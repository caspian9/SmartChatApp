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

    // Test-only counter: increments every time a real connect attempt begins
    // (i.e. `connectOperator` or `connectNodeRole` actually starts). Resets
    // on `disconnect()`. Used by `ConnectionCoordinatorCoalescingTests` to
    // assert that parallel `ensureConnected` calls coalesce into a single
    // underlying connect attempt. No production code reads this.
    private var connectAttemptCount: Int = 0

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

    // Test-only: number of connect attempts that have started since the last
    // `disconnect()`. See `connectAttemptCount` for context.
    nonisolated var currentConnectAttemptCount: Int {
        get async { await self._currentConnectAttemptCount() }
    }
    private func _currentConnectAttemptCount() -> Int { connectAttemptCount }

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

    /// Cancel all in-flight connect attempts (operator + node).
    /// Does NOT call `disconnect()` — the existing transport stays alive.
    /// Used by `ProfileManager.switchToProfile` to abort a connect attempt
    /// when the user changes their mind and switches to a different profile.
    func cancelInFlight() {
        for (_, task) in inFlight {
            task.cancel()
        }
        inFlight = [:]
    }

    func disconnect() async {
        cancelInFlight()
        await operatorSession.disconnect()
        await nodeSession.disconnect()
        operatorConnected = false
        nodeConnected = false
        connectedDeviceName = nil
        connectAttemptCount = 0
        await MainActor.run {
            self.state.setDisconnected(reason: nil)
        }
    }

    /// Test-only connect: same flow as `connectWithRole`, but does NOT
    /// touch `state.phase` / `operatorConnected` / `nodeConnected`.
    /// The caller (EditProfileSheet "Test Connection" button) reads
    /// `state.testInProgress` / `state.testLastResult` instead.
    func testConnect(
        gatewayURL: URL,
        authToken: String,
        role: GatewayConnectionRole,
        enabledCaps: Set<String>
    ) async throws {
        await MainActor.run {
            self.state.setTestInProgress()
        }
        // Track which roles we opened so the defer can tear down only those.
        // Without this, a successful test connect leaves the operator/node
        // session open and the next real `connectWithProfile` would re-open
        // an already-open session (which the SDK either errors on or
        // silently no-ops — both bad).
        var openedOperator = false
        var openedNode = false
        do {
            switch role {
            case .operatorOnly:
                try await connectOperatorForTest(gatewayURL: gatewayURL, authToken: authToken)
                openedOperator = true
            case .nodeOnly:
                await connectNodeRoleForTest(gatewayURL: gatewayURL, authToken: authToken, enabledCaps: enabledCaps)
                openedNode = true
            case .operatorAndNode:
                await connectNodeRoleForTest(gatewayURL: gatewayURL, authToken: authToken, enabledCaps: enabledCaps)
                openedNode = true
                try await connectOperatorForTest(gatewayURL: gatewayURL, authToken: authToken)
                openedOperator = true
            }
            await MainActor.run {
                self.state.setTestResult(.success)
            }
        } catch is CancellationError {
            await MainActor.run {
                self.state.setTestResult(.failure(reason: "cancelled"))
            }
            throw CancellationError()
        } catch {
            let reason = error.localizedDescription
            await MainActor.run {
                self.state.setTestResult(.failure(reason: reason))
            }
            throw error
        }
        // Tear down the test session so it doesn't leak. The actor is
        // serial, so awaiting disconnect here doesn't race with anything
        // except other in-flight test calls — and we don't support parallel
        // test connects (UI is single-button).
        if openedOperator {
            await operatorSession.disconnect()
        }
        if openedNode {
            await nodeSession.disconnect()
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
        connectAttemptCount += 1
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
        await MainActor.run {
            state.setConnecting(role: .operator)
        }
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
            // Throw if the in-flight task was cancelled (via
            // `cancelInFlight()`) before we commit success. Without this,
            // a profile switch mid-connect would race the success path and
            // leave `state.phase = .connected` even though the user
            // already moved on.
            try Task.checkCancellation()
            operatorConnected = true
            let deviceName = deviceIdentity.deviceId.prefix(16).description
            connectedDeviceName = deviceName
            await MainActor.run {
                state.setConnected(deviceName: deviceName)
            }
        } catch is CancellationError {
            // Don't surface cancellation as a "connection failure" — the
            // user just changed their mind. Leave state alone
            // (`setDisconnected` would clobber any current state).
            AppLogger.log("Operator connect cancelled", category: .network)
            throw CancellationError()
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

    /// Test-only variant of `connectOperator`. Performs the same SDK connect
    /// call but does NOT touch `state.phase` or `operatorConnected` — the
    /// caller's `state.testInProgress` / `state.testLastResult` track the
    /// outcome instead. This lets EditProfileSheet's "Test Connection"
    /// button probe a profile without disturbing the main connection.
    private func connectOperatorForTest(gatewayURL: URL, authToken: String) async throws {
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
        try await operatorSession.connect(
            url: gatewayURL,
            token: authToken,
            bootstrapToken: nil,
            password: nil,
            connectOptions: options,
            sessionBox: sessionBox,
            onConnected: {
                AppLogger.log("Operator test connected", category: .network)
            },
            onDisconnected: { _ in
                // No-op in test path — we don't track test state in
                // onDisconnected; the caller surfaces the result via
                // `state.testLastResult`.
            },
            onInvoke: { request in
                BridgeInvokeResponse(id: request.id, ok: true, payloadJSON: nil, error: nil)
            }
        )
        // IMPORTANT: do NOT set `operatorConnected = true` or call
        // `state.setConnected` — the test path is read-only with respect
        // to the main connection.
    }

    private func connectNodeRole(
        gatewayURL: URL,
        authToken: String,
        enabledCaps: Set<String>
    ) async {
        connectAttemptCount += 1
        let deviceIdentity = DeviceIdentityStore.loadOrCreate()
        let options = makeNodeOptions(
            deviceIdentity: deviceIdentity,
            enabledCaps: enabledCaps
        )
        let sessionBox = WebSocketSessionBox(session: URLSession.shared)
        let state = self.state
        let router = commandRouter
        await MainActor.run {
            state.setConnecting(role: .node)
        }
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
            // Same as `connectOperator`: throw if the in-flight task was
            // cancelled before we commit success. Cancellation is swallowed
            // (matching the existing silent-failure behavior for node
            // errors) so callers don't need to handle a new error type.
            try Task.checkCancellation()
            nodeConnected = true
            AppLogger.log("Node connection established", category: .network)
        } catch is CancellationError {
            AppLogger.log("Node connect cancelled", category: .network)
        } catch {
            AppLogger.log("Node connection error: \(error.localizedDescription)", category: .network, level: .error)
        }
    }

    /// Test-only variant of `connectNodeRole`. Same shape as
    /// `connectOperatorForTest` — does NOT touch `state.phase` or
    /// `nodeConnected`. Returns silently on success/failure; the caller
    /// (testConnect) updates `state.testLastResult`.
    private func connectNodeRoleForTest(
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
                    AppLogger.log("Node test connected", category: .network)
                },
                onDisconnected: { _ in
                    // No-op in test path.
                },
                onInvoke: { request in
                    await router.handle(request)
                }
            )
            // No `nodeConnected = true` — test path is read-only.
        } catch {
            AppLogger.log("Node test connection error: \(error.localizedDescription)", category: .network, level: .error)
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
