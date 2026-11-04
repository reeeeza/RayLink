import SwiftUI

struct V2SSettingsView: View {
    @ObservedObject var model: V2SViewModel
    @ObservedObject private var premium = V2SPremiumStore.shared
    @State private var settings = V2SStore.loadSettings()
    @State private var showResetConfirmation = false
    @State private var showDeleteConfirmation = false
    @State private var showingPrivacy = false
    @State private var showingWithdrawConsent = false
    @State private var showingDiscoveryConsent = false
    @State private var showingOpenSourceNotices = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                titleBlock
                section("CONNECTION", icon: "bolt.horizontal.circle") {
                    Picker("Preferred IP version", selection: $settings.preferredIP) {
                        Text("IPv4").tag(V2SIPPreference.ipv4)
                        Text("IPv6").tag(V2SIPPreference.ipv6)
                        Text("Automatic").tag(V2SIPPreference.automatic)
                    }
                    Text("This preference guides DNS lookups. V2S routes both IPv4 and IPv6 traffic through the VPN.")
                        .font(.system(size: 13)).foregroundStyle(V2SPalette.secondaryText).fixedSize(horizontal: false, vertical: true)
                    Toggle("Connect automatically when V2S opens", isOn: Binding(
                        get: { settings.autoConnectEnabled }, set: { settings.autoConnect = $0 }
                    ))
                    Toggle("Disconnect when this Mac sleeps", isOn: $settings.disconnectOnSleep)
                    Toggle("On Demand", isOn: $settings.onDemand)
                    Text("On Demand behavior is managed by macOS and may depend on installed VPN configuration. Per-app bypass is an Android-only control and is unavailable in this Mac app.")
                        .font(.system(size: 13)).foregroundStyle(V2SPalette.secondaryText).fixedSize(horizontal: false, vertical: true)
                }
                section("DNS AND ROUTING", icon: "point.3.connected.trianglepath.dotted") {
                    Picker("DNS resolver", selection: $settings.dnsPreset) {
                        ForEach(V2SDNSPreset.allCases) { preset in Text(preset.title).tag(preset) }
                    }
                    if settings.dnsPreset == .custom {
                        TextField("IPv4 or IPv6 addresses, comma separated", text: $settings.customDNS)
                            .textFieldStyle(.roundedBorder)
                    }
                    if settings.dnsPreset == .system {
                        Text("System DNS uses macOS-configured resolvers. DNS requests may not use a V2S resolver.")
                            .font(.system(size: 13)).foregroundStyle(V2SPalette.secondaryText)
                    }
                    Toggle("Enable routing rules", isOn: $settings.routingEnabled)
                    Toggle("Bypass private and local networks", isOn: $settings.bypassPrivateNetworks)
                        .disabled(!settings.routingEnabled)
                    Toggle("Include all network traffic", isOn: Binding(
                        get: { settings.includeAllNetworks ?? false },
                        set: { settings.includeAllNetworks = $0 }
                    ))
                    Text("Optional macOS traffic enforcement. Leave off if it prevents this Mac or other network services from connecting.")
                        .font(.system(size: 13)).foregroundStyle(V2SPalette.secondaryText).fixedSize(horizontal: false, vertical: true)
                    Text("DNS and routing changes take effect after reconnecting. Local-network bypass sends local traffic outside the VPN.")
                        .font(.system(size: 13)).foregroundStyle(V2SPalette.secondaryText).fixedSize(horizontal: false, vertical: true)
                }
                section("SERVER LIST", icon: "server.rack") {
                    Toggle("Refresh subscriptions while V2S is open", isOn: $settings.refreshSubscriptionsWhileOpen)
                    Stepper("Refresh every \(settings.subscriptionRefreshHours) hour\(settings.subscriptionRefreshHours == 1 ? "" : "s")", value: $settings.subscriptionRefreshHours, in: 1...24)
                        .disabled(!settings.refreshSubscriptionsWhileOpen)
                    Toggle("Enable public server discovery", isOn: Binding(
                        get: { settings.communityDiscoveryEnabled },
                        set: { enabled in
                            if enabled { showingDiscoveryConsent = true }
                            else { settings.communityDiscoveryEnabled = false; model.stopCommunityScan() }
                        }
                    ))
                    Button("Public-server privacy and usage notice") { showingPrivacy = true }
                    Text("With your consent, V2S checks the approved public catalog when enabled and every 30 minutes while this app is open and disconnected. Only servers that pass a proxy check on this Mac are saved. The catalog may be empty while source and operator permissions are unresolved. Public server operators are unknown; don’t send them sensitive traffic.")
                        .font(.system(size: 13)).foregroundStyle(V2SPalette.secondaryText).fixedSize(horizontal: false, vertical: true)
                }
                section("PRIVACY AND ADVANCED", icon: "hand.raised") {
                    Toggle("Multiplexing (Mux)", isOn: $settings.muxEnabled)
                    Text("Mux may help some servers and reduce compatibility with others. Reconnect after changing it.")
                        .font(.system(size: 13)).foregroundStyle(V2SPalette.secondaryText)
                    Toggle("TLS fragmentation", isOn: $settings.fragmentationEnabled).disabled(true)
                    Text("Unavailable until this option is validated against the selected server and current Mac tunnel engine.")
                        .font(.system(size: 13)).foregroundStyle(V2SPalette.secondaryText)
                    Toggle("Allow invalid subscription certificates", isOn: $settings.insecureSubscriptionCertificates)
                    Text("Weakens HTTPS certificate checks for subscription downloads. Leave off unless your provider requires it.")
                        .font(.system(size: 13)).foregroundStyle(V2SPalette.secondaryText)
                    Text("Imported profiles and subscription credentials are stored in macOS Keychain. Activity messages redact proxy links and URLs.")
                        .font(.system(size: 13)).foregroundStyle(V2SPalette.secondaryText).fixedSize(horizontal: false, vertical: true)
                }
                section("PREMIUM", icon: "crown") {
                    Label(premium.isEntitled ? "Premium access active" : premium.message,
                          systemImage: premium.isEntitled ? "checkmark.seal.fill" : "lock.fill")
                        .foregroundStyle(premium.isEntitled ? Color.cyan : Color(red: 1, green: 0.73, blue: 0.30))
                    if premium.hasCheckedEntitlement && !premium.isEntitled && !premium.isCheckingEntitlement && !premium.products.isEmpty {
                        ForEach(premium.products, id: \.id) { product in
                            Button {
                                Task {
                                    await model.purchasePremium(product)
                                    model.clearError()
                                }
                            } label: {
                                HStack {
                                    Text(product.displayName)
                                    Spacer()
                                    Text(product.displayPrice).monospacedDigit()
                                }.frame(maxWidth: .infinity)
                            }
                            .disabled(premium.purchasingProductID != nil || premium.isCheckingEntitlement)
                        }
                    }
                    HStack {
                        Button("Restore Purchases") { Task { await model.restorePremium() } }
                            .disabled(premium.isCheckingEntitlement)
                        Link("Manage subscription", destination: URL(string: "https://apps.apple.com/account/subscriptions")!)
                    }
                    if premium.isEntitled || !premium.products.isEmpty {
                        Text("Subscriptions renew automatically until canceled. You can manage or cancel through your Apple Account.")
                            .font(.system(size: 13)).foregroundStyle(V2SPalette.secondaryText)
                    }
                    Text("V2S checks subscription status with its service before enabling a premium server. If that check is unavailable, premium connections remain locked until it succeeds.")
                        .font(.system(size: 13)).foregroundStyle(V2SPalette.secondaryText).fixedSize(horizontal: false, vertical: true)
                }
                section("PRIVACY", icon: "hand.raised") {
                    Button("Read privacy policy") { showingPrivacy = true }
                    Button("Withdraw consent and disconnect", role: .destructive) { showingWithdrawConsent = true }
                    Text("Stops network features and V2S automatic connection rules. Saved private profiles remain on this Mac. This does not cancel your Apple subscription or delete remote records.")
                        .font(.system(size: 13)).foregroundStyle(V2SPalette.secondaryText)
                    Link("Privacy and deletion requests", destination: URL(string: "https://v2teh.com/contact.html")!)
                    Link("Apple Standard End User License Agreement", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                    Text("Copyright © 2026 Irisholdingsbuddy Inc. Third-party components and materials retain their respective licenses and rights.")
                        .font(.system(size: 13)).foregroundStyle(V2SPalette.secondaryText)
                    Button("Open-source licenses and notices") { showingOpenSourceNotices = true }
                }
                section("ABOUT AND SUPPORT", icon: "info.circle") {
                    HStack(alignment: .top, spacing: 12) {
                        Image("V2SLogo").resizable().scaledToFit().frame(width: 42, height: 42)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("V2S").font(.system(size: 19, weight: .heavy, design: .rounded))
                            Text("VPN · Proxies · Private access").font(.callout).foregroundStyle(V2SPalette.secondaryText)
                        }
                        Spacer(minLength: 0)
                    }
                    Link(destination: URL(string: "https://v2teh.com")!) {
                        Label("v2teh.com", systemImage: "globe").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Link(destination: URL(string: "https://v2teh.com/contact.html")!) {
                        Label("Contact support", systemImage: "text.bubble").frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let issue = settings.validationIssue {
                    Label(issue, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                }
                HStack {
                    Text("V2S for macOS · Settings save automatically").font(.system(size: 13)).foregroundStyle(V2SPalette.mutedText)
                    Spacer()
                    Button("Restore Defaults", role: .destructive) { showResetConfirmation = true }
                    Button("Remove Local Data", role: .destructive) { showDeleteConfirmation = true }
                }.padding(.top, 2)
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .font(.system(size: 14))
        .foregroundStyle(V2SPalette.text)
        .preferredColorScheme(.dark)
        .tint(V2SPalette.cyan)
        .background(V2SPalette.background)
        .sheet(isPresented: $showingPrivacy) {
            VStack {
                V2SPrivacyView(model: model)
                Button("Done") { showingPrivacy = false }.padding()
            }.frame(width: 780, height: 720)
        }
        .sheet(isPresented: $showingOpenSourceNotices) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Open-source licenses and notices").font(.title2.bold())
                ScrollView {
                    Text(V2SOpenSourceNotices.text)
                        .font(.system(size: 13)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button("Done") { showingOpenSourceNotices = false }
            }.padding(24).frame(width: 780, height: 720)
                .foregroundStyle(V2SPalette.text).background(V2SPalette.background)
        }
        .confirmationDialog("Withdraw privacy consent?", isPresented: $showingWithdrawConsent, titleVisibility: .visible) {
            Button("Withdraw and disconnect", role: .destructive) { model.withdrawPrivacyConsent() }
            Button("Cancel", role: .cancel) { }
        } message: { Text("V2S will stop network features and its VPN. Requests already in progress may finish. Your Apple subscription remains active until you cancel it with Apple.") }
        .onAppear { settings = model.settings }
        .confirmationDialog("Remove V2S local data before uninstalling?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Remove Local Data", role: .destructive) { Task { await model.removeLocalData() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Disconnects V2S and removes saved servers, provider credentials, settings and local diagnostic history. This cannot be undone. Apple subscription ownership is preserved; billing is not cancelled. This does not delete app bundles, development files, backups or Trash.")
        }
        .confirmationDialog("Enable automatic public-server discovery?", isPresented: $showingDiscoveryConsent, titleVisibility: .visible) {
            Button("Enable public discovery") { settings.communityDiscoveryEnabled = true }
            Button("Read privacy and public-server notice") { showingPrivacy = true }
            Button("Cancel", role: .cancel) { }
        } message: { Text(V2SPublicServerNotice.text) }
        .onChange(of: settings) { _, updated in model.updateSettings(updated) }
        .confirmationDialog("Restore V2S settings defaults?", isPresented: $showResetConfirmation, titleVisibility: .visible) {
            Button("Restore Defaults", role: .destructive) { settings = V2SSettings() }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Your server profiles and subscriptions will not be removed.") }
    }

    private var titleBlock: some View {
        HStack(spacing: 13) {
            Image("V2SLogo").resizable().scaledToFit().frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text("Settings").font(.system(size: 25, weight: .bold, design: .rounded))
                Text("Control how V2S connects on this Mac.").font(.callout).foregroundStyle(V2SPalette.secondaryText)
            }
        }.padding(.bottom, 2)
    }

    private func section<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Label(title, systemImage: icon).font(.system(size: 12, weight: .bold)).tracking(1).foregroundStyle(Color(red: 0.32, green: 0.82, blue: 0.95))
            content()
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.075, green: 0.09, blue: 0.125), in: RoundedRectangle(cornerRadius: 15))
    }
}
