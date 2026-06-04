import Foundation
import UIKit
import MarkdownDisplayView

@MainActor
final class MarkdownHolder {
    let messageId: String
    let view: MarkdownViewTextKit
    private var hasBegun = false
    private(set) var isEnded = false
    /// Last cumulative `data["text"]` we received from the server for this
    /// run. The Gateway sends the full assistant text on every chunk
    /// (`OpenClawChatUI/ChatViewModel.handleAgentEvent` mirrors this:
    /// `streamingAssistantText = text`). We use it to compute the actual
    /// incremental suffix to feed `appendStreamData`, which only knows how
    /// to append. Without this we'd render `ABC + ABCDE + ABCDEF` =
    /// `ABCABCDEABCDEF`.
    private(set) var lastReceivedText: String = ""

    init(messageId: String) {
        self.messageId = messageId
        self.view = MarkdownViewTextKit()
        self.view.enableTypewriterEffect = false
        var config = MarkdownConfiguration.default
        config.typewriterTextMode = .append
        // Bigger flush threshold = fewer TextKit relayouts during long streams.
        // Stuttering during 10-round conversations was traced to per-chunk
        // re-renders firing every 20 chars; 50 cuts that ~2.5× without
        // noticeably hurting perceived smoothness.
        config.typewriterHeightUpdateInterval = 50
        config.streamMinModuleLength = 50
        self.view.configuration = config
    }

    func begin() {
        guard !hasBegun else {
            AppLogger.log("[MarkdownHolder] begin() skipped (already begun) id=\(String(messageId.prefix(8)))", category: .markdown)
            return
        }
        hasBegun = true
        view.beginRealStreaming(autoScrollBottom: false, useSmartBuffer: true)
        AppLogger.log("[MarkdownHolder] begin() id=\(String(messageId.prefix(8)))", category: .markdown)
    }

    /// Server delivers full cumulative text on every chunk. Compute the
    /// incremental suffix relative to what we've already appended and feed
    /// only that to the TextKit view.
    /// - Returns the suffix that was appended (for callers that want to log it).
    @discardableResult
    func appendCumulative(_ cumulative: String) -> String {
        guard hasBegun, !isEnded else {
            AppLogger.log("[MarkdownHolder] appendCumulative skipped (not begun/ended) id=\(String(messageId.prefix(8)))", category: .markdown)
            return ""
        }
        let suffix: String
        if cumulative.hasPrefix(lastReceivedText) {
            suffix = String(cumulative.dropFirst(lastReceivedText.count))
        } else {
            // Server sent text that doesn't extend what we had — most likely a
            // retransmit or reordering. Trust the new text and replace our
            // notion of "what's been streamed". The TextKit view can't be
            // truncated mid-stream, so we just append the whole cumulative
            // string; this can leave visible duplication but it's strictly
            // safer than dropping content.
            AppLogger.log("[MarkdownHolder] cumulative does not extend prev id=\(String(messageId.prefix(8))) prev_len=\(lastReceivedText.count) new_len=\(cumulative.count)", category: .markdown, level: .warning)
            suffix = cumulative
        }
        lastReceivedText = cumulative
        if !suffix.isEmpty {
            view.appendStreamData(suffix)
            AppLogger.log("[MarkdownHolder] appendCumulative id=\(String(messageId.prefix(8))) suffix_len=\(suffix.count) total_len=\(cumulative.count)", category: .markdown)
        }
        return suffix
    }

    func end() {
        guard hasBegun, !isEnded else {
            AppLogger.log("[MarkdownHolder] end() skipped (not begun/already ended) id=\(String(messageId.prefix(8)))", category: .markdown)
            return
        }
        isEnded = true
        view.endRealStreaming()
        AppLogger.log("[MarkdownHolder] end() id=\(String(messageId.prefix(8))) final_len=\(lastReceivedText.count)", category: .markdown)
    }

    /// Reset for reuse - call when re-entering a message that may have leftover state
    func reset() {
        if hasBegun && !isEnded {
            view.endRealStreaming()
        }
        hasBegun = false
        isEnded = false
        lastReceivedText = ""
    }

    /// Returns the full markdown text that has been streamed for this run.
    /// Prefers our tracked cumulative copy (authoritative — it's exactly
    /// what the server sent) over `view.markdown` (which can lag behind
    /// when the smart buffer hasn't flushed yet).
    func currentText() -> String? {
        guard hasBegun else { return nil }
        if !lastReceivedText.isEmpty {
            return lastReceivedText
        }
        let text = view.markdown
        return text.isEmpty ? nil : text
    }
}

@MainActor
final class MarkdownStreamManager {
    static let shared = MarkdownStreamManager()

    private var holders: [String: MarkdownHolder] = [:]

    private init() {}

    func holder(for messageId: String) -> MarkdownHolder {
        if let existing = holders[messageId] {
            existing.reset()
            return existing
        }
        let new = MarkdownHolder(messageId: messageId)
        holders[messageId] = new
        AppLogger.log("[MarkdownStreamManager] created holder id=\(String(messageId.prefix(8))) total=\(holders.count)", category: .markdown)
        return new
    }

    func begin(messageId: String) {
        holders[messageId]?.begin()
    }

    func appendCumulative(messageId: String, cumulative: String) {
        guard let holder = holders[messageId] else {
            AppLogger.log("[MarkdownStreamManager] appendCumulative no holder id=\(String(messageId.prefix(8)))", category: .markdown)
            return
        }
        holder.appendCumulative(cumulative)
    }

    func end(messageId: String) {
        holders[messageId]?.end()
    }

    /// Returns the full markdown text accumulated for the given message id,
    /// or nil if no holder exists / hasn't begun / has empty text. The
    /// agent-end handler uses this to write the final text to the cache.
    func currentText(for messageId: String) -> String? {
        return holders[messageId]?.currentText()
    }

    func release(messageId: String) {
        if let holder = holders.removeValue(forKey: messageId) {
            holder.reset()
            AppLogger.log("[MarkdownStreamManager] released holder id=\(String(messageId.prefix(8))) remaining=\(holders.count)", category: .markdown)
        }
    }

    func releaseAll() {
        for (_, holder) in holders {
            holder.reset()
        }
        holders.removeAll()
        AppLogger.log("[MarkdownStreamManager] released all", category: .markdown)
    }
}
