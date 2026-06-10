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

    public func append(_ messages: [OpenClawChatMessage], for sessionKey: String) async {}
    public func clear(for sessionKey: String) async {}
    public func clearAll() async {}
}
