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
            return cached
        }
        let computed = computeShouldCollapse(for: message)
        cache[message.id] = computed
        return computed
    }

    func precompute(for messages: [ChatMessage], batchSize: Int = 50) {
        var computedCount = 0
        for msg in messages {
            if cache[msg.id] == nil {
                cache[msg.id] = computeShouldCollapse(for: msg)
                computedCount += 1
            }
        }
        os_log("SMAlog: [CollapseCache] precompute processed=%{public}d computed=%{public}d cacheSize=%{public}d", log: collapseLog, type: .debug, messages.count, computedCount, cache.count)
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
        // Fast path: for very long content, estimate and return true without boundingRect
        let estimatedLineCount = max(1, text.count / 40)
        if estimatedLineCount >= 4 {
            let estimatedHeight = CGFloat(estimatedLineCount) * 20
            // If clearly exceeds threshold, return true without expensive boundingRect
            if estimatedHeight >= maxCollapsedHeight + 40 {
                return true
            }
        }

        // Use boundingRect for accurate calculation
        let textHeight = text.boundingRect(
            with: CGSize(width: UIScreen.main.bounds.width * 0.65, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).height
        let lineHeight: CGFloat = 20
        let lineCount = Int(ceil(textHeight / lineHeight))

        os_log("SMAlog: [CollapseCache] id=%{public}s text_len=%{public}d lines=%{public}d height=%{public}.1f", log: collapseLog, type: .debug, String(message.id.prefix(8)), text.count, lineCount, textHeight)

        if lineCount < 4 {
            return false
        }
        if textHeight <= maxCollapsedHeight + 20 && lineCount <= 8 {
            return false
        }
        return textHeight >= maxCollapsedHeight + 10
    }
}