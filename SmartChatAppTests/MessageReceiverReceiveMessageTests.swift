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
        vm = NativeChatViewModel(store: store)  // 注入 test store
        // vm 初始化已经把 messageReceiver.viewModel = self 注好了,
        // 我们只需要注入 store(等价于 HistoryLoader 注入 store 的方式)
        receiver = vm.messageReceiver
        receiver.store = store
        // 测试需要 selectedSession 给一个 sessionKey,
        // 否则 receiveMessage 会 guard let 早退。
        vm.selectedSession = makeTestSession()
        // 隔离 CollapseStateCache.shared 的副作用
        CollapseStateCache.shared.clear()
    }

    override func tearDown() async throws {
        CollapseStateCache.shared.clear()
        receiver = nil
        store = nil
        fakeStorage = nil
        vm = nil
    }

    func test_streamingMessage_appendsToStore() async {
        let key = "session-1"
        let chat = makeChat(text: "delta", state: "streaming")
        receiver.receiveMessage(chat)
        // store.append 是 async,在 receiveMessage 返回前 schedule
        try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
        let messages = store.messages(for: key, since: nil)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].content.first?.text, "delta")
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
