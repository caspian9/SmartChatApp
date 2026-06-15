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
        let chat = ChatMessageConverter.toChatMessage(from: msg)
        XCTAssertEqual(chat?.text, "hello")
        XCTAssertEqual(chat?.role, "assistant")
        XCTAssertEqual(chat?.id, msg.id.uuidString)
    }

    func testToChatMessage_emptyText_returnsNil() {
        let content = [OpenClawChatMessageContent(
            type: "text", text: "", thinking: nil, thinkingSignature: nil,
            mimeType: nil, fileName: nil, content: nil)]
        let msg = OpenClawChatMessage(
            id: UUID(), role: "assistant", content: content,
            timestamp: 0, toolCallId: nil, toolName: nil,
            usage: nil, stopReason: nil, errorMessage: nil)
        XCTAssertNil(ChatMessageConverter.toChatMessage(from: msg))
    }

    func testToChatMessage_thinkingOnly_roleIsThinking() {
        let content = [OpenClawChatMessageContent(
            type: "thinking", text: nil, thinking: "let me think",
            thinkingSignature: nil, mimeType: nil, fileName: nil, content: nil)]
        let msg = OpenClawChatMessage(
            id: UUID(), role: "assistant", content: content,
            timestamp: 0, toolCallId: nil, toolName: nil,
            usage: nil, stopReason: nil, errorMessage: nil)
        let chat = ChatMessageConverter.toChatMessage(from: msg)
        XCTAssertEqual(chat?.role, "thinking")
        XCTAssertEqual(chat?.text, "let me think")
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
        let chat = ChatMessageConverter.toChatMessage(from: msg)
        XCTAssertEqual(chat?.role, "toolCall")
        XCTAssertTrue(chat?.text.contains("read_file") ?? false)
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

    // MARK: - seq / startedAt / endedAt round-trip

    func testToOpenClawChatMessage_preservesSeqStartedAtEndedAt() {
        // The view shows #N / started-at / ended-at labels from these
        // three fields. The refactor moved ChatMessage through an
        // OpenClawChatMessage round trip (the cache layer), which
        // must NOT silently drop them. Regression test for the
        // "seq/start/end all gone" report.
        let started = Date(timeIntervalSince1970: 1_700_000_001)
        let ended = Date(timeIntervalSince1970: 1_700_000_005)
        let chat = ChatMessage(
            id: UUID().uuidString, text: "answer", timestamp: ended,
            role: "assistant", state: "final", runId: "r-1", seq: 7,
            startedAt: started, endedAt: ended, livenessState: nil,
            inputTokens: 10, outputTokens: 20, cacheRead: 3, cacheWrite: 1,
            toolCallId: nil, toolName: nil, stopReason: nil, isFresh: true)
        let openclaw = ChatMessageConverter.toOpenClawChatMessage(from: chat)
        XCTAssertEqual(openclaw?.seq, 7)
        // Date → epoch ms (matches `timestamp`'s convention).
        XCTAssertEqual(openclaw?.startedAt, started.timeIntervalSince1970 * 1000)
        XCTAssertEqual(openclaw?.endedAt, ended.timeIntervalSince1970 * 1000)
    }

    func testToChatMessage_extractsSeqStartedAtEndedAt() {
        // Reverse direction: OpenClawChatMessage from the store
        // must surface the metadata on the ChatMessage the view
        // reads. Verifies the new SDK fields actually flow through.
        let startedMs: Double = 1_700_000_001_000
        let endedMs: Double = 1_700_000_005_000
        let openclaw = OpenClawChatMessage(
            id: UUID(), role: "assistant",
            content: [OpenClawChatMessageContent(
                type: "text", text: "answer", thinking: nil, thinkingSignature: nil,
                mimeType: nil, fileName: nil, content: nil)],
            timestamp: endedMs, toolCallId: nil, toolName: nil,
            usage: nil, stopReason: nil, errorMessage: nil,
            seq: 7, startedAt: startedMs, endedAt: endedMs)
        let chat = ChatMessageConverter.toChatMessage(from: openclaw)
        XCTAssertEqual(chat?.seq, 7)
        // Epoch ms → Date, matching how `timestamp` is unwrapped.
        // `XCTUnwrap` is required because `chat` itself is optional
        // and `startedAt` is optional — `?.timeIntervalSince1970`
        // would still be `Double?` and XCTAssertEqual(accuracy:)
        // needs a non-optional Double.
        guard let chat,
              let startedDate = chat.startedAt,
              let endedDate = chat.endedAt else {
            XCTFail("expected chat with non-nil startedAt/endedAt")
            return
        }
        XCTAssertEqual(startedDate.timeIntervalSince1970, startedMs / 1000, accuracy: 0.001)
        XCTAssertEqual(endedDate.timeIntervalSince1970, endedMs / 1000, accuracy: 0.001)
    }

    func testToChatMessage_oldPayloadWithoutMetadata_decodesNil() {
        // Backward compat: payloads encoded before the SDK had
        // these fields (or from the server's chat.history response,
        // which never sets them) must decode with nil metadata —
        // the view falls back to omitting the #N / time labels.
        let openclaw = OpenClawChatMessage(
            id: UUID(), role: "assistant",
            content: [OpenClawChatMessageContent(
                type: "text", text: "answer", thinking: nil, thinkingSignature: nil,
                mimeType: nil, fileName: nil, content: nil)],
            timestamp: 1_700_000_000_000, toolCallId: nil, toolName: nil,
            usage: nil, stopReason: nil, errorMessage: nil)
        let chat = ChatMessageConverter.toChatMessage(from: openclaw)
        XCTAssertNil(chat?.seq)
        XCTAssertNil(chat?.startedAt)
        XCTAssertNil(chat?.endedAt)
    }

    func testToChatMessage_emptyTextStreaming_keepsPlaceholder() {
        // Regression test for "no typing indicator on receive start":
        // the EventInterpreter's `lifecycle=start` placeholder has
        // `text=""` and `state="streaming"`. The converter must
        // NOT drop this entry — the view's TypingIndicatorView
        // depends on the bubble existing in the messages array.
        let openclaw = OpenClawChatMessage(
            id: UUID(), role: "assistant",
            content: [OpenClawChatMessageContent(
                type: "text", text: "", thinking: nil, thinkingSignature: nil,
                mimeType: nil, fileName: nil, content: nil)],
            timestamp: 1_700_000_000_000, toolCallId: nil, toolName: nil,
            usage: nil, stopReason: nil, errorMessage: nil,
            seq: nil, startedAt: nil, endedAt: nil, state: "streaming")
        let chat = ChatMessageConverter.toChatMessage(from: openclaw)
        XCTAssertNotNil(chat, "empty-text streaming placeholder must survive converter (it drives the typing indicator)")
        XCTAssertEqual(chat?.text, "")
        XCTAssertEqual(chat?.state, "streaming")
    }

    func testToChatMessage_emptyTextFinal_isDropped() {
        // The opposite case: a server message with no content and
        // no streaming marker should still be dropped, so the view
        // doesn't render a phantom empty bubble for it.
        let openclaw = OpenClawChatMessage(
            id: UUID(), role: "assistant",
            content: [OpenClawChatMessageContent(
                type: "text", text: "", thinking: nil, thinkingSignature: nil,
                mimeType: nil, fileName: nil, content: nil)],
            timestamp: 1_700_000_000_000, toolCallId: nil, toolName: nil,
            usage: nil, stopReason: nil, errorMessage: nil,
            seq: nil, startedAt: nil, endedAt: nil, state: "final")
        XCTAssertNil(ChatMessageConverter.toChatMessage(from: openclaw))
    }

    func testToOpenClawChatMessage_roundTripsState() {
        // Verify the converter preserves the lifecycle marker so
        // the view can re-render the streaming placeholder after
        // the cache round-trip (loadHistory → upsert → toChatMessage).
        let chat = ChatMessage(
            id: UUID().uuidString, text: "", timestamp: Date(),
            role: "assistant", state: "streaming", runId: nil, seq: nil,
            startedAt: nil, endedAt: nil, livenessState: nil,
            toolCallId: nil, toolName: nil, stopReason: nil, isFresh: true)
        let openclaw = ChatMessageConverter.toOpenClawChatMessage(from: chat)
        XCTAssertEqual(openclaw?.state, "streaming")
    }
}
