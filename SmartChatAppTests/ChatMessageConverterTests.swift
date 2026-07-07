import XCTest
@testable import SmartChatApp
@testable import OpenClawProtocol
import OpenClawChatUI

final class ChatMessageConverterTests: XCTestCase {

    // MARK: - toChatMessage

    func testToChatMessage_textOnly_returnsAssistantRole() {
        let content = [OpenClawChatMessageContent(
            type: "text", text: "hello", thinking: nil, thinkingSignature: nil,
            mimeType: nil, fileName: nil, content: nil)]
        let msg = OpenClawChatMessage(
            id: UUID(), role: "assistant", content: content,
            timestamp: 1_700_000_000_000, toolCallId: nil, toolName: nil,
            usage: nil, stopReason: nil, errorMessage: nil)
        let chats = ChatMessageConverter.toChatMessage(from: msg)
        XCTAssertEqual(chats.count, 1)
        XCTAssertEqual(chats[0].text, "hello")
        XCTAssertEqual(chats[0].role, "assistant")
        XCTAssertEqual(chats[0].id, msg.id.uuidString)
    }

    func testToChatMessage_emptyText_returnsOneBubble() {
        // Empty content (no text, no thinking) used to return an
        // empty array. After routing streaming bubbles through
        // the store (id-upsert via
        // MessageReceiver.receiveMessage), the
        // lifecycle=start placeholder arrives here with
        // text="" and no thinking — dropping it would make the
        // view's TypingIndicatorView never render during
        // streaming. Now we emit an empty-text bubble with
        // role=assistant so the placeholder is visible.
        let content = [OpenClawChatMessageContent(
            type: "text", text: "", thinking: nil, thinkingSignature: nil,
            mimeType: nil, fileName: nil, content: nil)]
        let msg = OpenClawChatMessage(
            id: UUID(), role: "assistant", content: content,
            timestamp: 0, toolCallId: nil, toolName: nil,
            usage: nil, stopReason: nil, errorMessage: nil)
        let chats = ChatMessageConverter.toChatMessage(from: msg)
        XCTAssertEqual(chats.count, 1, "empty text + no thinking → 1 placeholder bubble (was: empty array)")
        XCTAssertEqual(chats.first?.text, "")
        XCTAssertEqual(chats.first?.role, "assistant")
    }

    func testToChatMessage_thinkingOnly_roleIsThinking() {
        let content = [OpenClawChatMessageContent(
            type: "thinking", text: nil, thinking: "let me think",
            thinkingSignature: nil, mimeType: nil, fileName: nil, content: nil)]
        let msg = OpenClawChatMessage(
            id: UUID(), role: "assistant", content: content,
            timestamp: 0, toolCallId: nil, toolName: nil,
            usage: nil, stopReason: nil, errorMessage: nil)
        let chats = ChatMessageConverter.toChatMessage(from: msg)
        XCTAssertEqual(chats.count, 1)
        XCTAssertEqual(chats[0].role, "thinking")
        XCTAssertEqual(chats[0].text, "let me think")
    }

    func testToChatMessage_textAndThinkingBundle_emitsBoth() {
        // Regression for the user-reported "thinking not visible in
        // chat.history" complaint. The server sometimes returns
        // text + thinking in the same `content` array
        // (e.g., [{type:"text", text:"Hello"}, {type:"thinking",
        // thinking:"reasoning"}]). The previous converter's
        // "first text wins" rule took the text and dropped the
        // thinking, so the user saw the answer but not the
        // reasoning that led to it. The fix emits BOTH as
        // separate ChatMessages — the first text (role:assistant)
        // and a separate thinking entry (role:thinking) with a
        // deterministic id derived from the source message id.
        // The view renders each as its own bubble, preserving the
        // pre-existing display logic (ThinkingCardView for
        // role:"thinking").
        //
        // Updated (2026-07-06): the user reported the order
        // `[text, thinking]` showed the response ABOVE its
        // reasoning, which is the opposite of the natural
        // reasoning-then-response flow. The new heuristic emits
        // the thinking block FIRST when the message has both
        // a sibling thinking block AND a non-thinking main
        // entry (text body or toolCall), regardless of the
        // content-block order on the wire.
        let content: [OpenClawChatMessageContent] = [
            OpenClawChatMessageContent(
                type: "text", text: "Hello!", thinking: nil,
                thinkingSignature: nil, mimeType: nil, fileName: nil, content: nil),
            OpenClawChatMessageContent(
                type: "thinking", text: nil, thinking: "reasoning",
                thinkingSignature: nil, mimeType: nil, fileName: nil, content: nil),
        ]
        let msg = OpenClawChatMessage(
            id: UUID(), role: "assistant", content: content,
            timestamp: 0, toolCallId: nil, toolName: nil,
            usage: nil, stopReason: nil, errorMessage: nil)
        let chats = ChatMessageConverter.toChatMessage(from: msg)
        XCTAssertEqual(chats.count, 2, "[text, thinking] bundle must emit both as separate ChatMessages")
        XCTAssertEqual(chats[0].role, "thinking", "thinking emits FIRST when assistant has a sibling thinking block")
        XCTAssertEqual(chats[0].text, "reasoning")
        XCTAssertEqual(chats[1].role, "assistant", "text response follows the thinking")
        XCTAssertEqual(chats[1].text, "Hello!")
    }

