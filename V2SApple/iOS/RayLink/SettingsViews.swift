import SwiftUI
import Combine
import CryptoKit
import NetworkExtension

@MainActor
final class SettingsStore: ObservableObject {
    @Published var settings: V2TehSettings {
        didSet {
            do {
                try SharedConfiguration.save(settings: settings)
            } catch {
                saveError = error.localizedDescription
            }
        }
    }

    @Published private(set) var saveError: String?

    init() {
        settings = SharedConfiguration.loadSettings()
    }

    func reset() {
        settings = .defaults
    }
}

struct SettingsRootView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject private var vpn = VPNManager.shared
    @AppStorage("v2s.interfaceLanguage") private var interfaceLanguage = "system"

    @State private var showingPrivacy = false

    var body: some View {
        NavigationStack {
            List {
                Section(AppStrings.value("Language")) {
                    Picker(AppStrings.value("App Language"), selection: $interfaceLanguage) {
                        Text(AppStrings.value("System Default")).tag("system")
                        Text(AppStrings.value("English")).tag("en")
                        Text(AppStrings.value("Français")).tag("fr")
                        Text(AppStrings.value("Español")).tag("es")
                        Text(AppStrings.value("Português")).tag("pt")
                        Text(AppStrings.value("العربية")).tag("ar")
                        Text(AppStrings.value("فارسی")).tag("fa")
                        Text(AppStrings.value("Türkçe")).tag("tr")
                        Text(AppStrings.value("Deutsch")).tag("de")
                        Text(AppStrings.value("简体中文")).tag("zh-Hans")
                    }
                }
                Section(AppStrings.value("Tunnel")) {
                    NavigationLink {
                        TrafficRulesView(store: store)
                    } label: {
                        settingsLabel("Traffic Rules", icon: "arrow.triangle.branch")
                    }

                    NavigationLink {
                        RoutingSettingsView(store: store)
                    } label: {
                        settingsLabel("Routing", icon: "point.3.connected.trianglepath.dotted")
                    }

                    NavigationLink {
                        FragmentationSettingsView(store: store)
                    } label: {
                        settingsLabel("Fragmentation", icon: "rectangle.3.group")
                    }

                    NavigationLink {
                        GeoResourcesView(store: store)
                    } label: {
                        settingsLabel("Geo Resources", icon: "globe")
                    }

                    NavigationLink {
                        MuxSettingsView(store: store)
                    } label: {
                        settingsLabel("Mux", icon: "circle.hexagongrid")
                    }

                    NavigationLink {
                        TunnelSettingsView(store: store)
                    } label: {
                        settingsLabel("Tunnel Settings", icon: "desktopcomputer")
                    }

                    NavigationLink {
                        DNSSettingsView(store: store)
                    } label: {
                        settingsLabel("DNS", icon: "network")
                    }

                    Toggle(isOn: $store.settings.tunnel.onDemandEnabled) {
                        settingsLabel("On Demand", icon: "link")
                    }
                    .disabled(vpn.status == .connected || vpn.status == .connecting)
                }

                Section(AppStrings.value("Subscription")) {
                    NavigationLink {
                        SubscriptionSettingsView(store: store)
                    } label: {
                        settingsLabel("Subscription Settings", icon: "link.badge.plus")
                    }

                    NavigationLink {
                        SubscriptionListView()
                    } label: {
                        settingsLabel("Update Subscriptions", icon: "arrow.clockwise")
                    }

                    NavigationLink {
                        ServerPingView()
                    } label: {
                        settingsLabel("Ping", icon: "waveform.path.ecg")
                    }
                }

                Section(AppStrings.value("Useful")) {
                    NavigationLink {
                        CommunityView()
                    } label: {
                        settingsLabel("Community", icon: "person.2")
                    }

                    NavigationLink {
                        ConnectionHelpView()
                    } label: {
                        settingsLabel("How to Connect", icon: "questionmark.circle.fill")
                    }
                }

                Section(AppStrings.value("More")) {
                    NavigationLink {
                        URLSchemeView()
                    } label: {
                        settingsLabel("URL Scheme", icon: "link")
                    }

                    NavigationLink {
                        LogsView()
                    } label: {
                        settingsLabel("Logs", icon: "books.vertical")
                    }

                    Button {
                        showingPrivacy = true
                    } label: {
                        settingsLabel("Privacy & Data", icon: "hand.raised")
                    }
                    .foregroundStyle(.primary)

                    NavigationLink {
                        AboutAppView(store: store)
                    } label: {
                        settingsLabel("About V2S", icon: "info.square")
                    }
                }
            }
            .navigationTitle(localizedSettingsTitle)
            .sheet(isPresented: $showingPrivacy) {
                PrivacyDisclosureView(
                    requiresAcknowledgement: false,
                    onContinue: {}
                )
            }
        }
    }

    private var localizedSettingsTitle: String {
        AppStrings.value("Settings")
    }

    private func settingsLabel(
        _ title: String,
        icon: String,
        color: Color = .blue
    ) -> some View {
        Label {
            Text(AppStrings.value(title))
        } icon: {
            Image(systemName: icon).foregroundStyle(color)
        }
    }
}

