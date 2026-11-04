import Foundation
import NetworkExtension
import OSLog

final class PacketTunnelProvider: NEPacketTunnelProvider {

    private let logger = Logger(
        subsystem: "com.rezaeskandari.RayLink.RayLinkTunnel",
        category: "Tunnel"
    )

    private var xrayStarted = false

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let profile: ProxyProfile

        do {
            profile = try SharedConfiguration.loadProfile()

            guard let rawLink = profile.rawLink, !rawLink.isEmpty else {
                throw V2TehTunnelError.missingRawLink
            }

        } catch {
            completionHandler(error)
            return
        }

        setTunnelNetworkSettings(makeNetworkSettings()) { [weak self] error in
            guard let self else {
                completionHandler(V2TehTunnelError.providerUnavailable)
                return
            }

            if let error {
                completionHandler(error)
                return
            }

            do {
                try? LibXrayBridge.stopXray()

                let tunFD = try TunnelFileDescriptor.find()
                let xrayJSON = try XrayConfigBuilder.build(
                    profile: profile,
                    tunFD: tunFD
                )

                guard !xrayJSON.isEmpty else {
                    throw V2TehTunnelError.emptyXrayConfiguration
                }

                // Never log the generated JSON. It contains proxy credentials.
                try LibXrayBridge.runXray(json: xrayJSON)

                guard try LibXrayBridge.isRunning() else {
                    throw V2TehTunnelError.xrayDidNotStart
                }

                self.xrayStarted = true

                self.logger.info("V2Teh tunnel started")
                completionHandler(nil)
            } catch {
                try? LibXrayBridge.stopXray()
                self.xrayStarted = false
                self.logger.error("V2Teh tunnel startup failed")
                completionHandler(error)
            }
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        if xrayStarted {
            try? LibXrayBridge.stopXray()
        }

        xrayStarted = false
        logger.info("V2Teh tunnel stopped")
        completionHandler()
    }

    override func handleAppMessage(
        _ messageData: Data,
        completionHandler: ((Data?) -> Void)?
    ) {
        guard let message = String(data: messageData, encoding: .utf8) else {
            completionHandler?(nil)
            return
        }

        switch message {
        case "ping":
            completionHandler?(Data("pong".utf8))

        case "status":
            do {
                let response = try LibXrayBridge.isRunning()
                    ? "running"
                    : "stopped"
                completionHandler?(Data(response.utf8))
            } catch {
                completionHandler?(Data("error".utf8))
            }

        default:
            completionHandler?(nil)
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    override func wake() {}

    private func makeNetworkSettings() -> NEPacketTunnelNetworkSettings {
        let appSettings = SharedConfiguration.loadSettings()
        let settings = NEPacketTunnelNetworkSettings(
            tunnelRemoteAddress: "127.0.0.1"
        )

        let ipv4 = NEIPv4Settings(
            addresses: ["10.77.0.2"],
            subnetMasks: ["255.255.255.0"]
        )
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4

        if appSettings.tunnel.preferredIPType != .ipv4 {
            let ipv6 = NEIPv6Settings(
                addresses: ["fd00::2"],
                networkPrefixLengths: [64]
            )
            ipv6.includedRoutes = [NEIPv6Route.default()]
            settings.ipv6Settings = ipv6
        }

        let dnsServers = appSettings.dns.preset.servers(
            customText: appSettings.dns.customServers
        )
        if !dnsServers.isEmpty {
            let dns = NEDNSSettings(servers: dnsServers)
            dns.matchDomains = [""]
            settings.dnsSettings = dns
        }

        settings.mtu = 1500

        return settings
    }
}

enum V2TehTunnelError: LocalizedError {
    case providerUnavailable
    case missingRawLink
    case emptyXrayConfiguration
    case xrayDidNotStart

    var errorDescription: String? {
        switch self {
        case .providerUnavailable:
            return "The V2Teh Packet Tunnel Provider became unavailable."
        case .missingRawLink:
            return "The selected profile has no original configuration link. Re-import the server in V2Teh."
        case .emptyXrayConfiguration:
            return "Xray configuration generation returned an empty configuration."
        case .xrayDidNotStart:
            return "Xray did not enter the running state."
        }
    }
}
