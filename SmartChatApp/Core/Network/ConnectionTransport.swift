import Foundation
import OpenClawKit

/// Test seam for the WebSocket-backed `GatewayNodeSession`.
///
/// The production code (`ConnectionCoordinator`) only drives three methods
/// of `GatewayNodeSession` directly: `connect`, `disconnect`, and `request`.
/// The remaining surface (`subscribeServerEvents`, `currentCanvasHostUrl`,
/// etc.) is reached indirectly through `GatewayChatTransport` which holds
/// its own concrete reference. By abstracting only the three methods the
/// coordinator actually calls, we get a focused seam that unit tests can
/// implement with a deterministic mock — no more flaky tests that race
/// the real SDK's WebSocket teardown timing.
///
/// The signatures match `GatewayNodeSession.swift:187-196, 255-266,
/// 325-337` verbatim. `GatewayNodeSession` conforms via the free-floating
/// extension at the bottom of this file — no OpenClawKit source changes
/// required.
///
/// `Sendable` is required: the coordinator is an actor and calls into
/// the transport from inside its actor isolation. A test that injects a
/// non-Sendable mock will be a compile error, which is exactly the
/// safety net we want.
public protocol ConnectionTransport: Sendable {
    func connect(
        url: URL,
        token: String?,
        bootstrapToken: String?,
        password: String?,
        connectOptions: GatewayConnectOptions,
        sessionBox: WebSocketSessionBox?,
        onConnected: @escaping @Sendable () async -> Void,
        onDisconnected: @escaping @Sendable (String) async -> Void,
        onInvoke: @escaping @Sendable (BridgeInvokeRequest) async -> BridgeInvokeResponse
    ) async throws

    func disconnect() async

    func request(method: String, paramsJSON: String?, timeoutSeconds: Int) async throws -> Data
}

/// Free-floating conformance: `GatewayNodeSession` already provides all
/// three methods with matching signatures. The real `request` has a
/// default value for `timeoutSeconds`; Swift synthesizes the default at
/// the call site, so the protocol requirement's lack of a default does
/// not affect callers like `ConnectionCoordinator.createSession`.
extension GatewayNodeSession: ConnectionTransport {}
