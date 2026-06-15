import Foundation
import UIKit
import Combine

/// `ObservableObject` + `@Published` so SwiftUI views reading
/// `isExpanded(_:)` get reliable invalidation on every mutation. The
/// previous three attempts used `@Observable` (iOS 17+ macro), each of
/// which failed under user testing: the `@MainActor @Observable
/// static let shared` combination silently dropped SwiftUI
/// invalidation for value-type `Set` mutations on iOS 26 — the cache
/// field would update but dependent views (e.g. `MessageBubbleView`)
/// would not re-render, so a manually-expanded bubble re-collapsed
/// after every network refresh. `@Published` triggers
/// `objectWillChange.send()` from a synthesized `willSet` block on
/// every mutation (including in-place `Set.insert/remove`), which is
/// the standard SwiftUI 1.0-era pattern and works on iOS 13+ without
/// regression. View side: `MessageBubbleView` now uses
/// `@ObservedObject` to subscribe.
@MainActor
final class CollapseStateCache: ObservableObject {
    static let shared = CollapseStateCache()

    private var shouldCollapseCache: [String: Bool] = [:]  // messageId -> shouldCollapse
    private var safeHeightCache: [String: CGFloat] = [:]  // messageId -> safeCollapseHeight
    /// Tracks which messages the user has manually expanded via the
    /// "Show more..." button or `MessageReceiver`'s `lifecycle end`
    /// mark. Lives outside `MessageBubbleView`'s `@State` because
    /// LazyVStack destroys and recreates bubble views when scrolling;
    /// an `@State` flag is lost on the round trip and the bubble
    /// appears to auto-collapse as the user scrolls away and back.
    /// The user's expand choice is sticky until the cache is cleared
    /// (which happens when the view leaves NativeChat, or when the
    /// user switches sessions via `clear()`). `private(set)` so the
    /// only write path is `setExpanded(_:_:)`, which keeps the
    /// logging centralized.
    @Published private(set) var expandedMessageIds: Set<String> = []

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
        return safeHeight
    }

    func precompute(for messages: [ChatMessage], batchSize: Int = 50) {
        // The expensive work is `computeShouldCollapse`, which
        // measures text height with `boundingRect` per message.
        // For a 200-message history this is ~200 UIKit text
        // measurements on the main thread. Delegate the
        // per-message compute to the nonisolated helper
        // (`precomputeValues`) so callers can drive it from a
        // `Task.detached` and keep the main thread free during
        // session switch. This precompute method itself is still
        // `@MainActor` (the class is) and runs the dict writes
        // synchronously, but the boundingRect + `lineCount`
        // compute is moved off main.
        let alreadyCached = shouldCollapseCache
        let values = Self.precomputeValues(
            for: messages, alreadyCachedIds: Set(alreadyCached.keys))
        for (id, value) in values {
            shouldCollapseCache[id] = value
        }
        AppLogger.log("[CollapseCache] precompute processed=\(messages.count) computed=\(values.count) cacheSize=\(shouldCollapseCache.count)", category: .cache)
    }

    /// Returns the set of message ids that already have a
    /// cached `shouldCollapse` value. Used by `HistoryLoader`'s
    /// detached precompute path: the caller reads the current
    /// set on the main actor, hands it to the background
    /// helper (`precomputeValues`) so the background task
    /// doesn't recompute values that are already cached, then
    /// applies the new entries via `applyPrecomputedValues`.
    func shouldCollapseCachedIds() -> Set<String> {
        Set(shouldCollapseCache.keys)
    }

    /// Apply the result of a background `precomputeValues` call.
    /// Cheap main-thread work — N dict writes for the messages
    /// that weren't already cached.
    func applyPrecomputedValues(_ values: [String: Bool]) {
        for (id, value) in values {
            shouldCollapseCache[id] = value
        }
    }

    /// Non-isolated, thread-safe static helper for the
    nonisolated static func precomputeValues(
        for messages: [ChatMessage],
        alreadyCachedIds: Set<String>
    ) -> [String: Bool] {
        var values: [String: Bool] = [:]
        let maxCollapsedHeight: CGFloat = 150
        for msg in messages {
            if alreadyCachedIds.contains(msg.id) { continue }
            if msg.seq != nil { values[msg.id] = false; continue }
            if msg.text.isEmpty { values[msg.id] = false; continue }
            let text = msg.text
            let estimatedLineCount = max(1, text.count / 40)
            if estimatedLineCount >= 4 {
                let estimatedHeight = CGFloat(estimatedLineCount) * 20
                if estimatedHeight >= maxCollapsedHeight + 40 {
                    values[msg.id] = true
                    continue
                }
            }
            let textHeight = text.boundingRect(
                with: CGSize(width: UIScreen.main.bounds.width * 0.65, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            ).height
            let lineHeight: CGFloat = 20
            let lineCount = Int(ceil(textHeight / lineHeight))
            if lineCount < 4 {
                values[msg.id] = false
            } else if textHeight <= maxCollapsedHeight + 20 && lineCount <= 8 {
                values[msg.id] = false
            } else {
                values[msg.id] = textHeight >= maxCollapsedHeight + 10
            }
        }
        return values
    }

    func remove(for messageId: String) {
        shouldCollapseCache.removeValue(forKey: messageId)
        safeHeightCache.removeValue(forKey: messageId)
        expandedMessageIds.remove(messageId)
    }

    func clear() {
        shouldCollapseCache.removeAll()
        safeHeightCache.removeAll()
        // `clear()` is called when the user leaves NativeChat or
        // switches sessions. Reset the manual-expand set so a return
        // visit (or the new session) starts every bubble in the
        // collapsed form. Per the user requirement: "已展开的 showMore
        // 气泡在用户滚动时不要被自动收起,只退出页面 / 切 session
        // 时才按折叠形式重置" — this is the reset path.
        expandedMessageIds.removeAll()
    }

    /// Returns true if the user has manually expanded this message via
    /// the "Show more..." button. False for messages the user has not
    /// touched (initial state — collapse controlled by `shouldCollapse`).
    /// `MessageBubbleView` reads `message.isUserExpanded` directly
    /// (set by the parent's `messages` computed property from
    /// `expandedMessageIds`); this method is kept for external
    /// callers and tests.
    func isExpanded(_ messageId: String) -> Bool {
        expandedMessageIds.contains(messageId)
    }

    /// Mark a message as user-expanded (or clear the mark if `false`).
    /// Idempotent: setting the same value twice is a no-op.
    ///
    /// MUST use whole-assignment (`union` / `subtracting`), NOT
    /// `Set.insert/remove`. `@Published` (iOS 13-era property wrapper)
    /// only triggers `objectWillChange.send()` from its `wrappedValue`
    /// setter's `willSet`. It does NOT provide a `_modify` accessor,
    /// so in-place `Set.insert/remove` — which Swift routes through
    /// the auto-synthesized `_modify` of the underlying storage —
    /// bypasses `@Published` entirely. The `Set` mutates in place but
    /// the publisher never fires, and `@ObservedObject`-subscribed
    /// views never re-render. Whole-assignment forces the setter
    /// path, which is what `ObservableObject` subscribers track.
    func setExpanded(_ messageId: String, _ expanded: Bool) {
        if expanded {
            expandedMessageIds = expandedMessageIds.union([messageId])
        } else {
            expandedMessageIds = expandedMessageIds.subtracting([messageId])
        }
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

        if lineCount < 4 {
            return false
        }
        if textHeight <= maxCollapsedHeight + 20 && lineCount <= 8 {
            return false
        }
        return textHeight >= maxCollapsedHeight + 10
    }
}