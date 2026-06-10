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

    func load(for sessionKey: String) async -> [OpenClawChatMessage] {
        lock.withLock { $0[sessionKey] ?? [] }
    }

    func append(_ messages: [OpenClawChatMessage], for sessionKey: String) async {
        lock.withLock { state in
            var all = state[sessionKey] ?? []
            for msg in messages {
                // 简化:fake 不做 dedup,直接 append
                all.append(msg)
            }
            all.sort { ($0.timestamp ?? 0) < ($1.timestamp ?? 0) }
            if all.count > maxLocalMessages {
                all = Array(all.suffix(maxLocalMessages))
            }
            state[sessionKey] = all
        }
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
}
