import Foundation
import OpenClawChatUI
import CryptoKit

public actor MessageCacheStorage {
    public static let shared = MessageCacheStorage()

    private var cache: [String: [OpenClawChatMessage]] = [:]
    private let maxLocalMessages: Int
    private let defaults: UserDefaults
    private let keyPrefix = "openclaw_messages_"

    public init(defaults: UserDefaults = .standard, maxLocalMessages: Int = 200) {
        self.defaults = defaults
        self.maxLocalMessages = maxLocalMessages
    }

    public func load(for sessionKey: String) -> [OpenClawChatMessage] {
        if let cached = cache[sessionKey] {
            return cached
        }
        let messages = loadFromDisk(for: sessionKey)
        cache[sessionKey] = messages
        return messages
    }

    // 占位 - Task 2 实现
    public func append(_ messages: [OpenClawChatMessage], for sessionKey: String) {}

    // 占位 - Task 3 实现
    public func clear(for sessionKey: String) {}
    public func clearAll() {}
    public func maxTimestamp(for sessionKey: String) -> Double? { return nil }
    public func messageIds(for sessionKey: String) -> Set<String> { return [] }

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
    fileprivate func dedupKey(for message: OpenClawChatMessage) -> String {
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

    fileprivate func isEmptyTextPlaceholder(_ message: OpenClawChatMessage) -> Bool {
        let rawText = message.content.compactMap { $0.text }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return rawText.isEmpty
    }
}
