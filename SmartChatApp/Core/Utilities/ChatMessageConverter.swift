import Foundation
import OpenClawChatUI
import OpenClawProtocol
import CryptoKit

enum ChatMessageConverter {
    /// OpenClawChatMessage → [ChatMessage], applying the project's
    /// content extraction rules. Returns one ChatMessage per
    /// displayable bubble the view should render. The previous
    /// version collapsed to a single ChatMessage with the
    /// "first text wins" rule, which silently dropped any
    /// `thinking` content when the same source message also had
    /// `text` — the user reported "thinking not visible in
    /// chat.history" for exactly this case. The new contract:
    /// - `[text]` alone → 1 ChatMessage (role: assistant)
    /// - `[thinking]` alone → 1 ChatMessage (role: thinking)
    /// - `[text, thinking]` → 2 ChatMessages (assistant + thinking)
    /// - `[text, toolCall]` → 1 ChatMessage (text with toolCall inline)
    /// - `[thinking, toolCall]` → 1 ChatMessage (thinking with toolCall inline)
    /// - `[text, thinking, toolCall]` → 2 ChatMessages (text+toolCall, then thinking)
    /// - empty / placeholder-only content → [] (caller skips)
    ///
    /// Each emitted ChatMessage has a deterministic id derived
    /// from `msg.id.uuidString`:
    /// - The main entry (text or first thinking) → `msg.id.uuidString`
    /// - Additional thinking entries → `"<msg.id.uuidString>:thinking:<i>"`
    /// The id namespace is stable across re-fetches (same source →
    /// same ChatMessage id) so `MessageCacheStorage.upsert` can
    /// replace by id on a subsequent pull-up refresh, and the
    /// view's `CollapseStateCache.expandedMessageIds` keyed on
    /// these ids survives a `chat.history` round-trip.
    ///
    /// Returns empty array (not nil) when the source has no
    /// displayable content of any kind.
    /// Normalize a role string from the server's `chat.history`
    /// projection to the client's display naming convention. The
    /// server emits lowercase tool-related roles (`tool`,
    /// `toolresult`, `tool_result`, `function`) per
    /// `chat-display-projection.ts:286-294`, while the rest of the
    /// client (view filter, bubble rendering, `MarkdownCache`,
    /// `EventInterpreter` streaming writes) uses camelCase
    /// `toolCall` / `toolResult`. Without normalization, a server-
    /// returned toolCall sits in the cache with `role: "tool"`,
    /// passes the view's `showToolCalls` filter (since "tool" ≠
    /// "toolCall"), but then renders as a plain text bubble (the
    /// bubble's `role == "toolCall"` branch never fires) — the
    /// user sees a text bubble with the tool's args but no
    /// "ToolCall" label. The fix maps every server-side variant
    /// to the canonical client form so both paths render the
    /// same.
    static func normalizeRole(_ role: String) -> String {
        switch role.lowercased() {
        case "toolcall", "tool_call", "tooluse", "tool_use", "tool", "function":
            return "toolCall"
        case "toolresult", "tool_result":
            return "toolResult"
        default:
            return role
        }
    }

