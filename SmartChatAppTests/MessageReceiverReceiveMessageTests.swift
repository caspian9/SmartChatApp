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

    func test_streamingMessage_appendsToPending_notStore() async throws {
        // PERSIST GATE: state="streaming" → VM's pendingBySession;
        // does NOT enter the persistent cache. The store stays empty.
        let key = "session-1"
        let chat = makeChat(text: "delta", state: "streaming")
        await receiver.receiveMessage(chat)

        // Give 200ms for the persist gate to complete (the streaming
        // branch itself is synchronous, but the await is still
        // crossed).
        try await Task.sleep(nanoseconds: 200_000_000)

        let messages = store.messages(for: key, since: nil)
        XCTAssertEqual(messages.count, 0, "PERSIST GATE: streaming delta must NOT enter the persistent cache")
        // The streaming message is visible in the merged view
        // (pending overlay).
        let merged = vm.chatMessages(for: key)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.text, "delta")
        XCTAssertEqual(merged.first?.role, "assistant")
    }

    func test_finalMessage_appendsToStore() async throws {
        // PERSIST GATE: state="final" → upsert into the cache.
        let key = "session-1"
        let chat = makeChat(text: "done", state: "final")
        await receiver.receiveMessage(chat)

        try await Task.sleep(nanoseconds: 200_000_000)

        let messages = store.messages(for: key, since: nil)
        XCTAssertEqual(messages.count, 1, "final message must enter the persistent cache")
        XCTAssertEqual(messages.first?.content.first?.text, "done")
    }

    func test_streamingThenFinal_storesOnlyFinal() async throws {
        // PERSIST GATE: streaming → pending, final → cache, dedup
        // by id. Multiple streaming deltas with the same runId
        // replace each other by id in pending; the final lands in
        // the cache and pending is cleared.
        let key = "session-1"
        let runId = "f1e2d3c4-b5a6-7890-1234-56789abcdef0"
        await receiver.receiveMessage(makeChat(id: runId, text: "", state: "streaming"))
        await receiver.receiveMessage(makeChat(id: runId, text: "ha", state: "streaming"))
        await receiver.receiveMessage(makeChat(id: runId, text: "hello there", state: "final"))
        // Simulate the clearPending call that EventInterpreter
        // makes after lifecycle=end.
        vm.clearPending(for: key)

        try await Task.sleep(nanoseconds: 200_000_000)

        let messages = store.messages(for: key, since: nil)
        XCTAssertEqual(messages.count, 1, "store has only the final entry")
        XCTAssertEqual(messages.first?.content.first?.text, "hello there")
        // The merged view also contains only the final entry.
        let merged = vm.chatMessages(for: key)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.text, "hello there")
    }

    func test_lifecycleEnd_setsIsUserExpandedInCollapseCache() async {
        let id = "msg-final-1"
        let chat = makeChat(id: id, text: "done", state: "final")
        await receiver.receiveMessage(chat)
        XCTAssertTrue(CollapseStateCache.shared.isExpanded(id))
    }

    func test_scrollRequestBumpedOnNewMessage() async {
        let originalToken = vm.scrollRequest.token
        await receiver.receiveMessage(makeChat(text: "x", state: "streaming"))
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
