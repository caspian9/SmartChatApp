import Foundation
import OpenClawChatUI

struct CachedSessions: Codable {
    let sessions: [OpenClawChatSessionEntry]
    let timestamp: Date
    let version: Int

    static let currentVersion = 1
}

enum SessionCache {
    private static let keyPrefix = "cached_sessions_"

    private static func key(for profileId: UUID) -> String {
        keyPrefix + profileId.uuidString
    }

    static func save(_ sessions: [OpenClawChatSessionEntry], for profileId: UUID) {
        let cached = CachedSessions(
            sessions: sessions,
            timestamp: Date(),
            version: CachedSessions.currentVersion
        )
        if let data = try? JSONEncoder().encode(cached) {
            UserDefaults.standard.set(data, forKey: key(for: profileId))
        }
    }

    static func load(for profileId: UUID) -> [OpenClawChatSessionEntry]? {
        guard let data = UserDefaults.standard.data(forKey: key(for: profileId)),
              let cached = try? JSONDecoder().decode(CachedSessions.self, from: data),
              cached.version == CachedSessions.currentVersion else {
            return nil
        }
        return cached.sessions
    }

    static func clear(for profileId: UUID) {
        UserDefaults.standard.removeObject(forKey: key(for: profileId))
    }

    static func clearAll() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(keyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    static func totalSessionCount() -> Int {
        let defaults = UserDefaults.standard
        var count = 0
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(keyPrefix) {
            guard let data = defaults.data(forKey: key),
                  let cached = try? JSONDecoder().decode(CachedSessions.self, from: data),
                  cached.version == CachedSessions.currentVersion else {
                continue
            }
            count += cached.sessions.count
        }
        return count
    }
}
