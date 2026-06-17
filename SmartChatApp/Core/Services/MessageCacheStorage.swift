import Foundation
import OpenClawChatUI
import CryptoKit

/// JSON-serializable wrapper around `OpenClawChatMessage` that
/// preserves the message's `id` across the on-disk round-trip.
///
/// The SDK's `OpenClawChatMessage.CodingKeys` (ChatModels.swift)
/// OMITS `id` — only `role`, `content`, `timestamp`, `toolCallId`,
/// `toolName`, `usage`, `stopReason`, `errorMessage` are
/// persisted. The default `var id: UUID = .init()` regenerates
/// a fresh UUID on every decode, so without this wrapper:
///
///   1. App saves a message with `id = A`.
///   2. App restarts. Storage reads the JSON, decoder sees no
///      `id` key, falls back to `UUID()` → fresh `id = B`.
///   3. The view's `ForEach(messages, id: \.id)` re-creates the
///      bubble with a new identity, breaking the dedup contract
///      (KEEP-on-id in `MessageCacheStorage.upsert` /
///      `MessageReceiver.receiveMessage`) and invalidating
///      `CollapseStateCache.expandedMessageIds` (keyed on the
///      streaming-time synthesized UUID).
///
/// The fix is a 1-field envelope at the disk boundary. The
/// in-memory `cache` is still `[OpenClawChatMessage]` — the
/// envelope only appears in `loadFromDisk` / `saveToDisk` /
/// `stats`, which is the only place the SDK's broken encoding
/// bites us. Public API (protocol methods) still take and return
/// `[OpenClawChatMessage]`; the conversion is internal to the
/// actor.
struct PersistedMessageEnvelope: Codable, Sendable {
    /// The stable message id. Taken from `OpenClawChatMessage.id`
    /// at wrap time, restored to the same field at unwrap time.
    let id: UUID
    /// The SDK message itself. On disk this loses its `id`
    /// (SDK's CodingKeys omit it); on unwrap we restore `id`
    /// from the envelope above so the in-memory value matches
    /// what was written.
    let message: OpenClawChatMessage

    init(wrapping message: OpenClawChatMessage) {
        self.id = message.id
        self.message = message
    }

