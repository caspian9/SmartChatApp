import Foundation

struct CachedSessions: Codable {
    let sessions: [OpenClawChatSessionEntry]
    let timestamp: Date
    let version: Int

    static let currentVersion = 1
}

enum SessionCache {
    private static let key = "cached_sessions"

    static func save(_ sessions: [OpenClawChatSessionEntry]) {
        let cached = CachedSessions(
            sessions: sessions,
            timestamp: Date(),
            version: CachedSessions.currentVersion
        )
        if let data = try? JSONEncoder().encode(cached) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func load() -> [OpenClawChatSessionEntry]? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let cached = try? JSONDecoder().decode(CachedSessions.self, from: data),
              cached.version == CachedSessions.currentVersion else {
            return nil
        }
        return cached.sessions
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}