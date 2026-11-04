import AppKit
import Combine
import Foundation
import StoreKit

@MainActor
final class V2SViewModel: ObservableObject {
    @Published private(set) var data = V2SData()
    @Published private(set) var pinging = Set<UUID>()
    @Published private(set) var isPingingAll = false
    @Published private(set) var isDiscoveringCommunity = false
    @Published private(set) var isRefreshingSubscriptions = false
    @Published private(set) var communityScanProgress = ""
    @Published private(set) var statusMessage = "Select a server to connect."
    @Published private(set) var errorMessage: String?
    @Published private(set) var settings = V2SStore.loadSettings()
    @Published var selectedProfileID: UUID? {
        didSet { V2SStore.activeProfileID = selectedProfileID }
    }

    @Published private(set) var isChangingPrivacyConsent = false
    @Published private(set) var privacyStopError: String?
    private var startupTask: Task<Void, Never>?
    private var privacyStopTask: Task<Void, Never>?

    private var pingTask: Task<Void, Never>?
    private var communityScanTask: Task<Void, Never>?
    private var refreshLoop: Task<Void, Never>?
    private var vpnStatusObservation: AnyCancellable?
    private var premiumProfilesObservation: AnyCancellable?

    init() {
        do {
            try V2SStore.prepareInstallation()
        } catch {
            errorMessage = "V2S could not prepare secure local storage. Reopen the app and try again."
            return
        }
        selectedProfileID = V2SStore.activeProfileID
        settings = V2SStore.loadSettings()
        reload()
        premiumProfilesObservation = V2SPremiumStore.shared.$premiumProfiles
            .dropFirst()
            .sink { [weak self] profiles in
                self?.syncPremiumProfiles(profiles)
            }
        vpnStatusObservation = MacVPNController.shared.$status
            .removeDuplicates()
            .sink { [weak self] status in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if status == .connected {
                        self.statusMessage = "Connected to the active server."
                    } else if status == .disconnecting {
                        self.statusMessage = "Disconnecting from V2S…"
                    } else if (status == .disconnected || status == .invalid),
                              self.statusMessage == "Disconnecting from V2S…" {
                        self.statusMessage = "V2S disconnected."
                    }
                }
            }
        if V2SPrivacyConsent.shared.accepted { startNetworkFeatures() }
        else { withdrawPrivacyConsent() }
    }

    func acceptPrivacyConsent() {
        guard !isChangingPrivacyConsent, privacyStopError == nil else { return }
        V2SPrivacyConsent.shared.accept()
        statusMessage = selectedProfile == nil ? "Select a server to connect." : "Ready to connect to the selected server."
        startNetworkFeatures()
    }

    func removeLocalData() async {
        withdrawPrivacyConsent()
        await privacyStopTask?.value
        guard privacyStopError == nil else { return }
        do {
            selectedProfileID = nil
            try V2SStore.removeLocalConfiguration()
            data = V2SData()
            settings = V2SSettings()
            V2SActivityLog.shared.clear()
            statusMessage = "Local configurations removed. Your Apple subscription is unchanged."
        } catch {
            privacyStopError = "Some local configuration could not be removed. Reopen V2S and retry; do not uninstall until cleanup succeeds."
        }
    }

    func withdrawPrivacyConsent() {
        V2SPrivacyConsent.shared.revoke()
        startupTask?.cancel()
        refreshLoop?.cancel()
        pingTask?.cancel()
        communityScanTask?.cancel()
        V2SPremiumStore.shared.withdrawPrivacyConsent()
        var updated = settings
        updated.autoConnect = false
        updated.onDemand = false
        updateSettings(updated)
        errorMessage = nil
        statusMessage = "Network features are off until you agree to the privacy disclosure."
        privacyStopError = nil
        isChangingPrivacyConsent = true
        privacyStopTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await MacVPNController.shared.stopForPrivacyWithdrawal()
                self.isChangingPrivacyConsent = false
            } catch {
                // Consent remains revoked. Never silently claim that an OS rule
                // was disabled when saving VPN preferences failed.
                self.privacyStopError = "V2S could not disable its VPN rules. Turn V2S off in System Settings > VPN, then reopen V2S."
                self.isChangingPrivacyConsent = false
            }
        }
    }

    private func startNetworkFeatures() {
        startupTask?.cancel()
        refreshLoop?.cancel()
        let ticket = V2SPrivacyConsent.shared.ticket
        startupTask = Task { [weak self] in
            guard let self, V2SPrivacyConsent.shared.permits(ticket) else { return }
            await V2SPremiumStore.shared.load()
            guard V2SPrivacyConsent.shared.permits(ticket), !Task.isCancelled else { return }
            self.syncPremiumProfiles(V2SPremiumStore.shared.premiumProfiles)
            do {
                try await MacVPNController.shared.prepare()
                guard V2SPrivacyConsent.shared.permits(ticket), !Task.isCancelled else { return }
                if V2SStore.loadSettings().autoConnectEnabled, self.selectedProfile != nil {
                    await self.connectSelected()
                }
            } catch {
                guard V2SPrivacyConsent.shared.permits(ticket) else { return }
                V2SActivityLog.shared.record("VPN preferences could not be prepared.", level: .warning)
            }
            guard V2SPrivacyConsent.shared.permits(ticket), !Task.isCancelled else { return }
            await self.refreshDueSources()
        }
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled, V2SPrivacyConsent.shared.permits(ticket) {
                do { try await Task.sleep(for: .seconds(30 * 60)) } catch { return }
                guard !Task.isCancelled, V2SPrivacyConsent.shared.permits(ticket) else { return }
                await self?.refreshDueSources()
            }
        }
    }

    var selectedProfile: V2SProfile? {
        data.profiles.first { $0.id == selectedProfileID }
    }

    private var connectionRequestInProgress = false

    func selectAndSwitch(_ profile: V2SProfile) async {
        let controller = MacVPNController.shared
        guard !connectionRequestInProgress,
              controller.status != .connecting,
              controller.status != .reasserting,
              controller.status != .disconnecting else { return }
        let shouldSwitch = controller.status == .connected && controller.connectedProfileID != profile.id
        select(profile)
        if shouldSwitch { await connect(profile: profile) }
    }

    func select(_ profile: V2SProfile) {
        selectedProfileID = profile.id
        statusMessage = "Ready to connect to the selected server."
    }

    func reload() {
        do {
            var loaded = try V2SStore.loadData()
            var changedNames = loaded.removeLegacyCommunityProfiles()
            for index in loaded.profiles.indices {
                let profile = loaded.profiles[index]
                let generatedName = "\(profile.protocolName.uppercased()) · \(profile.server)"
                guard profile.name == generatedName,
                      let providerName = V2SXray.suggestedProfileName(from: profile.shareLink) else { continue }
                loaded.profiles[index].name = providerName
                changedNames = true
            }
            if changedNames { try V2SStore.saveData(loaded) }
            data = loaded
            if selectedProfileID == nil || !data.profiles.contains(where: { $0.id == selectedProfileID }) {
                selectedProfileID = data.profiles.first?.id
            }
            if selectedProfile != nil {
                statusMessage = "Ready to connect to the selected server."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearError() { errorMessage = nil }

    func purchasePremium(_ product: Product) async {
        guard V2SPrivacyConsent.shared.accepted else { return }
        await V2SPremiumStore.shared.purchase(product)
        syncPremiumProfiles(V2SPremiumStore.shared.premiumProfiles)
    }

    func restorePremium() async {
        guard V2SPrivacyConsent.shared.accepted else { return }
        await V2SPremiumStore.shared.restore()
        syncPremiumProfiles(V2SPremiumStore.shared.premiumProfiles)
    }

    @discardableResult
    private func syncPremiumProfiles(_ profiles: [V2SProfile]) -> Bool {
        var updated = data
        updated.replacePremiumProfiles(with: profiles)
        let controller = MacVPNController.shared
        if let connectedID = controller.connectedProfileID ?? V2SStore.connectedProfileID,
           data.profiles.contains(where: { $0.id == connectedID && $0.isPremium == true }),
           !updated.profiles.contains(where: { $0.id == connectedID && $0.isPremium == true }) {
            // Stop revoked/rotated access even if saving the updated list fails.
            controller.disconnect()
            statusMessage = "Premium access changed. The Premium tunnel has been disconnected."
        }
        do {
            try V2SStore.saveData(updated)
            data = updated
            if let selectedProfileID, !updated.profiles.contains(where: { $0.id == selectedProfileID }) {
                self.selectedProfileID = updated.profiles.first?.id
            }
            return true
        } catch {
            errorMessage = "V2S could not securely update the Premium server list."
            return false
        }
    }

    func updateSettings(_ updated: V2SSettings) {
        let wasCommunityEnabled = settings.communityDiscoveryEnabled
        settings = updated
        V2SStore.saveSettings(updated)
        if updated.communityDiscoveryEnabled && !wasCommunityEnabled {
            V2SStore.defaults?.removeObject(forKey: "v2s.community.lastRefresh")
            // Start the first permitted scan now; the existing loop handles later 30-minute checks.
            if V2SPrivacyConsent.shared.accepted, MacVPNController.shared.canTestServers {
                scanCommunityServers()
            }
        }
    }

    func importText(_ text: String, name: String) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let links = text.split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !links.isEmpty else {
            errorMessage = "Paste one or more VLESS, VMess, Trojan, or Shadowsocks links."
            return
        }
        do {
            var updated = data
            var added = 0
            for (index, link) in links.enumerated() {
                var profile = try V2SXray.makeProfile(from: link)
                if !cleanName.isEmpty {
                    profile.name = links.count == 1 ? cleanName : "\(cleanName) \(index + 1)"
                } else if profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    profile.name = "\(profile.protocolName.uppercased()) · \(profile.server)"
                }
                guard !updated.profiles.contains(where: { $0.shareLink == profile.shareLink }) else { continue }
                updated.profiles.append(profile)
                added += 1
            }
            try V2SStore.saveData(updated)
            data = updated
            selectedProfileID = updated.profiles.last?.id
            statusMessage = "Added \(added) new server configuration\(added == 1 ? "" : "s")."
            V2SActivityLog.shared.record("Imported \(added) server configuration(s).")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ profile: V2SProfile) {
        do {
            var updated = data
            updated.profiles.removeAll { $0.id == profile.id }
            try V2SStore.saveData(updated)
            data = updated
            V2SActivityLog.shared.record("Removed a server configuration.")
            if selectedProfileID == profile.id { selectedProfileID = updated.profiles.first?.id }
        } catch { errorMessage = error.localizedDescription }
    }

    @discardableResult
    func replaceManualProfile(_ profile: V2SProfile, with link: String, name: String) -> Bool {
        guard MacVPNController.shared.canTestServers else {
            errorMessage = "Disconnect V2S before updating a server."
            return false
        }
        guard profile.sourceID == nil, profile.isCommunity != true, profile.isPremium != true,
              data.profiles.contains(where: { $0.id == profile.id }) else { return false }
        do {
            var replacement = try V2SXray.makeProfile(from: link.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !data.profiles.contains(where: { $0.id != profile.id && $0.shareLink == replacement.shareLink }) else {
                errorMessage = "This server link is already in your list."
                return false
            }
            replacement.id = profile.id
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedName.isEmpty { replacement.name = trimmedName }
            var updated = data
            guard let index = updated.profiles.firstIndex(where: { $0.id == profile.id }) else { return false }
            updated.profiles[index] = replacement
            try V2SStore.saveData(updated)
            data = updated
            statusMessage = "Server configuration updated."
            V2SActivityLog.shared.record("Updated a server configuration.")
            return true
        } catch {
            errorMessage = "The replacement server link could not be read or saved."
            return false
        }
    }

    func copyServerLink(_ profile: V2SProfile) {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(profile.shareLink, forType: .string) else {
            errorMessage = "V2S could not copy this server link to the clipboard."
            return
        }
        statusMessage = "Server link copied to the clipboard."
        V2SActivityLog.shared.record("Copied a server link to the clipboard.")
    }

    func addSubscription(url: String, name: String) async {
        guard V2SPrivacyConsent.shared.accepted else { return }
        let cleanURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanName = requestedName.isEmpty ? V2SSubscriptionService.suggestedName(for: cleanURL) : requestedName
        let privacyTicket = V2SPrivacyConsent.shared.ticket
        do {
            let source = V2SSubscription(name: cleanName, url: cleanURL)
            let download = try await V2SSubscriptionService.download(
                source,
                allowInvalidCertificate: V2SStore.loadSettings().insecureSubscriptionCertificates
            )
            guard V2SPrivacyConsent.shared.permits(privacyTicket), !Task.isCancelled else { return }
            var updated = data
            var savedSource = source
            let sourceID = updated.subscriptions.first(where: { $0.url == cleanURL })?.id ?? source.id
            savedSource.usage = download.usage
            updated.profiles.removeAll { $0.sourceID == sourceID }
            savedSource.id = sourceID
            savedSource.lastUpdated = Date()
            if let index = updated.subscriptions.firstIndex(where: { $0.id == sourceID }) {
                updated.subscriptions[index] = savedSource
            } else {
                updated.subscriptions.append(savedSource)
            }
            updated.profiles.append(contentsOf: download.profiles.map { profile in
                var item = profile
                item.sourceID = sourceID
                item.sourceName = savedSource.name
                return item
            })
            try V2SStore.saveData(updated)
            data = updated
            selectedProfileID = updated.profiles.last?.id
            statusMessage = "Imported \(download.profiles.count) server profiles from \(source.name)."
            V2SActivityLog.shared.record("Imported \(download.profiles.count) profiles from a subscription.")
        } catch { if V2SPrivacyConsent.shared.permits(privacyTicket) { errorMessage = error.localizedDescription } }
    }

    func refresh(_ source: V2SSubscription) async {
        guard V2SPrivacyConsent.shared.accepted else { return }
        guard MacVPNController.shared.canTestServers else {
            errorMessage = "Disconnect V2S before refreshing a subscription."
            return
        }
        let privacyTicket = V2SPrivacyConsent.shared.ticket
        do {
            let download = try await V2SSubscriptionService.download(
                source,
                allowInvalidCertificate: V2SStore.loadSettings().insecureSubscriptionCertificates
            )
            guard V2SPrivacyConsent.shared.permits(privacyTicket), !Task.isCancelled else { return }
            var updated = data
            updated.profiles.removeAll { $0.sourceID == source.id }
            updated.profiles.append(contentsOf: download.profiles.map { profile in
                var item = profile
                item.sourceID = source.id
                item.sourceName = source.name
                return item
            })
            if let index = updated.subscriptions.firstIndex(where: { $0.id == source.id }) {
                updated.subscriptions[index].lastUpdated = Date()
                // Some providers intermittently omit quota headers. Keep the
                // last reported allowance instead of making it disappear.
                updated.subscriptions[index].usage = download.usage ?? source.usage
            }
            try V2SStore.saveData(updated)
            data = updated
            if selectedProfileID.map({ id in updated.profiles.contains(where: { $0.id == id }) }) != true {
                selectedProfileID = download.profiles.first?.id
            }
            statusMessage = "Updated \(source.name) with \(download.profiles.count) server profiles."
            V2SActivityLog.shared.record("Subscription refreshed with \(download.profiles.count) profiles.")
        } catch { if V2SPrivacyConsent.shared.permits(privacyTicket) { errorMessage = error.localizedDescription } }
    }

    func refreshAllSubscriptions() async {
        guard V2SPrivacyConsent.shared.accepted else { return }
        guard !isRefreshingSubscriptions else { return }
        guard MacVPNController.shared.canTestServers else {
            errorMessage = "Disconnect V2S before updating subscriptions."
            return
        }
        let sources = data.subscriptions
        guard !sources.isEmpty else { return }
        isRefreshingSubscriptions = true
        defer { isRefreshingSubscriptions = false }
        let privacyTicket = V2SPrivacyConsent.shared.ticket
        for source in sources {
            guard V2SPrivacyConsent.shared.permits(privacyTicket), MacVPNController.shared.canTestServers else { break }
            await refresh(source)
        }
    }

    func delete(_ source: V2SSubscription) {
        var updated = data
        updated.subscriptions.removeAll { $0.id == source.id }
        let active = selectedProfileID
        updated.profiles.removeAll { $0.sourceID == source.id }
        do {
            try V2SStore.saveData(updated)
            data = updated
            if let active, !updated.profiles.contains(where: { $0.id == active }) {
                selectedProfileID = updated.profiles.first?.id
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func scanCommunityServers() {
        guard V2SPrivacyConsent.shared.accepted else { return }
        guard !isDiscoveringCommunity, !isPingingAll, MacVPNController.shared.canTestServers else {
            errorMessage = "Disconnect V2S and finish other proxy checks before scanning."
            return
        }
        guard V2SStore.loadSettings().communityDiscoveryEnabled else {
            errorMessage = "Enable public server discovery in Settings first."
            return
        }
        isDiscoveringCommunity = true
        communityScanProgress = "Contacting the public feed…"
        let privacyTicket = V2SPrivacyConsent.shared.ticket
        communityScanTask = Task {
            defer {
                isDiscoveringCommunity = false
                communityScanTask = nil
            }
            do {
                let feed = try await V2SCommunityService.download()
                guard V2SPrivacyConsent.shared.permits(privacyTicket), !Task.isCancelled else { return }
                let candidates = Array(feed.profiles.prefix(V2SCommunityService.maxEntries))
                communityScanProgress = candidates.isEmpty
                    ? "No approved free-server candidates are available in the current catalog."
                    : "Checking \(candidates.count) free-server candidates…"
                var responseTimes: [UUID: Int] = [:]
                var checked = 0
                for start in stride(from: 0, to: candidates.count, by: 5) {
                    guard !Task.isCancelled, V2SPrivacyConsent.shared.accepted else { break }
                    let batch = Array(candidates[start..<min(start + 5, candidates.count)])
                    let results = await Self.proxyLatency(for: batch)
                    for profile in batch {
                        checked += 1
                        if let latency = results[profile.id] { responseTimes[profile.id] = latency }
                    }
                    communityScanProgress = "Checked \(checked) of \(candidates.count) public servers · \(responseTimes.count) responded"
                }
                guard !Task.isCancelled, V2SPrivacyConsent.shared.permits(privacyTicket) else {
                    communityScanProgress = "Public server scan cancelled. Your saved list was left unchanged."
                    return
                }
                let previous = data.profiles.filter { $0.isCommunity == true }.reduce(into: [String: V2SProfile]()) { map, profile in
                    map[profile.shareLink] = profile
                }
                var saved: [V2SProfile] = []
                for var profile in candidates {
                    let latency = responseTimes[profile.id]
                    guard let latency else { continue }
                    if let old = previous[profile.shareLink] { profile.id = old.id }
                    profile.latencyMilliseconds = latency
                    saved.append(profile)
                }
                saved.sort {
                    switch ($0.latencyMilliseconds, $1.latencyMilliseconds) {
                    case let (left?, right?): left < right
                    case (_?, nil): true
                    case (nil, _?): false
                    case (nil, nil): $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    }
                }
                saved = Array(saved.prefix(V2SCommunityService.resultLimit))
                var updated = data
                updated.profiles.removeAll { $0.isCommunity == true }
                updated.profiles.append(contentsOf: saved)
                try V2SStore.saveData(updated)
                data = updated
                if selectedProfileID.map({ id in updated.profiles.contains(where: { $0.id == id }) }) != true {
                    selectedProfileID = saved.first?.id ?? updated.profiles.first?.id
                }
                V2SStore.defaults?.set(Date(), forKey: "v2s.community.lastRefresh")
                statusMessage = saved.isEmpty
                    ? (candidates.isEmpty
                        ? "No approved free-server candidates are available in the current catalog."
                        : "No free servers passed the proxy check on this Mac. Checked \(candidates.count) candidates.")
                    : "\(saved.count) public server(s) passed a proxy check from \(feed.sourceCount) sources on this Mac."
                communityScanProgress = statusMessage
                V2SActivityLog.shared.record("\(saved.count) public server(s) passed a proxy check from \(feed.sourceCount) sources.")
            } catch {
                guard V2SPrivacyConsent.shared.permits(privacyTicket) else { return }
                communityScanProgress = "Public server scan failed. Try again later."
                errorMessage = error.localizedDescription
                V2SActivityLog.shared.record("Public server scan failed; private server details were not recorded.", level: .error)
            }
        }
    }

    func stopCommunityScan() { communityScanTask?.cancel() }

    private func refreshDueSources() async {
        guard V2SPrivacyConsent.shared.accepted else { return }
        let settings = V2SStore.loadSettings()
        guard MacVPNController.shared.canTestServers else { return }
        if settings.communityDiscoveryEnabled {
            let last = V2SStore.defaults?.object(forKey: "v2s.community.lastRefresh") as? Date ?? .distantPast
            if Date().timeIntervalSince(last) >= 30 * 60, !isPingingAll, !isDiscoveringCommunity {
                scanCommunityServers()
                while isDiscoveringCommunity, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        }
        guard settings.refreshSubscriptionsWhileOpen else { return }
        let interval = TimeInterval(max(1, min(settings.subscriptionRefreshHours, 24))) * 60 * 60
        for subscription in data.subscriptions {
            guard !Task.isCancelled, V2SPrivacyConsent.shared.accepted else { return }
            guard Date().timeIntervalSince(subscription.lastUpdated ?? .distantPast) >= interval,
                  MacVPNController.shared.canTestServers else { continue }
            await refresh(subscription)
        }
    }

    func connectSelected() async {
        guard let profile = selectedProfile else {
            errorMessage = "Select a server in Servers before connecting."
            return
        }
        await connect(profile: profile)
    }

    func connect(profile: V2SProfile) async {
        guard !connectionRequestInProgress else { return }
        connectionRequestInProgress = true
        defer { connectionRequestInProgress = false }

        let privacyTicket = V2SPrivacyConsent.shared.ticket
        guard V2SPrivacyConsent.shared.permits(privacyTicket) else { return }
        if profile.isPremium == true {
            let store = V2SPremiumStore.shared
            let verified = await store.refreshEntitlement()
            guard V2SPrivacyConsent.shared.permits(privacyTicket), !Task.isCancelled else { return }
            guard verified, store.isEntitled,
                  let current = store.premiumProfiles.first(where: { $0.shareLink == profile.shareLink }) else {
                syncPremiumProfiles(store.premiumProfiles)
                errorMessage = "An active Apple subscription and V2S server verification are required to connect to this premium server."
                return
            }
            guard syncPremiumProfiles(store.premiumProfiles),
                  let saved = data.profiles.first(where: { $0.isPremium == true && $0.shareLink == current.shareLink }) else {
                errorMessage = "V2S could not securely save the verified Premium server. Try Restore Purchases again."
                return
            }
            return await connectVerifiedPremiumProfile(saved)
        }
        await connectWithoutPremiumVerification(profile)
    }

    func toggleConnection(profile: V2SProfile) async {
        let controller = MacVPNController.shared
        if controller.status == .connected, controller.connectedProfileID == profile.id {
            select(profile)
            disconnect()
            return
        }
        guard controller.status != .connecting,
              controller.status != .reasserting,
              controller.status != .disconnecting else {
            statusMessage = "Wait for the current VPN connection change to finish."
            return
        }
        select(profile)
        await connect(profile: profile)
    }

    private func connectVerifiedPremiumProfile(_ profile: V2SProfile) async {
        await connectWithoutPremiumVerification(profile)
    }

    private func connectWithoutPremiumVerification(_ profile: V2SProfile) async {
        guard V2SPrivacyConsent.shared.accepted else { return }
        if let issue = V2SStore.loadSettings().validationIssue {
            errorMessage = issue
            return
        }
        selectedProfileID = profile.id
        statusMessage = "Connecting to the selected server…"
        do {
            V2SActivityLog.shared.record("Connection requested.")
            try await MacVPNController.shared.connect(profile: profile)
            statusMessage = "Connected to the selected server."
        }
        catch {
            guard V2SPrivacyConsent.shared.accepted else { return }
            statusMessage = "V2S could not establish the tunnel."
            errorMessage = error.localizedDescription
            V2SActivityLog.shared.record("VPN tunnel failed to connect.", level: .error)
        }
    }

    func disconnect() {
        statusMessage = "Disconnecting from V2S…"
        MacVPNController.shared.disconnect()
    }

    func test(_ profile: V2SProfile) {
        guard V2SPrivacyConsent.shared.accepted else { return }
        guard !isPingingAll, !isDiscoveringCommunity, !pinging.contains(profile.id), MacVPNController.shared.canTestServers else { return }
        pinging.insert(profile.id)
        let privacyTicket = V2SPrivacyConsent.shared.ticket
        Task {
            let result = await Self.proxyLatency(for: [profile])
            guard V2SPrivacyConsent.shared.permits(privacyTicket) else {
                pinging.remove(profile.id)
                return
            }
            updateLatency(profile.id, result[profile.id])
            pinging.remove(profile.id)
        }
    }

    func testAll() {
        guard V2SPrivacyConsent.shared.accepted else { return }
        guard !isPingingAll, !data.profiles.isEmpty, MacVPNController.shared.canTestServers else { return }
        var seen = Set<String>()
        let uniqueProfiles = data.profiles.filter { seen.insert($0.shareLink).inserted }
        let wasCapped = uniqueProfiles.count > 300
        let profiles = Array(uniqueProfiles.prefix(300))
        isPingingAll = true
        pinging = Set(profiles.map(\.id))
        pingTask = Task {
            var complete = 0
            for start in stride(from: 0, to: profiles.count, by: 5) {
                guard !Task.isCancelled, V2SPrivacyConsent.shared.accepted else { break }
                let batch = Array(profiles[start..<min(start + 5, profiles.count)])
                let results = await Self.proxyLatency(for: batch)
                for profile in batch {
                    updateLatency(profile.id, results[profile.id])
                    pinging.remove(profile.id)
                    complete += 1
                }
                statusMessage = "Checked \(complete) of \(profiles.count) unique proxy servers."
            }
            if Task.isCancelled {
                statusMessage = "Proxy checks cancelled after \(complete) of \(profiles.count) unique servers."
            } else if wasCapped {
                statusMessage += " Limited to 300 in this run."
            }
            pinging.removeAll()
            isPingingAll = false
            pingTask = nil
        }
    }

    func test(_ profiles: [V2SProfile]) {
        guard V2SPrivacyConsent.shared.accepted else { return }
        guard !isPingingAll, !isDiscoveringCommunity, MacVPNController.shared.canTestServers else { return }
        var seen = Set<String>()
        let uniqueProfiles = profiles.filter { seen.insert($0.shareLink).inserted }
        guard !uniqueProfiles.isEmpty else { return }
        let wasCapped = uniqueProfiles.count > 300
        let unique = Array(uniqueProfiles.prefix(300))
        isPingingAll = true
        pinging = Set(unique.map(\.id))
        pingTask = Task {
            var complete = 0
            for start in stride(from: 0, to: unique.count, by: 5) {
                guard !Task.isCancelled, V2SPrivacyConsent.shared.accepted else { break }
                let batch = Array(unique[start..<min(start + 5, unique.count)])
                let results = await Self.proxyLatency(for: batch)
                for profile in batch {
                    updateLatency(profile.id, results[profile.id])
                    pinging.remove(profile.id)
                    complete += 1
                }
                statusMessage = "Checked \(complete) of \(unique.count) proxy servers."
            }
            if Task.isCancelled { statusMessage = "Proxy checks cancelled after \(complete) of \(unique.count)." }
            else if wasCapped { statusMessage += " Limited to 300 in this run." }
            pinging.removeAll()
            isPingingAll = false
            pingTask = nil
        }
    }

    func cancelPingAll() { pingTask?.cancel() }

    private func updateLatency(_ id: UUID, _ delay: Int?) {
        guard V2SPrivacyConsent.shared.accepted else { return }
        guard let target = data.profiles.first(where: { $0.id == id }) else { return }
        if target.isCommunity == true, delay == nil {
            var updated = data
            updated.profiles.removeAll { $0.shareLink == target.shareLink && $0.isCommunity == true }
            if selectedProfileID == id {
                selectedProfileID = updated.profiles.first(where: { $0.isCommunity != true })?.id
                    ?? updated.profiles.first(where: { $0.isCommunity == true })?.id
            }
            try? V2SStore.saveData(updated)
            data = updated
            return
        }
        for index in data.profiles.indices where data.profiles[index].shareLink == target.shareLink {
            data.profiles[index].latencyMilliseconds = delay
        }
        try? V2SStore.saveData(data)
    }

    private static func proxyLatency(for profiles: [V2SProfile]) async -> [UUID: Int] {
        let privacyTicket = V2SPrivacyConsent.shared.ticket
        guard V2SPrivacyConsent.shared.permits(privacyTicket), !profiles.isEmpty else { return [:] }
        let prepared: [(profile: V2SProfile, config: [String: String])] = profiles.compactMap { profile in
            guard var config = try? V2SXray.configuration(from: profile.shareLink),
                  var outbounds = config["outbounds"] as? [[String: Any]], !outbounds.isEmpty
            else { return nil }
            for index in outbounds.indices {
                var outbound = outbounds[index]
                outbound.removeValue(forKey: "sendThrough")
                if index == 0 {
                    var stream = outbound["streamSettings"] as? [String: Any] ?? [:]
                    if (stream["security"] as? String ?? "").lowercased() == "reality" {
                        var reality = stream["realitySettings"] as? [String: Any] ?? [:]
                        for key in ["target", "dest", "serverNames", "privateKey", "minClientVer", "maxClientVer", "maxTimeDiff", "xver"] {
                            reality.removeValue(forKey: key)
                        }
                        if (reality["serverName"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            reality["serverName"] = profile.server
                        }
                        stream["realitySettings"] = reality
                        outbound["streamSettings"] = stream
                    }
                }
                outbounds[index] = outbound
            }
            config["outbounds"] = outbounds
            guard let bytes = try? JSONSerialization.data(withJSONObject: config) else { return nil }
            return (profile, ["xrayJson": String(decoding: bytes, as: UTF8.self)])
        }
        guard !prepared.isEmpty else { return [:] }
        return await Task.detached(priority: .utility) {
            let urls = [
                "https://www.cloudflare.com/cdn-cgi/trace",
                "https://www.gstatic.com/generate_204"
            ]
            var delays: [UUID: Int] = [:]
            for url in urls {
                guard await MainActor.run(body: { V2SPrivacyConsent.shared.permits(privacyTicket) }) else { break }
                let pending = prepared.filter { delays[$0.profile.id] == nil }
                guard !pending.isEmpty else { break }
                do {
                    let result = try V2SXray.call("pingBatch", payload: [
                        "configs": pending.map(\.config),
                        "timeout": 2,
                        "url": url
                    ])
                    let object: [String: Any]
                    if let string = result as? String, let bytes = string.data(using: .utf8) {
                        object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] ?? [:]
                    } else { object = result as? [String: Any] ?? [:] }
                    let rows = object["results"] as? [[String: Any]] ?? []
                    for (index, item) in pending.enumerated() {
                        if index < rows.count, rows[index]["success"] as? Bool == true,
                           let delay = rows[index]["delay"] as? Int, (0..<10_000).contains(delay) {
                            delays[item.profile.id] = delay
                        }
                    }
                } catch {
                    // A blocked test URL should not invalidate a proxy that may
                    // succeed against the alternate independent test endpoint.
                }
            }
            return delays
        }.value
    }

}

@MainActor
final class V2SActivityLog: ObservableObject {
    enum Level { case info, warning, error }

    struct Entry: Identifiable {
        let id = UUID()
        let time: Date
        let level: Level
        let message: String
        var display: String { "\(time.formatted(date: .omitted, time: .standard))  \(level.label)  \(message)" }
    }

    static let shared = V2SActivityLog()
    @Published private(set) var entries: [Entry] = []

    private init() {}

    func record(_ message: String, level: Level = .info) {
        let safe = message
            .replacingOccurrences(of: #"(?i)(vless|vmess|trojan|ss)://\S+"#, with: "<redacted proxy link>", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)https?://\S+"#, with: "<redacted URL>", options: .regularExpression)
        entries.insert(Entry(time: Date(), level: level, message: String(safe.prefix(500))), at: 0)
        if entries.count > 200 { entries.removeLast(entries.count - 200) }
    }

    func clear() { entries.removeAll() }
}

private extension V2SActivityLog.Level {
    var label: String {
        switch self {
        case .info: "INFO"
        case .warning: "WARN"
        case .error: "ERROR"
        }
    }
}
