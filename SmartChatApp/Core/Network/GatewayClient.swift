import Foundation
import OpenClawKit
import OpenClawProtocol
import OpenClawChatUI

actor GatewayClient {
    private let nodeSession: GatewayNodeSession
    private var activeURL: URL?
    private var sessionKey: String?

    init() {
        self.nodeSession = GatewayNodeSession()
    }

    func connect(gatewayURL: URL, authToken: String) async throws {
        self.activeURL = gatewayURL

        let connectOptions = GatewayConnectOptions(
            role: "node",
            scopes: ["chat"],
            caps: ["sessions", "chat"],
            commands: [],
            permissions: [:],
            clientId: "openclaw-ios",
            clientMode: "ui",
            clientDisplayName: "SmartChatApp",
            includeDeviceIdentity: true
        )

        let sessionBox = WebSocketSessionBox(session: URLSession.shared)

        do {
            try await nodeSession.connect(
                url: gatewayURL,
                token: authToken,
                bootstrapToken: nil,
                password: nil,
                connectOptions: connectOptions,
                sessionBox: sessionBox,
                onConnected: {},
                onDisconnected: { reason in
                    print("Gateway disconnected: \(reason)")
                },
                onInvoke: { request in
                    BridgeInvokeResponse(
                        id: request.id,
                        ok: true,
                        payloadJSON: nil,
                        error: nil
                    )
                }
            )
        } catch let error as GatewayConnectAuthError {
            let requestIdStr = error.requestId.map { " (requestId: \($0))" } ?? ""
            let displayError = GatewayClientError.authError(error.message + requestIdStr, error.detailCodeRaw)
            print("Gateway connection error: \(error.message)\(requestIdStr), detailCode: \(error.detailCodeRaw ?? "nil")")
            throw displayError
        } catch {
            print("Gateway connection error: \(error)")
            throw error
        }
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

    func subscribe(sessionKey: String) -> AsyncThrowingStream<OpenClawChatTransportEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                continuation.finish()
            }
        }
    }

    func disconnect() async {
        await nodeSession.disconnect()
        activeURL = nil
        sessionKey = nil
    }
}

enum GatewayClientError: Error, LocalizedError {
    case notConnected
    case invalidResponse
    case authError(String, String?)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to gateway"
        case .invalidResponse:
            return "Invalid server response"
        case .authError(let message, _):
            return message
        }
    }
}
