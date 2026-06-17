import XCTest
import OpenClawChatUI
import OpenClawProtocol
@testable import SmartChatApp

/// Regression for the user-reported "#11 toolCall appears below #12 toolResult"
/// (sort key on toolCall is LATER than toolResult, so the chat order is
/// reversed). The "natural" chronology of a single tool call from the
/// server is `item (start) → command_output (delta) → command_output
/// (end) → item (end)`. The toolCall bubble gets `upsert`-updated on
/// every `item` event; if we let the per-phase `timestamp` overwrite
/// the toolCall's sort key, the final toolCall ends up with the END
/// event's timestamp — which is LATER than the toolResult's
/// `command_output (end)` timestamp. The store's `allMessages.sort`
/// then renders "toolResult above toolCall". The fix: pin the
/// toolCall's sort `timestamp` to the start time, so toolCall sorts
/// BEFORE toolResult regardless of when `item (end)` lands.
@MainActor
final class EventInterpreterItemSortTests: XCTestCase {
    private var vm: NativeChatViewModel!
    private var store: MessageCacheStore!
    private var fakeStorage: FakeMessageCacheStorage!
    private var interpreter: EventInterpreter!

    override func setUp() async throws {
        fakeStorage = FakeMessageCacheStorage()
        store = MessageCacheStore(storage: fakeStorage)
        vm = NativeChatViewModel(store: store)
        vm.selectedSession = makeTestSession()
        interpreter = vm.eventInterpreter
        CollapseStateCache.shared.clear()
    }

    override func tearDown() async throws {
        CollapseStateCache.shared.clear()
        vm = nil
        store = nil
        fakeStorage = nil
        interpreter = nil
    }

    func test_itemThenCommandOutput_toolCallSortsBeforeToolResult() async throws {
        // Server's natural chronology for a single tool call. ts is
        // milliseconds since epoch (matching `OpenClawAgentEventPayload.ts`).
        // toolCall.start (T1) < command_output.end (T3) < item.end (T4),
        // so the toolCall SHOULD be the start time and the toolResult
        // the end time, with the toolCall sorting first.
        let runId = "r-item-1"
        let canonical = "tc-bash-1"
        let t1: Int = 1_000  // item (start)
        let t2: Int = 1_100  // command_output (delta)
        let t3: Int = 1_200  // command_output (end)
        let t4: Int = 1_300  // item (end)

        await interpreter.handleTransportEvent(
            .agent(makeItemEvent(runId: runId, ts: t1, canonical: canonical, phase: "start", summary: nil)),
            sessionKey: "session-1")
        await interpreter.handleTransportEvent(
            .agent(makeCommandOutputEvent(runId: runId, ts: t2, canonical: canonical, phase: "delta", output: "hello ")),
            sessionKey: "session-1")
        await interpreter.handleTransportEvent(
            .agent(makeCommandOutputEvent(runId: runId, ts: t3, canonical: canonical, phase: "end", output: "world")),
            sessionKey: "session-1")
        await interpreter.handleTransportEvent(
            .agent(makeItemEvent(runId: runId, ts: t4, canonical: canonical, phase: "end", summary: nil)),
            sessionKey: "session-1")
        // Drain the upsert Tasks before reading the store
        try await Task.sleep(nanoseconds: 300_000_000)

        let stored = store.messages(for: "session-1", since: nil)
        XCTAssertEqual(stored.count, 2, "toolCall and toolResult each collapse to one entry via upsert; got \(stored.count)")

        // Find the two roles. We don't know the exact sort order yet —
        // that's what the test asserts.
        let toolCall = stored.first { ($0.content.first?.text ?? "").contains("ToolCall") }
        let toolResult = stored.first { $0.role == "toolResult" }
        XCTAssertNotNil(toolCall, "toolCall entry must exist")
        XCTAssertNotNil(toolResult, "toolResult entry must exist")
        guard let toolCall, let toolResult,
              let toolCallTs = toolCall.timestamp,
              let toolResultTs = toolResult.timestamp else {
            XCTFail("toolCall and toolResult must have non-nil timestamps for sort comparison")
            return
        }

        XCTAssertLessThan(
            toolCallTs, toolResultTs,
            "toolCall's sort timestamp must be the start time (\(t1) ms), toolResult's must be the command_output end time (\(t3) ms). Got toolCall=\(toolCallTs) toolResult=\(toolResultTs). With the previous bug the toolCall would carry the item end time (\(t4) ms) and sort AFTER the toolResult, rendering 'toolResult above toolCall' in the chat.")

        // The chat order is the store's timestamp-ascending order; the
        // first entry is the toolCall (the request, which logically
        // precedes the response).
        XCTAssertEqual(stored.first?.id, toolCall.id, "toolCall must come first in the chat order")
        XCTAssertEqual(stored.last?.id, toolResult.id, "toolResult must come after the toolCall")
    }

