import Foundation
import Darwin
import Security

struct V2SProfile: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var protocolName: String
    var server: String
    var port: Int
    var shareLink: String
    var sourceID: UUID?
    var sourceName: String?
    var latencyMilliseconds: Int?
    var communityCatalogVersion: Int? = nil
    var isCommunity: Bool?
    var isV2SOperated: Bool?
    var city: String? = nil
    var countryCode: String?
    var isPremium: Bool? = nil
}

extension V2SProfile {
    /// Presentation-only labels; never derive a city from an endpoint hostname.
    func displayLocation(language: String? = nil) -> String {
        let locale = Locale(identifier: language ?? "en")
        let cleanName = Self.safeLocationLabel(name, endpoint: server)
        let first = name.uppercased().split(whereSeparator: { !$0.isLetter }).first.map(String.init)
        let aliases: [String: String] = ["CA":"CA","NL":"NL","TR":"TR","US":"US","USA":"US","BG":"BG","DE":"DE","GB":"GB","UK":"GB","FR":"FR","IR":"IR","SG":"SG","JP":"JP","AU":"AU"]
        let code = countryCode?.uppercased() ?? first.flatMap { aliases[$0] }
        let country = code.flatMap { locale.localizedString(forRegionCode: $0) }
        let cleanCity = city.flatMap { Self.safeLocationLabel($0, endpoint: server) }
        if let country { return [country, cleanCity].compactMap { $0 }.joined(separator: " · ") }
        return cleanCity ?? cleanName ?? "Location not provided"
    }

    private static func safeLocationLabel(_ value: String, endpoint: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 100,
              !text.lowercased().contains(endpoint.lowercased()),
              !text.contains("://"), !text.contains("@"), !text.contains(":"),
              text.range(of: #"(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}|\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b"#, options: .regularExpression) == nil,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return text
    }
}

struct V2SSubscription: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var url: String
    var lastUpdated: Date?
    var usage: V2SSubscriptionUsage? = nil
}

struct V2SSubscriptionUsage: Codable, Hashable {
    var uploadBytes: Int64
    var downloadBytes: Int64
    var totalBytes: Int64?
    var expiryDate: Date?

    var usedBytes: Int64 {
        let (sum, overflow) = max(0, uploadBytes).addingReportingOverflow(max(0, downloadBytes))
        return overflow ? Int64.max : sum
    }

    var fractionUsed: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, max(0, Double(usedBytes) / Double(totalBytes)))
    }

    var remainingBytes: Int64? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return max(0, totalBytes - min(usedBytes, totalBytes))
    }
}

struct V2SSubscriptionDownload {
    var profiles: [V2SProfile]
    var usage: V2SSubscriptionUsage?
}

struct V2SData: Codable {
    var profiles: [V2SProfile] = []
    var subscriptions: [V2SSubscription] = []

    mutating func removeLegacyCommunityProfiles() -> Bool {
        let count = profiles.count
        profiles.removeAll { $0.isCommunity == true && $0.communityCatalogVersion != 3 }
        return count != profiles.count
    }

    mutating func replacePremiumProfiles(with verifiedProfiles: [V2SProfile]) {
        let existing = Dictionary(profiles.filter { $0.isPremium == true }
            .map { ($0.shareLink, $0) }, uniquingKeysWith: { first, _ in first })
        profiles.removeAll { $0.isPremium == true }
        profiles.append(contentsOf: verifiedProfiles.map { profile in
            var value = profile
            if let saved = existing[profile.shareLink] {
                value.id = saved.id
                value.latencyMilliseconds = saved.latencyMilliseconds
            }
            value.isPremium = true
            value.isV2SOperated = true
            return value
        })
    }
}

enum V2SIPPreference: String, Codable, CaseIterable, Identifiable {
    case ipv4
    case ipv6
    case automatic

    var id: String { rawValue }
}

enum V2SDNSPreset: String, Codable, CaseIterable, Identifiable {
    case cloudflareGoogle
    case cloudflare
    case google
    case quad9
    case system
    case custom

    var id: String { rawValue }
    var title: String {
        switch self {
        case .cloudflareGoogle: "Cloudflare + Google"
        case .cloudflare: "Cloudflare"
        case .google: "Google"
        case .quad9: "Quad9"
        case .system: "System DNS"
        case .custom: "Custom"
        }
    }

    var servers: [String] {
        switch self {
        case .cloudflareGoogle: ["1.1.1.1", "8.8.8.8"]
        case .cloudflare: ["1.1.1.1", "1.0.0.1"]
        case .google: ["8.8.8.8", "8.8.4.4"]
        case .quad9: ["9.9.9.9", "149.112.112.112"]
        case .system, .custom: []
        }
    }
}

