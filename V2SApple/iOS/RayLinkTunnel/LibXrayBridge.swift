import Foundation
import LibXray

enum LibXrayBridgeError: LocalizedError {

    case encodingFailed
    case invocationFailed
    case invalidResponse
    case xrayError(String)

    var errorDescription: String? {

        switch self {

        case .encodingFailed:
            return "Could not encode the libXray request."

        case .invocationFailed:
            return "libXray returned no response."

        case .invalidResponse:
            return "libXray returned an invalid response."

        case .xrayError(let message):
            return message
        }
    }
}

enum LibXrayBridge {

    // MARK: - Core Invocation

    private static func invoke(
        method: String,
        payload: [String: Any]? = nil
    ) throws -> Any {

        var request: [String: Any] = [
            "apiVersion": 2,
            "method": method
        ]

        if let payload {
            request["payload"] = payload
        }

        guard
            JSONSerialization.isValidJSONObject(request)
        else {
            throw LibXrayBridgeError.encodingFailed
        }

        let requestData =
            try JSONSerialization.data(
                withJSONObject: request
            )

        guard
            let requestString =
                String(
                    data: requestData,
                    encoding: .utf8
                )
        else {
            throw LibXrayBridgeError.encodingFailed
        }

        var requestBytes =
            Array(requestString.utf8CString)

        let responsePointer =
            requestBytes.withUnsafeMutableBufferPointer {
                buffer in

                CGoInvoke(
                    buffer.baseAddress
                )
            }

        guard let responsePointer else {
            throw LibXrayBridgeError.invocationFailed
        }

        defer {
            CGoFree(responsePointer)
        }

        let responseString =
            String(
                cString: responsePointer
            )

        guard
            let responseData =
                responseString.data(
                    using: .utf8
                )
        else {
            throw invalidResponseError(
                method: method,
                response: responseString
            )
        }

        let responseObject: Any

        do {

            responseObject =
                try JSONSerialization.jsonObject(
                    with: responseData
                )

        } catch {

            throw invalidResponseError(
                method: method,
                response: responseString
            )
        }

        guard
            let envelope =
                responseObject as? [String: Any]
        else {
            throw invalidResponseError(
                method: method,
                response: responseString
            )
        }

        let success: Bool

        if let boolean =
            envelope["success"] as? Bool {

            success = boolean

        } else if let number =
            envelope["success"] as? NSNumber {

            success = number.boolValue

        } else {

            throw invalidResponseError(
                method: method,
                response: responseString
            )
        }

        guard success else {

            let message =
                envelope["error"] as? String
                ?? "Unknown Xray error."

            throw xrayFailureError(
                method: method,
                message: message
            )
        }

        return envelope["data"] ?? NSNull()
    }

    // MARK: - Credential-Safe Errors

    private static func invalidResponseError(
        method: String,
        response: String
    ) -> LibXrayBridgeError {

        switch method {

        case "stopXray",
             "xrayVersion",
             "getXrayState":

            let visibleResponse =
                response.isEmpty
                ? "<empty>"
                : response

            return .xrayError(
                "Invalid \(method) response: \(visibleResponse)"
            )

        case "convertShareLinksToXrayJson":

            return .xrayError(
                "libXray share-link conversion returned an invalid response. Details hidden for credential safety."
            )

        case "runXray":

            return .xrayError(
                "libXray runXray returned an invalid response. Details hidden for credential safety."
            )

        default:

            return .invalidResponse
        }
    }

    private static func sanitizedDiagnostic(
        _ message: String
    ) -> String {

        var sanitized = message

        let redactions: [
            (pattern: String, replacement: String)
        ] = [

            (
                #"(?i)(?:vless|trojan|vmess|ss)://[^\s]+"#,
                "<redacted-proxy-link>"
            ),

            (
                #"\b[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}\b"#,
                "<redacted-uuid>"
            ),

            (
                #"(?i)(["']?(?:password|passwd|uuid|id|publicKey|privateKey|shortId|pbk|sid|server|address|host|sni)["']?\s*[:=]\s*)["']?[^"',\s}\]]+["']?"#,
                "$1<redacted>"
            )
        ]

        for redaction in redactions {

            guard
                let expression =
                    try? NSRegularExpression(
                        pattern: redaction.pattern
                    )
            else {
                continue
            }

            let range =
                NSRange(
                    sanitized.startIndex..<sanitized.endIndex,
                    in: sanitized
                )

            sanitized =
                expression.stringByReplacingMatches(
                    in: sanitized,
                    range: range,
                    withTemplate: redaction.replacement
                )
        }

        if sanitized.isEmpty {
            return "Unknown Xray error."
        }

        return String(sanitized.prefix(1000))
    }

    private static func xrayFailureError(
        method: String,
        message: String
    ) -> LibXrayBridgeError {

        switch method {

        case "convertShareLinksToXrayJson":

            return .xrayError(
                "libXray share-link conversion failed. Details hidden for credential safety."
            )

        case "runXray":

            return .xrayError(
                "libXray runXray failed: \(sanitizedDiagnostic(message))"
            )

        default:

            let safeMessage =
                message.isEmpty
                ? "Unknown Xray error."
                : message

            return .xrayError(safeMessage)
        }
    }

    // MARK: - Version

    static func xrayVersion() throws -> String {

        let data =
            try invoke(
                method: "xrayVersion"
            )

        if
            let dictionary =
                data as? [String: Any],
            let version =
                dictionary["version"] as? String,
            !version.isEmpty {

            return version
        }

        if
            let version = data as? String,
            !version.isEmpty {

            return version
        }

        throw LibXrayBridgeError.xrayError(
            "Invalid xrayVersion data: \(String(describing: data))"
        )
    }

    // MARK: - Share-Link Conversion

    static func convertShareLink(
        _ link: String
    ) throws -> String {

        let convertedData =
            try invoke(
                method:
                    "convertShareLinksToXrayJson",
                payload: [
                    "text": link
                ]
            )

        if
            let jsonString =
                convertedData as? String,
            !jsonString.isEmpty {

            return jsonString
        }

        guard
            JSONSerialization.isValidJSONObject(
                convertedData
            )
        else {
            throw LibXrayBridgeError.xrayError(
                "libXray share-link conversion returned unsupported data. Details hidden for credential safety."
            )
        }

        let jsonData =
            try JSONSerialization.data(
                withJSONObject: convertedData
            )

        guard
            let jsonString =
                String(
                    data: jsonData,
                    encoding: .utf8
                ),
            !jsonString.isEmpty
        else {
            throw LibXrayBridgeError.xrayError(
                "Could not serialize the converted Xray configuration."
            )
        }

        return jsonString
    }

    // MARK: - Run Xray

    static func runXray(
        json: String
    ) throws {

        _ = try invoke(
            method: "runXray",
            payload: [
                "xrayJson": json
            ]
        )
    }

    // MARK: - Stop Xray

    static func stopXray() throws {

        _ = try invoke(
            method: "stopXray"
        )
    }

    // MARK: - State

    static func isRunning() throws -> Bool {

        let data =
            try invoke(
                method: "getXrayState"
            )

        if let dictionary =
            data as? [String: Any] {

            if let running =
                dictionary["running"] as? Bool {

                return running
            }

            if let running =
                dictionary["running"] as? NSNumber {

                return running.boolValue
            }
        }

        if let running = data as? Bool {
            return running
        }

        if let running = data as? NSNumber {
            return running.boolValue
        }

        throw LibXrayBridgeError.xrayError(
            "Invalid getXrayState data: \(String(describing: data))"
        )
    }
}
