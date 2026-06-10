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
        XCTAssertNotNil(msg, "invalid UUID 兜底: 应该合成一个新的 UUID,而不是返回 nil")
        XCTAssertNotEqual(msg?.id.uuidString, "not-a-uuid")
        XCTAssertNotNil(UUID(uuidString: msg?.id.uuidString ?? ""), "合成的 id 必须是合法 UUID")
    }

    // MARK: - toOpenClawChatMessage (synthetic id 兜底)

    func testToOpenClawChatMessage_syntheticId_synthesizesUUID() {
        let syntheticId = "ABC123:tool:def-456"  // 旧 streaming 期间的合成 id
        let chat = ChatMessage(
            id: syntheticId, text: "hello", timestamp: Date(),
            role: "toolCall", state: "streaming", runId: nil, seq: nil,
            startedAt: nil, endedAt: nil, livenessState: nil,
            inputTokens: nil, outputTokens: nil, cacheRead: nil, cacheWrite: nil,
            toolCallId: "def-456", toolName: "search", stopReason: nil,
            isFresh: true)
        let openclaw = ChatMessageConverter.toOpenClawChatMessage(from: chat)
        XCTAssertNotNil(openclaw, "synthetic id 兜底,不应该返回 nil")
        XCTAssertNotEqual(openclaw?.id.uuidString, syntheticId)
        XCTAssertNotNil(UUID(uuidString: openclaw?.id.uuidString ?? ""), "生成的 id 必须是合法 UUID")
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
}
