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
    // Concrete `GatewayNodeSession` retained for the chat-transport
    // path only. `GatewayChatTransport.init` takes a concrete
    // `GatewayNodeSession` (because it calls `subscribeServerEvents`,
    // which is not on the `ConnectionTransport` protocol). When the
    // coordinator is constructed with a mocked operator transport
    // for unit tests, this is `nil` and `getTransport(_:)` traps.
    // None of the test seams that use a mock call `getTransport`,
    // so this is safe.
    private let operatorRequestSession: GatewayNodeSession?

    // Protocol-typed seam for `connect` / `disconnect` / `request`.
    // Production wires these to the same `GatewayNodeSession` instance
    // `operatorRequestSession` points to; tests inject
    // `MockConnectionTransport` to drive the connect/disconnect race
    // deterministically.
    private let operatorTransport: any ConnectionTransport
    private let nodeTransport: any ConnectionTransport

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

    // Monotonic counter bumped by `cancelInFlight` (i.e. at the start
    // of every `switchToProfile`). Each `connectOperator` /
    // `connectNodeRole` snapshots it at entry; catch and success
    // paths compare the snapshot to the current value and treat a
    // mismatch as "a newer connect has started — my result is stale".
    // This suppresses the old connect's catch writing `setDisconnected`
    // over the new connect's `setConnecting`, which is what was
    // causing the "Failed → Disconnect" flicker on Switch.
    private var connectGeneration: Int = 0

    // Set to true by `disconnect()` so the SDK's onDisconnected
    // callbacks (which fire when the WebSocket closes — including
    // a user-initiated close) don't write `state.setReconnecting`
    // over our explicit `state.setDisconnected(reason: nil)`. The
    // SDK fires onDisconnected ASYNCHRONOUSLY: it can land AFTER
    // `disconnect()` returns, so without this flag the UI gets
    // stuck on "Reconnecting..." with no actual reconnect attempt.
    // Reset to false at the start of every `connectWithRole()` so
    // a subsequent connect is free to surface reconnect state.
    private var userInitiatedDisconnect: Bool = false

    // Transport cache: sessionKey -> GatewayChatTransport (conforms to
    // OpenClawChatTransport). One actor per session key for the lifetime of
    // the app.
    private var transports: [String: GatewayChatTransport] = [:]

    static let shared = ConnectionCoordinator(state: .shared)

    init(
        state: ConnectionState,
        operatorTransport: (any ConnectionTransport)? = nil,
        nodeTransport: (any ConnectionTransport)? = nil
    ) {
        self.state = state
        let opReal = GatewayNodeSession()
        let ndReal = GatewayNodeSession()
        if let op = operatorTransport {
            self.operatorTransport = op
            // Cast is what enables the chat-transport path. The cast
            // fails (and the property stays nil) when the test injects
            // a mock — `getTransport` then traps, as documented above.
            self.operatorRequestSession = op as? GatewayNodeSession
        } else {
            self.operatorTransport = opReal
            self.operatorRequestSession = opReal
        }
        if let nd = nodeTransport {
            self.nodeTransport = nd
        } else {
            self.nodeTransport = ndReal
        }
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
        // A new connect attempt means the user wants to be
        // connected again. Reset the user-initiated-disconnect
        // flag so the next disconnect is judged fresh, and so
        // the new connect's success path doesn't see a stale
        // "true" from a previous explicit disconnect.
        userInitiatedDisconnect = false
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
            // Run node + operator connects in parallel instead of
            // sequentially. Sequential was the previous default
            // (`await connectNodeRole(...); try await connectOperator(...)`),
            // but for `operatorAndNode` profiles both connections are
            // independent (separate transports, separate WebSockets) and
            // there is no ordering reason to wait for node before
            // starting operator. `withThrowingTaskGroup` ensures both
            // are awaited before returning and propagates any
            // `connectOperator` error to the caller.
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    await self.connectNodeRole(
                        gatewayURL: gatewayURL,
                        authToken: authToken,
                        enabledCaps: enabledCaps
                    )
                }
                group.addTask {
                    try await self.connectOperator(
                        gatewayURL: gatewayURL,
                        authToken: authToken
                    )
                }
                try await group.waitForAll()
            }
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
        // Bump the generation BEFORE cancelling so any catch / success
        // path that observes the cancellation also sees the new
        // generation and suppresses its state writes. Order matters:
        // if we cancelled first, a catch that ran synchronously could
        // see the old generation and still clobber state.
        connectGeneration += 1
        for (_, task) in inFlight {
            task.cancel()
        }
        inFlight = [:]
    }

    func disconnect() async {
        // Mark as user-initiated BEFORE the SDK tears down the
        // WebSocket. The SDK fires `onDisconnected` asynchronously,
        // and the callback can land AFTER this method returns and
        // after our explicit `state.setDisconnected(reason: nil)`.
        // The flag tells the onDisconnected handler to stay quiet
        // for this disconnect.
        userInitiatedDisconnect = true
        cancelInFlight()
        await operatorTransport.disconnect()
        await nodeTransport.disconnect()
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
            await operatorTransport.disconnect()
        }
        if openedNode {
            await nodeTransport.disconnect()
        }
    }

    /// Returns a cached `GatewayChatTransport` for `sessionKey`, or constructs
    /// a new one wrapping the operator session. One actor per session key.
    ///
    /// Traps if invoked on a coordinator constructed with a mocked
    /// operator transport — the chat-transport path requires a real
    /// `GatewayNodeSession` because `GatewayChatTransport.events()`
    /// calls `subscribeServerEvents`, which is not on the
    /// `ConnectionTransport` protocol. None of the test seams that
    /// use a mock call `getTransport`, so this trap is never reached
    /// in the test suite.
    func getTransport(sessionKey: String) -> GatewayChatTransport {
        if let cached = transports[sessionKey] { return cached }
        guard let session = operatorRequestSession else {
            fatalError("getTransport() called on a coordinator constructed with a mocked operator transport")
        }
        let chat = GatewayChatTransport(nodeSession: session, sessionKey: sessionKey)
        transports[sessionKey] = chat
        return chat
    }

    /// Drop a cached transport (called when a session is deleted).
    func invalidateTransport(sessionKey: String) {
        transports[sessionKey] = nil
    }

    /// Generic RPC forwarder. Exposes the underlying
    /// `operatorTransport.request(...)` so callers outside this
    /// actor (e.g. `ServerCommandSource` for `commands.list`)
    /// can fire arbitrary RPCs through the established
    /// operator connection.
    func request(method: String,
                 paramsJSON: String?,
                 timeoutSeconds: Int) async throws -> Data {
        try await operatorTransport.request(
            method: method,
            paramsJSON: paramsJSON,
            timeoutSeconds: timeoutSeconds
        )
    }

    /// Handle an SDK `onDisconnected` callback. The SDK fires this
    /// callback when the WebSocket closes — INCLUDING for a
    /// user-initiated close via `disconnect()`. Two cases must be
    /// suppressed to avoid clobbering state:
    ///
    /// 1. **User-initiated disconnect**: `disconnect()` set
    ///    `userInitiatedDisconnect = true` BEFORE the SDK teardown.
    ///    Without this guard, the callback would land after our
    ///    `state.setDisconnected(reason: nil)` and overwrite it with
    ///    `state.setReconnecting(reason:)` — leaving the UI stuck on
    ///    "Reconnecting..." with no actual reconnect attempt.
    ///
    /// 2. **Stale callback from a previous session**: when
    ///    `switchToProfile` calls `cancelInFlight`, `connectGeneration`
    ///    is bumped. The OLD session's onDisconnected callback
    ///    captures the OLD `generation`. When it fires (late), the
    ///    handler sees a mismatch and stays quiet — preventing the
    ///    stale callback from clobbering the NEW connect's
    ///    `.connecting` state with `.reconnecting`. (This is the
    ///    "Failed → Disconnect" flicker pattern, ported to the
    ///    onDisconnected path.)
    ///
    /// `internal` so tests can drive the handler directly (the SDK
    /// callback path can't be exercised without a real WebSocket).
    func handleTransportDisconnect(role: GatewayRole, reason: String, generation: Int) async {
        if userInitiatedDisconnect {
            AppLogger.log("\(role.rawValue) onDisconnected suppressed (user-initiated): \(reason)", category: .network)
            return
        }
        if generation != connectGeneration {
            AppLogger.log("\(role.rawValue) onDisconnected suppressed (stale generation=\(generation), current=\(connectGeneration)): \(reason)", category: .network)
            return
        }
        await MainActor.run { state.setReconnecting(reason: reason) }
    }

    /// Symmetric counterpart to `handleTransportDisconnect`. The SDK fires
    /// `onConnected` both on the initial connect AND on every successful
    /// reconnect (after `hasNotifiedConnected` is reset by
    /// `handleChannelDisconnected`). Without this handler, a reconnect
    /// leaves the UI stuck on `.reconnecting` forever even though the
    /// WebSocket is actually up — `state.phase` is only updated by our
    /// own `connectOperator` success path, which doesn't run when the
    /// SDK's internal watchdog reconnects on its own.
    ///
    /// Same two guards as `handleTransportDisconnect`:
    /// 1. **User-initiated disconnect**: if the user clicked "Disconnect",
    ///    `userInitiatedDisconnect` is true and we must not clobber the
    ///    `.disconnected` state with `.connected`.
    /// 2. **Stale generation**: a previous connect's `onConnected` may
    ///    fire after the user switched profiles / reconnected. The
    ///    generation guard prevents the old connect from marking the
    ///    new profile as connected.
    func handleTransportConnect(role: GatewayRole, generation: Int) async {
        if userInitiatedDisconnect {
            AppLogger.log("\(role.rawValue) onConnected suppressed (user-initiated)", category: .network)
            return
        }
        if generation != connectGeneration {
            AppLogger.log("\(role.rawValue) onConnected suppressed (stale generation=\(generation), current=\(connectGeneration))", category: .network)
            return
        }
        let deviceIdentity = DeviceIdentityStore.loadOrCreate()
        let deviceName = deviceIdentity.deviceId.prefix(16).description
        await MainActor.run {
            state.setConnected(deviceName: deviceName)
        }
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
        let responseData = try await operatorTransport.request(
            method: "sessions.create",
            paramsJSON: paramsJSON,
            timeoutSeconds: 15
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
        // Snapshot the generation so catch / success paths can detect
        // "a newer connect started while I was running" and treat
        // their result as stale. Bumped by `cancelInFlight` (called
        // at the start of every `switchToProfile`).
        let generation = connectGeneration
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
            try await operatorTransport.connect(
                url: gatewayURL,
                token: authToken,
                bootstrapToken: nil,
                password: nil,
                connectOptions: options,
                sessionBox: sessionBox,
                onConnected: {
                    AppLogger.log("Operator connected to gateway", category: .network)
                    // Structured await — the SDK's own caller awaits the
                    // closure (see `await self.onConnected?(...)` in
                    // GatewayNodeSession), so a fire-and-forget `Task { }`
                    // would lose ordering between handleTransportConnect
                    // and the rest of the test/state pipeline. Awaiting
                    // directly keeps state writes deterministic.
                    await self.handleTransportConnect(role: .operator, generation: generation)
                },
                onDisconnected: { reason in
                    AppLogger.log("Operator disconnected: \(reason)", category: .network)
                    // See comment on `onConnected` above — fire-and-forget
                    // here would let the test's `simulateDisconnected`
                    // return BEFORE the handler wrote `.reconnecting`,
                    // causing the test to observe stale `.connecting`.
                    await self.handleTransportDisconnect(role: .operator, reason: reason, generation: generation)
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
            // Even if our own Task wasn't cancelled, a newer connect
            // may have started (generation bumped by another
            // `cancelInFlight`). In that case our success is stale
            // — the new profile owns the connection now. Don't
            // commit operatorConnected / setConnected.
            if generation != connectGeneration {
                AppLogger.log("Operator connect succeeded but generation moved on; ignoring", category: .network)
                throw CancellationError()
            }
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
            // If a newer connect has started, our error is stale —
            // the new profile owns the connection now. Don't write
            // `setDisconnected` over its `setConnecting`.
            if generation != connectGeneration {
                AppLogger.log("Operator connect auth error but generation moved on; ignoring", category: .network)
                throw CancellationError()
            }
            let requestIdStr = error.requestId.map { " (requestId: \($0))" } ?? ""
            let displayError = SessionManagerError.authError(error.message + requestIdStr, error.detailCodeRaw)
            AppLogger.log("Auth error: \(error.message)\(requestIdStr)", category: .network, level: .error)
            await MainActor.run { state.setDisconnected(reason: error.message) }
            throw displayError
        } catch {
            // Same generation guard: a newer connect started while we
            // were in flight; our error belongs to an attempt the
            // user has already abandoned. Don't clobber state.
            if generation != connectGeneration {
                AppLogger.log("Operator connect error but generation moved on; ignoring", category: .network)
                throw CancellationError()
            }
            // Safety net for the generation guard: even when the
            // generation matches, a "cancelled" error message means
            // `cancelInFlight` (or `disconnect`, which calls it) tore
            // down our URLSession. The user has already moved on to
            // another profile; surfacing "Failed" with a cancelled
            // reason is a misleading flicker on the new row. Treat
            // as silent cancellation.
            let errorMessage = error.localizedDescription
            if errorMessage.range(of: "cancel", options: .caseInsensitive) != nil {
                AppLogger.log("Operator connect cancelled (error: \(errorMessage))", category: .network)
                throw CancellationError()
            }
            AppLogger.log("Connection error: \(errorMessage)", category: .network, level: .error)
            await MainActor.run { state.setDisconnected(reason: errorMessage) }
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
        try await operatorTransport.connect(
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
        // Snapshot the generation — see `connectOperator` for rationale.
        let generation = connectGeneration
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
            try await nodeTransport.connect(
                url: gatewayURL,
                token: authToken,
                bootstrapToken: nil,
                password: nil,
                connectOptions: options,
                sessionBox: sessionBox,
                onConnected: {
                    AppLogger.log("Node connected to gateway", category: .network)
                    // See the matching comment on the operator install
                    // site — structured await is required to keep state
                    // writes deterministic when the SDK's onConnected
                    // callback path is exercised by tests.
                    await self.handleTransportConnect(role: .node, generation: generation)
                },
                onDisconnected: { reason in
                    AppLogger.log("Node disconnected: \(reason)", category: .network)
                    await self.handleTransportDisconnect(role: .node, reason: reason, generation: generation)
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
            // Generation guard: even if our own Task wasn't cancelled,
            // a newer connect may have started. Don't commit
            // nodeConnected — the new profile owns the session now.
            if generation != connectGeneration {
                AppLogger.log("Node connect succeeded but generation moved on; ignoring", category: .network)
                return
            }
            nodeConnected = true
            AppLogger.log("Node connection established", category: .network)
        } catch is CancellationError {
            AppLogger.log("Node connect cancelled", category: .network)
        } catch {
            // Generation guard for the error path. The node catch
            // already doesn't write state, but the log is misleading
            // ("error") when the cause is just a newer connect
            // superseding us. Skip the log in that case.
            if generation != connectGeneration {
                AppLogger.log("Node connect error but generation moved on; ignoring", category: .network)
                return
            }
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
            try await nodeTransport.connect(
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