struct V2SSettings: Codable, Equatable {
    var languageCode: String? = nil
    var preferredIP: V2SIPPreference = .ipv4
    var dnsPreset: V2SDNSPreset = .cloudflareGoogle
    var customDNS = ""
    var routingEnabled = true
    var bypassPrivateNetworks = true
    // Optional so settings saved by older V2S builds decode safely. macOS
    // traffic enforcement is opt-in, matching the working V2Teh Mac client.
    var includeAllNetworks: Bool? = nil
    var disconnectOnSleep = true
    var onDemand = false
    var autoConnect: Bool? = nil
    var muxEnabled = false
    var fragmentationEnabled = false
    var fragmentationPackets = "tlshello"
    var fragmentationLength = "100-200"
    var fragmentationInterval = "10-20"
    var insecureSubscriptionCertificates = false
    var refreshSubscriptionsWhileOpen = true
    var subscriptionRefreshHours = 6
    var communityDiscoveryEnabled = false

    var autoConnectEnabled: Bool { autoConnect ?? false }

    var validationIssue: String? {
        if dnsPreset == .custom {
            let values = customDNS.split(whereSeparator: { $0 == "," || $0.isWhitespace })
            if values.isEmpty || values.contains(where: { !Self.isIPAddress(String($0)) }) {
                return "Enter one or more valid IPv4 or IPv6 addresses for custom DNS."
            }
        }
        if fragmentationEnabled {
            let patterns: [(String, String)] = [
                (fragmentationPackets, #"^(tlshello|1-8|1-16|1-32|1-64|1-128|1-256|1-512|tlshello,1-)$"#),
                (fragmentationLength, #"^\d{1,4}-\d{1,4}$"#),
                (fragmentationInterval, #"^\d{1,4}-\d{1,4}$"#)
            ]
            if patterns.contains(where: { value, pattern in
                value.range(of: pattern, options: .regularExpression) == nil
            }) {
                return "Check the TLS fragmentation values or turn fragmentation off."
            }
        }
        return nil
    }

    var dnsServers: [String] {
        if dnsPreset == .custom {
            return customDNS.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
        }
        return dnsPreset.servers
    }

    private static func isIPAddress(_ value: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return value.withCString { inet_pton(AF_INET, $0, &v4) == 1 }
            || value.withCString { inet_pton(AF_INET6, $0, &v6) == 1 }
    }
}

enum V2SStoreError: LocalizedError {
    case secureStoreUnavailable

    var errorDescription: String? {
        "V2S could not access secure profile storage. Check the shared Keychain capability and try again."
    }
}

enum V2SStore {
    // Introduced additively: a marker-less older installation is migrated,
    // never treated as an uninstall. Only a surviving secure marker with a
    // missing app preference indicates a later fresh installation/reset.
    static func prepareInstallation() throws {
        let key = "v2s.installation.marker"
        guard UserDefaults.standard.string(forKey: key) == nil else { return }
        if readSecureData(account: "installation-marker") != nil {
            try removeLocalConfiguration()
        }
        let marker = UUID().uuidString
        guard writeSecureData(Data(marker.utf8), account: "installation-marker") else {
            throw V2SStoreError.secureStoreUnavailable
        }
        UserDefaults.standard.set(marker, forKey: key)
    }
    static let appGroup = "group.ca.irisbuddy.v2s.shared"
    private static let service = "ca.irisbuddy.v2s.shared-data"
    private static let account = "profiles-and-subscriptions"
    private static let settingsAccount = "settings"
    private static let activeProfileAccount = "active-profile"
    private static let settingsKey = "v2s.settings"
    private static let activeProfileKey = "v2s.activeProfile"
    private static let connectedProfileKey = "v2s.connected.profileID"
    private static var accessGroup: String? {
        guard let task = SecTaskCreateFromSelf(nil),
              let groups = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil) as? [String],
              let configured = Bundle.main.object(forInfoDictionaryKey: "V2SKeychainAccessGroup") as? String,
              groups.contains(configured) else { return nil }
        return configured
    }

    // Settings and selected-profile state are shared through the existing
    // Keychain access group. macOS app-group containers require a registered
    // Developer Portal capability, which is not present in the current profile.
    static var defaults: UserDefaults? { .standard }

    private static var legacyGroupDefaults: UserDefaults? {
        guard FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) != nil else { return nil }
        return UserDefaults(suiteName: appGroup)
    }

    static func loadData() throws -> V2SData {
        let stored = fetchSecureData(account: account)
        guard let data = stored.data else {
            if stored.status == errSecItemNotFound { return V2SData() }
            throw V2SStoreError.secureStoreUnavailable
        }
        do { return try JSONDecoder().decode(V2SData.self, from: data) }
        catch { throw V2SStoreError.secureStoreUnavailable }
    }

    static func saveData(_ value: V2SData) throws {
        let data: Data
        do { data = try JSONEncoder().encode(value) }
        catch { throw V2SStoreError.secureStoreUnavailable }
        guard writeSecureData(data, account: account) else { throw V2SStoreError.secureStoreUnavailable }
        NotificationCenter.default.post(name: .v2sDataDidChange, object: nil)
    }

    static func removeLocalConfiguration() throws {
        for item in [account, settingsAccount, activeProfileAccount, "installation-marker"] {
            guard let query = secureQuery(account: item) else { throw V2SStoreError.secureStoreUnavailable }
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw V2SStoreError.secureStoreUnavailable }
        }
        for key in [settingsKey, activeProfileKey, connectedProfileKey] {
            defaults?.removeObject(forKey: key)
            legacyGroupDefaults?.removeObject(forKey: key)
        }
        URLCache.shared.removeAllCachedResponses()
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
        legacyGroupDefaults?.removePersistentDomain(forName: appGroup)
    }

