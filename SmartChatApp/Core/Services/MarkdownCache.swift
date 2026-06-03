import Foundation
import OSLog

private let markdownLog = OSLog(subsystem: "SmartChatApp", category: "MarkdownCache")

@MainActor
final class MarkdownCache: @unchecked Sendable {
    static let shared = MarkdownCache()

    private var cache: [String: Bool] = [:]  // messageId -> needsMarkdown

    @MainActor
    func precomputeForMessages(_ messages: [ChatMessage]) {
        cache.removeAll()
        for msg in messages {
            let isMarkdown = CardRegistry.containsMarkdown(content: msg.text)
            let needsMarkdown = !msg.isOutgoing && !msg.text.isEmpty && isMarkdown
            cache[msg.id] = needsMarkdown
        }
    }

    @MainActor
    func needsMarkdown(for messageId: String) -> Bool {
        return cache[messageId] ?? false
    }

    @MainActor
    func clear() {
        cache.removeAll()
    }

    @MainActor
    func remove(for messageId: String) {
        cache.removeValue(forKey: messageId)
    }
}
