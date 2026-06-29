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
                // Mirror the production `MessageCacheStorage.append`
                // id-dedup contract (added in sub-task 1 of #36):
                // same id in cache → skip the new copy. We
                // intentionally do NOT mirror content-dedup here
                // because the existing `MessageCacheStoreTests`
                // rely on append admitting multiple same-text
                // entries (e.g., `test_append_updatesLastSeenTimestampToMax`
                // appends 3 same-text messages with different
                // timestamps and expects lastSeen to track the
                // max). The production storage's content-dedup is
                // covered by `MessageCacheStorageTests`; the fake
                // only needs id-dedup for `HistoryLoaderAppendTests`.
                if all.contains(where: { $0.id == msg.id }) {
                    continue
                }
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

    /// Authoritative-replace used by `HistoryLoader.fetchAndMergeFromNetwork`.
/// Faithfully simulates the production `MessageCacheStorage.replaceForSession`
/// wipe+replace semantics: clears the session first, then writes the
/// incoming messages as the new sole contents. This is critical for
/// `HistoryLoaderAppendTests` — they need the wipe to verify that
/// switching to `append` (issue #36) preserves client-only entries
/// that `replaceForSession` would have erased.
    func replaceForSession(_ messages: [OpenClawChatMessage], for sessionKey: String) async -> [OpenClawChatMessage] {
        let result: [OpenClawChatMessage] = lock.withLock { state in
            state[sessionKey] = messages
            return messages
        }
        return result
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

    func stats() async -> MessageCacheStats {
        let snapshot = lock.withLock { $0 }
        let messageCount = snapshot.values.reduce(0) { $0 + $1.count }
        // Mirror the production storage's span semantics: skip
        // nil timestamps (counting them as 0 would put nil entries
        // at the head of every span).
        let allTimestamps = snapshot.values
            .flatMap { $0.compactMap(\.timestamp) }
        return MessageCacheStats(
            sessionCount: snapshot.count,
            messageCount: messageCount,
            oldestTimestamp: allTimestamps.min(),
            newestTimestamp: allTimestamps.max()
        )
    }

    // No-op for the fake: the in-memory dict IS the
    // authoritative state, and `append` / `upsert` write to it
    // synchronously. No debounce window to drain.
    func flushPendingWrites() async {}
}