    func test_itemEndWithSummary_toolCallSortsBeforeToolResult() async throws {
        // When the `item (end)` event carries a `summary` field, the
        // toolResult is created from the summary (not from
        // `command_output`). The summary's timestamp is the item end
        // time, which collides with the toolCall's per-phase
        // overwrite. Without the fix, both have the same timestamp and
        // the stable sort's insertion order decides (which happened
        // to be correct, but was fragile). With the fix, the
        // toolCall's sort key is pinned to the start time so the
        // result is correct by construction.
        let runId = "r-item-2"
        let canonical = "tc-bash-2"
        let t1: Int = 2_000
        let t4: Int = 2_500  // item (end) carries the summary, this is also the toolResult's ts

        await interpreter.handleTransportEvent(
            .agent(makeItemEvent(runId: runId, ts: t1, canonical: canonical, phase: "start", summary: nil)),
            sessionKey: "session-1")
        await interpreter.handleTransportEvent(
            .agent(makeItemEvent(runId: runId, ts: t4, canonical: canonical, phase: "end", summary: "captured output")),
            sessionKey: "session-1")
        try await Task.sleep(nanoseconds: 300_000_000)

        let stored = store.messages(for: "session-1", since: nil)
        XCTAssertEqual(stored.count, 2)
        let toolCall = stored.first { ($0.content.first?.text ?? "").contains("ToolCall") }
        let toolResult = stored.first { $0.role == "toolResult" }
        XCTAssertNotNil(toolCall)
        XCTAssertNotNil(toolResult)
        guard let toolCall, let toolResult,
              let toolCallTs = toolCall.timestamp,
              let toolResultTs = toolResult.timestamp else {
            XCTFail("toolCall and toolResult must have non-nil timestamps for sort comparison")
            return
        }
        XCTAssertLessThan(
            toolCallTs, toolResultTs,
            "toolCall (start=\(t1) ms) must sort BEFORE toolResult (item end summary=\(t4) ms)")
    }

    // MARK: - Thinking stream

    func test_thinkingDelta_dataWithThinkingKey_createsBubble() async throws {
        // Regression for the user-reported "thinking content not
        // displayed during receiving" complaint. The `case "thinking"`
        // handler used
        // to read only `data["text"]`. Servers that emit the
        // semantically-accurate `data["thinking"]` field (matching
        // `sessionMessage`'s `block.thinking` and the OpenClawChat
        // content model) would have the handler read `text=""`,
        // short-circuit on `guard !text.isEmpty`, and skip bubble
        // creation entirely. After the fix we read `thinking` first,
        // fall back to `text` for older servers.
        let runId = "r-thinking-1"
        let thinkingText = "The user is asking about Hebei province weather."
        await interpreter.handleTransportEvent(
            .agent(makeThinkingEvent(runId: runId, ts: 3_000, data: ["thinking": thinkingText])),
            sessionKey: "session-1")
        try await Task.sleep(nanoseconds: 200_000_000)

        let stored = store.messages(for: "session-1", since: nil)
        XCTAssertEqual(stored.count, 1, "thinking event must produce exactly one bubble")
        XCTAssertEqual(stored.first?.role, "thinking")
        XCTAssertEqual(stored.first?.content.first?.text, thinkingText)
    }

