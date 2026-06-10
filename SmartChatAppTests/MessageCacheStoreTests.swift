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

    // —— append ——

    func test_append_updatesMessagesBySession() async {
        let key = "session-1"
        let msg = makeMsg()
        await store.append([msg], for: key)
        let messages = store.messages(for: key, since: nil)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].id, msg.id)
    }

    func test_append_updatesLastSeenTimestampToMax() async {
        let key = "session-1"
        await store.append([makeMsg(timestamp: 1000), makeMsg(timestamp: 5000), makeMsg(timestamp: 3000)],
                           for: key)
        XCTAssertEqual(store.lastSeenTimestamp(for: key), 5000)
    }

    func test_append_emptyArray_doesNothing() async {
        let key = "session-1"
        await store.append([], for: key)
        XCTAssertNil(store.lastSeenTimestamp(for: key))
        XCTAssertEqual(store.messages(for: key).count, 0)
    }

    func test_append_emptyTimestamp_skipsLastSeenUpdate() async {
        let key = "session-1"
        let noTs = OpenClawChatMessage(
            id: UUID(), role: "assistant",
            content: [OpenClawChatMessageContent(type: "text", text: "x", thinking: nil,
                                                 thinkingSignature: nil, mimeType: nil, fileName: nil,
                                                 content: nil)],
            timestamp: nil, toolCallId: nil, toolName: nil, usage: nil, stopReason: nil, errorMessage: nil)
        await store.append([noTs], for: key)
        XCTAssertNil(store.lastSeenTimestamp(for: key))
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
