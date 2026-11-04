import Combine
import Foundation
import NetworkExtension

@MainActor
final class MacVPNController: ObservableObject {
    static let shared = MacVPNController()
    static let providerID = "ca.irisbuddy.v2s.macos.Tunnel"

    @Published private(set) var status: NEVPNStatus = .invalid
    @Published private(set) var prepared = false
    private(set) var connectedProfileID: UUID?
    private var manager: NETunnelProviderManager?

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(statusChanged(_:)),
            name: .NEVPNStatusDidChange,
            object: nil
        )
    }

    var canTestServers: Bool { status == .disconnected || status == .invalid }

    @objc private func statusChanged(_ note: Notification) {
        // A status notification may belong to another installed VPN. Read the
        // state from V2S's own manager instead of trusting the notification object.
        Task { @MainActor [weak self] in self?.refreshStatusFromManager() }
    }

    private func refreshStatusFromManager() {
        guard let connection = manager?.connection else { return }
        updateStatus(connection.status)
    }

    private func updateStatus(_ newStatus: NEVPNStatus) {
        let oldStatus = status
        status = newStatus
        guard oldStatus != status else { return }
        if status == .disconnected || status == .invalid {
            connectedProfileID = nil
            V2SStore.connectedProfileID = nil
        } else if status == .connected {
            connectedProfileID = V2SStore.connectedProfileID ?? V2SStore.activeProfileID
        }
        switch status {
        case .connected: V2SActivityLog.shared.record("VPN tunnel connected.")
        case .connecting: V2SActivityLog.shared.record("VPN tunnel connecting.")
        case .reasserting: V2SActivityLog.shared.record("VPN tunnel reconnecting.", level: .warning)
        case .disconnecting: V2SActivityLog.shared.record("VPN tunnel disconnecting.")
        case .disconnected: V2SActivityLog.shared.record("VPN tunnel disconnected.")
        case .invalid: V2SActivityLog.shared.record("VPN configuration is unavailable.", level: .warning)
        @unknown default: V2SActivityLog.shared.record("VPN status changed.")
        }
    }

    func prepare() async throws {
        let privacyTicket = V2SPrivacyConsent.shared.ticket
        guard V2SPrivacyConsent.shared.permits(privacyTicket) else { throw CancellationError() }
        let all = try await NETunnelProviderManager.loadAllFromPreferences()
        guard V2SPrivacyConsent.shared.permits(privacyTicket) else { throw CancellationError() }
        let selected = all.first { manager in
            (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.providerID
        } ?? NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = Self.providerID
        proto.serverAddress = "V2S"
        let settings = V2SStore.loadSettings()
        proto.disconnectOnSleep = settings.disconnectOnSleep
        let includeAllNetworks = settings.includeAllNetworks ?? false
        proto.includeAllNetworks = includeAllNetworks
        proto.excludeLocalNetworks = settings.bypassPrivateNetworks
        proto.enforceRoutes = includeAllNetworks
        selected.protocolConfiguration = proto
        selected.localizedDescription = "V2S"
        selected.isEnabled = true
        let hasActiveProfile = V2SStore.activeProfileID != nil
        selected.onDemandRules = settings.onDemand && hasActiveProfile ? [NEOnDemandRuleConnect()] : []
        selected.isOnDemandEnabled = settings.onDemand && hasActiveProfile
        try await selected.saveToPreferences()
        guard V2SPrivacyConsent.shared.permits(privacyTicket) else {
            try await stopForPrivacyWithdrawal()
            throw CancellationError()
        }
        try await selected.loadFromPreferences()
        guard V2SPrivacyConsent.shared.permits(privacyTicket) else {
            try await stopForPrivacyWithdrawal()
            throw CancellationError()
        }
        manager = selected
        updateStatus(selected.connection.status)
        if status == .connecting || status == .disconnecting || status == .reasserting {
            let latest = try await NETunnelProviderManager.loadAllFromPreferences()
            if let refreshed = latest.first(where: {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.providerID
            }) {
                manager = refreshed
                updateStatus(refreshed.connection.status)
            }
        }
        if status == .connected {
            connectedProfileID = V2SStore.connectedProfileID ?? V2SStore.activeProfileID
        } else if status == .disconnected || status == .invalid {
            connectedProfileID = nil
            V2SStore.connectedProfileID = nil
        }
        prepared = true
    }

    func connect(profile: V2SProfile) async throws {
        let privacyTicket = V2SPrivacyConsent.shared.ticket
        guard V2SPrivacyConsent.shared.permits(privacyTicket) else { throw CancellationError() }
        try await prepare()
        guard V2SPrivacyConsent.shared.permits(privacyTicket) else { throw CancellationError() }
        guard let manager else { throw MacVPNError.unavailable }

        guard status != .connecting && status != .reasserting && status != .disconnecting else {
            throw MacVPNError.connectionInProgress
        }

        if status == .connected {
            guard connectedProfileID != profile.id else { return }
            // Suspend on-demand reconnect until the selected profile is installed.
            if manager.isOnDemandEnabled {
                manager.isOnDemandEnabled = false
                try await manager.saveToPreferences()
                try await manager.loadFromPreferences()
            }
            manager.connection.stopVPNTunnel()
            for _ in 0..<100 {
                updateStatus(manager.connection.status)
                if status == .disconnected || status == .invalid { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard status == .disconnected || status == .invalid else {
                throw MacVPNError.disconnectTimedOut
            }
        }

        guard V2SPrivacyConsent.shared.permits(privacyTicket) else { throw CancellationError() }
        try V2SStore.saveActiveProfileID(profile.id)
        V2SStore.connectedProfileID = profile.id
        do {
            try manager.connection.startVPNTunnel(options: ["profileID": profile.id.uuidString as NSString])
            updateStatus(.connecting)
        } catch {
            connectedProfileID = nil
            V2SStore.connectedProfileID = nil
            throw error
        }

        // startVPNTunnel only accepts the request; wait for the extension to
        // connect and report its real failure instead of leaving a stale spinner.
        for attempt in 0..<60 {
            try await Task.sleep(for: .milliseconds(500))
            guard V2SPrivacyConsent.shared.permits(privacyTicket) else { throw CancellationError() }
            if attempt == 4 {
                let latest = try? await NETunnelProviderManager.loadAllFromPreferences()
                if let refreshed = latest?.first(where: {
                    ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.providerID
                }) {
                    self.manager = refreshed
                }
            }
            refreshStatusFromManager()
            if status == .connected {
                if V2SStore.loadSettings().onDemand && !manager.isOnDemandEnabled {
                    manager.isOnDemandEnabled = true
                    try await manager.saveToPreferences()
                }
                return
            }
            if (status == .disconnected || status == .invalid), attempt >= 10 {
                throw MacVPNError.tunnelFailed(await lastDisconnectDescription())
            }
        }
        refreshStatusFromManager()
        if status != .connected {
            throw MacVPNError.startTimedOut(await lastDisconnectDescription())
        }
    }

    func disconnect() {
        manager?.connection.stopVPNTunnel()
        updateStatus(.disconnecting)
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Revocation can arrive during app startup, before prepare() has
            // loaded a tunnel that macOS kept running while the app was closed.
            if self.manager == nil {
                let existing = try? await NETunnelProviderManager.loadAllFromPreferences()
                self.manager = existing?.first(where: {
                    ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.providerID
                })
                self.manager?.connection.stopVPNTunnel()
                if self.manager == nil {
                    self.updateStatus(.invalid)
                    return
                }
            }
            for attempt in 0..<20 {
                try? await Task.sleep(for: .milliseconds(500))
                if attempt == 4 {
                    let latest = try? await NETunnelProviderManager.loadAllFromPreferences()
                    if let refreshed = latest?.first(where: {
                        ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.providerID
                    }) {
                        self.manager = refreshed
                    }
                }
                self.refreshStatusFromManager()
                if self.status == .disconnected || self.status == .invalid { return }
            }
        }
    }

    func stopForPrivacyWithdrawal() async throws {
        manager?.connection.stopVPNTunnel()
        let existing = try await NETunnelProviderManager.loadAllFromPreferences()
        for item in existing where (item.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.providerID {
            item.connection.stopVPNTunnel()
            item.isOnDemandEnabled = false
            item.onDemandRules = []
            item.isEnabled = false
            try await item.saveToPreferences()
            item.connection.stopVPNTunnel()
            manager = item
        }
        prepared = false
        refreshStatusFromManager()
    }

    private func lastDisconnectDescription() async -> String? {
        guard let connection = manager?.connection else { return nil }
        return await withCheckedContinuation { continuation in
            connection.fetchLastDisconnectError { error in
                continuation.resume(returning: error?.localizedDescription)
            }
        }
    }
}

enum MacVPNError: LocalizedError {
    case unavailable
    case profileUnavailable
    case settingsInvalid
    case disconnectTimedOut
    case connectionInProgress
    case tunnelFailed(String?)
    case startTimedOut(String?)

    var errorDescription: String? {
        switch self {
        case .unavailable: "The V2S macOS VPN service is unavailable."
        case .profileUnavailable: "Select an available V2S server before connecting."
        case .settingsInvalid: "Review the V2S network settings before connecting."
        case .disconnectTimedOut: "V2S could not finish disconnecting from the current server. Try again shortly."
        case .connectionInProgress: "V2S is already changing connection state. Wait a moment, then try again."
        case .tunnelFailed(let detail):
            if let detail, !detail.isEmpty { "The V2S tunnel stopped before it connected: \(detail)" }
            else { "The V2S tunnel stopped before it connected. Check VPN access in System Settings and try again." }
        case .startTimedOut(let detail):
            if let detail, !detail.isEmpty { "V2S did not finish connecting: \(detail)" }
            else { "V2S did not finish connecting. Check VPN status in System Settings and try again." }
        }
    }
}
