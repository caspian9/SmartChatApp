import Foundation
import OpenClawChatUI

@MainActor
@Observable
public final class MessageCacheStore {
    public static let shared = MessageCacheStore(storage: MessageCacheStorage.shared)

    @ObservationIgnored
    private let storage: MessageCacheStorageProtocol

    private(set) var messagesBySession: [String: [OpenClawChatMessage]] = [:]
    private(set) var lastSeenTimestampBySession: [String: Double] = [:]
    private var hydratedSessions: Set<String> = []

    public init(storage: MessageCacheStorageProtocol) {
        self.storage = storage
    }

    // —— query(sync,@MainActor)——

    public func messages(for sessionKey: String, since: Double? = nil) -> [OpenClawChatMessage] {
        let all = messagesBySession[sessionKey] ?? []
        guard let since else { return all }
        return all.filter { ($0.timestamp ?? 0) > since }
    }

    public func lastSeenTimestamp(for sessionKey: String) -> Double? {
        lastSeenTimestampBySession[sessionKey]
    }

    public func isHydrated(for sessionKey: String) -> Bool {
        hydratedSessions.contains(sessionKey)
    }

    // —— 写入(async,委托 storage)—— Task 6/7 实现

    public func hydrate(for sessionKey: String) async {
        let loaded = await storage.load(for: sessionKey)
        messagesBySession[sessionKey] = loaded
        hydratedSessions.insert(sessionKey)
    }

    public func append(_ messages: [OpenClawChatMessage], for sessionKey: String) async {
        guard !messages.isEmpty else { return }
        // 防御:如果内存没 hydrate,先 hydrate
        if !isHydrated(for: sessionKey) {
            let loaded = await storage.load(for: sessionKey)
            messagesBySession[sessionKey] = loaded
            hydratedSessions.insert(sessionKey)
        }
        // 委托 storage dedup + 写盘
        await storage.append(messages, for: sessionKey)
        // 重新从 storage 拿全量(dedup 后),更新内存
        let updated = await storage.load(for: sessionKey)
        messagesBySession[sessionKey] = updated
        // 推进 lastSeenTimestamp
        if let newMax = updated.compactMap(\.timestamp).max() {
            let current = lastSeenTimestampBySession[sessionKey] ?? 0
            if newMax > current {
                lastSeenTimestampBySession[sessionKey] = newMax
            }
        }
    }
    public func clear(for sessionKey: String) async {
        await storage.clear(for: sessionKey)
        messagesBySession[sessionKey] = []
        lastSeenTimestampBySession[sessionKey] = nil
        hydratedSessions.remove(sessionKey)
    }

    public func clearAll() async {
        await storage.clearAll()
        messagesBySession.removeAll()
        lastSeenTimestampBySession.removeAll()
        hydratedSessions.removeAll()
    }
}
