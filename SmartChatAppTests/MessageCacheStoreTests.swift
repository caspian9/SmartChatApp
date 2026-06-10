import XCTest
import OpenClawChatUI
@testable import SmartChatApp

@MainActor
final class MessageCacheStoreTests: XCTestCase {
    private var store: MessageCacheStore!
    private var fakeStorage: FakeMessageCacheStorage!

    override func setUp() async throws {
        fakeStorage = FakeMessageCacheStorage()
        store = MessageCacheStore(storage: fakeStorage)
    }

    // —— 基础 query ——

    func test_messages_emptySessionReturnsEmpty() {
        XCTAssertEqual(store.messages(for: "any").count, 0)
    }

    func test_lastSeenTimestamp_unsetReturnsNil() {
        XCTAssertNil(store.lastSeenTimestamp(for: "any"))
    }

    func test_isHydrated_initiallyFalse() {
        XCTAssertFalse(store.isHydrated(for: "any"))
    }

    // —— since 过滤 ——

    func test_messages_since_filtersByTimestamp() async {
        let key = "session-1"
        await fakeStorage.append([
            makeMsg(text: "old", timestamp: 1000),
            makeMsg(text: "mid", timestamp: 2000),
            makeMsg(text: "new", timestamp: 3000),
        ], for: key)
        // hydrate to load from storage
        await store.hydrate(for: key)

        let newer = store.messages(for: key, since: 1500)
        XCTAssertEqual(newer.map { $0.content.first?.text }, ["mid", "new"])
    }

    func test_messages_since_nilReturnsAll() async {
        let key = "session-1"
        await fakeStorage.append([
            makeMsg(text: "a", timestamp: 1000),
            makeMsg(text: "b", timestamp: 2000),
        ], for: key)
        await store.hydrate(for: key)

        XCTAssertEqual(store.messages(for: key, since: nil).count, 2)
    }

    // —— helpers ——

    private func makeMsg(id: UUID = UUID(), role: String = "assistant",
                         text: String = "hello", timestamp: Double = 1000) -> OpenClawChatMessage {
        OpenClawChatMessage(
            id: id, role: role,
            content: [OpenClawChatMessageContent(
                type: "text", text: text, thinking: nil, thinkingSignature: nil,
                mimeType: nil, fileName: nil, content: nil)],
            timestamp: timestamp, toolCallId: nil, toolName: nil,
            usage: nil, stopReason: nil, errorMessage: nil)
    }
}
