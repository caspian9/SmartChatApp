import Foundation
import OpenClawChatUI
import CryptoKit

public protocol MessageCacheStorageProtocol: Sendable {
    /// Synchronous load. Reads UserDefaults directly. Use this from
    /// the @MainActor store for the *initial* hydrate on session
    /// entry, where blocking the main thread for one JSON decode
    /// is much cheaper than awaiting an actor hop (which serializes
    /// through the storage actor and may queue behind an in-flight
    /// `append`/`upsert` from streaming). The async `load(for:)`
    /// remains for callers that need the actor's in-memory cache
    /// (e.g. when the protocol implementation is not UserDefaults-backed
    /// in tests, or when the user wants to bypass any state that
    /// the async path may have mutated).
    func loadSync(for sessionKey: String) -> [OpenClawChatMessage]
    func load(for sessionKey: String) async -> [OpenClawChatMessage]
    /// Append with content-dedup. Returns the post-write array for
    /// the session so the caller (`MessageCacheStore`) can update
    /// its in-memory dict without re-reading from disk. The
    /// previous signature was `async` with no return value, which
    /// forced the store to do a second `await load(for:)` after
    /// every write to refresh its `messagesBySession` dict — a full
    /// JSON decode of the session's array on every streaming delta.
    /// For a 200-message session with ~100 streaming deltas, that
    /// was 100 redundant full-array decodes (~5-20ms each on a
    /// physical iPhone) serialized through the actor — a 500-2000ms
    /// cumulative main-thread-blocked latency budget. Returning
    /// the new state from the actor's already-locked critical
    /// section eliminates that re-read.
    func append(_ messages: [OpenClawChatMessage], for sessionKey: String) async -> [OpenClawChatMessage]
    /// Id-based upsert. For each input message, if an entry with the
    /// same `id` already exists in the session's array, replace it
    /// in place; otherwise append. Used by the streaming receive
    /// path (`MessageReceiver`) where every delta shares one
    /// `runId` but carries a longer cumulative text — `append`'s
    /// content-dedup would store all N copies (different texts),
    /// but `upsert` collapses them to a single entry whose text
    /// reflects the latest delta. Last-write-wins on text/timestamp;
    /// does NOT apply `append`'s content-dedup (two messages with
    /// the same text but different ids are both kept). Returns the
    /// post-write array — see `append` for the no-re-read rationale.
    func upsert(_ messages: [OpenClawChatMessage], for sessionKey: String) async -> [OpenClawChatMessage]
    /// Authoritative-replace for `loadHistory`. Wipes every existing
    /// entry in the session and writes `messages` as the new sole
    /// contents. The server's response is treated as ground truth:
    /// streaming residue (id=client-runId, partial text), stale
    /// entries from prior app launches, and any other unrelated
    /// entries that the client wrote but the server doesn't
    /// re-emit are dropped. Use this on initial history load and
    /// pull-up refresh; use `append` for incremental ingest
    /// (e.g., the user-message sent through `GatewayChatTransport`).
    /// Returns the post-write array (which is `messages` after
    /// sort + cap) so the store doesn't re-read.
    func replaceForSession(_ messages: [OpenClawChatMessage], for sessionKey: String) async -> [OpenClawChatMessage]
    func clear(for sessionKey: String) async
    func clearAll() async
    func maxTimestamp(for sessionKey: String) async -> Double?
    func messageIds(for sessionKey: String) async -> Set<String>
    /// Aggregate stats across all session keys currently on disk.
    /// Returns `(sessionCount, messageCount)` — used by the Settings
    /// page to display "X messages (Y sessions)" next to the
    /// "Clear Message Cache" button. Implementations must scan
    /// every persisted session (not just hydrated ones) so the
    /// count reflects what is on disk, independent of which
    /// sessions the user has visited this launch.
    func stats() async -> (sessionCount: Int, messageCount: Int)
}