struct TrafficRulesView: View {
    @ObservedObject var store: SettingsStore
    @State private var showingAddRule = false

    var body: some View {
        List {
            Section {
                Text(AppStrings.value("Find or create a traffic-rule preset for your needs."))
                    .font(.headline)

                Toggle(AppStrings.value("Enable Traffic Rules"), isOn: $store.settings.trafficRulesEnabled)
            }

            Section {
                NavigationLink {
                    CommunityRulesView(store: store)
                } label: {
                    Label(AppStrings.value("Community Rules"), systemImage: "globe")
                }
            } footer: {
                Text(AppStrings.value("Community rules are ready-made routing presets shared for common needs. Review every rule before enabling it."))
            }

            Section(AppStrings.value("Your Presets")) {
                if store.settings.trafficRulePresets.isEmpty {
                    ContentUnavailableView(AppStrings.value("No Rule Presets"),
                        systemImage: "square.stack.3d.up.slash",
                        description: Text(AppStrings.value("Choose a community preset or create your own."))
                    )
                } else {
                    ForEach(store.settings.trafficRulePresets) { rule in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(rule.name).fontWeight(.semibold)
                            Text(
                                "\(AppStrings.value(rule.action.title)) • " +
                                AppStrings.format("%d domains", [rule.domains.count]) + " • " +
                                AppStrings.format("%d IP ranges", [rule.ipRanges.count])
                            )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { offsets in
                        store.settings.trafficRulePresets.remove(atOffsets: offsets)
                    }
                }
            }
        }
        .navigationTitle(AppStrings.value("Traffic Rules"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAddRule = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAddRule) {
            AddTrafficRuleView { rule in
                store.settings.trafficRulePresets.append(rule)
            }
        }
    }
}

private struct AddTrafficRuleView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var action: TrafficRuleAction = .direct
    @State private var domains = ""
    @State private var ipRanges = ""

    let onSave: (TrafficRulePreset) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section(AppStrings.value("Preset")) {
                    TextField(AppStrings.value("Name"), text: $name)
                    Picker(AppStrings.value("Action"), selection: $action) {
                        ForEach(TrafficRuleAction.allCases) { action in
                            Text(AppStrings.value(action.title)).tag(action)
                        }
                    }
                }

                Section {
                    TextEditor(text: $domains)
                        .frame(minHeight: 100)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text(AppStrings.value("Domains"))
                } footer: {
                    Text(AppStrings.value("One Xray domain matcher per line, for example domain:example.com or regexp:.*\\.example\\.com$."))
                }

                Section {
                    TextEditor(text: $ipRanges)
                        .frame(minHeight: 90)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text(AppStrings.value("IP Ranges"))
                } footer: {
                    Text(AppStrings.value("One IP address or CIDR range per line."))
                }
            }
            .navigationTitle(AppStrings.value("New Traffic Rule"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppStrings.value("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppStrings.value("Save")) {
                        onSave(
                            TrafficRulePreset(
                                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                action: action,
                                domains: lines(domains),
                                ipRanges: lines(ipRanges)
                            )
                        )
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func lines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private struct CommunityRulesView: View {
    @ObservedObject var store: SettingsStore

    private let privateNetworks = TrafficRulePreset(
        name: "Direct Private Networks",
        action: .direct,
        ipRanges: [
            "10.0.0.0/8",
            "172.16.0.0/12",
            "192.168.0.0/16",
            "127.0.0.0/8",
            "169.254.0.0/16",
            "::1/128",
            "fc00::/7",
            "fe80::/10"
        ]
    )

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(AppStrings.value(privateNetworks.name)).font(.headline)
                    Text(AppStrings.value("Sends private and device-local address ranges directly instead of through the proxy."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Button {
                        store.settings.trafficRulePresets.append(privateNetworks)
                    } label: {
                        Text(AppStrings.value(alreadyAdded ? "Added" : "Add Preset"))
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(alreadyAdded)
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle(AppStrings.value("Community Rules"))
    }

    private var alreadyAdded: Bool {
        store.settings.trafficRulePresets.contains {
            $0.name == privateNetworks.name
        }
    }
}

struct RoutingSettingsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle(AppStrings.value("Enable Routing"), isOn: $store.settings.routing.enabled)
                Picker(AppStrings.value("Domain Strategy"), selection: $store.settings.routing.domainStrategy) {
                    ForEach(RoutingDomainStrategy.allCases) { strategy in
                        Text(AppStrings.value(strategy.title)).tag(strategy)
                    }
                }
                Toggle(AppStrings.value("Bypass Private Networks"), isOn: $store.settings.routing.bypassPrivateNetworks)
            } footer: {
                Text(AppStrings.value("Routing changes take effect the next time the tunnel connects."))
            }
        }
        .navigationTitle(AppStrings.value("Routing"))
    }
}

struct FragmentationSettingsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle(AppStrings.value("Enabled"), isOn: $store.settings.fragmentation.enabled)
                TextField(AppStrings.value("Packets"), text: $store.settings.fragmentation.packets)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField(AppStrings.value("Length (bytes)"), text: $store.settings.fragmentation.length)
                    .keyboardType(.numbersAndPunctuation)
                TextField(AppStrings.value("Interval (ms)"), text: $store.settings.fragmentation.interval)
                    .keyboardType(.numbersAndPunctuation)
            } footer: {
                Text(AppStrings.value("Advanced Xray fragmentation. Defaults: tlshello, 100–200 bytes, 10–20 ms. Invalid values can prevent connection."))
            }
        }
        .navigationTitle(AppStrings.value("Fragmentation"))
    }
}

