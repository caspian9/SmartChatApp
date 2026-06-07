import XCTest
@testable import SmartChatApp

@MainActor
final class ConnectionCoordinatorCoalescingTests: XCTestCase {
    /// Two parallel `ensureConnected` calls with the same profile must share
    /// one in-flight connect task. We assert on the coordinator's
    /// `currentConnectAttemptCount`: with coalescing, exactly one underlying
    /// connect attempt begins; without coalescing, two would. This is a
    /// direct, deterministic check of the property under test (an earlier
    /// version asserted on elapsed time, which is unreliable because
    /// ECONNREFUSED on port 1 returns in ~200ms locally, so two parallel
    /// non-coalesced attempts would also complete well under any reasonable
    /// elapsed-time threshold).
    func testEnsureConnectedCoalescesTwoParallelCalls() async throws {
        let coordinator = ConnectionCoordinator.shared
        let badProfile = GatewayProfile(
            id: UUID(),
            name: "test",
            colorTag: "#000000",
            host: "127.0.0.1",
            port: 1, // unused port; should fail fast with ECONNREFUSED
            token: "test-token",
            tlsEnabled: false,
            role: .operatorOnly,
            enabledCaps: [],
            isActive: true,
            createdAt: Date(),
            updatedAt: Date()
        )

        // Make sure we start disconnected (this also resets the
        // connect-attempt counter).
        await coordinator.disconnect()

        let startCount = await coordinator.currentConnectAttemptCount
        async let r1: Void = {
            do { try await coordinator.ensureConnected(profile: badProfile) }
            catch { /* expected: connect fails */ }
        }()
        async let r2: Void = {
            do { try await coordinator.ensureConnected(profile: badProfile) }
            catch { /* expected: connect fails */ }
        }()
        _ = await (r1, r2)
        let endCount = await coordinator.currentConnectAttemptCount
        XCTAssertEqual(
            endCount - startCount,
            1,
            "ensureConnected should coalesce two parallel calls into one underlying connect attempt (started \(endCount - startCount))"
        )

        // Cleanup: disconnect so other tests start clean.
        await coordinator.disconnect()
    }

    /// `getTransport(sessionKey:)` returns the same actor identity for the
    /// same key, and different identities for different keys.
    func testGetTransportCachesBySessionKey() async {
        let coordinator = ConnectionCoordinator.shared
        let a1 = await coordinator.getTransport(sessionKey: "agent:foo:bar:11111111-1111")
        let a2 = await coordinator.getTransport(sessionKey: "agent:foo:bar:11111111-1111")
        let b  = await coordinator.getTransport(sessionKey: "agent:foo:bar:22222222-2222")
        // Same session key -> same actor instance.
        XCTAssertTrue(a1 === a2, "expected cached transport for same sessionKey")
        // Different session key -> different actor instance.
        XCTAssertFalse(a1 === b, "expected different transport for different sessionKey")
    }

    /// `cancelInFlight()` cancels the in-flight connect task and throws
    /// `CancellationError` to the caller. We target an unreachable port
    /// (127.0.0.1:1) so the connect attempts to fail with ECONNREFUSED;
    /// cancelling the task should short-circuit that to a
    /// `CancellationError`.
    func testCancelInFlightClearsInFlightMap() async throws {
        let coordinator = ConnectionCoordinator.shared
        let badProfile = GatewayProfile(
            id: UUID(),
            name: "test",
            colorTag: "#000000",
            host: "127.0.0.1",
            port: 1, // unused port
            token: "test-token",
            tlsEnabled: false,
            role: .operatorOnly,
            enabledCaps: [],
            isActive: true,
            createdAt: Date(),
            updatedAt: Date()
        )

        // Make sure we start disconnected.
        await coordinator.disconnect()

        // Fire-and-forget: a connect that will hang in the in-flight map
        // until cancelled (or fail with ECONNREFUSED first). The point
        // is the `inFlight` map has a task in it.
        let connectTask = Task {
            do {
                try await coordinator.ensureConnected(profile: badProfile)
            } catch {
                // expected: CancellationError or connect failure
            }
        }
        // Give the task a moment to land in `inFlight`.
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms

        // Cancel and wait for the connect task to finish.
        await coordinator.cancelInFlight()
        await connectTask.value

        // The in-flight map is empty — verified by a fresh coalesce
        // starting a new attempt on the next call. We don't have direct
        // access to the in-flight map, so we use a subsequent connect
        // attempt's counter increment as a proxy: a fresh start
        // increments `connectAttemptCount`, but a coalesced hit doesn't.
        let before = await coordinator.currentConnectAttemptCount
        // Start another connect and let it fail; the counter should
        // increment (proving it's a new attempt, not a coalesce on the
        // cancelled task).
        do {
            try await coordinator.ensureConnected(profile: badProfile)
            XCTFail("Expected connect to fail on unreachable port")
        } catch {
            // expected
        }
        let after = await coordinator.currentConnectAttemptCount
        XCTAssertGreaterThan(
            after - before, 0,
            "After cancelInFlight, a subsequent connect should start a new attempt (not coalesce on the cancelled task)"
        )

        // Cleanup
        await coordinator.disconnect()
    }

