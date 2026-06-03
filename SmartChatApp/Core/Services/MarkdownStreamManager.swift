import Foundation
import UIKit
import MarkdownDisplayView
import OSLog

private let managerLog = OSLog(subsystem: "SmartChatApp.MarkdownStreamManager", category: "debug")

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
            os_log("SMAlog: [MarkdownHolder] begin() skipped (already begun) id=%{public}s", log: managerLog, type: .debug, String(messageId.prefix(8)))
            return
        }
        hasBegun = true
        view.beginRealStreaming(autoScrollBottom: false, useSmartBuffer: true)
        os_log("SMAlog: [MarkdownHolder] begin() id=%{public}s", log: managerLog, type: .debug, String(messageId.prefix(8)))
    }

    /// Server delivers full cumulative text on every chunk. Compute the
    /// incremental suffix relative to what we've already appended and feed
    /// only that to the TextKit view.
    /// - Returns the suffix that was appended (for callers that want to log it).
    @discardableResult
    func appendCumulative(_ cumulative: String) -> String {
        guard hasBegun, !isEnded else {
            os_log("SMAlog: [MarkdownHolder] appendCumulative skipped (not begun/ended) id=%{public}s", log: managerLog, type: .debug, String(messageId.prefix(8)))
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
            os_log("SMAlog: [MarkdownHolder] cumulative does not extend prev id=%{public}s prev_len=%{public}d new_len=%{public}d", log: managerLog, type: .debug, String(messageId.prefix(8)), lastReceivedText.count, cumulative.count)
            suffix = cumulative
        }
        lastReceivedText = cumulative
        if !suffix.isEmpty {
            view.appendStreamData(suffix)
            os_log("SMAlog: [MarkdownHolder] appendCumulative id=%{public}s suffix_len=%{public}d total_len=%{public}d", log: managerLog, type: .debug, String(messageId.prefix(8)), suffix.count, cumulative.count)
        }
        return suffix
    }

    func end() {
        guard hasBegun, !isEnded else {
            os_log("SMAlog: [MarkdownHolder] end() skipped (not begun/already ended) id=%{public}s", log: managerLog, type: .debug, String(messageId.prefix(8)))
            return
        }
        isEnded = true
        view.endRealStreaming()
        os_log("SMAlog: [MarkdownHolder] end() id=%{public}s final_len=%{public}d", log: managerLog, type: .debug, String(messageId.prefix(8)), lastReceivedText.count)
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
        os_log("SMAlog: [MarkdownStreamManager] created holder id=%{public}s total=%{public}d", log: managerLog, type: .debug, String(messageId.prefix(8)), holders.count)
        return new
    }

    func begin(messageId: String) {
        holders[messageId]?.begin()
    }

    func appendCumulative(messageId: String, cumulative: String) {
        guard let holder = holders[messageId] else {
            os_log("SMAlog: [MarkdownStreamManager] appendCumulative no holder id=%{public}s", log: managerLog, type: .debug, String(messageId.prefix(8)))
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
            os_log("SMAlog: [MarkdownStreamManager] released holder id=%{public}s remaining=%{public}d", log: managerLog, type: .debug, String(messageId.prefix(8)), holders.count)
        }
    }

    func releaseAll() {
        for (_, holder) in holders {
            holder.reset()
        }
        holders.removeAll()
        os_log("SMAlog: [MarkdownStreamManager] released all", log: managerLog, type: .debug)
    }
}