    func testToChatMessage_thinkingThenText_emitThinkingFirst() {
        // Companion to `testToChatMessage_textAndThinkingBundle_emitsBoth`:
        // the server's `chat.history` also returns the
        // mirror order [{type:"thinking", thinking:"..."},
        // {type:"text", text:"..."}] when the model produced
        // reasoning BEFORE its response in the same assistant
        // turn (server preserves content order). The previous
        // converter's "first text wins, then thinking" rule
        // inverted this and rendered the response ABOVE its
        // reasoning, so a user reading the bubble saw the
        // answer first and only then the rationale — a
        // long-standing "why did the model answer this?" mystery.
        // The new rule detects `content[0]` is a thinking
        // block and emits the thinking bubbles first.
        let content: [OpenClawChatMessageContent] = [
            OpenClawChatMessageContent(
                type: "thinking", text: nil, thinking: "reasoning",
                thinkingSignature: nil, mimeType: nil, fileName: nil, content: nil),
            OpenClawChatMessageContent(
                type: "text", text: "Hello!", thinking: nil,
                thinkingSignature: nil, mimeType: nil, fileName: nil, content: nil),
        ]
        let msg = OpenClawChatMessage(
            id: UUID(), role: "assistant", content: content,
            timestamp: 0, toolCallId: nil, toolName: nil,
            usage: nil, stopReason: nil, errorMessage: nil)
        let chats = ChatMessageConverter.toChatMessage(from: msg)
        XCTAssertEqual(chats.count, 2, "[thinking, text] bundle must emit both as separate ChatMessages")
        XCTAssertEqual(chats[0].role, "thinking", "first entry is the reasoning (content[0])")
        XCTAssertEqual(chats[0].text, "reasoning")
        XCTAssertEqual(chats[1].role, "assistant", "second entry is the text response (content[1])")
        XCTAssertEqual(chats[1].text, "Hello!")
    }

    func testToChatMessage_toolCallOnly_roleIsToolCall() {
        let content = [OpenClawChatMessageContent(
            type: "toolCall", text: nil, thinking: nil, thinkingSignature: nil,
            mimeType: nil, fileName: nil, content: nil,
            id: "tc-1", name: "read_file", arguments: AnyCodable(["path": "x.txt"]))]
        let msg = OpenClawChatMessage(
            id: UUID(), role: "tool", content: content,
            timestamp: 0, toolCallId: "tc-1", toolName: "read_file",
            usage: nil, stopReason: nil, errorMessage: nil)
        let chats = ChatMessageConverter.toChatMessage(from: msg)
        XCTAssertEqual(chats.count, 1)
        XCTAssertEqual(chats[0].role, "toolCall")
        XCTAssertTrue(chats[0].text.contains("read_file"))
    }

