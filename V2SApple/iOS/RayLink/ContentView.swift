import SwiftUI
import NetworkExtension
import Combine
import UIKit

struct ContentView: View {

    @StateObject private var settingsStore = SettingsStore()
    @ObservedObject private var vpn = VPNManager.shared
    @AppStorage("v2s.interfaceLanguage") private var interfaceLanguage = "system"
    @State private var selectedTab = 0
    @State private var deepLinkImport: String?

    var body: some View {
        TabView(selection: $selectedTab) {
            ConnectView(deepLinkImport: $deepLinkImport)
                .tabItem {
                    Label(AppStrings.value("Connect"), systemImage: "point.3.connected.trianglepath.dotted")
                }
                .tag(0)

            V2SPremiumPlansView()
            .id(interfaceLanguage)
            .tabItem {
                Label(AppStrings.value("Premium"), systemImage: "crown.fill")
            }
            .tag(1)

            SettingsRootView(store: settingsStore)
                .id(interfaceLanguage)
                .tabItem {
                    Label(AppStrings.value("Settings"), systemImage: "gearshape")
                }
                .tag(2)
        }
        .tint(.blue)
        .onOpenURL(perform: handleURL)
    }

    private func handleURL(_ url: URL) {
        guard url.scheme?.lowercased() == "v2s" else { return }

        switch url.host?.lowercased() {
        case "connect":
            selectedTab = 0
            Task {
                do {
                    try await vpn.connect()
                    SafeLogStore.append("Connection requested from URL command")
                } catch {
                    SafeLogStore.append("URL connection command failed")
                }
            }

        case "disconnect":
            selectedTab = 0
            vpn.disconnect()
            SafeLogStore.append("Disconnect requested from URL command")

        case "import", "subscription":
            let encodedValue = String(url.path.drop(while: { $0 == "/" }))
            guard !encodedValue.isEmpty,
                  let value = encodedValue.removingPercentEncoding,
                  !value.isEmpty
            else {
                return
            }

            // The configuration is shown in the normal import flow and is not
            // stored until the user explicitly taps Import Servers.
            deepLinkImport = value
            selectedTab = 0

        default:
            break
        }
    }
}

private struct ConnectView: View {
    @AppStorage("v2s.interfaceLanguage") private var interfaceLanguage = "system"

    @ObservedObject private var vpn = VPNManager.shared
    @ObservedObject private var latencyTester = ServerLatencyTester.shared
    @ObservedObject private var premium = V2SSubscriptions.shared
    @Binding var deepLinkImport: String?
    @Environment(\.scenePhase) private var scenePhase
    @State private var freeProfiles: [ProxyProfile] = []
    @State private var scanningFree = false
    @State private var freeScanMessage = "Scan for up to 10 worker-checked VLESS and Trojan servers."
    @State private var freeScanCount: Int?
    @State private var lastFreeScan: Date?
    @State private var freeScanEnabled = false
    @State private var freeServersHidden = false
    @State private var premiumServersHidden = false

    @AppStorage("v2tah.hasAcknowledgedPrivacy")
    private var hasAcknowledgedPrivacy = false

