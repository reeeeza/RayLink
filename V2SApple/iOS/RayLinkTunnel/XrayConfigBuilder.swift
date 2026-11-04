import Foundation

enum XrayConfigBuilderError: LocalizedError {

    case missingRawLink
    case invalidGeneratedConfig
    case invalidSettings(String)

    var errorDescription: String? {

        switch self {

        case .missingRawLink:
            return "The selected proxy profile has no original share link."

        case .invalidGeneratedConfig:
            return "The generated Xray configuration is invalid."
        case .invalidSettings(let message):
            return message
        }
    }
}

enum XrayConfigBuilder {

    static func build(
        profile: ProxyProfile,
        tunFD: Int32
    ) throws -> String {

        let appSettings = SharedConfiguration.loadSettings()

        if let issue = appSettings.validationIssue {
            throw XrayConfigBuilderError.invalidSettings(issue)
        }

        guard
            let rawLink = profile.rawLink,
            !rawLink.isEmpty
        else {
            throw XrayConfigBuilderError.missingRawLink
        }

        // Convert the imported share link into an Xray
        // configuration without logging its contents.
        let generatedJSON =
            try LibXrayBridge.convertShareLink(
                rawLink
            )

        guard
            let generatedData =
                generatedJSON.data(
                    using: .utf8
                ),
            var root =
                try JSONSerialization.jsonObject(
                    with: generatedData
                ) as? [String: Any]
        else {
            throw XrayConfigBuilderError
                .invalidGeneratedConfig
        }

        // ---------------------------------------------------------
        // Clean libXray share-link metadata
        // ---------------------------------------------------------

        guard
            var outbounds =
                root["outbounds"]
                    as? [[String: Any]],
            !outbounds.isEmpty
        else {
            throw XrayConfigBuilderError
                .invalidGeneratedConfig
        }

        for index in outbounds.indices {

            // libXray stores the node display name in
            // sendThrough during share conversion.
            //
            // Xray itself interprets sendThrough as a local
            // source IP address, so it must not be passed
            // into the live Xray configuration.
            outbounds[index]
                .removeValue(
                    forKey: "sendThrough"
                )

            // Give each outbound a safe internal tag when
            // the converted profile did not provide one.
            outbounds[index]["tag"] = index == 0
                ? "v2teh-proxy"
                : "v2teh-proxy-\(index + 1)"
        }

        outbounds[0]["mux"] = [
            "enabled": appSettings.muxEnabled,
            "concurrency": 8
        ]

        if appSettings.fragmentation.enabled {
            var streamSettings = outbounds[0]["streamSettings"]
                as? [String: Any] ?? [:]
            var socketOptions = streamSettings["sockopt"]
                as? [String: Any] ?? [:]
            socketOptions["dialerProxy"] = "v2teh-fragment"
            streamSettings["sockopt"] = socketOptions
            outbounds[0]["streamSettings"] = streamSettings

            outbounds.append([
                "tag": "v2teh-fragment",
                "protocol": "freedom",
                "settings": [
                    "fragment": [
                        "packets": safeFragmentValue(
                            appSettings.fragmentation.packets,
                            fallback: "tlshello"
                        ),
                        "length": safeFragmentValue(
                            appSettings.fragmentation.length,
                            fallback: "100-200"
                        ),
                        "interval": safeFragmentValue(
                            appSettings.fragmentation.interval,
                            fallback: "10-20"
                        )
                    ]
                ]
            ])
        }

        outbounds.append([
            "tag": "v2teh-direct",
            "protocol": "freedom",
            "settings": [:]
        ])
        outbounds.append([
            "tag": "v2teh-block",
            "protocol": "blackhole",
            "settings": ["response": ["type": "none"]]
        ])

        root["outbounds"] = outbounds

        // ---------------------------------------------------------
        // Supply the existing Apple Network Extension TUN descriptor.
        // ---------------------------------------------------------

        var environment = ["xray.tun.fd": String(tunFD)]
        if let resourcePath = geoResourcePath() {
            environment["xray.location.asset"] = resourcePath
        }
        root["env"] = environment

        // Do not enable verbose Xray logging because the
        // generated configuration contains sensitive values.
        root["log"] = [
            "loglevel": "warning"
        ]

        // ---------------------------------------------------------
        // Xray TUN inbound
        // ---------------------------------------------------------

        var gateways = ["10.77.0.2/24"]
        if appSettings.tunnel.preferredIPType != .ipv4 {
            gateways.append("fd00::2/64")
        }

        root["inbounds"] = [
            [
                "tag": "raylink-tun",
                "protocol": "tun",

                "settings": [
                    "name": "utun",
                    "mtu": 1500,
                    "gateway": gateways
                ],

                "sniffing": [
                    "enabled": true,
                    "destOverride": [
                        "http",
                        "tls",
                        "quic"
                    ]
                ]
            ]
        ]

        let dnsServers = appSettings.dns.preset.servers(
            customText: appSettings.dns.customServers
        )
        if !dnsServers.isEmpty {
            root["dns"] = [
                "servers": dnsServers,
                "queryStrategy": dnsQueryStrategy(
                    appSettings.tunnel.preferredIPType
                )
            ]
        }

        if appSettings.routing.enabled {
            root["routing"] = [
                "domainStrategy": appSettings.routing.domainStrategy.xrayValue,
                "rules": routingRules(for: appSettings)
            ]
        }

        guard
            JSONSerialization
                .isValidJSONObject(root)
        else {
            throw XrayConfigBuilderError
                .invalidGeneratedConfig
        }

        let finalData =
            try JSONSerialization.data(
                withJSONObject: root
            )

        guard
            let finalJSON =
                String(
                    data: finalData,
                    encoding: .utf8
                ),
            !finalJSON.isEmpty
        else {
            throw XrayConfigBuilderError
                .invalidGeneratedConfig
        }

        return finalJSON
    }

