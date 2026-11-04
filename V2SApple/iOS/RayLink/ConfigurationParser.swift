import Foundation

enum ConfigurationParserError: LocalizedError {
    case invalidURL
    case unsupportedProtocol
    case missingServer
    case missingPort
    case missingCredentials
    case invalidEncodedConfiguration
    case noSupportedConfigurations

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The configuration URL is invalid."
        case .unsupportedProtocol:
            return "This proxy protocol is not supported."
        case .missingServer:
            return "The server address is missing."
        case .missingPort:
            return "The server port is missing."
        case .missingCredentials:
            return "Authentication information is missing."
        case .invalidEncodedConfiguration:
            return "The encoded proxy configuration is invalid."
        case .noSupportedConfigurations:
            return "No supported VLESS, VMess, Trojan, or Shadowsocks servers were found."
        }
    }
}

enum ConfigurationParser {

    static func parse(_ text: String) throws -> ProxyProfile {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercase = value.lowercased()

        if lowercase.hasPrefix("vless://") {
            return try parseVLESS(value)
        }

        if lowercase.hasPrefix("vmess://") {
            return try parseVMess(value)
        }

        if lowercase.hasPrefix("trojan://") {
            return try parseTrojan(value)
        }

        if lowercase.hasPrefix("ss://") {
            return try parseShadowsocks(value)
        }

        throw ConfigurationParserError.unsupportedProtocol
    }