public actor MessageCacheStorage: MessageCacheStorageProtocol {
    public static let shared = MessageCacheStorage()

    private var cache: [String: [OpenClawChatMessage]] = [:]
    private let maxLocalMessages: Int
    /// `nonisolated` because `UserDefaults` is documented as
    /// thread-safe (Apple's docs: "UserDefaults is thread-safe"),
    /// and `loadSync(for:)` — called from `@MainActor` on the
    /// `MessageCacheStore` to avoid an actor hop on entry — is
    /// `nonisolated` itself. Marking this property `nonisolated`
    /// lets the sync read path touch it without crossing the
    /// actor boundary. Writes still serialize through the actor
    /// (only `saveToDisk` mutates UserDefaults from inside the
    /// actor's lock), so there is no race with concurrent writers.
    nonisolated private let defaults: UserDefaults
    nonisolated private let keyPrefix = "openclaw_messages_"

    public init(defaults: UserDefaults = .standard, maxLocalMessages: Int = 200) {
        self.defaults = defaults
        self.maxLocalMessages = maxLocalMessages
    }

    public nonisolated func loadSync(for sessionKey: String) -> [OpenClawChatMessage] {
        // Bypass the actor's in-memory cache: this method is the
        // entry-point that *populates* the cache, so reading from
        // `cache` first would defeat its purpose (and would race
        // any in-flight `append` from a different MainActor hop).
        // UserDefaults reads are thread-safe and the JSON decode
        // is the same code the async path takes, so callers get
        // identical results without the actor-hop latency.
        loadFromDisk(for: sessionKey)
    }

    public func load(for sessionKey: String) async -> [OpenClawChatMessage] {
        if let cached = cache[sessionKey] {
            return cached
        }
        let messages = loadFromDisk(for: sessionKey)
        cache[sessionKey] = messages
        return messages
    }

    public func append(_ messages: [OpenClawChatMessage], for sessionKey: String) async -> [OpenClawChatMessage] {
        var allMessages = await load(for: sessionKey)  // prefer in-memory cache
        let originalCount = allMessages.count

        var added = 0
        var deduped = 0
        var skippedEmpty = 0
        for msg in messages {
            if isEmptyTextPlaceholder(msg) {
                skippedEmpty += 1
                continue
            }
            let key = dedupKey(for: msg)
            if allMessages.contains(where: { dedupKey(for: $0) == key }) {
                // Dedup hit: KEEP the existing entry. The existing message's
                // `id` is preserved — important because consumers (e.g.
                // `CollapseStateCache.expandedMessageIds` keyed on the
                // streaming-time synthesized UUID) would otherwise lose
                // their state on a server re-fetch that returns the same
                // message with a server-assigned UUID. The content is
                // identical (by dedup key), so dropping the new copy
                // has no observable effect except id stability.
                deduped += 1
            } else {
                allMessages.append(msg)
                added += 1
            }
        }

        allMessages.sort { ($0.timestamp ?? 0) < ($1.timestamp ?? 0) }
        if allMessages.count > maxLocalMessages {
            allMessages = Array(allMessages.suffix(maxLocalMessages))
        }

        cache[sessionKey] = allMessages
        saveToDisk(allMessages, for: sessionKey)

        AppLogger.log(
            "[MessageCacheStorage append] sessionKey=\(String(sessionKey.prefix(8))) original=\(originalCount) added=\(added) deduped=\(deduped) skippedEmpty=\(skippedEmpty) final=\(allMessages.count)",
            category: .cache)
        return allMessages
    }

    // Placeholder — implementation lands in Task 3
    public func clear(for sessionKey: String) async {
        cache[sessionKey] = []
        defaults.removeObject(forKey: storageKey(for: sessionKey))
    }
    public func clearAll() async {
        cache.removeAll()
        let keys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(keyPrefix) }
        for key in keys {
            defaults.removeObject(forKey: key)
        }
    }
    public func maxTimestamp(for sessionKey: String) async -> Double? {
        let messages = await load(for: sessionKey)
        return messages.compactMap(\.timestamp).max()
    }
    public func messageIds(for sessionKey: String) async -> Set<String> {
        Set(await load(for: sessionKey).map { $0.id.uuidString })
    }
    public func stats() async -> (sessionCount: Int, messageCount: Int) {
        // Scan UserDefaults for every persisted session key. We can't
        // just iterate `cache` because that dict only contains
        // sessions this actor has loaded since launch — Settings
        // needs the disk-truth count, not the in-memory working set.
        var sessionCount = 0
        var messageCount = 0
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(keyPrefix) {
            sessionCount += 1
            if let data = defaults.data(forKey: key),
               let messages = try? JSONDecoder().decode([OpenClawChatMessage].self, from: data) {
                messageCount += messages.count
            }
            // A session whose entry can't decode still counts as a
            // session — the user can see it (and Clear All will
            // remove it). Reporting (0, 0) for an undecodable
            // session would understate the cache size.
        }
        return (sessionCount: sessionCount, messageCount: messageCount)
    }

    public func replaceForSession(_ messages: [OpenClawChatMessage], for sessionKey: String) async -> [OpenClawChatMessage] {
        // Defensive: do NOT wipe the session with an empty payload.
        // Weak-network responses can decode successfully but return
        // an empty `messages` array (intermittent gateway, response
        // truncated at the JSON layer, server-side pagination bug).
        // Without this guard, the user opens a chat, sees their
        // cached messages, then a refresh lands an empty response
        // and the in-memory + on-disk store is wiped — the view
        // shows nothing even though the connection is "connected".
        // Treat empty as "no new data" and keep what we have.
        guard !messages.isEmpty else {
            AppLogger.log(
                "[MessageCacheStorage replaceForSession] sessionKey=\(String(sessionKey.prefix(8))) SKIPPED: empty payload, keeping existing \(self.cache[sessionKey]?.count ?? -1) entries",
                category: .cache, level: .warning)
            return self.cache[sessionKey] ?? []
        }
        // Preserve the streaming-time `usage` (input / output /
        // cacheRead / cacheWrite tokens) when the server's history
        // response omits it. The server's `requestHistory` payload
        // does NOT include the `usage` block — usage is reported
        // only in the streaming `lifecycle=end` event, which the
        // client captures and writes to the in-memory cache via
        // `MessageCacheStorage.append` / `upsert`. A naive replace
        // (the previous behavior) overwrote those streamed entries
        // with the server's bare payloads, and the bubble's
        // "↑input ↓output ↑cacheRead ↓cacheWrite" footer silently
        // disappeared on the first refresh of any session.
        //
        // Matching strategy: text + role + timestamp within 1s
        // tolerance. The streaming `lifecycle=end` message and the
        // server's history message have the same final text and
        // close-enough timestamps; ids differ (runId vs server
        // UUID) so id-matching is not viable. `dedupKey` includes
        // usage in its hash, so a server message with no usage
        // would never match a client message with full usage —
        // hence the explicit text/role/timestamp match below.
        let existing = cache[sessionKey] ?? []
        var sorted = messages
        sorted.sort { ($0.timestamp ?? 0) < ($1.timestamp ?? 0) }
        if sorted.count > maxLocalMessages {
            sorted = Array(sorted.suffix(maxLocalMessages))
        }
        if !existing.isEmpty {
            var preservedCount = 0
            sorted = sorted.map { incoming in
                guard incoming.usage == nil else { return incoming }
                guard let newText = incoming.content.first?.text,
                      let newTs = incoming.timestamp else { return incoming }
                if let match = existing.first(where: { old in
                    guard old.role == incoming.role else { return false }
                    guard let oldText = old.content.first?.text else { return false }
                    guard oldText == newText else { return false }
                    guard let oldTs = old.timestamp else { return false }
                    return abs(oldTs - newTs) < 1000
                }), let oldUsage = match.usage {
                    preservedCount += 1
                    // `OpenClawChatMessage.usage` is `let` (immutable
                    // by design — message content is treated as a
                    // value snapshot). Construct a fresh message
                    // with the streamed usage spliced in via the
                    // explicit memberwise init; all other fields
                    // carry over from the server's payload.
                    return OpenClawChatMessage(
                        id: incoming.id,
                        role: incoming.role,
                        content: incoming.content,
                        timestamp: incoming.timestamp,
                        toolCallId: incoming.toolCallId,
                        toolName: incoming.toolName,
                        usage: oldUsage,
                        stopReason: incoming.stopReason,
                        errorMessage: incoming.errorMessage,
                        seq: incoming.seq,
                        startedAt: incoming.startedAt,
                        endedAt: incoming.endedAt,
                        state: incoming.state
                    )
                }
                return incoming
            }
            if preservedCount > 0 {
                AppLogger.log(
                    "[MessageCacheStorage replaceForSession] sessionKey=\(String(sessionKey.prefix(8))) preserved usage from \(preservedCount) streaming entries (server payload omitted usage block)",
                    category: .cache)
            }
        }
        cache[sessionKey] = sorted
        saveToDisk(sorted, for: sessionKey)
        AppLogger.log(
            "[MessageCacheStorage replaceForSession] sessionKey=\(String(sessionKey.prefix(8))) wiped=1 wrote=\(sorted.count)",
            category: .cache)
        return sorted
    }

    public func upsert(_ messages: [OpenClawChatMessage], for sessionKey: String) async -> [OpenClawChatMessage] {
        var allMessages = await load(for: sessionKey)
        var replaced = 0
        var added = 0
        var skippedEmpty = 0
        for msg in messages {
            if isEmptyTextPlaceholder(msg) {
                // Allow empty-text placeholders in the upsert path —
                // the EventInterpreter creates a `text=""` entry on
                // `lifecycle=start` so the view can render a typing
                // indicator before the first delta arrives. Without
                // this bypass, the placeholder is dropped and the
                // user sees an empty gap between sending and the
                // first text delta landing. The `append` path keeps
                // the filter — historical loads shouldn't carry
                // empty entries.
                allMessages.removeAll { $0.id == msg.id }
                allMessages.append(msg)
                added += 1
                skippedEmpty += 1
                continue
            }
            if let idx = allMessages.firstIndex(where: { $0.id == msg.id }) {
                allMessages[idx] = msg
                replaced += 1
            } else {
                allMessages.append(msg)
                added += 1
            }
        }
        allMessages.sort { ($0.timestamp ?? 0) < ($1.timestamp ?? 0) }
        if allMessages.count > maxLocalMessages {
            allMessages = Array(allMessages.suffix(maxLocalMessages))
        }
        cache[sessionKey] = allMessages
        saveToDisk(allMessages, for: sessionKey)
        AppLogger.log(
            "[MessageCacheStorage upsert] sessionKey=\(String(sessionKey.prefix(8))) replaced=\(replaced) added=\(added) skippedEmpty=\(skippedEmpty) final=\(allMessages.count)",
            category: .cache)
        return allMessages
    }

    private nonisolated func storageKey(for sessionKey: String) -> String {
        "\(keyPrefix)\(sessionKey)"
    }

    private nonisolated func loadFromDisk(for sessionKey: String) -> [OpenClawChatMessage] {
        // `nonisolated` so `loadSync(for:)` (also nonisolated) can
        // call it. The body only touches `defaults` (UserDefaults is
        // thread-safe) and `storageKey` (pure function), so there's
        // no actor-isolation requirement. The async `load(for:)`
        // continues to use this same method.
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

    // Internal helper — ported from the old MessageCache.swift:79-107
    private func dedupKey(for message: OpenClawChatMessage) -> String {
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

    private func isEmptyTextPlaceholder(_ message: OpenClawChatMessage) -> Bool {
        let rawText = message.content.compactMap { $0.text }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return rawText.isEmpty
    }
}
