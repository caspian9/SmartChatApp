import XCTest
import OpenClawChatUI
@testable import SmartChatApp

final class MessageCacheStorageTests: XCTestCase {
    private let testSuite = "test.openclaw.messages.\(UUID().uuidString)"
    private var defaults: UserDefaults!
    private var storage: MessageCacheStorage!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: testSuite)!
        defaults.removePersistentDomain(forName: testSuite)
        storage = MessageCacheStorage(defaults: defaults, maxLocalMessages: 200)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: testSuite)
    }

    func test_load_unknownSession_returnsEmpty() async {
        let result = await storage.load(for: "nonexistent")
        XCTAssertEqual(result.count, 0)
    }

    // MARK: - append tests

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

    func test_append_persistsToDisk_loadRoundTrips() async {
        let key = "session-1"
        let msg = makeMsg(text: "first", timestamp: 1000)
        await storage.append([msg], for: key)

        // Re-load from disk via new instance
        let storage2 = MessageCacheStorage(defaults: defaults, maxLocalMessages: 200)
        let loaded = await storage2.load(for: key)
        XCTAssertEqual(loaded.count, 1)
        // Note: OpenClawChatMessage.CodingKeys omits `id`, so it regenerates on decode.
        // Assert by content (the dedup contract) instead.
        XCTAssertEqual(loaded[0].role, msg.role)
        XCTAssertEqual(loaded[0].timestamp, msg.timestamp)
        XCTAssertEqual(loaded[0].content.first?.text, msg.content.first?.text)
    }

    func test_append_dedupsByContent_replacesExisting() async {
        let key = "session-1"
        let id1 = UUID()
        let id2 = UUID()
        let msg1 = makeMsg(id: id1, text: "same", timestamp: 1000)
        let msg2 = makeMsg(id: id2, text: "same", timestamp: 1000)
        await storage.append([msg1], for: key)
        await storage.append([msg2], for: key)

        let loaded = await storage.load(for: key)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].id, id2, "Newer copy replaces older by content dedup")
    }

    func test_append_dedupsByContent_firstLineForToolCall() async {
        let key = "session-1"
        let msg1 = makeMsg(id: UUID(), role: "toolCall", text: "get_weather\n{\"city\":\"SF\"}",
                           timestamp: 1000)
        let msg2 = makeMsg(id: UUID(), role: "toolCall",
                           text: "get_weather\n{\"city\":\"NYC\"}", timestamp: 1000)
        await storage.append([msg1], for: key)
        await storage.append([msg2], for: key)

        // Same first line "get_weather" → dedup (params don't matter for toolCall)
        let loaded = await storage.load(for: key)
        XCTAssertEqual(loaded.count, 1)
    }

    func test_append_skipsEmptyTextPlaceholder() async {
        let key = "session-1"
        let empty = makeMsg(text: "", timestamp: 1000)
        let real = makeMsg(text: "real", timestamp: 1000)
        await storage.append([empty, real], for: key)
        let loaded = await storage.load(for: key)
        XCTAssertEqual(loaded.count, 1)
    }

    func test_append_sortsByTimestampAscending() async {
        let key = "session-1"
        let a = makeMsg(text: "a", timestamp: 2000)
        let b = makeMsg(text: "b", timestamp: 1000)
        let c = makeMsg(text: "c", timestamp: 3000)
        await storage.append([a, b, c], for: key)
        let loaded = await storage.load(for: key)
        XCTAssertEqual(loaded.map(\.timestamp), [1000, 2000, 3000])
    }

    func test_append_capsAtMaxLocalMessages_trimsOldest() async {
        let cap = 5
        let small = MessageCacheStorage(defaults: defaults, maxLocalMessages: cap)
        let key = "session-1"
        for i in 0..<10 {
            await small.append([makeMsg(text: "m\(i)", timestamp: Double(i * 1000))], for: key)
        }
        let loaded = await small.load(for: key)
        XCTAssertEqual(loaded.count, cap)
        XCTAssertEqual(loaded.compactMap { $0.content.first?.text }, ["m5", "m6", "m7", "m8", "m9"])
    }

    // MARK: - clear / clearAll / maxTimestamp / messageIds tests (Task 3)

    func test_clear_removesFromMemoryAndDisk() async {
        let key = "session-1"
        await storage.append([makeMsg()], for: key)
        let before = await storage.load(for: key)
        XCTAssertEqual(before.count, 1)

        await storage.clear(for: key)
        let after = await storage.load(for: key)
        XCTAssertEqual(after.count, 0)

        // Disk also cleared
        let storage2 = MessageCacheStorage(defaults: defaults, maxLocalMessages: 200)
        let fromDisk = await storage2.load(for: key)
        XCTAssertEqual(fromDisk.count, 0)
    }

    func test_clear_doesNotAffectOtherSessions() async {
        await storage.append([makeMsg()], for: "session-1")
        await storage.append([makeMsg()], for: "session-2")
        await storage.clear(for: "session-1")
        let s1 = await storage.load(for: "session-1")
        let s2 = await storage.load(for: "session-2")
        XCTAssertEqual(s1.count, 0)
        XCTAssertEqual(s2.count, 1)
    }

    func test_clearAll_removesAllSessions() async {
        await storage.append([makeMsg()], for: "session-1")
        await storage.append([makeMsg()], for: "session-2")
        await storage.clearAll()
        let s1 = await storage.load(for: "session-1")
        let s2 = await storage.load(for: "session-2")
        XCTAssertEqual(s1.count, 0)
        XCTAssertEqual(s2.count, 0)
    }

    func test_maxTimestamp_returnsHighestTimestamp() async {
        let key = "session-1"
        await storage.append(
            [makeMsg(text: "a", timestamp: 1000),
             makeMsg(text: "b", timestamp: 5000),
             makeMsg(text: "c", timestamp: 2000)],
            for: key)
        let max = await storage.maxTimestamp(for: key)
        XCTAssertEqual(max, 5000)
    }

    func test_maxTimestamp_emptySessionReturnsNil() async {
        let max = await storage.maxTimestamp(for: "nonexistent")
        XCTAssertNil(max)
    }

    func test_messageIds_returnsAllIds() async {
        let key = "session-1"
        let id1 = UUID()
        let id2 = UUID()
        await storage.append(
            [makeMsg(id: id1, text: "first"), makeMsg(id: id2, text: "second")],
            for: key)
        let ids = await storage.messageIds(for: key)
        XCTAssertEqual(ids, Set([id1.uuidString, id2.uuidString]))
    }
}
