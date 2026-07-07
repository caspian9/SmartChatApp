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
        storage = MessageCacheStorage(defaults: defaults)
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
        // Disk write is debounced (100ms coalesce window); force
        // the flush so the fresh-instance read below sees the
        // expected 1 entry on disk. Without this, `storage2.load`
        // would see an empty disk (the in-memory cache hasn't
        // been flushed yet) and `loaded[0]` would crash with
        // "Index out of range".
        await storage.flushPendingWrites()

        // Re-load from disk via new instance
        let storage2 = MessageCacheStorage(defaults: defaults)
        let loaded = await storage2.load(for: key)
        XCTAssertEqual(loaded.count, 1)
        // Note: OpenClawChatMessage.CodingKeys omits `id`, so it regenerates on decode.
        // Assert by content (the dedup contract) instead.
        XCTAssertEqual(loaded[0].role, msg.role)
        XCTAssertEqual(loaded[0].timestamp, msg.timestamp)
        XCTAssertEqual(loaded[0].content.first?.text, msg.content.first?.text)
    }

    // MARK: - id-dedup (issue #36)

    /// KEEP-on-id semantics (mirror of KEEP-on-content above).
    /// Server returns a message whose UUID we already have cached;
    /// the existing entry wins (id stability > content authority).
    /// The previous behavior would have replaced the existing
    /// entry's content with the incoming copy (the upsert path's
    /// id-replace rule, applied accidentally). With append now
    /// doing id-dedup BEFORE content-dedup, the existing entry is
    /// untouched.
    func test_append_dedupsById_existingId_skipped() async {
        let key = "session-1"
        let sharedId = UUID()
        let first = makeMsg(id: sharedId, text: "original text", timestamp: 1000)
        let second = makeMsg(id: sharedId, text: "REPLACEMENT text", timestamp: 2000)
        await storage.append([first], for: key)
        await storage.append([second], for: key)
        let loaded = await storage.load(for: key)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].content.first?.text, "original text",
                       "id-dedup must KEEP the existing entry's content (not last-write-wins)")
        XCTAssertEqual(loaded[0].id, sharedId)
    }

    /// In-progress dedup check: when `[A, A]` is appended in a
    /// single call, the second A must not appear in the final
    /// array. Catches a regression where `allMessages.contains`
    /// ran against the in-progress append (so the second A always
    /// matched the just-appended first A and never landed).
    func test_append_dedupsById_appendedMessageNotDeduplicatedAgainstItself() async {
        let key = "session-1"
        let sharedId = UUID()
        let a1 = makeMsg(id: sharedId, text: "first arrival", timestamp: 1000)
        let a2 = makeMsg(id: sharedId, text: "second arrival", timestamp: 2000)
        await storage.append([a1, a2], for: key)
        let loaded = await storage.load(for: key)
        XCTAssertEqual(loaded.count, 1, "in-progress append must not let A→A survive in a single call")
    }

    /// Id-dedup and content-dedup are independent axes. To assert
    /// "id-dedup doesn't break a legitimate new append", we use
    /// messages that collide on NEITHER axis: different ids AND
    /// different timestamps (different tsBucket, so content-dedup
    /// doesn't fire either). Both must be appended. (A same-content
    /// different-ids case would still be content-deduped — that's
    /// the complementary contract, not a regression of id-dedup.)
    func test_append_dedupsById_differentIdsDifferentTimestamp_appended() async {
        let key = "session-1"
        let id1 = UUID()
        let id2 = UUID()
        let msg1 = makeMsg(id: id1, text: "first", timestamp: 1000)
        let msg2 = makeMsg(id: id2, text: "second", timestamp: 2000)
        await storage.append([msg1], for: key)
        await storage.append([msg2], for: key)
        let loaded = await storage.load(for: key)
        XCTAssertEqual(loaded.count, 2,
                       "different ids with different timestamps must both be appended")
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

    func test_append_doesNotDedupByToolName_differentArgs_bothKept() async {
        // Regression for the user-reported "TOOLCALL disappeared"
        // bug. The previous dedupKey used the first line of
        // toolCall / toolResult / thinking payloads as a
        // "name-only" key on the theory that two toolCalls of
        // the same tool (e.g. two `read` calls) with different
        // arguments should be treated as the same logical step.
        // That made them dedup to one entry, and the user saw
        // only the first `read` bubble — TOOLCALL info went
        // missing. The fix: dedupKey now uses the full text for
        // every role, so two toolCalls with different args
        // produce different keys and BOTH survive.
        let key = "session-1"
        let msg1 = makeMsg(id: UUID(), role: "toolCall", text: "get_weather\n{\"city\":\"SF\"}",
                           timestamp: 1000)
        let msg2 = makeMsg(id: UUID(), role: "toolCall",
                           text: "get_weather\n{\"city\":\"NYC\"}", timestamp: 1000)
        await storage.append([msg1], for: key)
        await storage.append([msg2], for: key)

        let loaded = await storage.load(for: key)
        XCTAssertEqual(loaded.count, 2, "different args on the same tool name must NOT dedup")
    }

    func test_append_dedupsByContent_toolCallExactSameText_deduped() async {
        // The complementary case: two toolCalls with the SAME
        // tool name AND the SAME args (which the server sometimes
        // re-emits when it rebroadcasts the agent event) should
        // still dedup, otherwise a server re-fetch would multiply
        // bubbles. This locks in the "content equality, not name
        // equality" contract.
        let key = "session-1"
        let id1 = UUID()
        let id2 = UUID()
        let msg1 = makeMsg(id: id1, role: "toolCall",
                           text: "get_weather\n{\"city\":\"SF\"}", timestamp: 1000)
        let msg2 = makeMsg(id: id2, role: "toolCall",
                           text: "get_weather\n{\"city\":\"SF\"}", timestamp: 1000)
        await storage.append([msg1], for: key)
        await storage.append([msg2], for: key)

        let loaded = await storage.load(for: key)
        XCTAssertEqual(loaded.count, 1, "identical toolCall payloads (same args) must dedup")
    }

    func test_append_skipsEmptyTextPlaceholder() async {
        let key = "session-1"
        let empty = makeMsg(text: "", timestamp: 1000)
        let real = makeMsg(text: "real", timestamp: 1000)
        await storage.append([empty, real], for: key)
        let loaded = await storage.load(for: key)
        XCTAssertEqual(loaded.count, 1)
    }

    func test_append_keepsThinkingOnlyMessages() async {
        // Regression for the user-reported "thinking not visible in
        // chat.history" bug. The previous `isEmptyTextPlaceholder`
        // check only looked at the `text` field — for a thinking-only
        // message (`content: [{type:"thinking", thinking:"..."}]`,
        // where `text` is nil), the message was wrongly classified
        // as a placeholder and SKIPPED at the `append` path. The
        // device log showed `skippedEmpty=12` for a session whose
        // chat.history payload had 12 thinking-only entries; the
        // view never saw any of them. With the fix, the check
        // also looks for non-empty `thinking` content — if present,
        // the message flows through the normal append/dedup/persist
        // path and the converter emits a `role: "thinking"`
        // ChatMessage for the view to render.
        let key = "session-1"
        let thinkingMsg = OpenClawChatMessage(
            id: UUID(), role: "assistant",
            content: [OpenClawChatMessageContent(
                type: "thinking", text: nil,
                thinking: "let me think about this",
                thinkingSignature: nil, mimeType: nil, fileName: nil,
                content: nil)],
            timestamp: 1000, toolCallId: nil, toolName: nil,
            usage: nil, stopReason: nil, errorMessage: nil)
        await storage.append([thinkingMsg], for: key)
        let loaded = await storage.load(for: key)
        XCTAssertEqual(loaded.count, 1, "thinking-only message must NOT be skipped by isEmptyTextPlaceholder")
        XCTAssertEqual(loaded.first?.content.first?.thinking, "let me think about this")
        XCTAssertEqual(loaded.first?.content.first?.type, "thinking")
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

    func test_append_doesNotCap_unbounded() async {
        // The 200-entry cap was removed. 500 messages must all be
        // retained, with no silent oldest-entry eviction.
        let key = "session-1"
        let total = 500
        for i in 0..<total {
            await storage.append([makeMsg(text: "m\(i)", timestamp: Double(i * 1000))], for: key)
        }
        let loaded = await storage.load(for: key)
        XCTAssertEqual(loaded.count, total, "All 500 entries must be retained; no silent oldest drop")
        XCTAssertEqual(loaded.first?.content.first?.text, "m0")
        XCTAssertEqual(loaded.last?.content.first?.text, "m\(total - 1)")
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
        let storage2 = MessageCacheStorage(defaults: defaults)
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

    // MARK: - stats() extended shape (issue #36)
    //
    // `stats()` now returns a `MessageCacheStats` struct with
    // `oldestTimestamp` / `newestTimestamp` for the Settings
    // time-span display. The 5 tests below lock in the contract:
    // nil for empty, single message echoes itself, multi-message
    // returns the extrema, nil-timestamp messages don't poison
    // the span, and the existing sessionCount / messageCount
    // semantics are unchanged by the extension.

    func test_stats_returnsOldestAndNewestTimestamps_emptySession_returnsNilNil() async {
        // The pre-existing `clearAll` returns the disk to a clean
        // slate; combined with a fresh suite, the stats pass sees
        // zero sessions and zero messages — both timestamps nil.
        await storage.clearAll()
        let stats = await storage.stats()
        XCTAssertEqual(stats.sessionCount, 0)
        XCTAssertEqual(stats.messageCount, 0)
        XCTAssertNil(stats.oldestTimestamp)
        XCTAssertNil(stats.newestTimestamp)
    }

    func test_stats_returnsOldestAndNewestTimestamps_singleMessage_returnsThatTimestamp() async {
        let key = "session-1"
        await storage.append([makeMsg(timestamp: 1000)], for: key)
        // `stats()` scans UserDefaults directly. The append path
        // is debounced (100ms coalesce), so we must flush before
        // reading disk-truth stats. (The Settings view hits this
        // through the `MessageCacheStore` — the production caller
        // doesn't need to flush explicitly because the user's UI
        // navigation pace dwarfs the debounce window.)
        await storage.flushPendingWrites()
        let stats = await storage.stats()
        XCTAssertEqual(stats.oldestTimestamp, 1000)
        XCTAssertEqual(stats.newestTimestamp, 1000)
    }

    func test_stats_returnsOldestAndNewestTimestamps_multipleMessages_returnsExtrema() async {
        let key = "session-1"
        await storage.append(
            [makeMsg(text: "a", timestamp: 3000),
             makeMsg(text: "b", timestamp: 1000),
             makeMsg(text: "c", timestamp: 2000)],
            for: key)
        await storage.flushPendingWrites()
        let stats = await storage.stats()
        XCTAssertEqual(stats.oldestTimestamp, 1000)
        XCTAssertEqual(stats.newestTimestamp, 3000)
    }

    func test_stats_oldestAndNewest_treatsNullTimestampAsSkipped() async {
        // A message with `timestamp: nil` is unusual (streaming
        // placeholders normally get one before persisting) but
        // must not count as the min/max — counting nil as 0 would
        // put nil entries at the head of every span and mislead
        // the user about when their oldest chat actually started.
        let key = "session-1"
        let nilTs = OpenClawChatMessage(
            id: UUID(), role: "user",
            content: [OpenClawChatMessageContent(
                type: "text", text: "no ts", thinking: nil,
                thinkingSignature: nil, mimeType: nil, fileName: nil,
                content: nil)],
            timestamp: nil, toolCallId: nil, toolName: nil,
            usage: nil, stopReason: nil, errorMessage: nil)
        await storage.append([nilTs, makeMsg(timestamp: 5000)], for: key)
        await storage.flushPendingWrites()
        let stats = await storage.stats()
        XCTAssertEqual(stats.oldestTimestamp, 5000)
        XCTAssertEqual(stats.newestTimestamp, 5000,
                       "nil timestamp must not be treated as 0 / oldest")
    }

    func test_stats_sessionCountAndMessageCount_unchangedByExtension() async {
        // Regression: the existing 2-tuple contract still works.
        // Adding the timestamp fields MUST NOT change sessionCount
        // / messageCount semantics — Settings displays them
        // alongside the new timestamp row.
        await storage.append([makeMsg(timestamp: 1000)], for: "session-1")
        await storage.append([makeMsg(timestamp: 2000)], for: "session-2")
        await storage.flushPendingWrites()
        let stats = await storage.stats()
        XCTAssertEqual(stats.sessionCount, 2)
        XCTAssertEqual(stats.messageCount, 2)
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
        // Regression for the user-reported "3 copies" bug: the
        // upsert path (used by `MessageReceiver` for streaming
        // events) used to be id-only dedup. The raw `command_output`
        // from `command_output stream=end`, `item phase=end
        // summary=...`, and the trailer-augmented `command_output`
        // end all had DIFFERENT ids but the same content, so all 3
        // landed in the cache. The fix added content-based dedup
        // to upsert (mirrors the `append` dedup): same role + same
        // first line + same tsBucket + same usage → drop the new
        // one. This test locks in the dedup contract.
        let key = "session-1"
        let id1 = UUID()
        let id2 = UUID()
        let msg1 = makeMsg(id: id1, text: "same", timestamp: 1000)
        let msg2 = makeMsg(id: id2, text: "same", timestamp: 1000)
        await storage.upsert([msg1, msg2], for: key)

        let loaded = await storage.load(for: key)
        XCTAssertEqual(loaded.count, 1, "upsert now content-dedups; different ids with same content collapse to one entry")
        XCTAssertEqual(loaded.first?.id, id1, "KEEP the first arrival (id stability > content authority)")
    }

    func test_upsert_dedupByContent_differentRoles_bothKept() async {
        // The dedup is keyed on `role + text + tsBucket + usage`.
        // Two messages with the same text but DIFFERENT roles
        // (e.g., one toolResult + one assistant bubble both
        // containing "exit=0") must NOT be deduped — the user
        // wants to see them as separate bubbles.
        let key = "session-1"
        let id1 = UUID()
        let id2 = UUID()
        let msg1 = makeMsg(id: id1, role: "toolResult", text: "exit=0", timestamp: 1000)
        let msg2 = makeMsg(id: id2, role: "assistant", text: "exit=0", timestamp: 1000)
        await storage.upsert([msg1, msg2], for: key)

        let loaded = await storage.load(for: key)
        XCTAssertEqual(loaded.count, 2, "different roles with same text must NOT dedup")
    }

    // MARK: - replaceForSession removed
    //
    // The 4 `test_replaceForSession_*` tests previously lived here.
    // `replaceForSession` is gone: `HistoryLoader.fetchAndMergeFromNetwork`
    // now calls `store.append(...)` and relies on `dedupKey`
    // (text + role + tsBucket + usage) to absorb overlaps. Any future
    // test that needs to assert "wipe and start over" should use
    // `clear` followed by `append`, not a hypothetical
    // `replaceForSession`.

    // MARK: - dedupKey content-shape invariance (streamed vs server)
    //
    // The same logical message arrives in two different
    // `OpenClawChatMessage` shapes depending on the source. The
    // streaming path (via `EventInterpreter` →
    // `ChatMessageConverter.toOpenClawChatMessage`) hardcodes
    // `content[0] = {type:"text", text: <formatted bubble>}` for
    // every role — the toolCall / toolResult / thinking body is
    // flattened into the text field by the formatter. The server's
    // `chat.history` response uses typed content blocks
    // (`{type:"toolcall", name:..., arguments:...}` or
    // `{type:"thinking", thinking:...}`) with `text: nil`. The
    // original text-only dedup would hash the server's empty
    // `text` to "" and miss the dedup — a pull-to-refresh after a
    // live run left both copies in the cache and the user saw two
    // toolCall / thinking bubbles for one logical call. The
    // current `dedupKeyText` and `dedupKeyRole` produce the same
    // signature for both shapes; these tests lock in the
    // contract for toolCall, toolResult, and thinking.

    func test_append_dedupsByContent_streamedToolCallVsServerHistory_deduped() async {
        // Both entries share `toolCallId: "xyz"` at the message
        // level (the streaming path sets it via the
        // ChatMessageConverter, the server's typed payload sets
        // it via the SDK's `OpenClawChatMessage.toolCallId`
        // field). The content shapes differ (text vs typed
        // name+args), but `dedupKey` now uses `toolCallId` as
        // the signature and normalizes the role to "tool" for
        // any tool-typed content, so the two entries collide
        // and the second is dropped.
        let key = "session-1"
        let streamed = OpenClawChatMessage(
            id: UUID(), role: "toolCall",
            content: [OpenClawChatMessageContent(
                type: "text", text: "ToolCall: read\npath: /foo",
                thinking: nil, thinkingSignature: nil, mimeType: nil,
                fileName: nil, content: nil, id: nil, name: nil,
                arguments: nil)],
            timestamp: 1000, toolCallId: "xyz", toolName: "read",
            usage: nil, stopReason: nil, errorMessage: nil)
        let serverHistory = OpenClawChatMessage(
            id: UUID(), role: "tool",
            content: [OpenClawChatMessageContent(
                type: "toolcall", text: nil,
                thinking: nil, thinkingSignature: nil, mimeType: nil,
                fileName: nil, content: nil, id: "xyz", name: "read",
                arguments: nil)],
            timestamp: 1000, toolCallId: "xyz", toolName: "read",
            usage: nil, stopReason: nil, errorMessage: nil)
        await storage.append([streamed], for: key)
        await storage.append([serverHistory], for: key)
        let loaded = await storage.load(for: key)
        XCTAssertEqual(loaded.count, 1, "streamed + server toolCall with same toolCallId must dedup")
    }

    func test_append_dedupsByContent_streamedToolResultVsServerHistory_deduped() async {
        // Same asymmetry as the toolCall test, but for
        // toolResult. The streaming path formats the result body
        // into `content[0].text`; the server returns it as a
        // typed `content[0] = {type:"toolresult", text: nil,
        // name:..., ...}` with no `text` field. Both carry the
        // same `toolCallId` at the message level.
        let key = "session-1"
        let streamed = OpenClawChatMessage(
            id: UUID(), role: "toolResult",
            content: [OpenClawChatMessageContent(
                type: "text", text: "result body",
                thinking: nil, thinkingSignature: nil, mimeType: nil,
                fileName: nil, content: nil, id: nil, name: nil,
                arguments: nil)],
            timestamp: 1000, toolCallId: "xyz", toolName: "read",
            usage: nil, stopReason: nil, errorMessage: nil)
        let serverHistory = OpenClawChatMessage(
            id: UUID(), role: "toolResult",
            content: [OpenClawChatMessageContent(
                type: "toolresult", text: nil,
                thinking: nil, thinkingSignature: nil, mimeType: nil,
                fileName: nil, content: nil, id: "xyz", name: "read",
                arguments: nil)],
            timestamp: 1000, toolCallId: "xyz", toolName: "read",
            usage: nil, stopReason: nil, errorMessage: nil)
        await storage.append([streamed], for: key)
        await storage.append([serverHistory], for: key)
        let loaded = await storage.load(for: key)
        XCTAssertEqual(loaded.count, 1, "streamed + server toolResult with same toolCallId must dedup")
    }

    func test_append_dedupsByContent_streamedThinkingVsServerHistory_deduped() async {
        // Thinking asymmetry. Streaming stores thinking as a
        // text content block (the converter hardcodes
        // `type:"text"` for every role), so the thinking text
        // is in `content[0].text`. Server returns it as a
        // typed `content[0] = {type:"thinking", thinking: "..."}`
        // with `text: nil`. The original text-only dedup hashed
        // the server's empty `text` to "" and missed the dedup.
        // The current `dedupKeyText` falls back to the `thinking`
        // field when `text` is empty, and `dedupKeyRole` normalizes
        // any entry with a thinking block to "thinking" so
        // the server's `role: "assistant"` (the typical shape
        // when thinking is a sub-block of the assistant turn)
        // and streaming's `role: "thinking"` collide.
        let key = "session-1"
        let streamed = OpenClawChatMessage(
            id: UUID(), role: "thinking",
            content: [OpenClawChatMessageContent(
                type: "text", text: "let me reason about this",
                thinking: nil, thinkingSignature: nil, mimeType: nil,
                fileName: nil, content: nil, id: nil, name: nil,
                arguments: nil)],
            timestamp: 1000, toolCallId: nil, toolName: nil,
            usage: nil, stopReason: nil, errorMessage: nil)
        let serverHistory = OpenClawChatMessage(
            id: UUID(), role: "assistant",
            content: [OpenClawChatMessageContent(
                type: "thinking", text: nil,
                thinking: "let me reason about this",
                thinkingSignature: nil, mimeType: nil, fileName: nil,
                content: nil, id: nil, name: nil, arguments: nil)],
            timestamp: 1000, toolCallId: nil, toolName: nil,
            usage: nil, stopReason: nil, errorMessage: nil)
        await storage.append([streamed], for: key)
        await storage.append([serverHistory], for: key)
        let loaded = await storage.load(for: key)
        XCTAssertEqual(loaded.count, 1, "streamed + server thinking with same text must dedup")
    }

    func test_append_dedupsByContent_streamedAssistantVsServerHistoryWithThinking_deduped() async {
        // The duplicate-assistant-bubble scenario from the
        // user-reported log captured 2026-07-03 (runId
        // 6BB8B583-BE35-42F9-B380-7E7FE993048D):
        //
        //   CACHE[13] (streaming write)
        //     role=assistant, text=<assistant body>,
        //     thinking="" (no thinking block — EventInterpreter
        //     flattens the assistant text into a single
        //     `{type:"text", text:...}` content block)
        //   CACHE[14] (server-history write via refresh)
        //     role=assistant, text=<same assistant body>,
        //     thinking=<reasoning> (the server's `chat.history`
        //     payload carries the reasoning as a sibling
        //     `{type:"thinking", thinking:...}` content block)
        //
        // Both are the SAME logical assistant turn. The
        // streaming copy's `dedupKey` hashes roleForHash as
        // "assistant" (no thinking block). The server copy's
        // `dedupKey` previously hashed roleForHash as
        // "thinking" (because `hasThinkingBlock` was true), so
        // the two never matched — both landed in the cache and
        // the user saw two assistant bubbles for one turn.
        //
        // The fix: `roleForHash = "thinking"` applies only to
        // thinking-only sub-block messages (text empty,
        // thinking non-empty). A full assistant turn that ALSO
        // carries a thinking reasoning block hashes with the
        // normalized role so it collides with the streaming
        // copy of the same turn.
        let key = "session-1"
        let sharedBody = "Hello there. How can I help today?"
        let streamed = OpenClawChatMessage(
            id: UUID(), role: "assistant",
            content: [OpenClawChatMessageContent(
                type: "text", text: sharedBody,
                thinking: nil, thinkingSignature: nil, mimeType: nil,
                fileName: nil, content: nil, id: nil, name: nil,
                arguments: nil)],
            timestamp: 1783048355210.0, toolCallId: nil, toolName: nil,
            usage: nil, stopReason: nil, errorMessage: nil)
        let serverHistory = OpenClawChatMessage(
            id: UUID(), role: "assistant",
            content: [
                OpenClawChatMessageContent(
                    type: "text", text: sharedBody,
                    thinking: nil, thinkingSignature: nil, mimeType: nil,
                    fileName: nil, content: nil, id: nil, name: nil,
                    arguments: nil),
                OpenClawChatMessageContent(
                    type: "thinking", text: nil,
                    thinking: "The user is asking for help.",
                    thinkingSignature: nil, mimeType: nil,
                    fileName: nil, content: nil, id: nil, name: nil,
                    arguments: nil),
            ],
            timestamp: 1783048355211.0, toolCallId: nil, toolName: nil,
            usage: nil, stopReason: nil, errorMessage: nil)
        await storage.append([streamed], for: key)
        await storage.append([serverHistory], for: key)
        let loaded = await storage.load(for: key)
        // After BUG-7's replace-on-match fix: the streaming
        // entry is REPLACED with the server entry (streaming id
        // preserved). The server's thinking block now lives
        // INLINE in the assistant entry's content array
        // (`{type:"thinking", thinking:"..."}` as a sibling of
        // the text block). `ChatMessageConverter.toChatMessage`
        // emits it as a separate `role:"thinking"` bubble from
        // the inline block (via the `emitThinkingFirst` path),
        // so the view still shows the reasoning — but the
        // cache only has ONE assistant entry, no separate
        // standalone `role:"thinking"` entry needed.
        let assistantEntries = loaded.filter { $0.role == "assistant" }
        let thinkingEntries = loaded.filter { $0.role == "thinking" }
        XCTAssertEqual(assistantEntries.count, 1,
            "streamed assistant bubble must be preserved as a single assistant entry after server-history dedup — got \(assistantEntries.count)")
        XCTAssertEqual(thinkingEntries.count, 0,
            "after replace-on-match, the server's thinking block lives INLINE on the assistant entry (no separate role:thinking entry needed) — got \(thinkingEntries.count), all=\(loaded.map { "\($0.role):\(String($0.id.uuidString.prefix(8)))" })")
        let inlineThinking = assistantEntries.first?.content.first(where: { $0.thinking?.isEmpty == false })?.thinking
        XCTAssertEqual(inlineThinking,
            "The user is asking for help.",
            "the server's reasoning text must survive the replace-on-match as an inline content block on the assistant entry")
    }

    // MARK: - dedupKey: `usage` is NOT part of the signature
    //
    // Background: a duplicate assistant bubble was reported
    // appearing after a streaming run was followed by a pull-up
    // refresh. The streaming path wrote
    // `usage={input:-1, output:-1, cacheRead:-1, cacheWrite:-1,
    // total:-1}` (the EventInterpreter's "no token data" sentinel
    // — the server's `lifecycle=end` event for this version
    // doesn't carry a usage block) while the server's
    // `chat.history` returned `usage=nil` for the same message.
    // The previous key included `usage`, so the two shapes of the
    // same logical message hashed to different keys and both
    // landed in the cache. The current key drops `usage`.
    //
    // These tests pin that contract: same role + same text +
    // same tsBucket must dedup regardless of `usage` shape.

    /// `OpenClawChatUsage` has no memberwise init (only the
    /// `Codable` synthesis). Round-trip a sentinel through
    /// JSONEncoder/JSONDecoder the same way
    /// `ChatMessageConverter.toOpenClawChatMessage` does for
    /// `usage`, so the test can construct one with `input: -1`.
    private func makeUsageSentinel(input: Int) -> OpenClawChatUsage {
        let payload: [String: Any] = [
            "input": input, "output": -1, "cacheRead": -1,
            "cacheWrite": -1, "total": -1
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return try! JSONDecoder().decode(OpenClawChatUsage.self, from: data)
    }

    func test_append_dedupsByContent_streamedUsageSentinelVsServerNilUsage_deduped() async {
        // The exact duplicate-bubble scenario from the original
        // diagnostic log. Streaming `lifecycle=end` writes
        // `usage={input:-1, ...}` (the EventInterpreter's "no
        // token data" sentinel) and the server's `chat.history`
        // returns `usage=nil` for the same message. With the
        // previous key, the two `usage` values hashed to
        // different strings and the server's copy bypassed dedup.
        // The current key dedupes them.
        let key = "session-1"
        let streamedFinal = OpenClawChatMessage(
            id: UUID(), role: "assistant",
            content: [OpenClawChatMessageContent(
                type: "text", text: "i'm here 👋",
                thinking: nil, thinkingSignature: nil, mimeType: nil,
                fileName: nil, content: nil, id: nil, name: nil,
                arguments: nil)],
            timestamp: 1781604599181, toolCallId: nil, toolName: nil,
            usage: makeUsageSentinel(input: -1), stopReason: nil,
            errorMessage: nil)
        let serverHistory = OpenClawChatMessage(
            id: UUID(), role: "assistant",
            content: [OpenClawChatMessageContent(
                type: "text", text: "i'm here 👋",
                thinking: nil, thinkingSignature: nil, mimeType: nil,
                fileName: nil, content: nil, id: nil, name: nil,
                arguments: nil)],
            timestamp: 1781604599181, toolCallId: nil, toolName: nil,
            usage: nil, stopReason: nil, errorMessage: nil)
        await storage.append([streamedFinal], for: key)
        await storage.append([serverHistory], for: key)
        let loaded = await storage.load(for: key)
        XCTAssertEqual(loaded.count, 1, "streaming usage={-1,...} vs server usage=nil must dedup")
    }

    func test_append_dedupsByContent_streamedUsageSentinelVsServerRealUsage_deduped() async {
        // Variant where the server's `chat.history` DOES return
        // a real usage block (e.g. a different server version
        // that fills it in). Different usage payloads but same
        // text + role + tsBucket → must still dedup. The previous
        // key would reject this; the current key accepts it.
        // This is the "false positive" worry in reverse: if we
        // ever DID want usage to be part of the identity, this
        // would break. We explicitly assert the contract.
        let key = "session-1"
        let streamedFinal = OpenClawChatMessage(
            id: UUID(), role: "assistant",
            content: [OpenClawChatMessageContent(
                type: "text", text: "i'm here 👋",
                thinking: nil, thinkingSignature: nil, mimeType: nil,
                fileName: nil, content: nil, id: nil, name: nil,
                arguments: nil)],
            timestamp: 1781604599181, toolCallId: nil, toolName: nil,
            usage: makeUsageSentinel(input: -1), stopReason: nil,
            errorMessage: nil)
        let serverRealUsage = makeUsageSentinel(input: 4321)
        let serverHistory = OpenClawChatMessage(
            id: UUID(), role: "assistant",
            content: [OpenClawChatMessageContent(
                type: "text", text: "i'm here 👋",
                thinking: nil, thinkingSignature: nil, mimeType: nil,
                fileName: nil, content: nil, id: nil, name: nil,
                arguments: nil)],
            timestamp: 1781604599181, toolCallId: nil, toolName: nil,
            usage: serverRealUsage, stopReason: nil, errorMessage: nil)
        await storage.append([streamedFinal], for: key)
        await storage.append([serverHistory], for: key)
        let loaded = await storage.load(for: key)
        XCTAssertEqual(loaded.count, 1, "different usage payloads with same text must still dedup")
    }

    func test_append_dedupsByContent_differentTextSameRole_doesNotDedup_regardlessOfUsage() async {
        // Negative test: dropping `usage` from the key MUST
        // NOT cause two different messages with the same role to
        // collide. Two user messages 8 seconds apart, one usage
        // sentinel one nil, different text → must keep both.
        let key = "session-1"
        let first = OpenClawChatMessage(
            id: UUID(), role: "user",
            content: [OpenClawChatMessageContent(
                type: "text", text: "hello",
                thinking: nil, thinkingSignature: nil, mimeType: nil,
                fileName: nil, content: nil, id: nil, name: nil,
                arguments: nil)],
            timestamp: 1781600000000, toolCallId: nil, toolName: nil,
            usage: makeUsageSentinel(input: -1), stopReason: nil,
            errorMessage: nil)
        let second = OpenClawChatMessage(
            id: UUID(), role: "user",
            content: [OpenClawChatMessageContent(
                type: "text", text: "hey",
                thinking: nil, thinkingSignature: nil, mimeType: nil,
                fileName: nil, content: nil, id: nil, name: nil,
                arguments: nil)],
            timestamp: 1781600008000, toolCallId: nil, toolName: nil,
            usage: nil, stopReason: nil, errorMessage: nil)
        await storage.append([first], for: key)
        await storage.append([second], for: key)
        let loaded = await storage.load(for: key)
        XCTAssertEqual(loaded.count, 2, "different text must not dedup even with different usage")
    }

    // MARK: - id stability across process restart

    func test_idStability_survivesStorageReinit() async throws {
        // Regression test for the "id regenerates on every load"
        // bug. The SDK's `OpenClawChatMessage.CodingKeys` omits
        // `id`; without the `PersistedMessageEnvelope` wrapper the
        // decoder falls back to `var id: UUID = .init()` and the
        // loaded message gets a fresh UUID every time the app
        // restarts — breaking dedup-by-id in `upsert` and
        // invalidating `CollapseStateCache.expandedMessageIds`.
        //
        // Simulates a process restart by creating two storage
        // instances against the same UserDefaults suite. The
        // in-memory `cache` is empty in the second instance, so
        // the only way the loaded id can match the saved id is
        // through the on-disk envelope.
        let key = "session-restart"
        let suite = "test-id-stability-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)
        XCTAssertNotNil(defaults, "test UserDefaults suite must be writable")
        defer { defaults?.removePersistentDomain(forName: suite) }

        let originalId = UUID()
        let original = OpenClawChatMessage(
            id: originalId, role: "assistant",
            content: [OpenClawChatMessageContent(
                type: "text", text: "stable id please",
                thinking: nil, thinkingSignature: nil,
                mimeType: nil, fileName: nil, content: nil,
                id: nil, name: nil, arguments: nil)],
            timestamp: 1_700_000_000_000, toolCallId: nil, toolName: nil,
            usage: nil, stopReason: nil, errorMessage: nil)

        // First storage writes the message. `load()` here
        // round-trips through the disk (cache is empty pre-append),
        // exercising the envelope encode/decode path.
        //
        // Force a flush so the disk write is durable before
        // the fresh-instance read. Without this, the test would
        // race the 100ms debounce window — sometimes the disk
        // write lands in time, sometimes not. The flush makes
        // the test deterministic.
        let storage1 = MessageCacheStorage(defaults: defaults!)
        _ = await storage1.append([original], for: key)
        await storage1.flushPendingWrites()
        let reloadedBySameInstance = await storage1.load(for: key)
        XCTAssertEqual(reloadedBySameInstance.count, 1)
        XCTAssertEqual(reloadedBySameInstance.first?.id, originalId,
                       "id must survive a load that round-trips through disk")

        // Second storage simulates process restart — fresh
        // in-memory cache, same UserDefaults. The only way the
        // loaded id matches is via the envelope.
        let storage2 = MessageCacheStorage(defaults: defaults!)
        let reloadedByFreshInstance = await storage2.load(for: key)
        XCTAssertEqual(reloadedByFreshInstance.count, 1,
                       "fresh storage instance must read the same on-disk data")
        XCTAssertEqual(reloadedByFreshInstance.first?.id, originalId,
                       "id must survive across storage-instance boundaries (= process restart)")
        XCTAssertEqual(reloadedByFreshInstance.first?.content.first?.text,
                       "stable id please",
                       "content must also survive intact")
    }

    func test_idStability_multipleMessages_allPreserved() async throws {
        // A second id-stability test covering the multi-message
        // case: every id in the saved array must come back as
        // the same UUID, not as 4 fresh ones. Catches a regression
        // where the envelope wrapper handles 1 message correctly
        // but drops ids for N>1.
        let key = "session-multi"
        let suite = "test-id-stability-multi-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)
        XCTAssertNotNil(defaults)
        defer { defaults?.removePersistentDomain(forName: suite) }

        let originalIds = (0..<4).map { _ in UUID() }
        let messages = originalIds.enumerated().map { i, id in
            OpenClawChatMessage(
                id: id, role: "user",
                content: [OpenClawChatMessageContent(
                    type: "text", text: "msg \(i)",
                    thinking: nil, thinkingSignature: nil,
                    mimeType: nil, fileName: nil, content: nil,
                    id: nil, name: nil, arguments: nil)],
                timestamp: Double(1_700_000_000_000 + i * 1000),
                toolCallId: nil, toolName: nil, usage: nil,
                stopReason: nil, errorMessage: nil)
        }
        let storage1 = MessageCacheStorage(defaults: defaults!)
        _ = await storage1.append(messages, for: key)
        // Flush so the disk write is durable before the
        // fresh-instance read (see idStability_survivesStorageReinit
        // for the debounce interaction rationale).
        await storage1.flushPendingWrites()
        let storage2 = MessageCacheStorage(defaults: defaults!)
        let loaded = await storage2.load(for: key)
        XCTAssertEqual(loaded.count, 4)
        let loadedIds = Set(loaded.map { $0.id })
        let originalIdsSet = Set(originalIds)
        XCTAssertEqual(loadedIds, originalIdsSet,
                       "all 4 ids must match originals after restart")
    }

    // MARK: - Disk-write debounce

    func test_diskWriteDebounce_pendingWritesCoalesce() async throws {
        // Regression test for write amplification: 5 streaming
        // deltas used to produce 5 JSON encodes + 5 UserDefaults
        // writes. With the debounce, the in-memory cache updates
        // synchronously (so the caller sees the right state) but
        // the disk write is deferred to `flushPendingWrites()`.
        //
        // We verify the debounce by:
        //   1. Appending 5 messages
        //   2. Reading disk via a *fresh* storage instance before
        //      flush → must be empty (or stale from prior tests)
        //   3. Calling `flushPendingWrites()`
        //   4. Reading disk again → must be the 5 messages
        let key = "session-debounce"
        let suite = "test-debounce-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)
        XCTAssertNotNil(defaults)
        defer { defaults?.removePersistentDomain(forName: suite) }

        let storage1 = MessageCacheStorage(defaults: defaults!)
        let messages = (0..<5).map { i in
            OpenClawChatMessage(
                id: UUID(), role: "user",
                content: [OpenClawChatMessageContent(
                    type: "text", text: "delta \(i)",
                    thinking: nil, thinkingSignature: nil,
                    mimeType: nil, fileName: nil, content: nil,
                    id: nil, name: nil, arguments: nil)],
                timestamp: Double(1_700_000_000_000 + i * 100),
                toolCallId: nil, toolName: nil, usage: nil,
                stopReason: nil, errorMessage: nil)
        }
        for msg in messages {
            _ = await storage1.append([msg], for: key)
        }
        // In-memory state is current (read via a fresh
        // instance, which is forced to round-trip through
        // disk — should be empty until flush).
        let inMemory = await storage1.load(for: key)
        XCTAssertEqual(inMemory.count, 5, "in-memory cache is synchronous and authoritative")
        // Before flush: a fresh storage instance reads from
        // disk directly. The 5 writes haven't been flushed yet,
        // so disk should be empty (or stale from a prior test
        // — we just verify the 5 messages aren't there yet).
        let storage2 = MessageCacheStorage(defaults: defaults!)
        let onDiskBeforeFlush = await storage2.load(for: key)
        XCTAssertEqual(onDiskBeforeFlush.count, 0,
                       "no disk write should have happened yet (5 appends coalesce into 1 deferred write)")

        // Force the flush. After this, disk is up-to-date.
        await storage1.flushPendingWrites()
        let storage3 = MessageCacheStorage(defaults: defaults!)
        let onDiskAfterFlush = await storage3.load(for: key)
        XCTAssertEqual(onDiskAfterFlush.count, 5,
                       "all 5 messages must be on disk after flush")
        XCTAssertEqual(Set(onDiskAfterFlush.map { $0.content.first?.text }),
                       Set(messages.map { $0.content.first?.text }),
                       "flushed content matches what was appended")
    }

    func test_diskWriteDebounce_clearRemovesPendingWrite() async throws {
        // Edge case: if `clear(for:)` runs while a debounced
        // write is pending for the same session, the in-flight
        // flush would otherwise resurrect the just-cleared data
        // from the (still-populated) in-memory cache. Verify
        // the clear also drops the pending write so the flush
        // is a no-op for that session.
        let key = "session-clear-debounce"
        let suite = "test-clear-debounce-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)
        XCTAssertNotNil(defaults)
        defer { defaults?.removePersistentDomain(forName: suite) }

        let storage = MessageCacheStorage(defaults: defaults!)
        let msg = OpenClawChatMessage(
            id: UUID(), role: "user",
            content: [OpenClawChatMessageContent(
                type: "text", text: "ephemeral",
                thinking: nil, thinkingSignature: nil,
                mimeType: nil, fileName: nil, content: nil,
                id: nil, name: nil, arguments: nil)],
            timestamp: 1_700_000_000_000, toolCallId: nil,
            toolName: nil, usage: nil, stopReason: nil,
            errorMessage: nil)
        _ = await storage.append([msg], for: key)
        // Clear BEFORE flush. Pending write for `key` should
        // be dropped — the flush task will see an empty set
        // and do nothing.
        await storage.clear(for: key)
        await storage.flushPendingWrites()
        let storage2 = MessageCacheStorage(defaults: defaults!)
        let onDisk = await storage2.load(for: key)
        XCTAssertEqual(onDisk.count, 0,
                       "cleared session must not resurrect its data via a debounced flush")
    }

    // MARK: - dedupKey: 60-second tsBucket + toolResult trailer strip
    //
    // Background: two failure logs (2026-07-06 device captures)
    // showed duplicate bubbles that the previous dedup missed:
    //
    //   CACHE[11] vs CACHE[15] (assistant turn)
    //     Stream wrote the assistant final at ts ~1783312535993
    //     (run-start bucket); server's `chat.history` returned
    //     the same turn at ts ~1783312544721 (run-end bucket).
    //     ~8.7s apart — crosses the old 10-second tsBucket
    //     boundary. Even with the `isThinkingOnlySubBlock`
    //     fix from 42c868d, the two buckets hash to different
    //     keys.
    //
    //   CACHE[14] vs CACHE[16] (toolResult)
    //     Modern `command_output (end)` path appended
    //     `exit=0 duration=2832ms` to the body; legacy
    //     `item` (end) / `tool` (result) paths did not.
    //     Same logical tool execution → different text bytes
    //     → no dedup → duplicate bubble.
    //
    // Fixes:
    //   - `tsBucket = Int64(ts / 60_000)` (60s window)
    //   - strip trailing `exit=… duration=…ms` from text
    //     before hashing.
    //
    // These tests pin both fixes. The "hi" twice two-hours-
    // apart regression test from `b6171c8` is preserved by
    // `test_append_dedupsByContent_userTextTwoHoursApart_kept`
    // below.

    func test_append_dedupsByContent_streamedVsServerAssistantEightSecondsApart_deduped() async {
        // CACHE[11] vs CACHE[15]: same assistant text body,
        // streamed-final ts ~8.7s before server-history ts.
        // Old 10s bucket crossed the boundary (178331253 vs
        // 178331254); new 60s bucket puts both in 178331254.
        let key = "session-1"
        let body = "**石景山当前天气** ☀️\n| 指标 | 数据 |\n|------|------|\n| 温度 | **30°C**（体感 29°C） |"
        let streamed = OpenClawChatMessage(
            id: UUID(), role: "assistant",
            content: [OpenClawChatMessageContent(
                type: "text", text: body,
                thinking: nil, thinkingSignature: nil, mimeType: nil,
                fileName: nil, content: nil, id: nil, name: nil,
                arguments: nil)],
            timestamp: 1_783_312_535_993.0,
            toolCallId: nil, toolName: nil,
            usage: nil, stopReason: nil, errorMessage: nil)
        let serverHistory = OpenClawChatMessage(
            id: UUID(), role: "assistant",
            content: [
                OpenClawChatMessageContent(
                    type: "text", text: body,
                    thinking: nil, thinkingSignature: nil, mimeType: nil,
                    fileName: nil, content: nil, id: nil, name: nil,
                    arguments: nil),
                OpenClawChatMessageContent(
                    type: "thinking", text: nil,
                    thinking: "The user is asking about Shijingshan (石景山) weather.",
                    thinkingSignature: nil, mimeType: nil,
                    fileName: nil, content: nil, id: nil, name: nil,
                    arguments: nil),
            ],
            timestamp: 1_783_312_544_721.0,
            toolCallId: nil, toolName: nil,
            usage: nil, stopReason: nil, errorMessage: nil)
        await storage.append([streamed], for: key)
        await storage.append([serverHistory], for: key)
        let loaded = await storage.load(for: key)
        // After BUG-7's replace-on-match: the streaming entry
        // is replaced with the server entry (streaming id
        // preserved), the server's thinking block lives
        // INLINE on the assistant entry. Cache has exactly
        // 1 assistant entry.
        let assistantEntries = loaded.filter { $0.role == "assistant" }
        let thinkingEntries = loaded.filter { $0.role == "thinking" }
        XCTAssertEqual(assistantEntries.count, 1,
            "streamed + server-history assistant turn ~8.7s apart must dedup to 1 assistant entry under 60s bucket — got \(assistantEntries.count) assistants")
        XCTAssertEqual(thinkingEntries.count, 0,
            "after replace-on-match, the server's thinking block lives INLINE on the assistant entry — got \(thinkingEntries.count) standalone thinking entries")
        let inlineThinking = assistantEntries.first?.content.first(where: { $0.thinking?.isEmpty == false })?.thinking
        XCTAssertEqual(inlineThinking, "The user is asking about Shijingshan (石景山) weather.",
            "the server's reasoning text must survive as an inline content block on the assistant entry")
    }

    func test_append_dedupsByContent_toolResultBodyVsBodyWithTrailer_deduped() async {
        // CACHE[14] vs CACHE[16]: same tool execution output,
        // one write with the trailing `exit=… duration=…ms`
        // (modern `command_output (end)`) and one without
        // (legacy `item` (end) / `tool` (result)).
        let key = "session-1"
        let body = "温: 30°C 体感: 29°C\n湿: 55% 风: 4km/h SSW\n云: 25% 雨: 0.0mm\n能见: 10km UV: 7"
        let withTrailer = body + "\nexit=0 duration=2832ms"
        let streamed = OpenClawChatMessage(
            id: UUID(), role: "toolResult",
            content: [OpenClawChatMessageContent(
                type: "text", text: body,
                thinking: nil, thinkingSignature: nil, mimeType: nil,
                fileName: nil, content: nil, id: nil, name: nil,
                arguments: nil)],
            timestamp: 1_783_312_544_719.0,
            toolCallId: nil, toolName: nil,
            usage: nil, stopReason: nil, errorMessage: nil)
        let withTrailerMsg = OpenClawChatMessage(
            id: UUID(), role: "toolResult",
            content: [OpenClawChatMessageContent(
                type: "text", text: withTrailer,
                thinking: nil, thinkingSignature: nil, mimeType: nil,
                fileName: nil, content: nil, id: nil, name: nil,
                arguments: nil)],
            timestamp: 1_783_312_545_134.259,
            toolCallId: nil, toolName: nil,
            usage: nil, stopReason: nil, errorMessage: nil)
        await storage.append([streamed], for: key)
        await storage.append([withTrailerMsg], for: key)
        let loaded = await storage.load(for: key)
        XCTAssertEqual(loaded.count, 1,
            "toolResult body vs body+exit/duration trailer must dedup — got \(loaded.count) entries")
    }

    // MARK: - toolResult: toolCallId-based dedup fallback (BUG-8 follow-up)
    //
    // When the streaming `command_output (end)` event's
    // `output` field arrives with an *incremental* (truncated)
    // body rather than the full accumulated stdout, the
    // streaming toolResult's text is shorter than the
    // server's `chat.history` full text. Strict content-dedup
    // (role+text+tsBucket) hashes them differently because
    // of the byte-length delta, and the role+text fuzzy
    // fallback also misses because the texts aren't equal.
    //
    // The fix: when both sides are `role:"toolResult"` and
    // their `toolCallId`+`toolName` match within a 60s
    // bucket, treat as the same logical call. Server's text
    // is always authoritative (it carries the full stdout
    // accumulated by the gateway); replace-on-match fires
    // because server text length > streaming text length by
    // > 64 bytes (the threshold chosen so that legitimate
    // whitespace/newline deltas between streaming and
    // server text don't trigger a replace for non-toolResult
    // roles).

    func test_append_dedupsByToolCallId_streamingTruncatedVsServerFull_toolResultReplaced() async {
        let key = "session-1"
        let sharedToolCallId = "weather-tool-abc123"
        let sharedToolName = "get_weather"
        // Streaming-side wrote a truncated body (e.g., the
        // gateway emitted `command_output (end)` with
        // incremental `output` rather than full stdout).
        let streamedTruncated = "...truncated weather data...\nexit=0 duration=644ms"
        let streamed = OpenClawChatMessage(
            id: UUID(), role: "toolResult",
            content: [OpenClawChatMessageContent(
                type: "text", text: streamedTruncated,
                thinking: nil, thinkingSignature: nil, mimeType: nil,
                fileName: nil, content: nil, id: nil, name: nil,
                arguments: nil)],
            timestamp: 1_783_328_621_179.0,
            toolCallId: sharedToolCallId, toolName: sharedToolName,
            usage: nil, stopReason: nil, errorMessage: nil)
        await storage.append([streamed], for: key)
        await storage.flushPendingWrites()

        // Server returns the full body (no trailer — server
        // doesn't add the exit/duration suffix).
        let fullBody = String(repeating: "full weather data, lots of JSON content here, ", count: 20)
        let server = OpenClawChatMessage(
            id: UUID(), role: "toolResult",
            content: [OpenClawChatMessageContent(
                type: "text", text: fullBody,
                thinking: nil, thinkingSignature: nil, mimeType: nil,
                fileName: nil, content: nil, id: nil, name: nil,
                arguments: nil)],
            // Same 60s bucket as streaming
            timestamp: 1_783_328_621_180.0,
            toolCallId: sharedToolCallId, toolName: sharedToolName,
            usage: nil, stopReason: nil, errorMessage: nil)
        await storage.append([server], for: key)

        let loaded = await storage.load(for: key)
        XCTAssertEqual(loaded.count, 1,
            "BUG-8 follow-up: toolCallId+toolName+tsBucket fallback must collapse streaming-truncated and server-full to a single entry — got \(loaded.count) entries")
        XCTAssertEqual(loaded.first?.content.first?.text, fullBody,
            "the surviving entry must be the server's full text (replace-on-match uses server's authoritative stdout)")
        XCTAssertEqual(loaded.first?.toolCallId, sharedToolCallId,
            "toolCallId must survive the replace")
        XCTAssertEqual(loaded.first?.toolName, sharedToolName,
            "toolName must survive the replace")
    }

    func test_append_dedupsByContent_userTextTwoHoursApart_kept() async {
        // Regression guard for the `b6171c8` revert: widening
        // the tsBucket to 60s must NOT collapse legitimate
        // user retries separated by 2 hours (the case that
        // motivated restoring the bucket after the PR #49
        // first attempt dropped it entirely).
        let key = "session-1"
        let first = OpenClawChatMessage(
            id: UUID(), role: "user",
            content: [OpenClawChatMessageContent(
                type: "text", text: "hi",
                thinking: nil, thinkingSignature: nil, mimeType: nil,
                fileName: nil, content: nil, id: nil, name: nil,
                arguments: nil)],
            timestamp: 1_783_000_000_000.0,
            toolCallId: nil, toolName: nil,
            usage: nil, stopReason: nil, errorMessage: nil)
        let twoHoursLater = OpenClawChatMessage(
            id: UUID(), role: "user",
            content: [OpenClawChatMessageContent(
                type: "text", text: "hi",
                thinking: nil, thinkingSignature: nil, mimeType: nil,
                fileName: nil, content: nil, id: nil, name: nil,
                arguments: nil)],
            timestamp: 1_783_007_200_500.0,
            toolCallId: nil, toolName: nil,
            usage: nil, stopReason: nil, errorMessage: nil)
        await storage.append([first], for: key)
        await storage.append([twoHoursLater], for: key)
        let loaded = await storage.load(for: key)
        XCTAssertEqual(loaded.count, 2,
            "user 'hi' typed twice 2 hours apart must NOT dedup under 60s bucket — got \(loaded.count) entries (regression: PR #49 first attempt dropped the bucket and merged these)")
    }

    func test_append_dedupsByContent_assistantTextEmojiVariationSelector_deduped() async {
        // The duplicate-assistant-bubble scenario from
        // user-reported log captured 2026-07-06T06:43
        // (CACHE[30] vs CACHE[32]): the server's
        // `chat.history` returned the same logical
        // assistant turn TWICE for the same run, with the
        // emoji variation selector differing in the title.
        // One copy had `🌤️` (U+1F324 U+FE0F) and the other
        // `🌤` (U+1F324). Same human-visible character, but
        // different UTF-8 bytes — the byte-sensitive
        // dedupKey hash split them into two entries.
        //
        // Fix: `normalizeTextForDedupHash` strips
        // U+FE0E / U+FE0F (text/emoji presentation
        // selectors) before hashing. The two copies now
        // hash identically and dedup to a single entry.
        let key = "session-1"
        let bodyWithVS = "**张家口当前天气** 🌤️\n| 指标 | 数据 |\n|------|------|"
        let bodyWithoutVS = "**张家口当前天气** 🌤\n| 指标 | 数据 |\n|------|------|"
        let first = OpenClawChatMessage(
            id: UUID(), role: "assistant",
            content: [OpenClawChatMessageContent(
                type: "text", text: bodyWithVS,
                thinking: nil, thinkingSignature: nil, mimeType: nil,
                fileName: nil, content: nil, id: nil, name: nil,
                arguments: nil)],
            timestamp: 1_783_318_080_981.0,
            toolCallId: nil, toolName: nil,
            usage: nil, stopReason: nil, errorMessage: nil)
        let second = OpenClawChatMessage(
            id: UUID(), role: "assistant",
            content: [OpenClawChatMessageContent(
                type: "text", text: bodyWithoutVS,
                thinking: nil, thinkingSignature: nil, mimeType: nil,
                fileName: nil, content: nil, id: nil, name: nil,
                arguments: nil)],
            timestamp: 1_783_318_085_324.0,
            toolCallId: nil, toolName: nil,
            usage: nil, stopReason: nil, errorMessage: nil)
        await storage.append([first], for: key)
        await storage.append([second], for: key)
        let loaded = await storage.load(for: key)
        XCTAssertEqual(loaded.count, 1,
            "two assistant copies differing only by emoji variation selector must dedup — got \(loaded.count) entries")
    }

    // MARK: - thinking-splice idempotency across repeated fetches
    //
    // Background: every `fetchAndMergeFromNetwork` (initial
    // session enter + every pull-to-refresh) appends the
    // server's `chat.history` to the cache. The dedup
    // branch splices a thinking entry when the existing
    // entry is an assistant with no reasoning block and
    // the server's copy has a sibling reasoning block.
    // The first version of this code used a deterministic
    // id `<existing.uuid>:thinking:<i>` for the spliced
    // thinking to make the splice idempotent. But
    // `OpenClawChatMessage.id` is a `UUID` and the
    // `:thinking:<i>` suffix makes the string unparseable
    // by `UUID(uuidString:)`, so the actual id was
    // `UUID()` (a fresh random UUID) on every call. The
    // id-based check then never matched across runs and
    // each refresh added one more spliced thinking
    // bubble (user-reported 2026-07-06T09:04, log showed
    // 4 thinking entries with identical text after 4
    // refreshes). The fix: content-based idempotency —
    // skip if any existing entry already carries the
    // same reasoning text. Reasoning text within a
    // single run is unique, so this is safe.

    func test_append_spliceThinking_isIdempotentAcrossRepeatedFetches() async {
        // Simulates 4 sequential `fetchAndMergeFromNetwork`
        // calls for the same session. Each call appends
        // the server's history (with the assistant +
        // thinking block). The cache should end with
        // exactly ONE spliced thinking entry, not four.
        let key = "session-1"
        let body = "**北京海淀当前天气** ☀️\n| 指标 | 数据 |\n|------|------|"
        let reasoning = "The user sent multiple messages - some f..."
        // The streaming-side write: assistant body,
        // no thinking block. Different id from the
        // server's copy.
        let streamed = OpenClawChatMessage(
            id: UUID(), role: "assistant",
            content: [OpenClawChatMessageContent(
                type: "text", text: body,
                thinking: nil, thinkingSignature: nil, mimeType: nil,
                fileName: nil, content: nil, id: nil, name: nil,
                arguments: nil)],
            timestamp: 1_783_328_621_179.0,
            toolCallId: nil, toolName: nil,
            usage: nil, stopReason: nil, errorMessage: nil)
        await storage.append([streamed], for: key)

        // 4 server-history fetches. Each passes a fresh
        // server-assigned id (matches dedupKey with the
        // streamed entry, KEEP-on-match) and a sibling
        // thinking block.
        for _ in 0..<4 {
            let serverCopy = OpenClawChatMessage(
                id: UUID(), role: "assistant",
                content: [
                    OpenClawChatMessageContent(
                        type: "text", text: body,
                        thinking: nil, thinkingSignature: nil, mimeType: nil,
                        fileName: nil, content: nil, id: nil, name: nil,
                        arguments: nil),
                    OpenClawChatMessageContent(
                        type: "thinking", text: nil,
                        thinking: reasoning,
                        thinkingSignature: nil, mimeType: nil,
                        fileName: nil, content: nil, id: nil, name: nil,
                        arguments: nil),
                ],
                timestamp: 1_783_328_621_179.0,
                toolCallId: nil, toolName: nil,
                usage: nil, stopReason: nil, errorMessage: nil)
            await storage.append([serverCopy], for: key)
        }

        let loaded = await storage.load(for: key)
        let thinkingEntries = loaded.filter { $0.role.lowercased() == "thinking" }
        XCTAssertEqual(loaded.count, 1,
            "after 4 server fetches + 1 streaming write, replace-on-match should leave just 1 assistant entry (the streaming one, with server's content inline) — got \(loaded.count) entries: roles=\(loaded.map { $0.role })")
        XCTAssertEqual(thinkingEntries.count, 0,
            "after replace-on-match, the server's thinking block lives INLINE on the assistant entry — no separate thinking entry needed")
        let inlineThinking = loaded.first?.content.first(where: { $0.thinking?.isEmpty == false })?.thinking
        XCTAssertEqual(inlineThinking, reasoning,
            "the inline thinking block must carry the server's reasoning text verbatim (and survive across repeated fetches)")
    }
}
