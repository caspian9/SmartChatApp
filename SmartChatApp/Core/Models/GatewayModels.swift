import Foundation

struct RequestFrame: Codable {
    let type: String  // "req"
    let id: String
    let method: String
    let params: [String: AnyCodable]?
}

struct ResponseFrame: Codable {
    let type: String  // "res"
    let id: String
    let ok: Bool
    let payload: AnyCodable?
    let error: ErrorShape?
}

struct EventFrame: Codable {
    let type: String  // "event"
    let event: String
    let payload: AnyCodable?
    let seq: Int?
}

struct ErrorShape: Codable {
    let code: String
    let message: String
}

struct ConnectParams: Codable {
    let minProtocol: Int
    let maxProtocol: Int
    let client: ClientInfo
    let caps: [String]?
    let auth: AuthInfo?
}

struct ClientInfo: Codable {
    let id: String
    let displayName: String?
    let version: String
    let platform: String
    let mode: String
}

struct AuthInfo: Codable {
    let token: String?
    let bootstrapToken: String?
    let deviceToken: String?
    let password: String?
}

struct HelloOk: Codable {
    let type: String  // "hello-ok"
    let `protocol`: Int
    let server: ServerInfo
    let features: Features
    let snapshot: Snapshot?
    let auth: AuthResult
    let policy: Policy
}

struct ServerInfo: Codable {
    let version: String
    let connId: String
}

struct Features: Codable {
    let methods: [String]
    let events: [String]
}

struct Snapshot: Codable {
    let stateVersion: StateVersion?
}

struct StateVersion: Codable {
    let version: Int
    let updatedAt: Int?
}

struct AuthResult: Codable {
    let deviceToken: String?
    let role: String
    let scopes: [String]
}

struct Policy: Codable {
    let maxPayload: Int
    let maxBufferedBytes: Int
    let tickIntervalMs: Int
}

struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let bool as Bool:
            try container.encode(bool)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }
}