    static func loadSettings() -> V2SSettings {
        if let data = readSecureData(account: settingsAccount),
           let settings = try? JSONDecoder().decode(V2SSettings.self, from: data) { return settings }
        let legacyData = legacyGroupDefaults?.data(forKey: settingsKey) ?? UserDefaults.standard.data(forKey: settingsKey)
        guard let legacyData,
              let settings = try? JSONDecoder().decode(V2SSettings.self, from: legacyData) else { return V2SSettings() }
        _ = writeSecureData(legacyData, account: settingsAccount)
        legacyGroupDefaults?.removeObject(forKey: settingsKey)
        UserDefaults.standard.removeObject(forKey: settingsKey)
        return settings
    }

    static func saveSettings(_ settings: V2SSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        guard writeSecureData(data, account: settingsAccount) else {
            return
        }
        defaults?.removeObject(forKey: settingsKey)
    }

    static var activeProfileID: UUID? {
        get {
            if let data = readSecureData(account: activeProfileAccount),
               let value = String(data: data, encoding: .utf8),
               let id = UUID(uuidString: value) { return id }
            let value = legacyGroupDefaults?.string(forKey: activeProfileKey)
                ?? UserDefaults.standard.string(forKey: activeProfileKey)
            guard let value, let id = UUID(uuidString: value) else { return nil }
            _ = writeSecureData(Data(value.utf8), account: activeProfileAccount)
            legacyGroupDefaults?.removeObject(forKey: activeProfileKey)
            UserDefaults.standard.removeObject(forKey: activeProfileKey)
            return id
        }
        set {
            if let newValue {
                _ = writeSecureData(Data(newValue.uuidString.utf8), account: activeProfileAccount)
            } else {
                _ = deleteSecureData(account: activeProfileAccount)
            }
            legacyGroupDefaults?.removeObject(forKey: activeProfileKey)
            defaults?.removeObject(forKey: activeProfileKey)
        }
    }

    static func saveActiveProfileID(_ profileID: UUID) throws {
        guard writeSecureData(Data(profileID.uuidString.utf8), account: activeProfileAccount) else {
            throw V2SStoreError.secureStoreUnavailable
        }
    }

    static var connectedProfileID: UUID? {
        get {
            guard let value = defaults?.string(forKey: connectedProfileKey) else { return nil }
            return UUID(uuidString: value)
        }
        set { defaults?.set(newValue?.uuidString, forKey: connectedProfileKey) }
    }

