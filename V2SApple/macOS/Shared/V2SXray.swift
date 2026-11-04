import Foundation
import LibXray

enum V2SXrayError: LocalizedError {
    case engineUnavailable
    case invalidResponse(String)
    case commandFailed(String)
    case unsupportedProfile

    var errorDescription: String? {
        switch self {
        case .engineUnavailable: "The V2S VPN engine is unavailable."
        case .invalidResponse(let operation): "The V2S VPN engine returned an invalid response while \(operation)."
        case .commandFailed(let operation): "The V2S VPN engine could not \(operation)."
        case .unsupportedProfile: "This server profile is not supported by V2S."
        }
    }
}

enum V2SXray {
    private static let engineLock = NSLock()

    /// Corrects a common clipboard/UI artifact such as `vless: vless://…`
    /// without changing the actual URI or any credentials in it.
    static func normalizedShareLink(_ value: String) -> String {
        let link = value.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ["vless", "vmess", "trojan", "ss", "shadowsocks"] {
            guard link.count >= scheme.count + 1,
                  link.prefix(scheme.count + 1).lowercased() == "\(scheme):" else { continue }
            let remainder = link.dropFirst(scheme.count + 1)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if remainder.lowercased().hasPrefix("\(scheme)://") { return remainder }
        }
        return link
    }

    static func normalizedShareLinksText(_ value: String) -> String {
        value.replacingOccurrences(of: "\u{FEFF}", with: "")
            .components(separatedBy: .newlines)
            .map(normalizedShareLink)
            .joined(separator: "\n")
    }

    static func makeProfile(from shareLink: String) throws -> V2SProfile {
        let normalizedLink = normalizedShareLink(shareLink)
        let root = try configuration(from: normalizedLink)
        let outbounds = root["outbounds"] as? [[String: Any]] ?? []
        guard let outbound = outbounds.first else { throw V2SXrayError.unsupportedProfile }
        let settings = outbound["settings"] as? [String: Any] ?? [:]
        let vnext = (settings["vnext"] as? [[String: Any]])?.first
        let servers = (settings["servers"] as? [[String: Any]])?.first
        guard let server = (vnext?["address"] as? String) ?? (servers?["address"] as? String) ?? (settings["address"] as? String),
              let port = (vnext?["port"] as? Int) ?? (servers?["port"] as? Int) ?? (settings["port"] as? Int)
        else { throw V2SXrayError.unsupportedProfile }
        let protocolName = outbound["protocol"] as? String ?? "server"
        let fallbackName = "\(protocolName.uppercased()) · \(server)"
        return V2SProfile(name: suggestedProfileName(from: normalizedLink) ?? fallbackName, protocolName: protocolName,
                          server: server, port: port, shareLink: normalizedLink)
    }

    static func suggestedProfileName(from shareLink: String) -> String? {
        if let fragment = URLComponents(string: shareLink)?.fragment,
           let decoded = fragment.removingPercentEncoding {
            let name = decoded.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            if !name.isEmpty, name.count <= 120 { return name }
        }

        guard shareLink.lowercased().hasPrefix("vmess://"),
              let encoded = shareLink.components(separatedBy: "://").dropFirst().first?.components(separatedBy: "#").first else { return nil }
        var base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for key in ["ps", "remarks", "name"] {
            guard let candidate = object[key] as? String else { continue }
            let name = candidate.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            if !name.isEmpty, name.count <= 120 { return name }
        }
        return nil
    }