    @State private var profiles: [ProxyProfile] = []
    @State private var subscriptionSources: [SubscriptionSource] = []
    @State private var selectedProfile: ProxyProfile?
    @State private var collapsedGroupIDs = Set<String>()
    @State private var refreshingSubscriptionIDs = Set<UUID>()
    @State private var isRefreshingAllSubscriptions = false
    @State private var showingImport = false
    @State private var showingServers = false
    @State private var showingPrivacy = false
    @State private var showingPlans = false
    @State private var detailProfile: ProxyProfile?
    @State private var errorMessage: String?
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    connectionHeader
                    freeAccessCard
                    quickActions
                    serverGroups
                    privacyFooter
                }
                .padding()
            }
            .background(
                LinearGradient(
                    colors: [
                        Color.indigo.opacity(0.08),
                        Color.cyan.opacity(0.04),
                        Color(uiColor: .systemGroupedBackground)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
            )
            .navigationTitle(AppStrings.value("V2S"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingServers = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .disabled(profiles.isEmpty)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showingImport = true
                        } label: {
                            Label(AppStrings.value("Enter Link"), systemImage: "keyboard")
                        }

                        Button {
                            importFromClipboard()
                        } label: {
                            Label(AppStrings.value("Paste from Clipboard"), systemImage: "doc.on.clipboard")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(isConnected)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showingServers = true
                        } label: {
                            Label(AppStrings.value("Saved Servers"), systemImage: "list.bullet")
                        }
                        .disabled(profiles.isEmpty)

                        Button {
                            latencyTester.testAll(profiles)
                        } label: {
                            Label(AppStrings.value("Ping All Servers"), systemImage: "waveform.path.ecg")
                        }
                        .disabled(profiles.isEmpty || isPingingAnyServer)

                        Button {
                            Task { await refreshAllSubscriptions() }
                        } label: {
                            Label(AppStrings.value("Update All Subscriptions"), systemImage: "arrow.clockwise")
                        }
                        .disabled(
                            subscriptionSources.isEmpty
                                || isConnected
                                || isRefreshingAllSubscriptions
                        )

                        Button {
                            showingPrivacy = true
                        } label: {
                            Label(AppStrings.value("Privacy & Data"), systemImage: "hand.raised")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showingImport) {
                ImportProfileView(
                    initialConfiguration: deepLinkImport ?? ""
                ) {
                    loadSavedProfiles()
                }
            }
            .onChange(of: deepLinkImport) { _, value in
                if value != nil {
                    showingImport = true
                }
            }
            .onChange(of: showingImport) { _, isShowing in
                if !isShowing {
                    deepLinkImport = nil
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .v2tehProfilesDidChange)
            ) { _ in
                loadSavedProfiles()
            }
            .sheet(isPresented: $showingServers) {
                ServerListView(
                    profiles: profiles,
                    selectedProfileID: selectedProfile?.id,
                    isConnectionActive: isConnected,
                    onSelect: selectProfile,
                    onConnect: connectToProfile,
                    onDelete: deleteProfiles
                )
            }
            .sheet(isPresented: $showingPrivacy) {
                PrivacyDisclosureView(
                    requiresAcknowledgement: !hasAcknowledgedPrivacy,
                    onContinue: {
                        hasAcknowledgedPrivacy = true
                        Task { await premium.prepare() }
                    }
                )
            }
            .sheet(isPresented: $showingPlans) {
                V2SPremiumPlansView()
            }
            .onChange(of: premium.profiles) { oldProfiles, newProfiles in
                premiumProfilesChanged(oldProfiles, newProfiles)
            }
            .sheet(item: $detailProfile) { profile in
                NavigationStack {
                    ScrollView {
                        selectedServerDetails(profile)
                            .padding()
                    }
                    .navigationTitle(AppStrings.value("Server Details"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(AppStrings.value("Done")) { detailProfile = nil }
                        }
                    }
                }
            }
            .task {
                loadSavedProfiles()
                await premium.prepare()

                if !hasAcknowledgedPrivacy {
                    showingPrivacy = true
                }

                #if !targetEnvironment(simulator)
                do {
                    try await vpn.prepare()
                } catch {
                    errorMessage = error.localizedDescription
                }
                #endif
            }
            .alert(AppStrings.value("V2S"), isPresented: errorBinding) {
                Button(AppStrings.value("OK")) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }
}

private extension ConnectView {

    var connectionHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if let selectedProfile {
                    Text(selectedProfile.name)
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                } else {
                    Text(AppStrings.value("Choose a server"))
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                connectionTimer
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button {
                Task { await toggleConnection() }
            } label: {
                HStack(spacing: 6) {
                    if isWorking || vpn.status == .connecting || vpn.status == .disconnecting {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: isConnected ? "stop.fill" : "power")
                    }
                    Text(AppStrings.value(isConnected ? "Disconnect" : "Connect"))
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(connectionColor)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .accessibilityHint(AppStrings.value(statusText))
            .disabled((selectedProfile == nil && !isConnected) || isWorking ||
                      vpn.status == .connecting || vpn.status == .disconnecting)
        }
        .padding(12)
        .background(connectionColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(connectionColor.opacity(0.18), lineWidth: 1)
        }
    }

    @ViewBuilder
    var connectionTimer: some View {
        if let connectedDate = vpn.connectedDate, vpn.status == .connected {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(durationText(from: connectedDate, to: context.date))
                    .font(.system(.caption, design: .monospaced).weight(.medium))
            }
        } else {
            Text(AppStrings.value("00:00:00"))
                .font(.system(.caption, design: .monospaced).weight(.medium))
        }
    }

    var freeAccessCard: some View {
        Label(AppStrings.value("Use your servers free, or choose Premium"), systemImage: "infinity.circle.fill")
            .font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    var quickActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                quickActionButton(
                    title: "Paste",
                    icon: "doc.on.clipboard",
                    color: .blue,
                    isDisabled: isConnected,
                    action: importFromClipboard
                )

                quickActionButton(
                    title: isPingingAnyServer ? "Pinging" : "Ping All",
                    icon: "waveform.path.ecg",
                    color: .green,
                    isDisabled: profiles.isEmpty || isPingingAnyServer
                ) {
                    latencyTester.testAll(profiles)
                }

                quickActionButton(
                    title: isRefreshingAllSubscriptions ? "Updating" : "Update",
                    icon: "arrow.clockwise",
                    color: .indigo,
                    isDisabled: subscriptionSources.isEmpty
                        || isConnected
                        || isRefreshingAllSubscriptions
                ) {
                    Task { await refreshAllSubscriptions() }
                }

                quickActionButton(
                    title: "Servers",
                    icon: "list.bullet",
                    color: .orange,
                    isDisabled: profiles.isEmpty
                ) {
                    showingServers = true
                }
            }
        }
        .padding(8)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.blue.opacity(0.10), lineWidth: 1)
        }
    }

    func quickActionButton(
        title: String,
        icon: String,
        color: Color,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.headline)
                    .frame(height: 20)
                Text(AppStrings.value(title))
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isDisabled ? Color.secondary : color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(color.opacity(isDisabled ? 0.03 : 0.08))
            .clipShape(RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }

    @ViewBuilder
    var serverGroups: some View {
        HStack {
            Text(AppStrings.value("SERVER SOURCES"))
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 4)

        if profiles.isEmpty && subscriptionSources.isEmpty {
            VStack(spacing: 16) {
                HStack {
                    Text(AppStrings.value("Added servers"))
                        .font(.title3.bold())
                    Spacer()
                    Button {
                        showingImport = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                    }
                    .disabled(isConnected)
                    .accessibilityLabel(AppStrings.value("Add servers"))
                }

                Divider()
                emptyServerView
            }
            .padding()
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .overlay {
                RoundedRectangle(cornerRadius: 24)
                    .stroke(Color.indigo.opacity(0.14), lineWidth: 1)
            }
        } else {
            let standaloneProfiles = profiles.filter { $0.sourceID == nil }

            if !standaloneProfiles.isEmpty {
                serverGroupCard(
                    title: "Added servers",
                    groupID: "configurations",
                    profiles: standaloneProfiles,
                    subscription: nil
                )
            }

            ForEach(subscriptionSources) { source in
                serverGroupCard(
                    title: source.name,
                    groupID: source.id.uuidString,
                    profiles: profiles.filter { $0.sourceID == source.id },
                    subscription: source
                )
            }

            let knownSourceIDs = Set(subscriptionSources.map(\.id))
            let recoveredProfiles = profiles.filter { profile in
                guard let sourceID = profile.sourceID else { return false }
                return !knownSourceIDs.contains(sourceID)
            }

            if !recoveredProfiles.isEmpty {
                serverGroupCard(
                    title: "Other Servers",
                    groupID: "recovered",
                    profiles: recoveredProfiles,
                    subscription: nil
                )
            }
        }

        freeServerCard

        premiumServerCard
    }

    var premiumServerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(AppStrings.value("Premium servers"), systemImage: "crown.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Spacer()
                Button {
                    showingPlans = true
                } label: {
                    Text(AppStrings.value(premium.profiles.isEmpty ? "View plans" : "Manage"))
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
            if premium.profiles.isEmpty {
                Text(AppStrings.value("Monthly and yearly plans unlock V2S-operated locations."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Button(AppStrings.value("Ping All")) { latencyTester.testAll(premium.profiles) }
                        .disabled(premium.profiles.contains { latencyTester.testingIDs.contains($0.id) })
                    Spacer()
                    Button {
                        withAnimation(.snappy) { premiumServersHidden.toggle() }
                    } label: {
                        Text(AppStrings.value(premiumServersHidden ? "Show" : "Hide"))
                    }
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(.orange)
                if !premiumServersHidden {
                    ForEach(premium.profiles) { profile in
                        groupedServerRow(profile, accent: .orange, isManaged: true)
                    }
                }
            }
        }
        .padding()
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    var freeServerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {

                    guard hasAcknowledgedPrivacy else {
                        showingPrivacy = true
                        return
                    }
                    freeScanEnabled = true
                    Task { await scanFreeServers() }
                } label: {
                    Label {
                        Text(AppStrings.value(scanningFree ? "Scanning…" : "Scan for free servers"))
                    } icon: {
                        Image(systemName: "globe")
                    }
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.borderedProminent).tint(.green)
                .disabled(scanningFree)
            }
            Group {
                if let freeScanCount {
                    Text(AppStrings.format("%d servers available · Select to connect", [freeScanCount]))
                } else {
                    Text(AppStrings.value(freeScanMessage))
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup(AppStrings.value("Scan information")) {
                Text(AppStrings.value("Independent public servers. Scanning contacts the V2S catalog; Ping checks endpoint reachability, not a complete VPN connection."))
            }.font(.caption).foregroundStyle(.secondary)
            if !freeProfiles.isEmpty {
                HStack {
                    Button(AppStrings.value("Ping All")) { latencyTester.testAll(freeProfiles) }
                        .disabled(freeProfiles.contains { latencyTester.testingIDs.contains($0.id) })
                    Spacer()
                    Button {
                        withAnimation(.snappy) { freeServersHidden.toggle() }
                    } label: {
                        Text(AppStrings.value(freeServersHidden ? "Show" : "Hide"))
                    }
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(.green)
                if !freeServersHidden {
                    ForEach(freeProfiles) { profile in
                        groupedServerRow(profile, accent: .green, isManaged: true)
                    }
                }
            }
            Toggle(AppStrings.value("Refresh every 30 minutes while this screen is active"), isOn: $freeScanEnabled)
                .font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .task(id: freeScanEnabled) {
            guard freeScanEnabled else { return }
            while !Task.isCancelled {
                if scenePhase == .active,
                   lastFreeScan.map({ Date().timeIntervalSince($0) >= 1800 }) ?? true {
                    await scanFreeServers()
                }
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
    }

    @MainActor
    func scanFreeServers() async {
        guard !scanningFree, hasAcknowledgedPrivacy, scenePhase == .active else { return }
        scanningFree = true
        lastFreeScan = Date()
        freeScanCount = nil
        freeScanMessage = "Retrieving worker-checked servers…"
        defer { scanningFree = false }
        do {
            let found = try await IOSFreeCatalog.download()
            try Task.checkCancellation()
            guard hasAcknowledgedPrivacy else { return }
            freeProfiles = found.map { item in
                var item = item
                if let previous = freeProfiles.first(where: { $0.rawLink == item.rawLink }) {
                    item.id = previous.id
                }
                return item
            }
            freeScanCount = found.isEmpty ? nil : found.count
            freeScanMessage = found.isEmpty
                ? "No checked servers are available right now. Try again later."
                : ""
        } catch is CancellationError {
            freeScanMessage = "Scan cancelled."
        } catch {
            freeScanMessage = "The free-server catalog could not be refreshed. Try again."
        }
    }

    func serverGroupCard(
        title: String,
        groupID: String,
        profiles groupProfiles: [ProxyProfile],
        subscription: SubscriptionSource?
    ) -> some View {
        let isExpanded = !collapsedGroupIDs.contains(groupID)
        let isRefreshing = subscription.map {
            refreshingSubscriptionIDs.contains($0.id)
        } ?? false
        let isPinging = groupProfiles.contains {
            latencyTester.testingIDs.contains($0.id)
        }
        let accent = groupAccentColor(
            for: groupID,
            isSubscription: subscription != nil
        )

        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9)
                            .fill(accent.opacity(0.14))
                            .frame(width: 32, height: 32)
                        Image(
                            systemName: subscription == nil
                                ? "square.stack.3d.up.fill"
                                : "antenna.radiowaves.left.and.right"
                        )
                        .foregroundStyle(accent)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(AppStrings.value(title))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)

                        Text(AppStrings.format(
                            groupProfiles.count == 1 ? "%d node in this deck" : "%d nodes in this deck",
                            [groupProfiles.count]
                        ))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 4)

                    if selectedProfile.map({ groupProfiles.contains($0) }) == true {
                        Text(AppStrings.value("SELECTED"))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(accent.opacity(0.10))
                            .clipShape(Capsule())
                    }
                }

                HStack(spacing: 5) {
                    if let subscription {
                        Button {
                            Task { await refreshSubscription(subscription) }
                        } label: {
                            if isRefreshing {
                                Label(AppStrings.value("Updating"), systemImage: "arrow.clockwise")
                            } else {
                                Label(AppStrings.value("Update"), systemImage: "arrow.clockwise")
                            }
                        }
                        .disabled(isRefreshing || isConnected)
                    }

                    Button {
                        latencyTester.testAll(groupProfiles)
                    } label: {
                        if isPinging {
                            Label(AppStrings.value("Testing"), systemImage: "waveform.path.ecg")
                        } else {
                            Label(AppStrings.value("Ping All"), systemImage: "waveform.path.ecg")
                        }
                    }
                    .disabled(groupProfiles.isEmpty || isPinging)

                    Spacer()

                    Button {
                        withAnimation(.snappy) {
                            if isExpanded {
                                collapsedGroupIDs.insert(groupID)
                            } else {
                                collapsedGroupIDs.remove(groupID)
                            }
                        }
                    } label: {
                        Label(
                            AppStrings.value(isExpanded ? "Hide" : "Show"),
                            systemImage: isExpanded ? "chevron.up" : "chevron.down"
                        )
                    }
                    .accessibilityLabel(AppStrings.format(
                        isExpanded ? "Collapse %@" : "Expand %@",
                        [AppStrings.value(title)]
                    ))
                }
                .font(.caption2.weight(.semibold))
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(accent)
            }
            .padding(10)

            if let usage = subscription?.usage {
                subscriptionUsageView(usage, accent: accent)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }

            if isExpanded {
                Divider()

                if groupProfiles.isEmpty {
                    Text(AppStrings.value("No supported servers were returned by this subscription."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding()
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(groupProfiles.enumerated()), id: \.element.id) { index, profile in
                            groupedServerRow(profile, accent: accent)

                            if index < groupProfiles.count - 1 {
                                Divider()
                                    .padding(.leading, 16)
                            }
                        }
                    }
                }
            }
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(accent)
                .frame(width: 5)
                .padding(.vertical, 14)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .stroke(accent.opacity(0.16), lineWidth: 1)
        }
    }

    func groupedServerRow(
        _ profile: ProxyProfile,
        accent: Color,
        isManaged: Bool = false
    ) -> some View {
        let isSelected = profile.id == selectedProfile?.id

        return HStack(spacing: 6) {
            HStack(spacing: 7) {
                    ZStack {
                        Circle()
                            .fill(isSelected ? accent : accent.opacity(0.10))
                            .frame(width: 27, height: 27)
                        Image(systemName: isSelected ? "checkmark" : "point.3.connected.trianglepath.dotted")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(isSelected ? .white : accent)
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        Text(profile.name)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text("\(profile.protocolType.rawValue.uppercased()) / \(profile.transport.rawValue.uppercased())")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
            .gesture(
                LongPressGesture(minimumDuration: 0.5)
                    .exclusively(before: TapGesture())
                    .onEnded { result in
                        guard !isWorking else { return }
                        switch result {
                        case .first(true):
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.5)
                            Task { await connectToProfile(profile) }
                        case .second:
                            selectProfile(profile)
                        default:
                            break
                        }
                    }
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: AppStrings.format("Connect to %@", [profile.name])) {
                Task { await connectToProfile(profile) }
            }

            Button {
                latencyTester.test(profile)
            } label: {
                ServerLatencyBadge(
                    result: latencyTester.results[profile.id],
                    isTesting: latencyTester.testingIDs.contains(profile.id),
                    showsPingPrompt: true
                )
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(AppStrings.format("Test %@ latency", [profile.name]))

            Menu {
                if !isSelected {
                    Button {
                        selectProfile(profile)
                    } label: {
                        Label(AppStrings.value("Make Active"), systemImage: "checkmark.circle")
                    }
                }

                Button {
                    latencyTester.test(profile)
                } label: {
                    Label(AppStrings.value("Ping Server"), systemImage: "waveform.path.ecg")
                }

                if let sourceID = profile.sourceID,
                   let source = subscriptionSources.first(where: { $0.id == sourceID }) {
                    Button {
                        Task { await refreshSubscription(source) }
                    } label: {
                        Label(AppStrings.value("Update Subscription"), systemImage: "arrow.clockwise")
                    }
                    .disabled(isConnected || refreshingSubscriptionIDs.contains(source.id))
                }

                Button {
                    detailProfile = profile
                } label: {
                    Label(AppStrings.value("Server Details"), systemImage: "info.circle")
                }

                Button {
                    copyServerAddress(profile)
                } label: {
                    Label(AppStrings.value("Copy Server Address"), systemImage: "doc.on.doc")
                }

                if !isManaged {
                    Divider()
                    Button(role: .destructive) {
                        deleteProfile(profile)
                    } label: {
                        Label(AppStrings.value("Delete Server"), systemImage: "trash")
                    }
                    .disabled(isConnected && isSelected)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 30)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(AppStrings.format("Options for %@", [profile.name]))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(isSelected ? accent.opacity(0.09) : Color.clear)
    }

    func subscriptionUsageView(
        _ usage: SubscriptionUsage,
        accent: Color
    ) -> some View {
        VStack(spacing: 9) {
            HStack {
                Label(AppStrings.value("Provider allowance"), systemImage: "gauge.with.dots.needle.33percent")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                if let totalBytes = usage.totalBytes {
                    Text("\(formattedBytes(usage.usedBytes)) / \(formattedBytes(totalBytes))")
                        .font(.caption.weight(.semibold))
                } else {
                    Text(AppStrings.format("%@ used", [formattedBytes(usage.usedBytes)]))
                        .font(.caption.weight(.semibold))
                }
            }

            if let fraction = usage.fractionUsed {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(accent.opacity(0.12))
                        Capsule()
                            .fill(accent)
                            .frame(width: proxy.size.width * fraction)
                    }
                }
                .frame(height: 9)
            }

            if let expiryDate = usage.expiryDate {
                HStack {
                    Spacer()
                    Text("Expires \(expiryDate.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption2)
                        .foregroundStyle(expiryDate < Date() ? .red : .secondary)
                }
            }
        }
        .padding(12)
        .background(accent.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    func groupAccentColor(
        for groupID: String,
        isSubscription: Bool
    ) -> Color {
        if groupID == "configurations" { return .teal }
        if groupID == "recovered" { return .orange }
        guard isSubscription else { return .blue }

        let colorIndex = groupID.unicodeScalars.reduce(0) {
            $0 + Int($1.value)
        } % 3

        switch colorIndex {
        case 0: return .indigo
        case 1: return .purple
        default: return .blue
        }
    }

    func selectedServerDetails(_ profile: ProxyProfile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.name)
                        .font(.title3.bold())
                        .lineLimit(2)

                    Text("\(profile.server):\(profile.port)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    protocolBadge(profile.protocolType)

                    Button {
                        latencyTester.test(profile)
                    } label: {
                        ServerLatencyBadge(
                            result: latencyTester.results[profile.id],
                            isTesting: latencyTester.testingIDs.contains(profile.id),
                            showsPingPrompt: true
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel(AppStrings.format("Test %@ latency", [profile.name]))
                }
            }

            Divider()
            profileDetail(
                title: "Protocol",
                value: profile.protocolType.rawValue.uppercased()
            )
            profileDetail(
                title: "Transport",
                value: profile.transport.rawValue.uppercased()
            )

            if let security = profile.security, !security.isEmpty {
                profileDetail(title: "Security", value: security.uppercased())
            }

            if let serverName = profile.serverName, !serverName.isEmpty {
                profileDetail(title: "SNI", value: serverName)
            }

            if profile.security?.lowercased() == "reality" {
                profileDetail(title: "REALITY", value: "Enabled")
            }

            if let sourceName = profile.sourceName {
                profileDetail(title: "Subscription", value: sourceName)
            }
        }
    }

    var emptyServerView: some View {
        VStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.system(size: 38))
                .foregroundStyle(.secondary)

            Text(AppStrings.value("No Servers Added"))
                .font(.headline)

            Text(AppStrings.value("Import a server link or HTTPS subscription to begin."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button(AppStrings.value("Add Servers")) {
                showingImport = true
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 15)
    }

    var privacyFooter: some View {
        VStack(spacing: 5) {
            Label(AppStrings.value("Imported configurations stay on this device"),
                systemImage: "lock.shield"
            )
            Text(AppStrings.value("V2S Premium server access requires an active subscription."))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.top, 4)
    }
}

private extension ConnectView {

    var isConnected: Bool {
        switch vpn.status {
        case .connected, .connecting, .reasserting:
            return true
        default:
            return false
        }
    }

    var isPingingAnyServer: Bool {
        !latencyTester.testingIDs.isDisjoint(with: Set(profiles.map(\.id)))
    }

    var statusText: String {
        switch vpn.status {
        case .invalid: return "Not Configured"
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .reasserting: return "Reconnecting…"
        case .disconnecting: return "Disconnecting…"
        @unknown default: return "Unknown"
        }
    }

    var connectionIcon: String {
        switch vpn.status {
        case .connected:
            return "checkmark.shield.fill"
        case .connecting, .reasserting:
            return "arrow.triangle.2.circlepath"
        default:
            return "shield"
        }
    }

    func durationText(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return String(
            format: "%02d:%02d:%02d",
            seconds / 3600,
            (seconds % 3600) / 60,
            seconds % 60
        )
    }

    var connectionColor: Color {
        switch vpn.status {
        case .connected:
            return .green
        case .connecting, .reasserting:
            return .orange
        default:
            return .blue
        }
    }

    var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    func protocolBadge(_ type: ProxyProtocol) -> some View {
        Text(type.rawValue.uppercased())
            .font(.caption.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.thinMaterial)
            .clipShape(Capsule())
    }

    func profileDetail(title: String, value: String) -> some View {
        HStack {
            Text(AppStrings.value(title)).foregroundStyle(.secondary)
            Spacer()
            Text(AppStrings.value(value))
                .fontWeight(.medium)
                .lineLimit(1)
        }
        .font(.subheadline)
    }

    func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(
            fromByteCount: max(0, bytes),
            countStyle: .binary
        )
    }

    func loadSavedProfiles() {
        do {
            subscriptionSources = SubscriptionStore.loadSources()
            profiles = try SharedConfiguration.loadProfiles()

            if let activeProfile = try? SharedConfiguration.loadProfile(),
               (profiles + premium.profiles + freeProfiles).contains(where: { $0.id == activeProfile.id }) {
                selectedProfile = activeProfile
            } else if let firstProfile = profiles.first {
                selectedProfile = firstProfile
                try SharedConfiguration.save(profile: firstProfile)
            } else {
                selectedProfile = nil
            }
        } catch {
            profiles = []
            selectedProfile = nil
            errorMessage = error.localizedDescription
        }
    }

    private func premiumProfilesChanged(_ old: [ProxyProfile], _ new: [ProxyProfile]) {
        if let selectedProfile, old.contains(where: { $0.id == selectedProfile.id }),
           !new.contains(where: { $0.id == selectedProfile.id }) {
            vpn.disconnect()
            SharedConfiguration.removeActiveProfile()
        }
        loadSavedProfiles()
    }

    @MainActor
    func refreshSubscription(_ source: SubscriptionSource) async {
        guard !refreshingSubscriptionIDs.contains(source.id) else { return }

        refreshingSubscriptionIDs.insert(source.id)
        defer { refreshingSubscriptionIDs.remove(source.id) }

        do {
            let refreshed = try await SubscriptionStore.refresh(source)
            loadSavedProfiles()
            SafeLogStore.append(
                "Subscription updated with \(refreshed.serverCount) supported servers"
            )
        } catch {
            SafeLogStore.append("Subscription update failed")
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    func refreshAllSubscriptions() async {
        guard !isRefreshingAllSubscriptions,
              !subscriptionSources.isEmpty,
              !isConnected
        else {
            return
        }

        isRefreshingAllSubscriptions = true
        let sources = subscriptionSources

        for source in sources {
            await refreshSubscription(source)
        }

        isRefreshingAllSubscriptions = false
    }

    func importFromClipboard() {
        guard !isConnected else {
            errorMessage = "Disconnect before importing servers."
            return
        }

        guard let clipboardText = UIPasteboard.general.string?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !clipboardText.isEmpty
        else {
            errorMessage = "The Clipboard does not contain a server or subscription link."
            return
        }

        deepLinkImport = clipboardText
        showingImport = true
    }

    func copyServerAddress(_ profile: ProxyProfile) {
        UIPasteboard.general.string = "\(profile.server):\(profile.port)"
        errorMessage = "The server address was copied to the Clipboard."
    }

    func selectProfile(_ profile: ProxyProfile) {
        guard !isWorking else { return }

        if vpn.status != .disconnected && vpn.status != .invalid {
            guard profile.id != selectedProfile?.id else { return }
            Task { await switchActiveProfile(to: profile) }
            return
        }

        do {
            try SharedConfiguration.save(profile: profile)
            selectedProfile = profile
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    func connectToProfile(_ profile: ProxyProfile) async {
        if profile.sourceName == "V2S Premium" {
            await premium.refresh()
            guard premium.isActive, premium.profiles.contains(where: { $0.id == profile.id }) else {
                errorMessage = AppStrings.value("V2S Premium server access requires an active subscription.")
                return
            }
        }
        guard !isWorking else { return }
        if isConnected && selectedProfile?.id == profile.id { return }
        if vpn.status != .disconnected && vpn.status != .invalid {
            await switchActiveProfile(to: profile)
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            try SharedConfiguration.save(profile: profile)
            selectedProfile = profile
            try await vpn.connect()
            SafeLogStore.append("Server connected after long press")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    func switchActiveProfile(to profile: ProxyProfile) async {
        isWorking = true
        defer { isWorking = false }

        vpn.disconnect()

        for _ in 0..<50 where vpn.status != .disconnected {
            try? await Task.sleep(for: .milliseconds(100))
        }

        guard vpn.status == .disconnected else {
            errorMessage = "V2S could not safely switch servers. Disconnect and try again."
            return
        }

        try? await Task.sleep(for: .milliseconds(500))

        do {
            try SharedConfiguration.save(profile: profile)
            selectedProfile = profile
            try await vpn.connect()
            SafeLogStore.append("Active server changed and tunnel reconnected")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteProfiles(at offsets: IndexSet) {
        let profilesToDelete = offsets.compactMap { index in
            profiles.indices.contains(index) ? profiles[index] : nil
        }

        if isConnected,
           profilesToDelete.contains(where: { $0.id == selectedProfile?.id }) {
            errorMessage = "Disconnect before deleting the active server."
            return
        }

        do {
            for profile in profilesToDelete {
                profiles = try SharedConfiguration.removeProfile(id: profile.id)
            }
            loadSavedProfiles()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteProfile(_ profile: ProxyProfile) {
        guard !(isConnected && profile.id == selectedProfile?.id) else {
            errorMessage = "Disconnect before deleting the active server."
            return
        }

        do {
            profiles = try SharedConfiguration.removeProfile(id: profile.id)
            loadSavedProfiles()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    func toggleConnection() async {
        isWorking = true
        defer { isWorking = false }

        do {
            if isConnected {
                vpn.disconnect()
                return
            }

            guard let selectedProfile else {
                errorMessage = "Add a server before connecting."
                return
            }

            try SharedConfiguration.save(profile: selectedProfile)
            try await vpn.connect()
            SafeLogStore.append("Connection requested")
        } catch {
            SafeLogStore.append("Connection failed")
            errorMessage = error.localizedDescription
        }
    }
}

private struct ServerListView: View {

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var latencyTester = ServerLatencyTester.shared

    let profiles: [ProxyProfile]
    let selectedProfileID: UUID?
    let isConnectionActive: Bool
    let onSelect: (ProxyProfile) -> Void
    let onConnect: (ProxyProfile) async -> Void
    let onDelete: (IndexSet) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(displayedProfiles) { profile in
                        HStack(spacing: 10) {
                            HStack(spacing: 12) {
                                    Image(systemName: "server.rack")
                                        .foregroundStyle(.blue)

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(profile.name)
                                            .fontWeight(.semibold)
                                            .foregroundStyle(.primary)
                                            .lineLimit(2)

                                        Text(
                                            "\(profile.protocolType.rawValue.uppercased())  •  "
                                            + "\(profile.server):\(profile.port)"
                                        )
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    }

                                    Spacer()

                                    if profile.id == selectedProfileID {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    }
                            }
                            .contentShape(Rectangle())
                            .gesture(
                                LongPressGesture(minimumDuration: 0.5)
                                    .exclusively(before: TapGesture())
                                    .onEnded { result in
                                        switch result {
                                        case .first(true):
                                            UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.5)
                                            dismiss()
                                            Task { await onConnect(profile) }
                                        case .second:
                                            onSelect(profile)
                                            dismiss()
                                        default:
                                            break
                                        }
                                    }
                            )
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction(named: AppStrings.format("Connect to %@", [profile.name])) {
                                dismiss()
                                Task { await onConnect(profile) }
                            }

                            Button {
                                latencyTester.test(profile)
                            } label: {
                                ServerLatencyBadge(
                                    result: latencyTester.results[profile.id],
                                    isTesting: latencyTester.testingIDs.contains(profile.id),
                                    showsPingPrompt: true
                                )
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(AppStrings.format("Test %@ latency", [profile.name]))
                        }
                    }
                    .onDelete { offsets in
                        let deletedIDs = Set(
                            offsets.compactMap { index in
                                displayedProfiles.indices.contains(index)
                                    ? displayedProfiles[index].id
                                    : nil
                            }
                        )
                        onDelete(
                            IndexSet(
                                profiles.indices.filter {
                                    deletedIDs.contains(profiles[$0].id)
                                }
                            )
                        )
                    }
                } footer: {
                    if isConnectionActive {
                        Text(AppStrings.value("Selecting another server disconnects the current tunnel and reconnects with the new server. Disconnect before deleting servers."))
                    } else {
                        Text(AppStrings.value("Tap a server to make it active. Ping measures TCP connection time; swipe left to delete."))
                    }
                }
            }
            .navigationTitle(AppStrings.value("Saved Servers"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search servers")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppStrings.value("Done")) { dismiss() }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        latencyTester.testAll(profiles)
                    } label: {
                        Label(AppStrings.value("Ping All"), systemImage: "waveform.path.ecg")
                    }
                    .disabled(profiles.isEmpty)
                }

                ToolbarItem(placement: .primaryAction) {
                    EditButton()
                        .disabled(isConnectionActive)
                }
            }
        }
    }

    @State private var searchText = ""

    private var displayedProfiles: [ProxyProfile] {
        guard !searchText.isEmpty else { return profiles }
        return profiles.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.protocolType.rawValue.localizedCaseInsensitiveContains(searchText)
        }
    }
}

struct ServerLatencyBadge: View {

    let result: ServerLatencyResult?
    let isTesting: Bool
    var showsPingPrompt = false

    var body: some View {
        Group {
            if isTesting {
                ProgressView()
                    .controlSize(.small)
            } else {
                switch result {
                case .reachable(let milliseconds):
                    Label("\(milliseconds) ms", systemImage: "bolt.horizontal.fill")
                        .foregroundStyle(color(for: milliseconds))
                case .unreachable:
                    Label(AppStrings.value("Timeout"), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                case nil:
                    if showsPingPrompt {
                        Label(AppStrings.value("Ping"), systemImage: "waveform.path.ecg")
                            .foregroundStyle(.blue)
                    } else {
                        Text(AppStrings.value("Not tested"))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .font(.caption.weight(.semibold))
        .lineLimit(1)
    }

    private func color(for milliseconds: Int) -> Color {
        switch milliseconds {
        case ..<150: return .green
        case 150..<350: return .orange
        default: return .red
        }
    }
}

private enum IOSFreeCatalog {
    static func download() async throws -> [ProxyProfile] {
        let endpoint = URL(string: "https://hostinger.v2teh.com/v2s/api/v1/community/servers?catalog=macos-1")!
        let session = URLSession(configuration: .ephemeral, delegate: IOSCatalogRedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("V2S/iOS", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url == endpoint, response.expectedContentLength <= 2_097_152 else {
            throw URLError(.badServerResponse)
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 2_097_152 else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["schema_version"] as? Int == 1,
              root["catalog"] as? String == "macos-1",
              let generated = root["generated_at"] as? Double,
              let expires = root["expires_at"] as? Double,
              generated <= Date().timeIntervalSince1970 + 180,
              expires > Date().timeIntervalSince1970,
              expires > generated, expires - generated <= 960,
              let entries = root["entries"] as? [[String: Any]], entries.count <= 10 else {
            throw URLError(.cannotParseResponse)
        }
        var seen = Set<String>()
        return entries.compactMap { entry in
            guard entry["origin"] as? String == "community",
                  entry["verification"] as? String == "https-proxy",
                  let link = entry["uri"] as? String, link.utf8.count <= 16384,
                  seen.insert(link).inserted,
                  let profile = try? ConfigurationParser.parseMany(link).first,
                  profile.protocolType == .vless || profile.protocolType == .trojan else { return nil }
            return profile
        }
    }
}

private final class IOSCatalogRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
