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

    init(messageId: String) {
        self.messageId = messageId
        self.view = MarkdownViewTextKit()
        self.view.enableTypewriterEffect = false
        var config = MarkdownConfiguration.default
        config.typewriterTextMode = .append
        config.typewriterHeightUpdateInterval = 20
        config.streamMinModuleLength = 20
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

    func append(_ chunk: String) {
        guard hasBegun, !isEnded else {
            os_log("SMAlog: [MarkdownHolder] append() skipped (not begun/ended) id=%{public}s", log: managerLog, type: .debug, String(messageId.prefix(8)))
            return
        }
        view.appendStreamData(chunk)
        os_log("SMAlog: [MarkdownHolder] append() id=%{public}s chunk_len=%{public}d", log: managerLog, type: .debug, String(messageId.prefix(8)), chunk.count)
    }

    func end() {
        guard hasBegun, !isEnded else {
            os_log("SMAlog: [MarkdownHolder] end() skipped (not begun/already ended) id=%{public}s", log: managerLog, type: .debug, String(messageId.prefix(8)))
            return
        }
        isEnded = true
        view.endRealStreaming()
        os_log("SMAlog: [MarkdownHolder] end() id=%{public}s", log: managerLog, type: .debug, String(messageId.prefix(8)))
    }

    /// Reset for reuse - call when re-entering a message that may have leftover state
    func reset() {
        if hasBegun && !isEnded {
            view.endRealStreaming()
        }
        hasBegun = false
        isEnded = false
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

    func append(messageId: String, chunk: String) {
        guard let holder = holders[messageId] else {
            os_log("SMAlog: [MarkdownStreamManager] append() no holder id=%{public}s", log: managerLog, type: .debug, String(messageId.prefix(8)))
            return
        }
        holder.append(chunk)
    }

    func end(messageId: String) {
        holders[messageId]?.end()
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