    func testToChatMessage_serverRoleVariants_normalizeToCanonical() {
        // Regression for the user-reported "TOOLCALL not showing
        // even with showToolCalls on" bug. The server's
        // chat.history projection emits tool messages with
        // lowercase / underscored role names ("tool",
        // "function", "toolresult", "tool_result",
        // "toolcall", "tool_call"). The client's view filter
        // and bubble rendering branches both check for
        // camelCase ("toolCall" / "toolResult"). Without
        // normalization, server-returned tool messages pass the
        // view filter (since "tool" ≠ "toolCall") but then
        // render as plain text bubbles (the role-specific
        // branches never fire) — the user sees the tool's
        // content as a text bubble, not a labeled "ToolCall"
        // bubble. The fix normalizes the role on read.
        let variants: [(input: String, expected: String)] = [
            ("tool", "toolCall"),
            ("function", "toolCall"),
            ("toolcall", "toolCall"),
            ("tool_call", "toolCall"),
            ("tooluse", "toolCall"),
            ("tool_use", "toolCall"),
            ("ToolCall", "toolCall"),
            ("TOOLCALL", "toolCall"),
            ("toolresult", "toolResult"),
            ("tool_result", "toolResult"),
            ("ToolResult", "toolResult"),
            ("assistant", "assistant"),
            ("user", "user"),
        ]
        for (input, expected) in variants {
            let msg = OpenClawChatMessage(
                id: UUID(), role: input,
                content: [OpenClawChatMessageContent(
                    type: "text", text: "x", thinking: nil,
                    thinkingSignature: nil, mimeType: nil, fileName: nil,
                    content: nil)],
                timestamp: 0, toolCallId: nil, toolName: nil,
                usage: nil, stopReason: nil, errorMessage: nil)
            let chats = ChatMessageConverter.toChatMessage(from: msg)
            XCTAssertEqual(chats.count, 1, "input role=\(input) should produce one chat message")
            XCTAssertEqual(chats[0].role, expected, "input role=\(input) must normalize to \(expected)")
        }
    }

    func testToOpenClawChatMessage_toolRoleInput_normalizesOnWrite() {
        // The cache writer must also normalize, so the dedupKey
        // (which keys on `message.role`) treats streaming
        // toolCall messages and history toolCall messages as
        // duplicates of each other. Without this, a server-
        // returned toolCall with role "tool" lands in the
        // cache alongside a streaming toolCall with role
        // "toolCall" — two bubbles for the same logical call.
        let chat = ChatMessage(
            id: UUID().uuidString, text: "x",
            timestamp: Date(timeIntervalSince1970: 0), role: "tool",
            state: "final", runId: nil, seq: nil,
            startedAt: nil, endedAt: nil, livenessState: nil,
            toolCallId: nil, toolName: nil, stopReason: nil, isFresh: true)
        let msg = ChatMessageConverter.toOpenClawChatMessage(from: chat)
        XCTAssertEqual(msg?.role, "toolCall", "writer normalizes lowercase 'tool' to camelCase 'toolCall'")
    }

    // MARK: - toOpenClawChatMessage

    func testToOpenClawChatMessage_validUuid_returnsMessage() {
        let chat = ChatMessage(
            id: "11111111-2222-3333-4444-555555555555",
            text: "hi", timestamp: Date(timeIntervalSince1970: 1700),
            role: "user", state: "final", runId: nil, seq: nil,
            startedAt: nil, endedAt: nil, livenessState: nil,
            toolCallId: nil, toolName: nil, stopReason: nil, isFresh: true)
        let msg = ChatMessageConverter.toOpenClawChatMessage(from: chat)
        XCTAssertEqual(msg?.role, "user")
        XCTAssertEqual(msg?.content.first?.text, "hi")
        XCTAssertEqual(msg?.timestamp, 1_700_000)  // ms (1700 sec * 1000)
    }

    func testToOpenClawChatMessage_invalidUuid_synthesizesUUID() {
        let chat = ChatMessage(
            id: "not-a-uuid", text: "x", timestamp: Date(),
            role: "user", state: "final", runId: nil, seq: nil,
            startedAt: nil, endedAt: nil, livenessState: nil,
            toolCallId: nil, toolName: nil, stopReason: nil, isFresh: true)
        let msg = ChatMessageConverter.toOpenClawChatMessage(from: chat)
        XCTAssertNotNil(msg, "invalid-UUID fallback: should synthesize a new UUID, not return nil")
        XCTAssertNotEqual(msg?.id.uuidString, "not-a-uuid")
        XCTAssertNotNil(UUID(uuidString: msg?.id.uuidString ?? ""), "synthesized id must be a valid UUID")
    }

    // MARK: - toOpenClawChatMessage (synthetic-id fallback)