    /// Returns the SDK message with `id` restored from the
    /// envelope. The SDK's `id` is a `var` (declared with
    /// `= .init()` default), so we can mutate it post-decode.
    func unwrapped() -> OpenClawChatMessage {
        var msg = self.message
        msg.id = self.id
        return msg
    }
}

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
    ///
    /// NOTE: `loadSync` reads from disk. If there are pending
    /// debounced writes for `sessionKey`, the disk is stale
    /// until `flushPendingWrites()` runs. Callers that need the
    /// latest state should use the async `load(for:)` (which
    /// reads the in-memory cache) or call `flushPendingWrites()`
    /// first.
    func loadSync(for sessionKey: String) -> [OpenClawChatMessage]
    func load(for sessionKey: String) async -> [OpenClawChatMessage]
    /// Force-flush any debounced disk writes. The actor's
    /// `append` / `upsert` paths coalesce JSON encodes +
    /// UserDefaults writes across a 100ms window; this method
    /// bypasses the window and writes immediately. Use it from
    /// app-lifecycle hooks (backgrounding, termination) to
    /// ensure no in-memory state is lost, and from tests to
    /// verify the debounce leaves the correct on-disk shape
    /// after the flush.
    func flushPendingWrites() async
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
    ///
    /// DISK WRITE IS DEBOUNCED. The in-memory `cache[sessionKey]`
    /// is updated synchronously (so the returned array is always
    /// current) but the JSON encode + UserDefaults write is
    /// coalesced across multiple calls within a 100ms window. A
    /// single streaming run of 50 deltas now produces 1 disk
    /// write instead of 50. Call `flushPendingWrites()` to force
    /// a synchronous flush (tests + app-lifecycle hooks).
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
    /// post-write array — see `append` for the no-re-read rationale
    /// AND for the disk-write debounce (same 100ms coalesce window).
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
    /// Sessions with a pending (debounced) disk write. The actor
    /// coalesces multiple `append` / `upsert` calls within a
    /// 100ms window into a single JSON encode + UserDefaults
    /// write per session. A streaming run of 50 deltas no longer
    /// produces 50 disk writes — it produces 1 (assuming they
    /// land within the window). `flushPendingWrites()` drains
    /// the set immediately.
    private var pendingDiskWrites: Set<String> = []
    /// The single in-flight debounce task. `nil` when no
    /// pending writes; non-nil when at least one session has
    /// been queued and a `Task.sleep(100ms)` is in progress.
    /// The task is cancelled and rescheduled if a new write
    /// arrives during the window (extending the debounce).
    private var flushTask: Task<Void, Never>?
    /// How long to wait after the latest write before actually
    /// encoding + writing to UserDefaults. 100ms is a
    /// compromise: long enough to coalesce a streaming burst
    /// (50 deltas typically land within 1-2s of wall time but
    /// bunched into ~10 sub-bursts of 5 deltas each — 100ms
    /// covers each sub-burst), short enough that the in-memory
    /// vs. on-disk skew is imperceptible.
    private let diskWriteDebounce: Duration = .milliseconds(100)
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

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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

        cache[sessionKey] = allMessages
        // Debounced: see `scheduleDiskWrite(for:)` + the protocol
        // doc on `append`. The in-memory cache is up-to-date
        // immediately; the JSON encode + UserDefaults write is
        // coalesced across the debounce window.
        scheduleDiskWrite(for: sessionKey)

        AppLogger.log(
            "[MessageCacheStorage append] sessionKey=\(String(sessionKey.prefix(8))) original=\(originalCount) added=\(added) deduped=\(deduped) skippedEmpty=\(skippedEmpty) final=\(allMessages.count)",
            category: .cache)
        return allMessages
    }

    // Placeholder — implementation lands in Task 3
    public func clear(for sessionKey: String) async {
        cache[sessionKey] = []
        // Drop any pending debounced write for this session —
        // otherwise the in-flight flush task could resurrect
        // the just-cleared data from the (still-populated)
        // in-memory cache.
        pendingDiskWrites.remove(sessionKey)
        defaults.removeObject(forKey: storageKey(for: sessionKey))
    }
    public func clearAll() async {
        cache.removeAll()
        // Same reasoning as `clear(for:)` — pending debounced
        // writes would otherwise re-write the just-cleared
        // data from the in-memory cache. For clearAll we drop
        // ALL pending writes; the next `append` / `upsert` /
        // `replaceForSession` will re-queue.
        pendingDiskWrites.removeAll()
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
               let envelopes = try? JSONDecoder().decode([PersistedMessageEnvelope].self, from: data) {
                messageCount += envelopes.count
            }
            // A session whose entry can't decode still counts as a
            // session — the user can see it (and Clear All will
            // remove it). Reporting (0, 0) for an undecodable
            // session would understate the cache size. The decode
            // failure here is a clean break with the pre-envelope
            // format (older payloads were `[OpenClawChatMessage]`
            // without the `id` wrapper); those sessions silently
            // report as 0 messages but the count is still +1 for
            // the session itself. A future maintenance pass can
            // add a one-shot migration if the in-the-wild install
            // base has pre-envelope data to recover.
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
                        errorMessage: incoming.errorMessage
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
        var deduped = 0
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
            let key = dedupKey(for: msg)
            if allMessages.contains(where: { dedupKey(for: $0) == key && $0.id != msg.id }) {
                // Content-dedup hit (different ids, same content).
                // The streaming path can emit the same logical
                // message via different transport events
                // (`command_output stream=end`,
                // `item phase=end summary=...`, and the
                // trailer-augmented `command_output` end) with
                // different ids but identical content; without
                // this dedup all three land in the cache and the
                // user sees the same text 3x. KEEP the first
                // arrival (id stability > content authority, same
                // as `append`'s KEEP behavior).
                deduped += 1
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
        cache[sessionKey] = allMessages
        // Debounced (same as `append` above).
        scheduleDiskWrite(for: sessionKey)
        AppLogger.log(
            "[MessageCacheStorage upsert] sessionKey=\(String(sessionKey.prefix(8))) replaced=\(replaced) added=\(added) skippedEmpty=\(skippedEmpty) deduped=\(deduped) final=\(allMessages.count)",
            category: .cache)
        return allMessages
    }

    private nonisolated func storageKey(for sessionKey: String) -> String {
        "\(keyPrefix)\(sessionKey)"
    }

    /// Queue a disk write for `sessionKey` and ensure the
    /// debounce task is running. Called from `append` and
    /// `upsert`; `replaceForSession` / `clear` / `clearAll`
    /// intentionally write synchronously (destructive ops
    /// need to be durable immediately).
    private func scheduleDiskWrite(for sessionKey: String) {
        pendingDiskWrites.insert(sessionKey)
        if flushTask == nil {
            // No task in flight — start one. The task holds a
            // weak reference to the actor; if the actor is
            // deallocated mid-wait the task becomes a no-op.
            let debounce = diskWriteDebounce
            flushTask = Task { [weak self] in
                try? await Task.sleep(for: debounce)
                await self?.flushPendingWrites()
            }
        }
        // If a task is already in flight, we don't touch it —
        // its sleep is "the time since the last write" and
        // adding a new entry to `pendingDiskWrites` is enough.
        // The existing task's flush will pick up the new entry
        // when it fires.
    }

    /// Drain `pendingDiskWrites` synchronously. Called by the
    /// debounce task after the sleep, and exposed publicly for
    /// tests + app-lifecycle hooks (background / terminate).
    /// The flush is a snapshot-and-clear: takes the current
    /// set, clears it, then writes each session's latest cache
    /// state to disk. New writes that arrive during the flush
    /// are queued in a fresh `pendingDiskWrites` and will be
    /// picked up by a future debounce task (or by the next
    /// call to this method).
    public func flushPendingWrites() async {
        flushTask = nil
        let keys = pendingDiskWrites
        pendingDiskWrites.removeAll()
        for key in keys {
            guard let messages = cache[key] else { continue }
            saveToDisk(messages, for: key)
        }
    }

    private nonisolated func loadFromDisk(for sessionKey: String) -> [OpenClawChatMessage] {
        // `nonisolated` so `loadSync(for:)` (also nonisolated) can
        // call it. The body only touches `defaults` (UserDefaults is
        // thread-safe) and `storageKey` (pure function), so there's
        // no actor-isolation requirement. The async `load(for:)`
        // continues to use this same method.
        //
        // Decodes `[PersistedMessageEnvelope]` (not raw
        // `[OpenClawChatMessage]`) so the stable `id` survives
        // the round-trip. See the type doc on
        // `PersistedMessageEnvelope` for the rationale.
        guard let data = defaults.data(forKey: storageKey(for: sessionKey)),
              let envelopes = try? JSONDecoder().decode([PersistedMessageEnvelope].self, from: data) else {
            return []
        }
        return envelopes.map { $0.unwrapped() }
    }

    private func saveToDisk(_ messages: [OpenClawChatMessage], for sessionKey: String) {
        // Wrap each message in `PersistedMessageEnvelope` so the
        // stable `id` is part of the JSON encoding — the SDK's
        // `OpenClawChatMessage.CodingKeys` omit it, which would
        // otherwise cause id regeneration on the next load (see
        // `PersistedMessageEnvelope` doc).
        let envelopes = messages.map { PersistedMessageEnvelope(wrapping: $0) }
        if let data = try? JSONEncoder().encode(envelopes) {
            defaults.set(data, forKey: storageKey(for: sessionKey))
        }
    }

    // Internal helper — content-shape-invariant hash for the
    // session's append dedup. The same logical message arrives
    // in two `OpenClawChatMessage` shapes depending on source:
    // the streaming path flattens toolCall / toolResult /
    // thinking bodies into `content[0].text` (the
    // `ChatMessageConverter.toOpenClawChatMessage` path); the
    // server's `chat.history` returns typed content blocks
    // (`{type:"thinking", thinking: "..."}` or
    // `{type:"toolcall", name:..., arguments:...}`) with
    // `text: nil`. A text-only hash would miss the dedup and
    // leave both copies in the cache. We fall back to the
    // `thinking` field when `text` is empty, and normalize the
    // role to its canonical client form so a server-side
    // `role: "tool"` (lowercase variant) hashes the same as the
    // streaming-side `role: "toolCall"`. If the message carries
    // a thinking block, we force the role to "thinking" so the
    // server's `role: "assistant"` (typical shape for a
    // thinking sub-block of the assistant turn) collides with
    // the streaming-side `role: "thinking"`.
    private func dedupKey(for message: OpenClawChatMessage) -> String {
        let rawText = message.content.compactMap { $0.text }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rawThinking = message.content.compactMap { $0.thinking }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasThinkingBlock = message.content.contains(where: { $0.thinking?.isEmpty == false })

        let textForHash: String
        if !rawText.isEmpty {
            textForHash = rawText
        } else if !rawThinking.isEmpty {
            textForHash = rawThinking
        } else {
            textForHash = ""
        }

        let roleForHash: String
        if hasThinkingBlock {
            roleForHash = "thinking"
        } else {
            roleForHash = MessageCacheStorage.normalizeRoleForDedup(message.role)
        }

        let tsBucket: Int64 = {
            guard let ts = message.timestamp else { return -1 }
            return Int64(ts / 10_000)
        }()

        let data = "\(roleForHash)|\(textForHash)|\(tsBucket)".data(using: .utf8) ?? Data()
        let hash = SHA256.hash(data: data)
        return hash.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static func normalizeRoleForDedup(_ role: String) -> String {
        switch role.lowercased() {
        case "toolcall", "tool_call", "tooluse", "tool_use", "tool", "function":
            return "toolCall"
        case "toolresult", "tool_result":
            return "toolResult"
        default:
            return role
        }
    }

    private func isEmptyTextPlaceholder(_ message: OpenClawChatMessage) -> Bool {
        let rawText = message.content.compactMap { $0.text }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rawThinking = message.content.compactMap { $0.thinking }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return rawText.isEmpty && rawThinking.isEmpty
    }
}