    static func toChatMessage(from msg: OpenClawChatMessage) -> [ChatMessage] {
        // First non-empty text is the main text entry (assistant role by default)
        var mainText: String? = nil
        for contentItem in msg.content {
            if let t = contentItem.text, !t.isEmpty {
                mainText = t.trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        // If no text, the first non-empty thinking becomes the main entry (thinking role)
        var mainIsThinking = false
        if mainText == nil {
            for contentItem in msg.content {
                if let thinking = contentItem.thinking, !thinking.isEmpty {
                    mainIsThinking = true
                    break
                }
            }
        }
        // Collect ALL thinking blocks (in server-content order).
        // Each emitted thinking bubble has a deterministic id
        // `msg.id.uuidString:thinking:<i>` so upsert-by-id on a
        // refresh collapses the same source thinking into one
        // bubble, and the view's `CollapseStateCache` survives
        // the round-trip.
        var allThinking: [String] = []
        for contentItem in msg.content {
            if let thinking = contentItem.thinking, !thinking.isEmpty {
                allThinking.append(thinking.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        // First-block-is-thinking heuristic. The previous converter
        // always emitted the main text first, then thinking — that
        // collapsed a `[thinking, text]` content order (the model's
        // actual reasoning-then-response flow) into `[text,
        // thinking]`, showing the response above its reasoning.
        // The user reported the order looks wrong for history
        // messages whose `role == "assistant"` carries a thinking
        // block first; they expect the reasoning to lead the
        // response. The new rule: when the FIRST non-empty content
        // block is a thinking block, emit the thinking bubbles
        // first, then the main text. When the first block is a
        // text block, keep the previous [text, then thinking]
        // order (the existing `testToChatMessage_textAndThinkingBundle_emitsBoth`
        // contract).
        var firstBlockIsThinking = false
        for contentItem in msg.content {
            if let t = contentItem.text, !t.isEmpty { break }
            if let th = contentItem.thinking, !th.isEmpty {
                firstBlockIsThinking = true
                break
            }
        }
        let emitThinkingFirst = firstBlockIsThinking
            && !mainIsThinking
            && !allThinking.isEmpty
        // ToolCall text (for inline merging with the main entry).
        // toolCall never gets its own bubble — it's always inline
        // with the text or the thinking, mirroring the previous
        // display contract.
        var hasToolCall = false
        var toolCallText = ""
        for contentItem in msg.content {
            // Server uses lowercase content types too: `toolcall`,
            // `tool_call`, `tooluse`, `tool_use`. Match any so
            // server-returned messages with these types still
            // produce the inline toolCall text below.
            if let type = contentItem.type?.lowercased(),
               ["toolcall", "tool_call", "tooluse", "tool_use"].contains(type),
               let name = contentItem.name {
                let callText = MessageFormatters.formatToolCallBubbleText(
                    name: name, arguments: contentItem.arguments)
                guard !callText.isEmpty else { continue }
                hasToolCall = true
                if toolCallText.isEmpty {
                    toolCallText = callText
                } else {
                    toolCallText += "\n\n" + callText
                }
            }
        }
        let ts = msg.timestamp ?? 0
        let dateTimestamp = Date(timeIntervalSince1970: ts / 1000)
        // History messages always render as `state: "final"` — the
        // SDK's `OpenClawChatMessage` does not carry streaming
        // state (no `state`/`seq`/`startedAt`/`endedAt` fields), and
        // the streaming values are owned by `EventInterpreter` /
        // `MessageReceiver` during an in-flight run, not by the
        // history decoder. The view's `TypingIndicatorView` only
        // fires for messages explicitly set to `"streaming"` by the
        // event pipeline, which historical messages are never.
        let baseState = "final"
        let sharedBase = ChatMessage.ChatMessageBaseFields(
            timestamp: dateTimestamp,
            seq: nil,
            startedAt: nil,
            endedAt: nil,
            state: baseState,
            inputTokens: msg.usage?.input,
            outputTokens: msg.usage?.output,
            cacheRead: msg.usage?.cacheRead,
            cacheWrite: msg.usage?.cacheWrite,
            toolCallId: msg.toolCallId,
            toolName: msg.toolName,
            stopReason: msg.stopReason
        )
        let normalizedRole = ChatMessageConverter.normalizeRole(msg.role)
        var result: [ChatMessage] = []
        // 1. Thinking blocks (only when main is NOT the first
        //    thinking). When `emitThinkingFirst` is true, the
        //    server's content was `[thinking, text]` (or
        //    `[thinking, thinking, text]`); render the reasoning
        //    bubbles first so the response is preceded by its
        //    rationale. When `emitThinkingFirst` is false, we
        //    preserve the previous "main text first" order for
        //    `[text, thinking]` content.
        if emitThinkingFirst {
            for (i, t) in allThinking.enumerated() {
                result.append(ChatMessage(
                    id: "\(msg.id.uuidString):thinking:\(i)",
                    text: t,
                    role: "thinking",
                    base: sharedBase
                ))
            }
        }
        // 2. Main entry — text or first-thinking-as-main.
        if let main = mainText {
            var mainFinalText = main
            if hasToolCall {
                mainFinalText = mainFinalText + "\n\n" + toolCallText
            }
            // role: assistant for text (after normalize), thinking
            // for the first-thinking-as-main case. toolCall never
            // produces its own role here — it lives inline.
            let mainRole: String = mainIsThinking ? "thinking" : normalizedRole
            result.append(ChatMessage(
                id: msg.id.uuidString,
                text: mainFinalText,
                role: mainRole,
                base: sharedBase
            ))
        } else if mainIsThinking, let firstThinking = allThinking.first {
            // No text block, but the first thinking block IS the
            // main entry. allThinking hasn't been pre-trimmed
            // (the previous "removeFirst" pass moved into the
            // emit-thinking-first branch above for the
            // `[thinking, text]` case). Emit the first thinking
            // as the main thinking bubble; the remaining entries
            // are emitted as separate thinking bubbles below.
            var mainFinalText = firstThinking
            if hasToolCall {
                mainFinalText = mainFinalText + "\n\n" + toolCallText
            }
            result.append(ChatMessage(
                id: msg.id.uuidString,
                text: mainFinalText,
                role: "thinking",
                base: sharedBase
            ))
        }
        // 4. Fallthrough: no main text and no thinking block.
        // After routing streaming bubbles through the store
        // (id-upsert via `MessageReceiver.receiveMessage`), the
        // lifecycle=start placeholder arrives here with
        // `text=""` and no thinking — the previous filter
        // dropped it, causing the view's TypingIndicatorView to
        // never render during streaming. Emit a bubble with
        // whatever text is available (toolCall if present, else
        // empty for the streaming placeholder) so the bubble is
        // visible. The view's `if message.text.isEmpty` branch
        // renders a small empty bubble that marks the streaming
        // position; a tool-call-only bubble keeps the inline
        // toolCall text the user was seeing before this path
        // was added.
        if result.isEmpty {
            let fallbackText = hasToolCall ? toolCallText : ""
            result.append(ChatMessage(
                id: msg.id.uuidString,
                text: fallbackText,
                role: hasToolCall ? "toolCall" : normalizedRole,
                base: sharedBase
            ))
        }
        // 3. Additional thinking entries (each as a separate
        //    bubble). Emitted after the main entry when
        //    `emitThinkingFirst` is false (i.e., main was text).
        //    When `emitThinkingFirst` is true, the main text
        //    comes AFTER the thinking blocks above and there's
        //    no extras to add here.
        //
        //    When `mainIsThinking` is true, the first thinking
        //    is the main entry and the rest are extras — we
        //    skip the first with `dropFirst()` to avoid
        //    emitting it twice. When `mainIsThinking` is
        //    false, every thinking entry in `allThinking` is
        //    an extra (the main was a text block, emitted
        //    above) — iterate over the full list.
        if !emitThinkingFirst {
            let extras = mainIsThinking ? allThinking.dropFirst() : allThinking[...]
            for (i, t) in extras.enumerated() {
                result.append(ChatMessage(
                    id: "\(msg.id.uuidString):thinking:\(i)",
                    text: t,
                    role: "thinking",
                    base: sharedBase
                ))
            }
        }
        // 4. Fallback: only toolCall content (no text, no thinking)
        if result.isEmpty && hasToolCall {
            result.append(ChatMessage(
                id: msg.id.uuidString,
                text: toolCallText,
                role: "toolCall",
                base: sharedBase
            ))
        }
        // 5. Streaming placeholder fallback: the `lifecycle=start`
        //    event creates a `text=""` `state="streaming"` entry
        //    that drives the view's TypingIndicatorView. Even if
        //    the message has no displayable content, the
        //    placeholder must reach the view — otherwise the user
        //    sees a blank gap between sending and the first delta.
        if result.isEmpty && baseState == "streaming" {
            result.append(ChatMessage(
                id: msg.id.uuidString,
                text: "",
                role: normalizedRole,
                base: sharedBase
            ))
        }
        return result
    }

    /// Shared construction fields for the multiple ChatMessages a
    /// single `OpenClawChatMessage` may emit. Lets the converter
    /// loop build each entry without repeating the same
    /// ChatMessage → OpenClawChatMessage (cache writer).
    ///
    /// The `OpenClawChatMessage.id` field is the primary key that
    /// `MessageCacheStorage.upsert` keys on to replace streaming deltas
    /// in place. For this to work across many deltas that share one
    /// logical id (e.g., the assistant bubble for a single run,
    /// identified by `runId`; tool call bubbles keyed by
    /// `"<runId>:toolCall:<toolCallId>"`), the synthesized UUID MUST be
    /// DETERMINISTIC — the same input id always produces the same
    /// output UUID. Otherwise every delta appends a new entry, the
    /// view shows N duplicates of the same logical message, the
    /// `lifecycle=start` typing-indicator placeholder is never
    /// replaced, and tool-call / tool-result bubbles accumulate
    /// dozens of partial-text variants.
    ///
    /// For input ids that are valid UUIDs (the user-message bubble,
    /// server-persisted history messages), we parse and use as-is.
    /// For non-UUID synthetic ids, we derive a stable UUID by
    /// SHA256-hashing the string and formatting the first 16 bytes as
    /// a UUID. The previous implementation (`UUID(uuidString: ...) ??
    /// UUID()`) generated a fresh UUID per call, which broke the
    /// upsert path — see commit abaf95c that introduced the bug.
    /// Mirrors the `createOpenClawChatMessage(from:)` previously on
    /// the VM.
    static func toOpenClawChatMessage(from chatMessage: ChatMessage) -> OpenClawChatMessage? {
        let uuid: UUID
        if let parsed = UUID(uuidString: chatMessage.id) {
            uuid = parsed
        } else {
            uuid = deterministicUUID(from: chatMessage.id)
        }
        var usage: OpenClawChatUsage? = nil
        if chatMessage.inputTokens != nil || chatMessage.outputTokens != nil
            || chatMessage.cacheRead != nil || chatMessage.cacheWrite != nil {
            var usageData: [String: AnyCodable] = [:]
            if let input = chatMessage.inputTokens { usageData["input"] = AnyCodable(input) }
            if let output = chatMessage.outputTokens { usageData["output"] = AnyCodable(output) }
            if let cr = chatMessage.cacheRead { usageData["cacheRead"] = AnyCodable(cr) }
            if let cw = chatMessage.cacheWrite { usageData["cacheWrite"] = AnyCodable(cw) }
            if let data = try? JSONEncoder().encode(usageData),
               let decoded = try? JSONDecoder().decode(OpenClawChatUsage.self, from: data) {
                usage = decoded
            }
        }
        return OpenClawChatMessage(
            id: uuid,
            // Normalize the role on the way in so the cache
            // (and the dedupKey, which keys on `message.role`)
            // always carries the canonical client form. A
            // server-returned message that went through the
            // reader's `normalizeRole` lands here with the
            // already-normalized value; a streaming message
            // already uses camelCase; either way, the cache
            // ends up with a consistent `toolCall` / `toolResult`
            // so streaming and history dedup against each other
            // and the view's role branches all see the same
            // strings.
            //
            // The SDK's `OpenClawChatMessage` does not carry
            // `seq` / `startedAt` / `endedAt` — those are
            // streaming-only fields owned by `EventInterpreter` /
            // `MessageReceiver` and gated out of the cache by
            // the persist gate (only `state: "final"` messages
            // reach this writer), so dropping them here is
            // safe and avoids writing a round-trip the SDK
            // can't decode.
            role: ChatMessageConverter.normalizeRole(chatMessage.role),
            // Schema must match the server's `chat.history` shape so a
            // streaming bubble and a server-returned bubble with the same
            // logical content dedup against each other in
            // `MessageCacheStorage.dedupKey`. Without this split, a
            // streaming thinking bubble lands in the cache as
            // `type="text", text="<thinking>"`, while the server returns
            // `type="thinking", thinking="<thinking>"`; both pass the
            // dedupKey match (same hash, same role), the streaming copy
            // is KEEP'd, and `toChatMessage` reads it as plain text —
            // the user reports "history thinking content not displayed".
            // toolCall bubbles use the same inline merge that the
            // streaming path produces (EventInterpreter formats the
            // toolCall text into `chatMessage.text` for the tool bubble);
            // see `MessageFormatters.formatToolCallBubbleText`.
            content: [Self.contentItem(for: chatMessage)],
            timestamp: chatMessage.timestamp.timeIntervalSince1970 * 1000,
            toolCallId: chatMessage.toolCallId,
            toolName: chatMessage.toolName,
            usage: usage,
            stopReason: chatMessage.stopReason,
            // The SDK's `OpenClawChatMessage` does not carry
            // `state`; the reader defaults every decoded message
            // to `state: "final"`. The persist gate ensures only
            // `final` messages reach this writer, so this is
            // always a no-op round-trip. (If we ever persist
            // streaming placeholders, the reader's default will
            // need to grow a "isStreaming" hint — out of scope
            // for this branch.)
        )
    }

    /// Build the single `OpenClawChatMessageContent` for a
    /// `ChatMessage` being written to the cache. The schema split
    /// mirrors the server's `chat.history` projection so a streaming
    /// thinking bubble (role: "thinking") and a server-returned
    /// thinking block (type: "thinking") end up with the same shape
    /// in the cache, and `MessageCacheStorage.dedupKey`'s content
    /// hash treats them as duplicates. Without this split, the
    /// streaming copy wins dedup but reads back as plain text, and
    /// the user sees the response bubble without its reasoning.
    ///
    /// The previous implementation always wrote `type: "text",
    /// text: chatMessage.text, thinking: nil` regardless of role —
    /// correct for assistant/user/toolCall bubbles but wrong for
    /// thinking, where the content belongs in the `thinking` field.
    static func contentItem(for chatMessage: ChatMessage) -> OpenClawChatMessageContent {
        if chatMessage.role == "thinking" {
            return OpenClawChatMessageContent(
                type: "thinking",
                text: nil,
                thinking: chatMessage.text,
                thinkingSignature: nil,
                mimeType: nil, fileName: nil, content: nil,
                id: nil, name: nil, arguments: nil)
        }
        return OpenClawChatMessageContent(
            type: "text",
            text: chatMessage.text,
            thinking: nil,
            thinkingSignature: nil,
            mimeType: nil, fileName: nil, content: nil,
            id: nil, name: nil, arguments: nil)
    }

    /// Deterministically derive a UUID from an arbitrary string. Used
    /// by `toOpenClawChatMessage` so that synthetic streaming ids
    /// (e.g. `runId`, `"<runId>:toolCall:<toolCallId>"`) map to a
    /// stable UUID across calls — the upsert-by-id path in
    /// `MessageCacheStorage.upsert` requires this stability to
    /// replace streaming deltas in place rather than appending a new
    /// entry per delta.
    ///
    /// SHA256(input.utf8) → first 16 bytes → formatted as a UUID
    /// string → parsed via `UUID(uuidString:)`. Same input always
    /// produces the same output; two distinct inputs colliding in
    /// the first 16 SHA256 bytes is cryptographically negligible.
    static func deterministicUUID(from string: String) -> UUID {
        let hash = SHA256.hash(data: Data(string.utf8))
        var bytes = [UInt8]()
        bytes.reserveCapacity(16)
        for byte in hash.prefix(16) {
            bytes.append(byte)
        }
        let uuidString = String(
            format: "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5],
            bytes[6], bytes[7],
            bytes[8], bytes[9],
            bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuidString: uuidString) ?? UUID()
    }
}
