import Foundation
import Network
import NetworkExtension
import Combine
import UIKit

@MainActor
final class VPNManager: NSObject, ObservableObject {

    static let shared = VPNManager()

    @Published private(set) var status: NEVPNStatus = .invalid
    @Published private(set) var isPrepared = false
    @Published private(set) var connectedDate: Date?

    private var manager: NETunnelProviderManager?
    private let connectedFeedback = UIImpactFeedbackGenerator(style: .medium)
    private let disconnectedFeedback = UIImpactFeedbackGenerator(style: .medium)

    private let providerBundleIdentifier =
        "ca.irisbuddy.v2s.macos.Tunnel"

    private override init() {
        super.init()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(vpnStatusDidChange(_:)),
            name: .NEVPNStatusDidChange,
            object: nil
        )
    }

    @objc
    private func vpnStatusDidChange(_ notification: Notification) {

        guard
            let connection = notification.object as? NEVPNConnection
        else {
            return
        }

        let oldStatus = status
        let newStatus = connection.status

        status = newStatus
        connectedDate = connection.status == .connected
            ? connection.connectedDate
            : nil

        playHapticTransition(
            from: oldStatus,
            to: newStatus
        )

    }

    private func playHapticTransition(
        from oldStatus: NEVPNStatus,
        to newStatus: NEVPNStatus
    ) {
        switch newStatus {
        case .connecting, .reasserting:
            connectedFeedback.prepare()

        case .disconnecting:
            disconnectedFeedback.prepare()

        case .connected where oldStatus != .connected:
            connectedFeedback.impactOccurred(intensity: 1.0)
            connectedFeedback.prepare()

        case .disconnected
            where oldStatus == .connected
                || oldStatus == .reasserting
                || oldStatus == .disconnecting
                || oldStatus == .connecting:
            disconnectedFeedback.impactOccurred(intensity: 0.85)
            disconnectedFeedback.prepare()

        default:
            break
        }
    }

    func prepare() async throws {

        let managers =
            try await NETunnelProviderManager
                .loadAllFromPreferences()

        let selectedManager: NETunnelProviderManager

        if let existing = managers.first(where: { manager in
            guard
                let tunnelProtocol =
                    manager.protocolConfiguration
                        as? NETunnelProviderProtocol
            else {
                return false
            }

            return tunnelProtocol.providerBundleIdentifier
                == providerBundleIdentifier
        }) {
            selectedManager = existing
        } else {
            selectedManager = NETunnelProviderManager()
        }

        let tunnelProtocol = NETunnelProviderProtocol()
        let settings = SharedConfiguration.loadSettings()

        tunnelProtocol.providerBundleIdentifier =
            providerBundleIdentifier

        tunnelProtocol.serverAddress =
            "V2S"

        tunnelProtocol.disconnectOnSleep = settings.tunnel.disconnectOnSleep
        tunnelProtocol.includeAllNetworks = settings.tunnel.includeAllNetworks
        tunnelProtocol.excludeLocalNetworks = settings.tunnel.excludeLocalNetworks
        tunnelProtocol.excludeCellularServices = settings.tunnel.excludeCellularServices
        tunnelProtocol.excludeAPNs = settings.tunnel.excludeAPNs
        tunnelProtocol.enforceRoutes = settings.tunnel.includeAllNetworks

        selectedManager.protocolConfiguration =
            tunnelProtocol

        selectedManager.localizedDescription =
            "V2S"

        selectedManager.isEnabled = true
        selectedManager.onDemandRules = settings.tunnel.onDemandEnabled
            ? [NEOnDemandRuleConnect()]
            : []
        selectedManager.isOnDemandEnabled = settings.tunnel.onDemandEnabled

        try await selectedManager.saveToPreferences()
        try await selectedManager.loadFromPreferences()

        manager = selectedManager

        status =
            selectedManager.connection.status

        connectedDate = selectedManager.connection.status == .connected
            ? selectedManager.connection.connectedDate
            : nil

        isPrepared = true
    }

    func connect() async throws {
        // Re-save the provider settings before every new connection so any
        // tunnel, DNS or on-demand changes are applied after reconnecting.
        try await prepare()

        guard let manager else {
            throw VPNManagerError.configurationUnavailable
        }

        try manager.connection.startVPNTunnel()
    }

    func disconnect() {

        manager?
            .connection
            .stopVPNTunnel()
    }
}

