import Foundation
import OpenClawChatUI
import os
@testable import SmartChatApp

final class FakeMessageCacheStorage: MessageCacheStorageProtocol, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<[String: [OpenClawChatMessage]]>(initialState: [:])

    init() {}

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
                all.append(msg)
            }
            all.sort { ($0.timestamp ?? 0) < ($1.timestamp ?? 0) }
            // No cap — the persistent cache dropped the 200-entry
            // cap so user-managed sessions can grow without silent
            // oldest-entry eviction.
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
            // No cap — mirrors `append` above.
            state[sessionKey] = all
            return all
        }
        return result
    }

    func clear(for sessionKey: String) async {
        lock.withLock { $0[sessionKey] = [] }
    }

    /// Legacy authoritative-replace method. The persistence plan
    /// removes this from the protocol once the
    /// `MessageCacheStore` migration lands; for now this stub
    /// preserves protocol conformance for the test mock by
    /// delegating to `append`. The dedup behavior is equivalent
    /// for the test cases that exercise this path.
    func replaceForSession(_ messages: [OpenClawChatMessage], for sessionKey: String) async -> [OpenClawChatMessage] {
        return await append(messages, for: sessionKey)
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

    // No-op for the fake: the in-memory dict IS the
    // authoritative state, and `append` / `upsert` write to it
    // synchronously. No debounce window to drain.
    func flushPendingWrites() async {}
}
