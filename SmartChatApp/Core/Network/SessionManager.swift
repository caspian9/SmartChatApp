import Foundation
import OpenClawKit
import OpenClawProtocol
import OpenClawChatUI
import UIKit
import SwiftData

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

    func connectWithRole(gatewayURL: URL, authToken: String, role: GatewayConnectionRole, enabledCaps: Set<String>) async throws {
        switch role {
        case .operatorOnly:
            try await connect(gatewayURL: gatewayURL, authToken: authToken)
        case .nodeOnly:
            try await connectNodeRole(gatewayURL: gatewayURL, authToken: authToken, enabledCaps: enabledCaps)
        case .operatorAndNode:
            try await connectNodeRole(gatewayURL: gatewayURL, authToken: authToken, enabledCaps: enabledCaps)
            try await connect(gatewayURL: gatewayURL, authToken: authToken)
        }
    }

    func connectWithProfile(_ profile: GatewayProfile) async throws {
        let url = gatewayURL(host: profile.host, port: profile.port, tlsEnabled: profile.tlsEnabled)
        try await connectWithRole(gatewayURL: url, authToken: profile.token, role: profile.role, enabledCaps: profile.enabledCaps)
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
                    AppLogger.log("Operator connected to gateway", category: .network)
                },
                onDisconnected: { [weak self] reason in
                    AppLogger.log("Operator disconnected: \(reason)", category: .network)
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
            AppLogger.log("Operator connection established, deviceId: \(self.connectedDeviceName ?? "unknown")", category: .network)
            appendDebugLog("gateway: Operator connected to gateway", category: "gateway")
            appendDebugLog("gateway: Operator caps: \(connectOptions.caps.joined(separator: ", "))", category: "gateway")
            appendDebugLog("gateway: Operator commands: \(connectOptions.commands.joined(separator: ", "))", category: "gateway")
        } catch let error as GatewayConnectAuthError {
            let requestIdStr = error.requestId.map { " (requestId: \($0))" } ?? ""
            let displayError = SessionManagerError.authError(error.message + requestIdStr, error.detailCodeRaw)
            AppLogger.log("Auth error: \(error.message)\(requestIdStr)", category: .network, level: .error)
            appendDebugLog("gateway: Auth error: \(error.message)\(requestIdStr)", category: "gateway")
            throw displayError
        } catch {
            AppLogger.log("Connection error: \(error.localizedDescription)", category: .network, level: .error)
            appendDebugLog("gateway: Connection error: \(error.localizedDescription)", category: "gateway")
            throw error
        }
    }

    func connectNodeRole(gatewayURL: URL, authToken: String, enabledCaps: Set<String>) async throws {
        let deviceIdentity = DeviceIdentityStore.loadOrCreate()
        let nodeOptions = makeNodeConnectOptions(deviceIdentity: deviceIdentity, enabledCaps: enabledCaps)
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
                    AppLogger.log("Node connected to gateway", category: .network)
                },
                onDisconnected: { [weak self] reason in
                    AppLogger.log("Node disconnected: \(reason)", category: .network)
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
            AppLogger.log("Node connection established", category: .network)
            let caps = nodeCaps(enabledCaps: enabledCaps)
            let commands = nodeCommands(enabledCaps: enabledCaps)
            AppLogger.log("Node caps sent to gateway: \(caps)", category: .network)
            AppLogger.log("Node commands sent to gateway: \(commands)", category: .network)
            appendDebugLog("gateway: Node connected to gateway", category: "gateway")
            appendDebugLog("gateway: Node caps: \(caps.joined(separator: ", "))", category: "gateway")
            appendDebugLog("gateway: Node commands: \(commands.joined(separator: ", "))", category: "gateway")
        } catch {
            AppLogger.log("Node connection error: \(error.localizedDescription)", category: .network, level: .error)
            nodeConnectionError = error.localizedDescription
            appendDebugLog("gateway: Node connection error: \(error.localizedDescription)", category: "gateway")
        }
    }

    private func makeNodeConnectOptions(deviceIdentity: DeviceIdentity, enabledCaps: Set<String>) -> GatewayConnectOptions {
        GatewayConnectOptions(
            role: "node",
            scopes: [],
            caps: nodeCaps(enabledCaps: enabledCaps),
            commands: nodeCommands(enabledCaps: enabledCaps),
            permissions: nodePermissions(),
            clientId: "openclaw-ios",
            clientMode: "node",
            clientDisplayName: deviceIdentity.deviceId.prefix(16).description,
            includeDeviceIdentity: true
        )
    }

    private func nodeCaps(enabledCaps: Set<String>) -> [String] {
        // `device` is a real implementation (battery/thermal/storage/network/status,
        // device info), not a stub — advertise unconditionally so the gateway can
        // query it without the user toggling anything. The rest of the caps come
        // from the profile's enabled set; handlers stay registered, so profile
        // changes need a reconnect to take effect.
        var caps: [String] = [OpenClawCapability.device.rawValue]
        for cap in enabledCaps.sorted() where cap != OpenClawCapability.device.rawValue {
            caps.append(cap)
        }
        return caps
    }

    private func nodeCommands(enabledCaps: Set<String>) -> [String] {
        // Always advertise `device.*` to match the unconditional `device` cap.
        var commands: [String] = [
            OpenClawDeviceCommand.status.rawValue,
            OpenClawDeviceCommand.info.rawValue,
        ]
        if enabledCaps.contains(OpenClawCapability.camera.rawValue) {
            commands.append(contentsOf: [
                OpenClawCameraCommand.list.rawValue,
                OpenClawCameraCommand.snap.rawValue,
                OpenClawCameraCommand.clip.rawValue,
            ])
        }
        if enabledCaps.contains(OpenClawCapability.location.rawValue) {
            commands.append(OpenClawLocationCommand.get.rawValue)
        }
        if enabledCaps.contains(OpenClawCapability.contacts.rawValue) {
            commands.append(OpenClawContactsCommand.search.rawValue)
        }
        if enabledCaps.contains(OpenClawCapability.calendar.rawValue) {
            commands.append(OpenClawCalendarCommand.events.rawValue)
        }
        if enabledCaps.contains(OpenClawCapability.reminders.rawValue) {
            commands.append(OpenClawRemindersCommand.list.rawValue)
        }
        if enabledCaps.contains(OpenClawCapability.photos.rawValue) {
            commands.append(OpenClawPhotosCommand.latest.rawValue)
        }
        if enabledCaps.contains(OpenClawCapability.motion.rawValue) {
            commands.append(contentsOf: [
                OpenClawMotionCommand.activity.rawValue,
                OpenClawMotionCommand.pedometer.rawValue,
            ])
        }
        if enabledCaps.contains(OpenClawCapability.canvas.rawValue) {
            commands.append(OpenClawCanvasCommand.present.rawValue)
        }
        if enabledCaps.contains(OpenClawCapability.browser.rawValue) {
            commands.append(OpenClawBrowserCommand.proxy.rawValue)
        }
        if enabledCaps.contains(OpenClawCapability.screen.rawValue) {
            commands.append(OpenClawScreenCommand.snapshot.rawValue)
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
            AppLogger.log("No active profile available", category: .network)
            appendDebugLog("gateway: No active profile", category: "gateway")
            return
        }

        let role = profile.role
        if role == .operatorOnly && operatorConnected {
            AppLogger.log("Already connected (operator), skipping", category: .network)
            return
        }
        if role == .nodeOnly && nodeConnected {
            AppLogger.log("Already connected (node), skipping", category: .network)
            return
        }
        if role == .operatorAndNode && operatorConnected {
            AppLogger.log("Already connected (operator+node), skipping", category: .network)
            return
        }

        let scheme = profile.tlsEnabled ? "wss" : "ws"
        let urlString = "\(scheme)://\(profile.host):\(profile.port)/gateway"
        guard let url = URL(string: urlString) else {
            AppLogger.log("Invalid profile URL", category: .network, level: .error)
            return
        }
        AppLogger.log("Attempting to connect to: \(urlString)", category: .network)
        appendDebugLog("gateway: Connecting to \(urlString)", category: "gateway")

        switch role {
        case .operatorOnly:
            try await connect(gatewayURL: url, authToken: profile.token)
        case .nodeOnly:
            try await connectNodeRole(gatewayURL: url, authToken: profile.token, enabledCaps: profile.enabledCaps)
        case .operatorAndNode:
            try await connectNodeRole(gatewayURL: url, authToken: profile.token, enabledCaps: profile.enabledCaps)
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
            AppLogger.log("No active profile for reconnect", category: .network)
            return
        }

        let scheme = profile.tlsEnabled ? "wss" : "ws"
        let urlString = "\(scheme)://\(profile.host):\(profile.port)/gateway"
        guard let url = URL(string: urlString) else {
            AppLogger.log("Invalid profile URL for reconnect", category: .network, level: .error)
            return
        }

        // Connect node first
        try await connectNodeRole(gatewayURL: url, authToken: profile.token, enabledCaps: profile.enabledCaps)

        // Connect operator
        try await connect(gatewayURL: url, authToken: profile.token)
    }

    func disconnect() async {
        AppLogger.log("Disconnecting...", category: .network)
        appendDebugLog("gateway: Disconnecting...", category: "gateway")
        await operatorSession.disconnect()
        await nodeSession.disconnect()
        operatorConnected = false
        nodeConnected = false
        connectedDeviceName = nil
    }

    func setReconnectOnLaunch(_ value: Bool) {
        reconnectOnLaunch = value
        AppLogger.log("reconnectOnLaunch set to: \(value)", category: .network)
    }

    var shouldReconnectOnLaunch: Bool {
        reconnectOnLaunch
    }

    func checkConnection() async -> Bool {
        AppLogger.log("checkConnection called, operatorConnected: \(self.operatorConnected)", category: .network)
        if !operatorConnected {
            AppLogger.log("Not connected, attempting reconnect...", category: .network)
            appendDebugLog("gateway: Not connected, attempting reconnect...", category: "gateway")
            do {
                try await ensureConnected()
                return true
            } catch {
                AppLogger.log("Reconnect failed: \(error.localizedDescription)", category: .network, level: .error)
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
