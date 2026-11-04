import Darwin
import Foundation
import NetworkExtension
import OSLog

final class V2STunnelProvider: NEPacketTunnelProvider {
    private let logger = Logger(subsystem: "ca.irisbuddy.v2s.macos.Tunnel", category: "PacketTunnel")
    private var xrayStarted = false

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        do {
            logger.info("Tunnel startup requested")
            let data = try V2SStore.loadData()
            let settings = V2SStore.loadSettings()
            let requestedID = (options?["profileID"] as? String).flatMap(UUID.init(uuidString:))
            guard let profileID = requestedID ?? V2SStore.activeProfileID,
                  let profile = data.profiles.first(where: { $0.id == profileID })
            else { throw TunnelError.profileUnavailable }
            if settings.validationIssue != nil { throw TunnelError.settingsInvalid }

            let networkSettings = Self.networkSettings(settings: settings)
            logger.info("Applying packet tunnel network settings")

            setTunnelNetworkSettings(networkSettings) { [weak self] error in
                guard let self else {
                    completionHandler(Self.stableError(error ?? TunnelError.startFailed))
                    return
                }
                guard error == nil else {
                    completionHandler(error ?? TunnelError.startFailed)
                    return
                }
                do {
                    let tunnelDescriptor = try Self.findTunnelDescriptor()
                    self.logger.info("Packet tunnel interface is ready")
                    let xrayJSON = try V2SXray.buildTunnelConfiguration(
                        profile: profile,
                        settings: settings,
                        descriptor: Int(tunnelDescriptor)
                    )
                    _ = try? V2SXray.call("stopXray")
                    self.logger.info("Starting the VPN engine")
                    _ = try V2SXray.call("runXray", payload: ["xrayJson": xrayJSON])
                    guard Self.waitForEngineStartup() else { throw TunnelError.engineDidNotStart }
                    self.xrayStarted = true
                    self.logger.info("VPN engine entered the running state")
                    completionHandler(nil)
                } catch {
                    self.logger.error("VPN engine startup failed (\(String(describing: type(of: error)), privacy: .public))")
                    _ = try? V2SXray.call("stopXray")
                    self.xrayStarted = false
                    let safeError = Self.stableError(error)
                    self.setTunnelNetworkSettings(nil) { _ in completionHandler(safeError) }
                }
            }
        } catch {
            logger.error("Tunnel startup failed before engine launch (\(String(describing: type(of: error)), privacy: .public))")
            completionHandler(Self.stableError(error))
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        // Restore macOS's physical routes before stopping Xray. If Xray is
        // stopped first, packets can briefly keep routing into a utun that no
        // longer has an engine reading it, which looks like the Mac has lost
        // its internet connection during disconnect.
        logger.info("Restoring the Mac network routes before stopping the VPN engine")
        setTunnelNetworkSettings(nil) { [weak self] error in
            guard let self else {
                completionHandler()
                return
            }
            if let error {
                self.logger.error("Could not clear tunnel network settings (\(String(describing: type(of: error)), privacy: .public))")
            }
            if self.xrayStarted { _ = try? V2SXray.call("stopXray") }
            self.xrayStarted = false
            self.logger.info("Packet tunnel stopped")
            completionHandler()
        }
    }

    private static func findTunnelDescriptor() throws -> Int32 {
        // Use the utun descriptor provided to the Network Extension. Xray's
        // macOS TUN inbound expects this descriptor; a socketpair is not a
        // substitute and can make the provider exit immediately.
        let sysprotoControl: Int32 = 2
        let utunOptIfName: Int32 = 2
        // Network Extensions can inherit a much larger open-file table than
        // the older fixed 0...1024 scan assumed. Query this process's actual
        // limit, with a cap so a misreported/unlimited limit cannot cause an
        // unbounded scan during tunnel startup.
        var fileLimits = rlimit()
        let descriptorLimit: Int
        if getrlimit(RLIMIT_NOFILE, &fileLimits) == 0 {
            descriptorLimit = Int(min(fileLimits.rlim_cur, 65_536))
        } else {
            descriptorLimit = 65_536
        }
        for descriptor in 0..<max(1, descriptorLimit) {
            var name = [CChar](repeating: 0, count: Int(IFNAMSIZ))
            var length = socklen_t(name.count)
            let result = name.withUnsafeMutableBytes { bytes in
                getsockopt(Int32(descriptor), sysprotoControl, utunOptIfName, bytes.baseAddress, &length)
            }
            guard result == 0 else { continue }
            if String(cString: name).hasPrefix("utun") { return Int32(descriptor) }
        }
        throw TunnelError.tunnelDescriptorUnavailable
    }