struct MuxSettingsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle(AppStrings.value("Enabled"), isOn: $store.settings.muxEnabled)
            } footer: {
                Text(AppStrings.value("Multiplexes compatible connections through fewer proxy connections. Reconnect to apply."))
            }
        }
        .navigationTitle(AppStrings.value("Mux"))
    }
}

struct TunnelSettingsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section {
                Picker(AppStrings.value("Preferred IP Type"), selection: $store.settings.tunnel.preferredIPType) {
                    ForEach(PreferredIPType.allCases) { type in
                        Text(AppStrings.value(type.title)).tag(type)
                    }
                }

                Toggle(AppStrings.value("Exclude APNs"), isOn: $store.settings.tunnel.excludeAPNs)
                Toggle(AppStrings.value("Exclude Cellular Services"), isOn: $store.settings.tunnel.excludeCellularServices)
                Toggle(AppStrings.value("Exclude Local Networks"), isOn: $store.settings.tunnel.excludeLocalNetworks)
                Toggle(AppStrings.value("Disconnect on Sleep"), isOn: $store.settings.tunnel.disconnectOnSleep)
                Toggle(AppStrings.value("Disallow Services Bypass"), isOn: $store.settings.tunnel.includeAllNetworks)
            } footer: {
                Text(AppStrings.value("Disallow Services Bypass asks iOS to route nearly all eligible traffic through V2S. APNs, cellular-service and local-network exclusions apply to that mode."))
            }
        }
        .navigationTitle(AppStrings.value("Tunnel"))
    }
}

struct DNSSettingsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section {
                Picker(AppStrings.value("DNS"), selection: $store.settings.dns.preset) {
                    ForEach(DNSPreset.allCases) { preset in
                        Text(AppStrings.value(preset.title)).tag(preset)
                    }
                }

