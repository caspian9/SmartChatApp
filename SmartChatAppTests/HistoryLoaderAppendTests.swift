import XCTest
import OpenClawChatUI
import OpenClawProtocol
@testable import SmartChatApp

/// Tests for issue #36's HistoryLoader change: the network
/// fetch path now uses `MessageCacheStore.append` instead of
/// `MessageCacheStorage.replaceForSession`. The wipe-and-replace
/// approach dropped client-only messages (the user-sent text
/// bubble for which the server hasn't yet emitted a history
/// record) and wiped streaming-time `usage` data; the new
/// append-only path merges the server payload onto whatever
/// the local cache already has.
///
/// The transport seam is `HistoryLoader.transportFactory`: a
/// test-injectable closure that returns a fake `OpenClawChatTransport`.
/// Production code uses the default (SessionManager.shared).
///
/// We use the production `MessageCacheStorage` (with a clean
/// UserDefaults suite per test) instead of `FakeMessageCacheStorage`
/// because the production storage has the dedup logic these
/// tests depend on (id-dedup + content-dedup). The fake is
/// simpler and tuned for `MessageCacheStoreTests`, where
/// content-dedup would break the `lastSeenTimestamp`
/// assertions.
@MainActor
final class HistoryLoaderAppendTests: XCTestCase {
    private var loader: HistoryLoader!
    private var vm: NativeChatViewModel!
    private var store: MessageCacheStore!
    private var storage: MessageCacheStorage!
    private var defaults: UserDefaults!
    private var fakeTransport: FakeHistoryTransport!
    private let testSuite = "test.openclaw.history-loader-append.\(UUID().uuidString)"

    override func setUp() async throws {
        await SessionManager.shared.disconnect()
        defaults = UserDefaults(suiteName: testSuite)!
        defaults.removePersistentDomain(forName: testSuite)
        storage = MessageCacheStorage(defaults: defaults)
        store = MessageCacheStore(storage: storage)
        vm = NativeChatViewModel(store: store)
        loader = HistoryLoader()
        loader.viewModel = vm
        loader.store = store
        fakeTransport = FakeHistoryTransport()
        loader.transportFactory = { [fakeTransport] _ in
            // Strong capture: the test owns `fakeTransport` as
            // a stored property for the test's lifetime, and the
            // closure runs synchronously during the awaited
            // `fetchAndMergeFromNetwork`. A weak capture here
            // would risk dropping the ref if the test setup ran
            // on a different actor than the loader.
            return fakeTransport
        }
    }

    override func tearDown() async throws {
        await SessionManager.shared.disconnect()
        loader = nil
        vm = nil
        store = nil
        storage = nil
        defaults?.removePersistentDomain(forName: testSuite)
        defaults = nil
        fakeTransport = nil
    }

    // MARK: - Test 1: client-only messages survive the merge
    //
    // Regression for the user-reported "my outgoing text bubble
    // disappeared after the network refresh" bug. With
    // `replaceForSession`, the server's history wipe erased the
    // client-only user message that hadn't yet been
    // server-confirmed. The append path keeps the cache and
    // merges the server payload on top.

    func test_fetchAndMergeFromNetwork_usesAppend_keepsClientOnlyMessages() async throws {
        let key = "session-1"
        vm.selectedSession = makeSession(key: key)
        let clientOnly = makeMsg(
            id: UUID(), role: "user", text: "client only",
            timestamp: 1000)
        let serverA = makeMsg(
            id: UUID(), role: "assistant", text: "A", timestamp: 2000)
        let serverB = makeMsg(
            id: UUID(), role: "assistant", text: "B", timestamp: 3000)
        let serverC = makeMsg(
            id: UUID(), role: "assistant", text: "C", timestamp: 4000)
        await store.append([clientOnly], for: key)
        await storage.flushPendingWrites()
        fakeTransport.payload = makeHistoryPayload(
            sessionKey: key, messages: [serverA, serverB, serverC])

        await loader.fetchAndMergeFromNetwork(
            sessionKey: key,
            sessionKeyPreview: String(key.prefix(8)),
            taskIdStr: "test1",
            scrollKind: .historyLoaded
        )

        let stored = store.messages(for: key)
        XCTAssertEqual(stored.count, 4,
                       "client-only user message must survive the merge (no wipe)")
        XCTAssertEqual(stored.map { $0.content.first?.text },
                       ["client only", "A", "B", "C"],
                       "messages must be in chronological order")
    }

