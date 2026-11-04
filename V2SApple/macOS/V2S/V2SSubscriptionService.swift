import Foundation
import Security

enum V2SSubscriptionService {
    private static let supportedLinkSchemes: Set<String> = ["vless", "vmess", "trojan", "ss", "shadowsocks"]

    static func isHTTPSSubscriptionURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return components.scheme?.lowercased() == "https" && components.host != nil
    }

    static func suggestedName(for value: String) -> String {
        guard let components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) else { return "Subscription" }
        let fragment = (components.fragment ?? "").removingPercentEncoding ?? components.fragment ?? ""
        let candidate = fragment.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        if !candidate.isEmpty, candidate.count <= 64, !candidate.contains("/") { return candidate }
        return components.host ?? "Subscription"
    }

    static func download(_ subscription: V2SSubscription, allowInvalidCertificate: Bool) async throws -> V2SSubscriptionDownload {
        guard let url = URL(string: subscription.url), url.scheme?.lowercased() == "https",
              url.host != nil, url.user == nil, url.password == nil
        else { throw SubscriptionError.invalidURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("text/plain, application/json;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("V2S/macOS", forHTTPHeaderField: "User-Agent")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let delegate = SubscriptionSessionDelegate(allowInvalidCertificate: allowInvalidCertificate)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              http.url?.scheme?.lowercased() == "https",
              http.expectedContentLength <= 2_000_000
        else { throw SubscriptionError.downloadFailed }

        var data = Data()
        for try await byte in stream {
            guard data.count < 2_000_000 else { throw SubscriptionError.responseTooLarge }
            data.append(byte)
        }
        let links = serverLinks(in: data)
        guard !links.isEmpty else { throw SubscriptionError.noProfiles }

        var profiles: [V2SProfile] = []
        for link in links.prefix(200) {
            guard let profile = try? V2SXray.makeProfile(from: link) else { continue }
            profiles.append(profile)
        }
        guard !profiles.isEmpty else { throw SubscriptionError.noProfiles }
        return V2SSubscriptionDownload(profiles: profiles, usage: subscriptionUsage(from: http))
    }

    static func subscriptionUsage(from response: HTTPURLResponse) -> V2SSubscriptionUsage? {
        let usageHeaderNames = ["subscription-userinfo", "subscription-user-info", "x-subscription-userinfo"]
        let header = usageHeaderNames.lazy.compactMap { name in
            response.value(forHTTPHeaderField: name)
                ?? response.allHeaderFields.first(where: { key, _ in
                    (key as? String)?.caseInsensitiveCompare(name) == .orderedSame
                })?.value as? String
        }.first
        guard let header else { return nil }
        var values: [String: Int64] = [:]
        for component in header.split(separator: ";") {
            let pair = component.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            let key = pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if let number = Int64(value), number >= 0 { values[key] = number }
        }
        guard values["upload"] != nil || values["download"] != nil || values["total"] != nil || values["expire"] != nil else { return nil }
        let expiryDate: Date? = values["expire"].flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil }
        return V2SSubscriptionUsage(
            uploadBytes: values["upload"] ?? 0,
            downloadBytes: values["download"] ?? 0,
            totalBytes: values["total"].flatMap { $0 > 0 ? $0 : nil },
            expiryDate: expiryDate
        )
    }

    private static func serverLinks(in data: Data) -> [String] {
        guard var text = String(data: data, encoding: .utf8) else { return [] }
        text = text.replacingOccurrences(of: "\u{FEFF}", with: "")
        let direct = recognizedLinks(in: text)
        if !direct.isEmpty { return direct }

        let compact = text.filter { !$0.isWhitespace }
        guard compact.count >= 16 else { return [] }
        var base64 = compact.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let decoded = Data(base64Encoded: base64),
              let decodedText = String(data: decoded, encoding: .utf8) else { return [] }
        return recognizedLinks(in: decodedText)
    }

    private static func recognizedLinks(in text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { V2SXray.normalizedShareLink(String($0)) }
            .filter { line in
                guard !line.isEmpty, !line.hasPrefix("#"),
                      let separator = line.range(of: "://") else { return false }
                return supportedLinkSchemes.contains(line[..<separator.lowerBound].lowercased())
            }
    }

    enum SubscriptionError: LocalizedError {
        case invalidURL, downloadFailed, responseTooLarge, noProfiles
        var errorDescription: String? {
            switch self {
            case .invalidURL: "Subscription links must use HTTPS and must not contain credentials in the URL."
            case .downloadFailed: "The V2S subscription provider did not return a safe HTTPS response."
            case .responseTooLarge: "The subscription response is larger than V2S allows."
            case .noProfiles: "This subscription contains no supported VLESS, VMess, Trojan, or Shadowsocks server links."
            }
        }
    }
}

private final class SubscriptionSessionDelegate: NSObject, URLSessionTaskDelegate {
    private let allowInvalidCertificate: Bool

    init(allowInvalidCertificate: Bool) {
        self.allowInvalidCertificate = allowInvalidCertificate
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard allowInvalidCertificate,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
