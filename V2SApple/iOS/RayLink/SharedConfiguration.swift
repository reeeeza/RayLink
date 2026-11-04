import Foundation
#if os(macOS)
import Security
#endif

extension Notification.Name {
    static let v2tehProfilesDidChange = Notification.Name(
        "com.rezaeskandari.V2Teh.profilesDidChange"
    )
}

enum SharedConfiguration {

    #if os(macOS)
    // A Team-ID-prefixed group is the native macOS app-group form. Keeping the
    // Mac app and its tunnel in their own container prevents macOS from
    // treating access to the iOS container as access to another app's data.
    static let appGroup = "4GL535W92X.com.rezaeskandari.V2TehMac.shared"
    #else
    static let appGroup = "group.ca.irisbuddy.v2s"
    #endif
    static let activeProfileKey = "raylink.activeProfile"

    private static let profilesKey = "raylink.profiles"
    private static let settingsKey = "v2teh.settings"
    private static let communityAcknowledgementKey = "v2teh.communityDiscoveryAcknowledged"
#if os(macOS)
    private static let profileKeychainService = "com.rezaeskandari.V2TehMac.profiles"
    private static let profileKeychainAccessGroup = "4GL535W92X.com.rezaeskandari.V2TehMac.shared"
#endif

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroup)
    }

    // MARK: - Active profile shared with the tunnel extension

    static func save(profile: ProxyProfile) throws {
        let data = try JSONEncoder().encode(profile)

#if os(macOS)
        try saveSecureData(data, for: activeProfileKey)
        defaults?.removeObject(forKey: activeProfileKey)
#else
        guard let defaults else {
            throw SharedConfigurationError.appGroupUnavailable
        }

        defaults.set(data, forKey: activeProfileKey)
#endif
    }

    static func loadProfile() throws -> ProxyProfile {
#if os(macOS)
        if let data = try loadSecureData(for: activeProfileKey) {
            let profile = try JSONDecoder().decode(ProxyProfile.self, from: data)
            defaults?.removeObject(forKey: activeProfileKey)
            return profile
        }
        if let data = defaults?.data(forKey: activeProfileKey) {
            let profile = try JSONDecoder().decode(ProxyProfile.self, from: data)
            try saveSecureData(data, for: activeProfileKey)
            defaults?.removeObject(forKey: activeProfileKey)
            return profile
        }
        throw SharedConfigurationError.profileNotFound
#else
        guard let defaults else {
            throw SharedConfigurationError.appGroupUnavailable
        }

        guard let data = defaults.data(forKey: activeProfileKey) else {
            throw SharedConfigurationError.profileNotFound
        }

        return try JSONDecoder().decode(ProxyProfile.self, from: data)
#endif
    }

    static func removeActiveProfile() {
#if os(macOS)
        deleteSecureData(for: activeProfileKey)
#endif
        defaults?.removeObject(forKey: activeProfileKey)
    }

    static var hasAcknowledgedCommunityRisk: Bool {
        defaults?.bool(forKey: communityAcknowledgementKey) ?? false
    }

    static func acknowledgeCommunityRisk() {
        defaults?.set(true, forKey: communityAcknowledgementKey)
    }

    // MARK: - Saved server list

    static func loadProfiles() throws -> [ProxyProfile] {
#if os(macOS)
        if let data = try loadSecureData(for: profilesKey) {
            let profiles = try JSONDecoder().decode([ProxyProfile].self, from: data)
            if let activeData = defaults?.data(forKey: activeProfileKey),
               (try? JSONDecoder().decode(ProxyProfile.self, from: activeData)) != nil {
                try saveSecureData(activeData, for: activeProfileKey)
                defaults?.removeObject(forKey: activeProfileKey)
            }
            defaults?.removeObject(forKey: profilesKey)
            return profiles
        }
        if let data = defaults?.data(forKey: profilesKey) {
            let profiles = try JSONDecoder().decode([ProxyProfile].self, from: data)
            if let activeData = defaults?.data(forKey: activeProfileKey),
               (try? JSONDecoder().decode(ProxyProfile.self, from: activeData)) != nil {
                try saveSecureData(activeData, for: activeProfileKey)
                defaults?.removeObject(forKey: activeProfileKey)
            }
            try saveSecureData(data, for: profilesKey)
            defaults?.removeObject(forKey: profilesKey)
            return profiles
        }

        if let activeData = defaults?.data(forKey: activeProfileKey),
           let activeProfile = try? JSONDecoder().decode(ProxyProfile.self, from: activeData) {
            let profileData = try JSONEncoder().encode([activeProfile])
            try saveSecureData(activeData, for: activeProfileKey)
            try saveSecureData(profileData, for: profilesKey)
            defaults?.removeObject(forKey: activeProfileKey)
            return [activeProfile]
        }
        if let activeProfile = try? loadProfile() {
            try save(profiles: [activeProfile])
            return [activeProfile]
        }
        return []
#else
        guard let defaults else {
            throw SharedConfigurationError.appGroupUnavailable
        }

        if let data = defaults.data(forKey: profilesKey) {
            return try JSONDecoder().decode([ProxyProfile].self, from: data)
        }

        // Migrate the original single-profile storage without losing it.
        if let activeData = defaults.data(forKey: activeProfileKey),
           let activeProfile = try? JSONDecoder().decode(
               ProxyProfile.self,
               from: activeData
           ) {
            try save(profiles: [activeProfile])
            return [activeProfile]
        }

        return []
#endif
    }

    static func add(profiles importedProfiles: [ProxyProfile]) throws -> [ProxyProfile] {
        var savedProfiles = try loadProfiles()
        var identities = Set(savedProfiles.map(profileIdentity))

        for profile in importedProfiles {
            let identity = profileIdentity(profile)

            if identities.insert(identity).inserted {
                savedProfiles.append(profile)
            }
        }

        try save(profiles: savedProfiles)
        return savedProfiles
    }

    @discardableResult
    static func removeProfile(id: UUID) throws -> [ProxyProfile] {
        var savedProfiles = try loadProfiles()
        savedProfiles.removeAll { $0.id == id }
        try save(profiles: savedProfiles)

        if (try? loadProfile().id) == id {
            if let replacement = savedProfiles.first {
                try save(profile: replacement)
            } else {
                removeActiveProfile()
            }
        }

        return savedProfiles
    }

    @discardableResult
    static func replaceProfiles(
        forSubscription sourceID: UUID,
        with importedProfiles: [ProxyProfile]
    ) throws -> [ProxyProfile] {
        let activeProfile = try? loadProfile()
        var savedProfiles = try loadProfiles()
        savedProfiles.removeAll { $0.sourceID == sourceID }

        var identities = Set(savedProfiles.map(profileIdentity))
        let uniqueImports = importedProfiles.filter {
            identities.insert(profileIdentity($0)).inserted
        }
        savedProfiles.append(contentsOf: uniqueImports)
        try save(profiles: savedProfiles)

        if activeProfile?.sourceID == sourceID {
            if let replacement = uniqueImports.first {
                try save(profile: replacement)
            } else if let replacement = savedProfiles.first {
                try save(profile: replacement)
            } else {
                removeActiveProfile()
            }
        }

        return savedProfiles
    }

    @discardableResult
    static func removeProfiles(subscriptionID: UUID) throws -> [ProxyProfile] {
        let activeProfile = try? loadProfile()
        var savedProfiles = try loadProfiles()
        savedProfiles.removeAll { $0.sourceID == subscriptionID }
        try save(profiles: savedProfiles)

        if activeProfile?.sourceID == subscriptionID {
            if let replacement = savedProfiles.first {
                try save(profile: replacement)
            } else {
                removeActiveProfile()
            }
        }

        return savedProfiles
    }

    private static func save(profiles: [ProxyProfile]) throws {
#if os(macOS)
        let data = try JSONEncoder().encode(profiles)
        try saveSecureData(data, for: profilesKey)
        defaults?.removeObject(forKey: profilesKey)
        NotificationCenter.default.post(name: .v2tehProfilesDidChange, object: nil)
#else
        guard let defaults else {
            throw SharedConfigurationError.appGroupUnavailable
        }

        let data = try JSONEncoder().encode(profiles)
        defaults.set(data, forKey: profilesKey)
        NotificationCenter.default.post(name: .v2tehProfilesDidChange, object: nil)
#endif
    }

