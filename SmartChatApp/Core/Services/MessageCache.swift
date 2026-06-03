import Foundation
import OpenClawKit
import OpenClawChatUI

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
            return cached
        }
        let messages = loadFromDisk(for: sessionKey)
        cache[sessionKey] = messages
        return messages
    }

    /// Sets messages - merges with existing cache to preserve historical messages, avoids duplicates
    func setMessages(_ messages: [OpenClawChatMessage], for sessionKey: String) {
        let existing = loadFromDisk(for: sessionKey)
        var merged: [OpenClawChatMessage] = []

        // Deduplicate: prefer existing (cached) messages over new ones
        // This preserves historical messages during page loads
        for msg in messages {
            let id = msg.id.uuidString
            let existingHasId = existing.contains { $0.id.uuidString == id }
            if !existingHasId {
                merged.append(msg)
            }
        }

        // Combine: existing + new messages, sorted by timestamp ascending, trim to maxLocalMessages (oldest)
        var allMessages = existing + merged
        allMessages.sort { ($0.timestamp ?? 0) < ($1.timestamp ?? 0) }
        if allMessages.count > maxLocalMessages {
            allMessages = Array(allMessages.suffix(maxLocalMessages))
        }

        cache[sessionKey] = allMessages
        saveToDisk(allMessages, for: sessionKey)
    }

    /// Appends new streaming messages - deduplicates by id
    func appendMessages(_ newMessages: [OpenClawChatMessage], for sessionKey: String) {
        var existing = cache[sessionKey] ?? loadFromDisk(for: sessionKey)
        for newMsg in newMessages {
            if !existing.contains(where: { $0.id == newMsg.id }) {
                existing.append(newMsg)
            }
        }
        let trimmed = Array(existing.suffix(maxLocalMessages))
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
        cache.removeAll()
        let keys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(keyPrefix) }
        for key in keys {
            defaults.removeObject(forKey: key)
        }
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
