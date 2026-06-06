import XCTest
@testable import SmartChatApp

@MainActor
final class ConnectionCoordinatorCoalescingTests: XCTestCase {
    /// Two parallel `ensureConnected` calls with the same profile must share
    /// one in-flight connect task. We assert on elapsed time: with
    /// coalescing, total ≈ one failed connect attempt (~connection refused
    /// in <1s); without coalescing, it'd be ~2×.
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

        // Make sure we start disconnected.
        await coordinator.disconnect()

        let t0 = Date()
        async let r1: Void = {
            do { try await coordinator.ensureConnected(profile: badProfile) }
            catch { /* expected: connect fails */ }
        }()
        async let r2: Void = {
            do { try await coordinator.ensureConnected(profile: badProfile) }
            catch { /* expected: connect fails */ }
        }()
        _ = await (r1, r2)
        let elapsed = Date().timeIntervalSince(t0)
        XCTAssertLessThan(elapsed, 1.8, "ensureConnected should coalesce (elapsed: \(elapsed)s)")

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
}