#if os(macOS)
    private static func secureQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: profileKeychainService,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: profileKeychainAccessGroup
        ]
    }

    private static func loadSecureData(for key: String) throws -> Data? {
        var query = secureQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw SharedConfigurationError.secureStorageUnavailable
        }
        return data
    }

    private static func saveSecureData(_ data: Data, for key: String) throws {
        let query = secureQuery(for: key)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess else {
                throw SharedConfigurationError.secureStorageUnavailable
            }
        } else if updateStatus != errSecSuccess {
            throw SharedConfigurationError.secureStorageUnavailable
        }
    }

    private static func deleteSecureData(for key: String) {
        SecItemDelete(secureQuery(for: key) as CFDictionary)
    }
#endif

    nonisolated private static func profileIdentity(_ profile: ProxyProfile) -> String {
        if let rawLink = profile.rawLink?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !rawLink.isEmpty {
            return rawLink
        }

        return [
            profile.protocolType.rawValue,
            profile.server.lowercased(),
            String(profile.port),
            profile.uuid ?? "",
            profile.password ?? ""
        ].joined(separator: "|")
    }

    // MARK: - Settings shared with the tunnel extension

    static func loadSettings() -> V2TehSettings {
        guard let data = defaults?.data(forKey: settingsKey),
              let settings = try? JSONDecoder().decode(
                V2TehSettings.self,
                from: data
              )
        else {
            return .defaults
        }

        return settings
    }

    static func save(settings: V2TehSettings) throws {
        guard let defaults else {
            throw SharedConfigurationError.appGroupUnavailable
        }

        defaults.set(try JSONEncoder().encode(settings), forKey: settingsKey)
    }

    static func removeAllAppData() {
#if os(macOS)
        deleteSecureData(for: activeProfileKey)
        deleteSecureData(for: profilesKey)
#endif
        defaults?.removeObject(forKey: activeProfileKey)
        defaults?.removeObject(forKey: profilesKey)
        defaults?.removeObject(forKey: settingsKey)
        defaults?.removeObject(forKey: communityAcknowledgementKey)
        URLCache.shared.removeAllCachedResponses()
        NotificationCenter.default.post(name: .v2tehProfilesDidChange, object: nil)
    }
}

enum SharedConfigurationError: LocalizedError {
    case profileNotFound
    case appGroupUnavailable
    case secureStorageUnavailable

    var errorDescription: String? {
        switch self {
        case .profileNotFound:
            return "No proxy profile has been selected."
        case .appGroupUnavailable:
            return "The V2Teh App Group is unavailable."
        case .secureStorageUnavailable:
            return "V2S could not securely read or save its server profiles. Check the app's Keychain-sharing setup and try again."
        }
    }
}
