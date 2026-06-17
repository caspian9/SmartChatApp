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
        let storage1 = MessageCacheStorage(defaults: defaults!)
        _ = await storage1.append([original], for: key)
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
        let storage2 = MessageCacheStorage(defaults: defaults!)
        let loaded = await storage2.load(for: key)
        XCTAssertEqual(loaded.count, 4)
        let loadedIds = Set(loaded.map { $0.id })
        let originalIdsSet = Set(originalIds)
        XCTAssertEqual(loadedIds, originalIdsSet,
                       "all 4 ids must match originals after restart")
    }
}
