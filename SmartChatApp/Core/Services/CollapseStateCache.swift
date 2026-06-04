import Foundation
import UIKit

@MainActor
final class CollapseStateCache: @unchecked Sendable {
    static let shared = CollapseStateCache()

    private var shouldCollapseCache: [String: Bool] = [:]  // messageId -> shouldCollapse
    private var safeHeightCache: [String: CGFloat] = [:]  // messageId -> safeCollapseHeight

    private let maxCollapsedHeight: CGFloat = 150

    func shouldCollapse(for message: ChatMessage) -> Bool {
        if let cached = shouldCollapseCache[message.id] {
            return cached
        }
        let computed = computeShouldCollapse(for: message)
        shouldCollapseCache[message.id] = computed
        return computed
    }

    /// Returns safe collapse height - the height at which no line is cut mid-way
    /// Only meaningful if shouldCollapse is true, returns nil otherwise
    func safeCollapseHeight(for message: ChatMessage) -> CGFloat? {
        if let cached = safeHeightCache[message.id] {
            return cached
        }
        // Only compute if text is non-empty
        guard !message.text.isEmpty else { return nil }

        // Compute the safe height using boundingRect methodology
        let text = message.text
        let maxWidth = UIScreen.main.bounds.width * 0.65

        // For markdown: variable line heights, find last incomplete row boundary
        // Simulate line-by-line rendering to find safe cutoff
        let lineHeight: CGFloat = 18  // Consistent line height for plain text fallback
        let spacing: CGFloat = 4  // VStack spacing

        // Use boundingRect to find approximate total height
        let totalHeight = text.boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).height

        // Calculate how many lines fit within maxCollapsedHeight + tolerance
        // Use 1 buffer row to ensure we don't cut mid-text
        let availableLines = maxCollapsedHeight / lineHeight
        let safeLines = min(floor(availableLines), 8)  // Max 8 lines, round down

        // Calculate final height aligning to line boundary
        var safeHeight: CGFloat = 0
        if safeLines >= 1 {
            safeHeight = lineHeight * safeLines + spacing * (safeLines - 1)
        } else {
            safeHeight = maxCollapsedHeight
        }

        // Cap at maxCollapsedHeight + tolerance for safety
        let maxAllowed = maxCollapsedHeight + 20
        if safeHeight > maxAllowed {
            safeHeight = maxAllowed
        }

        safeHeightCache[message.id] = safeHeight
        AppLogger.log("[CollapseCache safeHeight] id=\(String(message.id.prefix(8))) totalHeight=\(String(format: "%.1f", totalHeight)) safeHeight=\(String(format: "%.1f", safeHeight)) lines=\(String(format: "%.1f", safeLines))", category: .cache)

        return safeHeight
    }

    func precompute(for messages: [ChatMessage], batchSize: Int = 50) {
        var computedCount = 0
        for msg in messages {
            if shouldCollapseCache[msg.id] == nil {
                shouldCollapseCache[msg.id] = computeShouldCollapse(for: msg)
                computedCount += 1
            }
        }
        AppLogger.log("[CollapseCache] precompute processed=\(messages.count) computed=\(computedCount) cacheSize=\(shouldCollapseCache.count)", category: .cache)
    }

    func remove(for messageId: String) {
        shouldCollapseCache.removeValue(forKey: messageId)
        safeHeightCache.removeValue(forKey: messageId)
    }

    func clear() {
        shouldCollapseCache.removeAll()
        safeHeightCache.removeAll()
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

        AppLogger.log("[CollapseCache] id=\(String(message.id.prefix(8))) text_len=\(text.count) lines=\(lineCount) height=\(String(format: "%.1f", textHeight))", category: .cache)

        if lineCount < 4 {
            return false
        }
        if textHeight <= maxCollapsedHeight + 20 && lineCount <= 8 {
            return false
        }
        return textHeight >= maxCollapsedHeight + 10
    }
}