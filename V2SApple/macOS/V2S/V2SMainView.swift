import AppKit
import SwiftUI
import StoreKit

enum V2SPalette {
    // Opaque text colors preserve contrast on every dark app surface.
    static let text = Color(red: 0.96, green: 0.97, blue: 0.99)
    static let secondaryText = Color(red: 0.76, green: 0.80, blue: 0.86)
    static let mutedText = Color(red: 0.68, green: 0.73, blue: 0.80)
    static let success = Color(red: 0.38, green: 0.90, blue: 0.62)
    static let warning = Color(red: 1.0, green: 0.69, blue: 0.35)
    static let error = Color(red: 1.0, green: 0.52, blue: 0.55)
    static let selected = Color(red: 0.19, green: 0.17, blue: 0.36)
    static let background = Color(red: 0.035, green: 0.047, blue: 0.071)
    static let panel = Color(red: 0.075, green: 0.090, blue: 0.125)
    static let raised = Color(red: 0.105, green: 0.125, blue: 0.165)
    static let cyan = Color(red: 0.32, green: 0.82, blue: 0.95)
    static let purple = Color(red: 0.43, green: 0.35, blue: 0.98)
    static let gold = Color(red: 1.0, green: 0.73, blue: 0.30)
}

struct V2SMainView: View {
    @ObservedObject var model: V2SViewModel
    @ObservedObject private var vpn = MacVPNController.shared
    @ObservedObject private var premium = V2SPremiumStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page: Page = .servers
    @State private var showingImport = false
    @State private var showingSubscriptionPlans = false
    @State private var showingOfferCodeRedemption = false
    @State private var showingProductionRedemptionHelp = false
    @State private var redemptionError: String?
    @State private var showingSharingGuide = false
    @State private var showingDiscoveryConsent = false
    @State private var showingDiscoveryPolicy = false
    @State private var heldProfileID: UUID?
    @State private var collapsedSubscriptionIDs = Set<UUID>()
    @State private var serverSection: ServerSection = .added
    @State private var editingProfile: V2SProfile?

    private enum Page: String, CaseIterable, Identifiable {
        case servers = "Servers", activity = "Activity & Logs", settings = "Settings"
        var id: String { rawValue }
        var icon: String { switch self { case .servers: "server.rack"; case .activity: "list.bullet.rectangle"; case .settings: "slider.horizontal.3" } }
    }

    private enum ServerSection: String, CaseIterable, Identifiable {
        case added = "Added servers", free = "Free servers", premium = "Premium servers"
        var id: String { rawValue }
        var icon: String { switch self { case .added: "server.rack"; case .free: "globe"; case .premium: "crown.fill" } }
        var color: Color { switch self { case .added: V2SPalette.cyan; case .free: V2SPalette.success; case .premium: V2SPalette.gold } }
    }

