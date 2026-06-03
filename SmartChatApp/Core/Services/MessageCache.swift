import Foundation
import OpenClawKit
import OpenClawChatUI

actor MessageCache {
    static let shared = MessageCache()

    private var cache: [String: [OpenClawChatMessage]] = [:]
    private let maxLocalMessages = 100

    func getMessages(for sessionKey: String) -> [OpenClawChatMessage] {
        cache[sessionKey] ?? []
    }

    func setMessages(_ messages: [OpenClawChatMessage], for sessionKey: String) {
        cache[sessionKey] = Array(messages.suffix(maxLocalMessages))
    }

    func appendMessages(_ newMessages: [OpenClawChatMessage], for sessionKey: String) {
        var existing = cache[sessionKey] ?? []
        for newMsg in newMessages {
            if !existing.contains(where: { $0.id == newMsg.id }) {
                existing.append(newMsg)
            }
        }
        cache[sessionKey] = Array(existing.suffix(maxLocalMessages))
    }

    func clear(for sessionKey: String) {
        cache[sessionKey] = nil
    }

    func clearAll() {
        cache.removeAll()
    }
}
