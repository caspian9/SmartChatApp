import Foundation
import OpenClawKit
import OpenClawProtocol
import OpenClawChatUI

/// Process-level owner of the two `GatewayNodeSession` instances (operator +
/// node) and the single observable `ConnectionState`.
///
/// Responsibilities:
/// - Owns 2 `GatewayNodeSession` (operator + node), wires their `onConnected`
///   / `onDisconnected` callbacks to `ConnectionState`.
/// - Coalesces `ensureConnected(profile:)` so N parallel calls result in 1
///   in-flight connect attempt.
/// - Caches one `GatewayChatTransport` per session key (returned by
///   `getTransport(sessionKey:)`).
actor ConnectionCoordinator {
    private let operatorSession: GatewayNodeSession
    private let nodeSession: GatewayNodeSession
    private let state: ConnectionState
    private let commandRouter = NodeCommandRouter()

    // Per-role connect status (mirrors today's `operatorConnected` /
    // `nodeConnected` flags in SessionManager).
    private var operatorConnected = false
    private var nodeConnected = false
    private var connectedDeviceName: String?

    // In-flight connect tasks, keyed by role. Coalesces parallel ensureConnected.
    private var inFlight: [GatewayRole: Task<Void, Error>] = [:]

    // Transport cache: sessionKey -> GatewayChatTransport (conforms to
    // OpenClawChatTransport). One actor per session key for the lifetime of
    // the app.
    private var transports: [String: GatewayChatTransport] = [:]

    static let shared = ConnectionCoordinator(state: .shared)

    init(state: ConnectionState) {
        self.state = state
        self.operatorSession = GatewayNodeSession()
        self.nodeSession = GatewayNodeSession()
    }

    // MARK: - Public API (used by SessionManager forwarders)

    nonisolated var connectionStatus: Bool { get async { await self._connectionStatus() } }
    private func _connectionStatus() -> Bool { operatorConnected }

    nonisolated var nodeConnectionStatus: Bool { get async { await self._nodeConnectionStatus() } }
    private func _nodeConnectionStatus() -> Bool { nodeConnected }

    nonisolated var deviceName: String? { get async { await self._deviceName() } }
    private func _deviceName() -> String? { connectedDeviceName }

    func connectWithProfile(_ profile: GatewayProfile) async throws {
        let url = gatewayURL(host: profile.host, port: profile.port, tlsEnabled: profile.tlsEnabled)
        try await connectWithRole(
            gatewayURL: url,
            authToken: profile.token,
            role: profile.role,
            enabledCaps: profile.enabledCaps
        )
    }

    func connectWithRole(
        gatewayURL: URL,
        authToken: String,
        role: GatewayConnectionRole,
        enabledCaps: Set<String>
    ) async throws {
        switch role {
        case .operatorOnly:
            try await connectOperator(gatewayURL: gatewayURL, authToken: authToken)
        case .nodeOnly:
            await connectNodeRole(
                gatewayURL: gatewayURL,
                authToken: authToken,
                enabledCaps: enabledCaps
            )
        case .operatorAndNode:
            await connectNodeRole(
                gatewayURL: gatewayURL,
                authToken: authToken,
                enabledCaps: enabledCaps
            )
            try await connectOperator(gatewayURL: gatewayURL, authToken: authToken)
        }
    }

    func ensureConnected(profile: GatewayProfile) async throws {
        // Already connected at the role the profile requires?
        switch profile.role {
        case .operatorOnly where operatorConnected,
             .nodeOnly where nodeConnected,
             .operatorAndNode where operatorConnected:
            return
        default:
            break
        }
        // Coalesce: if a connect for the same role is in flight, await it.
        let roleKey: GatewayRole = profile.role == .nodeOnly ? .node : .`operator`
        if let existing = inFlight[roleKey] {
            try await existing.value
            return
        }
        let task = Task<Void, Error> { [profile] in
            try await self.connectWithProfile(profile)
        }
        inFlight[roleKey] = task
        defer { inFlight[roleKey] = nil }
        try await task.value
    }

    func disconnect() async {
        await operatorSession.disconnect()
        await nodeSession.disconnect()
        operatorConnected = false
        nodeConnected = false
        connectedDeviceName = nil
        await MainActor.run {
            self.state.setDisconnected(reason: nil)
        }
    }

    /// Returns a cached `GatewayChatTransport` for `sessionKey`, or constructs
    /// a new one wrapping `operatorSession`. One actor per session key.
    func getTransport(sessionKey: String) -> GatewayChatTransport {
        if let cached = transports[sessionKey] { return cached }
        let chat = GatewayChatTransport(nodeSession: operatorSession, sessionKey: sessionKey)
        transports[sessionKey] = chat
        return chat
    }

    /// Drop a cached transport (called when a session is deleted).
    func invalidateTransport(sessionKey: String) {
        transports[sessionKey] = nil
    }

    func createSession(agentId: String? = nil, customKey: String? = nil) async throws -> String {
        var params: [String: String] = [:]
        if let agentId, !agentId.isEmpty { params["agentId"] = agentId }
        if let customKey, !customKey.isEmpty { params["key"] = customKey }
        let paramsJSON: String?
        if params.isEmpty {
            paramsJSON = nil
        } else {
            let data = try JSONEncoder().encode(params)
            paramsJSON = String(data: data, encoding: .utf8)
        }
        let responseData = try await operatorSession.request(
            method: "sessions.create",
            paramsJSON: paramsJSON
        )
        struct CreateSessionResponse: Decodable { let key: String }
        guard let r = try? JSONDecoder().decode(CreateSessionResponse.self, from: responseData) else {
            throw SessionManagerError.invalidResponse
        }
        return r.key
    }

    nonisolated func gatewayURL(host: String, port: Int, tlsEnabled: Bool) -> URL {
        let scheme = tlsEnabled ? "wss" : "ws"
        return URL(string: "\(scheme)://\(host):\(port)/gateway")!
    }

    // MARK: - Private

    private func connectOperator(gatewayURL: URL, authToken: String) async throws {
        let deviceIdentity = DeviceIdentityStore.loadOrCreate()
        let options = GatewayConnectOptions(
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
        let state = self.state
        do {
            try await operatorSession.connect(
                url: gatewayURL,
                token: authToken,
                bootstrapToken: nil,
                password: nil,
                connectOptions: options,
                sessionBox: sessionBox,
                onConnected: {
                    AppLogger.log("Operator connected to gateway", category: .network)
                },
                onDisconnected: { reason in
                    AppLogger.log("Operator disconnected: \(reason)", category: .network)
                    Task { @MainActor in
                        state.setReconnecting(reason: reason)
                    }
                },
                onInvoke: { request in
                    BridgeInvokeResponse(id: request.id, ok: true, payloadJSON: nil, error: nil)
                }
            )
            operatorConnected = true
            let deviceName = deviceIdentity.deviceId.prefix(16).description
            connectedDeviceName = deviceName
            await MainActor.run {
                state.setConnected(deviceName: deviceName)
            }
        } catch let error as GatewayConnectAuthError {
            let requestIdStr = error.requestId.map { " (requestId: \($0))" } ?? ""
            let displayError = SessionManagerError.authError(error.message + requestIdStr, error.detailCodeRaw)
            AppLogger.log("Auth error: \(error.message)\(requestIdStr)", category: .network, level: .error)
            await MainActor.run { state.setDisconnected(reason: error.message) }
            throw displayError
        } catch {
            AppLogger.log("Connection error: \(error.localizedDescription)", category: .network, level: .error)
            await MainActor.run { state.setDisconnected(reason: error.localizedDescription) }
            throw error
        }
    }

    private func connectNodeRole(
        gatewayURL: URL,
        authToken: String,
        enabledCaps: Set<String>
    ) async {
        let deviceIdentity = DeviceIdentityStore.loadOrCreate()
        let options = makeNodeOptions(
            deviceIdentity: deviceIdentity,
            enabledCaps: enabledCaps
        )
        let sessionBox = WebSocketSessionBox(session: URLSession.shared)
        let state = self.state
        let router = commandRouter
        do {
            try await nodeSession.connect(
                url: gatewayURL,
                token: authToken,
                bootstrapToken: nil,
                password: nil,
                connectOptions: options,
                sessionBox: sessionBox,
                onConnected: {
                    AppLogger.log("Node connected to gateway", category: .network)
                },
                onDisconnected: { reason in
                    AppLogger.log("Node disconnected: \(reason)", category: .network)
                    Task { @MainActor in
                        state.setReconnecting(reason: reason)
                    }
                },
                onInvoke: { request in
                    await router.handle(request)
                }
            )
            nodeConnected = true
            AppLogger.log("Node connection established", category: .network)
        } catch {
            AppLogger.log("Node connection error: \(error.localizedDescription)", category: .network, level: .error)
        }
    }

    // MARK: - Node option builders (mirrors the new per-cap logic in
    // commit 661c8df: `device` cap is always-on, the rest come from
    // the profile's `enabledCaps` set. Command set is derived from the
    // cap set so the gateway handshake advertises a matching command
    // set per cap.)

    private func makeNodeOptions(
        deviceIdentity: DeviceIdentity,
        enabledCaps: Set<String>
    ) -> GatewayConnectOptions {
        GatewayConnectOptions(
            role: "node",
            scopes: [],
            caps: nodeCaps(enabledCaps: enabledCaps),
            commands: nodeCommands(enabledCaps: enabledCaps),
            permissions: [:],
            clientId: "openclaw-ios",
            clientMode: "node",
            clientDisplayName: deviceIdentity.deviceId.prefix(16).description,
            includeDeviceIdentity: true
        )
    }

    private func nodeCaps(enabledCaps: Set<String>) -> [String] {
        // `device` is always-on (real impl, not a stub). The rest come
        // from the profile's enabled set. `device` is appended once.
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
        if enabledCaps.contains(OpenClawCapability.canvas.rawValue) {
            commands.append(contentsOf: [
                OpenClawCanvasCommand.present.rawValue,
                OpenClawCanvasCommand.hide.rawValue,
                OpenClawCanvasCommand.navigate.rawValue,
                OpenClawCanvasCommand.evalJS.rawValue,
                OpenClawCanvasCommand.snapshot.rawValue,
            ])
        }
        if enabledCaps.contains(OpenClawCapability.canvas.rawValue) {
            commands.append(contentsOf: [
                OpenClawCanvasA2UICommand.push.rawValue,
                OpenClawCanvasA2UICommand.pushJSONL.rawValue,
                OpenClawCanvasA2UICommand.reset.rawValue,
            ])
        }
        if enabledCaps.contains(OpenClawCapability.screen.rawValue) {
            commands.append(OpenClawScreenCommand.record.rawValue)
        }
        if enabledCaps.contains(OpenClawCapability.talk.rawValue) {
            commands.append(contentsOf: [
                OpenClawTalkCommand.pttStart.rawValue,
                OpenClawTalkCommand.pttStop.rawValue,
                OpenClawTalkCommand.pttCancel.rawValue,
                OpenClawTalkCommand.pttOnce.rawValue,
            ])
        }
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
        if enabledCaps.contains(OpenClawCapability.photos.rawValue) {
            commands.append(OpenClawPhotosCommand.latest.rawValue)
        }
        if enabledCaps.contains(OpenClawCapability.contacts.rawValue) {
            commands.append(contentsOf: [
                OpenClawContactsCommand.search.rawValue,
                OpenClawContactsCommand.add.rawValue,
            ])
        }
        if enabledCaps.contains(OpenClawCapability.calendar.rawValue) {
            commands.append(contentsOf: [
                OpenClawCalendarCommand.events.rawValue,
                OpenClawCalendarCommand.add.rawValue,
            ])
        }
        if enabledCaps.contains(OpenClawCapability.reminders.rawValue) {
            commands.append(contentsOf: [
                OpenClawRemindersCommand.list.rawValue,
                OpenClawRemindersCommand.add.rawValue,
            ])
        }
        if enabledCaps.contains(OpenClawCapability.motion.rawValue) {
            commands.append(contentsOf: [
                OpenClawMotionCommand.activity.rawValue,
                OpenClawMotionCommand.pedometer.rawValue,
            ])
        }
        if enabledCaps.contains(OpenClawCapability.browser.rawValue) {
            commands.append(OpenClawBrowserCommand.proxy.rawValue)
        }
        if enabledCaps.contains(OpenClawCapability.screen.rawValue) {
            commands.append(OpenClawScreenCommand.snapshot.rawValue)
        }
        return commands
    }
}