    // MARK: - Test 2: content-dedup catches server returning same content twice
    //
    // A buggy server or a relay that double-emits could send the
    // same logical message twice in one history response. Because
    // the SDK's `OpenClawChatMessage.CodingKeys` omits `id` (a
    // known limitation, see `PersistedMessageEnvelope` for the
    // disk-round-trip workaround), each server-side decode gets
    // a fresh UUID. So the dedup that catches this is
    // **content-dedup** (same role + same text + same tsBucket),
    // not id-dedup. The store ends up with 2 entries (the
    // existing serverA from the pre-populate + the new serverB);
    // the duplicate A is dropped.

    func test_fetchAndMergeFromNetwork_contentDedup_serverReturnsSameMessageTwice_appendsOnce() async throws {
        let key = "session-1"
        vm.selectedSession = makeSession(key: key)
        let serverA = makeMsg(
            id: UUID(), role: "assistant", text: "duplicate A", timestamp: 2000)
        let serverADup = makeMsg(
            id: UUID(), role: "assistant", text: "duplicate A", timestamp: 2000)
        let serverB = makeMsg(
            id: UUID(), role: "assistant", text: "B", timestamp: 3000)
        await store.append([serverA], for: key)
        await storage.flushPendingWrites()
        // Server returns [serverA (same content, fresh id), serverB].
        // Content-dedup keeps the existing serverA, appends serverB.
        // Note: the SDK regenerates ids on decode, so even if the
        // server included the same id on the wire, the in-memory
        // copy would have a fresh UUID.
        fakeTransport.payload = makeHistoryPayload(
            sessionKey: key, messages: [serverADup, serverB])

        await loader.fetchAndMergeFromNetwork(
            sessionKey: key,
            sessionKeyPreview: String(key.prefix(8)),
            taskIdStr: "test2",
            scrollKind: .historyLoaded
        )

        let stored = store.messages(for: key)
        XCTAssertEqual(stored.count, 2,
                       "content-dedup must drop the duplicate A; only serverB is new")
        XCTAssertEqual(stored.map { $0.content.first?.text }, ["duplicate A", "B"])
    }

    // MARK: - Test 3: streaming-time `usage` preserved across merge
    //
    // Regression for the user-reported "input / output / cache
    // tokens disappeared after refresh" bug. The server's
    // `chat.history` payload omits the streaming-time `usage`
    // block. With `replaceForSession`, the wipe + replace dropped
    // the streaming-time `usage` data. With `append`, the
    // existing entry's `usage` is preserved (last-write-wins
    // content dedup keeps the existing entry by id).

