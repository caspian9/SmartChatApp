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
    /// Bumped on every write to `messagesBySession` (any session).
    /// Consumers (e.g. `NativeChatViewModel.chatMessages(for:)`)
    /// use this as a cache-invalidation signal: any write to the
    /// store means "the source of truth changed, re-read me." The
    /// earlier id-list fingerprint (`chatMessagesSourceIdsBySession`)
    /// missed streaming text updates, which share an id with the
    /// previous frame but carry longer text — the view kept showing
    /// the typing indicator because the cache returned a stale
    /// `text=""` `ChatMessage` for an `id=runId` whose source entry
    /// now had `text="ha"`. Global version is overkill (a write to
    /// session A invalidates session B's cache too) but the
    /// conversion is <1ms for any realistic session, and
    /// `messagesBySession` is the bigger signal that drives view
    /// re-evaluation — version just keeps the VM's auxiliary cache
    /// in lockstep. `@ObservationIgnored` because the view re-renders
    /// on `messagesBySession`, not on the version itself.
    @ObservationIgnored
    private var writeVersion: Int = 0
    var version: Int { writeVersion }

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

    /// Returns the id of the last (most recent by sort order) message
    /// in `sessionKey`, or nil if the session has no messages. The
    /// id is the same `String` form the view layer uses for
    /// `ChatMessage.id` (i.e., `OpenClawChatMessage.id.uuidString`),
    /// so the caller can plug it straight into
    /// `.scrollPosition(id:)` on the chat ScrollView.
    ///
    /// Used by `NativeChatView` to scroll to the latest message on
    /// session entry and on cross-session switch. The store keeps
    /// messages sorted by timestamp, so `array.last` is the
    /// most-recent one — O(1) per call, no extra bookkeeping.
    public func latestMessageId(for sessionKey: String) -> String? {
        messagesBySession[sessionKey]?.last?.id.uuidString
    }

    public func isHydrated(for sessionKey: String) -> Bool {
        hydratedSessions.contains(sessionKey)
    }

    /// Single write path for `messagesBySession`. Bumps the version
    /// alongside the assignment so external caches (the VM's
    /// converted-message cache) can detect "the source changed" via
    /// `version` instead of trying to fingerprint the array contents.
    /// `clearAll` is the one exception — it does `removeAll()` rather
    /// than per-key assignment, so it bumps the version inline.
    private func setMessages(_ messages: [OpenClawChatMessage], for sessionKey: String) {
        writeVersion &+= 1
        messagesBySession[sessionKey] = messages
    }

    // -- Write path (async, delegates to storage) — Task 6/7 implementation

    public func hydrate(for sessionKey: String) async {
        let loaded = await storage.load(for: sessionKey)
        setMessages(loaded, for: sessionKey)
        hydratedSessions.insert(sessionKey)
    }

    /// Synchronous hydrate. Reads UserDefaults directly via
    /// `storage.loadSync(for:)` and updates the in-memory dict
    /// without an actor hop. Use this from `loadHistory` /
    /// `selectSession` / view-body paths where the goal is to
    /// surface cached messages to the user as fast as possible —
    /// awaiting the storage actor for the initial hydrate was the
    /// main reason `.historyLoaded` scrollRequest fired hundreds
    /// of ms after the view appeared, and the multi-poll cascade
    /// often landed the viewport at a stale anchor. The async
    /// `hydrate(for:)` is kept for callers that already have an
    /// `await` in flight (e.g. `MessageCacheStore.append`'s
    /// defensive-hydrate branch).
    public func hydrateSync(for sessionKey: String) {
        let loaded = storage.loadSync(for: sessionKey)
        setMessages(loaded, for: sessionKey)
        hydratedSessions.insert(sessionKey)
    }

    public func append(_ messages: [OpenClawChatMessage], for sessionKey: String) async {
        guard !messages.isEmpty else { return }
        // Defensive: if memory isn't hydrated, hydrate first via the
        // sync path to avoid an actor hop.
        if !isHydrated(for: sessionKey) {
            let loaded = storage.loadSync(for: sessionKey)
            setMessages(loaded, for: sessionKey)
            hydratedSessions.insert(sessionKey)
        }
        // Delegate storage dedup + persist; storage now returns the
        // post-write array so we can update memory directly without a
        // second `await load(for:)` re-read.
        // This change drops streaming-delta actor hops from 2 to 1,
        // and full-array JSON decodes from 1 to 0.
        let updated = await storage.append(messages, for: sessionKey)
        setMessages(updated, for: sessionKey)
        // Advance lastSeenTimestamp
        if let newMax = updated.compactMap(\.timestamp).max() {
            let current = lastSeenTimestampBySession[sessionKey] ?? 0
            if newMax > current {
                lastSeenTimestampBySession[sessionKey] = newMax
            }
        }
    }

    /// Id-based upsert used by the streaming receive path. Replaces
    /// any existing entry with the same id (so N streaming deltas
    /// sharing one runId collapse to a single entry) and appends
    /// entries with new ids. Storage returns the post-write array so
    /// the store's in-memory dict stays in lockstep without a
    /// second disk read. See `append` for the no-re-read rationale
    /// (this is the hot path during streaming — called per delta).
    public func upsert(_ messages: [OpenClawChatMessage], for sessionKey: String) async {
        guard !messages.isEmpty else { return }
        if !isHydrated(for: sessionKey) {
            let loaded = storage.loadSync(for: sessionKey)
            setMessages(loaded, for: sessionKey)
            hydratedSessions.insert(sessionKey)
        }
        let updated = await storage.upsert(messages, for: sessionKey)
        setMessages(updated, for: sessionKey)
        if let newMax = updated.compactMap(\.timestamp).max() {
            let current = lastSeenTimestampBySession[sessionKey] ?? 0
            if newMax > current {
                lastSeenTimestampBySession[sessionKey] = newMax
            }
        }
    }

    /// Authoritative-replace used by `loadHistory`. Wipes every
    /// existing entry in the session and replaces with `messages`.
    /// The server's response is treated as ground truth: streaming
    /// residue from a prior run (id=client-runId, partial text),
    /// stale entries from prior app launches, and any other
    /// client-only entries are dropped.
    ///
    /// Unlike `append` / `upsert`, this path is NOT debounced —
    /// the storage's `replaceForSession` writes synchronously to
    /// UserDefaults. That's intentional: this is a "wipe + replace"
    /// operation, and the caller (`HistoryLoader.fetchAndMergeFromNetwork`)
    /// wants the on-disk state to be the new truth immediately,
    /// not 100ms later. The next `append` / `upsert` for this
    /// session WILL coalesce with the immediate-prior
    /// `replaceForSession` via the normal debounce window, but
    /// that's fine — the wipe has already landed.
    ///
    /// Streaming residue bug fix: the previous `append`-based
    /// implementation used content-dedup which missed same-content
    /// different-id entries (the streaming path's synthesized
    /// runId vs. the server's UUID for the same final message).
    /// `replaceForSession` wipes the residue entirely.
    ///
    /// After the storage write, refreshes `messagesBySession`
    /// and resets `lastSeenTimestamp` to the new max. The
    /// hydration flag stays set — the session is still "live",
    /// just with new content.
    ///
    /// Empty payloads are short-circuited at the storage layer
    /// (no write, no `messagesBySession` change) — see
    /// `MessageCacheStorage.replaceForSession` for the
    /// weak-network rationale.
    public func replaceForSession(_ messages: [OpenClawChatMessage], for sessionKey: String) async {
        if !isHydrated(for: sessionKey) {
            let loaded = storage.loadSync(for: sessionKey)
            setMessages(loaded, for: sessionKey)
            hydratedSessions.insert(sessionKey)
        }
        let updated = await storage.replaceForSession(messages, for: sessionKey)
        setMessages(updated, for: sessionKey)
        // Update the water-line. Storage's empty-payload guard
        // returns the existing array unchanged, so an empty
        // server response doesn't shift `lastSeen` backwards.
        if let newMax = updated.compactMap(\.timestamp).max() {
            lastSeenTimestampBySession[sessionKey] = newMax
        }
    }

    public func clear(for sessionKey: String) async {
        await storage.clear(for: sessionKey)
        setMessages([], for: sessionKey)
        lastSeenTimestampBySession[sessionKey] = nil
        hydratedSessions.remove(sessionKey)
    }

    /// In-memory-only clear. Wipes the store's working-set dicts
    /// for `sessionKey` but does **not** touch the on-disk storage.
    /// Used by `SessionCoordinator.selectSession` to drop the
    /// outgoing session's cached bubbles so the user doesn't see
    /// them flash during the cross-session transition, while
    /// keeping the disk copy intact for the eventual
    /// "switch back to that session" — if the user comes back to
    /// this session under a weak/intermittent network, the cache
    /// is still there to backstop the `fetchAndMergeFromNetwork`
    /// attempt. The previous implementation called
    /// `clear(for: sessionKey)` here, which (despite the comment)
    /// wiped both memory and disk — leaving the user with no
    /// fallback on a subsequent switch-back if the network failed.
    public func clearMemory(for sessionKey: String) {
        setMessages([], for: sessionKey)
        lastSeenTimestampBySession[sessionKey] = nil
        hydratedSessions.remove(sessionKey)
    }

    public func clearAll() async {
        await storage.clearAll()
        // `removeAll()` doesn't go through `setMessages` (no per-key
        // assignment), so bump the version explicitly to keep the
        // VM's cache invalidation in lockstep with the wipe.
        writeVersion &+= 1
        messagesBySession.removeAll()
        lastSeenTimestampBySession.removeAll()
        hydratedSessions.removeAll()
    }

    /// Disk-truth aggregate stats across all session keys, not just
    /// the ones hydrated into memory. Used by the Settings page to
    /// render "X messages (Y sessions)" plus the date-range row
    /// next to the Clear Message Cache button. Returns
    /// `MessageCacheStats` so the Settings view can render the
    /// span (oldest/newest) in one call.
    public func stats() async -> MessageCacheStats {
        await storage.stats()
    }
}
