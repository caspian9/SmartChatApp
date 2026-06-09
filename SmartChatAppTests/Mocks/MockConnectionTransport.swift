import Foundation
import OpenClawKit
import OpenClawProtocol
@testable import SmartChatApp

/// Script-driven mock `ConnectionTransport` for unit tests.
///
/// Tests configure a `connectScript` BEFORE triggering
/// `coordinator.ensureConnected(...)`; the mock replays the steps
/// in order, with each `connect` call consuming the first step.
/// Multi-step scenarios (e.g. "first connect hangs, second connect
/// succeeds") are expressed as a 2-element script
/// (`[.hang, .connected]`). The test then calls
/// `simulateDisconnected(reason:)` at deterministic points to fire
/// the SDK's `onDisconnected` callback.
///
/// This mock eliminates the WebSocket-teardown race that
/// `testNewerConnectSuppressesOldConnectsStateWrites` used to depend
/// on (and flake on). The test is now fully deterministic: no
/// `Task.sleep`, no `XCTSkip`, no dependency on real network timing.
actor MockConnectionTransport: ConnectionTransport {
    /// What the next `connect()` call should do.
    enum ConnectStep {
        /// Block until the task is cancelled (then throw
        /// `CancellationError`). Mirrors the real `GatewayNodeSession`
        /// connect behavior when the SDK's WebSocket is sitting open
        /// waiting for server messages.
        case hang

        /// Fire the registered `onConnected` closure, then return
        /// successfully. Mirrors a successful handshake.
        case connected

        /// Throw `GatewayConnectAuthError` (caught specially by
        /// `ConnectionCoordinator.connectOperator`).
        case throwAuthError(message: String, detailCodeRaw: String?)

        /// Throw any other error. The generic `catch` in
        /// `connectOperator` will see it.
        case throwError(Error)
    }

    /// FIFO queue of connect outcomes. Each `connect()` call removes
    /// and executes the first step. When the queue is empty, the
    /// default behavior is `.connected` (succeed silently).
    ///
    /// `nonisolated(unsafe)` so tests can pre-populate the script from
    /// the main actor before kicking off a connect (which then drains
    /// the script on the actor's own isolation). The test contract is
    /// "set the script before any `connect()` runs" — concurrent
    /// mutation from multiple actors is not expected.
    nonisolated(unsafe) var connectScript: [ConnectStep] = []

    /// All `onDisconnected` closures installed by past `connect()` calls,
    /// in install order (oldest first). The real
    /// `GatewayNodeSession` stores only the most recent closure
    /// (line 210 of `GatewayNodeSession.swift`), but in this test
    /// mock we want to drive the OLD session's callback independently
    /// of the NEW session's callback — so we keep the history.
    /// Tests use `simulateDisconnectedForCall(index:reason:)` to
    /// fire a specific connect's callback.
    private var onDisconnectedHistory: [@Sendable (String) async -> Void] = []
    private var lastOnConnected: (@Sendable () async -> Void)?
    private var lastOnDisconnected: (@Sendable (String) async -> Void)?

    /// Observation for assertions.
    private(set) var connectCallCount: Int = 0
    private(set) var disconnectCallCount: Int = 0
    private(set) var requestCallCount: Int = 0

    init() {}

    /// Test-driven trigger: invoke the `onDisconnected` closure
    /// installed by the `index`-th `connect()` call (0-based). This
    /// is the key API for race-condition tests: it lets the test
    /// fire OLD callbacks (with stale generation) independently of
    /// NEW callbacks (with matching generation). Awaitable so the
    /// test can `await` the callback's effect on state before
    /// reading the post-condition.
    func simulateDisconnectedForCall(index: Int, reason: String) async {
        guard index >= 0 && index < onDisconnectedHistory.count else {
            fatalError("simulateDisconnectedForCall(\(index)): no such connect call (history has \(onDisconnectedHistory.count) entries)")
        }
        let closure = onDisconnectedHistory[index]
        await closure(reason)
    }

    /// Test-driven trigger: invoke the most recently installed
    /// `onDisconnected` closure with `reason`. Awaitable so the
    /// test can `await` the callback's effect (state writes etc.)
    /// before reading the post-condition.
    func simulateDisconnected(reason: String) async {
        await lastOnDisconnected?(reason)
    }

    /// Test-driven trigger: invoke the most recently installed
    /// `onConnected` closure. Useful for tests that drive the
    /// connect/callback sequence manually instead of via the script.
    func simulateConnected() async {
        await lastOnConnected?()
    }

    // MARK: - ConnectionTransport

    nonisolated func connect(
        url: URL,
        token: String?,
        bootstrapToken: String?,
        password: String?,
        connectOptions: GatewayConnectOptions,
        sessionBox: WebSocketSessionBox?,
        onConnected: @escaping @Sendable () async -> Void,
        onDisconnected: @escaping @Sendable (String) async -> Void,
        onInvoke: @escaping @Sendable (BridgeInvokeRequest) async -> BridgeInvokeResponse
    ) async throws {
        try await _recordConnectAndRun(
            onConnected: onConnected,
            onDisconnected: onDisconnected
        )
    }

    nonisolated func disconnect() async {
        await _recordDisconnect()
    }

    nonisolated func request(method: String, paramsJSON: String?, timeoutSeconds: Int) async throws -> Data {
        await _recordRequest()
        // Default: empty Data. Tests that need a real response can
        // override via a subclass or by adding a response script
        // (out of scope for the current test set).
        return Data()
    }

    // MARK: - Actor-isolated bookkeeping

    private func _recordConnectAndRun(
        onConnected: @escaping @Sendable () async -> Void,
        onDisconnected: @escaping @Sendable (String) async -> Void
    ) async throws {
        connectCallCount += 1
        lastOnConnected = onConnected
        lastOnDisconnected = onDisconnected
        onDisconnectedHistory.append(onDisconnected)

        // Honor cancellation that arrived between the test's
        // `coordinator.cancelInFlight()` and this `connect` body.
        // The real `GatewayNodeSession` also checks for cancellation
        // before doing any work.
        if Task.isCancelled {
            throw CancellationError()
        }

        let step: ConnectStep = connectScript.isEmpty ? .connected : connectScript.removeFirst()
        switch step {
        case .hang:
            // Block until the task is cancelled. Use a finite sleep
            // to avoid `.max` parsing surprises — long enough that
            // the test will not see it complete on its own.
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000) // 60s
            } catch {
                throw CancellationError()
            }
            // If the sleep returned without cancellation (impossible
            // in practice for a 60s sleep during a unit test), treat
            // as a successful silent connect.
        case .connected:
            await onConnected()
        case .throwAuthError(let msg, let code):
            throw GatewayConnectAuthError(
                message: msg,
                detailCodeRaw: code,
                canRetryWithDeviceToken: false
            )
        case .throwError(let err):
            throw err
        }
    }

    private func _recordDisconnect() {
        disconnectCallCount += 1
    }

    private func _recordRequest() {
        requestCallCount += 1
    }
}
