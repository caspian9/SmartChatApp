import XCTest
import OpenClawChatUI
@testable import SmartChatApp

@MainActor
final class HistoryLoaderHasNewContentTests: XCTestCase {
    private var loader: HistoryLoader!
    private var vm: NativeChatViewModel!
    private var store: MessageCacheStore!
    private var fakeStorage: FakeMessageCacheStorage!

    override func setUp() async throws {
        await SessionManager.shared.disconnect()
        fakeStorage = FakeMessageCacheStorage()
        store = MessageCacheStore(storage: fakeStorage)
        vm = NativeChatViewModel(store: store)  // 注入 test store
        loader = HistoryLoader()
        loader.viewModel = vm
        loader.store = store
    }

    override func tearDown() async throws {
        await SessionManager.shared.disconnect()
        loader = nil
        vm = nil
        store = nil
        fakeStorage = nil
    }

    // —— hasNewContent 逻辑(直接测 helper)——

    func test_hasNewContent_firstLoad_lastSeenNil_alwaysTrue() {
        // 新架构下 store.lastSeenTimestamp(for:) 返回 nil → hasNewContent = true
        let result = loader.hasNewContent(newMaxTimestamp: 1000, sessionKey: "k")
        XCTAssertTrue(result)
    }

    func test_hasNewContent_newMaxGreaterThanLastSeen_true() async {
        let key = "k"
        await store.append([makeMsg(timestamp: 1000)], for: key)
        let result = loader.hasNewContent(newMaxTimestamp: 2000, sessionKey: key)
        XCTAssertTrue(result)
    }

    func test_hasNewContent_newMaxEqualToLastSeen_false() async {
        let key = "k"
        await store.append([makeMsg(timestamp: 1000)], for: key)
        let result = loader.hasNewContent(newMaxTimestamp: 1000, sessionKey: key)
        XCTAssertFalse(result)
    }

    func test_hasNewContent_newMaxLessThanLastSeen_false() async {
        let key = "k"
        await store.append([makeMsg(timestamp: 5000)], for: key)
        let result = loader.hasNewContent(newMaxTimestamp: 3000, sessionKey: key)
        XCTAssertFalse(result)
    }

    func test_hasNewContent_newMaxNil_false() async {
        let key = "k"
        await store.append([makeMsg(timestamp: 1000)], for: key)
        // server 返空 messages 数组 → newMax = nil
        let result = loader.hasNewContent(newMaxTimestamp: nil, sessionKey: key)
        XCTAssertFalse(result)
    }

    private func makeMsg(id: UUID = UUID(), role: String = "assistant",
                         text: String = "x", timestamp: Double = 1000) -> OpenClawChatMessage {
        OpenClawChatMessage(
            id: id, role: role,
            content: [OpenClawChatMessageContent(type: "text", text: text, thinking: nil,
                                                 thinkingSignature: nil, mimeType: nil,
                                                 fileName: nil, content: nil)],
            timestamp: timestamp, toolCallId: nil, toolName: nil, usage: nil,
            stopReason: nil, errorMessage: nil)
    }
}
