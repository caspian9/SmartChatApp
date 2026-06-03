import Foundation
import OpenClawKit
import OpenClawProtocol
import OpenClawChatUI

actor SessionManager {
    static let shared = SessionManager()

    private let nodeSession: GatewayNodeSession
    private var isConnected = false

    private init() {
        self.nodeSession = GatewayNodeSession()
    }

    func connect(gatewayURL: URL, authToken: String) async throws {
        let connectOptions = GatewayConnectOptions(
            role: "operator",
            scopes: ["operator.admin", "operator.read", "operator.write", "operator.approvals", "operator.pairing"],
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
                onDisconnected: { [weak self] reason in
                    Task { [weak self] in
                        await self?.setConnected(false)
                        print("Gateway disconnected: \(reason)")
                    }
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
            isConnected = true
        } catch let error as GatewayConnectAuthError {
            let requestIdStr = error.requestId.map { " (requestId: \($0))" } ?? ""
            let displayError = SessionManagerError.authError(error.message + requestIdStr, error.detailCodeRaw)
            print("Gateway connection error: \(error.message)\(requestIdStr), detailCode: \(error.detailCodeRaw ?? "nil")")
            throw displayError
        } catch {
            print("Gateway connection error: \(error)")
            throw error
        }
    }

    private func setConnected(_ value: Bool) {
        isConnected = value
    }

    func createSession() async throws -> String {
        let responseData = try await nodeSession.request(
            method: "sessions.create",
            paramsJSON: nil
        )

        struct CreateSessionResponse: Decodable {
            let key: String
        }

        guard let response = try? JSONDecoder().decode(CreateSessionResponse.self, from: responseData) else {
            throw SessionManagerError.invalidResponse
        }

        return response.key
    }

    func makeTransport(sessionKey: String) -> GatewayChatTransport {
        GatewayChatTransport(nodeSession: nodeSession, sessionKey: sessionKey)
    }

    struct GatewayConfig {
        let host: String
        let port: Int
        let useTLS: Bool
        let authToken: String
    }

    func getGatewayConfig() -> GatewayConfig? {
        let config = ConfigurationManager.shared
        guard !config.gatewayHost.isEmpty, !config.authToken.isEmpty else { return nil }
        return GatewayConfig(
            host: config.gatewayHost,
            port: config.gatewayPort,
            useTLS: config.gatewayUseTLS,
            authToken: config.authToken
        )
    }

    func ensureConnected() async throws {
        if isConnected { return }
        guard let config = getGatewayConfig() else {
            throw SessionManagerError.notConnected
        }
        let scheme = config.useTLS ? "wss" : "ws"
        let urlString = "\(scheme)://\(config.host):\(config.port)/gateway"
        guard let url = URL(string: urlString) else {
            throw SessionManagerError.notConnected
        }
        try await connect(gatewayURL: url, authToken: config.authToken)
    }

    func disconnect() async {
        await nodeSession.disconnect()
        isConnected = false
    }

    var connectionStatus: Bool {
        isConnected
    }
}

enum SessionManagerError: Error, LocalizedError {
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
