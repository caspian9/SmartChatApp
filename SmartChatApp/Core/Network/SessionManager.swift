import Foundation
import OpenClawKit
import OpenClawProtocol
import OpenClawChatUI
import UIKit
import SwiftData
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

    private let operatorSession: GatewayNodeSession
    private let nodeSession: GatewayNodeSession
    private var operatorConnected = false
    private var nodeConnected = false
    private var nodeConnectionError: String? = nil
    private var connectedDeviceName: String?
    private var reconnectOnLaunch = false
    private var currentSessionKey: String?
    private var debugLoggingEnabled = false
    private var discoveryDebugLoggingEnabled = false
    private var debugLog: [DebugLogEntry] = []
    private let commandRouter = NodeCommandRouter()

    private init() {
        self.operatorSession = GatewayNodeSession()
        self.nodeSession = GatewayNodeSession()
    }

    var connectionStatus: Bool {
        operatorConnected
    }

    var operatorConnectionStatus: Bool {
        operatorConnected
    }

    var nodeConnectionStatus: Bool {
        nodeConnected
    }

    var nodeConnectionErrorMessage: String? {
        nodeConnectionError
    }

    var deviceName: String? {
        connectedDeviceName
    }

    func connectWithRole(gatewayURL: URL, authToken: String, role: GatewayConnectionRole) async throws {
        switch role {
        case .operatorOnly:
            try await connect(gatewayURL: gatewayURL, authToken: authToken)
        case .nodeOnly:
            try await connectNodeRole(gatewayURL: gatewayURL, authToken: authToken)
        case .operatorAndNode:
            try await connect(gatewayURL: gatewayURL, authToken: authToken)
            if !nodeConnected {
                do {
                    try await connectNodeRole(gatewayURL: gatewayURL, authToken: authToken)
                } catch {
                    logger.log("log: Node connection failed (non-fatal): \(error.localizedDescription)")
                }
            }
        }
    }

    func connectWithProfile(_ profile: GatewayProfile) async throws {
        let url = URL(string: "\(profile.tlsEnabled ? "https" : "http")://\(profile.host):\(profile.port)")!
        try await connectWithRole(gatewayURL: url, authToken: profile.token, role: .operatorAndNode)
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
            try await operatorSession.connect(
                url: gatewayURL,
                token: authToken,
                bootstrapToken: nil,
                password: nil,
                connectOptions: connectOptions,
                sessionBox: sessionBox,
                onConnected: {
                    logger.log("log: Operator connected to gateway")
                },
                onDisconnected: { [weak self] reason in
                    logger.log("log: Operator disconnected: \(reason)")
                    Task { [weak self] in
                        await self?.setOperatorConnected(false)
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
            operatorConnected = true
            connectedDeviceName = deviceIdentity.deviceId.prefix(16).description
            logger.log("log: Operator connection established, deviceId: \(self.connectedDeviceName ?? "unknown")")
            appendDebugLog("gateway: Operator connected to gateway", category: "gateway")
            appendDebugLog("gateway: Operator caps: \(connectOptions.caps.joined(separator: ", "))", category: "gateway")
            appendDebugLog("gateway: Operator commands: \(connectOptions.commands.joined(separator: ", "))", category: "gateway")
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

    func connectNodeRole(gatewayURL: URL, authToken: String) async throws {
        let deviceIdentity = DeviceIdentityStore.loadOrCreate()
        let nodeOptions = makeNodeConnectOptions(deviceIdentity: deviceIdentity)
        let sessionBox = WebSocketSessionBox(session: URLSession.shared)

        do {
            try await nodeSession.connect(
                url: gatewayURL,
                token: authToken,
                bootstrapToken: nil,
                password: nil,
                connectOptions: nodeOptions,
                sessionBox: sessionBox,
                onConnected: {
                    logger.log("log: Node connected to gateway")
                },
                onDisconnected: { [weak self] reason in
                    logger.log("log: Node disconnected: \(reason)")
                    Task { [weak self] in
                        await self?.setNodeConnected(false)
                    }
                },
                onInvoke: { [weak self] request in
                    guard let self = self else {
                        return BridgeInvokeResponse(
                            type: "response",
                            id: request.id,
                            ok: false,
                            payloadJSON: nil,
                            error: OpenClawNodeError(code: .unavailable, message: "Session unavailable")
                        )
                    }
                    return await self.commandRouter.handle(request)
                }
            )
            nodeConnected = true
            nodeConnectionError = nil
            logger.log("log: Node connection established")
            let caps = nodeCaps()
            let commands = nodeCommands()
            appendDebugLog("gateway: Node connected to gateway", category: "gateway")
            appendDebugLog("gateway: Node caps: \(caps.joined(separator: ", "))", category: "gateway")
            appendDebugLog("gateway: Node commands: \(commands.joined(separator: ", "))", category: "gateway")
        } catch {
            logger.log("log: Node connection error: \(error.localizedDescription)")
            nodeConnectionError = error.localizedDescription
            appendDebugLog("gateway: Node connection error: \(error.localizedDescription)", category: "gateway")
        }
    }

    private func makeNodeConnectOptions(deviceIdentity: DeviceIdentity) -> GatewayConnectOptions {
        GatewayConnectOptions(
            role: "node",
            scopes: [],
            caps: nodeCaps(),
            commands: nodeCommands(),
            permissions: nodePermissions(),
            clientId: "openclaw-ios",
            clientMode: "node",
            clientDisplayName: deviceIdentity.deviceId.prefix(16).description,
            includeDeviceIdentity: true
        )
    }

    private func nodeCaps() -> [String] {
        var caps: [String] = [
            OpenClawCapability.canvas.rawValue,
            OpenClawCapability.screen.rawValue,
            OpenClawCapability.device.rawValue,
            OpenClawCapability.talk.rawValue,
        ]

        // Optional caps based on user settings
        let config = ConfigurationManager.shared
        if config.cameraEnabled {
            caps.append(OpenClawCapability.camera.rawValue)
        }
        if config.voiceWakeEnabled {
            caps.append(OpenClawCapability.voiceWake.rawValue)
        }
        if config.locationEnabled {
            caps.append(OpenClawCapability.location.rawValue)
        }

        // Always-on caps
        caps.append(contentsOf: [
            OpenClawCapability.photos.rawValue,
            OpenClawCapability.contacts.rawValue,
            OpenClawCapability.calendar.rawValue,
            OpenClawCapability.reminders.rawValue,
        ])

        return caps
    }

    private func nodeCommands() -> [String] {
        var commands: [String] = [
            // Canvas commands
            OpenClawCanvasCommand.present.rawValue,
            OpenClawCanvasCommand.hide.rawValue,
            OpenClawCanvasCommand.navigate.rawValue,
            OpenClawCanvasCommand.evalJS.rawValue,
            OpenClawCanvasCommand.snapshot.rawValue,
            // Canvas A2UI commands
            OpenClawCanvasA2UICommand.push.rawValue,
            OpenClawCanvasA2UICommand.pushJSONL.rawValue,
            OpenClawCanvasA2UICommand.reset.rawValue,
            // Screen commands
            OpenClawScreenCommand.record.rawValue,
            // System commands
            OpenClawSystemCommand.notify.rawValue,
            // Chat commands
            OpenClawChatCommand.push.rawValue,
            // Talk commands
            OpenClawTalkCommand.pttStart.rawValue,
            OpenClawTalkCommand.pttStop.rawValue,
            OpenClawTalkCommand.pttCancel.rawValue,
            OpenClawTalkCommand.pttOnce.rawValue,
        ]

        let caps = Set(nodeCaps())

        if caps.contains(OpenClawCapability.camera.rawValue) {
            commands.append(contentsOf: [
                OpenClawCameraCommand.list.rawValue,
                OpenClawCameraCommand.snap.rawValue,
                OpenClawCameraCommand.clip.rawValue,
            ])
        }

        if caps.contains(OpenClawCapability.location.rawValue) {
            commands.append(OpenClawLocationCommand.get.rawValue)
        }

        if caps.contains(OpenClawCapability.device.rawValue) {
            commands.append(contentsOf: [
                OpenClawDeviceCommand.status.rawValue,
                OpenClawDeviceCommand.info.rawValue,
            ])
        }

        if caps.contains(OpenClawCapability.photos.rawValue) {
            commands.append(OpenClawPhotosCommand.latest.rawValue)
        }

        if caps.contains(OpenClawCapability.contacts.rawValue) {
            commands.append(contentsOf: [
                OpenClawContactsCommand.search.rawValue,
                OpenClawContactsCommand.add.rawValue,
            ])
        }

        if caps.contains(OpenClawCapability.calendar.rawValue) {
            commands.append(contentsOf: [
                OpenClawCalendarCommand.events.rawValue,
                OpenClawCalendarCommand.add.rawValue,
            ])
        }

        if caps.contains(OpenClawCapability.reminders.rawValue) {
            commands.append(contentsOf: [
                OpenClawRemindersCommand.list.rawValue,
                OpenClawRemindersCommand.add.rawValue,
            ])
        }

        return commands
    }

    private func nodePermissions() -> [String: Bool] {
        // Return empty permissions for now
        // Can be expanded to check actual authorization status
        [:]
    }

    private func setOperatorConnected(_ value: Bool) {
        operatorConnected = value
        if !value {
            connectedDeviceName = nil
            appendDebugLog("gateway: Operator disconnected", category: "gateway")
        }
    }

    private func setNodeConnected(_ value: Bool) {
        nodeConnected = value
        if !value {
            appendDebugLog("gateway: Node disconnected", category: "gateway")
        } else {
            nodeConnectionError = nil
        }
    }

    func createSession() async throws -> String {
        let responseData = try await operatorSession.request(
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
        return GatewayChatTransport(nodeSession: operatorSession, sessionKey: sessionKey)
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
        let role = ConfigurationManager.shared.gatewayRole
        if role == .operatorOnly && operatorConnected {
            logger.log("log: Already connected (operator), skipping")
            return
        }
        if role == .nodeOnly && nodeConnected {
            logger.log("log: Already connected (node), skipping")
            return
        }
        if role == .operatorAndNode && operatorConnected {
            logger.log("log: Already connected (operator+node), skipping")
            return
        }

        // Try active profile first, then fall back to legacy config
        var host: String
        var port: Int
        var useTLS: Bool
        var authToken: String

        let activeProfile = await MainActor.run { ProfileManager.shared.activeProfile }
        if let profile = activeProfile {
            host = profile.host
            port = profile.port
            useTLS = profile.tlsEnabled
            authToken = profile.token
        } else if let config = getGatewayConfig() {
            host = config.host
            port = config.port
            useTLS = config.useTLS
            authToken = config.authToken
        } else {
            logger.log("log: No gateway config available")
            appendDebugLog("gateway: No config available", category: "gateway")
            throw SessionManagerError.notConnected
        }

        let scheme = useTLS ? "wss" : "ws"
        let urlString = "\(scheme)://\(host):\(port)/gateway"
        guard let url = URL(string: urlString) else {
            throw SessionManagerError.notConnected
        }
        logger.log("log: Attempting to connect to: \(urlString)")
        appendDebugLog("gateway: Connecting to \(urlString)", category: "gateway")

        switch role {
        case .operatorOnly:
            try await connect(gatewayURL: url, authToken: authToken)
        case .nodeOnly:
            try await connectNodeRole(gatewayURL: url, authToken: authToken)
        case .operatorAndNode:
            try await connect(gatewayURL: url, authToken: authToken)
            if !nodeConnected {
                do {
                    try await connectNodeRole(gatewayURL: url, authToken: authToken)
                } catch {
                    logger.log("log: Node connection failed (non-fatal): \(error.localizedDescription)")
                }
            }
        }
    }

    func reconnect() async throws {
        await operatorSession.disconnect()
        await nodeSession.disconnect()
        operatorConnected = false
        nodeConnected = false

        guard let config = getGatewayConfig() else {
            throw SessionManagerError.notConnected
        }
        let scheme = config.useTLS ? "wss" : "ws"
        let urlString = "\(scheme)://\(config.host):\(config.port)/gateway"
        guard let url = URL(string: urlString) else {
            throw SessionManagerError.notConnected
        }

        // Connect operator
        try await connect(gatewayURL: url, authToken: config.authToken)

        // Connect node
        if !nodeConnected {
            do {
                try await connectNodeRole(gatewayURL: url, authToken: config.authToken)
            } catch {
                logger.log("log: Node connection failed (non-fatal): \(error.localizedDescription)")
            }
        }
    }

    func disconnect() async {
        logger.log("log: Disconnecting...")
        appendDebugLog("gateway: Disconnecting...", category: "gateway")
        await operatorSession.disconnect()
        await nodeSession.disconnect()
        operatorConnected = false
        nodeConnected = false
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
        logger.log("log: checkConnection called, operatorConnected: \(self.operatorConnected)")
        if !operatorConnected {
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
