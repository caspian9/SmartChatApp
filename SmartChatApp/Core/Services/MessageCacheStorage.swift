import Foundation
import OpenClawChatUI
import CryptoKit

public protocol MessageCacheStorageProtocol: Sendable {
    func load(for sessionKey: String) async -> [OpenClawChatMessage]
    func append(_ messages: [OpenClawChatMessage], for sessionKey: String) async
    func clear(for sessionKey: String) async
    func clearAll() async
    func maxTimestamp(for sessionKey: String) async -> Double?
    func messageIds(for sessionKey: String) async -> Set<String>
}

public actor MessageCacheStorage: MessageCacheStorageProtocol {
    public static let shared = MessageCacheStorage()

    private var cache: [String: [OpenClawChatMessage]] = [:]
    private let maxLocalMessages: Int
    private let defaults: UserDefaults
    private let keyPrefix = "openclaw_messages_"

    public init(defaults: UserDefaults = .standard, maxLocalMessages: Int = 200) {
        self.defaults = defaults
        self.maxLocalMessages = maxLocalMessages
    }

    public func load(for sessionKey: String) async -> [OpenClawChatMessage] {
        if let cached = cache[sessionKey] {
            return cached
        }
        let messages = loadFromDisk(for: sessionKey)
        cache[sessionKey] = messages
        return messages
    }

    public func append(_ messages: [OpenClawChatMessage], for sessionKey: String) async {
        var allMessages = await load(for: sessionKey)  // 内存优先
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

        allMessages.sort { ($0.timestamp ?? 0) < ($1.timestamp ?? 0) }
        if allMessages.count > maxLocalMessages {
            allMessages = Array(allMessages.suffix(maxLocalMessages))
        }

        cache[sessionKey] = allMessages
        saveToDisk(allMessages, for: sessionKey)

        AppLogger.log(
            "[MessageCacheStorage append] sessionKey=\(String(sessionKey.prefix(8))) original=\(originalCount) added=\(added) replaced=\(replaced) skippedEmpty=\(skippedEmpty) final=\(allMessages.count)",
            category: .cache)
    }

    // 占位 - Task 3 实现
    public func clear(for sessionKey: String) async {
        cache[sessionKey] = []
        defaults.removeObject(forKey: storageKey(for: sessionKey))
    }
    public func clearAll() async {
        cache.removeAll()
        let keys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(keyPrefix) }
        for key in keys {
            defaults.removeObject(forKey: key)
        }
    }
    public func maxTimestamp(for sessionKey: String) async -> Double? {
        let messages = await load(for: sessionKey)
        return messages.compactMap(\.timestamp).max()
    }
    public func messageIds(for sessionKey: String) async -> Set<String> {
        Set(await load(for: sessionKey).map { $0.id.uuidString })
    }

    private func storageKey(for sessionKey: String) -> String {
        "\(keyPrefix)\(sessionKey)"
    }

    private func loadFromDisk(for sessionKey: String) -> [OpenClawChatMessage] {
        guard let data = defaults.data(forKey: storageKey(for: sessionKey)),
              let messages = try? JSONDecoder().decode([OpenClawChatMessage].self, from: data) else {
            return []
        }
        return messages
    }

    private func saveToDisk(_ messages: [OpenClawChatMessage], for sessionKey: String) {
        if let data = try? JSONEncoder().encode(messages) {
            defaults.set(data, forKey: storageKey(for: sessionKey))
        }
    }

    // 内部 helper - 从旧 MessageCache.swift:79-107 搬过来
    private func dedupKey(for message: OpenClawChatMessage) -> String {
        let rawText = message.content.compactMap { $0.text }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var textForHash = rawText
        if message.role == "toolCall" || message.role == "toolResult" || message.role == "thinking" {
            if let firstLine = rawText.split(separator: "\n", omittingEmptySubsequences: false).first {
                textForHash = String(firstLine).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        let tsBucket: Int64 = {
            guard let ts = message.timestamp else { return -1 }
            return Int64(ts / 10_000)
        }()

        let usage = message.usage.map { u in
            "\(u.input ?? 0),\(u.output ?? 0),\(u.cacheRead ?? 0),\(u.cacheWrite ?? 0),\(u.total ?? 0)"
        } ?? "-"

        let data = "\(message.role)|\(textForHash)|\(tsBucket)|\(usage)".data(using: .utf8) ?? Data()
        let hash = SHA256.hash(data: data)
        return hash.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func isEmptyTextPlaceholder(_ message: OpenClawChatMessage) -> Bool {
        let rawText = message.content.compactMap { $0.text }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return rawText.isEmpty
    }
}
