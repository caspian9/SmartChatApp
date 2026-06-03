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

    /// Sets messages - merges new messages with existing cache
    /// Uses content hash to detect genuinely new messages (not duplicates)
    func setMessages(_ messages: [OpenClawChatMessage], for sessionKey: String) {
        let existing = loadFromDisk(for: sessionKey)

        // Calculate dedup keys for existing messages
        let existingKeys = Set(existing.map { dedupKey(for: $0) })

        // Find genuinely new messages (not in cache)
        var newMessages: [OpenClawChatMessage] = []
        for msg in messages {
            let key = dedupKey(for: msg)
            if !existingKeys.contains(key) {
                newMessages.append(msg)
            }
        }

        os_log("SMAlog: [MessageCache setMessages] sessionKey=%{public}s existing.count=%{public}d newMessages.count=%{public}d totalInput=%{public}d", log: osLog, type: .debug, String(sessionKey.prefix(8)), existing.count, newMessages.count, messages.count)

        // Merge: keep existing + add genuinely new messages
        var allMessages = existing + newMessages
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
    /// Includes timestamp and usage so a streaming message that later gains
    /// final usage tokens isn't collapsed against the earlier streaming copy,
    /// and so two messages that share role+text but land at different times
    /// are treated as distinct entries.
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

        let timestamp = message.timestamp.map { String($0) } ?? "-"
        let usage = message.usage.map { u in
            "\(u.input ?? 0),\(u.output ?? 0),\(u.cacheRead ?? 0),\(u.cacheWrite ?? 0),\(u.total ?? 0)"
        } ?? "-"

        let data = "\(message.role)|\(textForHash)|\(timestamp)|\(usage)".data(using: .utf8) ?? Data()
        let hash = SHA256.hash(data: data)
        return hash.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Appends new streaming messages - deduplicates by content-based key
    func appendMessages(_ newMessages: [OpenClawChatMessage], for sessionKey: String) {
        var existing = cache[sessionKey] ?? loadFromDisk(for: sessionKey)
        os_log("SMAlog: [MessageCache appendMessages] sessionKey=%{public}s existing.count=%{public}d newMessages.count=%{public}d", log: osLog, type: .debug, String(sessionKey.prefix(8)), existing.count, newMessages.count)
        for newMsg in newMessages {
            let key = dedupKey(for: newMsg)
            if !existing.contains(where: { dedupKey(for: $0) == key }) {
                existing.append(newMsg)
            }
        }
        let trimmed = Array(existing.suffix(maxLocalMessages))
        os_log("SMAlog: [MessageCache appendMessages] final count=%{public}d", log: osLog, type: .debug, trimmed.count)
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
