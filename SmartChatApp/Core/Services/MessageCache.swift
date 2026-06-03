import Foundation
import OpenClawKit
import OpenClawChatUI

actor MessageCache {
    static let shared = MessageCache()

    private var cache: [String: [OpenClawChatMessage]] = [:]
    private let maxLocalMessages = 100
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

    func setMessages(_ messages: [OpenClawChatMessage], for sessionKey: String) {
        let trimmed = Array(messages.suffix(maxLocalMessages))
        cache[sessionKey] = trimmed
        saveToDisk(trimmed, for: sessionKey)
    }

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
        Set(getMessages(for: sessionKey).compactMap { $0.id.uuidString })
    }

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