    func test_fetchAndMergeFromNetwork_streamingUsagePreserved_afterMerge() async throws {
        let key = "session-1"
        vm.selectedSession = makeSession(key: key)
        let sharedId = UUID()
        let streamingUsage = makeUsageSentinel(input: 1234)
        let streamed = OpenClawChatMessage(
            id: sharedId, role: "assistant",
            content: [OpenClawChatMessageContent(
                type: "text", text: "final answer", thinking: nil,
                thinkingSignature: nil, mimeType: nil, fileName: nil,
                content: nil)],
            timestamp: 2000, toolCallId: nil, toolName: nil,
            usage: streamingUsage, stopReason: nil, errorMessage: nil)
        await store.append([streamed], for: key)
        await storage.flushPendingWrites()
        // Server returns the same logical message (same text +
        // role + same timestamp) but with `usage: nil` — the
        // typical shape of `chat.history`.
        let serverCopy = OpenClawChatMessage(
            id: sharedId, role: "assistant",
            content: [OpenClawChatMessageContent(
                type: "text", text: "final answer", thinking: nil,
                thinkingSignature: nil, mimeType: nil, fileName: nil,
                content: nil)],
            timestamp: 2000, toolCallId: nil, toolName: nil,
            usage: nil, stopReason: nil, errorMessage: nil)
        fakeTransport.payload = makeHistoryPayload(
            sessionKey: key, messages: [serverCopy])

        await loader.fetchAndMergeFromNetwork(
            sessionKey: key,
            sessionKeyPreview: String(key.prefix(8)),
            taskIdStr: "test3",
            scrollKind: .historyLoaded
        )

        let stored = store.messages(for: key)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.usage?.input, 1234,
                       "streaming-time usage must survive the server merge (input=1234, server omitted it)")
    }

    // MARK: - Test 4: streaming-time `usage` preserved when ids differ
    //
    // C1 follow-up: the test above (`streamingUsagePreserved_afterMerge`)
    // uses `sharedId` for both the streamed and server copies. With
    // matching ids, `MessageCacheStorage.append`'s new id-dedup drops
    // the server copy BEFORE `applyUsagePreservation` has a chance to
    // run — so that test passes by id-dedup, not by the splice. This
    // test covers the realistic production case: the SDK's
    // `OpenClawChatMessage.CodingKeys` omits `id` (see
    // `PersistedMessageEnvelope`), so every server-side decode gets
    // a fresh UUID, and the streamed (client-side synthesized) id
    // never matches the server's id. The dedup that actually saves
    // the streaming-time usage in production is therefore the
    // KEEP-on-content-match branch of `append` — the existing entry
    // stays, with its original `usage` intact.
    //
    // Asserts the user-visible contract: streaming-time `usage`
    // survives the merge even when ids differ. (`applyUsagePreservation`
    // runs first to splice usage into the server copy, then
    // content-dedup drops the server copy and keeps the streamed one.
    // The end state is the same: usage preserved.)

    func test_fetchAndMergeFromNetwork_streamingUsagePreserved_differentIds_afterMerge() async throws {
        let key = "session-1"
        vm.selectedSession = makeSession(key: key)
        let streamedId = UUID()
        let serverId = UUID()
        let streamingUsage = makeUsageSentinel(input: 1234)
        let streamed = OpenClawChatMessage(
            id: streamedId, role: "assistant",
            content: [OpenClawChatMessageContent(
                type: "text", text: "final answer", thinking: nil,
                thinkingSignature: nil, mimeType: nil, fileName: nil,
                content: nil)],
            timestamp: 2000, toolCallId: nil, toolName: nil,
            usage: streamingUsage, stopReason: nil, errorMessage: nil)
        await store.append([streamed], for: key)
        await storage.flushPendingWrites()
        // Server returns the same logical message (same text +
        // role + same timestamp) but with a FRESH id and
        // `usage: nil` — the typical shape of `chat.history`
        // after the SDK drops `id` on JSON decode.
        let serverCopy = OpenClawChatMessage(
            id: serverId, role: "assistant",
            content: [OpenClawChatMessageContent(
                type: "text", text: "final answer", thinking: nil,
                thinkingSignature: nil, mimeType: nil, fileName: nil,
                content: nil)],
            timestamp: 2000, toolCallId: nil, toolName: nil,
            usage: nil, stopReason: nil, errorMessage: nil)
        fakeTransport.payload = makeHistoryPayload(
            sessionKey: key, messages: [serverCopy])

        await loader.fetchAndMergeFromNetwork(
            sessionKey: key,
            sessionKeyPreview: String(key.prefix(8)),
            taskIdStr: "test4",
            scrollKind: .historyLoaded
        )

        let stored = store.messages(for: key)
        XCTAssertEqual(stored.count, 1,
                       "content-dedup must keep the streamed entry; the fresh-id server copy is dropped")
        XCTAssertEqual(stored.first?.usage?.input, 1234,
                       "streaming-time usage must survive even when the server copy has a different id (input=1234, server omitted it)")
        XCTAssertEqual(stored.first?.id, streamedId,
                       "the entry that survives is the streamed (client-synthesized) one — content-dedup keeps it by KEEP-on-content-match")
    }

        // MARK: - Test 5: streaming's assistant + server's sibling thinking → both preserved
    //
    // User-reported 2026-07-06: when stream + history merge, the
    // assistant bubble's thinking and 4 token usage fields don't
    // display. Pure history works. Pure stream works. Only the
    // merge is broken.
    //
    // Production scenario (issue #36 + the dedup path):
    //   1. Stream runs. The streaming-side `lifecycle=end` writes
    //      an assistant entry with text + usage, no thinking
    //      block (EventInterpreter flattens the assistant text
    //      into a single `{type:"text", text:...}` content
    //      block; the streaming path doesn't capture the
    //      sibling reasoning block).
    //   2. User pulls to refresh. Server's `chat.history`
    //      returns the same turn with the reasoning AS A
    //      SIBLING `{type:"thinking", thinking:...}` content
    //      block alongside the text. Server's entry also has
    //      `usage` (newer server version) or nil (older).
    //   3. `append` dedups by content (KEEP-on-match), so the
    //      streaming entry is preserved. The server entry is
    //      dropped — including its thinking block and its
    //      usage. Without the splice, the assistant bubble
    //      has no thinking and the usage footer is lost.
    //
    // This test pins the desired behavior: after the merge,
    // the cache has
    //   (a) the streamed assistant entry (with usage)
    //   (b) a spliced thinking entry carrying the server's
    //       reasoning text
    // so the view's footer shows the 4 token counts and the
    // thinking bubble renders the reasoning.

    func test_fetchAndMergeFromNetwork_streamingTextNoThinking_serverSiblingThinking_spliceAddsThinking() async throws {
        let key = "session-1"
        vm.selectedSession = makeSession(key: key)

        // Step 1: streaming-side writes a final assistant
        // entry with text + usage (no thinking block). The
        // streaming entry's id is client-synthesized
        // (`deterministicUUID(<runId>:assistant:0)`), distinct
        // from any server-assigned UUID.
        let streamedAssistantId = UUID()
        let streamingUsage = makeUsageSentinel(input: 1234)
        let streamedAssistant = OpenClawChatMessage(
            id: streamedAssistantId, role: "assistant",
            content: [OpenClawChatMessageContent(
                type: "text", text: "**Region E current weather** ☀️",
                thinking: nil, thinkingSignature: nil, mimeType: nil,
                fileName: nil, content: nil, id: nil, name: nil,
                arguments: nil)],
            timestamp: 1_783_328_621_179.0,
            toolCallId: nil, toolName: nil,
            usage: streamingUsage, stopReason: nil, errorMessage: nil)
        await store.append([streamedAssistant], for: key)
        await storage.flushPendingWrites()

        // Server ts is 1ms after the streaming ts. The
        // `hasNewContent` guard in `HistoryLoader.fetchAndMergeFromNetwork`
        // short-circuits when `newMax <= lastSeenTimestamp`, and
        // the test setup above bumped `lastSeenTimestamp` to
        // `1_783_328_621_179.0`. An equal ts would skip the merge
        // entirely; the 1ms offset forces the merge to run.
        let serverTs = 1_783_328_621_180.0

        // Step 2: server returns the same logical turn WITH
        // a sibling thinking block. The server-side `id` is
        // a fresh UUID (SDK drops `id` on JSON decode).
        // The server's `usage` is non-nil (newer server
        // version sends real token counts) — applyUsagePreservation
        // early-returns for non-nil `usage`, so the server's
        // `usage` flows through unchanged. (The streaming
        // entry's `usage` would also be preserved if the
        // server omitted it, by the applyUsagePreservation
        // splice on the existing matching entry.)
        let serverAssistant = OpenClawChatMessage(
            id: UUID(), role: "assistant",
            content: [
                OpenClawChatMessageContent(
                    type: "text", text: "**Region E current weather** ☀️",
                    thinking: nil, thinkingSignature: nil, mimeType: nil,
                    fileName: nil, content: nil, id: nil, name: nil,
                    arguments: nil),
                OpenClawChatMessageContent(
                    type: "thinking", text: nil,
                    thinking: "The user sent multiple messages - some follow-up questions",
                    thinkingSignature: nil, mimeType: nil,
                    fileName: nil, content: nil, id: nil, name: nil,
                    arguments: nil),
            ],
            timestamp: serverTs,
            toolCallId: nil, toolName: nil,
            usage: streamingUsage, // server has same usage
            stopReason: nil, errorMessage: nil)
        fakeTransport.payload = makeHistoryPayload(
            sessionKey: key, messages: [serverAssistant])

        // Step 3: merge.
        await loader.fetchAndMergeFromNetwork(
            sessionKey: key,
            sessionKeyPreview: String(key.prefix(8)),
            taskIdStr: "test5",
            scrollKind: .historyLoaded
        )

        // Verify the cache has the expected post-merge shape.
        // After BUG-7's replace-on-match fix: the streaming
        // entry is REPLACED with the server entry (keeping
        // the streaming id, picking up server's inline
        // thinking block + usage). The thinking content is
        // now carried INLINE in the assistant entry's
        // content array — `ChatMessageConverter.toChatMessage`
        // emits it as a separate thinking bubble from the
        // sibling block, so the view still renders the
        // reasoning without a duplicate.
        let stored = store.messages(for: key)
        let assistantEntries = stored.filter { $0.role.lowercased() == "assistant" }
        let standaloneThinkingEntries = stored.filter { $0.role.lowercased() == "thinking" }

        XCTAssertEqual(assistantEntries.count, 1,
            "the streamed assistant entry must survive the merge as the single assistant — got \(assistantEntries.count) entries")
        XCTAssertEqual(standaloneThinkingEntries.count, 0,
            "the server's sibling thinking block lives INLINE in the assistant entry now (replaced-on-match); a standalone role:thinking entry would be a duplicate rendering")

        // Verify the assistant's inline thinking block survived
        // the replacement — this is what `ChatMessageConverter`
        // reads to emit the thinking bubble.
        let survivingAssistant = assistantEntries.first
        let inlineThinking = survivingAssistant?.content.first(where: { $0.thinking?.isEmpty == false })?.thinking
        XCTAssertEqual(inlineThinking,
            "The user sent multiple messages - some follow-up questions",
            "the server's sibling thinking block must survive the replace-on-match as an inline content block on the assistant entry")

        // Verify the assistant's 4 token usage fields survived
        // (this is the user-visible contract — the bubble's
        // footer reads `usage.input`/`usage.output`/etc).
        XCTAssertEqual(survivingAssistant?.usage?.input, 1234,
            "assistant's input token count must survive the merge (input=1234, server had same)")
        XCTAssertEqual(survivingAssistant?.usage?.output, -1,
            "assistant's output token count must survive (output sentinel = -1)")
        XCTAssertEqual(survivingAssistant?.id, streamedAssistantId,
            "the entry that survives is the streamed (client-synthesized) one — replace-on-match preserves the streaming id for CollapseStateCache")
    }

    // MARK: - Test 6: server's usage must survive when streaming entry had no usage
    //
    // User-reported 2026-07-06 (log 09:04:53): the assistant's
    // 4 token usage fields don't display after stream + history
    // merge. Production data flow: streaming's `lifecycle=end`
    // sometimes arrives WITHOUT a `usage` block (e.g., gateway
    // didn't include it, or the run was aborted before token
    // accounting finalized). The server's `chat.history`
    // returns the same turn WITH `usage` (newer server
    // version). KEEP-on-content-match drops the server copy
    // — taking its usage with it — leaving the user with no
    // token counts on the bubble's footer.
    //
    // The desired behavior: when the existing (streaming)
    // entry has no `usage` but the incoming (server) entry
    // does, splice `usage` from the incoming entry onto the
    // existing entry — same pattern as the thinking-splice
    // (issue #36 follow-up). Idempotent across repeated
    // refreshes.

    func test_fetchAndMergeFromNetwork_streamingNoUsage_serverHasUsage_spliceAddsUsage() async throws {
        let key = "session-1"
        vm.selectedSession = makeSession(key: key)

        // Step 1: streaming-side wrote the final assistant
        // entry WITHOUT `usage` (e.g., lifecycle=end's payload
        // omitted the usage block).
        let streamedAssistantId = UUID()
        let streamedAssistant = OpenClawChatMessage(
            id: streamedAssistantId, role: "assistant",
            content: [OpenClawChatMessageContent(
                type: "text", text: "**Region E current weather** ☀️",
                thinking: nil, thinkingSignature: nil, mimeType: nil,
                fileName: nil, content: nil, id: nil, name: nil,
                arguments: nil)],
            timestamp: 1_783_328_621_179.0,
            toolCallId: nil, toolName: nil,
            usage: nil, // no usage on the streaming copy
            stopReason: nil, errorMessage: nil)
        await store.append([streamedAssistant], for: key)
        await storage.flushPendingWrites()

        // Step 2: server returns the same turn WITH a full
        // usage block (newer server version).
        let serverUsage = makeUsageSentinel(input: 4321)
        let serverAssistant = OpenClawChatMessage(
            id: UUID(), role: "assistant",
            content: [OpenClawChatMessageContent(
                type: "text", text: "**Region E current weather** ☀️",
                thinking: nil, thinkingSignature: nil, mimeType: nil,
                fileName: nil, content: nil, id: nil, name: nil,
                arguments: nil)],
            timestamp: 1_783_328_621_180.0, // 1ms after streaming
            toolCallId: nil, toolName: nil,
            usage: serverUsage,
            stopReason: nil, errorMessage: nil)
        fakeTransport.payload = makeHistoryPayload(
            sessionKey: key, messages: [serverAssistant])

        await loader.fetchAndMergeFromNetwork(
            sessionKey: key,
            sessionKeyPreview: String(key.prefix(8)),
            taskIdStr: "test6",
            scrollKind: .historyLoaded
        )

        // Verify the cache has the streamed entry with the
        // server's usage spliced in.
        let stored = store.messages(for: key)
        let surviving = stored.first(where: { $0.id == streamedAssistantId })
        XCTAssertNotNil(surviving,
            "the streamed entry must survive the merge (KEEP-on-content-match)")
        XCTAssertEqual(surviving?.usage?.input, 4321,
            "server's input token count must be spliced onto the streamed entry — got nil or wrong value")
        XCTAssertEqual(surviving?.usage?.output, -1,
            "server's output token count must be spliced (sentinel = -1)")
    }

    // MARK: - Test 7: replace-on-match collapses two assistant bubbles
    //
    // User-reported 2026-07-07 (BUG-7): after stream + history
    // merge, two assistant bubbles are visible — one from the
    // stream (no usage) and one from the server's `chat.history`
    // (with usage). The user's diagnosis: the dedup key DOES
    // NOT match between the two — the streaming entry has no
    // usage while the server's has usage, AND both have
    // identical text + role + same 60s bucket. Wait, that
    // scenario would dedup. So the actual cause must be
    // bucket drift: the streaming entry's `OpenClawChatMessage.
    // timestamp` (from `EventInterpreter.chosenAnchor`, which
    // falls back to `Date()` when the gateway's `endedAtMs` is
    // 0) lands in one 60s bucket while the server's
    // `chat.history` copy lands in a different one, breaking
    // the content-dedup. Or — the streaming text and the
    // server text differ at byte level despite both being
    // "hello world" (e.g., the streaming path uses suffix-
    // overlap collapse which can leave a small residue).
    //
    // The fix is replace-on-match: when content-dedup hits,
    // REPLACE the streaming entry with the server's richer
    // entry, preserving the streaming id (CollapseStateCache).
    // The streaming entry becomes the server entry in place
    // — no second bubble, no missing usage.
    //
    // This test pins the contract: regardless of why the
    // streaming entry and the server entry are "close but
    // not equal", the merge produces exactly ONE assistant
    // bubble (the streaming entry's id), and that bubble
    // carries the server's `usage` and (if present) the
    // server's inline thinking block.

    func test_fetchAndMergeFromNetwork_streamingVsServer_replaceOnMatch_collapsesToOneAssistant() async throws {
        let key = "session-1"
        vm.selectedSession = makeSession(key: key)

        // Step 1: streaming-side wrote a final assistant
        // entry WITHOUT `usage` (e.g., lifecycle=end omitted
        // the usage block).
        let streamedAssistantId = UUID()
        let streamedAssistant = OpenClawChatMessage(
            id: streamedAssistantId, role: "assistant",
            content: [OpenClawChatMessageContent(
                type: "text", text: "**Region E current weather** ☀️",
                thinking: nil, thinkingSignature: nil, mimeType: nil,
                fileName: nil, content: nil, id: nil, name: nil,
                arguments: nil)],
            timestamp: 1_783_328_621_179.0,
            toolCallId: nil, toolName: nil,
            usage: nil,
            stopReason: nil, errorMessage: nil)
        await store.append([streamedAssistant], for: key)
        await storage.flushPendingWrites()

        // Step 2: server returns the same turn WITH a full
        // usage block + sibling thinking block.
        // Importantly: timestamp is in a DIFFERENT 60s
        // bucket from the streaming entry — emulating the
        // production scenario where `chosenAnchor` falls
        // back to `Date()` and the server's end-time is
        // seconds earlier. The 60s-bucket content-dedup
        // would MISS, leaving two assistant bubbles.
        let serverUsage = makeUsageSentinel(input: 4321)
        let serverAssistant = OpenClawChatMessage(
            id: UUID(), role: "assistant",
            content: [
                OpenClawChatMessageContent(
                    type: "text", text: "**Region E current weather** ☀️",
                    thinking: nil, thinkingSignature: nil, mimeType: nil,
                    fileName: nil, content: nil, id: nil, name: nil,
                    arguments: nil),
                OpenClawChatMessageContent(
                    type: "thinking", text: nil,
                    thinking: "Weather query reasoning",
                    thinkingSignature: nil, mimeType: nil,
                    fileName: nil, content: nil, id: nil, name: nil,
                    arguments: nil),
            ],
            // 70 seconds later — different 60s bucket
            timestamp: 1_783_328_621_179.0 + 70_000,
            toolCallId: nil, toolName: nil,
            usage: serverUsage,
            stopReason: nil, errorMessage: nil)
        fakeTransport.payload = makeHistoryPayload(
            sessionKey: key, messages: [serverAssistant])

        // Step 3: merge. Without BUG-7's fix, this would
        // leave two assistant bubbles (different
        // timestamps → different `tsBucket` → content-dedup
        // misses).
        await loader.fetchAndMergeFromNetwork(
            sessionKey: key,
            sessionKeyPreview: String(key.prefix(8)),
            taskIdStr: "test7",
            scrollKind: .historyLoaded
        )

        // The streaming entry's id is preserved (so
        // CollapseStateCache doesn't lose its key) and the
        // server's content + usage take over.
        let stored = store.messages(for: key)
        XCTAssertEqual(stored.count, 1,
            "exactly one entry must survive the merge — got \(stored.count) (BUG-7 regression: stream + history left two assistant bubbles)")
        XCTAssertEqual(stored.first?.id, streamedAssistantId,
            "the surviving entry must keep the streaming id (for CollapseStateCache compatibility)")
        XCTAssertEqual(stored.first?.role.lowercased(), "assistant",
            "the surviving entry must be the assistant")
        XCTAssertEqual(stored.first?.usage?.input, 4321,
            "the server's usage.input must replace the streaming entry's nil usage — got \(String(describing: stored.first?.usage?.input))")
        XCTAssertEqual(stored.first?.usage?.output, -1,
            "the server's usage.output must replace the streaming entry's nil usage")
        // The inline thinking block from the server must
        // survive the replacement.
        let inlineThinking = stored.first?.content.first(where: { $0.thinking?.isEmpty == false })?.thinking
        XCTAssertEqual(inlineThinking, "Weather query reasoning",
            "the server's inline thinking block must survive the replace-on-match")
    }

    // MARK: - Helpers

    private func makeMsg(id: UUID = UUID(), role: String = "assistant",
                         text: String = "x",
                         timestamp: Double = 1000) -> OpenClawChatMessage {
        OpenClawChatMessage(
            id: id, role: role,
            content: [OpenClawChatMessageContent(
                type: "text", text: text, thinking: nil,
                thinkingSignature: nil, mimeType: nil, fileName: nil,
                content: nil)],
            timestamp: timestamp, toolCallId: nil, toolName: nil,
            usage: nil, stopReason: nil, errorMessage: nil)
    }

    /// `fetchAndMergeFromNetwork` reads `viewModel.selectedSession`
    /// to check that the user hasn't switched sessions since the
    /// network call started. Tests need a selected session set so
    /// the staleness guard doesn't fire and the merge runs.
    private func makeSession(key: String) -> OpenClawChatSessionEntry {
        OpenClawChatSessionEntry(
            key: key, kind: "test", displayName: "Test Session",
            surface: nil, subject: nil, room: nil, space: nil,
            updatedAt: nil, sessionId: nil, systemSent: nil,
            abortedLastRun: nil, thinkingLevel: nil, verboseLevel: nil,
            inputTokens: nil, outputTokens: nil, totalTokens: nil,
            modelProvider: nil, model: nil, contextTokens: nil,
            thinkingLevels: nil, thinkingOptions: nil,
            thinkingDefault: nil)
    }

    /// Round-trip a usage sentinel through JSONEncoder/JSONDecoder
    /// the same way `ChatMessageConverter.toOpenClawChatMessage`
    /// does for `usage` — `OpenClawChatUsage` has no memberwise
    /// init, only `Codable` synthesis.
    private func makeUsageSentinel(input: Int) -> OpenClawChatUsage {
        let payload: [String: Any] = [
            "input": input, "output": -1, "cacheRead": -1,
            "cacheWrite": -1, "total": -1
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return try! JSONDecoder().decode(OpenClawChatUsage.self, from: data)
    }

    /// Builds an `OpenClawChatHistoryPayload` from a sessionKey +
    /// message list. The struct has no memberwise init in the
    /// SDK (only `Codable` synthesis), so we build the JSON by
    /// encoding each message individually and assembling the
    /// top-level dict. Mirrors the approach used by
    /// `GatewayChatTransport.payloadWithEmptyMessages`.
    private func makeHistoryPayload(
        sessionKey: String,
        messages: [OpenClawChatMessage]
    ) -> OpenClawChatHistoryPayload {
        let encoder = JSONEncoder()
        let messageDicts: [[String: Any]] = messages.map { msg in
            let data = (try? encoder.encode(msg)) ?? Data()
            let obj = try? JSONSerialization.jsonObject(with: data)
            return (obj as? [String: Any]) ?? [:]
        }
        let topLevel: [String: Any] = [
            "sessionKey": sessionKey,
            "messages": messageDicts
        ]
        let data = try! JSONSerialization.data(withJSONObject: topLevel)
        return try! JSONDecoder().decode(
            OpenClawChatHistoryPayload.self, from: data)
    }
}