                if store.settings.dns.preset == .custom {
                    TextField(AppStrings.value("1.1.1.1, 9.9.9.9"),
                        text: $store.settings.dns.customServers,
                        axis: .vertical
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                }
            } footer: {
                Text(AppStrings.value("DNS changes are applied on the next connection. System DNS leaves DNS selection to iOS."))
            }
        }
        .navigationTitle(AppStrings.value("DNS"))
    }
}

struct SubscriptionSettingsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle(AppStrings.value("Enable Background Refresh"), isOn: $store.settings.subscription.backgroundRefresh)

                Stepper(
                    "Refresh Interval: \(store.settings.subscription.refreshIntervalHours) h",
                    value: $store.settings.subscription.refreshIntervalHours,
                    in: 1...24
                )

                Toggle(AppStrings.value("Notify on Update"), isOn: $store.settings.subscription.notifyOnUpdate)
            } header: {
                Text(AppStrings.value("Background Updates"))
            } footer: {
                Text(AppStrings.value("The preferences are saved locally. iOS decides when background work is allowed; use Add Servers to refresh a private link manually when needed."))
            }

            Section(AppStrings.value("User Agent")) {
                TextField(AppStrings.value("V2S/iOS"), text: $store.settings.subscription.userAgent)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section {
                Toggle(AppStrings.value("Allow Insecure HTTP"), isOn: $store.settings.subscription.allowInsecure)
            } footer: {
                Text(AppStrings.value("Not recommended. HTTPS protects subscription credentials while they travel to the provider."))
            }
        }
        .navigationTitle(AppStrings.value("Subscription"))
    }
}