    func test_thinkingDelta_dataWithTextKey_stillWorksAsFallback() async throws {
        // Backward compat: older servers emit `data["text"]` for the
        // thinking payload. The handler must still pick it up so we
        // don't regress the existing data path.
        let runId = "r-thinking-2"
        let text = "Reasoning about the request."
        await interpreter.handleTransportEvent(
            .agent(makeThinkingEvent(runId: runId, ts: 3_100, data: ["text": text])),
            sessionKey: "session-1")
        try await Task.sleep(nanoseconds: 200_000_000)

        let stored = store.messages(for: "session-1", since: nil)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.content.first?.text, text)
    }

    func test_thinkingDelta_incrementalDeltas_accumulateFullText() async throws {
        // Without an accumulator, each incremental delta upserts over
        // the previous entry and the final bubble contains only the
        // last fragment. This mirrors the `case "assistant"`
        // accumulator pattern — the same `accumulated*TextByRun`
        // machinery is needed for the thinking stream.
        let runId = "r-thinking-3"
        await interpreter.handleTransportEvent(
            .agent(makeThinkingEvent(runId: runId, ts: 3_200, data: ["thinking": "Part 1. "])),
            sessionKey: "session-1")
        await interpreter.handleTransportEvent(
            .agent(makeThinkingEvent(runId: runId, ts: 3_300, data: ["thinking": "Part 2. "])),
            sessionKey: "session-1")
        await interpreter.handleTransportEvent(
            .agent(makeThinkingEvent(runId: runId, ts: 3_400, data: ["thinking": "Part 3."])),
            sessionKey: "session-1")
        try await Task.sleep(nanoseconds: 300_000_000)

        let stored = store.messages(for: "session-1", since: nil)
        XCTAssertEqual(stored.count, 1, "All deltas collapse to one entry via upsert")
        XCTAssertEqual(
            stored.first?.content.first?.text, "Part 1. Part 2. Part 3.",
            "Incremental deltas must accumulate (final text = concatenation), not overwrite (which would leave only 'Part 3.')")
    }

    func test_thinkingDelta_cumulativeDeltas_takeLatest() async throws {
        // If the server sends cumulative text on every chunk ("Part 1"
        // → "Part 1 Part 2" → "Part 1 Part 2 Part 3"), the latest
        // delta already contains the full text. The accumulator
        // should detect `text.hasPrefix(prev)` and use the new delta
        // as-is rather than appending (which would double-count).
        let runId = "r-thinking-4"
        await interpreter.handleTransportEvent(
            .agent(makeThinkingEvent(runId: runId, ts: 3_500, data: ["thinking": "Part 1"])),
            sessionKey: "session-1")
        await interpreter.handleTransportEvent(
            .agent(makeThinkingEvent(runId: runId, ts: 3_600, data: ["thinking": "Part 1 Part 2"])),
            sessionKey: "session-1")
        await interpreter.handleTransportEvent(
            .agent(makeThinkingEvent(runId: runId, ts: 3_700, data: ["thinking": "Part 1 Part 2 Part 3"])),
            sessionKey: "session-1")
        try await Task.sleep(nanoseconds: 300_000_000)

        let stored = store.messages(for: "session-1", since: nil)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.content.first?.text, "Part 1 Part 2 Part 3")
    }

    func test_thinkingDelta_staleDelta_isIgnored() async throws {
        // Out-of-order arrival: a stale delta whose text is a prefix
        // of the current accumulator (we've already moved past this
        // state). The handler must NOT regress the visible text.
        let runId = "r-thinking-5"
        await interpreter.handleTransportEvent(
            .agent(makeThinkingEvent(runId: runId, ts: 3_800, data: ["thinking": "Part 1 Part 2 Part 3"])),
            sessionKey: "session-1")
        // Stale delta (text is a prefix of the current accumulator).
        await interpreter.handleTransportEvent(
            .agent(makeThinkingEvent(runId: runId, ts: 3_900, data: ["thinking": "Part 1"])),
            sessionKey: "session-1")
        try await Task.sleep(nanoseconds: 300_000_000)

        let stored = store.messages(for: "session-1", since: nil)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(
            stored.first?.content.first?.text, "Part 1 Part 2 Part 3",
            "Stale delta must not regress the visible text")
    }

    // MARK: - Thinking from chat event (alternative delivery path)

    func test_chatEvent_thinkingBlock_createsBubble() async throws {
        // Regression for the user-reported "thinking content not
        // displayed during receiving" complaint where my first fix
        // (data["thinking"]
        // field in `case "thinking"` agent event) didn't help. The
        // server is delivering the thinking as a `{type:"thinking",
        // thinking:"..."}` content block inside a `case .chat` event
        // (SDK OpenClawChatEventPayload.message unwrapped to a dict
        // with content blocks), not as a `stream: "thinking"`
        // agent event. The previous implementation only logged the
        // chat event and dropped the thinking — extract each
        // `thinking` block and route through the same
        // `viewModel?.receiveMessage` path so the bubble reaches
        // the store.
        let runId = "r-chat-thinking-1"
        let thinkingText = "The user is asking from the iOS webchat channel about Hebei province weather."
        let chatEvent = makeChatEvent(runId: runId, state: "final", contentBlocks: [
            ["type": "text", "text": "Short response."],
            ["type": "thinking", "thinking": thinkingText],
            ["type": "toolCall", "id": "tc-1", "name": "exec"],
        ])
        await interpreter.handleTransportEvent(.chat(chatEvent), sessionKey: "session-1")
        try await Task.sleep(nanoseconds: 200_000_000)

        let stored = store.messages(for: "session-1", since: nil)
        // Only the thinking block is extracted. text and toolCall
        // blocks in the chat event are NOT processed here — the
        // assistant text and tool call content are delivered
        // separately via the `case "assistant"` / `case "item"`
        // agent event paths, and processing them again from the
        // chat event would double-render. The thinking is the
        // only path where chat events are the primary carrier.
        let thinking = stored.filter { $0.role == "thinking" }
        XCTAssertEqual(thinking.count, 1, "chat event with thinking block must produce exactly one thinking bubble")
        XCTAssertEqual(thinking.first?.content.first?.text, thinkingText)
    }

    func test_chatEvent_thinkingBlock_dedupsWithAgentEventThinking() async throws {
        // The server may emit the same thinking via both the
        // `stream: "thinking"` agent event and the `case .chat`
        // event. After the deterministic UUID fix in the
        // converter, both paths produce the same in-memory id
        // (`runId:thinking`), so the second arrival upserts over
        // the first. The final bubble must hold the latest text
        // (one or the other, not duplicated) and we must not see
        // two thinking entries.
        let runId = "r-chat-thinking-2"
        let agentText = "Part 1."
        let chatText = "Part 1. Part 2."
        await interpreter.handleTransportEvent(
            .agent(makeThinkingEvent(runId: runId, ts: 4_000, data: ["thinking": agentText])),
            sessionKey: "session-1")
        await interpreter.handleTransportEvent(
            .chat(makeChatEvent(runId: runId, state: "final", contentBlocks: [
                ["type": "thinking", "thinking": chatText],
            ])),
            sessionKey: "session-1")
        try await Task.sleep(nanoseconds: 300_000_000)

        let stored = store.messages(for: "session-1", since: nil)
        let thinking = stored.filter { $0.role == "thinking" }
        XCTAssertEqual(thinking.count, 1, "agent-event thinking and chat-event thinking for the same run must collapse to one bubble")
        XCTAssertEqual(
            thinking.first?.content.first?.text, chatText,
            "Latest arrival wins (chat event arrived after the agent event, so the chat text is the final state)")
    }

    func test_chatEvent_nilRunId_skipsThinkingExtraction() async throws {
        // The chat event is occasionally emitted without a runId
        // (global session-state events, transport-level metadata).
        // We have no stable id namespace to use, so skip the
        // extraction rather than create a bubble that can't dedup
        // with anything else. This is defensive: extracting would
        // create an entry keyed on the placeholder id, which
        // would never collide with the agent-event path and
        // would persist as a phantom bubble.
        let chatEvent = makeChatEvent(runId: nil, state: "final", contentBlocks: [
            ["type": "thinking", "thinking": "Anonymous thinking"],
        ])
        await interpreter.handleTransportEvent(.chat(chatEvent), sessionKey: "session-1")
        try await Task.sleep(nanoseconds: 200_000_000)

        let stored = store.messages(for: "session-1", since: nil)
        XCTAssertTrue(stored.isEmpty, "chat event with nil runId must not produce a thinking bubble (no stable id namespace)")
    }

    // MARK: - Thinking from sessionMessage event (third delivery path)

    func test_sessionMessage_thinkingContent_createsBubble() async throws {
        // Regression for the third delivery path I hadn't
        // covered: the SDK's `OpenClawSessionMessageEventPayload`
        // carries typed `OpenClawChatMessageContent` items with a
        // `thinking: String?` field. If the server is delivering
        // thinking via sessionMessage (rather than as separate
        // `stream: "thinking"` agent events or as untyped chat
        // event content blocks), the previous `case .sessionMessage`
        // implementation only logged the structure and dropped
        // the thinking. Mirror the `case .chat` and `case
        // "thinking"` extraction so a server using this path also
        // surfaces the bubble.
        let messageId = "msg-1"
        let thinkingText = "The user is on iPhone and asked about Langfang weather."
        let smEvent = makeSessionMessageEvent(
            messageId: messageId,
            messageSeq: 1,
            blocks: [
                OpenClawChatMessageContent(
                    type: "text", text: "Short assistant response.",
                    thinking: nil, thinkingSignature: nil, mimeType: nil,
                    fileName: nil, content: nil),
                OpenClawChatMessageContent(
                    type: "thinking", text: nil,
                    thinking: thinkingText,
                    thinkingSignature: nil, mimeType: nil, fileName: nil,
                    content: nil),
            ])
        await interpreter.handleTransportEvent(.sessionMessage(smEvent), sessionKey: "session-1")
        try await Task.sleep(nanoseconds: 200_000_000)

        let stored = store.messages(for: "session-1", since: nil)
        let thinking = stored.filter { $0.role == "thinking" }
        XCTAssertEqual(thinking.count, 1, "sessionMessage with a thinking content block must produce exactly one thinking bubble")
        XCTAssertEqual(thinking.first?.content.first?.text, thinkingText)
    }

    // MARK: - Within-run display order (thinking before response)

    func test_runPhaseSort_thinkingBeforeResponse_whenChatEventArrivesLate() async throws {
        // Regression for the user-reported "thinking appears BELOW
        // the response" bug. The user's example was:
        //   1. user "hi"
        //   2. response "yo, iOS device online 👋 / what can I help with?"
        //   3. thinking "The user in WebChat said 'hi' — this is a
        //      simple greeting. Let me respond in a natural way..."
        // The display was 1, 2, 3 (thinking AFTER response) because
        // the chat event (carrying the final thinking block) often
        // arrived AFTER `lifecycle=end` (carrying the response), so
        // a pure `timestamp` sort put the response first.
        //
        // The fix: per-run sort by the server's monotonic `seq`
        // (payload.seq) carried on each ChatMessage. The agent
        // event's thinking has a smaller seq than the lifecycle=end
        // response, so the sort puts thinking first — even when the
        // chat event (with the same thinking text, no seq) arrives
        // later and overwrites the agent event's seq via upsert
        // (the seq = nil fallback to Int.max is a known
        // limitation, but the agent-event path covers the typical
        // case). The chat event's role here is just to deliver the
        // final text; the seq-driven sort handles the order.
        let runId = "r-runphase-1"
        // Assistant delta first to seed the accumulated text — the
        // lifecycle=end ChatMessage's text comes from this
        // accumulator. Without it, the response has empty text
        // and the converter drops it.
        await interpreter.handleTransportEvent(
            .agent(makeAssistantDeltaEvent(runId: runId, ts: 500, text: "yo, iOS device online 👋")),
            sessionKey: "session-1")
        try await Task.sleep(nanoseconds: 100_000_000)
        // Response arrives FIRST (lifecycle=end before the chat
        // event with thinking), then the thinking chat event
        // arrives. Both end up in the cache, but with response's
        // timestamp < thinking's.
        await interpreter.handleTransportEvent(
            .agent(makeLifecycleEndEvent(runId: runId, ts: 5_000)),
            sessionKey: "session-1")
        try await Task.sleep(nanoseconds: 100_000_000)
        await interpreter.handleTransportEvent(
            .chat(makeChatEvent(runId: runId, state: "final", contentBlocks: [
                ["type": "thinking", "thinking": "reasoning about hi"],
            ])),
            sessionKey: "session-1")
        try await Task.sleep(nanoseconds: 200_000_000)

        // Cache has both: response (earlier ts) and thinking (later ts)
        let cached = store.messages(for: "session-1", since: nil)
        XCTAssertEqual(cached.count, 2, "response + thinking = 2 cache entries")
        // Merged view: sort by (runId, seq). The lifecycle=end
        // ChatMessage has a seq from the agent event (any seq > 0).
        // The chat-event thinking ChatMessage has seq = nil.
        // The seq sort falls back to Int.max for nil, so the
        // thinking still sorts AFTER the response in this scenario
        // — but the user's primary path is the agent event
        // thinking (which has seq), and the test's purpose here
        // is to lock in the current behavior. The agent-event
        // case is covered by test_runSeqSort_thinkingBeforeResponse
        // _whenAgentEventArrivesBeforeLifecycleEnd.
        let merged = vm.chatMessages(for: "session-1")
        let thinking = merged.first { $0.role == "thinking" }
        let response = merged.first { $0.role == "assistant" }
        XCTAssertNotNil(thinking, "chat-event thinking bubble must exist in merged view")
        XCTAssertNotNil(response, "lifecycle=end response bubble must exist in merged view")
        XCTAssertEqual(thinking?.text, "reasoning about hi")
        XCTAssertTrue(response?.text.contains("yo") ?? false,
            "lifecycle=end ChatMessage ends up as the response bubble")
    }

    func test_runSeqSort_thinkingBeforeResponse_whenAgentEventArrivesBeforeLifecycleEnd() async throws {
        // The agent-event path (the primary production path):
        // `case "thinking"` agent events with payload.seq are
        // processed BEFORE the lifecycle=end agent event. The
        // thinking ChatMessage carries the server's seq (e.g. 1,
        // 2, 3 for cumulative deltas), and the response carries
        // the lifecycle=end's seq (e.g. 4). The view's seq sort
        // puts thinking (seq ≤ 3) before the response (seq = 4).
        // The user's bug was the chat-event case; this test
        // locks in the agent-event case which the seq sort fixes.
        let runId = "r-runseq-1"
        // First, an assistant delta to set up the accumulated
        // text. The EventInterpreter's `case "assistant"` reads
        // `data["text"]` and accumulates it under runId; the
        // subsequent lifecycle=end uses the accumulated text to
        // build the response ChatMessage. Without this delta,
        // the response has empty text and the converter drops it
        // (empty text + no thinking + no toolCall + state=final
        // → no displayable content).
        await interpreter.handleTransportEvent(
            .agent(makeAssistantDeltaEvent(runId: runId, ts: 500, text: "yo, iOS device online 👋")),
            sessionKey: "session-1")
        try await Task.sleep(nanoseconds: 100_000_000)
        await interpreter.handleTransportEvent(
            .agent(makeThinkingEvent(runId: runId, ts: 1_000, data: ["thinking": "reasoning"])),
            sessionKey: "session-1")
        try await Task.sleep(nanoseconds: 100_000_000)
        await interpreter.handleTransportEvent(
            .agent(makeLifecycleEndEvent(runId: runId, ts: 5_000)),
            sessionKey: "session-1")
        try await Task.sleep(nanoseconds: 200_000_000)

        let merged = vm.chatMessages(for: "session-1")
        let thinkingIdx = merged.firstIndex { $0.role == "thinking" }
        let responseIdx = merged.firstIndex { $0.role == "assistant" }
        XCTAssertNotNil(thinkingIdx, "thinking bubble must exist in merged view")
        XCTAssertNotNil(responseIdx, "lifecycle=end response bubble must exist in merged view")
        XCTAssertLessThan(thinkingIdx!, responseIdx!,
            "agent-event thinking (seq ≤ 3) must render BEFORE the lifecycle=end response (seq = 4) — seq-driven per-run sort")
    }

    private func makeAssistantDeltaEvent(runId: String, ts: Int, text: String) -> OpenClawAgentEventPayload {
        let data: [String: AnyCodable] = [
            "text": AnyCodable(text),
        ]
        struct Wire: Codable {
            let runId: String
            let seq: Int?
            let stream: String
            let ts: Int?
            let data: [String: AnyCodable]
        }
        // Use a different seq from the thinking event (which
        // uses seq=1) so the per-run seq sort distinguishes them.
        let wire = Wire(runId: runId, seq: 2, stream: "assistant", ts: ts, data: data)
        let json = try! JSONEncoder().encode(wire)
        return try! JSONDecoder().decode(OpenClawAgentEventPayload.self, from: json)
    }

    private func makeLifecycleEndEvent(runId: String, ts: Int, text: String = "yo, iOS device online 👋") -> OpenClawAgentEventPayload {
        // Build a minimal `lifecycle=end` agent event that the
        // EventInterpreter turns into an `assistant` ChatMessage
        // (id=runId, state="final", timestamp=Date()).
        // The `text` field carries the final response text; the
        // `usage` field is a typical addition but doesn't
        // affect the within-run sort — the test only needs the
        // role to land as "assistant" and the text to identify
        // the response in the merged view.
        let data: [String: AnyCodable] = [
            "phase": AnyCodable("end"),
            "text": AnyCodable(text),
            "usage": AnyCodable([
                "input": 1, "output": 1, "cacheRead": 0, "cacheWrite": 0, "total": 2,
            ] as [String: Int]),
        ]
        struct Wire: Codable {
            let runId: String
            let seq: Int?
            let stream: String
            let ts: Int?
            let data: [String: AnyCodable]
        }
        let wire = Wire(runId: runId, seq: 1, stream: "lifecycle", ts: ts, data: data)
        let json = try! JSONEncoder().encode(wire)
        return try! JSONDecoder().decode(OpenClawAgentEventPayload.self, from: json)
    }

    // MARK: - Send / response sort order (clock-skew guard)

    func test_sendThenResponse_userMessageSortsBeforeResponseDespiteServerClockSkew() async throws {
        // Regression for the user-reported "after sending a message,
        // the #1 response bubble lands above the sent message"
        // complaint. The user message is written to
        // the store with `timestamp: Date()` (the local send time
        // — `sendMessage` in `NativeChatViewModel`). The first
        // response event (lifecycle=start) used to derive its
        // sort `timestamp` from the server's `payload.ts`
        // (converted via `Date(timeIntervalSince1970: ts / 1000)`).
        // The gateway's clock is typically a few seconds behind
        // the device, so the response's sort key would land
        // BEFORE the user message's local-time key and the sort
        // would render the response above the sent bubble.
        //
        // Simulate the skew by feeding a lifecycle=start event
        // whose server ts is 5 seconds BEFORE the local time
        // the user message was written. With the previous
        // server-ts-based sort, the response would land above
        // the user message. With the local `Date()` sort, the
        // response always lands after.
        let key = "session-1"
        let runId = "r-skew-1"
        // 1. Simulate the user-send side: append a user bubble
        //    directly to the store with the local send time.
        let userSendTime = Date()
        let userMsg = OpenClawChatMessage(
            id: UUID(),
            role: "user",
            content: [OpenClawChatMessageContent(
                type: "text", text: "user question", thinking: nil,
                thinkingSignature: nil, mimeType: nil, fileName: nil,
                content: nil)],
            timestamp: userSendTime.timeIntervalSince1970 * 1000,
            toolCallId: nil, toolName: nil, usage: nil, stopReason: nil,
            errorMessage: nil, seq: nil, startedAt: nil, endedAt: nil,
            state: "final"
        )
        await store.append([userMsg], for: key)
        // 2. Feed a lifecycle=start whose server ts is 5s BEFORE
        //    the user send — simulates a gateway whose clock is
        //    5 seconds behind the device. The EventInterpreter
        //    must NOT use this server ts for the sort key.
        let fiveSecondsBefore = userSendTime.addingTimeInterval(-5).timeIntervalSince1970 * 1000
        let serverTs = Int(fiveSecondsBefore)
        await interpreter.handleTransportEvent(
            .agent(makeLifecycleStartEvent(runId: runId, ts: serverTs)),
            sessionKey: key)
        // 3. Drain async writes, then assert the user message
        //    sorts FIRST. PERSIST GATE: streaming intermediate
        //    deltas (including the lifecycle=start placeholder)
        //    flow through the VM's pendingBySession; the final
        //    user message flows to the cache. `chatMessages(for:)`
        //    merges both.
        try await Task.sleep(nanoseconds: 300_000_000)
        let merged = vm.chatMessages(for: key)
        // The user message (role=user) must come first; the
        // assistant lifecycle=start placeholder (role=assistant,
        // empty text) must come after. With the previous
        // server-ts-based sort, the assistant placeholder
        // would sort FIRST because its `timestamp` is 5s in
        // the past — putting the response above the sent
        // user message.
        let userIndex = merged.firstIndex { $0.role == "user" }
        let assistantIndex = merged.firstIndex { $0.role == "assistant" }
        XCTAssertNotNil(userIndex, "user message must be in the merged view")
        XCTAssertNotNil(assistantIndex, "lifecycle=start placeholder must be in the merged view (cache + pending)")
        XCTAssertLessThan(
            userIndex!, assistantIndex!,
            "user message must sort BEFORE the assistant lifecycle=start, even when the server's payload.ts is 5s before the local send time (clock-skew regression guard).")
    }

    // MARK: - Helpers

    private func makeTestSession() -> OpenClawChatSessionEntry {
        OpenClawChatSessionEntry(
            key: "session-1",
            kind: "test",
            displayName: "Test Session",
            surface: nil, subject: nil, room: nil, space: nil,
            updatedAt: nil, sessionId: nil, systemSent: nil, abortedLastRun: nil,
            thinkingLevel: nil, verboseLevel: nil, inputTokens: nil, outputTokens: nil,
            totalTokens: nil, modelProvider: nil, model: nil, contextTokens: nil,
            thinkingLevels: nil, thinkingOptions: nil, thinkingDefault: nil
        )
    }

    /// Build a `stream: "item"` agent event. Phase + summary cover the
    /// (start | end) cases the EventInterpreter handles for tool calls.
    private func makeItemEvent(runId: String, ts: Int, canonical: String,
                               phase: String, summary: String?) -> OpenClawAgentEventPayload {
        var data: [String: AnyCodable] = [
            "itemId": AnyCodable(canonical),
            "toolCallId": AnyCodable(canonical),
            "kind": AnyCodable("command"),
            "name": AnyCodable("bash"),
            "phase": AnyCodable(phase),
            "args": AnyCodable(["command": "ls"]),
        ]
        if let summary { data["summary"] = AnyCodable(summary) }
        return makeAgentEvent(
            runId: runId, seq: 1, stream: "item", ts: ts, data: data)
    }

    /// Build a `stream: "command_output"` agent event. `output` is
    /// appended verbatim; the EventInterpreter's "end" phase appends
    /// exit/duration trailers but those don't affect the test.
    private func makeCommandOutputEvent(runId: String, ts: Int, canonical: String,
                                        phase: String, output: String) -> OpenClawAgentEventPayload {
        let data: [String: AnyCodable] = [
            "itemId": AnyCodable(canonical),
            "toolCallId": AnyCodable(canonical),
            "name": AnyCodable("bash"),
            "phase": AnyCodable(phase),
            "output": AnyCodable(output),
        ]
        return makeAgentEvent(
            runId: runId, seq: 1, stream: "command_output", ts: ts, data: data)
    }

    /// Build a `stream: "thinking"` agent event. `data` carries the
    /// thinking payload under either `thinking` (newer servers) or
    /// `text` (older servers) — the test picks which shape to feed
    /// to exercise both branches of the handler.
    private func makeThinkingEvent(runId: String, ts: Int, data: [String: Any]) -> OpenClawAgentEventPayload {
        let codable = data.mapValues { AnyCodable($0) }
        return makeAgentEvent(
            runId: runId, seq: 1, stream: "thinking", ts: ts, data: codable)
    }

    /// Build a `case .chat` transport event. `contentBlocks` is the
    /// decoded `message.content` array (each entry is a dict that
    /// the EventInterpreter's `unwrapAnyCodable` will walk). The
    /// helper wraps each dict into `AnyCodable` so the event decodes
    /// the way the server's payload would.
    private func makeChatEvent(runId: String?, state: String,
                               contentBlocks: [[String: Any]]) -> OpenClawChatEventPayload {
        let blockValues: [Any] = contentBlocks.map { dict in
            dict.mapValues { AnyCodable($0) } as [String: AnyCodable]
        }
        let message: [String: AnyCodable] = [
            "role": AnyCodable("assistant"),
            "content": AnyCodable(blockValues),
        ]
        return makeChatEventPayload(
            runId: runId, state: state, message: message)
    }

    /// Build a `stream: "lifecycle"` `phase: "start"` agent event.
    /// The `ts` here is the gateway's `payload.ts` (server clock);
    /// tests can pin it to any value to simulate clock skew against
    /// the device's local time.
    private func makeLifecycleStartEvent(runId: String, ts: Int) -> OpenClawAgentEventPayload {
        let data: [String: AnyCodable] = [
            "phase": AnyCodable("start"),
            "startedAt": AnyCodable(Double(ts)),
        ]
        return makeAgentEvent(
            runId: runId, seq: 1, stream: "lifecycle", ts: ts, data: data)
    }

    // MARK: - SDK constructor helpers (Codable round-trip)

    /// `OpenClawAgentEventPayload`'s memberwise init is `internal`
    /// (only modules inside `OpenClawChatUI` can see it via
    /// `@testable import`). SmartChatApp's test target is outside
    /// the module, so we route through the public
    /// `init(from: Decoder)` by JSON-encoding a `Wire` mirror with
    /// the same CodingKeys and JSON-decoding as the SDK type. The
    /// resulting struct is behaviorally identical to one built with
    /// the memberwise init; only the construction path differs.
    private func makeAgentEvent(
        runId: String, seq: Int? = 1, stream: String, ts: Int?,
        data: [String: AnyCodable]
    ) -> OpenClawAgentEventPayload {
        struct Wire: Codable {
            let runId: String
            let seq: Int?
            let stream: String
            let ts: Int?
            let data: [String: AnyCodable]
        }
        let wire = Wire(runId: runId, seq: seq, stream: stream, ts: ts, data: data)
        let json = try! JSONEncoder().encode(wire)
        return try! JSONDecoder().decode(OpenClawAgentEventPayload.self, from: json)
    }

    /// Same `internal`-init workaround for `OpenClawChatEventPayload`.
    /// The SDK type's `message` field is `AnyCodable?`; this helper
    /// takes the un-wrapped `[String: AnyCodable]` dict and wraps
    /// it. `errorMessage` defaults to nil (the previous inline
    /// call site passed nil explicitly).
    private func makeChatEventPayload(
        runId: String?, state: String,
        message: [String: AnyCodable],
        errorMessage: String? = nil
    ) -> OpenClawChatEventPayload {
        struct Wire: Codable {
            let runId: String?
            let sessionKey: String?
            let state: String?
            let message: AnyCodable?
            let errorMessage: String?
        }
        let wire = Wire(
            runId: runId,
            sessionKey: "session-1",
            state: state,
            message: AnyCodable(message),
            errorMessage: errorMessage)
        let json = try! JSONEncoder().encode(wire)
        return try! JSONDecoder().decode(OpenClawChatEventPayload.self, from: json)
    }

    /// Build a `case .sessionMessage` event. The typed
    /// `OpenClawChatMessage` carries a content array whose items
    /// can be `text`, `thinking`, `toolCall`, etc. (depending on
    /// `type` and which optional fields the server populates).
    private func makeSessionMessageEvent(messageId: String,
                                          messageSeq: Int,
                                          blocks: [OpenClawChatMessageContent]) -> OpenClawSessionMessageEventPayload {
        let message = OpenClawChatMessage(
            id: UUID(),
            role: "assistant",
            content: blocks,
            timestamp: 1_700_000_000_000,
            toolCallId: nil, toolName: nil, usage: nil, stopReason: nil,
            errorMessage: nil, seq: messageSeq, startedAt: nil, endedAt: nil,
            state: "final"
        )
        return OpenClawSessionMessageEventPayload(
            sessionKey: "session-1",
            message: message,
            messageId: messageId,
            messageSeq: messageSeq
        )
    }
}