/// In-memory fake for `OpenClawChatTransport.requestHistory`.
/// Records the requested sessionKey and returns whatever the
/// test stashed in `payload`. All other protocol methods are
/// satisfied by the SDK's default extension implementations
/// (most throw "not supported by this transport"). The
/// `events()` extension returns an empty stream.
final class FakeHistoryTransport: OpenClawChatTransport, @unchecked Sendable {
    var payload: OpenClawChatHistoryPayload?
    var requestedKeys: [String] = []

    func requestHistory(sessionKey: String) async throws -> OpenClawChatHistoryPayload {
        requestedKeys.append(sessionKey)
        if let payload {
            return payload
        }
        // Empty fallback — build via JSON round-trip because
        // `OpenClawChatHistoryPayload` has no public memberwise
        // init in the SDK.
        let jsonStr = "{\"sessionKey\": \"\(sessionKey)\", \"messages\": []}"
        let data = jsonStr.data(using: .utf8)!
        return try JSONDecoder().decode(
            OpenClawChatHistoryPayload.self, from: data)
    }

    // Other protocol methods — only `requestHistory` is exercised
    // by `HistoryLoader.fetchAndMergeFromNetwork`. The SDK
    // extension provides defaults for `createSession`,
    // `setActiveSessionKey`, `waitForRunCompletion`,
    // `resetSession`, `compactSession`, `abortRun`,
    // `listSessions`, `listModels`, `setSessionModel`,
    // `setSessionThinking`. Three are NOT extended — provide
    // minimal stubs.

    func sendMessage(
        sessionKey: String, message: String, thinking: String,
        idempotencyKey: String,
        attachments: [OpenClawChatAttachmentPayload]
    ) async throws -> OpenClawChatSendResponse {
        throw URLError(.unsupportedURL)
    }
    func requestHealth(timeoutMs: Int) async throws -> Bool {
        return true
    }
    func events() -> AsyncStream<OpenClawChatTransportEvent> {
        AsyncStream { _ in }
    }
}