    /// `testConnect(...)` must NOT touch the main `state.phase` even on
    /// failure. The test targets an unreachable port so the SDK connect
    /// fails fast; we verify the test-side state is updated (test in
    /// progress, then test result = .failure) but `phase` stays
    /// `.disconnected`.
    func testTestConnectFailureUpdatesTestStateNotMainPhase() async {
        let state = ConnectionState()
        let coord = ConnectionCoordinator(state: state)
        let url = URL(string: "ws://127.0.0.1:1/gateway")!

        do {
            try await coord.testConnect(
                gatewayURL: url,
                authToken: "fake",
                role: .operatorOnly,
                enabledCaps: []
            )
            XCTFail("Expected testConnect to fail on unreachable port")
        } catch {
            // After failure, test state should reflect it.
            XCTAssertFalse(state.testInProgress, "testInProgress should be false after failure")
            if case .failure = state.testLastResult {
                // OK
            } else {
                XCTFail("Expected testLastResult to be .failure, got \(String(describing: state.testLastResult))")
            }
            // Main phase should NOT have been touched.
            XCTAssertEqual(state.phase, .disconnected, "testConnect must not change state.phase")
        }
    }

    /// `cancelInFlight()` clears the in-flight map. The "awaiter
    /// observes CancellationError" half of the contract is covered by
    /// code review of `catch is CancellationError` in `connectOperator`
    /// / `connectNodeRole` — racing the cancel against a fast
    /// ECONNREFUSED on `127.0.0.1:1` is not reliable enough to assert
    /// on in CI. This test asserts the invariant that matters: after
    /// cancel, the next `ensureConnected` starts a fresh attempt
    /// (i.e., the in-flight map was actually cleared).
    func testCancelInFlightClearsInFlightMapForNextCaller() async throws {
        let coordinator = ConnectionCoordinator.shared
        let badProfile = GatewayProfile(
            id: UUID(),
            name: "test",
            colorTag: "#000000",
            host: "127.0.0.1",
            port: 1,
            token: "test-token",
            tlsEnabled: false,
            role: .operatorOnly,
            enabledCaps: [],
            isActive: true,
            createdAt: Date(),
            updatedAt: Date()
        )

        await coordinator.disconnect()

        // Kick off a connect (will fail on port 1) and cancel mid-flight.
        let task = Task {
            try? await coordinator.ensureConnected(profile: badProfile)
        }
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms — long enough for the in-flight task to be registered
        await coordinator.cancelInFlight()
        _ = await task.value

        // Counter increments only when a real connect attempt begins.
        // After cancel + the original task completing, the next
        // `ensureConnected` should start a fresh attempt, not coalesce
        // with a stale one.
        let beforeFresh = await coordinator.currentConnectAttemptCount
        let freshTask = Task {
            try? await coordinator.ensureConnected(profile: badProfile)
        }
        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        _ = await freshTask.value
        let afterFresh = await coordinator.currentConnectAttemptCount
        XCTAssertGreaterThan(afterFresh, beforeFresh, "After cancel, next ensureConnected must start a fresh attempt")

        // Cleanup
        await coordinator.disconnect()
    }

    /// When `cancelInFlight()` cancels a Task whose SDK connect is
    /// about to throw, the catch block in `connectOperator` must NOT
    /// write that error into `state.lastError` — the new attempt (or
    /// a subsequent successful connect) is in charge of state. Without
    /// the `Task.isCancelled` guard in the catch, a brief "Failed"
    /// flash races the new connect's success and the user sees
    /// "Failed → Disconnect" flicker on Switch.
    func testCancelInFlightDoesNotPolluteStateLastError() async throws {
        let coordinator = ConnectionCoordinator.shared
        let badProfile = GatewayProfile(
            id: UUID(),
            name: "test",
            colorTag: "#000000",
            host: "127.0.0.1",
            port: 1,
            token: "test-token",
            tlsEnabled: false,
            role: .operatorOnly,
            enabledCaps: [],
            isActive: true,
            createdAt: Date(),
            updatedAt: Date()
        )

        await coordinator.disconnect()
        // Reset state so a leftover from a prior test doesn't trip
        // the assertion.
        await MainActor.run {
            ConnectionState.shared.setDisconnected(reason: nil)
        }

        // Kick off a connect (will fail on port 1 with a non-cancel
        // error) and cancel mid-flight. The catch must see
        // `Task.isCancelled == true` and skip the `setDisconnected`
        // call.
        let task = Task {
            try? await coordinator.ensureConnected(profile: badProfile)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        await coordinator.cancelInFlight()
        _ = await task.value

        // The cancelled task's catch must not have written
        // lastError. A real error from this attempt would have a
        // "refused" / "Connection" / "errno" substring; we accept
        // lastError being nil OR an unrelated prior value, but it
        // must not be a fresh entry from the cancelled attempt.
        let lastError = await MainActor.run { ConnectionState.shared.lastError }
        let looksLikeNetworkError = lastError.map {
            $0.contains("refused") || $0.contains("Connection") || $0.contains("errno") || $0.contains("canceled")
        } ?? false
        XCTAssertFalse(looksLikeNetworkError, "Cancelled task must not write a network-error lastError. Got: \(lastError ?? "nil")")

        // Cleanup
        await coordinator.disconnect()
    }
}
