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

    func connectWithRole(gatewayURL: URL, authToken: String, role: GatewayConnectionRole, cameraEnabled: Bool, locationEnabled: Bool, voiceWakeEnabled: Bool) async throws {
        switch role {
        case .operatorOnly:
            try await connect(gatewayURL: gatewayURL, authToken: authToken)
        case .nodeOnly:
            try await connectNodeRole(gatewayURL: gatewayURL, authToken: authToken, cameraEnabled: cameraEnabled, locationEnabled: locationEnabled, voiceWakeEnabled: voiceWakeEnabled)
        case .operatorAndNode:
            try await connectNodeRole(gatewayURL: gatewayURL, authToken: authToken, cameraEnabled: cameraEnabled, locationEnabled: locationEnabled, voiceWakeEnabled: voiceWakeEnabled)
            try await connect(gatewayURL: gatewayURL, authToken: authToken)
        }
    }

    func connectWithProfile(_ profile: GatewayProfile) async throws {
        let url = gatewayURL(host: profile.host, port: profile.port, tlsEnabled: profile.tlsEnabled)
        try await connectWithRole(gatewayURL: url, authToken: profile.token, role: profile.role, cameraEnabled: profile.cameraEnabled, locationEnabled: profile.locationEnabled, voiceWakeEnabled: profile.voiceWakeEnabled)
    }

    func gatewayURL(host: String, port: Int, tlsEnabled: Bool) -> URL {
        let scheme = tlsEnabled ? "wss" : "ws"
        return URL(string: "\(scheme)://\(host):\(port)/gateway")!
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

    func connectNodeRole(gatewayURL: URL, authToken: String, cameraEnabled: Bool, locationEnabled: Bool, voiceWakeEnabled: Bool) async throws {
        let deviceIdentity = DeviceIdentityStore.loadOrCreate()
        let nodeOptions = makeNodeConnectOptions(deviceIdentity: deviceIdentity, cameraEnabled: cameraEnabled, locationEnabled: locationEnabled, voiceWakeEnabled: voiceWakeEnabled)
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
            let caps = nodeCaps(cameraEnabled: cameraEnabled, locationEnabled: locationEnabled, voiceWakeEnabled: voiceWakeEnabled)
            let commands = nodeCommands(cameraEnabled: cameraEnabled, locationEnabled: locationEnabled, voiceWakeEnabled: voiceWakeEnabled)
            appendDebugLog("gateway: Node connected to gateway", category: "gateway")
            appendDebugLog("gateway: Node caps: \(caps.joined(separator: ", "))", category: "gateway")
            appendDebugLog("gateway: Node commands: \(commands.joined(separator: ", "))", category: "gateway")
        } catch {
            logger.log("log: Node connection error: \(error.localizedDescription)")
            nodeConnectionError = error.localizedDescription
            appendDebugLog("gateway: Node connection error: \(error.localizedDescription)", category: "gateway")
        }
    }

    private func makeNodeConnectOptions(deviceIdentity: DeviceIdentity, cameraEnabled: Bool, locationEnabled: Bool, voiceWakeEnabled: Bool) -> GatewayConnectOptions {
        GatewayConnectOptions(
            role: "node",
            scopes: [],
            caps: nodeCaps(cameraEnabled: cameraEnabled, locationEnabled: locationEnabled, voiceWakeEnabled: voiceWakeEnabled),
            commands: nodeCommands(cameraEnabled: cameraEnabled, locationEnabled: locationEnabled, voiceWakeEnabled: voiceWakeEnabled),
            permissions: nodePermissions(),
            clientId: "openclaw-ios",
            clientMode: "node",
            clientDisplayName: deviceIdentity.deviceId.prefix(16).description,
            includeDeviceIdentity: true
        )
    }

    private func nodeCaps(cameraEnabled: Bool, locationEnabled: Bool, voiceWakeEnabled: Bool) -> [String] {
        var caps: [String] = [
            OpenClawCapability.canvas.rawValue,
            OpenClawCapability.screen.rawValue,
            OpenClawCapability.device.rawValue,
            OpenClawCapability.talk.rawValue,
        ]

        // Optional caps based on profile settings
        if cameraEnabled {
            caps.append(OpenClawCapability.camera.rawValue)
        }
        if voiceWakeEnabled {
            caps.append(OpenClawCapability.voiceWake.rawValue)
        }
        if locationEnabled {
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

    private func nodeCommands(cameraEnabled: Bool, locationEnabled: Bool, voiceWakeEnabled: Bool) -> [String] {
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

        // Add commands based on capabilities
        if cameraEnabled {
            commands.append(contentsOf: [
                OpenClawCameraCommand.list.rawValue,
                OpenClawCameraCommand.snap.rawValue,
                OpenClawCameraCommand.clip.rawValue,
            ])
        }

        if locationEnabled {
            commands.append(OpenClawLocationCommand.get.rawValue)
        }

        // Always include device commands
        commands.append(contentsOf: [
            OpenClawDeviceCommand.status.rawValue,
            OpenClawDeviceCommand.info.rawValue,
        ])

        if true { // photos is always enabled
            commands.append(OpenClawPhotosCommand.latest.rawValue)
        }

        if true { // contacts is always enabled
            commands.append(contentsOf: [
                OpenClawContactsCommand.search.rawValue,
                OpenClawContactsCommand.add.rawValue,
            ])
        }

        if true { // calendar is always enabled
            commands.append(contentsOf: [
                OpenClawCalendarCommand.events.rawValue,
                OpenClawCalendarCommand.add.rawValue,
            ])
        }

        if true { // reminders is always enabled
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

    /// Creates a new session on the gateway.
    ///
    /// - Parameters:
    ///   - agentId: Optional agent id to scope the new session to.
    ///     When `nil`, the gateway falls back to `resolveDefaultAgentId(cfg)`
    ///     — its configured default agent. Pass a specific agent id (parsed
    ///     from a current session key, e.g. `agent:<id>:dashboard:<uuid>`)
    ///     when the user has an existing session in view and you want the new
    ///     session to land under the same agent instead of the gateway default.
    ///   - customKey: Optional full session key to request, e.g.
    ///     `agent:<agentId>:SmartChatApp:<uuid>`. When provided, the gateway
    ///     will use this key as-is (after its standard lowercase
    ///     normalization). The keys's `agentId` portion must match the
    ///     `agentId` parameter — the gateway rejects mismatches.
    func createSession(agentId: String? = nil, customKey: String? = nil) async throws -> String {
        var params: [String: String] = [:]
        if let agentId, !agentId.isEmpty {
            params["agentId"] = agentId
        }
        if let customKey, !customKey.isEmpty {
            params["key"] = customKey
        }
        let paramsJSON: String?
        if params.isEmpty {
            paramsJSON = nil
        } else {
            // Use the real JSON encoder rather than hand-stringifying — it
            // handles escaping of `"`, `\`, control characters, etc.
            let data = try JSONEncoder().encode(params)
            paramsJSON = String(data: data, encoding: .utf8)
        }
        let responseData = try await operatorSession.request(
            method: "sessions.create",
            paramsJSON: paramsJSON
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

    func ensureConnected() async throws {
        // Use active profile
        let activeProfile = await MainActor.run { ProfileManager.shared.activeProfile }
        guard let profile = activeProfile else {
            logger.log("log: No active profile available")
            appendDebugLog("gateway: No active profile", category: "gateway")
            return
        }

        let role = profile.role
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

        let scheme = profile.tlsEnabled ? "wss" : "ws"
        let urlString = "\(scheme)://\(profile.host):\(profile.port)/gateway"
        guard let url = URL(string: urlString) else {
            logger.log("log: Invalid profile URL")
            return
        }
        logger.log("log: Attempting to connect to: \(urlString)")
        appendDebugLog("gateway: Connecting to \(urlString)", category: "gateway")

        switch role {
        case .operatorOnly:
            try await connect(gatewayURL: url, authToken: profile.token)
        case .nodeOnly:
            try await connectNodeRole(gatewayURL: url, authToken: profile.token, cameraEnabled: profile.cameraEnabled, locationEnabled: profile.locationEnabled, voiceWakeEnabled: profile.voiceWakeEnabled)
        case .operatorAndNode:
            try await connectNodeRole(gatewayURL: url, authToken: profile.token, cameraEnabled: profile.cameraEnabled, locationEnabled: profile.locationEnabled, voiceWakeEnabled: profile.voiceWakeEnabled)
            try await connect(gatewayURL: url, authToken: profile.token)
        }
    }

    func reconnect() async throws {
        await operatorSession.disconnect()
        await nodeSession.disconnect()
        operatorConnected = false
        nodeConnected = false

        let activeProfile = await MainActor.run { ProfileManager.shared.activeProfile }
        guard let profile = activeProfile else {
            logger.log("log: No active profile for reconnect")
            return
        }

        let scheme = profile.tlsEnabled ? "wss" : "ws"
        let urlString = "\(scheme)://\(profile.host):\(profile.port)/gateway"
        guard let url = URL(string: urlString) else {
            logger.log("log: Invalid profile URL for reconnect")
            return
        }

        // Connect node first
        try await connectNodeRole(gatewayURL: url, authToken: profile.token, cameraEnabled: profile.cameraEnabled, locationEnabled: profile.locationEnabled, voiceWakeEnabled: profile.voiceWakeEnabled)

        // Connect operator
        try await connect(gatewayURL: url, authToken: profile.token)
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