    private static func routingRules(
        for settings: V2TehSettings
    ) -> [[String: Any]] {
        var rules: [[String: Any]] = []

        if settings.routing.bypassPrivateNetworks {
            rules.append([
                "type": "field",
                "ip": [
                    "10.0.0.0/8",
                    "172.16.0.0/12",
                    "192.168.0.0/16",
                    "127.0.0.0/8",
                    "169.254.0.0/16",
                    "::1/128",
                    "fc00::/7",
                    "fe80::/10"
                ],
                "outboundTag": "v2teh-direct"
            ])
        }

        if settings.trafficRulesEnabled {
            for preset in settings.trafficRulePresets {
                var rule: [String: Any] = [
                    "type": "field",
                    "outboundTag": outboundTag(for: preset.action)
                ]

                let domains = preset.domains
                    .map(safeRuleValue)
                    .filter { !$0.isEmpty }
                let ipRanges = preset.ipRanges
                    .map(safeRuleValue)
                    .filter { !$0.isEmpty }

                if !domains.isEmpty { rule["domain"] = domains }
                if !ipRanges.isEmpty { rule["ip"] = ipRanges }

                if !domains.isEmpty || !ipRanges.isEmpty {
                    rules.append(rule)
                }
            }
        }

        return rules
    }

    private static func outboundTag(
        for action: TrafficRuleAction
    ) -> String {
        switch action {
        case .proxy: return "v2teh-proxy"
        case .direct: return "v2teh-direct"
        case .block: return "v2teh-block"
        }
    }

    private static func safeRuleValue(_ value: String) -> String {
        String(
            value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .filter { !$0.isNewline && $0 != "\0" }
                .prefix(500)
        )
    }

    private static func safeFragmentValue(
        _ value: String,
        fallback: String
    ) -> String {
        let safe = value
            .lowercased()
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "," }
        return safe.isEmpty ? fallback : String(safe.prefix(40))
    }

    private static func dnsQueryStrategy(
        _ type: PreferredIPType
    ) -> String {
        switch type {
        case .automatic: return "UseIP"
        case .ipv4: return "UseIPv4"
        case .ipv6: return "UseIPv6"
        }
    }

    private static func geoResourcePath() -> String? {
        guard let directory = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedConfiguration.appGroup
        )?.appendingPathComponent("GeoResources", isDirectory: true),
              FileManager.default.fileExists(atPath: directory.path)
        else {
            return nil
        }

        return directory.path
    }
}
