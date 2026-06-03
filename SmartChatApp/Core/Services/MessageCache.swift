import Foundation
import OpenClawKit
import OpenClawChatUI
import OSLog
import CryptoKit

private let osLog = OSLog(subsystem: "SmartChatApp", category: "MessageCache")

actor MessageCache {
    static let shared = MessageCache()

    private var cache: [String: [OpenClawChatMessage]] = [:]
    private let maxLocalMessages = 200
    private let defaults = UserDefaults.standard
    private let keyPrefix = "openclaw_messages_"

    private func storageKey(for sessionKey: String) -> String {
        "\(keyPrefix)\(sessionKey)"
    }

    func getMessages(for sessionKey: String) -> [OpenClawChatMessage] {
        if let cached = cache[sessionKey] {
            os_log("SMAlog: [MessageCache getMessages] sessionKey=%{public}s returning=%{public}d from_memory", log: osLog, type: .debug, String(sessionKey.prefix(8)), cached.count)
            return cached
        }
        let messages = loadFromDisk(for: sessionKey)
        os_log("SMAlog: [MessageCache getMessages] sessionKey=%{public}s returning=%{public}d from_disk", log: osLog, type: .debug, String(sessionKey.prefix(8)), messages.count)
        cache[sessionKey] = messages
        return messages
    }

    /// Sets messages - merges new messages with existing cache.
    /// REPLACE strategy: when a new message has the same content+timestamp
    /// bucket as an existing one, the existing entry is replaced (the new
    /// copy is more authoritative, e.g. the server's version of a message
    /// we previously wrote locally on send). New messages are appended.
    /// Skips empty-text placeholders (streaming-final has empty text; the
    /// real copy with full text arrives from history).
    func setMessages(_ messages: [OpenClawChatMessage], for sessionKey: String) {
        var allMessages = loadFromDisk(for: sessionKey)
        let originalCount = allMessages.count

        var added = 0
        var replaced = 0
        var skippedEmpty = 0
        for msg in messages {
            if isEmptyTextPlaceholder(msg) {
                skippedEmpty += 1
                continue
            }
            let key = dedupKey(for: msg)
            if let existingIndex = allMessages.firstIndex(where: { dedupKey(for: $0) == key }) {
                allMessages[existingIndex] = msg
                replaced += 1
            } else {
                allMessages.append(msg)
                added += 1
            }
        }

        os_log("SMAlog: [MessageCache setMessages] sessionKey=%{public}s original=%{public}d added=%{public}d replaced=%{public}d skippedEmpty=%{public}d totalInput=%{public}d", log: osLog, type: .debug, String(sessionKey.prefix(8)), originalCount, added, replaced, skippedEmpty, messages.count)

        allMessages.sort { ($0.timestamp ?? 0) < ($1.timestamp ?? 0) }
        if allMessages.count > maxLocalMessages {
            allMessages = Array(allMessages.suffix(maxLocalMessages))
        }

        os_log("SMAlog: [MessageCache setMessages] final allMessages.count=%{public}d", log: osLog, type: .debug, allMessages.count)

        cache[sessionKey] = allMessages
        saveToDisk(allMessages, for: sessionKey)
    }

    /// Content-based dedup key using content hash
    /// For toolCall/thinking/toolResult: uses first line only (stable across parameter order changes)
    /// For other roles: uses full text
    /// Uses a 10-second timestamp bucket so the same logical message
    /// collapses across sources (local user send with client clock vs.
    /// server fetch with server clock, even with a few seconds of
    /// network latency or clock skew). The accompanying REPLACE strategy
    /// ensures the server's authoritative copy wins on a history fetch.
    private func dedupKey(for message: OpenClawChatMessage) -> String {
        let rawText = message.content.compactMap { $0.text }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // For toolCall/thinking/toolResult: use first line only (action/command is stable, params vary)
        var textForHash = rawText
        if message.role == "toolCall" || message.role == "toolResult" || message.role == "thinking" {
            if let firstLine = rawText.split(separator: "\n", omittingEmptySubsequences: false).first {
                textForHash = String(firstLine).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Bucket the timestamp to 10-second resolution. Same logical
        // message from local send (client clock) and server fetch (server
        // clock) typically fall in the same bucket. Two distinct sends
        // of the same text are usually separated by more than 10s.
        let tsBucket: Int64 = {
            guard let ts = message.timestamp else { return -1 }
            return Int64(ts / 10_000) // ms -> 10s bucket
        }()

        let usage = message.usage.map { u in
            "\(u.input ?? 0),\(u.output ?? 0),\(u.cacheRead ?? 0),\(u.cacheWrite ?? 0),\(u.total ?? 0)"
        } ?? "-"

        let data = "\(message.role)|\(textForHash)|\(tsBucket)|\(usage)".data(using: .utf8) ?? Data()
        let hash = SHA256.hash(data: data)
        return hash.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Returns true if this is a streaming placeholder (empty text + has usage
    /// from `agent end`). The real copy with full text arrives from history;
    /// we don't want the empty placeholder to consume a cache slot.
    private func isEmptyTextPlaceholder(_ message: OpenClawChatMessage) -> Bool {
        let rawText = message.content.compactMap { $0.text }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return rawText.isEmpty
    }

    /// Appends new streaming messages - REPLACE on content match, otherwise add.
    /// Skips empty-text placeholders (streaming-final has empty text; the
    /// real copy with full text arrives from history).
    func appendMessages(_ newMessages: [OpenClawChatMessage], for sessionKey: String) {
        var existing = cache[sessionKey] ?? loadFromDisk(for: sessionKey)
        let originalCount = existing.count
        os_log("SMAlog: [MessageCache appendMessages] sessionKey=%{public}s existing.count=%{public}d newMessages.count=%{public}d", log: osLog, type: .debug, String(sessionKey.prefix(8)), existing.count, newMessages.count)
        var added = 0
        var replaced = 0
        var skippedEmpty = 0
        for newMsg in newMessages {
            if isEmptyTextPlaceholder(newMsg) {
                skippedEmpty += 1
                continue
            }
            let key = dedupKey(for: newMsg)
            if let existingIndex = existing.firstIndex(where: { dedupKey(for: $0) == key }) {
                existing[existingIndex] = newMsg
                replaced += 1
            } else {
                existing.append(newMsg)
                added += 1
            }
        }
        let trimmed = Array(existing.suffix(maxLocalMessages))
        os_log("SMAlog: [MessageCache appendMessages] original=%{public}d added=%{public}d replaced=%{public}d skippedEmpty=%{public}d final count=%{public}d", log: osLog, type: .debug, originalCount, added, replaced, skippedEmpty, trimmed.count)
        cache[sessionKey] = trimmed
        saveToDisk(trimmed, for: sessionKey)
    }

    func getLatestTimestamp(for sessionKey: String) -> Double? {
        cache[sessionKey]?.last?.timestamp ?? loadFromDisk(for: sessionKey).last?.timestamp
    }

    func hasNewMessages(for sessionKey: String, since timestamp: Double) -> Bool {
        guard let latest = getLatestTimestamp(for: sessionKey) else { return false }
        return latest > timestamp
    }

    func messageIds(for sessionKey: String) -> Set<String> {
        Set(getMessages(for: sessionKey).map { $0.id.uuidString })
    }

    /// Clears all cached messages for a session and disk storage
    func clear(for sessionKey: String) {
        cache[sessionKey] = nil
        defaults.removeObject(forKey: storageKey(for: sessionKey))
    }

    func clearAll() {
        os_log("SMAlog: [MessageCache clearAll] START", log: osLog, type: .debug)
        cache.removeAll()
        let keys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(keyPrefix) }
        os_log("SMAlog: [MessageCache clearAll] found %d keys to remove", log: osLog, type: .debug, keys.count)
        for key in keys {
            defaults.removeObject(forKey: key)
        }
        os_log("SMAlog: [MessageCache clearAll] DONE", log: osLog, type: .debug)
    }

    func getStats() -> (sessionCount: Int, messageCount: Int) {
        let keys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(keyPrefix) }
        var totalMessages = 0
        for key in keys {
            if let data = defaults.data(forKey: key),
               let messages = try? JSONDecoder().decode([OpenClawChatMessage].self, from: data) {
                totalMessages += messages.count
            }
        }
        return (sessionCount: keys.count, messageCount: totalMessages)
    }

    private func saveToDisk(_ messages: [OpenClawChatMessage], for sessionKey: String) {
        if let data = try? JSONEncoder().encode(messages) {
            defaults.set(data, forKey: storageKey(for: sessionKey))
        }
    }

    private func loadFromDisk(for sessionKey: String) -> [OpenClawChatMessage] {
        guard let data = defaults.data(forKey: storageKey(for: sessionKey)),
              let messages = try? JSONDecoder().decode([OpenClawChatMessage].self, from: data) else {
            return []
        }
        return messages
    }
}
