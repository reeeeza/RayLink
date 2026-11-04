import Foundation

enum SubscriptionImportError: LocalizedError {
    case invalidURL
    case insecureURL
    case downloadFailed
    case invalidResponse
    case responseTooLarge
    case tooManyServers
    case noSupportedServers

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The subscription URL is invalid."
        case .insecureURL:
            return "Subscription imports require a secure HTTPS URL."
        case .downloadFailed:
            return "The subscription could not be downloaded. Check the link and try again."
        case .invalidResponse:
            return "The subscription provider returned an invalid response."
        case .responseTooLarge:
            return "The subscription response is too large to import safely."
        case .tooManyServers:
            return "The subscription contains too many servers."
        case .noSupportedServers:
            return "The subscription contains no supported VLESS, VMess, Trojan, or Shadowsocks servers."
        }
    }
}

struct SubscriptionUsage: Codable, Hashable, Sendable {
    var uploadBytes: Int64
    var downloadBytes: Int64
    var totalBytes: Int64?
    var expiryDate: Date?

    var usedBytes: Int64 {
        let upload = max(0, uploadBytes)
        let download = max(0, downloadBytes)
        let (sum, overflow) = upload.addingReportingOverflow(download)
        return overflow ? Int64.max : sum
    }

    var fractionUsed: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, max(0, Double(usedBytes) / Double(totalBytes)))
    }
}

struct SubscriptionImportResult {
    var profiles: [ProxyProfile]
    var usage: SubscriptionUsage?
}

enum SubscriptionImporter {

    private static let maximumResponseSize = 2 * 1024 * 1024
    private static let maximumServerCount = 1_000

    static func isSubscriptionURL(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              components.host != nil
        else {
            return false
        }

        return scheme == "https" || scheme == "http"
    }

    static func importProfiles(from text: String) async throws -> [ProxyProfile] {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard isSubscriptionURL(value) else {
            return try ConfigurationParser.parseMany(value)
        }

        return try await importSubscription(from: value).profiles
    }

    static func importSubscription(
        from text: String
    ) async throws -> SubscriptionImportResult {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard isSubscriptionURL(value) else {
            throw SubscriptionImportError.invalidURL
        }

        return try await downloadSubscription(from: value)
    }

    private static func downloadSubscription(
        from value: String
    ) async throws -> SubscriptionImportResult {
        guard var components = URLComponents(string: value),
              components.host != nil,
              let scheme = components.scheme?.lowercased()
        else {
            throw SubscriptionImportError.invalidURL
        }

        let settings = SharedConfiguration.loadSettings().subscription

        guard scheme == "https" || (scheme == "http" && settings.allowInsecure) else {
            throw SubscriptionImportError.insecureURL
        }

        // The fragment is a local label and is never sent to the provider.
        components.fragment = nil

        guard let url = components.url else {
            throw SubscriptionImportError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("text/plain, application/octet-stream, */*", forHTTPHeaderField: "Accept")

        let safeUserAgent = settings.userAgent
            .filter { $0.isASCII && !$0.isNewline }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !safeUserAgent.isEmpty {
            request.setValue(String(safeUserAgent.prefix(100)), forHTTPHeaderField: "User-Agent")
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)

        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SubscriptionImportError.downloadFailed
        }

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode)
        else {
            throw SubscriptionImportError.invalidResponse
        }

        guard data.count <= maximumResponseSize else {
            throw SubscriptionImportError.responseTooLarge
        }

        guard let responseText = String(data: data, encoding: .utf8) else {
            throw SubscriptionImportError.invalidResponse
        }

        let profiles: [ProxyProfile]

        do {
            profiles = try ConfigurationParser.parseMany(responseText)
        } catch {
            throw SubscriptionImportError.noSupportedServers
        }

        guard !profiles.isEmpty else {
            throw SubscriptionImportError.noSupportedServers
        }

        guard profiles.count <= maximumServerCount else {
            throw SubscriptionImportError.tooManyServers
        }

        return SubscriptionImportResult(
            profiles: profiles,
            usage: subscriptionUsage(from: httpResponse)
        )
    }

    private static func subscriptionUsage(
        from response: HTTPURLResponse
    ) -> SubscriptionUsage? {
        guard let header = response.value(
            forHTTPHeaderField: "Subscription-Userinfo"
        ) else {
            return nil
        }

        var values: [String: Int64] = [:]

        for component in header.split(separator: ";") {
            let pair = component.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }

            let key = pair[0]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let value = pair[1]
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let number = Int64(value), number >= 0 {
                values[key] = number
            }
        }

        guard values["upload"] != nil
                || values["download"] != nil
                || values["total"] != nil
                || values["expire"] != nil
        else {
            return nil
        }

        let expiryDate: Date?
        if let expiry = values["expire"], expiry > 0 {
            expiryDate = Date(timeIntervalSince1970: TimeInterval(expiry))
        } else {
            expiryDate = nil
        }

        return SubscriptionUsage(
            uploadBytes: values["upload"] ?? 0,
            downloadBytes: values["download"] ?? 0,
            totalBytes: values["total"].flatMap { $0 > 0 ? $0 : nil },
            expiryDate: expiryDate
        )
    }
}
