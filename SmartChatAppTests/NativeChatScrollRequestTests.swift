import XCTest
import OpenClawChatUI
@testable import SmartChatApp

@MainActor
final class NativeChatScrollRequestTests: XCTestCase {
    var sut: NativeChatViewModel!

    override func setUp() {
        super.setUp()
        sut = NativeChatViewModel()
        // Post-refactor: MessageReceiver.receiveMessage is a no-op
        // without a selected session (the receiver needs a sessionKey
        // to know where to write the incoming message). The production
        // app always has a session set before the transport stream
        // starts; the scroll-token tests previously relied on the
        // pre-refactor behavior of unconditionally bumping the token
        // even when no session existed. Mirror the production contract
        // here so these tests exercise the same code path.
        sut.selectedSession = makeTestSession()
    }

    /// Regression guard for the scroll-jitter fix: the initial scroll request
    /// must be `kind: .newMessage` with `token: 0` so the view's first
    /// `onChange(scrollRequest.token)` doesn't see a phantom historyLoaded.
    func testInitialScrollRequest_isNewMessageTokenZero() {
        XCTAssertEqual(sut.scrollRequest.token, 0)
        XCTAssertEqual(sut.scrollRequest.kind, .newMessage)
    }

    /// `MessageReceiver.receiveMessage` must increment the scroll token
    /// exactly once per call. The previous code had three separate
    /// `vm.scrollTrigger += 1` sites plus a 5-poll `cacheLoadCounter`
    /// cascade in HistoryLoader — together that produced 11+ `scrollTo`
    /// calls per history load, which is what caused the visible
    /// up-down jitter. The post-refactor receiver writes to the store
    /// and fires a single `.newMessage` scroll request.
    func testReceiveMessage_freshInsert_incrementsTokenOnce() {
        let initialToken = sut.scrollRequest.token
        let msg = makeMessage(id: "m1", text: "hi", role: "assistant", state: "final")
        sut.messageReceiver.receiveMessage(msg)
        XCTAssertEqual(sut.scrollRequest.token, initialToken &+ 1)
        XCTAssertEqual(sut.scrollRequest.kind, .newMessage)
    }

    /// Streaming deltas share the same id across the run. The view's
    /// single-scroll handler is a no-op when `lastId` is unchanged, so
    /// this case should not cause visible viewport jumps — but each
    /// receive still fires a single token bump (the store handles
    /// the id-match dedup).
    func testReceiveMessage_idMatch_stillIncrementsTokenOnce() {
        let initialToken = sut.scrollRequest.token
        let first = makeMessage(id: "run-1", text: "", role: "assistant", state: "streaming")
        sut.messageReceiver.receiveMessage(first)
        let tokenAfterFirst = sut.scrollRequest.token
        let delta = makeMessage(id: "run-1", text: "Hello world", role: "assistant", state: "streaming")
        sut.messageReceiver.receiveMessage(delta)
        XCTAssertEqual(sut.scrollRequest.token, tokenAfterFirst &+ 1)
        XCTAssertEqual(sut.scrollRequest.token, initialToken &+ 2)
        XCTAssertEqual(sut.scrollRequest.kind, .newMessage)
    }

    /// Multiple back-to-back receives must produce a monotonically
    /// increasing token. The wrapping `&+` operator is used so the test
    /// stays valid even if the token were ever to overflow Int.max.
    func testReceiveMessage_multipleReceives_tokenMonotonic() {
        var lastToken = sut.scrollRequest.token
        for i in 0..<5 {
            let msg = makeMessage(id: "m\(i)", text: "msg \(i)", role: "user", state: "final")
            sut.messageReceiver.receiveMessage(msg)
            XCTAssertGreaterThan(sut.scrollRequest.token, lastToken, "token must increase after receive #\(i)")
            XCTAssertEqual(sut.scrollRequest.kind, .newMessage)
            lastToken = sut.scrollRequest.token
        }
    }

    /// The manual pull-up refresh path uses `.manualRefresh` so the view's
    /// scroll handler can bypass the `userHasScrolled` gate. A user who
    /// previously scrolled up to read history has `userHasScrolled == true`,
    /// but if they then pull up to refresh at the bottom, the resulting
    /// scroll MUST land on the new message — that's the whole point of the
    /// pull. `.historyLoaded` would silently no-op in that case.
    func testNativeChatScrollKind_hasManualRefreshCase() {
        let manualKind: NativeChatScrollKind = .manualRefresh
        XCTAssertNotEqual(manualKind, .newMessage)
        XCTAssertNotEqual(manualKind, .historyLoaded)
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

    private func makeMessage(id: String, text: String, role: String, state: String) -> ChatMessage {
        ChatMessage(
            id: id,
            text: text,
            timestamp: Date(),
            role: role,
            state: state,
            runId: nil,
            seq: nil,
            startedAt: nil,
            endedAt: nil,
            livenessState: nil,
            toolCallId: nil,
            toolName: nil,
            stopReason: nil,
            isFresh: true
        )
    }
}