    func testToOpenClawChatMessage_syntheticId_synthesizesUUID() {
        let syntheticId = "ABC123:tool:def-456"  // legacy streaming-time synthetic id
        let chat = ChatMessage(
            id: syntheticId, text: "hello", timestamp: Date(),
            role: "toolCall", state: "streaming", runId: nil, seq: nil,
            startedAt: nil, endedAt: nil, livenessState: nil,
            inputTokens: nil, outputTokens: nil, cacheRead: nil, cacheWrite: nil,
            toolCallId: "def-456", toolName: "search", stopReason: nil,
            isFresh: true)
        let openclaw = ChatMessageConverter.toOpenClawChatMessage(from: chat)
        XCTAssertNotNil(openclaw, "synthetic-id fallback: should not return nil")
        XCTAssertNotEqual(openclaw?.id.uuidString, syntheticId)
        XCTAssertNotNil(UUID(uuidString: openclaw?.id.uuidString ?? ""), "generated id must be a valid UUID")
    }

    // MARK: - Deterministic UUID (streaming dedup relies on this)

    func testToOpenClawChatMessage_syntheticId_isDeterministic() {
        // Same synthetic id called twice with different text/state must
        // produce the same UUID. This is what `MessageCacheStorage.upsert`
        // keys on to replace streaming deltas in place — a fresh UUID per
        // call would silently degrade upsert to append, accumulating one
        // duplicate entry per delta (and never replacing the
        // `lifecycle=start` typing-indicator placeholder). Regression for
        // the bug introduced in abaf95c (`UUID(uuidString: ...) ?? UUID()`
        // generated a fresh UUID per call).
        let id = "run-abc-123:toolCall:def-456"
        let chat1 = ChatMessage(
            id: id, text: "ha", timestamp: Date(),
            role: "toolCall", state: "streaming", runId: nil, seq: nil,
            startedAt: nil, endedAt: nil, livenessState: nil,
            inputTokens: nil, outputTokens: nil, cacheRead: nil, cacheWrite: nil,
            toolCallId: "def-456", toolName: "search", stopReason: nil,
            isFresh: true)
        let chat2 = ChatMessage(
            id: id, text: "hello there", timestamp: Date(),
            role: "toolCall", state: "final", runId: nil, seq: nil,
            startedAt: nil, endedAt: nil, livenessState: nil,
            inputTokens: nil, outputTokens: nil, cacheRead: nil, cacheWrite: nil,
            toolCallId: "def-456", toolName: "search", stopReason: nil,
            isFresh: true)
        let msg1 = ChatMessageConverter.toOpenClawChatMessage(from: chat1)
        let msg2 = ChatMessageConverter.toOpenClawChatMessage(from: chat2)
        XCTAssertNotNil(msg1)
        XCTAssertNotNil(msg2)
        XCTAssertEqual(
            msg1?.id, msg2?.id,
            "Same synthetic input id must map to the same UUID (id-based upsert depends on this stability)")
    }

    func testToOpenClawChatMessage_differentSyntheticIds_produceDifferentUUIDs() {
        // The deterministic UUID derivation must be injective on its
        // input space for any realistic ids, otherwise unrelated
        // streaming bubbles would collapse to a single entry (e.g.
        // two different tool calls in the same run sharing an id by
        // accident). SHA256 collisions in the first 16 bytes are
        // cryptographically negligible; this test just guards the
        // trivial case where two distinct inputs of similar length
        // don't collide.
        let chat1 = ChatMessage(
            id: "run-1:toolCall:a", text: "x", timestamp: Date(),
            role: "toolCall", state: "streaming", runId: nil, seq: nil,
            startedAt: nil, endedAt: nil, livenessState: nil,
            inputTokens: nil, outputTokens: nil, cacheRead: nil, cacheWrite: nil,
            toolCallId: "a", toolName: "search", stopReason: nil,
            isFresh: true)
        let chat2 = ChatMessage(
            id: "run-1:toolCall:b", text: "y", timestamp: Date(),
            role: "toolCall", state: "streaming", runId: nil, seq: nil,
            startedAt: nil, endedAt: nil, livenessState: nil,
            inputTokens: nil, outputTokens: nil, cacheRead: nil, cacheWrite: nil,
            toolCallId: "b", toolName: "search", stopReason: nil,
            isFresh: true)
        let msg1 = ChatMessageConverter.toOpenClawChatMessage(from: chat1)
        let msg2 = ChatMessageConverter.toOpenClawChatMessage(from: chat2)
        XCTAssertNotEqual(
            msg1?.id, msg2?.id,
            "Distinct synthetic ids must produce distinct UUIDs (otherwise different tool calls would collide into one entry)")
    }

