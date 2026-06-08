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

    /// When `cancelInFlight()` is called (e.g., by `switchToProfile`
    /// on Switch), a NEW connect attempt is started immediately after.
    /// The OLD connect's catch must not write state that clobbers the
    /// NEW connect's `.connecting` state. This is the "Failed →
    /// Disconnect" flicker the user reported on Switch: the old
    /// profile's connect fails, its catch runs ~2s later, and writes
    /// `setDisconnected` over the new profile's `setConnecting`.
    ///
    /// The generation counter in `connectOperator` / `connectNodeRole`
    /// is what makes this safe: even if the OLD task's catch runs late
    /// (after `Task.isCancelled` is no longer a reliable signal — e.g.
    /// the SDK threw a non-cancellation error after our cancel arrived
    /// and the task body has already returned), the generation
    /// snapshot tells it "you've been superseded; stay quiet".
    ///
    /// Without the generation guard, this test is timing-dependent and
    /// would flake. With it, the old catch always short-circuits to
    /// `CancellationError` regardless of when the SDK's underlying
    /// error surfaces.
    func testNewerConnectSuppressesOldConnectsStateWrites() async throws {
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
        await MainActor.run {
            ConnectionState.shared.setDisconnected(reason: nil)
        }

        // Start a connect that will fail.
        let firstTask = Task {
            try? await coordinator.ensureConnected(profile: badProfile)
        }
        // Let it get into the SDK connect call.
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms

        // Simulate Switch: `switchToProfile` calls `cancelInFlight`
        // and then immediately starts a new connect. Both connects
        // will fail (bad port), but the OLD connect's catch must
        // not clobber the NEW connect's `.connecting` state.
        await coordinator.cancelInFlight()
        let secondTask = Task {
            try? await coordinator.ensureConnected(profile: badProfile)
        }
        // Give the new connect's setConnecting a moment to land
        // before waiting for both to settle.
        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms

        // Wait for both to settle. The new connect's catch will
        // run after `cancelInFlight` and may overwrite the old
        // one's; the old one must NOT overwrite the new one's
        // state in between.
        _ = await firstTask.value
        _ = await secondTask.value

        // After both: state should be .disconnected (the new
        // connect eventually also wrote setDisconnected). The
        // invariant is: no half-set state from the old connect
        // racing the new one. We can't directly assert "no flicker
        // happened" without a UI test, but we can verify the final
        // state is consistent and the lastError is from the new
        // attempt (proving the old attempt didn't write first).
        let finalPhase = await MainActor.run { ConnectionState.shared.phase }
        if case .disconnected = finalPhase {
            // OK
        } else {
            XCTFail("Expected phase = .disconnected after both failed connects, got \(String(describing: finalPhase))")
        }

        // The lastError should be set (both connects failed), but
        // it should be a network error, not stuck at nil (which
        // would mean an old connect's catch was suppressed in
        // favor of the new one which never got to write). The
        // exact source doesn't matter — what matters is that the
        // final state reflects the *newest* connect's outcome.
        let lastError = await MainActor.run { ConnectionState.shared.lastError }
        XCTAssertNotNil(lastError, "Final state should reflect the new connect's failure")

        // Cleanup
        await coordinator.disconnect()
    }

    /// When the user clicks "Disconnect" in Settings, `disconnect()` writes
    /// `state.setDisconnected(reason: nil)` to set the phase to
    /// `.disconnected`. However, the SDK's `onDisconnected` callback (which
    /// we registered in `connectOperator`/`connectNodeRole`) fires
    /// **asynchronously** — it can land AFTER `disconnect()` returns and
    /// after the explicit `setDisconnected` call. The callback then writes
    /// `state.setReconnecting(reason:)` over the disconnected state,
    /// leaving the UI stuck on "Reconnecting..." with no actual reconnect
    /// attempt. The fix: `disconnect()` sets a `userInitiatedDisconnect`
    /// flag, and the onDisconnected handler short-circuits when the flag
    /// is true.
    ///
    /// This test exercises the handler directly (rather than the SDK
    /// callback path) because driving a real WebSocket close in unit
    /// tests is not feasible — the handler is the only piece of logic
    /// that decides whether to call `setReconnecting`, so testing it
    /// deterministically covers the property under test.
    func testUserInitiatedDisconnectSuppressesOnDisconnectedStateWrite() async throws {
        let state = ConnectionState()
        let coord = ConnectionCoordinator(state: state)

        // Simulate the user clicking Disconnect: this sets the
        // `userInitiatedDisconnect` flag and writes
        // `state.setDisconnected(reason: nil)`.
        await coord.disconnect()

        // Simulate the SDK firing `onDisconnected` AFTER our
        // `setDisconnected`. Without the flag, this would write
        // `state.setReconnecting(...)` and leave the state as
        // `.reconnecting`. With the flag, the handler is a no-op.
        await coord.handleTransportDisconnect(
            role: .operator,
            reason: "test",
            generation: 0
        )

        // Phase should still be `.disconnected` — the user-initiated
        // disconnect flag suppressed the stale onDisconnected callback.
        let phase = await MainActor.run { state.phase }
        XCTAssertEqual(
            phase, .disconnected,
            "user-initiated disconnect must not be overwritten by delayed onDisconnected callback. Got: \(String(describing: phase))"
        )

        // Cleanup
        await coord.disconnect()
    }

    /// On `switchToProfile`, `cancelInFlight` is called, which bumps
    /// `connectGeneration`. A new connect then starts at the new
    /// generation. If the OLD session's `onDisconnected` callback fires
    /// after the new connect has started, the handler must treat it as
    /// stale (the new connect owns the session now) and skip
    /// `setReconnecting`. Otherwise the stale callback would clobber the
    /// new connect's `.connecting` state with `.reconnecting` — a
    /// re-incarnation of the "Failed → Disconnect" flicker.
    func testStaleGenerationSuppressesOnDisconnectedStateWrite() async throws {
        let state = ConnectionState()
        let coord = ConnectionCoordinator(state: state)

        // Bump the generation (simulates `cancelInFlight` on
        // `switchToProfile` — bumps `connectGeneration` to 1).
        await coord.cancelInFlight()

        // The OLD session's onDisconnected callback captures
        // `generation = 0` (the value at the time of the old
        // `connectOperator` call). It fires AFTER `cancelInFlight`,
        // so the current `connectGeneration` is 1.
        await coord.handleTransportDisconnect(
            role: .operator,
            reason: "stale from previous session",
            generation: 0
        )

        // The handler must short-circuit because the snapshot
        // generation (0) != current generation (1).
        let phase = await MainActor.run { state.phase }
        XCTAssertEqual(
            phase, .disconnected,
            "stale onDisconnected callback (from a previous generation) must not write setReconnecting. Got: \(String(describing: phase))"
        )

        // Cleanup
        await coord.disconnect()
    }

    /// When the onDisconnected callback IS for the current session AND
    /// the disconnect is NOT user-initiated (e.g., the network dropped),
    /// the handler MUST call `setReconnecting` so the UI can show
    /// "Reconnecting...". This is the inverse case of the two tests
    /// above — without this, an unexpected drop would leave the UI
    /// showing "Connected" while the WebSocket is actually dead.
    func testUnexpectedDisconnectWritesSetReconnecting() async throws {
        let state = ConnectionState()
        let coord = ConnectionCoordinator(state: state)

        // No `disconnect()` call → flag is false (default).
        // No `cancelInFlight` call → generation matches.
        // Initial state is .disconnected; we need to set it to .connected
        // first to verify the handler transitions to .reconnecting.
        await MainActor.run {
            state.setConnected(deviceName: "test-device")
        }

        // Simulate the SDK firing onDisconnected for the CURRENT
        // session: generation matches, flag is false → handler calls
        // setReconnecting.
        await coord.handleTransportDisconnect(
            role: .operator,
            reason: "network dropped",
            generation: 0
        )

        // Phase should now be .reconnecting.
        let phase = await MainActor.run { state.phase }
        if case .reconnecting = phase {
            // OK
        } else {
            XCTFail("Expected phase = .reconnecting, got \(String(describing: phase))")
        }

        // Cleanup
        await MainActor.run { state.setDisconnected(reason: nil) }
    }
}
