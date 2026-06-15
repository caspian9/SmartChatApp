import Foundation
import OpenClawChatUI
import os
@testable import SmartChatApp

final class FakeMessageCacheStorage: MessageCacheStorageProtocol, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<[String: [OpenClawChatMessage]]>(initialState: [:])
    private let maxLocalMessages: Int

    init(maxLocalMessages: Int = 200) {
        self.maxLocalMessages = maxLocalMessages
    }

    func loadSync(for sessionKey: String) -> [OpenClawChatMessage] {
        lock.withLock { $0[sessionKey] ?? [] }
    }

    func load(for sessionKey: String) async -> [OpenClawChatMessage] {
        lock.withLock { $0[sessionKey] ?? [] }
    }

    func append(_ messages: [OpenClawChatMessage], for sessionKey: String) async -> [OpenClawChatMessage] {
        let result: [OpenClawChatMessage] = lock.withLock { state in
            var all = state[sessionKey] ?? []
            for msg in messages {
                // Simplified: fake doesn't dedup, just appends.
                all.append(msg)
            }
            all.sort { ($0.timestamp ?? 0) < ($1.timestamp ?? 0) }
            if all.count > maxLocalMessages {
                all = Array(all.suffix(maxLocalMessages))
            }
            state[sessionKey] = all
            return all
        }
        return result
    }

    func upsert(_ messages: [OpenClawChatMessage], for sessionKey: String) async -> [OpenClawChatMessage] {
        let result: [OpenClawChatMessage] = lock.withLock { state in
            var all = state[sessionKey] ?? []
            for msg in messages {
                if let idx = all.firstIndex(where: { $0.id == msg.id }) {
                    all[idx] = msg
                } else {
                    all.append(msg)
                }
            }
            all.sort { ($0.timestamp ?? 0) < ($1.timestamp ?? 0) }
            if all.count > maxLocalMessages {
                all = Array(all.suffix(maxLocalMessages))
            }
            state[sessionKey] = all
            return all
        }
        return result
    }

    func replaceForSession(_ messages: [OpenClawChatMessage], for sessionKey: String) async -> [OpenClawChatMessage] {
        let result: [OpenClawChatMessage] = lock.withLock { state in
            var sorted = messages
            sorted.sort { ($0.timestamp ?? 0) < ($1.timestamp ?? 0) }
            if sorted.count > maxLocalMessages {
                sorted = Array(sorted.suffix(maxLocalMessages))
            }
            state[sessionKey] = sorted
            return sorted
        }
        return result
    }

    func clear(for sessionKey: String) async {
        lock.withLock { $0[sessionKey] = [] }
    }

    func clearAll() async {
        lock.withLock { $0.removeAll() }
    }

    func maxTimestamp(for sessionKey: String) async -> Double? {
        await load(for: sessionKey).compactMap(\.timestamp).max()
    }

    func messageIds(for sessionKey: String) async -> Set<String> {
        Set(await load(for: sessionKey).map { $0.id.uuidString })
    }

    func stats() async -> (sessionCount: Int, messageCount: Int) {
        let snapshot = lock.withLock { $0 }
        let messageCount = snapshot.values.reduce(0) { $0 + $1.count }
        return (sessionCount: snapshot.count, messageCount: messageCount)
    }
}
