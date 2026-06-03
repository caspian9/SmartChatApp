import Foundation
import OpenClawKit
import OpenClawProtocol
import OpenClawChatUI
import UIKit
import os.log

private let logger = Logger(subsystem: "SmartChatApp", category: "SessionManager")

public struct DebugLogEntry: Identifiable, Equatable {
    public var id = UUID()
    public var ts: Date
    public var message: String
    public var category: String

    public init(id: UUID = UUID(), ts: Date, message: String, category: String) {
        self.id = id
        self.ts = ts
        self.message = message
        self.category = category
    }
}

actor SessionManager {
    static let shared = SessionManager()

    private let nodeSession: GatewayNodeSession
    private var isConnected = false
    private var connectedDeviceName: String?
    private var reconnectOnLaunch = false
    private var currentSessionKey: String?
    private var debugLoggingEnabled = false
    private var discoveryDebugLoggingEnabled = false
    private var debugLog: [DebugLogEntry] = []

    private init() {
        self.nodeSession = GatewayNodeSession()
    }

    var connectionStatus: Bool {
        isConnected
    }

    var deviceName: String? {
        connectedDeviceName
    }

    func connect(gatewayURL: URL, authToken: String) async throws {
        let deviceIdentity = DeviceIdentityStore.loadOrCreate()
        let connectOptions = GatewayConnectOptions(
            role: "operator",
            scopes: ["operator.admin", "operator.read", "operator.write", "operator.approvals", "operator.pairing"],
            caps: ["sessions", "chat"],
            commands: [],
            permissions: [:],
            clientId: "openclaw-ios",
            clientMode: "ui",
            clientDisplayName: deviceIdentity.deviceId.prefix(16).description,
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
                onConnected: {
                    logger.log("log: Connected to gateway")
                },
                onDisconnected: { [weak self] reason in
                    logger.log("log: Disconnected: \(reason)")
                    Task { [weak self] in
                        await self?.setConnected(false)
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
            connectedDeviceName = deviceIdentity.deviceId.prefix(16).description
            logger.log("log: Connection established, deviceId: \(self.connectedDeviceName ?? "unknown")")
            appendDebugLog("gateway: Connected to gateway", category: "gateway")
        } catch let error as GatewayConnectAuthError {
            let requestIdStr = error.requestId.map { " (requestId: \($0))" } ?? ""
            let displayError = SessionManagerError.authError(error.message + requestIdStr, error.detailCodeRaw)
            logger.log("log: Auth error: \(error.message)\(requestIdStr)")
            appendDebugLog("gateway: Auth error: \(error.message)\(requestIdStr)", category: "gateway")
            throw displayError
        } catch {
            logger.log("log: Connection error: \(error.localizedDescription)")
            appendDebugLog("gateway: Connection error: \(error.localizedDescription)", category: "gateway")
            throw error
        }
    }

    private func setConnected(_ value: Bool) {
        isConnected = value
        if !value {
            connectedDeviceName = nil
            appendDebugLog("gateway: Disconnected", category: "gateway")
        }
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
        currentSessionKey = sessionKey
        return GatewayChatTransport(nodeSession: nodeSession, sessionKey: sessionKey)
    }

    func getCurrentSessionKey() -> String? {
        currentSessionKey
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
        if isConnected {
            logger.log("log: Already connected, skipping")
            return
        }
        guard let config = getGatewayConfig() else {
            logger.log("log: No gateway config available")
            appendDebugLog("gateway: No config available", category: "gateway")
            throw SessionManagerError.notConnected
        }
        let scheme = config.useTLS ? "wss" : "ws"
        let urlString = "\(scheme)://\(config.host):\(config.port)/gateway"
        guard let url = URL(string: urlString) else {
            throw SessionManagerError.notConnected
        }
        logger.log("log: Attempting to connect to: \(urlString)")
        appendDebugLog("gateway: Connecting to \(urlString)", category: "gateway")
        try await connect(gatewayURL: url, authToken: config.authToken)
    }

    func disconnect() async {
        logger.log("log: Disconnecting...")
        appendDebugLog("gateway: Disconnecting...", category: "gateway")
        await nodeSession.disconnect()
        isConnected = false
        connectedDeviceName = nil
    }

    func setReconnectOnLaunch(_ value: Bool) {
        reconnectOnLaunch = value
        logger.log("log: reconnectOnLaunch set to: \(value)")
    }

    var shouldReconnectOnLaunch: Bool {
        reconnectOnLaunch
    }

    func checkConnection() async -> Bool {
        logger.log("log: checkConnection called, isConnected: \(self.isConnected)")
        if !isConnected {
            logger.log("log: Not connected, attempting reconnect...")
            appendDebugLog("gateway: Not connected, attempting reconnect...", category: "gateway")
            do {
                try await ensureConnected()
                return true
            } catch {
                logger.log("log: Reconnect failed: \(error.localizedDescription)")
                return false
            }
        }
        return true
    }

    // MARK: - Debug Logging

    func setDebugLoggingEnabled(_ enabled: Bool) {
        self.debugLoggingEnabled = enabled
        if enabled {
            appendDebugLog("gateway: Debug logging enabled", category: "gateway")
        }
    }

    func setDiscoveryDebugLoggingEnabled(_ enabled: Bool) {
        self.discoveryDebugLoggingEnabled = enabled
        if enabled {
            appendDebugLog("discovery: Discovery debug logging enabled", category: "discovery")
        }
    }

    func getDebugLogs() -> [DebugLogEntry] {
        return debugLog
    }

    func clearDebugLogs() {
        debugLog.removeAll()
    }

    private func appendDebugLog(_ message: String, category: String) {
        // Check if logging is enabled for this category
        if category == "discovery" && !discoveryDebugLoggingEnabled {
            return
        }
        if category == "gateway" && !debugLoggingEnabled {
            return
        }
        debugLog.append(DebugLogEntry(ts: Date(), message: message, category: category))
        if debugLog.count > 200 {
            debugLog.removeFirst(debugLog.count - 200)
        }
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