    static func parseMany(_ text: String) throws -> [ProxyProfile] {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !value.isEmpty else {
            throw ConfigurationParserError.noSupportedConfigurations
        }

        if !value.contains(where: { $0.isNewline }),
           isShareLink(value) {
            return [try parse(value)]
        }

        var candidates = [value]

        if let decoded = decodeBase64String(value), decoded != value {
            candidates.append(decoded)
        }

        var links: [String] = []

        for candidate in candidates {
            links.append(contentsOf: shareLinks(in: candidate))
        }

        var seen = Set<String>()
        links = links.filter { seen.insert($0).inserted }

        var profiles: [ProxyProfile] = []
        var firstError: Error?

        for link in links {
            do {
                profiles.append(try parse(link))
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }

        guard !profiles.isEmpty else {
            throw firstError ?? ConfigurationParserError.noSupportedConfigurations
        }

        return profiles
    }

    // MARK: - VLESS

    private static func parseVLESS(_ text: String) throws -> ProxyProfile {
        guard let components = URLComponents(string: text) else {
            throw ConfigurationParserError.invalidURL
        }

        guard let server = components.host, !server.isEmpty else {
            throw ConfigurationParserError.missingServer
        }

        guard let port = components.port else {
            throw ConfigurationParserError.missingPort
        }

        guard let uuid = components.user, !uuid.isEmpty else {
            throw ConfigurationParserError.missingCredentials
        }

        let parameters = makeParameters(from: components)

        return ProxyProfile(
            name: decodedName(components.fragment, fallback: server),
            protocolType: .vless,
            server: server,
            port: port,
            uuid: uuid,
            password: nil,
            transport: transport(from: parameters["type"]),
            security: parameters["security"],
            serverName: parameters["sni"] ?? parameters["serverName"],
            fingerprint: parameters["fp"],
            publicKey: parameters["pbk"] ?? parameters["publicKey"],
            shortID: parameters["sid"] ?? parameters["shortId"],
            flow: parameters["flow"],
            encryption: parameters["encryption"],
            host: parameters["host"],
            path: parameters["path"],
            serviceName: parameters["serviceName"],
            rawLink: text
        )
    }

    // MARK: - VMess

    private static func parseVMess(_ text: String) throws -> ProxyProfile {
        let encoded = String(text.dropFirst("vmess://".count))
            .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? ""

        guard let decoded = decodeBase64String(encoded),
              let data = decoded.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let values = object as? [String: Any]
        else {
            throw ConfigurationParserError.invalidEncodedConfiguration
        }

        guard let server = stringValue(values["add"]), !server.isEmpty else {
            throw ConfigurationParserError.missingServer
        }

        guard let port = integerValue(values["port"]) else {
            throw ConfigurationParserError.missingPort
        }

        guard let uuid = stringValue(values["id"]), !uuid.isEmpty else {
            throw ConfigurationParserError.missingCredentials
        }

        let network = stringValue(values["net"])
        let tls = stringValue(values["tls"])

        return ProxyProfile(
            name: stringValue(values["ps"]) ?? server,
            protocolType: .vmess,
            server: server,
            port: port,
            uuid: uuid,
            password: nil,
            transport: transport(from: network),
            security: tls?.isEmpty == false ? tls : nil,
            serverName: stringValue(values["sni"]),
            fingerprint: stringValue(values["fp"]),
            publicKey: nil,
            shortID: nil,
            flow: nil,
            encryption: stringValue(values["scy"]),
            host: stringValue(values["host"]),
            path: stringValue(values["path"]),
            serviceName: network?.lowercased() == "grpc"
                ? stringValue(values["path"])
                : nil,
            rawLink: text
        )
    }

    // MARK: - Trojan

    private static func parseTrojan(_ text: String) throws -> ProxyProfile {
        guard let components = URLComponents(string: text) else {
            throw ConfigurationParserError.invalidURL
        }

        guard let server = components.host, !server.isEmpty else {
            throw ConfigurationParserError.missingServer
        }

        guard let port = components.port else {
            throw ConfigurationParserError.missingPort
        }

        guard let password = components.user, !password.isEmpty else {
            throw ConfigurationParserError.missingCredentials
        }

        let parameters = makeParameters(from: components)

        return ProxyProfile(
            name: decodedName(components.fragment, fallback: server),
            protocolType: .trojan,
            server: server,
            port: port,
            uuid: nil,
            password: password,
            transport: transport(from: parameters["type"]),
            security: parameters["security"] ?? "tls",
            serverName: parameters["sni"] ?? parameters["serverName"],
            fingerprint: parameters["fp"],
            publicKey: nil,
            shortID: nil,
            flow: nil,
            encryption: nil,
            host: parameters["host"],
            path: parameters["path"],
            serviceName: parameters["serviceName"],
            rawLink: text
        )
    }

    // MARK: - Shadowsocks

    private static func parseShadowsocks(_ text: String) throws -> ProxyProfile {
        let remainder = String(text.dropFirst("ss://".count))
        let parts = remainder.split(
            separator: "#",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        let nameFragment = parts.count > 1 ? String(parts[1]) : nil
        let authority = String(parts[0])
            .split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? ""

        let credentialText: String
        let endpointText: String

        if let atIndex = authority.lastIndex(of: "@") {
            let encodedCredentials = String(authority[..<atIndex])
            let normalizedCredentials =
                encodedCredentials.removingPercentEncoding
                ?? encodedCredentials
            credentialText = decodeBase64String(normalizedCredentials)
                ?? normalizedCredentials
            endpointText = String(authority[authority.index(after: atIndex)...])
        } else {
            guard let decoded = decodeBase64String(authority),
                  let atIndex = decoded.lastIndex(of: "@")
            else {
                throw ConfigurationParserError.invalidEncodedConfiguration
            }

            credentialText = String(decoded[..<atIndex])
            endpointText = String(decoded[decoded.index(after: atIndex)...])
        }

        guard let separator = credentialText.firstIndex(of: ":") else {
            throw ConfigurationParserError.missingCredentials
        }

        let method = String(credentialText[..<separator])
        let password = String(credentialText[credentialText.index(after: separator)...])

        guard !method.isEmpty, !password.isEmpty else {
            throw ConfigurationParserError.missingCredentials
        }

        guard let endpoint = URLComponents(
            string: "ss://placeholder@\(endpointText)"
        ), let server = endpoint.host, !server.isEmpty else {
            throw ConfigurationParserError.missingServer
        }

        guard let port = endpoint.port else {
            throw ConfigurationParserError.missingPort
        }

        return ProxyProfile(
            name: decodedName(nameFragment, fallback: server),
            protocolType: .shadowsocks,
            server: server,
            port: port,
            uuid: nil,
            password: password,
            transport: .tcp,
            security: method,
            serverName: nil,
            fingerprint: nil,
            publicKey: nil,
            shortID: nil,
            flow: nil,
            encryption: method,
            host: nil,
            path: nil,
            serviceName: nil,
            rawLink: text
        )
    }

    // MARK: - Helpers

    private static func makeParameters(
        from components: URLComponents
    ) -> [String: String] {
        var parameters: [String: String] = [:]

        for item in components.queryItems ?? [] {
            if let value = item.value {
                parameters[item.name] = value
            }
        }

        return parameters
    }

    private static func transport(from rawValue: String?) -> TransportType {
        switch rawValue?.lowercased() {
        case "ws", "websocket":
            return .websocket
        case "grpc":
            return .grpc
        case "xhttp", "httpupgrade", "splithttp":
            return .xhttp
        default:
            return .tcp
        }
    }

    private static func decodedName(
        _ fragment: String?,
        fallback: String
    ) -> String {
        guard let fragment, !fragment.isEmpty else {
            return fallback
        }

        return fragment.removingPercentEncoding ?? fragment
    }

    private static func decodeBase64String(_ value: String) -> String? {
        var normalized = value
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let remainder = normalized.count % 4
        if remainder != 0 {
            normalized.append(String(repeating: "=", count: 4 - remainder))
        }

        guard let data = Data(base64Encoded: normalized),
              let decoded = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return decoded
    }

    private static func shareLinks(in text: String) -> [String] {
        let lineLinks = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter(isShareLink)

        if !lineLinks.isEmpty {
            return lineLinks
        }

        guard let expression = try? NSRegularExpression(
            pattern: #"(?i)(?:vless|vmess|trojan|ss)://[^\s]+"#
        ) else {
            return []
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: text) else {
                return nil
            }
            return String(text[swiftRange])
        }
    }

    nonisolated private static func isShareLink(_ value: String) -> Bool {
        let lowercase = value.lowercased()
        return lowercase.hasPrefix("vless://")
            || lowercase.hasPrefix("vmess://")
            || lowercase.hasPrefix("trojan://")
            || lowercase.hasPrefix("ss://")
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String {
            return value
        }
        if let value = value as? NSNumber {
            return value.stringValue
        }
        return nil
    }

    private static func integerValue(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        if let value = value as? String {
            return Int(value)
        }
        return nil
    }
}
