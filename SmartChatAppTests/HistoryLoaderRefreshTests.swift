import XCTest
import OpenClawChatUI
@testable import SmartChatApp

@MainActor
final class HistoryLoaderRefreshTests: XCTestCase {
    var sut: NativeChatViewModel!

    override func setUp() async throws {
        try await super.setUp()
        // Start disconnected so the network call in refreshFromServer fails
        // fast (no active profile → ensureConnected throws / times out
        // quickly). Each test cleans up after itself in tearDown.
        await SessionManager.shared.disconnect()
        sut = NativeChatViewModel()
    }

    override func tearDown() async throws {
        await SessionManager.shared.disconnect()
        sut = nil
        try await super.tearDown()
    }

    // MARK: - Initial state

    /// `isManualRefreshing` must default to `false` so the view's
    /// indicator stays hidden until a pull actually triggers a refresh.
    func testIsManualRefreshing_initialValueIsFalse() {
        XCTAssertFalse(sut.isManualRefreshing)
    }

    // MARK: - Flag behavior on completion

    /// After `refreshFromServer()` is called and the underlying network
    /// task completes (success or error), the flag must be cleared by
    /// the `defer` block. The test triggers refresh with a session set
    /// but no profile, so the network call fails — the test only
    /// asserts on the observable end state (flag back to false), not
    /// on the network outcome.
    func testRefreshFromServer_flagIsFalseAfterCompletion() async throws {
        // Set a session so refreshFromServer() proceeds past the early
        // `vm.selectedSession` guard.
        sut.selectedSession = makeTestSession()

        sut.refreshFromServer()

        // Poll for completion with a 5s deadline. The flag should be
        // cleared by the `defer { vm.isManualRefreshing = false }` in
        // HistoryLoader.refreshFromServer, regardless of whether the
        // network call succeeds or fails.
        let deadline = Date().addingTimeInterval(5.0)
        while sut.isManualRefreshing {
            if Date() > deadline {
                XCTFail("isManualRefreshing did not clear within 5s after refreshFromServer()")
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }
    }

    // MARK: - No-crash and no-UI-change on network error

    /// When the network call fails (no active profile), the refresh
    /// must complete silently: no exception propagates, and the
    /// already-shown messages are left untouched. The user sees the
    /// indicator appear and then disappear with no error toast.
    func testRefreshFromServer_networkError_leavesMessagesUnchanged() async throws {
        let originalMessages = sut.messages
        sut.selectedSession = makeTestSession()

        sut.refreshFromServer()

        // Wait for completion.
        let deadline = Date().addingTimeInterval(5.0)
        while sut.isManualRefreshing {
            if Date() > deadline {
                XCTFail("isManualRefreshing did not clear within 5s")
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        // Messages should be unchanged: no cache to read, no network to
        // succeed, so the network-error path runs and `vm.messages` is
        // never written.
        XCTAssertEqual(sut.messages, originalMessages)
    }

    /// Same as above but for `scrollRequest` — a failed refresh must
    /// not fire any scroll event. The user's viewport stays where it
    /// was; the indicator appearing and disappearing is the only
    /// visual feedback.
    func testRefreshFromServer_networkError_leavesScrollRequestUnchanged() async throws {
        let originalRequest = sut.scrollRequest
        sut.selectedSession = makeTestSession()

        sut.refreshFromServer()

        let deadline = Date().addingTimeInterval(5.0)
        while sut.isManualRefreshing {
            if Date() > deadline {
                XCTFail("isManualRefreshing did not clear within 5s")
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(sut.scrollRequest, originalRequest)
    }

    // MARK: - Helpers

    private func makeTestSession() -> OpenClawChatSessionEntry {
        OpenClawChatSessionEntry(
            key: "agent:test:label:11111111-1111-1111-1111-111111111111",
            kind: "test",
            displayName: "Test Session",
            surface: nil,
            subject: nil,
            room: nil,
            space: nil,
            updatedAt: nil,
            sessionId: nil,
            systemSent: nil,
            abortedLastRun: nil,
            thinkingLevel: nil,
            verboseLevel: nil,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: nil,
            modelProvider: nil,
            model: nil,
            contextTokens: nil,
            thinkingLevels: nil,
            thinkingOptions: nil,
            thinkingDefault: nil
        )
    }
}