    static func call(_ method: String, payload: [String: Any] = [:]) throws -> Any {
        engineLock.lock()
        defer { engineLock.unlock() }
        var request: [String: Any] = ["apiVersion": 2, "method": method]
        if !payload.isEmpty { request["payload"] = payload }
        let data = try JSONSerialization.data(withJSONObject: request)
        var cString = Array(String(decoding: data, as: UTF8.self).utf8CString)
        guard let pointer = cString.withUnsafeMutableBufferPointer({ CGoInvoke($0.baseAddress) }) else {
            throw V2SXrayError.engineUnavailable
        }
        defer { CGoFree(pointer) }
        guard let bytes = String(validatingUTF8: pointer),
              let response = try? JSONSerialization.jsonObject(with: Data(bytes.utf8)) as? [String: Any]
        else { throw V2SXrayError.invalidResponse(Self.safeOperation(for: method)) }
        let succeeded: Bool
        if let value = response["success"] as? Bool {
            succeeded = value
        } else if let value = response["success"] as? NSNumber {
            succeeded = value.boolValue
        } else {
            throw V2SXrayError.invalidResponse(Self.safeOperation(for: method))
        }
        guard succeeded else { throw V2SXrayError.commandFailed(Self.safeOperation(for: method)) }
        // libXray's successful command methods (notably runXray and
        // stopXray) may return an envelope without a `data` field. Treat
        // that as a successful void result; requiring data here makes the
        // tunnel tear down immediately after Xray has started.
        return response["data"] ?? NSNull()
    }

    private static func safeOperation(for method: String) -> String {
        switch method {
        case "convertShareLinksToXrayJson": "convert the selected server configuration"
        case "runXray": "start the VPN engine"
        case "getXrayState": "check whether the VPN engine started"
        case "stopXray": "stop the VPN engine"
        default: "complete a VPN engine operation"
        }
    }

    static func isRunning() throws -> Bool {
        let result = try call("getXrayState")
        if let state = result as? [String: Any] {
            if let running = state["running"] as? Bool { return running }
            if let running = state["running"] as? NSNumber { return running.boolValue }
        }
        if let running = result as? Bool { return running }
        if let running = result as? NSNumber { return running.boolValue }
        throw V2SXrayError.invalidResponse("check whether the VPN engine started")
    }

    static func configuration(from shareLink: String) throws -> [String: Any] {
        let normalizedLink = normalizedShareLink(shareLink)
        let result = try call("convertShareLinksToXrayJson", payload: ["text": normalizedLink])
        let configuration: [String: Any]
        if let text = result as? String, let data = text.data(using: .utf8) {
            configuration = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        } else {
            configuration = result as? [String: Any] ?? [:]
        }
        guard let outbounds = configuration["outbounds"] as? [[String: Any]],
              let outbound = outbounds.first,
              let protocolName = outbound["protocol"] as? String,
              ["vless", "vmess", "trojan", "shadowsocks"].contains(protocolName.lowercased())
        else { throw V2SXrayError.unsupportedProfile }
        try requireEncrypted(outbound)
        return configuration
    }

