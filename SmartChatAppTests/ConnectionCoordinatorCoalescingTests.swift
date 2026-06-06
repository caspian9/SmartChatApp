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
}