    /// `runXray` can return before the embedded core publishes its running
    /// state. Poll briefly so a normal startup race does not tear down a
    /// tunnel that is still initializing; a core that never becomes ready
    /// still fails closed.
    private static func waitForEngineStartup() -> Bool {
        let attempts = 50
        for attempt in 0..<attempts {
            if (try? V2SXray.isRunning()) == true { return true }
            if attempt + 1 < attempts { Thread.sleep(forTimeInterval: 0.1) }
        }
        return false
    }

    private static func stableError(_ error: Error) -> NSError {
        let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let code = (error as? TunnelError)?.rawValue ?? 100
        return NSError(
            domain: "ca.irisbuddy.v2s.tunnel",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }

    private static func networkSettings(settings: V2SSettings) -> NEPacketTunnelNetworkSettings {
        // Match the previous working Mac client. Resolving the proxy host from
        // inside the extension can fail before the tunnel starts; the provider
        // uses this placeholder while Xray resolves the imported hostname.
        let result = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        // Match Xray's configured TUN gateway, as in the previously working Mac client.
        let ipv4 = NEIPv4Settings(addresses: ["10.77.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [.default()]
        if settings.routingEnabled && settings.bypassPrivateNetworks {
            ipv4.excludedRoutes = [
                NEIPv4Route(destinationAddress: "10.0.0.0", subnetMask: "255.0.0.0"),
                NEIPv4Route(destinationAddress: "172.16.0.0", subnetMask: "255.240.0.0"),
                NEIPv4Route(destinationAddress: "192.168.0.0", subnetMask: "255.255.0.0"),
                NEIPv4Route(destinationAddress: "127.0.0.0", subnetMask: "255.0.0.0"),
                NEIPv4Route(destinationAddress: "169.254.0.0", subnetMask: "255.255.0.0")
            ]
        }
        result.ipv4Settings = ipv4

        // Keep both IP families inside the tunnel regardless of the DNS
        // resolver preference. Omitting IPv6 settings on an IPv4-preferred
        // profile leaves the Mac's physical IPv6 default route untouched,
        // which can bypass the VPN even while IPv4 is protected.
        let ipv6 = NEIPv6Settings(addresses: ["fd00::2"], networkPrefixLengths: [64])
        ipv6.includedRoutes = [.default()]
        if settings.routingEnabled && settings.bypassPrivateNetworks {
            ipv6.excludedRoutes = [
                NEIPv6Route(destinationAddress: "::1", networkPrefixLength: 128),
                NEIPv6Route(destinationAddress: "fc00::", networkPrefixLength: 7),
                NEIPv6Route(destinationAddress: "fe80::", networkPrefixLength: 10)
            ]
        }
        result.ipv6Settings = ipv6
        if !settings.dnsServers.isEmpty {
            let dns = NEDNSSettings(servers: settings.dnsServers)
            dns.matchDomains = [""]
            result.dnsSettings = dns
        }
        result.mtu = 1_500
        return result
    }

}

private enum TunnelError: Int, LocalizedError {
    case startFailed
    case tunnelDescriptorUnavailable
    case engineDidNotStart
    case profileUnavailable
    case settingsInvalid

    var errorDescription: String? {
        switch self {
        case .startFailed: "The V2S macOS tunnel could not start."
        case .tunnelDescriptorUnavailable: "macOS did not provide a tunnel interface to V2S."
        case .engineDidNotStart: "The V2S VPN engine did not remain running after startup."
        case .profileUnavailable: "Select an available V2S server before connecting."
        case .settingsInvalid: "Review the V2S network settings before connecting."
        }
    }
}
