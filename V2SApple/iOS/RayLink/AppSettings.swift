import Foundation
import Darwin

enum PreferredIPType: String, Codable, CaseIterable, Identifiable, Hashable {
    case automatic
    case ipv4
    case ipv6

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .ipv4: return "IPv4"
        case .ipv6: return "IPv6"
        }
    }
}

enum DNSPreset: String, Codable, CaseIterable, Identifiable, Hashable {
    case cloudflareGoogle
    case cloudflare
    case google
    case quad9
    case local
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cloudflareGoogle: return "Cloudflare + Google"
        case .cloudflare: return "Cloudflare"
        case .google: return "Google"
        case .quad9: return "Quad9"
        case .local: return "System DNS"
        case .custom: return "Custom DNS"
        }
    }

    func servers(customText: String) -> [String] {
        switch self {
        case .cloudflareGoogle:
            return ["1.1.1.1", "8.8.8.8"]
        case .cloudflare:
            return ["1.1.1.1", "1.0.0.1"]
        case .google:
            return ["8.8.8.8", "8.8.4.4"]
        case .quad9:
            return ["9.9.9.9", "149.112.112.112"]
        case .local:
            return []
        case .custom:
            return customText
                .components(separatedBy: CharacterSet(charactersIn: ",\n "))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
    }
}

enum RoutingDomainStrategy: String, Codable, CaseIterable, Identifiable, Hashable {
    case asIs
    case ipIfNonMatch
    case ipOnDemand

    var id: String { rawValue }

    var title: String {
        switch self {
        case .asIs: return "Domain names"
        case .ipIfNonMatch: return "Resolve when needed"
        case .ipOnDemand: return "Resolve before matching"
        }
    }

    var xrayValue: String {
        switch self {
        case .asIs: return "AsIs"
        case .ipIfNonMatch: return "IPIfNonMatch"
        case .ipOnDemand: return "IPOnDemand"
        }
    }
}

enum TrafficRuleAction: String, Codable, CaseIterable, Identifiable, Hashable {
    case proxy
    case direct
    case block

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct TrafficRulePreset: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var action: TrafficRuleAction
    var domains: [String] = []
    var ipRanges: [String] = []
}

struct TunnelPreferences: Codable, Equatable {
    var preferredIPType: PreferredIPType = .ipv4
    var excludeAPNs = true
    var excludeCellularServices = true
    var excludeLocalNetworks = true
    var disconnectOnSleep = false
    var includeAllNetworks = false
    var onDemandEnabled = false
}

struct DNSPreferences: Codable, Equatable {
    var preset: DNSPreset = .cloudflareGoogle
    var customServers = ""
}

struct RoutingPreferences: Codable, Equatable {
    var enabled = true
    var domainStrategy: RoutingDomainStrategy = .ipIfNonMatch
    var bypassPrivateNetworks = true
}

struct FragmentationPreferences: Codable, Equatable {
    var enabled = false
    var packets = "tlshello"
    var length = "100-200"
    var interval = "10-20"
}

struct SubscriptionPreferences: Codable, Equatable {
    var backgroundRefresh = false
    var refreshIntervalHours = 6
    var notifyOnUpdate = false
#if os(macOS)
    var userAgent = "V2S/macOS"
#else
    var userAgent = "V2S/iOS"
#endif
    var allowInsecure = false
}

struct GeoResourcePreferences: Codable, Equatable {
    static let defaultGeoSiteURL = "https://github.com/reeeeza/v2teh-geo/releases/latest/download/geosite.dat"
    static let defaultGeoIPURL = "https://github.com/reeeeza/v2teh-geo/releases/latest/download/geoip.dat"
    static let defaultChecksumURL = "https://github.com/reeeeza/v2teh-geo/releases/latest/download/SHA256SUMS"

    var trimUnusedResources = true
    var useCustomURLs = false
    var geoSiteURL = Self.defaultGeoSiteURL
    var geoIPURL = Self.defaultGeoIPURL
    var checksumURL = Self.defaultChecksumURL

    init() {}

