import Foundation
import OpenClawChatUI
import OpenClawProtocol
import CryptoKit

enum ChatMessageConverter {
    /// OpenClawChatMessage → ChatMessage, applying the project's content
    /// extraction rules (text → assistant, thinking → thinking, toolCall →
    /// toolCall). Returns nil when the message has no displayable text.
    /// Body mirrors the `compactMap { msg -> ChatMessage? in ... }` blocks
    /// previously duplicated 3× in NativeChatViewModel.loadHistory.
    static func toChatMessage(from msg: OpenClawChatMessage) -> ChatMessage? {
        var text = ""
        var role = msg.role
        for contentItem in msg.content {
            if let t = contentItem.text, !t.isEmpty {
                text = t.trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        if text.isEmpty {
            for contentItem in msg.content {
                if let thinking = contentItem.thinking, !thinking.isEmpty {
                    text = thinking.trimmingCharacters(in: .whitespacesAndNewlines)
                    role = "thinking"
                    break
                }
            }
        }
        var hasToolCall = false
        var toolCallText = ""
        for contentItem in msg.content {
            if contentItem.type == "toolCall", let name = contentItem.name {
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
        if hasToolCall {
            if text.isEmpty {
                text = toolCallText
                role = "toolCall"
            } else {
                text = text + "\n\n" + toolCallText
            }
        }
        guard !text.isEmpty || msg.state == "streaming" else { return nil }
        let ts = msg.timestamp ?? 0
        return ChatMessage(
            id: msg.id.uuidString,
            text: text,
            timestamp: Date(timeIntervalSince1970: ts / 1000),
            role: role,
            // Server-persisted history messages leave `state` nil; default
            // to "final" so the view doesn't try to render a typing
            // indicator on a historical message. The streaming
            // placeholder (lifecycle=start) keeps its `"streaming"`
            // value so the view's `TypingIndicatorView` renders before
            // the first delta arrives.
            state: msg.state ?? "final",
            runId: nil,
            seq: msg.seq,
            // Persisted startedAt/endedAt are epoch milliseconds
            // (matching `timestamp`); ChatMessage wants Date.
            startedAt: msg.startedAt.map { Date(timeIntervalSince1970: $0 / 1000) },
            endedAt: msg.endedAt.map { Date(timeIntervalSince1970: $0 / 1000) },
            livenessState: nil,
            inputTokens: msg.usage?.input,
            outputTokens: msg.usage?.output,
            cacheRead: msg.usage?.cacheRead,
            cacheWrite: msg.usage?.cacheWrite,
            toolCallId: msg.toolCallId,
            toolName: msg.toolName,
            stopReason: msg.stopReason
        )
    }

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
            role: chatMessage.role,
            content: [OpenClawChatMessageContent(
                type: "text", text: chatMessage.text, thinking: nil,
                thinkingSignature: nil, mimeType: nil, fileName: nil,
                content: nil, id: nil, name: nil, arguments: nil)],
            timestamp: chatMessage.timestamp.timeIntervalSince1970 * 1000,
            toolCallId: chatMessage.toolCallId,
            toolName: chatMessage.toolName,
            usage: usage,
            stopReason: chatMessage.stopReason,
            seq: chatMessage.seq,
            // Date → epoch milliseconds (matches `timestamp`).
            // `.map` is required — `?.timeIntervalSince1970 * 1000`
            // would be `Double? * Double`, which Swift refuses to
            // implicitly unwrap.
            startedAt: chatMessage.startedAt.map { $0.timeIntervalSince1970 * 1000 },
            endedAt: chatMessage.endedAt.map { $0.timeIntervalSince1970 * 1000 },
            // Round-trip the lifecycle so the view can re-create a
            // streaming placeholder from the cache (it shows
            // TypingIndicatorView when state=="streaming" and text is
            // empty).
            state: chatMessage.state
        )
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
    private static func deterministicUUID(from string: String) -> UUID {
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