struct GeoResourcesView: View {
    @ObservedObject var store: SettingsStore
    @StateObject private var resources = GeoResourceManager()

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image("V2SResources")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(AppStrings.value("V2S Resources"))
                            .font(.headline)
                        Text(AppStrings.value("Secure routing data maintained by V2S"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                Toggle(AppStrings.value("Trim Unused Resources"), isOn: $store.settings.geoResources.trimUnusedResources)
            } footer: {
                Text(AppStrings.value("Keep only the resource files needed by routing rules to reduce local storage."))
            }

            Section(AppStrings.value("Advanced")) {
                Toggle(AppStrings.value("Use Custom Download URLs"),
                    isOn: $store.settings.geoResources.useCustomURLs
                )
                .onChange(of: store.settings.geoResources.useCustomURLs) { _, enabled in
                    if !enabled {
                        store.settings.geoResources.restoreV2TehSource()
                    }
                }

                if store.settings.geoResources.useCustomURLs {
                    TextField(AppStrings.value("GeoSite URL"),
                        text: $store.settings.geoResources.geoSiteURL,
                        axis: .vertical
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    TextField(AppStrings.value("GeoIP URL"),
                        text: $store.settings.geoResources.geoIPURL,
                        axis: .vertical
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    TextField(AppStrings.value("SHA256SUMS URL"),
                        text: $store.settings.geoResources.checksumURL,
                        axis: .vertical
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                } else {
                    LabeledContent("Source", value: "V2S")
                    Text(AppStrings.value("V2S verifies every resource before replacing the files currently in use."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section(AppStrings.value("Local Files")) {
                Button {
                    Task {
                        await resources.updateAll(
                            geoSiteURL: store.settings.geoResources.geoSiteURL,
                            geoIPURL: store.settings.geoResources.geoIPURL,
                            checksumURL: store.settings.geoResources.checksumURL
                        )
                    }
                } label: {
                    HStack {
                        Text(AppStrings.value("Update All"))
                        Spacer()
                        if resources.isUpdating { ProgressView() }
                    }
                }
                .disabled(resources.isUpdating)

                LabeledContent("geosite.dat", value: resources.geoSiteMetadata)
                LabeledContent("geoip.dat", value: resources.geoIPMetadata)
                LabeledContent("Integrity", value: resources.integrityMetadata)
            }
        }
        .navigationTitle(AppStrings.value("Geo Resources"))
        .task { resources.refreshMetadata() }
        .alert(AppStrings.value("Geo Resources"), isPresented: resources.errorBinding) {
            Button(AppStrings.value("OK")) { resources.errorMessage = nil }
        } message: {
            Text(resources.errorMessage ?? "")
        }
    }

}

@MainActor
private final class GeoResourceManager: ObservableObject {
    @Published var isUpdating = false
    @Published var geoSiteMetadata = "Not downloaded"
    @Published var geoIPMetadata = "Not downloaded"
    @Published var integrityMetadata = "Not verified"
    @Published var errorMessage: String?

    var errorBinding: Binding<Bool> {
        Binding(
            get: { self.errorMessage != nil },
            set: { if !$0 { self.errorMessage = nil } }
        )
    }

    func updateAll(
        geoSiteURL: String,
        geoIPURL: String,
        checksumURL: String
    ) async {
        isUpdating = true
        defer { isUpdating = false }

        do {
            async let geoSiteData = download(geoSiteURL, maximumSize: 64 * 1024 * 1024)
            async let geoIPData = download(geoIPURL, maximumSize: 64 * 1024 * 1024)
            async let checksumData = download(checksumURL, maximumSize: 1024 * 1024)

            let (downloadedGeoSite, downloadedGeoIP, downloadedChecksums) = try await (
                geoSiteData,
                geoIPData,
                checksumData
            )
            let expectedHashes = try parseChecksums(downloadedChecksums)

            try verify(
                downloadedGeoSite,
                filename: "geosite.dat",
                expectedHashes: expectedHashes
            )
            try verify(
                downloadedGeoIP,
                filename: "geoip.dat",
                expectedHashes: expectedHashes
            )
            try installAtomically(
                geoSiteData: downloadedGeoSite,
                geoIPData: downloadedGeoIP,
                checksumData: downloadedChecksums
            )
            refreshMetadata()
            SafeLogStore.append("Verified V2S geo routing resources updated")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshMetadata() {
        geoSiteMetadata = metadata(for: "geosite.dat")
        geoIPMetadata = metadata(for: "geoip.dat")
        integrityMetadata = localFilesAreVerified() ? "Verified" : "Not verified"
    }

    private func download(_ value: String, maximumSize: Int) async throws -> Data {
        guard let url = URL(string: value), url.scheme?.lowercased() == "https" else {
            throw GeoResourceError.secureURLRequired
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 45
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        let (data, response) = try await URLSession(configuration: configuration).data(for: request)

        guard let response = response as? HTTPURLResponse,
              (200...299).contains(response.statusCode),
              !data.isEmpty,
              data.count <= maximumSize
        else {
            throw GeoResourceError.downloadFailed
        }

        return data
    }

    private func parseChecksums(_ data: Data) throws -> [String: String] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw GeoResourceError.invalidChecksumManifest
        }

        var hashes: [String: String] = [:]

        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2 else { continue }

            let hash = String(fields[0]).lowercased()
            let rawFilename = String(fields[fields.count - 1])
            let filename = rawFilename.hasPrefix("*")
                ? String(rawFilename.dropFirst())
                : rawFilename

            if hash.count == 64,
               hash.allSatisfy({ $0.isHexDigit }) {
                hashes[URL(fileURLWithPath: filename).lastPathComponent] = hash
            }
        }

        guard hashes["geosite.dat"] != nil,
              hashes["geoip.dat"] != nil else {
            throw GeoResourceError.invalidChecksumManifest
        }

        return hashes
    }

    private func verify(
        _ data: Data,
        filename: String,
        expectedHashes: [String: String]
    ) throws {
        guard let expectedHash = expectedHashes[filename] else {
            throw GeoResourceError.invalidChecksumManifest
        }

        let actualHash = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()

        guard actualHash == expectedHash else {
            throw GeoResourceError.checksumMismatch(filename)
        }
    }

    private func installAtomically(
        geoSiteData: Data,
        geoIPData: Data,
        checksumData: Data
    ) throws {
        guard let directory = resourceDirectory() else {
            throw GeoResourceError.storageUnavailable
        }

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let filenames = ["geosite.dat", "geoip.dat", "SHA256SUMS"]
        let newData = [geoSiteData, geoIPData, checksumData]
        var previousData: [String: Data?] = [:]

        for filename in filenames {
            let url = directory.appendingPathComponent(filename)
            previousData[filename] = try? Data(contentsOf: url)
        }

        do {
            for (filename, data) in zip(filenames, newData) {
                try data.write(
                    to: directory.appendingPathComponent(filename),
                    options: .atomic
                )
            }
        } catch {
            for filename in filenames {
                let url = directory.appendingPathComponent(filename)

                if let oldData = previousData[filename] ?? nil {
                    try? oldData.write(to: url, options: .atomic)
                } else {
                    try? FileManager.default.removeItem(at: url)
                }
            }

            throw GeoResourceError.installationFailed
        }
    }

    private func resourceDirectory() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: SharedConfiguration.appGroup)?
            .appendingPathComponent("GeoResources", isDirectory: true)
    }

    private func metadata(for filename: String) -> String {
        guard let url = resourceDirectory()?.appendingPathComponent(filename),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              let date = attributes[.modificationDate] as? Date
        else {
            return "Not downloaded"
        }

        return "\(ByteCountFormatter.string(fromByteCount: size.int64Value, countStyle: .file)) • \(date.formatted(date: .abbreviated, time: .omitted))"
    }

    private func localFilesAreVerified() -> Bool {
        guard let directory = resourceDirectory(),
              let checksumData = try? Data(
                contentsOf: directory.appendingPathComponent("SHA256SUMS")
              ),
              let hashes = try? parseChecksums(checksumData),
              let geoSiteData = try? Data(
                contentsOf: directory.appendingPathComponent("geosite.dat")
              ),
              let geoIPData = try? Data(
                contentsOf: directory.appendingPathComponent("geoip.dat")
              ),
              (try? verify(
                geoSiteData,
                filename: "geosite.dat",
                expectedHashes: hashes
              )) != nil,
              (try? verify(
                geoIPData,
                filename: "geoip.dat",
                expectedHashes: hashes
              )) != nil else {
            return false
        }

        return true
    }
}

private enum GeoResourceError: LocalizedError {
    case secureURLRequired
    case downloadFailed
    case invalidChecksumManifest
    case checksumMismatch(String)
    case installationFailed
    case storageUnavailable

    var errorDescription: String? {
        switch self {
        case .secureURLRequired: return "Geo resource downloads require HTTPS URLs."
        case .downloadFailed: return "The geo resource could not be downloaded safely."
        case .invalidChecksumManifest: return "The V2S checksum file is missing or invalid."
        case .checksumMismatch(let filename): return "The downloaded \(filename) did not pass V2S integrity verification. Your existing files were kept."
        case .installationFailed: return "The verified resources could not be installed. Your existing files were restored."
        case .storageUnavailable: return "The shared V2S storage is unavailable."
        }
    }
}

private struct SubscriptionListView: View {
    @ObservedObject private var vpn = VPNManager.shared
    @State private var sources = SubscriptionStore.loadSources()
    @State private var updatingIDs = Set<UUID>()
    @State private var errorMessage: String?

    var body: some View {
        List {
            if sources.isEmpty {
                ContentUnavailableView(AppStrings.value("No Saved Subscriptions"),
                    systemImage: "link.badge.plus",
                    description: Text(AppStrings.value("Use + on the Connect screen to import an HTTPS subscription."))
                )
            } else {
                ForEach(sources) { source in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(source.name).fontWeight(.semibold)
                                Text(AppStrings.format("%d supported servers", [source.serverCount]))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if updatingIDs.contains(source.id) {
                                ProgressView()
                            } else {
                                Button {
                                    Task { await refresh(source) }
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                }
                                .buttonStyle(.borderless)
                                .disabled(isConnectionActive)
                            }
                        }

                        Text("Updated \(source.lastUpdated.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                }
                .onDelete(perform: deleteSources)
            }

            Section {
                Label(AppStrings.value("Private subscription URLs are kept in Keychain and never shown in the list or app logs."), systemImage: "lock.shield")
            }
        }
        .navigationTitle(AppStrings.value("Update Subscriptions"))
        .toolbar {
            if !sources.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button(AppStrings.value("Update All")) {
                        Task { await refreshAll() }
                    }
                    .disabled(isConnectionActive || !updatingIDs.isEmpty)
                }
            }
        }
        .alert(AppStrings.value("Subscription Update"), isPresented: errorBinding) {
            Button(AppStrings.value("OK")) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var isConnectionActive: Bool {
        vpn.status == .connected
            || vpn.status == .connecting
            || vpn.status == .reasserting
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    @MainActor
    private func refresh(_ source: SubscriptionSource) async {
        updatingIDs.insert(source.id)
        defer { updatingIDs.remove(source.id) }

        do {
            _ = try await SubscriptionStore.refresh(source)
            sources = SubscriptionStore.loadSources()
            SafeLogStore.append("Subscription refreshed successfully")
        } catch {
            SafeLogStore.append("Subscription refresh failed")
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func refreshAll() async {
        for source in sources {
            await refresh(source)
        }
    }

    private func deleteSources(at offsets: IndexSet) {
        guard !isConnectionActive else {
            errorMessage = "Disconnect before deleting a subscription."
            return
        }

        do {
            for index in offsets where sources.indices.contains(index) {
                try SubscriptionStore.remove(sources[index])
            }
            sources = SubscriptionStore.loadSources()
            SafeLogStore.append("Subscription and its servers deleted")
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ServerPingView: View {

    @ObservedObject private var latencyTester = ServerLatencyTester.shared
    @State private var profiles: [ProxyProfile] = []

    var body: some View {
        List {
            if profiles.isEmpty {
                ContentUnavailableView(AppStrings.value("No Servers Added"),
                    systemImage: "server.rack",
                    description: Text(AppStrings.value("Import a server or subscription before testing latency."))
                )
            } else {
                Section {
                    Button {
                        latencyTester.testAll(profiles)
                    } label: {
                        HStack {
                            Label(AppStrings.value("Ping All Servers"), systemImage: "waveform.path.ecg")
                            Spacer()
                            if !latencyTester.testingIDs.isDisjoint(
                                with: Set(profiles.map(\.id))
                            ) {
                                ProgressView()
                            }
                        }
                    }

                    Button(AppStrings.value("Clear Results"), role: .destructive) {
                        latencyTester.clearResults()
                    }
                    .disabled(latencyTester.results.isEmpty)
                }

                Section {
                    ForEach(profiles) { profile in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(profile.name)
                                    .fontWeight(.semibold)
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
                } header: {
                    Text(AppStrings.value("Servers"))
                } footer: {
                    Text(AppStrings.value("Ping measures the TCP connection time to each server without using or displaying its proxy credentials. It tests reachability, not a complete proxy connection."))
                }
            }
        }
        .navigationTitle(AppStrings.value("Ping"))
        .task { loadProfiles() }
        .onReceive(
            NotificationCenter.default.publisher(for: .v2tehProfilesDidChange)
        ) { _ in
            loadProfiles()
        }
    }

    private func loadProfiles() {
        profiles = (try? SharedConfiguration.loadProfiles()) ?? []
    }
}

private struct CommunityView: View {
    var body: some View {
        ContentUnavailableView(AppStrings.value("V2S Community"),
            systemImage: "person.2",
            description: Text(AppStrings.value("No community account or external discussion link is configured in this build."))
        )
        .navigationTitle(AppStrings.value("Community"))
    }
}

struct DonateView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                ZStack {
                    RoundedRectangle(cornerRadius: 28)
                        .fill(
                            LinearGradient(
                                colors: [.pink.opacity(0.18), .indigo.opacity(0.12)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 132, height: 132)

                    Image(systemName: "heart.fill")
                        .font(.system(size: 54, weight: .semibold))
                        .foregroundStyle(.pink)
                }

                VStack(spacing: 8) {
                    Text(AppStrings.value("Keep V2S Open"))
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)

                    Text(AppStrings.value("V2S is free, private, and has no advertisements. Optional support can help fund testing and continued maintenance."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(alignment: .leading, spacing: 15) {
                    supportReason(
                        "Independent development",
                        icon: "hammer.fill"
                    )
                    Divider()
                    supportReason(
                        "Compatibility testing",
                        icon: "iphone.gen3.radiowaves.left.and.right"
                    )
                    Divider()
                    supportReason(
                        "Free access without tracking",
                        icon: "hand.raised.fill"
                    )
                }
                .padding(18)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 22))

                Label(AppStrings.value("Donations are not enabled in this build yet."),
                    systemImage: "info.circle"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            }
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(AppStrings.value("Support"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func supportReason(
        _ title: String,
        icon: String
    ) -> some View {
        Label {
            Text(AppStrings.value(title))
                .font(.subheadline.weight(.semibold))
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(.pink)
                .frame(width: 28)
        }
    }
}

private struct ConnectionHelpView: View {
    var body: some View {
        List {
            helpStep(1, "Open Connect and tap +.")
            helpStep(2, "Paste a supported VLESS, VMess, Trojan, Shadowsocks, or HTTPS subscription link.")
            helpStep(3, "Choose a saved server. Never share its private link or credentials.")
            helpStep(4, "Tap the power button and allow iOS to add the VPN configuration if asked.")
        }
        .navigationTitle(AppStrings.value("How to Connect"))
    }

    private func helpStep(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.headline)
                .frame(width: 30, height: 30)
                .background(.blue.opacity(0.15))
                .clipShape(Circle())
            Text(AppStrings.value(text))
        }
        .padding(.vertical, 3)
    }
}

private struct URLSchemeView: View {
    var body: some View {
        List {
            Section(AppStrings.value("Import Configuration")) {
                Text(AppStrings.value("v2teh://import/{configuration}")).font(.system(.body, design: .monospaced))
            }
            Section(AppStrings.value("Import Subscription")) {
                Text(AppStrings.value("v2teh://subscription/{url}")).font(.system(.body, design: .monospaced))
            }
            Section(AppStrings.value("Connection")) {
                Text(AppStrings.value("v2teh://connect")).font(.system(.body, design: .monospaced))
                Text(AppStrings.value("v2teh://disconnect")).font(.system(.body, design: .monospaced))
            }
            Section {
                Text(AppStrings.value("V2S registers this URL scheme. Configuration and subscription values must be percent-encoded; V2S opens the normal import screen so the user can review and confirm before anything is saved."))
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(AppStrings.value("URL Scheme"))
    }
}

private struct LogsView: View {
    @State private var entries = SafeLogStore.load()

    var body: some View {
        List {
            if entries.isEmpty {
                ContentUnavailableView(AppStrings.value("No App Events"),
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(AppStrings.value("V2S keeps only credential-safe app events on this device."))
                )
            } else {
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.message)
                        Text(entry.date.formatted(date: .abbreviated, time: .standard))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(AppStrings.value("Logs"))
        .toolbar {
            if !entries.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button(AppStrings.value("Clear")) {
                        SafeLogStore.removeAll()
                        entries = []
                    }
                }
            }
        }
    }
}

private struct AboutAppView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject private var vpn = VPNManager.shared
    @State private var showingDeleteConfirmation = false

    var body: some View {
        List {
            Section(AppStrings.value("Information")) {
                LabeledContent("Version", value: appVersion)
                LabeledContent("Xray", value: "Bundled with V2S")
                LabeledContent("Saved Servers", value: "\((try? SharedConfiguration.loadProfiles().count) ?? 0)")
            }

            Section(AppStrings.value("Privacy")) {
                Label(AppStrings.value("No advertising SDK"), systemImage: "checkmark.shield")
                Label(AppStrings.value("No analytics or persistent device ID"), systemImage: "checkmark.shield")
                Label(AppStrings.value("Configurations stay in the private App Group"), systemImage: "lock")
            }

            Section {
                Button(AppStrings.value("Delete All Local Data"), role: .destructive) {
                    showingDeleteConfirmation = true
                }
                .disabled(vpn.status == .connected || vpn.status == .connecting)
            } footer: {
                Text(AppStrings.value("Disconnect first. This removes saved servers, V2S settings and credential-safe local logs from this device."))
            }
        }
        .navigationTitle(AppStrings.value("About V2S"))
        .confirmationDialog(AppStrings.value("Delete all V2S data?"),
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(AppStrings.value("Delete All Local Data"), role: .destructive) {
                SharedConfiguration.removeAllAppData()
                SubscriptionStore.removeAll()
                SafeLogStore.removeAll()
                UserDefaults.standard.removeObject(forKey: "v2tah.hasAcknowledgedPrivacy")
                V2SSubscriptions.shared.resetLocalState()
                store.reset()
            }
            Button(AppStrings.value("Cancel"), role: .cancel) {}
        } message: {
            Text(AppStrings.value("This cannot be undone. Your Apple subscription is preserved and billing is not cancelled. Use this cleanup before uninstalling; deleting the app alone may leave Keychain entries."))
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }
}
