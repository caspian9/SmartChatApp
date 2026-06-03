import Foundation
import UIKit
import OSLog

private let collapseLog = OSLog(subsystem: "SmartChatApp", category: "CollapseStateCache")

@MainActor
final class CollapseStateCache: @unchecked Sendable {
    static let shared = CollapseStateCache()

    private var cache: [String: Bool] = [:]  // messageId -> shouldCollapse

    private let maxCollapsedHeight: CGFloat = 150

    func shouldCollapse(for message: ChatMessage) -> Bool {
        if let cached = cache[message.id] {
            os_log("SMAlog: [CollapseCache] id=%{public}s hit=true value=%{public}03d", log: collapseLog, type: .debug, String(message.id.prefix(8)), cached ? 1 : 0)
            return cached
        }
        let computed = computeShouldCollapse(for: message)
        cache[message.id] = computed
        os_log("SMAlog: [CollapseCache] id=%{public}s computed=%{public}03d stored=%{public}03d", log: collapseLog, type: .debug, String(message.id.prefix(8)), computed ? 1 : 0, cache[message.id] ?? false ? 1 : 0)
        return computed
    }

    func precompute(for messages: [ChatMessage]) {
        os_log("SMAlog: [CollapseCache] precompute count=%{public}d", log: collapseLog, type: .debug, messages.count)
        for msg in messages {
            if cache[msg.id] == nil {
                cache[msg.id] = computeShouldCollapse(for: msg)
            }
        }
        os_log("SMAlog: [CollapseCache] cacheSize=%{public}d", log: collapseLog, type: .debug, cache.count)
    }

    func remove(for messageId: String) {
        cache.removeValue(forKey: messageId)
    }

    func clear() {
        cache.removeAll()
    }

    private func computeShouldCollapse(for message: ChatMessage) -> Bool {
        // Only exclude continuation messages (seq != nil)
        if message.seq != nil {
            return false
        }
        if message.text.isEmpty {
            return false
        }

        let text = message.text
        let textHeight = text.boundingRect(
            with: CGSize(width: UIScreen.main.bounds.width * 0.65, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).height
        let lineHeight: CGFloat = 20
        let lineCount = Int(ceil(textHeight / lineHeight))

        if lineCount < 4 {
            return false
        }
        if textHeight <= maxCollapsedHeight + 20 && lineCount <= 8 {
            return false
        }
        return textHeight >= maxCollapsedHeight + 10
    }
}