    static func buildTunnelConfiguration(
        profile: V2SProfile,
        settings: V2SSettings,
        descriptor: Int,
        serverAddressOverride: String? = nil
    ) throws -> String {
        var root = try configuration(from: profile.shareLink)
        let outbounds = root["outbounds"] as? [[String: Any]] ?? []
        guard let first = outbounds.first else { throw V2SXrayError.unsupportedProfile }
        var taggedOutbounds: [[String: Any]] = []
        for (index, var outbound) in outbounds.enumerated() {
            outbound.removeValue(forKey: "sendThrough")
            outbound["tag"] = index == 0 ? "v2s-proxy" : "v2s-proxy-\(index + 1)"
            if index == 0 {
                if let serverAddressOverride {
                    var outboundSettings = outbound["settings"] as? [String: Any] ?? [:]
                    for key in ["vnext", "servers"] {
                        guard var servers = outboundSettings[key] as? [[String: Any]] else { continue }
                        for serverIndex in servers.indices {
                            servers[serverIndex]["address"] = serverAddressOverride
                        }
                        outboundSettings[key] = servers
                    }
                    if outboundSettings["address"] is String {
                        outboundSettings["address"] = serverAddressOverride
                    }
                    outbound["settings"] = outboundSettings
                }
                var stream = outbound["streamSettings"] as? [String: Any] ?? [:]
                let security = (stream["security"] as? String ?? "").lowercased()
                let securityKey = security == "reality" ? "realitySettings" : "tlsSettings"
                if security == "tls" || security == "reality" {
                    var tls = stream[securityKey] as? [String: Any] ?? [:]
                    if (tls["serverName"] as? String ?? "").isEmpty { tls["serverName"] = profile.server }
                    tls["allowInsecure"] = false
                    stream[securityKey] = tls
                    outbound["streamSettings"] = stream
                }
                var mux = outbound["mux"] as? [String: Any] ?? [:]
                mux["enabled"] = settings.muxEnabled
                mux["concurrency"] = 8
                outbound["mux"] = mux
                try Self.requireEncrypted(outbound)
            }
            taggedOutbounds.append(outbound)
        }
        _ = first

        let direct: [String: Any] = ["tag": "v2s-direct", "protocol": "freedom", "settings": [:]]
        let block: [String: Any] = ["tag": "v2s-block", "protocol": "blackhole", "settings": ["response": ["type": "none"]]]
        taggedOutbounds.append(contentsOf: [direct, block])
        root["outbounds"] = taggedOutbounds

        root["env"] = ["xray.tun.fd": String(descriptor)]
        let gateway = ["10.77.0.2/24", "fd00::2/64"]
        root["inbounds"] = [[
            "tag": "v2s-tun",
            "protocol": "tun",
            // LibXray attaches to the utun descriptor supplied by macOS.
            // Keep the advertised interface name aligned with that existing
            // descriptor, matching the previously working V2Teh Mac client.
            "settings": ["name": "utun", "mtu": 1500, "gateway": gateway],
            "sniffing": ["enabled": true, "destOverride": ["http", "tls", "quic"]]
        ]]
        root["log"] = ["loglevel": "warning"]

        if !settings.dnsServers.isEmpty {
            root["dns"] = [
                "servers": settings.dnsServers,
                "queryStrategy": settings.preferredIP == .ipv4 ? "UseIPv4" : (settings.preferredIP == .ipv6 ? "UseIPv6" : "UseIP")
            ]
        } else {
            root.removeValue(forKey: "dns")
        }

        if settings.routingEnabled {
            var rules: [[String: Any]] = []
            if settings.bypassPrivateNetworks {
                rules.append([
                    "type": "field",
                    "ip": ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.0/8", "169.254.0.0/16", "::1/128", "fc00::/7", "fe80::/10"],
                    "outboundTag": "v2s-direct"
                ])
            }
            root["routing"] = ["domainStrategy": "IPIfNonMatch", "rules": rules]
        } else {
            root.removeValue(forKey: "routing")
        }

        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func requireEncrypted(_ outbound: [String: Any]) throws {
        let protocolName = (outbound["protocol"] as? String ?? "").lowercased()
        if protocolName == "shadowsocks" {
            let settings = outbound["settings"] as? [String: Any] ?? [:]
            let server = (settings["servers"] as? [[String: Any]])?.first ?? [:]
            let method = (server["method"] as? String ?? "").lowercased()
            let password = server["password"] as? String ?? ""
            let methods: Set<String> = [
                "aes-128-gcm", "aes-256-gcm", "chacha20-ietf-poly1305",
                "xchacha20-ietf-poly1305", "2022-blake3-aes-128-gcm",
                "2022-blake3-aes-256-gcm", "2022-blake3-chacha20-poly1305"
            ]
            guard methods.contains(method), !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw V2SXrayError.unsupportedProfile
            }
            return
        }
        let stream = outbound["streamSettings"] as? [String: Any] ?? [:]
        let security = (stream["security"] as? String ?? "").lowercased()
        guard security == "tls" || security == "reality" else { throw V2SXrayError.unsupportedProfile }
        if let tls = stream["tlsSettings"] as? [String: Any], tls["allowInsecure"] as? Bool == true {
            throw V2SXrayError.unsupportedProfile
        }
    }
}