    private static func secureQuery(account: String) -> [String: Any]? {
        // Never silently fall back to the process-private default Keychain:
        // the app and packet-tunnel extension must share this exact group.
        guard let accessGroup else { return nil }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup
        ]
    }

    private static func readSecureData(account: String) -> Data? {
        fetchSecureData(account: account).data
    }

    private static func fetchSecureData(account: String) -> (data: Data?, status: OSStatus) {
        guard var query = secureQuery(account: account) else {
            return (nil, errSecMissingEntitlement)
        }
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status == errSecSuccess ? result as? Data : nil, status)
    }

    private static func writeSecureData(_ data: Data, account: String) -> Bool {
        guard let query = secureQuery(account: account) else { return false }
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    private static func deleteSecureData(account: String) -> Bool {
        guard let query = secureQuery(account: account) else { return false }
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

enum V2SCommunityService {
    static let endpoint = URL(string: "https://hostinger.v2teh.com/v2s/api/v1/community/servers?catalog=macos-1")!
    static let maxBytes = 2 * 1024 * 1024
    static let maxEntries = 10
    static let resultLimit = 10
    static let publicSourceLabels: Set<String> = [
        "Alirewa", "Morpheus Iran", "EbraSha", "Barry", "Radikal",
        "Mosifree REALITY", "Amin Iran", "Vira", "Irancell"
    ]
    static let communitySourceID = UUID(uuidString: "B2D927E6-A1EE-4D0C-A275-791E3D97C2C0")!

    static func download() async throws -> (profiles: [V2SProfile], sourceCount: Int) {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("V2S/macOS", forHTTPHeaderField: "User-Agent")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        let delegate = CommunityNoRedirectDelegate()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url?.scheme == "https", http.url?.host == endpoint.host,
              http.expectedContentLength <= maxBytes else {
            throw CommunityError.downloadFailed
        }
        var data = Data()
        for try await byte in stream {
            guard data.count < maxBytes else { throw CommunityError.downloadFailed }
            data.append(byte)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["schema_version"] as? Int == 1,
              let generated = root["generated_at"] as? TimeInterval,
              let expires = root["expires_at"] as? TimeInterval,
              let sourceTotal = root["source_total"] as? Int,
              let sourcesOK = root["sources_ok"] as? Int,
              let entries = root["entries"] as? [[String: Any]], entries.count <= maxEntries
        else { throw CommunityError.invalidFeed }
        let now = Date().timeIntervalSince1970
        guard generated > 0, generated <= now + 180, expires >= now,
              expires - generated <= 16 * 60, sourceTotal >= 0, sourceTotal <= 9,
              root["catalog"] as? String == "macos-1",
              sourcesOK >= 0, sourcesOK <= sourceTotal else { throw CommunityError.invalidFeed }
        // A rights-held catalog must not smuggle entries into a zero-source response.
        if sourceTotal == 0 {
            guard entries.isEmpty else { throw CommunityError.invalidFeed }
            return ([], 0)
        }

        var unique: [String: V2SProfile] = [:]
        for entry in entries {
            guard let source = entry["source"] as? String, Self.publicSourceLabels.contains(source),
                  entry["origin"] as? String == "community",
                  let protocolName = entry["protocol"] as? String,
                  ["VLESS", "TROJAN"].contains(protocolName.uppercased()),
                  entry["verification"] as? String == "https-proxy",
                  let proxyMS = entry["vps_https_ms"] as? Int, proxyMS >= 0,
                  let link = entry["uri"] as? String, link.utf8.count <= 16_384,
                  var profile = try? V2SXray.makeProfile(from: link) else { continue }
            profile.communityCatalogVersion = 3
            profile.isCommunity = true
            profile.isV2SOperated = (entry["operator_id"] as? String)?.lowercased() == "v2s"
                && (entry["operator_verified"] as? Bool == true)
            if let code = entry["country_code"] as? String,
               code.range(of: #"^[A-Za-z]{2}$"#, options: .regularExpression) != nil {
                profile.countryCode = code.uppercased()
            }
            profile.sourceID = communitySourceID
            profile.sourceName = "Public servers"
            let normalized = try? JSONSerialization.data(withJSONObject: profileConfiguration(from: link), options: [.sortedKeys])
            let key = normalized.map { String(decoding: $0, as: UTF8.self) } ?? profile.shareLink
            if unique[key] == nil || profile.isV2SOperated == true { unique[key] = profile }
        }
        return (Array(unique.values), sourcesOK)
    }

    private static func profileConfiguration(from link: String) throws -> [String: Any] {
        try V2SXray.configuration(from: link)
    }

    enum CommunityError: LocalizedError {
        case downloadFailed, invalidFeed
        var errorDescription: String? {
            switch self {
            case .downloadFailed: "V2S could not safely download the public server list. Try again later."
            case .invalidFeed: "The public server list is expired or has an unsupported format."
            }
        }
    }
}

private final class CommunityNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) { completionHandler(nil) }
}

extension Notification.Name {
    static let v2sDataDidChange = Notification.Name("ca.irisbuddy.v2s.dataDidChange")
}

/// A server-verified lease; stale asynchronous responses cannot reinstate it.
struct V2SPremiumLease {
    private(set) var revision: UInt64 = 0
    private(set) var expiresAt: Date?

    mutating func beginVerification() -> UInt64 {
        revision &+= 1
        return revision
    }

    mutating func invalidate() {
        revision &+= 1
        expiresAt = nil
    }

    mutating func accept(revision candidate: UInt64, expiresAt: Date, now: Date) -> Bool {
        guard candidate == revision, expiresAt > now else { return false }
        self.expiresAt = expiresAt
        return true
    }

    func isActive(at now: Date) -> Bool { expiresAt.map { $0 > now } ?? false }
}
