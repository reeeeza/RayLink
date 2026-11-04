import Foundation

enum ProxyProtocol: String, Codable, CaseIterable {
    case vless
    case vmess
    case trojan
    case shadowsocks
}

enum TransportType: String, Codable {
    case tcp
    case websocket
    case grpc
    case xhttp
}

struct ProxyProfile: Codable, Identifiable, Hashable {

    var id = UUID()

    var name: String

    var protocolType: ProxyProtocol

    var server: String
    var port: Int

    // Authentication
    var uuid: String?
    var password: String?

    // Transport
    var transport: TransportType = .tcp

    // Security
    var security: String?

    // TLS / REALITY
    var serverName: String?
    var fingerprint: String?
    var publicKey: String?
    var shortID: String?

    // VLESS
    var flow: String?
    var encryption: String?

    // WebSocket / HTTP
    var host: String?
    var path: String?

    // gRPC
    var serviceName: String?

    // Subscription metadata is safe to display. The private subscription URL
    // is stored separately in Keychain and never placed in this model.
    var sourceID: UUID? = nil
    var sourceName: String? = nil

    // Original imported share link used to build the private Xray config.
    var rawLink: String? = nil
}