    @ViewBuilder
    var body: some View {
        if #available(macOS 27.0, *) {
            rootContent.offerCodeRedemption(options: [], isPresented: $showingOfferCodeRedemption) { result in
                if case .success(let transaction) = result {
                    redemptionError = nil
                    Task { await premium.refreshEntitlement(redeemedTransaction: transaction) }
                } else if case .failure(let error) = result {
                    redemptionError = V2SRedemptionFailure.message(for: error)
                }
            }
        } else if #available(macOS 15.0, *) {
            rootContent.offerCodeRedemption(isPresented: $showingOfferCodeRedemption) { result in
                if case .success = result {
                    redemptionError = nil
                    Task { await premium.refreshEntitlement() }
                } else if case .failure(let error) = result {
                    redemptionError = V2SRedemptionFailure.message(for: error)
                }
            }
        } else {
            rootContent
        }
    }

    private var rootContent: some View {
        VStack(spacing: 0) {
            topNavigation
            switch page {
            case .servers: home
            case .activity: V2SActivityView()
            case .settings: V2SSettingsView(model: model)
            }
        }
        .background(V2SPalette.background)
        .font(.system(size: 14))
        .foregroundStyle(V2SPalette.text)
        .preferredColorScheme(.dark)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await premium.refreshEntitlement() }
        }
        .tint(V2SPalette.cyan)
        .frame(minWidth: 900, minHeight: 620)
        .sheet(isPresented: $showingImport) {
            V2SImportView(
                onImportInput: { input, name in
                    if V2SSubscriptionService.isHTTPSSubscriptionURL(input) {
                        let chosenName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        let subscriptionName = chosenName.isEmpty ? V2SSubscriptionService.suggestedName(for: input) : chosenName
                        Task { await model.addSubscription(url: input, name: subscriptionName) }
                    } else {
                        model.importText(input, name: name)
                    }
                }
            ).v2sSelectedLanguage()
        }
        .sheet(isPresented: $showingSharingGuide) { V2SInternetSharingGuide(isConnected: vpn.status == .connected).v2sSelectedLanguage() }
        .sheet(isPresented: $showingSubscriptionPlans) { subscriptionPlansSheet.v2sSelectedLanguage() }
        .alert(V2SLocalization.text("Use the Mac App Store version for real offer codes"), isPresented: $showingProductionRedemptionHelp) {
            Button(V2SLocalization.text("Open V2S in Mac App Store")) {
                NSWorkspace.shared.open(URL(string: "https://apps.apple.com/app/id6815956749")!)
            }
            Button(V2SLocalization.text("Cancel"), role: .cancel) { }
        } message: {
            Text(V2SLocalization.text("This copy uses test purchases. A regular Apple Account does not switch it to production. Redeem your real offer in the Mac App Store version, using your purchasing account. Returning here cannot transfer a production subscription into this test environment."))
        }
        .sheet(item: $editingProfile) { profile in
            V2SReplaceProfileView(profile: profile) { link, name in
                model.replaceManualProfile(profile, with: link, name: name)
            } onCancel: {
                editingProfile = nil
            }.v2sSelectedLanguage()
        }
        .confirmationDialog(V2SLocalization.text("Scan public servers?"), isPresented: $showingDiscoveryConsent, titleVisibility: .visible) {
            Button(V2SLocalization.text("Scan public servers")) { model.scanCommunityServers() }
            Button(V2SLocalization.text("Read privacy and public-server notice")) { showingDiscoveryPolicy = true }
            Button(V2SLocalization.text("Cancel"), role: .cancel) { }
        } message: {
            Text(V2SLocalization.text(V2SPublicServerNotice.text))
        }
        .sheet(isPresented: $showingDiscoveryPolicy) {
            VStack {
                V2SPrivacyView(model: model)
                Button(V2SLocalization.text("Done")) { showingDiscoveryPolicy = false }.padding()
            }.frame(width: 780, height: 720).v2sSelectedLanguage()
        }
        .alert(V2SLocalization.text("V2S"), isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.clearError() } })) {
            Button(V2SLocalization.text("OK")) { model.clearError() }
        } message: { Text(V2SLocalization.text(model.errorMessage ?? "")) }
    }

    private func tr(_ text: String) -> String { V2SLocalization.text(text, language: model.settings.languageCode) }

    private var topNavigation: some View {
        HStack(spacing: 18) {
            HStack(spacing: 8) {
                Image("V2SLogo").resizable().scaledToFit().frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(V2SLocalization.text("V2S")).font(.system(size: 19, weight: .heavy, design: .rounded))
                    Text(V2SLocalization.text("\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"))"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            ForEach(Page.allCases) { item in
                Button { page = item } label: {
                    Label(tr(item.rawValue), systemImage: item.icon)
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(page == item ? V2SPalette.raised : .clear, in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(page == item ? .isSelected : [])
            }
            appActions
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(V2SPalette.panel)
    }

    private var appActions: some View {
            Menu {
                Button(V2SLocalization.text("Add server or subscription"), systemImage: "plus") { showingImport = true }
                Button(V2SLocalization.text("Update all subscriptions"), systemImage: "arrow.clockwise") {
                    Task { await model.refreshAllSubscriptions() }
                }
                .disabled(model.data.subscriptions.isEmpty || !vpn.canTestServers || model.isRefreshingSubscriptions)
                Button(tr(model.isPingingAll ? "Stop checking servers" : "Check all server responses"), systemImage: "waveform.path.ecg") {
                    if model.isPingingAll { model.cancelPingAll() }
                    else { model.testAll() }
                }
                .disabled(model.data.profiles.isEmpty || !vpn.canTestServers)
                Button(V2SLocalization.text("Share connection"), systemImage: "wifi.router") { showingSharingGuide = true }
            } label: { Label(V2SLocalization.text("More"), systemImage: "ellipsis.circle") }
            .menuStyle(.borderlessButton)
            .fixedSize()
    }

    private var serversContent: some View {
        VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(tr("Choose a source, select a server, then connect."))
                        .font(.callout).foregroundStyle(V2SPalette.secondaryText)
                    Spacer()

                }
                Text(tr("SERVER SOURCE"))
                    .font(.system(size: 12, weight: .bold)).tracking(1.2)
                    .foregroundStyle(V2SPalette.secondaryText)
                HStack(spacing: 10) {
                    ForEach(ServerSection.allCases) { section in
                        let selected = serverSection == section
                        Button { serverSection = section } label: {
                            Label(tr(section.rawValue), systemImage: section.icon)
                                .font(.system(size: 15, weight: .semibold))
                                .frame(maxWidth: .infinity, minHeight: 52)
                                .foregroundStyle(selected ? section.color : V2SPalette.secondaryText)
                                .background(selected ? section.color.opacity(0.18) : V2SPalette.panel, in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? section.color.opacity(0.9) : .white.opacity(0.08), lineWidth: selected ? 2 : 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(V2SLocalization.text("Server source"))
                switch serverSection {
                case .added:
                    HStack {
                        Text(V2SLocalization.text("Servers you added, including your subscriptions"))
                            .font(.system(size: 13)).foregroundStyle(V2SPalette.secondaryText)
                        Spacer()
                        Button { showingImport = true } label: { Label(V2SLocalization.text("Add server"), systemImage: "plus") }
                    }
                    if !localProfiles.isEmpty { serverGroup("MY SERVERS", profiles: localProfiles, section: .added) }
                    ForEach(model.data.subscriptions) { source in
                        let profiles = model.data.profiles.filter { $0.sourceID == source.id }
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Button {
                                    if collapsedSubscriptionIDs.contains(source.id) { collapsedSubscriptionIDs.remove(source.id) }
                                    else { collapsedSubscriptionIDs.insert(source.id) }
                                } label: {
                                    Label(V2SLocalization.text("\(source.name) · \(profiles.count) servers"), systemImage: collapsedSubscriptionIDs.contains(source.id) ? "chevron.right" : "chevron.down")
                                        .font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                groupActions(profiles: profiles, source: source, section: .added)
                            }
                            if !collapsedSubscriptionIDs.contains(source.id) {
                                if profiles.isEmpty {
                                    Text(V2SLocalization.text("No servers in this subscription yet.")).foregroundStyle(V2SPalette.mutedText)
                                } else {
                                    ForEach(sortedProfiles(profiles)) { serverRow($0) }
                                }
                            }
                        }
                        .padding(12)
                        .background(V2SPalette.panel, in: RoundedRectangle(cornerRadius: 12))
                    }
                    if localProfiles.isEmpty && model.data.subscriptions.isEmpty {
                        ContentUnavailableView(V2SLocalization.text("No added servers"), systemImage: "server.rack", description: Text(V2SLocalization.text("Add a server link or subscription to get started.")))
                    }
                case .free:
                    communityCard
                    if communityProfiles.isEmpty {
                        ContentUnavailableView(V2SLocalization.text("No checked free servers"), systemImage: "globe", description: Text(V2SLocalization.text("Scan to check approved candidates. Availability depends on the feed and your network.")))
                    } else { serverGroup("SCANNED FREE SERVERS", profiles: communityProfiles, section: .free) }
                case .premium:
                    premiumCard
                    if premiumProfiles.isEmpty {
                        ContentUnavailableView(tr("No Premium servers available"), systemImage: "crown", description: Text(tr(premium.isEntitled ? "Refresh your subscription or try again later." : "Subscribe or restore purchases to access Premium servers.")))
                    } else { serverGroup("V2S PREMIUM SERVERS", profiles: premiumProfiles, section: .premium) }
                }
        }
    }

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                connectionCard
                serversContent
                if let selected = model.selectedProfile { selectedCard(selected) }
                Text(V2SLocalization.text("A proxy response check measures a request through a server. It does not verify the VPN tunnel, server location, or overall privacy."))
                    .font(.system(size: 13)).foregroundStyle(V2SPalette.mutedText).frame(maxWidth: .infinity, alignment: .center).padding(.top, 2)
            }
            .padding(22).frame(maxWidth: 1100).frame(maxWidth: .infinity)
        }
    }

    private var connectionCard: some View {
        let accent = connectionAccent
        return HStack(spacing: 18) {
            ZStack {
                Circle().fill(accent.opacity(0.16)).frame(width: 52, height: 52)
                Circle().stroke(accent.opacity(0.52), lineWidth: 1).frame(width: 52, height: 52)
                Image(systemName: vpn.status == .connected ? "checkmark.shield.fill" : "shield.lefthalf.filled")
                    .font(.system(size: 23)).foregroundStyle(accent)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 9) {
                    Circle().fill(statusColor).frame(width: 9, height: 9)
                    Text(tr(statusTitle)).font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(vpn.status == .connected ? V2SPalette.success : V2SPalette.text)
                }
                if let started = vpn.connectedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        Text(tr("Connected time") + " · " + V2SConnectionDuration.format(since: started, now: timeline.date))
                            .font(.system(size: 13, design: .monospaced)).monospacedDigit()
                            .foregroundStyle(V2SPalette.secondaryText)
                    }
                }
            }
            Spacer()
            connectionActionButton
        }
        .padding(17).background(V2SPalette.panel, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(accent.opacity(0.34), lineWidth: 1))
    }

    @ViewBuilder
    private var connectionActionButton: some View {
        let isConnecting = vpn.status == .connecting || vpn.status == .reasserting
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isConnecting || reduceMotion)) { timeline in
            let wave = (sin(timeline.date.timeIntervalSinceReferenceDate * .pi / 0.72) + 1) / 2
            let opacity = isConnecting && !reduceMotion ? 0.58 + (0.42 * wave) : 1.0
            Button {
                if vpn.status == .connected || vpn.status == .connecting || vpn.status == .reasserting {
                    model.disconnect()
                } else {
                    Task { await model.connectSelected() }
                }
            } label: {
                Label(
                    tr(vpn.status == .connected ? "Disconnect" : (isConnecting ? "Connecting…" : "Connect")),
                    systemImage: vpn.status == .connected ? "stop.fill" : "play.fill"
                )
                .font(.system(size: 14, weight: .semibold))
                .frame(minWidth: 145).padding(.horizontal, 16).padding(.vertical, 9)
                .foregroundStyle(.white)
                .background { RoundedRectangle(cornerRadius: 11).fill(connectionGradient).opacity(opacity) }
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(.white.opacity(0.2), lineWidth: 1))
                .shadow(color: connectionAccent.opacity(0.28), radius: 10, y: 3)
            }
            .buttonStyle(.plain)
            .disabled((model.selectedProfile == nil && vpn.status != .connected) || isConnecting || vpn.status == .disconnecting)
            .accessibilityHint(vpn.status == .connected ? "Disconnect the active V2S tunnel." : "Connect to the selected server.")
        }
    }

    private var connectionAccent: Color {
        switch vpn.status {
        case .connected: V2SPalette.success
        case .connecting, .reasserting: V2SPalette.gold
        case .disconnecting: V2SPalette.cyan
        case .disconnected, .invalid: V2SPalette.purple
        @unknown default: V2SPalette.purple
        }
    }

    private var connectionGradient: LinearGradient {
        let colors: [Color]
        switch vpn.status {
        case .connected: colors = [Color(red: 0.04, green: 0.48, blue: 0.27), Color(red: 0.03, green: 0.38, blue: 0.23)]
        case .connecting, .reasserting: colors = [Color(red: 0.52, green: 0.31, blue: 0.04), Color(red: 0.55, green: 0.22, blue: 0.07)]
        case .disconnecting: colors = [Color(red: 0.04, green: 0.40, blue: 0.52), Color(red: 0.34, green: 0.25, blue: 0.78)]
        case .disconnected, .invalid: colors = [Color(red: 0.04, green: 0.40, blue: 0.52), Color(red: 0.34, green: 0.25, blue: 0.78)]
        @unknown default: colors = [Color(red: 0.04, green: 0.40, blue: 0.52), Color(red: 0.34, green: 0.25, blue: 0.78)]
        }
        return LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }

    private var premiumStatusText: String {
        if !premium.hasCheckedEntitlement { return tr("Checking your Apple subscription…") }
        if premium.isEntitled, let expiry = premium.expirationDate {
            let date = expiry.formatted(.dateTime.locale(Locale(identifier: model.settings.languageCode ?? "en")).year().month().day().hour().minute())
            return tr("Premium access expires") + " · " + date
        }
        return tr(premium.message)
    }

    private var premiumCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
            Image(systemName: "crown.fill").font(.system(size: 20)).foregroundStyle(V2SPalette.gold)
                .frame(width: 42, height: 42).background(V2SPalette.gold.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("V2S Premium Servers")).font(.headline)
                Text(tr(premiumStatusText))
                    .font(.system(size: 13)).foregroundStyle(V2SPalette.secondaryText).lineLimit(2)
            }
            Spacer(minLength: 8)
            if premium.isEntitled {
                Label(tr("Active"), systemImage: "checkmark.seal.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(V2SPalette.cyan)
            } else if premium.hasCheckedEntitlement {
                Label(tr("Subscription"), systemImage: "lock.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(V2SPalette.gold)
            }
            }
            if premium.isEntitled {
                HStack {
                    Text(tr(premium.activeProductID == V2SPremiumStore.monthlyProductID
                         ? "Monthly plan active. Premium servers are ready below."
                         : premium.activeProductID == V2SPremiumStore.yearlyProductID
                         ? "Yearly plan active. Premium servers are ready below."
                         : "Premium servers are ready to select below."))
                        .font(.system(size: 13)).foregroundStyle(V2SPalette.secondaryText)
                    Spacer()
                    Button(tr("Change plan")) { showingSubscriptionPlans = true }
                        .buttonStyle(.borderless)
                }
            } else if !premium.hasCheckedEntitlement || premium.isCheckingEntitlement {
                ProgressView(tr("Checking Premium access…")).controlSize(.small)
            } else {
                Button(tr("View subscription plans")) { showingSubscriptionPlans = true }
                    .buttonStyle(.borderedProminent).tint(V2SPalette.gold)
            }
            HStack(spacing: 14) {
                Button(tr("Restore Purchases")) { Task { await model.restorePremium() } }
                    .buttonStyle(.borderless).disabled(premium.isCheckingEntitlement)
                if #available(macOS 15.0, *) {
                    Button(tr("Redeem offer code")) {
                        redemptionError = nil
                        if premium.installation.usesTestPurchases { showingProductionRedemptionHelp = true }
                        else { showingOfferCodeRedemption = true }
                    }
                        .buttonStyle(.borderless).disabled(premium.isCheckingEntitlement)
                }
                Link(tr("Manage subscription"), destination: URL(string: "https://apps.apple.com/account/subscriptions")!)
                    .font(.system(size: 13))
            }.font(.system(size: 13))
            Text(tr("Redeem a V2S Premium Monthly or Yearly subscription offer code. Apple shows the free or discounted period and renewal terms before confirmation. App-download promo codes do not include Premium."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let redemptionError { Text(V2SLocalization.text(redemptionError)).font(.caption).foregroundStyle(.orange) }

        }
        .environment(\.layoutDirection, ["fa", "ar"].contains(model.settings.languageCode ?? "en") ? .rightToLeft : .leftToRight)
        .padding(15).background(V2SPalette.panel, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(V2SPalette.gold.opacity(0.28), lineWidth: 1))
    }

    private var subscriptionPlansSheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(tr("V2S Premium Servers")).font(.title2.bold())
                    Spacer()
                    Button(tr("Done")) { showingSubscriptionPlans = false }
                }
                Text(tr("Choose a subscription to unlock V2S Premium Servers."))
                    .foregroundStyle(V2SPalette.secondaryText)
                if premium.isLoadingProducts || !premium.hasCheckedEntitlement {
                    ProgressView(tr("Loading Apple subscription plans…"))
                } else if premium.products.isEmpty {
                    Text(tr("Subscription plans are unavailable right now. Please try again later."))
                        .foregroundStyle(V2SPalette.secondaryText)
                } else {
                    VStack(spacing: 10) {
                        ForEach(premium.products, id: \.id) { product in
                            Button {
                                Task {
                                    await model.purchasePremium(product)
                                    if premium.completedPurchaseProductID == product.id {
                                        showingSubscriptionPlans = false
                                    }
                                }
                            } label: {
                                let isMonthly = product.id == V2SPremiumStore.monthlyProductID
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(tr(isMonthly ? "Monthly plan" : "Yearly plan")).font(.headline)
                                        if let trial = premiumTrialDisclosure(for: product) {
                                            Text(trial).font(.system(size: 13))
                                        }
                                    }
                                    Spacer()
                                    Text(V2SLocalization.text("\(product.displayPrice) / \(V2SLocalization.text(isMonthly ? "month" : "year"))"))
                                        .font(.system(size: 15, weight: .semibold).monospacedDigit())
                                }
                                .padding(14)
                                .background(V2SPalette.gold, in: RoundedRectangle(cornerRadius: 10))
                                .foregroundStyle(V2SPalette.background)
                            }
                            .buttonStyle(.plain)
                            .disabled(premium.purchasingProductID != nil || premium.isCheckingEntitlement)
                        }
                    }
                    if premium.purchasingProductID != nil {
                        ProgressView(tr("Processing purchase…"))
                        if let notice = premium.purchaseWaitMessage {
                            Text(V2SLocalization.text(notice)).font(.system(size: 13)).foregroundStyle(V2SPalette.secondaryText)
                        }
                    }
                    Text(tr("Plans renew automatically at the displayed price until canceled. Manage or cancel through your Apple Account. Free trials and introductory offers are available only to eligible subscribers when shown on a plan."))
                        .font(.system(size: 13)).foregroundStyle(V2SPalette.secondaryText)
                }
                HStack(spacing: 18) {
                    Link(tr("Privacy Policy"), destination: URL(string: "https://v2teh.com/v2s-macos-privacy.html")!)
                    Link(tr("Terms of Use"), destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(V2SPalette.cyan)
            }
            .padding(24)
        }
        .frame(width: 620, height: 400)
        .background(V2SPalette.background)
        .preferredColorScheme(.dark)
    }

    private func premiumTrialDisclosure(for product: Product) -> String? {
        guard let offer = product.subscription?.introductoryOffer,
              offer.paymentMode == .freeTrial else { return nil }
        let period = offer.period
        let unit: String
        switch period.unit {
        case .day: unit = period.value == 1 ? "day" : "days"
        case .week: unit = period.value == 1 ? "week" : "weeks"
        case .month: unit = period.value == 1 ? "month" : "months"
        case .year: unit = period.value == 1 ? "year" : "years"
        @unknown default: return nil
        }
        let duration = "\(period.value) \(V2SLocalization.text(unit))"
        return V2SLocalization.text("\(duration) free trial for eligible subscribers")
    }

    private var communityCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "globe.americas.fill").font(.system(size: 18)).foregroundStyle(V2SPalette.success)
                .frame(width: 40, height: 40).background(V2SPalette.success.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text(V2SLocalization.text("Scan for Free Servers")).font(.headline)
                Text(V2SLocalization.text(model.communityScanProgress.isEmpty ? "Only approved candidates that pass a proxy check on this Mac are listed." : model.communityScanProgress))
                    .font(.system(size: 13)).foregroundStyle(V2SPalette.secondaryText).lineLimit(2)
            }
            Spacer(minLength: 8)
            if model.isDiscoveringCommunity {
                Button(V2SLocalization.text("Stop")) { model.stopCommunityScan() }.buttonStyle(.bordered)
            } else {
                Button(tr(model.settings.communityDiscoveryEnabled ? "Scan for Free Servers" : "Enable in Settings")) {
                    if model.settings.communityDiscoveryEnabled { showingDiscoveryConsent = true }
                    else { page = .settings }
                }
                    .buttonStyle(.borderedProminent).tint(V2SPalette.success)
                    .disabled(!vpn.canTestServers || model.isPingingAll)
            }
        }
        .padding(14).background(V2SPalette.panel, in: RoundedRectangle(cornerRadius: 16))
    }

    private func selectedCard(_ profile: V2SProfile) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(V2SLocalization.text("SELECTED SERVER")).font(.system(size: 12, weight: .bold)).tracking(1.5).foregroundStyle(V2SPalette.secondaryText)
                    Text(profile.displayLocation(language: model.settings.languageCode)).font(.title3.weight(.semibold))
                    Text(profile.protocolName.uppercased()).font(.callout).foregroundStyle(V2SPalette.secondaryText)
                }
                Spacer()
                Label(tr(isConnected(profile) ? "Connected" : "Not connected"), systemImage: isConnected(profile) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isConnected(profile) ? V2SPalette.success : V2SPalette.secondaryText)
                Text(profile.protocolName.uppercased()).font(.system(size: 13, weight: .bold)).padding(.horizontal, 10).padding(.vertical, 6)
                    .background(V2SPalette.purple.opacity(0.15), in: Capsule()).foregroundStyle(V2SPalette.cyan)
            }
            Divider().overlay(.white.opacity(0.07))
            HStack {
                Label(
                    tr(profile.latencyMilliseconds.map { "\($0) ms proxy response" }
                        ?? (profile.isCommunity == true ? "Not verified on this Mac" : "Not checked")),
                    systemImage: "waveform.path.ecg"
                )
                .font(.callout)
                .foregroundStyle(profile.latencyMilliseconds.map(latencyColor) ?? (profile.isCommunity == true ? V2SPalette.gold : V2SPalette.secondaryText))
                .help(profile.isCommunity == true && profile.latencyMilliseconds == nil
                      ? "This public server has not passed a proxy check on this Mac yet. Scan public servers to find responding options."
                      : "Measures an HTTPS request through the selected proxy; it does not certify the VPN tunnel.")
                Spacer()
                Button { model.test(profile) } label: {
                    if model.pinging.contains(profile.id) { ProgressView().controlSize(.small) }
                    else { Label(V2SLocalization.text("Check"), systemImage: "arrow.clockwise") }
                }
                .disabled(!vpn.canTestServers || model.pinging.contains(profile.id) || model.isPingingAll)
                Button { showingSharingGuide = true } label: { Label(V2SLocalization.text("Share"), systemImage: "wifi.router") }.buttonStyle(.bordered)
            }
            if let source = subscriptionSource(for: profile) {
                HStack {
                    Label(V2SLocalization.text("Subscription"), systemImage: "arrow.triangle.2.circlepath")
                        .font(.callout).foregroundStyle(V2SPalette.secondaryText)
                    Spacer()
                    Text(source.name).font(.callout.weight(.medium))
                }
                Divider().overlay(.white.opacity(0.07))
                if let usage = source.usage {
                    subscriptionUsageView(usage)
                } else {
                    HStack(alignment: .top) {
                        Label(V2SLocalization.text("Provider allowance"), systemImage: "gauge.with.dots.needle.33percent")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(V2SPalette.secondaryText)
                        Spacer()
                        Text(V2SLocalization.text("Not provided"))
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(V2SPalette.secondaryText)
                        Button(V2SLocalization.text("Update")) { Task { await model.refresh(source) } }
                            .buttonStyle(.borderless)
                            .disabled(!vpn.canTestServers)
                    }
                    .help(V2SLocalization.text("This subscription response did not include usage or allowance information."))
                }
            }
            if profile.isCommunity == true {
                Label(V2SLocalization.text("Public third-party server. Avoid sensitive traffic."), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13)).foregroundStyle(V2SPalette.gold)
            }
        }
        .padding(20).background(V2SPalette.panel, in: RoundedRectangle(cornerRadius: 16))
    }

    private func subscriptionSource(for profile: V2SProfile) -> V2SSubscription? {
        if let sourceID = profile.sourceID,
           let source = model.data.subscriptions.first(where: { $0.id == sourceID }) {
            return source
        }
        guard let sourceName = profile.sourceName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sourceName.isEmpty else { return nil }
        let matches = model.data.subscriptions.filter { $0.name.localizedCaseInsensitiveCompare(sourceName) == .orderedSame }
        return matches.count == 1 ? matches.first : nil
    }

    private func subscriptionUsageView(_ usage: V2SSubscriptionUsage) -> some View {
        VStack(spacing: 9) {
            HStack {
                Label(V2SLocalization.text("Provider allowance"), systemImage: "gauge.with.dots.needle.33percent")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(V2SPalette.secondaryText)
                Spacer()
                if let total = usage.totalBytes {
                    Text(V2SLocalization.text("\(formattedBytes(usage.usedBytes)) / \(formattedBytes(total))"))
                        .font(.system(size: 13, weight: .semibold))
                } else {
                    Text(V2SLocalization.text("\(formattedBytes(usage.usedBytes)) used"))
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            if let fraction = usage.fractionUsed {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(V2SPalette.cyan.opacity(0.12))
                        Capsule().fill(V2SPalette.purple).frame(width: proxy.size.width * fraction)
                    }
                }
                .frame(height: 8)
                if let remaining = usage.remainingBytes {
                    HStack {
                        Text(V2SLocalization.text("\(formattedPercent(fraction)) used"))
                        Spacer()
                        Text(V2SLocalization.text("\(formattedBytes(remaining)) remaining"))
                    }
                    .font(.system(size: 13)).foregroundStyle(V2SPalette.secondaryText)
                }
            }
            if let expiryDate = usage.expiryDate {
                HStack {
                    Spacer()
                    Text(V2SLocalization.text("Expires \(expiryDate.formatted(date: .abbreviated, time: .omitted))"))
                        .font(.system(size: 13)).foregroundStyle(expiryDate < Date() ? V2SPalette.error : V2SPalette.secondaryText)
                }
            }
        }
        .padding(12)
        .background(V2SPalette.raised, in: RoundedRectangle(cornerRadius: 10))
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useGB, .useMB, .useKB, .useBytes]
        return formatter.string(fromByteCount: max(0, bytes))
    }

    private func formattedPercent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    private var emptyHomeCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image("V2SLogo").resizable().scaledToFit().frame(width: 45, height: 45)
                VStack(alignment: .leading, spacing: 4) {
                    Text(V2SLocalization.text("Get started with V2S")).font(.title3.bold())
                    Text(V2SLocalization.text("Add a server profile, then test and connect.")).font(.callout).foregroundStyle(V2SPalette.secondaryText)
                }
                Spacer()
                Button { showingImport = true } label: { Label(V2SLocalization.text("Add server"), systemImage: "plus") }
                    .buttonStyle(.borderedProminent).tint(V2SPalette.purple)
            }
            Divider().overlay(.white.opacity(0.07))
            HStack(alignment: .top, spacing: 22) {
                quickStep("1", "Import", "Choose a file, paste proxy links, or add an HTTPS subscription.", icon: "square.and.arrow.down")
                quickStep("2", "Check", "Measure proxy response time. Ping does not certify a VPN tunnel.", icon: "waveform.path.ecg")
                quickStep("3", "Connect", "Select a server and connect through the V2S Mac tunnel.", icon: "lock.shield")
            }
        }
        .padding(21).background(V2SPalette.panel, in: RoundedRectangle(cornerRadius: 16))
    }

    private func quickStep(_ number: String, _ title: String, _ text: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(V2SPalette.cyan)
                .frame(width: 31, height: 31).background(V2SPalette.cyan.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 4) {
                Text(V2SLocalization.text("\(number) · \(V2SLocalization.text(title))")).font(.subheadline.weight(.semibold))
                Text(V2SLocalization.text(text)).font(.system(size: 13)).foregroundStyle(V2SPalette.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var localProfiles: [V2SProfile] { model.data.profiles.filter { $0.sourceID == nil && $0.isCommunity != true && $0.isPremium != true } }
    private var premiumProfiles: [V2SProfile] { model.data.profiles.filter { $0.isPremium == true } }
    private var communityProfiles: [V2SProfile] {
        model.data.profiles.filter { $0.isCommunity == true && $0.latencyMilliseconds != nil }
    }

    private var selectedServerInSection: V2SProfile? {
        guard let selected = model.selectedProfile else { return nil }
        switch serverSection {
        case .added: return selected.isCommunity != true && selected.isPremium != true ? selected : nil
        case .free: return selected.isCommunity == true ? selected : nil
        case .premium: return selected.isPremium == true ? selected : nil
        }
    }

    private func serverGroup(_ title: String, profiles: [V2SProfile], section: ServerSection, opensConnectionDetail: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(V2SLocalization.text(title)).font(.system(size: 12, weight: .bold)).tracking(1).foregroundStyle(V2SPalette.secondaryText)
                Spacer()
                groupActions(profiles: profiles, source: nil, section: section)
            }.padding(.horizontal, 9)
            ForEach(sortedProfiles(profiles)) { serverRow($0, opensConnectionDetail: opensConnectionDetail) }
        }
    }

    private func groupActions(profiles: [V2SProfile], source: V2SSubscription?, section: ServerSection) -> some View {
        HStack(spacing: 12) {
            Button {
                if model.isPingingAll { model.cancelPingAll() }
                else { model.test(profiles) }
            } label: {
                Image(systemName: model.isPingingAll ? "stop.circle" : "waveform.path.ecg")
            }
            .help(tr(model.isPingingAll ? "Stop checking servers" : "Ping all servers"))
            .accessibilityLabel(tr(model.isPingingAll ? "Stop checking servers" : "Ping all servers"))
            .disabled(profiles.isEmpty || !vpn.canTestServers || model.isDiscoveringCommunity)
            Button {
                if let source { Task { await model.refresh(source) } }
                else if section == .premium { Task { await premium.refreshEntitlement() } }
                else if section == .free {
                    if model.settings.communityDiscoveryEnabled { showingDiscoveryConsent = true }
                    else { page = .settings }
                } else { Task { await model.refreshAllSubscriptions() } }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help(tr("Update all servers"))
            .accessibilityLabel(tr("Update all servers"))
            .disabled(!vpn.canTestServers || model.isRefreshingSubscriptions || model.isDiscoveringCommunity || premium.isCheckingEntitlement)
        }
        .font(.system(size: 16, weight: .semibold)).foregroundStyle(V2SPalette.cyan)
        .buttonStyle(.borderless)
    }

    private func serverRow(_ profile: V2SProfile, opensConnectionDetail: Bool = false) -> some View {
        Button {
            if opensConnectionDetail { page = .servers }
            Task { await model.selectAndSwitch(profile) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: profile.isCommunity == true ? "globe" : "server.rack")
                    .font(.system(size: 17)).foregroundStyle(V2SPalette.cyan).frame(width: 21)
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.displayLocation(language: model.settings.languageCode)).font(.system(size: 15, weight: .semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Text(profile.protocolName.uppercased())
                        .font(.system(size: 13)).foregroundStyle(V2SPalette.secondaryText).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 2)
                if model.pinging.contains(profile.id) { ProgressView().controlSize(.mini) }
                else if let ms = profile.latencyMilliseconds { Text(V2SLocalization.text("\(ms) ms")).font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(latencyColor(ms)) }
                else if profile.isCommunity == true {
                    Text(V2SLocalization.text("Not checked"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(V2SPalette.gold)
                        .help(V2SLocalization.text("This public server has not passed a proxy check on this Mac yet."))
                }
                Button { model.test(profile) } label: {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(V2SPalette.cyan)
                        .frame(width: 28, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(V2SLocalization.text("Check this server's proxy response"))
                .accessibilityLabel(V2SLocalization.text("Ping server"))
                .disabled(!vpn.canTestServers || model.pinging.contains(profile.id))
            }
            .padding(.horizontal, 12).padding(.vertical, 12)
            .background(heldProfileID == profile.id ? V2SPalette.cyan.opacity(0.20) : (profile.id == model.selectedProfileID ? V2SPalette.selected : .clear), in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .help(isConnected(profile)
              ? "Click to select. Press and hold to disconnect from this server."
              : "Click to switch here when connected. Otherwise click to select or press and hold to connect.")
        .accessibilityHint(isConnected(profile)
                           ? "Press and hold to disconnect from this server."
                           : "Click to switch here when connected. Press and hold to connect otherwise.")
        // Keep the hold recognizer simultaneous with the row Button. A regular
        // Button can otherwise consume the same pointer sequence on macOS,
        // leaving the row's long-press action un-fired.
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.65, maximumDistance: 24)
                .onChanged { isRecognized in
                    heldProfileID = isRecognized ? profile.id : nil
                }
                .onEnded { _ in
                    heldProfileID = nil
                    if opensConnectionDetail { page = .servers }
                    Task { await model.toggleConnection(profile: profile) }
                }
        )
        .contextMenu {
            Button(tr(isConnected(profile) ? "Disconnect from Server" : "Connect to Server")) {
                if opensConnectionDetail { page = .servers }
                Task { await model.toggleConnection(profile: profile) }
            }
            Button(V2SLocalization.text("Check proxy response")) { model.test(profile) }.disabled(!vpn.canTestServers)
            if let source = subscriptionSource(for: profile) {
                Button(V2SLocalization.text("Update from subscription")) { Task { await model.refresh(source) } }
                    .disabled(!vpn.canTestServers)
            } else if profile.isCommunity == true {
                Button(V2SLocalization.text("Refresh free-server scan")) {
                    if model.settings.communityDiscoveryEnabled { showingDiscoveryConsent = true }
                    else { page = .settings }
                }
            } else if profile.isPremium == true {
                Button(V2SLocalization.text("Update Premium access")) { Task { await premium.refreshEntitlement() } }
            } else {
                Button(V2SLocalization.text("Replace server link")) { editingProfile = profile }
                    .disabled(!vpn.canTestServers)
            }
            Button(V2SLocalization.text("Copy server link")) { model.copyServerLink(profile) }
            Button(V2SLocalization.text("Remove server"), role: .destructive) { model.delete(profile) }
        }
    }

    private func isConnected(_ profile: V2SProfile) -> Bool {
        vpn.status == .connected && vpn.connectedProfileID == profile.id
    }

    private func sortedProfiles(_ profiles: [V2SProfile]) -> [V2SProfile] {
        profiles.sorted {
            switch ($0.latencyMilliseconds, $1.latencyMilliseconds) {
            case let (a?, b?): a < b
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
    }

    private func latencyColor(_ ms: Int) -> Color { ms < 150 ? V2SPalette.success : (ms < 350 ? V2SPalette.gold : V2SPalette.warning) }
    private var statusColor: Color { vpn.status == .connected ? .green : (vpn.status == .connecting || vpn.status == .reasserting ? V2SPalette.gold : V2SPalette.purple) }
    private var statusTitle: String {
        switch vpn.status {
        case .connected: model.selectedProfile == nil ? "Connected · profile unavailable" : "Connected"
        case .connecting: "Connecting…"
        case .reasserting: "Reconnecting…"
        case .disconnecting: "Disconnecting…"
        case .disconnected, .invalid: "Not connected"
        @unknown default: "V2S"
        }
    }
}

private struct V2SReplaceProfileView: View {
    let profile: V2SProfile
    let onSave: (String, String) -> Bool
    let onCancel: () -> Void
    @State private var name = ""
    @State private var link = ""
    @State private var updateFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(V2SLocalization.text("Update server")).font(.title2.bold())
            Text(V2SLocalization.text("Paste a replacement link for this manually added server. The current link stays saved until the new one is valid."))
                .foregroundStyle(V2SPalette.secondaryText)
            TextField(V2SLocalization.text("Server name"), text: $name)
            SecureField(V2SLocalization.text("Replacement VLESS, Trojan, VMess, or Shadowsocks link"), text: $link)
                .textContentType(.password)
            if updateFailed {
                Text(V2SLocalization.text("The server could not be updated. Check the link and try again."))
                    .foregroundStyle(V2SPalette.error)
            }
            HStack {
                Spacer()
                Button(V2SLocalization.text("Cancel"), action: onCancel)
                Button(V2SLocalization.text("Update server")) {
                    if onSave(link, name) { onCancel() }
                    else { updateFailed = true }
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 540)
        .onAppear { name = profile.name }
    }
}

private struct V2SImportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var input = ""
    @State private var isImportingFile = false
    @State private var fileImportError: String?
    let onImportInput: (String, String) -> Void

    private var trimmedInput: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isSubscription: Bool {
        !trimmedInput.contains("\n") && V2SSubscriptionService.isHTTPSSubscriptionURL(trimmedInput)
    }
    private var detectionMessage: String {
        if trimmedInput.isEmpty { return "Paste a subscription link or one or more server links. V2S will detect the format." }
        if isSubscription {
            let inferredName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? V2SSubscriptionService.suggestedName(for: trimmedInput)
                : name.trimmingCharacters(in: .whitespacesAndNewlines)
            return "HTTPS subscription detected · \(inferredName)"
        }
        return "Server links detected · VLESS, VMess, Trojan, or Shadowsocks"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack { Image("V2SLogo").resizable().scaledToFit().frame(width: 36, height: 36); Text(V2SLocalization.text("Add to V2S")).font(.title2.bold()) }
            Text(V2SLocalization.text("Paste a subscription link or server links. V2S detects the format automatically."))
                .font(.callout).foregroundStyle(V2SPalette.secondaryText)
            HStack {
                TextField(V2SLocalization.text("Name (optional)"), text: $name).textFieldStyle(.roundedBorder)
                Button(V2SLocalization.text("Import from Mac…")) { isImportingFile = true }
                Button(V2SLocalization.text("Paste")) {
                    if let value = NSPasteboard.general.string(forType: .string) {
                        input = V2SXray.normalizedShareLinksText(value)
                    }
                }
            }
            TextEditor(text: Binding(
                get: { input },
                set: { input = V2SXray.normalizedShareLinksText($0) }
            )).font(.system(.body, design: .monospaced)).frame(minHeight: 210)
                .overlay(alignment: .topLeading) {
                    if input.isEmpty {
                        Text(V2SLocalization.text("Paste an HTTPS subscription URL or one or more server links…"))
                            .font(.system(.body, design: .monospaced)).foregroundStyle(V2SPalette.mutedText)
                            .padding(.horizontal, 6).padding(.vertical, 8).allowsHitTesting(false)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            Label(V2SLocalization.text(detectionMessage), systemImage: isSubscription ? "arrow.triangle.2.circlepath" : "server.rack")
                .font(.system(size: 13)).foregroundStyle(V2SPalette.secondaryText).lineLimit(2)
            Text(V2SLocalization.text("Subscription URLs are private account information and are kept out of activity logs."))
                .font(.system(size: 13)).foregroundStyle(V2SPalette.secondaryText)
            HStack { Spacer(); Button(V2SLocalization.text("Cancel"), role: .cancel) { dismiss() }; Button(V2SLocalization.text("Import")) {
                onImportInput(trimmedInput, name)
                dismiss()
            }.buttonStyle(.borderedProminent).disabled(trimmedInput.isEmpty) }
        }
        .font(.system(size: 14)).foregroundStyle(V2SPalette.text)
        .padding(24).frame(width: 640)
        .fileImporter(isPresented: $isImportingFile,
                      allowedContentTypes: [.plainText, .json, .data],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let hasScopedAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if hasScopedAccess { url.stopAccessingSecurityScopedResource() }
                }
                do {
                    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                    guard values.isRegularFile == true,
                          let size = values.fileSize,
                          size <= 2_000_000 else {
                        fileImportError = "Choose a regular text or config file no larger than 2 MB."
                        return
                    }
                    let data = try Data(contentsOf: url, options: .mappedIfSafe)
                    guard data.count <= 2_000_000,
                          let contents = String(data: data, encoding: .utf8) else {
                        fileImportError = "V2S could not read that file as UTF-8 text."
                        return
                    }
                    input = V2SXray.normalizedShareLinksText(contents)
                } catch {
                    fileImportError = "V2S could not read the selected file."
                }
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError {
                    fileImportError = "V2S could not open the selected file. Try a plain-text or JSON config."
                }
            }
        }
        .alert(V2SLocalization.text("V2S"), isPresented: Binding(
            get: { fileImportError != nil },
            set: { if !$0 { fileImportError = nil } }
        )) {
            Button(V2SLocalization.text("OK")) { fileImportError = nil }
        } message: {
            Text(V2SLocalization.text(fileImportError ?? ""))
        }
    }
}

private struct V2SActivityView: View {
    @ObservedObject private var log = V2SActivityLog.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                VStack(alignment: .leading, spacing: 4) { Text(V2SLocalization.text("Activity")).font(.title2.bold()); Text(V2SLocalization.text("Recent connection and server-list events. Profile links and URLs are redacted.")).font(.callout).foregroundStyle(V2SPalette.secondaryText) }
                Spacer()
                Button(V2SLocalization.text("Clear")) { log.clear() }.disabled(log.entries.isEmpty)
            }
            if log.entries.isEmpty {
                ContentUnavailableView(V2SLocalization.text("No activity yet"), systemImage: "text.page.slash", description: Text(V2SLocalization.text("Connection, import, refresh, and scan events will show here.")))
            } else {
                List(log.entries) { entry in
                    HStack(alignment: .top, spacing: 12) {
                        Circle().fill(entry.level == .error ? V2SPalette.error : (entry.level == .warning ? V2SPalette.gold : V2SPalette.cyan)).frame(width: 7, height: 7).padding(.top, 6)
                        Text(entry.display).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    }.padding(.vertical, 4)
                }.listStyle(.inset)
            }
            Spacer(minLength: 0)
        }.padding(22).background(V2SPalette.background)
    }
}

private struct V2SInternetSharingGuide: View {
    @Environment(\.dismiss) private var dismiss
    let isConnected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 13) {
                Image(systemName: "wifi.router.fill").font(.system(size: 25)).foregroundStyle(V2SPalette.cyan)
                    .frame(width: 52, height: 52).background(V2SPalette.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 15))
                VStack(alignment: .leading, spacing: 3) { Text(V2SLocalization.text("Share V2S over Wi-Fi")).font(.title2.bold()); Text(V2SLocalization.text("Use macOS Internet Sharing for nearby devices.")).font(.callout).foregroundStyle(V2SPalette.secondaryText) }
                Spacer()
                Button(V2SLocalization.text("Done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
            if !isConnected {
                Label(V2SLocalization.text("Connect V2S first"), systemImage: "exclamationmark.circle.fill")
                    .font(.headline).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(V2SPalette.gold.opacity(0.12), in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(V2SPalette.gold)
            } else {
                Label(V2SLocalization.text("V2S is connected"), systemImage: "checkmark.circle.fill")
                    .font(.headline).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(.green)
            }
            VStack(alignment: .leading, spacing: 15) {
                instruction(1, "Connect V2S", "Choose a server in the main window and wait for Connected.")
                instruction(2, "Open Internet Sharing", "In System Settings, go to General › Sharing and open Internet Sharing.")
                instruction(3, "Choose the source and destination", "If V2S appears under “Share your connection from”, choose it. Select Wi-Fi as the destination, then configure the network name and password.")
                instruction(4, "Secure and enable the hotspot", "Use WPA2/WPA3 with a strong password. Turn Internet Sharing on in System Settings when you are ready.")
            }.padding(18).background(V2SPalette.panel, in: RoundedRectangle(cornerRadius: 14))
            Label(V2SLocalization.text("A wired, USB, or Thunderbolt upstream connection is preferable because Wi-Fi is used to broadcast the hotspot."), systemImage: "info.circle.fill")
                .font(.callout).foregroundStyle(V2SPalette.secondaryText).fixedSize(horizontal: false, vertical: true)
            Label(V2SLocalization.text("macOS may not list a Network Extension VPN as an Internet Sharing source. If V2S is absent from that menu, this Mac cannot share the V2S tunnel using the built-in hotspot feature. V2S will not change or enable system sharing for you."), systemImage: "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(V2SPalette.gold).fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button { openSharingSettings() } label: { Label(V2SLocalization.text("Open Sharing Settings"), systemImage: "gearshape") }.buttonStyle(.borderedProminent) }
        }
        .padding(24).frame(width: 720)
    }

    private func instruction(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(V2SLocalization.text("\(number)")).font(.system(size: 13, weight: .bold)).foregroundStyle(.white).frame(width: 26, height: 26).background(V2SPalette.purple, in: Circle())
            VStack(alignment: .leading, spacing: 3) { Text(V2SLocalization.text(title)).font(.headline); Text(V2SLocalization.text(detail)).font(.callout).foregroundStyle(V2SPalette.secondaryText).fixedSize(horizontal: false, vertical: true) }
        }
    }

    private func openSharingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension") { NSWorkspace.shared.open(url) }
    }
}

// macOS sheets may retain the process language instead of the window locale.
// Keep both layout direction and labels on the app's selected language.
extension View {
    @MainActor func v2sSelectedLanguage() -> some View {
        self.environment(\.locale, Locale(identifier: V2SLocalization.currentLanguage))
            .environment(\.layoutDirection, V2SLocalization.isRightToLeft ? .rightToLeft : .leftToRight)
    }
}
