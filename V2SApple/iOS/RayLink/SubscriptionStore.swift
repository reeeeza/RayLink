import Foundation
import Security

struct SubscriptionSource: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var lastUpdated = Date()
    var serverCount: Int
    var usage: SubscriptionUsage? = nil
}

enum SubscriptionStoreError: LocalizedError {
    case keychainFailure
    case sourceNotFound

    var errorDescription: String? {
        switch self {
        case .keychainFailure:
            return "The private subscription URL could not be saved securely."
        case .sourceNotFound:
            return "The saved subscription is no longer available. Import it again."
        }
    }
}

enum SubscriptionStore {
    static func prepareInstallation() {
        let key = "v2s.installation.marker"
        guard UserDefaults.standard.string(forKey: key) == nil else { return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.rezaeskandari.V2S.installation",
            kSecAttrAccount as String: "marker"]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecItemNotFound else { return }
        if status == errSecSuccess {
            SharedConfiguration.removeAllAppData()
            removeAll()
            SafeLogStore.removeAll()
        }
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(UUID().uuidString.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { return }
        }
        UserDefaults.standard.set(UUID().uuidString, forKey: key)
    }
    private static let metadataKey = "v2teh.subscriptionSources"
    private static let keychainService = "com.rezaeskandari.V2S.subscriptions"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: SharedConfiguration.appGroup)
    }

    static func loadSources() -> [SubscriptionSource] {
        guard let data = defaults?.data(forKey: metadataKey),
              let sources = try? JSONDecoder().decode(
                [SubscriptionSource].self,
                from: data
              )
        else {
            return []
        }

        return sources.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func saveImport(
        urlString: String,
        profiles: [ProxyProfile],
        usage: SubscriptionUsage? = nil
    ) throws -> (SubscriptionSource, [ProxyProfile]) {
        var sources = loadSources()
        let existingSource = sources.first { source in
            loadPrivateURL(for: source.id) == urlString
        }

        var source = existingSource ?? SubscriptionSource(
            name: sourceName(from: urlString),
            serverCount: profiles.count
        )
        source.name = sourceName(from: urlString)
        source.lastUpdated = Date()
        source.serverCount = profiles.count
        source.usage = usage

        try savePrivateURL(urlString, for: source.id)

        sources.removeAll { $0.id == source.id }
        sources.append(source)
        try save(sources: sources)

        let taggedProfiles = profiles.map { profile in
            var tagged = profile
            tagged.sourceID = source.id
            tagged.sourceName = source.name
            return tagged
        }

        _ = try SharedConfiguration.replaceProfiles(
            forSubscription: source.id,
            with: taggedProfiles
        )

        return (source, taggedProfiles)
    }

    static func refresh(_ source: SubscriptionSource) async throws -> SubscriptionSource {
        guard let urlString = loadPrivateURL(for: source.id) else {
            throw SubscriptionStoreError.sourceNotFound
        }

        let imported = try await SubscriptionImporter.importSubscription(
            from: urlString
        )
        let result = try saveImport(
            urlString: urlString,
            profiles: imported.profiles,
            usage: imported.usage
        )
        return result.0
    }

    static func remove(_ source: SubscriptionSource) throws {
        var sources = loadSources()
        sources.removeAll { $0.id == source.id }
        try save(sources: sources)
        deletePrivateURL(for: source.id)
        _ = try SharedConfiguration.removeProfiles(subscriptionID: source.id)
    }

    static func removeAll() {
        for source in loadSources() {
            deletePrivateURL(for: source.id)
        }
        defaults?.removeObject(forKey: metadataKey)
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: keychainService] as CFDictionary)
    }

    private static func save(sources: [SubscriptionSource]) throws {
        guard let defaults else {
            throw SharedConfigurationError.appGroupUnavailable
        }
        defaults.set(try JSONEncoder().encode(sources), forKey: metadataKey)
    }

    private static func sourceName(from value: String) -> String {
        guard let components = URLComponents(string: value) else {
            return "Subscription"
        }

        if let fragment = components.fragment?.removingPercentEncoding,
           !fragment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(fragment.prefix(80))
        }

        return String((components.host ?? "Subscription").prefix(80))
    }

    private static func savePrivateURL(_ value: String, for id: UUID) throws {
        let account = id.uuidString
        let data = Data(value.utf8)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]

        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )

        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess else {
                throw SubscriptionStoreError.keychainFailure
            }
        } else if updateStatus != errSecSuccess {
            throw SubscriptionStoreError.keychainFailure
        }
    }

    private static func loadPrivateURL(for id: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    private static func deletePrivateURL(for id: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: id.uuidString
        ]
        SecItemDelete(query as CFDictionary)
    }
}
