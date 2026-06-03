import Foundation
import OpenClawKit
import OpenClawProtocol

actor GatewayClient {
    private let nodeSession: GatewayNodeSession
    private var activeURL: URL?
    private var sessionKey: String?

    init() {
        self.nodeSession = GatewayNodeSession()
    }

    func connect(gatewayURL: URL, authToken: String) async throws -> HelloOk {
        self.activeURL = gatewayURL

        let connectOptions = GatewayConnectOptions(
            role: "user",
            scopes: ["chat"],
            caps: ["sessions", "chat"],
            commands: [],
            permissions: [:],
            clientId: "smartchat-ios",
            clientMode: "user",
            clientDisplayName: "SmartChatApp",
            includeDeviceIdentity: false
        )

        let sessionBox = WebSocketSessionBox(session: URLSession.shared)

        return try await nodeSession.connect(
            url: gatewayURL,
            token: authToken,
            bootstrapToken: nil,
            password: nil,
            connectOptions: connectOptions,
            sessionBox: sessionBox,
            onConnected: {},
            onDisconnected: { _ in },
            onInvoke: { request in
                BridgeInvokeResponse(
                    id: request.id,
                    ok: true,
                    error: nil,
                    payloadJSON: nil
                )
            }
        )
    }

    func createSession() async throws -> String {
        guard let url = activeURL else {
            throw GatewayClientError.notConnected
        }

        let responseData = try await nodeSession.request(
            method: "sessions.create",
            paramsJSON: nil
        )

        struct CreateSessionResponse: Decodable {
            let key: String
        }

        guard let response = try? JSONDecoder().decode(CreateSessionResponse.self, from: responseData) else {
            throw GatewayClientError.invalidResponse
        }

        sessionKey = response.key
        return response.key
    }

    func sendMessage(sessionKey: String, message: String) async throws {
        let params = """
        {"key": "\(sessionKey)", "message": "\(message)"}
        """

        _ = try await nodeSession.request(
            method: "sessions.send",
            paramsJSON: params
        )
    }

    func subscribe(sessionKey: String) -> AsyncThrowingStream<GatewayEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let events = nodeSession.subscribeServerEvents()
                    for try await event in events {
                        continuation.yield(.event(event))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func disconnect() async {
        await nodeSession.disconnect()
        activeURL = nil
        sessionKey = nil
    }
}

enum GatewayClientError: Error {
    case notConnected
    case invalidResponse
}