    func testToOpenClawChatMessage_runId_placeholder_collidesWithAssistantDeltas() {
        // The streaming `lifecycle=start` placeholder, every assistant
        // delta, and the `lifecycle=end` final message all share the
        // same `id: runId` in `EventInterpreter`. After the fix all
        // three must round-trip to the same UUID, so the in-memory
        // upsert collapses them to one entry. This test reproduces
        // the exact shape of the user-reported "two identical
        // messages" / "typing indicator won't disappear" bug at
        // the converter level.
        let runId = "f1e2d3c4-b5a6-7890-1234-56789abcdef0"  // not a UUID
        let placeholder = ChatMessage(
            id: runId, text: "", timestamp: Date(),
            role: "assistant", state: "streaming", runId: runId, seq: 7,
            startedAt: nil, endedAt: nil, livenessState: "working",
            toolCallId: nil, toolName: nil, stopReason: nil, isFresh: true)
        let delta1 = ChatMessage(
            id: runId, text: "ha", timestamp: Date(),
            role: "assistant", state: "streaming", runId: runId, seq: 7,
            startedAt: nil, endedAt: nil, livenessState: "working",
            toolCallId: nil, toolName: nil, stopReason: nil, isFresh: true)
        let delta2 = ChatMessage(
            id: runId, text: "hello there", timestamp: Date(),
            role: "assistant", state: "final", runId: runId, seq: 7,
            startedAt: nil, endedAt: nil, livenessState: nil,
            toolCallId: nil, toolName: nil, stopReason: nil, isFresh: true)
        let u1 = ChatMessageConverter.toOpenClawChatMessage(from: placeholder)?.id
        let u2 = ChatMessageConverter.toOpenClawChatMessage(from: delta1)?.id
        let u3 = ChatMessageConverter.toOpenClawChatMessage(from: delta2)?.id
        XCTAssertNotNil(u1)
        XCTAssertNotNil(u2)
        XCTAssertNotNil(u3)
        XCTAssertEqual(u1, u2, "lifecycle=start placeholder and assistant delta 1 must share a UUID (so delta replaces placeholder)")
        XCTAssertEqual(u2, u3, "All assistant deltas + lifecycle=end must share a UUID (so they collapse to one bubble)")
    }

    func testToOpenClawChatMessage_validUUIDId_preservesIt() {
        let validId = UUID().uuidString
        let chat = ChatMessage(
            id: validId, text: "hello", timestamp: Date(),
            role: "user", state: "final", runId: nil, seq: nil,
            startedAt: nil, endedAt: nil, livenessState: nil,
            inputTokens: nil, outputTokens: nil, cacheRead: nil, cacheWrite: nil,
            toolCallId: nil, toolName: nil, stopReason: nil, isFresh: true)
        let openclaw = ChatMessageConverter.toOpenClawChatMessage(from: chat)
        XCTAssertEqual(openclaw?.id.uuidString, validId)
    }

    // MARK: - SDK shape: streaming metadata is NOT preserved through round-trip