enum VPNManagerError: LocalizedError {

    case configurationUnavailable

    var errorDescription: String? {

        switch self {

        case .configurationUnavailable:
            return "The V2S VPN configuration is unavailable."
        }
    }
}

enum ServerLatencyResult: Equatable, Sendable {
    case reachable(milliseconds: Int)
    case unreachable
}

@MainActor
final class ServerLatencyTester: ObservableObject {

    static let shared = ServerLatencyTester()

    @Published private(set) var results: [UUID: ServerLatencyResult] = [:]
    @Published private(set) var testingIDs = Set<UUID>()

    private init() {}

    func test(_ profile: ProxyProfile) {
        guard !testingIDs.contains(profile.id) else { return }

        let target = Self.target(for: profile)
        testingIDs.insert(profile.id)

        Task {
            let result = await Self.measure(host: target.host, port: target.port)
            results[target.id] = result
            testingIDs.remove(target.id)
        }
    }

    func testAll(_ profiles: [ProxyProfile]) {
        let targets = profiles
            .filter { !testingIDs.contains($0.id) }
            .map(Self.target(for:))

        guard !targets.isEmpty else { return }
        testingIDs.formUnion(targets.map(\.id))

        Task {
            var pending = targets.makeIterator()

            await withTaskGroup(
                of: (UUID, ServerLatencyResult).self
            ) { group in
                for _ in 0..<min(6, targets.count) {
                    guard let target = pending.next() else { break }
                    group.addTask {
                        let result = await Self.measure(
                            host: target.host,
                            port: target.port
                        )
                        return (target.id, result)
                    }
                }

                while let (id, result) = await group.next() {
                    results[id] = result
                    testingIDs.remove(id)

                    if let target = pending.next() {
                        group.addTask {
                            let result = await Self.measure(
                                host: target.host,
                                port: target.port
                            )
                            return (target.id, result)
                        }
                    }
                }
            }
        }
    }

    func clearResults() {
        results.removeAll()
    }

    private static func target(
        for profile: ProxyProfile
    ) -> (id: UUID, host: String, port: UInt16?) {
        (
            id: profile.id,
            host: profile.server,
            port: UInt16(exactly: profile.port)
        )
    }

    nonisolated private static func measure(
        host: String,
        port: UInt16?
    ) async -> ServerLatencyResult {
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let port,
              let networkPort = NWEndpoint.Port(rawValue: port) else {
            return .unreachable
        }

        return await withCheckedContinuation { continuation in
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: networkPort,
                using: .tcp
            )
            let completion = LatencyProbeCompletion(
                connection: connection,
                continuation: continuation
            )

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    completion.finishReachable()
                case .failed:
                    completion.finish(.unreachable)
                default:
                    break
                }
            }

            connection.start(queue: LatencyProbeCompletion.queue)
            LatencyProbeCompletion.queue.asyncAfter(
                deadline: .now() + .seconds(3)
            ) {
                completion.finish(.unreachable)
            }
        }
    }
}

nonisolated private final class LatencyProbeCompletion: @unchecked Sendable {

    static let queue = DispatchQueue(
        label: "com.rezaeskandari.V2S.latency",
        qos: .utility,
        attributes: .concurrent
    )

    private let lock = NSLock()
    private let startedAt = DispatchTime.now().uptimeNanoseconds
    private let connection: NWConnection
    private let continuation: CheckedContinuation<ServerLatencyResult, Never>
    private var hasFinished = false

    init(
        connection: NWConnection,
        continuation: CheckedContinuation<ServerLatencyResult, Never>
    ) {
        self.connection = connection
        self.continuation = continuation
    }

    func finishReachable() {
        let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt
        let milliseconds = max(1, Int(elapsed / 1_000_000))
        finish(.reachable(milliseconds: milliseconds))
    }

    func finish(_ result: ServerLatencyResult) {
        lock.lock()
        guard !hasFinished else {
            lock.unlock()
            return
        }
        hasFinished = true
        lock.unlock()

        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.resume(returning: result)
    }
}
