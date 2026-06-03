import Foundation

actor OpenClawClient {
    private let gatewayURL: URL
    private var webSocket: WebSocketManager?
    private var authToken: String?
    private var sessionKey: String?

    init(gatewayURL: URL) {
        self.gatewayURL = gatewayURL
    }

    func connect(authToken: String) async throws -> HelloOk {
        self.authToken = authToken
        webSocket = WebSocketManager(url: gatewayURL)
        try await webSocket?.connect()

        let connectParams = ConnectParams(
            minProtocol: 1,
            maxProtocol: 100,
            client: ClientInfo(
                id: "smartchat-ios",
                displayName: "SmartChatApp",
                version: "1.0.0",
                platform: "iOS",
                mode: "user"
            ),
            caps: ["sessions", "chat"],
            auth: AuthInfo(
                token: authToken,
                bootstrapToken: nil,
                deviceToken: nil,
                password: nil
            )
        )

        let frame = RequestFrame(
            type: "req",
            id: UUID().uuidString,
            method: "hello",
            params: [
                "minProtocol": AnyCodable(connectParams.minProtocol),
                "maxProtocol": AnyCodable(connectParams.maxProtocol),
                "client": AnyCodable(encodeToDict(connectParams.client)),
                "caps": AnyCodable(connectParams.caps ?? []),
                "auth": AnyCodable(encodeToDict(connectParams.auth))
            ]
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(frame)
        guard let json = String(data: data, encoding: .utf8) else {
            throw OpenClawError.encodingFailed
        }

        try await webSocket?.send(json)

        return HelloOk(
            type: "hello-ok",
            protocol: 1,
            server: ServerInfo(version: "1.0.0", connId: ""),
            features: Features(methods: [], events: []),
            snapshot: nil,
            auth: AuthResult(deviceToken: nil, role: "", scopes: []),
            policy: Policy(maxPayload: 0, maxBufferedBytes: 0, tickIntervalMs: 0)
        )
    }

    func createSession() async throws -> String {
        let frame = RequestFrame(
            type: "req",
            id: UUID().uuidString,
            method: "sessions.create",
            params: nil
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(frame)
        guard let json = String(data: data, encoding: .utf8) else {
            throw OpenClawError.encodingFailed
        }

        try await webSocket?.send(json)
        sessionKey = UUID().uuidString
        return sessionKey ?? ""
    }

    func sendMessage(sessionKey: String, message: String) async throws {
        self.sessionKey = sessionKey
        let frame = RequestFrame(
            type: "req",
            id: UUID().uuidString,
            method: "sessions.send",
            params: [
                "key": AnyCodable(sessionKey),
                "message": AnyCodable(message)
            ]
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(frame)
        guard let json = String(data: data, encoding: .utf8) else {
            throw OpenClawError.encodingFailed
        }

        try await webSocket?.send(json)
    }

    func subscribe(sessionKey: String) -> AsyncThrowingStream<GatewayEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let frame = RequestFrame(
                        type: "req",
                        id: UUID().uuidString,
                        method: "sessions.subscribe",
                        params: ["key": AnyCodable(sessionKey)]
                    )
                    let encoder = JSONEncoder()
                    let data = try encoder.encode(frame)
                    if let json = String(data: data, encoding: .utf8) {
                        try await self.webSocket?.send(json)
                    }

                    guard let ws = self.webSocket else {
                        continuation.finish()
                        return
                    }

                    for try await rawFrame in ws.receive() {
                        if let event = self.parseEvent(rawFrame) {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func parseEvent(_ json: String) -> GatewayEvent? {
        guard let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        if let frame = try? decoder.decode(ResponseFrame.self, from: data) {
            return .response(frame)
        } else if let frame = try? decoder.decode(EventFrame.self, from: data) {
            return .event(frame)
        }
        return nil
    }

    private func encodeToDict<T: Encodable>(_ value: T) -> [String: AnyCodable] {
        guard let data = try? JSONEncoder().encode(value),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return dict.mapValues { AnyCodable($0) }
    }

    func disconnect() {
        webSocket?.disconnect()
        webSocket = nil
    }
}

enum OpenClawError: Error {
    case encodingFailed
    case connectionFailed
}

enum GatewayEvent {
    case response(ResponseFrame)
    case event(EventFrame)
}