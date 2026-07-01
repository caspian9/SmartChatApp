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

    // -- Basic query --

    func test_messages_emptySessionReturnsEmpty() {
        XCTAssertEqual(store.messages(for: "any").count, 0)
    }

    func test_lastSeenTimestamp_unsetReturnsNil() {
        XCTAssertNil(store.lastSeenTimestamp(for: "any"))
    }

    func test_isHydrated_initiallyFalse() {
        XCTAssertFalse(store.isHydrated(for: "any"))
    }

    // -- since filter --

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

    func test_append_firstCall_defensivelyHydratesFromStorage() async {
        let key = "session-1"
        let existing = makeMsg(timestamp: 500)
        await fakeStorage.append([existing], for: key)  // pre-existing data
        let newMsg = makeMsg(timestamp: 1000)
        await store.append([newMsg], for: key)
        let messages = store.messages(for: key, since: nil)
        XCTAssertEqual(messages.count, 2)
        XCTAssertTrue(messages.contains { $0.id == existing.id })
        XCTAssertTrue(messages.contains { $0.id == newMsg.id })
        XCTAssertTrue(store.isHydrated(for: key))
    }

    func test_append_olderBatch_doesNotRollbackLastSeen() async {
        let key = "session-1"
        // First batch: advance to 5000
        await store.append([makeMsg(timestamp: 1000), makeMsg(timestamp: 5000)], for: key)
        XCTAssertEqual(store.lastSeenTimestamp(for: key), 5000)
        // Second batch: older messages, must NOT roll back the waterline
        await store.append([makeMsg(timestamp: 100), makeMsg(timestamp: 2000)], for: key)
        XCTAssertEqual(store.lastSeenTimestamp(for: key), 5000, "older batch must not roll back the waterline")
    }

    // —— clear ——

    func test_clear_removesSession() async {
        let key = "session-1"
        await store.append([makeMsg()], for: key)
        XCTAssertEqual(store.messages(for: key).count, 1)

        await store.clear(for: key)
        XCTAssertEqual(store.messages(for: key).count, 0)
        XCTAssertNil(store.lastSeenTimestamp(for: key))
        XCTAssertFalse(store.isHydrated(for: key), "clear also wipes the hydrated flag")
    }

    func test_clearAll_removesEverything() async {
        await store.append([makeMsg()], for: "session-1")
        await store.append([makeMsg()], for: "session-2")
        await store.clearAll()
        XCTAssertEqual(store.messages(for: "session-1").count, 0)
        XCTAssertEqual(store.messages(for: "session-2").count, 0)
    }

    // MARK: - replaceForSession removed
    //
    // The 3 `test_replaceForSession_*` tests previously lived here.
    // `replaceForSession` is gone: `HistoryLoader.fetchAndMergeFromNetwork`
    // now calls `store.append(...)` and relies on `dedupKey` (role +
    // text) to absorb overlaps. Any future test that needs to
    // assert "wipe and start over" should use
    // `clear(for:)` followed by `append(_:for:)`, not a hypothetical
    // `replaceForSession`.

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