    func testToOpenClawChatMessage_dropsSeqStartedAtEndedAtAndState() {
        // The SDK's `OpenClawChatMessage` does not carry `seq` /
        // `startedAt` / `endedAt` / `state` — only the historical
        // content + usage fields. Streaming metadata is owned by
        // `EventInterpreter` / `MessageReceiver` for the lifetime
        // of an in-flight run and routed to `pendingBySession`
        // (in-memory, gated out of the cache by the persist gate);
        // cached `OpenClawChatMessage`s are always `state: "final"`.
        // This test documents the drop so a future reader doesn't
        // re-add the round-trip and reintroduce the old build
        // errors.
        let started = Date(timeIntervalSince1970: 1_700_000_001)
        let ended = Date(timeIntervalSince1970: 1_700_000_005)
        let chat = ChatMessage(
            id: UUID().uuidString, text: "answer", timestamp: ended,
            role: "assistant", state: "streaming", runId: "r-1", seq: 7,
            startedAt: started, endedAt: ended, livenessState: nil,
            inputTokens: 10, outputTokens: 20, cacheRead: 3, cacheWrite: 1,
            toolCallId: nil, toolName: nil, stopReason: nil, isFresh: true)
        let openclaw = ChatMessageConverter.toOpenClawChatMessage(from: chat)
        XCTAssertNotNil(openclaw, "round-trip should still produce a valid OpenClawChatMessage")
        // Content + usage + role + timestamp + id survive; streaming
        // metadata does not (no SDK field to carry it). Text lives
        // in `content[0].text` (the converter's `[OpenClawChatMessageContent(
        // type: "text", text: chatMessage.text, ...)]` writer).
        XCTAssertEqual(openclaw?.content.first?.text, "answer")
        XCTAssertEqual(openclaw?.usage?.input, 10)
        XCTAssertEqual(openclaw?.usage?.output, 20)
        XCTAssertEqual(openclaw?.role, "assistant")
    }

    func testToChatMessage_oldPayloadWithoutMetadata_decodesNil() {
        // Backward compat: payloads from the server's `chat.history`
        // response never set streaming metadata. The reader defaults
        // every field to nil and the state to "final", so the
        // view sees a clean historical message.
        let openclaw = OpenClawChatMessage(
            id: UUID(), role: "assistant",
            content: [OpenClawChatMessageContent(
                type: "text", text: "answer", thinking: nil, thinkingSignature: nil,
                mimeType: nil, fileName: nil, content: nil)],
            timestamp: 1_700_000_000_000, toolCallId: nil, toolName: nil,
            usage: nil, stopReason: nil, errorMessage: nil)
        let chats = ChatMessageConverter.toChatMessage(from: openclaw)
        XCTAssertEqual(chats.count, 1)
        XCTAssertNil(chats[0].seq)
        XCTAssertNil(chats[0].startedAt)
        XCTAssertNil(chats[0].endedAt)
        XCTAssertEqual(chats[0].state, "final",
                       "reader always defaults state to 'final' for history messages — streaming state is owned by EventInterpreter")
    }

    func testToChatMessage_emptyText_keepsPlaceholder() {
        // Empty text + no thinking previously dropped the bubble
        // entirely. After routing streaming bubbles through the
        // store (id-upsert via MessageReceiver.receiveMessage),
        // the lifecycle=start placeholder arrives here with
        // text="" and no thinking — dropping it would make the
        // view's TypingIndicatorView never render during
        // streaming. Now we emit an empty-text bubble with
        // role=assistant so the placeholder is visible. The
        // view's `if message.text.isEmpty` branch renders an
        // empty bubble that marks the streaming position.
        let openclaw = OpenClawChatMessage(
            id: UUID(), role: "assistant",
            content: [OpenClawChatMessageContent(
                type: "text", text: "", thinking: nil, thinkingSignature: nil,
                mimeType: nil, fileName: nil, content: nil)],
            timestamp: 1_700_000_000_000, toolCallId: nil, toolName: nil,
            usage: nil, stopReason: nil, errorMessage: nil)
        let chats = ChatMessageConverter.toChatMessage(from: openclaw)
        XCTAssertEqual(chats.count, 1, "empty text + no thinking → 1 placeholder bubble (was: dropped)")
        XCTAssertEqual(chats.first?.text, "")
        XCTAssertEqual(chats.first?.role, "assistant")
    }

    // MARK: - Schema symmetry: streaming write ↔ history read

