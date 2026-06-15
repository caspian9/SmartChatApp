import XCTest
import OpenClawChatUI
@testable import SmartChatApp

@MainActor
final class MessageReceiverReceiveMessageTests: XCTestCase {
    private var receiver: MessageReceiver!
    private var store: MessageCacheStore!
    private var fakeStorage: FakeMessageCacheStorage!
    private var vm: NativeChatViewModel!

    override func setUp() async throws {
        fakeStorage = FakeMessageCacheStorage()
        store = MessageCacheStore(storage: fakeStorage)
        vm = NativeChatViewModel(store: store)  // inject the test store
        // vm.init already wires messageReceiver.viewModel = self
        // and injects the store — no further setup needed here.
        receiver = vm.messageReceiver
        // Tests need selectedSession to provide a sessionKey,
        // otherwise receiveMessage's guard let will early-return.
        vm.selectedSession = makeTestSession()
        // Isolate CollapseStateCache.shared side effects across tests.
        CollapseStateCache.shared.clear()
    }

    override func tearDown() async throws {
        CollapseStateCache.shared.clear()
        receiver = nil
        store = nil
        fakeStorage = nil
        vm = nil
    }

    func test_streamingMessage_appendsToStore() async throws {
        let key = "session-1"
        let chat = makeChat(text: "delta", state: "streaming")
        receiver.receiveMessage(chat)
        // Poll for the async store write to complete (don't rely on a fixed sleep — flaky under CI)
        let deadline = Date().addingTimeInterval(2.0)
        while store.messages(for: key, since: nil).isEmpty {
            if Date() > deadline {
                XCTFail("store.append did not complete within 2s")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)  // 10ms poll interval
        }
        let messages = store.messages(for: key, since: nil)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].content.first?.text, "delta")
    }

    func test_streamingDeltas_sameSyntheticId_collapseToOneEntry() async throws {
        // End-to-end regression for the "duplicate messages /
        // typing indicator won't disappear" bug. EventInterpreter's
        // `lifecycle=start` placeholder, every
        // assistant delta, and `lifecycle=end` all share `id: runId` —
        // a synthetic string, NOT a UUID. `toOpenClawChatMessage` must
        // derive a DETERMINISTIC UUID from it (not a fresh UUID per
        // call), otherwise `MessageCacheStorage.upsert` can't find the
        // existing entry and every delta appends a new bubble. After
        // the fix the three receiveMessage calls collapse to a single
        // store entry carrying the last delta's text.
        let key = "session-1"
        let runId = "f1e2d3c4-b5a6-7890-1234-56789abcdef0"  // synthetic
        receiver.receiveMessage(makeChat(id: runId, text: "", state: "streaming"))
        receiver.receiveMessage(makeChat(id: runId, text: "ha", state: "streaming"))
        receiver.receiveMessage(makeChat(id: runId, text: "hello there", state: "final"))

        // Poll for at least 1 entry to land, then give a small grace
        // window for the third write to complete. We can't poll for
        // "exactly 1" because the broken behavior would also produce
        // ≥1 entries — the assertion is on the count after a stable
        // settle, not on arrival order.
        let deadline = Date().addingTimeInterval(2.0)
        while store.messages(for: key, since: nil).isEmpty {
            if Date() > deadline {
                XCTFail("store.upsert did not complete within 2s")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        // Wait a short grace period so the third async write has time
        // to land before we assert the count.
        try await Task.sleep(nanoseconds: 200_000_000)

        let messages = store.messages(for: key, since: nil)
        XCTAssertEqual(
            messages.count, 1,
            "Same synthetic id streaming deltas must collapse to one entry (id-based upsert); got \(messages.count) entries")
        XCTAssertEqual(
            messages.first?.content.first?.text, "hello there",
            "Last delta must win (in-place replace, not append)")
    }

    func test_lifecycleEnd_setsIsUserExpandedInCollapseCache() {
        let id = "msg-final-1"
        let chat = makeChat(id: id, text: "done", state: "final")
        receiver.receiveMessage(chat)
        XCTAssertTrue(CollapseStateCache.shared.isExpanded(id))
    }

    func test_scrollRequestBumpedOnNewMessage() {
        let originalToken = vm.scrollRequest.token
        receiver.receiveMessage(makeChat(text: "x", state: "streaming"))
        XCTAssertEqual(vm.scrollRequest.token, originalToken &+ 1)
        XCTAssertEqual(vm.scrollRequest.kind, .newMessage)
    }

    // MARK: - Helpers

    private func makeTestSession() -> OpenClawChatSessionEntry {
        OpenClawChatSessionEntry(
            key: "session-1",
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

    private func makeChat(id: String = "msg-1", text: String = "x",
                          state: String = "streaming") -> ChatMessage {
        ChatMessage(
            id: id, text: text, timestamp: Date(),
            role: "assistant", state: state, runId: "run-1", seq: nil,
            startedAt: Date(), endedAt: state == "final" ? Date() : nil,
            livenessState: state == "streaming" ? "working" : nil,
            inputTokens: nil, outputTokens: nil, cacheRead: nil, cacheWrite: nil,
            toolCallId: nil, toolName: nil, stopReason: nil)
    }
}
