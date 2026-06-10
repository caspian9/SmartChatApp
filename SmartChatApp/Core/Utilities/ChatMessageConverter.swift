import Foundation
import OpenClawChatUI
import OpenClawProtocol

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
        guard !text.isEmpty else { return nil }
        let ts = msg.timestamp ?? 0
        return ChatMessage(
            id: msg.id.uuidString,
            text: text,
            timestamp: Date(timeIntervalSince1970: ts / 1000),
            role: role,
            state: "final",
            runId: nil,
            seq: nil,
            startedAt: nil,
            endedAt: nil,
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

    /// ChatMessage → OpenClawChatMessage (cache writer). Synthesizes a
    /// fresh UUID when the input id is not a valid UUID (e.g., streaming
    /// messages with synthetic ids like `"ABC123:tool:def-456"`).
    /// Mirrors the `createOpenClawChatMessage(from:)` previously on the VM.
    static func toOpenClawChatMessage(from chatMessage: ChatMessage) -> OpenClawChatMessage? {
        let uuid = UUID(uuidString: chatMessage.id) ?? UUID()
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
            stopReason: chatMessage.stopReason
        )
    }
}