    func testToOpenClawChatMessage_thinkingRole_writesToThinkingField() {
        // Regression for the user-reported "history[25].content[0]
        // (thinking) not displayed" bug. The streaming write path
        // used to emit `type:"text", text:"<thinking>", thinking:nil`
        // for every ChatMessage regardless of role, so a streaming
        // thinking bubble and a server-returned thinking block had
        // different shapes in the cache. `MessageCacheStorage.dedupKey`
        // hashes text+role+tsBucket — both produced the same hash
        // (because text is the thinking string in the streaming copy
        // and the thinking fallback in the read path also surfaces
        // that string), so the streaming copy was KEEP'd and the
        // server's properly-shaped copy was DROP'd. `toChatMessage`
        // then read the streaming copy as `type:"text", text:"..."`,
        // not a thinking block — no thinking bubble rendered.
        //
        // The fix routes role=="thinking" through
        // `contentItem(for:)` which writes `type:"thinking",
        // thinking:"<text>", text:nil`, matching the server's
        // `chat.history` projection. Now both paths share the same
        // content shape and the KEEP-on-dedup decision doesn't
        // silently swap schema.
        let chat = ChatMessage(
            id: UUID().uuidString, text: "let me think",
            timestamp: Date(timeIntervalSince1970: 1700),
            role: "thinking", state: "final", runId: "r-1", seq: 3,
            startedAt: nil, endedAt: nil, livenessState: nil,
            inputTokens: nil, outputTokens: nil, cacheRead: nil, cacheWrite: nil,
            toolCallId: nil, toolName: nil, stopReason: nil, isFresh: true)
        let openclaw = ChatMessageConverter.toOpenClawChatMessage(from: chat)
        XCTAssertNotNil(openclaw)
        XCTAssertEqual(openclaw?.content.count, 1)
        XCTAssertEqual(openclaw?.content.first?.type, "thinking",
                       "streaming thinking bubble must write type=\"thinking\" to match server schema")
        XCTAssertEqual(openclaw?.content.first?.thinking, "let me think",
                       "thinking bubble content lives in the `thinking` field, not `text`")
        XCTAssertNil(openclaw?.content.first?.text,
                     "thinking bubble must NOT write the content into `text` — that's the assistant/user schema")
    }

    func testToOpenClawChatMessage_assistantRole_keepsTextSchema() {
        // Companion to the above: the assistant/user schema stays
        // `type:"text", text:"<chatMessage.text>"`. The split on
        // role=="thinking" must not regress non-thinking writes.
        let chat = ChatMessage(
            id: UUID().uuidString, text: "the answer",
            timestamp: Date(timeIntervalSince1970: 1700),
            role: "assistant", state: "final", runId: "r-1", seq: 4,
            startedAt: nil, endedAt: nil, livenessState: nil,
            inputTokens: nil, outputTokens: nil, cacheRead: nil, cacheWrite: nil,
            toolCallId: nil, toolName: nil, stopReason: nil, isFresh: true)
        let openclaw = ChatMessageConverter.toOpenClawChatMessage(from: chat)
        XCTAssertEqual(openclaw?.content.first?.type, "text")
        XCTAssertEqual(openclaw?.content.first?.text, "the answer")
        XCTAssertNil(openclaw?.content.first?.thinking)
    }

    func testToChatMessage_streamingThinkingRoundTrip_emitsThinkingBubble() {
        // End-to-end: a streaming thinking bubble written by
        // `toOpenClawChatMessage` must round-trip back through
        // `toChatMessage` as a thinking bubble. Before the fix,
        // the streaming copy went into the cache with
        // `type:"text"` and `text:"<thinking content>"`, so
        // `toChatMessage` produced an assistant-role bubble with
        // the thinking string as its text — no ThinkingCardView
        // was rendered. After the fix, the streaming copy lands
        // in the cache as `type:"thinking", thinking:"<content>"`
        // (matching the server), and `toChatMessage`'s
        // first-non-empty-thinking scan (line 73-80) produces a
        // thinking ChatMessage just like it does for server-
        // returned thinking blocks.
        let streamed = ChatMessage(
            id: UUID().uuidString, text: "reasoning content",
            timestamp: Date(timeIntervalSince1970: 1700),
            role: "thinking", state: "final", runId: "r-1", seq: 3,
            startedAt: nil, endedAt: nil, livenessState: nil,
            inputTokens: nil, outputTokens: nil, cacheRead: nil, cacheWrite: nil,
            toolCallId: nil, toolName: nil, stopReason: nil, isFresh: true)
        guard let persisted = ChatMessageConverter.toOpenClawChatMessage(from: streamed) else {
            XCTFail("toOpenClawChatMessage returned nil")
            return
        }
        let chats = ChatMessageConverter.toChatMessage(from: persisted)
        XCTAssertEqual(chats.count, 1, "streaming thinking round-trips to 1 thinking bubble")
        XCTAssertEqual(chats[0].role, "thinking",
                       "round-trip must surface the thinking bubble, not an assistant bubble with the thinking string as text")
        XCTAssertEqual(chats[0].text, "reasoning content")
    }
}