    mutating func restoreV2TehSource() {
        useCustomURLs = false
        geoSiteURL = Self.defaultGeoSiteURL
        geoIPURL = Self.defaultGeoIPURL
        checksumURL = Self.defaultChecksumURL
    }

    private enum CodingKeys: String, CodingKey {
        case trimUnusedResources
        case useCustomURLs
        case geoSiteURL
        case geoIPURL
        case checksumURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        trimUnusedResources = try container.decodeIfPresent(
            Bool.self,
            forKey: .trimUnusedResources
        ) ?? true
        useCustomURLs = try container.decodeIfPresent(
            Bool.self,
            forKey: .useCustomURLs
        ) ?? false

        if useCustomURLs {
            geoSiteURL = try container.decodeIfPresent(
                String.self,
                forKey: .geoSiteURL
            ) ?? Self.defaultGeoSiteURL
            geoIPURL = try container.decodeIfPresent(
                String.self,
                forKey: .geoIPURL
            ) ?? Self.defaultGeoIPURL
            checksumURL = try container.decodeIfPresent(
                String.self,
                forKey: .checksumURL
            ) ?? Self.defaultChecksumURL
        } else {
            // Migrate installations that still have the former V2Fly or
            // Loyalsoldier URLs to the V2Teh-managed release automatically.
            geoSiteURL = Self.defaultGeoSiteURL
            geoIPURL = Self.defaultGeoIPURL
            checksumURL = Self.defaultChecksumURL
        }
    }
}

struct V2TehSettings: Codable, Equatable {
    var tunnel = TunnelPreferences()
    var dns = DNSPreferences()
    var routing = RoutingPreferences()
    var fragmentation = FragmentationPreferences()
    var muxEnabled = false
    var trafficRulesEnabled = false
    var trafficRulePresets: [TrafficRulePreset] = []
    var subscription = SubscriptionPreferences()
    var geoResources = GeoResourcePreferences()

    static let defaults = V2TehSettings()

    var validationIssue: String? {
        guard (1...24).contains(subscription.refreshIntervalHours) else {
            return "Subscription refresh interval must be between 1 and 24 hours."
        }

        if dns.preset == .custom {
            let servers = dns.customServers
                .components(separatedBy: CharacterSet(charactersIn: ",\n "))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !servers.isEmpty else {
                return "Add at least one DNS server IP address or choose a DNS preset."
            }
            guard servers.allSatisfy(Self.isIPAddress) else {
                return "Custom DNS accepts IPv4 or IPv6 addresses only. Check the address format."
            }
            if tunnel.preferredIPType == .ipv4,
               servers.contains(where: { $0.contains(":") }) {
                return "Your preferred IP setting disables IPv6. Choose Automatic or IPv6, or remove IPv6 DNS addresses."
            }
        }

        if fragmentation.enabled {
            let packets = fragmentation.packets.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard packets == "tlshello" || Self.isNumericRange(packets, maximum: 100) else {
                return "Fragmentation packets must be tlshello or a number/range from 1 to 100."
            }
            guard Self.isNumericRange(fragmentation.length, maximum: 4_096) else {
                return "Fragmentation length must be a number/range from 1 to 4096 bytes."
            }
            guard Self.isNumericRange(fragmentation.interval, maximum: 1_000) else {
                return "Fragmentation interval must be a number/range from 1 to 1000 ms."
            }
        }
        return nil
    }

    nonisolated private static func isIPAddress(_ value: String) -> Bool {
        var ipv4 = in_addr()
        if value.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 { return true }
        var ipv6 = in6_addr()
        return value.withCString { inet_pton(AF_INET6, $0, &ipv6) } == 1
    }

    nonisolated private static func isNumericRange(_ value: String, maximum: Int) -> Bool {
        let parts = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "-", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let lower = Int(parts[0]), lower > 0, lower <= maximum
        else { return false }
        guard parts.count == 2 else { return true }
        guard let upper = Int(parts[1]) else { return false }
        return upper >= lower && upper <= maximum
    }
}
