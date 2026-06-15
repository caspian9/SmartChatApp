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

    func test_append_dedupsByContent_keepsExistingOnDedupMatch() async {
        // KEEP (not REPLACE) on dedup key match: the existing message's
        // id is preserved so callers keying expand state on the id
        // (e.g. CollapseStateCache via streaming-time synthesized UUID)
        // survive server re-fetches that return the same content with
        // a server-assigned UUID.
        let key = "session-1"
        let id1 = UUID()
        let id2 = UUID()
        let msg1 = makeMsg(id: id1, text: "same", timestamp: 1000)
        let msg2 = makeMsg(id: id2, text: "same", timestamp: 1000)
        await storage.append([msg1], for: key)
        await storage.append([msg2], for: key)

        let loaded = await storage.load(for: key)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].id, id1, "Dedup hit: keep the existing entry (id stability > content authority)")
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

    // MARK: - upsert tests (streaming-delta id stability)

    func test_upsert_sameId_replacesInPlace() async {
        // Streaming deltas share one runId; each carries a longer
        // cumulative text. upsert must replace the existing entry
        // (not append a new one) so the view never sees duplicate
        // ids in its ForEach.
        let key = "session-1"
        let runId = UUID()
        let m1 = makeMsg(id: runId, text: "ABC", timestamp: 1000)
        let m2 = makeMsg(id: runId, text: "ABCDE", timestamp: 1100)
        let m3 = makeMsg(id: runId, text: "ABCDEF", timestamp: 1200)
        await storage.upsert([m1, m2, m3], for: key)

        let loaded = await storage.load(for: key)
        XCTAssertEqual(loaded.count, 1, "Same id across multiple upserts must collapse to one entry")
        XCTAssertEqual(loaded[0].id, runId)
        XCTAssertEqual(loaded[0].content.first?.text, "ABCDEF", "Last upsert wins (streaming final state)")
    }

    func test_upsert_differentIds_appendsAll() async {
        // History-style messages all have unique ids; upsert should
        // behave like append for these (no accidental merge).
        let key = "session-1"
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()
        await storage.upsert(
            [makeMsg(id: id1, text: "a", timestamp: 1000),
             makeMsg(id: id2, text: "b", timestamp: 2000),
             makeMsg(id: id3, text: "c", timestamp: 3000)],
            for: key)

        let loaded = await storage.load(for: key)
        XCTAssertEqual(loaded.map(\.id), [id1, id2, id3])
        XCTAssertEqual(loaded.map { $0.content.first?.text }, ["a", "b", "c"])
    }

    func test_upsert_doesNotDedupByContent_differentIdsSameText_bothKept() async {
        // The previous `append` test (test_append_dedupsByContent_*)
        // asserts that two messages with the same content but
        // different ids are deduped to one entry. upsert must NOT
        // apply that dedup — it keys on id, not content. This is
        // critical for history re-fetches where the server might
        // re-assign a different id to the same logical message.
        let key = "session-1"
        let id1 = UUID()
        let id2 = UUID()
        let msg1 = makeMsg(id: id1, text: "same", timestamp: 1000)
        let msg2 = makeMsg(id: id2, text: "same", timestamp: 1000)
        await storage.upsert([msg1, msg2], for: key)

        let loaded = await storage.load(for: key)
        XCTAssertEqual(loaded.count, 2, "upsert must not apply content-dedup; different ids both stay")
    }

    // MARK: - replaceForSession tests (loadHistory authoritative-replace)

    func test_replaceForSession_clearsExistingAndWritesNew() async {
        // loadHistory uses replaceForSession to make the server's
        // response the sole source of truth. Existing entries (from
        // previous runs, streaming residue, etc.) are wiped.
        let key = "session-1"
        await storage.append([makeMsg(text: "stale1"), makeMsg(text: "stale2")], for: key)
        let before = await storage.load(for: key)
        XCTAssertEqual(before.count, 2)

        await storage.replaceForSession([makeMsg(text: "new1"), makeMsg(text: "new2")], for: key)
        let loaded = await storage.load(for: key)
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.compactMap { $0.content.first?.text }, ["new1", "new2"])
    }

    func test_replaceForSession_doesNotApplyContentDedup() async {
        // Server is authoritative; do not merge with existing entries.
        // If the server's response has the same content as an existing
        // entry (a streaming residue, for example), the existing
        // entry is wiped regardless of content.
        let key = "session-1"
        await storage.append([makeMsg(text: "shared")], for: key)
        await storage.replaceForSession(
            [makeMsg(text: "shared", timestamp: 2000)],
            for: key)
        let loaded = await storage.load(for: key)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.timestamp, 2000, "Server version (newer timestamp) wins, residue is wiped")
    }

    func test_replaceForSession_emptyPayloadKeepsExisting() async {
        // Weak-network guard: if the server returns an empty list
        // (intermittent gateway, truncated response), the storage
        // layer must NOT wipe the existing entries. The user would
        // otherwise see their messages disappear mid-session even
        // though the connection shows "connected".
        let key = "session-1"
        await storage.append([makeMsg(text: "old")], for: key)
        let before = await storage.load(for: key)
        XCTAssertEqual(before.count, 1)

        await storage.replaceForSession([], for: key)
        let after = await storage.load(for: key)
        XCTAssertEqual(after.count, 1, "Empty replaceForSession must preserve existing data (weak-network guard)")
        XCTAssertEqual(after.first?.content.first?.text, "old")
    }

    func test_replaceForSession_emptyWhenNoPriorData_remainsEmpty() async {
        // No prior data: empty replace is a no-op (cache stays
        // empty, disk stays empty). Just confirms the guard doesn't
        // accidentally crash on the empty-cache path.
        let key = "session-fresh"
        await storage.replaceForSession([], for: key)
        let after = await storage.load(for: key)
        XCTAssertEqual(after.count, 0)
    }
}
