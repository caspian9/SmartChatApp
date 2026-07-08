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

/// Aggregate stats across every persisted session. Returned by
/// `MessageCacheStorage.stats()` and surfaced by the Settings
/// page's Cache section ("X messages (Y sessions)" + date range).
/// `oldestTimestamp` / `newestTimestamp` are nil when the cache
/// has no messages with a non-nil timestamp; otherwise they
/// span the full disk-truth age of the user's history. Sendable
/// because the implementation crosses actor boundaries (the
/// storage is an actor, the store is `@MainActor`, the Settings
/// view is on `@MainActor`); `Equatable` so the view can avoid
/// duplicate re-renders via the existing `chatMessagesCachedVersionBySession`
/// pattern (or its successor).
public struct MessageCacheStats: Sendable, Equatable {
    public let sessionCount: Int
    public let messageCount: Int
    public let oldestTimestamp: Double?
    public let newestTimestamp: Double?

    public init(
        sessionCount: Int,
        messageCount: Int,
        oldestTimestamp: Double?,
        newestTimestamp: Double?
    ) {
        self.sessionCount = sessionCount
        self.messageCount = messageCount
        self.oldestTimestamp = oldestTimestamp
        self.newestTimestamp = newestTimestamp
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
    /// Returns `MessageCacheStats` (sessionCount + messageCount
    /// + oldest/newest timestamp span) — used by the Settings
    /// page to render "X messages (Y sessions)" plus the date
    /// range row. Implementations must scan every persisted
    /// session (not just hydrated ones) so the count reflects
    /// what is on disk, independent of which sessions the user
    /// has visited this launch.
    func stats() async -> MessageCacheStats
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
        var dedupedById = 0
        var skippedEmpty = 0
        for msg in messages {
            if isEmptyTextPlaceholder(msg) {
                skippedEmpty += 1
                continue
            }
            // Id-dedup runs BEFORE content-dedup so a server re-fetch
            // that returns a message whose UUID we already have cached
            // is a clean no-op (existing entry's id is preserved, no
            // chance of an in-progress match against the just-appended
            // copy). Content-dedup is the fallback for the streaming-
            // vs-server shape mismatch (see `dedupKey` doc). Both are
            // KEEP-on-match — id stability > content authority — same
            // contract as the existing content-dedup behavior.
            if allMessages.contains(where: { $0.id == msg.id }) {
                dedupedById += 1
                continue
            }
            let key = dedupKey(for: msg)
            // Strict content-dedup: same role + same text +
            // same 60s timestamp bucket. Catches
            // streaming-vs-server writes of the same logical
            // message when both sides land within ~60s of
            // each other (the typical case).
            var existingIdx = allMessages.firstIndex(where: { dedupKey(for: $0) == key })
            if existingIdx == nil {
                // toolResult-specific fallback (BUG-8
                // follow-up, user-reported 2026-07-07):
                // when the streaming `command_output (end)`
                // event's `output` is itself incremental
                // rather than cumulative, the streaming
                // toolResult's text ends mid-JSON — strictly
                // shorter than the server's `chat.history`
                // full text. The strict content-dedup hashes
                // them differently (different byte lengths →
                // different SHA256), and the role+text fuzzy
                // fallback above also misses because the
                // texts aren't equal.
                //
                // For toolResult the *correct* identity
                // signal is `(toolCallId, toolName, tsBucket)`:
                //   - toolCallId is the canonical call id
                //     emitted by both the streaming path
                //     (`<runId>:toolResult:<canonical>`) and
                //     the server's `chat.history` payload
                //     (stored verbatim in
                //     `OpenClawChatMessage.toolCallId`).
                //   - toolName ensures a sub-agent's
                //     `get_weather` doesn't collide with the
                //     root agent's `get_weather`.
                //   - tsBucket keeps the window tight (60s)
                //     so two unrelated tool calls within a
                //     few minutes don't merge.
                //
                // Server's toolResult is always authoritative
                // (it carries the full stdout accumulated by
                // the gateway) — the replace-on-match path
                // replaces the streaming entry with the
                // server entry when it lands.
                let msgRoleLower = MessageCacheStorage.normalizeRoleForDedup(msg.role)
                if msgRoleLower == "toolResult",
                   let msgToolCallId = msg.toolCallId, !msgToolCallId.isEmpty,
                   let msgToolName = msg.toolName, !msgToolName.isEmpty {
                    let msgTs = msg.timestamp ?? 0
                    let msgBucket = Int64(msgTs / 60_000)
                    existingIdx = allMessages.firstIndex(where: { other in
                        let otherRole = MessageCacheStorage.normalizeRoleForDedup(other.role)
                        guard otherRole == "toolResult" else { return false }
                        guard other.toolCallId == msgToolCallId else { return false }
                        guard other.toolName == msgToolName else { return false }
                        guard let otherTs = other.timestamp else { return false }
                        // Same 60s bucket — catches the
                        // typical stream-vs-server pair
                        // without merging two real distinct
                        // tool calls in adjacent buckets.
                        return Int64(otherTs / 60_000) == msgBucket
                    })
                    // I2 (audit 2026-07-07): log this
                    // fallback path when it fires.
                    // toolCallId reuse across runs is
                    // rare but does happen (server
                    // resets the call-id counter on a
                    // fresh agent session that ends up
                    // using the same tool name + same
                    // upstream call id), and the
                    // replace-on-match that follows
                    // here can silently collapse
                    // legitimate distinct calls if
                    // the timestamps happen to land
                    // in the same 60s bucket.
                    // Logging at `.info` keeps it
                    // greppable for on-call without
                    // polluting the default
                    // debug-noise level.
                    if existingIdx != nil {
                        AppLogger.log(
                            "[MessageCacheStorage append] toolCallId fallback hit: sessionKey=\(String(sessionKey.prefix(8))) toolCallId=\(msgToolCallId) toolName=\(msgToolName) bucket=\(msgBucket)",
                            category: .cache, level: .info)
                    }
                }
            }
            if existingIdx == nil {
                // FUZZY FALLBACK (BUG-7, user-reported
                // 2026-07-07): the strict bucket missed
                // because the streaming entry's
                // `OpenClawChatMessage.timestamp` and the
                // server's `chat.history` timestamp land in
                // different 60s buckets — usually because
                // the streaming path's `chosenAnchor` falls
                // back to `Date()` when the gateway's
                // `endedAtMs` is 0, putting the streaming
                // entry's ts well after the server's
                // authoritative end-time. The fuzzy match
                // requires:
                //   - same role
                //   - same text (post-normalization)
                //   - timestamps within 3 minutes
                //     (180_000 ms)
                //
                // C4 (audit 2026-07-07): the previous
                // 5-minute window was too wide — a user
                // could legitimately send the same short
                // reply ("ok", "thanks", "yes") twice
                // within 5 minutes and the second
                // occurrence would silently merge into the
                // first. The 3-minute window still covers
                // the typical stream-vs-server drift
                // (streaming anchor fallback puts the
                // streaming ts at wall-clock-now, which
                // for a normal run is well under 3
                // minutes after the server's authoritative
                // end-time) while making accidental
                // user-text merges less likely. Test:
                // `test_append_dedupsByFuzzy_userTextFourMinutesApart_kept`
                // verifies the boundary.
                //
                // The fuzzy hit triggers the same
                // replace-on-match path as a strict hit.
                let msgTs = msg.timestamp ?? 0
                existingIdx = allMessages.firstIndex(where: { other in
                    guard dedupKeyRoleAndText(for: other) == dedupKeyRoleAndText(for: msg)
                    else { return false }
                    guard let otherTs = other.timestamp else { return false }
                    return abs(otherTs - msgTs) < 180_000
                })
            }
            if let existingIdx = existingIdx {
                // Dedup hit: KEEP the existing entry. The existing message's
                // `id` is preserved — important because consumers (e.g.
                // `CollapseStateCache.expandedMessageIds` keyed on the
                // streaming-time synthesized UUID) would otherwise lose
                // their state on a server re-fetch that returns the same
                // message with a server-assigned UUID.
                //
                // Thinking-block splice: if the existing entry is an
                // ASSISTANT bubble with no reasoning (streaming
                // wrote the assistant body without the sibling
                // thinking block; server's `chat.history` later
                // returns the same turn WITH the reasoning), append
                // each missing thinking block as a standalone
                // `OpenClawChatMessage` with role `"thinking"`. The
                // standalone shape survives the converter
                // (`ChatMessageConverter.toChatMessage`), which
                // already emits a `ChatMessage(role: "thinking")`
                // for such entries — the `ThinkingCardView` then
                // renders it.
                //
                // Skip the splice when the existing entry is
                // already a thinking entry (`role == "thinking"`)
                // OR has a sibling thinking block — both mean the
                // streaming path already emitted the reasoning, so
                // adding more would duplicate the thinking bubble.
                // This covers the streaming-thinking-vs-server-
                // history-thinking case where both sides agree on
                // the reasoning but use different shapes
                // (`role:"thinking", text:<reasoning>` vs
                // `role:"assistant", thinking-only block`).
                //
                // Idempotency: this branch can fire MANY times
                // across repeated `fetchAndMergeFromNetwork` calls
                // (every pull-to-refresh, every session re-enter).
                // The first version of this code used a
                // deterministic id `<existing.uuid>:thinking:<i>`
                // to make the check idempotent, but
                // `OpenClawChatMessage.id` is a `UUID` and the
                // deterministic string has a `:thinking:<i>`
                // suffix that `UUID(uuidString:)` rejects, so the
                // id fell back to `UUID()` — a fresh random UUID
                // every call. The id-based check never matched
                // across runs and one refresh added one spliced
                // thinking bubble (user-reported 2026-07-06, log
                // 09:04:53.151, CACHE[36/37/38/39]). The fix: check
                // the cache for an existing thinking entry with
                // the same reasoning text. Content-based dedup
                // here is safe because reasoning text within a
                // single run is unique (the model produces one
                // chain of thought per assistant turn).
                let existing = allMessages[existingIdx]
                let existingHasThinkingBlock = existing.content.contains(where: { $0.thinking?.isEmpty == false })
                let existingIsPureThinking = existing.role.lowercased() == "thinking"
                let newThinkingBlocks: [String] = msg.content.compactMap { block in
                    block.thinking?.trimmingCharacters(in: .whitespacesAndNewlines)
                }.filter { !$0.isEmpty }
                // REPLACE-ON-MATCH (user request 2026-07-07).
                // The server's `chat.history` payload is the
                // authoritative version of the same logical
                // turn — it carries the sibling reasoning
                // block, the full `usage` block, and the
                // model's authoritative final text. The
                // streaming-side entry is a *partial* view of
                // the same turn: flat text without the
                // thinking block, sometimes without usage
                // (gateway may omit it on lifecycle=end),
                // assembled via suffix-overlap collapse from
                // the deltas. KEEP-on-match (the previous
                // behavior) drops the server's copy and tries
                // to re-attach the missing fields via
                // usage-splice + thinking-splice. That works
                // when the streaming entry is textually close
                // to the server copy, but when the two texts
                // differ enough that the dedup key STILL
                // matches (which is the dedup's whole point)
                // yet the splice's content-block walk misses
                // something — or when the user clears their
                // thinking display path and only the server
                // has it — the cache ends up with two entries
                // (one streaming-text, one server-text+usage)
                // showing two assistant bubbles.
                //
                // The fix: when the dedup key matches, REPLACE
                // the existing entry with the server's entry
                // in place, KEEPING the existing entry's `id`.
                // The id-preservation is critical because:
                //   1. The view's `ForEach(messages, id: \.id)`
                //      would otherwise re-create the bubble,
                //      animating a fade-out + fade-in.
                //   2. `CollapseStateCache.expandedMessageIds`
                //      is keyed on the streaming-time
                //      synthesized UUID — replacing the id
                //      would silently lose the user's
                //      expand/collapse state.
                //
                // The replacement entry carries the server's
                // `content` (which may now include the sibling
                // `{type:"thinking", ...}` block that the
                // streaming path didn't capture), the
                // server's `usage`, and the server's
                // `timestamp` (the model's authoritative
                // end-time, more accurate than the client's
                // `endedAtMs`). The streaming entry's `id`,
                // `toolCallId`, `toolName`, `stopReason`, and
                // `errorMessage` carry over from the existing
                // entry — these are streaming-side fields the
                // server doesn't emit on `chat.history`.
//
// C3 (audit 2026-07-07): replace-on-match assumes
// the server's payload is a strict superset of the
// streaming entry's content. Any client-side content
// blocks that the server doesn't re-emit on
// `chat.history` will be silently dropped by this
// branch (custom card payloads, transient
// placeholders, future-shape streaming-only blocks).
// The pre-replace code KEEP'd the streaming entry's
// content and only spliced the missing usage /
// thinking — that mode survives server omissions but
// also fails to surface the server's fuller content.
// If the server ever stops emitting a content type
// that the streaming path produces, this branch will
// need to fall back to a per-block merge that keeps
// non-overlapping streaming blocks. Audit log: see
// PR #49 review (caspian9, 2026-07-07).
                //
                // If the existing entry is a standalone
                // `role:"thinking"` bubble (the streaming path
                // emits those for inline reasoning deltas),
                // the dedup hit is a streaming-thinking-vs-
                // server-thinking collision. The role check
                // is the same role, same text → both are
                // thinking → the streaming entry is ALSO
                // replaced with the server's. In that case,
                // the server's entry is a more authoritative
                // `role:"thinking"` (server's full reasoning
                // chain) — replacing is also correct.
                //
                // Idempotent across repeated refreshes: the
                // first replace establishes the server's
                // shape; subsequent replaces are no-ops
                // (server returns the same content).
                let replacement: OpenClawChatMessage
                // "Server is richer than streaming" is the
                // signal to REPLACE. The streaming entry is a
                // partial view of the same logical turn (text
                // only, no sibling thinking block, possibly
                // no usage); the server's `chat.history`
                // payload is the authoritative version with
                // the full content (text + thinking) and the
                // token-usage block. Replacing when the
                // server has more data fixes the "two
                // assistant bubbles after stream+history
                // merge" bug (user-reported 2026-07-07).
                //
                // BUG-8 follow-up: for `role: "toolResult"`
                // specifically, "more data" also covers the
                // case where the streaming accumulator
                // produced a truncated body (server's
                // `command_output (end)` arrived with
                // incremental `output` rather than full text)
                // and the server's later history fetch
                // carries the full stdout. Without the
                // text-length signal here, the streaming
                // entry would survive the dedup and the user
                // would see two toolResult bubbles — the
                // truncated streaming one and the full
                // history one.
                //
                // The text-length signal is scoped to
                // toolResult because other roles (user,
                // assistant, thinking) don't suffer from
                // text-length drift in practice — the
                // streaming text is the authoritative final
                // for those (the model emits a single
                // cumulative text and lifecycle=end captures
                // it). Server's text for those roles is
                // either equal to or a sibling-shape
                // expansion of the streaming text.
                //
                // If neither side has an advantage (e.g.,
                // user-vs-user within 60s with same text,
                // or thinking-vs-thinking with same content)
                // we KEEP the existing entry — preserves
                // CollapseStateCache and avoids clobbering
                // newer streaming-side data with stale
                // server-side data when the server hasn't
                // emitted anything newer.
                let msgHasUsage = msg.usage != nil
                let msgHasThinkingBlock = msg.content.contains(where: { $0.thinking?.isEmpty == false })
                let msgHasMoreContentBlocks = msg.content.count > existing.content.count
                let msgRoleLower = MessageCacheStorage.normalizeRoleForDedup(msg.role)
                let existingRoleLower = MessageCacheStorage.normalizeRoleForDedup(existing.role)
                let msgText = msg.content.compactMap { $0.text }.joined(separator: "\n")
                let existingText = existing.content.compactMap { $0.text }.joined(separator: "\n")
                let msgHasMoreText = msgText.count > existingText.count + 64
                // FIX-9 (user-reported 2026-07-08, log
                // 08:42:47.586Z): when the streaming
                // `lifecycle=end` final and the server's
                // `chat.history` final are textually
                // identical (post-normalization), they are
                // the SAME logical turn — the streaming copy
                // just arrived first because the user's
                // device was faster than the next pull-to-
                // refresh round-trip. The previous
                // `serverRicher` signal required the server
                // copy to be structurally richer
                // (usage/thinking/extra content blocks),
                // which it isn't when the server returns a
                // bare text-only assistant message (no usage
                // block, no sibling thinking block, single
                // content block — the most common case for a
                // short assistant final). Without this
                // `textEqual` short-circuit, the fuzzy
                // fallback above (same role + same text +
                // ts within 5min) hits but the REPLACE
                // branch is skipped, the existing streaming
                // entry is KEEP'd, and the user sees the
                // same assistant bubble twice (CACHE[13]
                // history + CACHE[15] stream in the
                // 2026-07-08 log, both with id distinct).
                //
                // The `textEqual` signal is post-
                // normalization (same invisible-character
                // strip as `dedupKeyRoleAndText` uses) so
                // tiny presentation-selector differences
                // (U+FE0E/U+FE0F) don't break the short-
                // circuit. It's a positive "definitely the
                // same logical turn" signal — independent
                // of which side is structurally richer —
                // and only fires when the two writes are
                // textually the same. For toolResult, the
                // existing `msgHasMoreText` text-length
                // signal is preferred (catches the
                // truncated-streaming-body case where the
                // server's full body is longer).
                let msgTextNormalized = MessageCacheStorage.normalizeTextForDedupHash(msgText)
                let existingTextNormalized = MessageCacheStorage.normalizeTextForDedupHash(existingText)
                let textEqual = !msgTextNormalized.isEmpty
                    && msgTextNormalized == existingTextNormalized
                // toolResult text-length drift is the
                // common case (truncated streaming body,
                // full server body). For other roles, we
                // only treat server as richer when the
                // structural fields (usage/thinking/blocks)
                // differ — text length alone is too noisy
                // (legitimate streaming-vs-server text can
                // differ by a few bytes without that
                // meaning the streaming entry is
                // incomplete).
                let msgTextRichness = msgRoleLower == "toolResult" && msgHasMoreText
                let serverRicher = msgHasUsage
                    || msgHasThinkingBlock
                    || msgHasMoreContentBlocks
                    || msgTextRichness
                    || textEqual
                if existing.id == msg.id {
                    // Defensive: this branch is unreachable in
                    // practice (id-dedup runs at line 260 and
                    // would have caught it), but if we ever
                    // change the dedup order, fall back to a
                    // straight assignment to avoid a
                    // UUID-collision where the streaming id
                    // and the server id happen to match.
                    replacement = msg
                } else if existingIsPureThinking || existingHasThinkingBlock {
                    // Both sides are thinking-shape. Keep
                    // the streaming entry's content as-is (it
                    // already has the reasoning text); only
                    // upgrade usage if missing.
                    if existing.usage == nil, let newUsage = msg.usage {
                        replacement = OpenClawChatMessage(
                            id: existing.id,
                            role: existing.role,
                            content: existing.content,
                            timestamp: existing.timestamp,
                            toolCallId: existing.toolCallId,
                            toolName: existing.toolName,
                            usage: newUsage,
                            stopReason: existing.stopReason,
                            errorMessage: existing.errorMessage)
                    } else {
                        replacement = existing
                    }
                } else if serverRicher {
                    // Streaming text-only (no thinking
                    // block) vs. server text+thinking+usage.
                    // Replace with the server's content,
                    // keeping the streaming id. The server's
                    // `content` array carries the sibling
                    // thinking block; the server's `usage`
                    // carries the token counts.
                    replacement = OpenClawChatMessage(
                        id: existing.id,
                        role: msg.role,
                        content: msg.content,
                        timestamp: msg.timestamp ?? existing.timestamp,
                        toolCallId: existing.toolCallId,
                        toolName: existing.toolName,
                        usage: msg.usage ?? existing.usage,
                        stopReason: existing.stopReason,
                        errorMessage: existing.errorMessage)
                } else {
                    // Server is not richer than streaming —
                    // KEEP the existing entry. Preserves
                    // CollapseStateCache keys and avoids
                    // clobbering newer streaming data with
                    // stale server data. No splice needed.
                    replacement = existing
                }
                allMessages[existingIdx] = replacement
                // Thinking splice — only needed when the
                // REPLACEMENT entry still doesn't carry the
                // thinking block (e.g., the dedup hit was
                // streaming-thinking vs. server-thinking and
                // we kept existing content above, OR the server
                // payload had thinking blocks that the
                // replacement's content didn't pick up — which
                // shouldn't happen now that the `else` branch
                // copies msg.content wholesale, but kept as a
                // safety net for any future shape change).
                let replacementHasThinking = replacement.content.contains(where: { $0.thinking?.isEmpty == false })
                let replacementIsPureThinking = replacement.role.lowercased() == "thinking"
                if !existingHasThinkingBlock && !existingIsPureThinking
                    && !replacementHasThinking && !replacementIsPureThinking {
                    for thinkingText in newThinkingBlocks {
                        // Idempotent: skip if a thinking block
                        // with this exact text already exists,
                        // but ONLY within a tight ±60s window
                        // of the existing entry's timestamp.
                        // The whole-session walk previously
                        // matched a same-text thinking entry
                        // from any past run, which would
                        // silently drop a legitimate thinking
                        // bubble for the current run if the
                        // model ever produced byte-identical
                        // reasoning in two different turns
                        // (rare but possible when the user
                        // asks the same question twice).
                        //
                        // The 60s window matches the
                        // dedupKey's `tsBucket` — both the
                        // dedup hit and the just-spliced
                        // thinking bubble live in the same
                        // bucket, so we never miss a
                        // same-run double-splice. Cross-run
                        // identical-reasoning is now correctly
                        // permitted to splice (the user gets
                        // the thinking bubble for the
                        // current turn even if a previous
                        // turn had identical reasoning).
                        let existingTs = existing.timestamp ?? 0
                        let alreadySpliced = allMessages.contains(where: { other in
                            guard let otherTs = other.timestamp else { return false }
                            if abs(otherTs - existingTs) > 60_000 { return false }
                            return other.content.contains(where: { block in
                                block.thinking?.trimmingCharacters(in: .whitespacesAndNewlines) == thinkingText
                            })
                        })
                        if alreadySpliced { continue }
                        let thinkingMsg = OpenClawChatMessage(
                            id: UUID(),
                            role: "thinking",
                            content: [OpenClawChatMessageContent(
                                type: "thinking", text: nil,
                                thinking: thinkingText,
                                thinkingSignature: nil,
                                mimeType: nil, fileName: nil,
                                content: nil, id: nil, name: nil,
                                arguments: nil)],
                            timestamp: msg.timestamp,
                            toolCallId: nil, toolName: nil,
                            usage: nil, stopReason: nil,
                            errorMessage: nil)
                        allMessages.append(thinkingMsg)
                        added += 1
                    }
                }
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
            "[MessageCacheStorage append] sessionKey=\(String(sessionKey.prefix(8))) original=\(originalCount) added=\(added) deduped=\(deduped) dedupedById=\(dedupedById) skippedEmpty=\(skippedEmpty) final=\(allMessages.count)",
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
    public func stats() async -> MessageCacheStats {
        // Scan UserDefaults for every persisted session key. We can't
        // just iterate `cache` because that dict only contains
        // sessions this actor has loaded since launch — Settings
        // needs the disk-truth count, not the in-memory working set.
        var sessionCount = 0
        var messageCount = 0
        var oldest: Double?
        var newest: Double?
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(keyPrefix) {
            sessionCount += 1
            if let data = defaults.data(forKey: key),
               let envelopes = try? JSONDecoder().decode([PersistedMessageEnvelope].self, from: data) {
                messageCount += envelopes.count
                // Only consider non-nil timestamps for the span.
                // A nil `timestamp` is rare (streaming placeholders
                // typically get one before persisting) but skip
                // rather than count as 0 — counting as 0 would put
                // nil entries at the head of every span, which is
                // misleading.
                let timestamps = envelopes.compactMap { $0.message.timestamp }
                if let sessionOldest = timestamps.min() {
                    oldest = min(oldest ?? sessionOldest, sessionOldest)
                }
                if let sessionNewest = timestamps.max() {
                    newest = max(newest ?? sessionNewest, sessionNewest)
                }
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
        return MessageCacheStats(
            sessionCount: sessionCount,
            messageCount: messageCount,
            oldestTimestamp: oldest,
            newestTimestamp: newest
        )
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
    // streaming-side `role: "toolCall"`. If the message is a
    // thinking-only sub-block (text empty, thinking non-empty),
    // we force the role to "thinking" so the server's
    // `role: "assistant"` (the typical shape for the thinking
    // sub-block of an assistant turn — typed content with no
    // sibling text block) collides with the streaming-side
    // `role: "thinking"`.
    //
    // The dedup key is `role + text + tsBucket`. (The earlier
    // design also included `usage`; removed — see the comment
    // on the `data:` line below.)
    //
    // `tsBucket = Int64(ts / 60_000)` is a 60-second bucket.
    // The intent: catch streamed-vs-server copies of the same
    // logical message even when the two writes happen seconds
    // apart (e.g. CACHE[11] stream bubble ts=`...5993`,
    // CACHE[15] server version ts=`...4721` — a single run
    // span of ~8.7s, on either side of the 10s boundary, log
    // 2026-07-06). A 60s bucket covers the full streaming
    // lifetime of a typical assistant turn (typing +
    // tool execution + finalization) while keeping
    // user-distinct messages partitioned.
    //
    // An earlier experiment dropped the bucket entirely and
    // made the key `role + text` only; that broke the user
    // bubble because two consecutive user messages with the
    // same text ("hi" repeated) collapsed onto each other even
    // when they were minutes apart in real time (PR #49 first
    // attempt, reverted in `b6171c8`). The 60s bucket keeps
    // near-in-time duplicates merged while preserving
    // user-distinct messages typed at different times. The
    // remaining edge case (user sends the same text twice
    // within 60s) is now caught upstream by a
    // duplicate-send confirmation in `NativeChatViewModel` —
    // see the doc on `sendMessage`.
    //
    // Tool-result text normalization: `EventInterpreter`
    // appends an `exit=<code> duration=<ms>ms` trailer to
    // toolResult bodies on the modern `command_output (end)`
    // path (line ~1242). The streaming toolResult written by
    // the `item` (end) / `tool` (result) paths does NOT add
    // the trailer. Same logical tool execution → two cache
    // writes with different text bytes → no dedup → duplicate
    // bubble (log 2026-07-06, CACHE[14] vs CACHE[16]). The
    // fix: strip a trailing `exit=… duration=…ms` segment
    // from the text BEFORE hashing. If the pattern doesn't
    // match (e.g. server changes its trailer format), the
    // strip is a no-op and dedup falls back to the unstripped
    // text — no regression vs. the previous behavior.
    //
    // IMPORTANT: the "force to thinking" override applies ONLY
    // to the thinking-only sub-block case (no text body). A
    // full assistant turn that ALSO carries a sibling
    // `{type:"thinking", thinking: "..."}` block (the server's
    // history shape for an assistant message that produced
    // reasoning alongside its final text) must hash under its
    // normalized role so it collides with the streaming copy of
    // the same turn (which has no thinking block). Forcing
    // role="thinking" on the "text + thinking" case made
    // streamed-vs-server copies of the same assistant turn
    // hash to different keys and produced duplicate assistant
    // bubbles after pull-to-refresh (logged 2026-07-03,
    // runId 6BB8B583-BE35-42F9-B380-7E7FE993048D).
    /// Returns the (role, text) pair used in both `dedupKey`
    /// (strict, with tsBucket) and the BUG-7 fuzzy fallback
    /// (no tsBucket, just role+text + a manual ts-range
    /// check). Factored out so the two paths agree on what
    /// "same logical message" means — both the text
    /// normalization (`normalizeTextForDedupHash`) and the
    /// trailer strip (`stripToolResultTrailer`) apply here.
    /// See `dedupKey`'s doc for the normalization rationale.
    private func dedupKeyRoleAndText(
        for message: OpenClawChatMessage
    ) -> (role: String, text: String) {
        let rawText = message.content.compactMap { $0.text }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rawThinking = message.content.compactMap { $0.thinking }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let baseTextForHash: String
        if !rawText.isEmpty {
            baseTextForHash = rawText
        } else if !rawThinking.isEmpty {
            baseTextForHash = rawThinking
        } else {
            baseTextForHash = ""
        }

        let normalizedText = MessageCacheStorage.normalizeTextForDedupHash(baseTextForHash)
        let textForHash = MessageCacheStorage.stripToolResultTrailer(normalizedText)

        // Thinking-only sub-block: force role to "thinking" so
        // the server's `{type:"thinking", thinking:"..."}`
        // shape collides with the streaming-side
        // `role:"thinking"` standalone.
        let isThinkingOnlySubBlock = rawText.isEmpty && !rawThinking.isEmpty

        let roleForHash: String
        if isThinkingOnlySubBlock {
            roleForHash = "thinking"
        } else {
            roleForHash = MessageCacheStorage.normalizeRoleForDedup(message.role)
        }

        return (roleForHash, textForHash)
    }

    private func dedupKey(for message: OpenClawChatMessage) -> String {
        let (roleForHash, textForHash) = dedupKeyRoleAndText(for: message)

        let tsBucket: Int64 = {
            guard let ts = message.timestamp else { return -1 }
            return Int64(ts / 60_000)
        }()

        // `usage` deliberately does NOT contribute to the dedup
        // key. The streaming `lifecycle=end` writes the
        // `{input:-1, ...}` "no token data" sentinel and the
        // server's `chat.history` returns `usage=nil` for the
        // same logical message; the streaming copy has the real
        // token values once the run finalizes with usage, while
        // the server copy sometimes carries a real usage block
        // (newer server versions) and sometimes `usage=nil`
        // (older). Including `usage` in the fingerprint would
        // make the streamed-vs-server pair split into two entries
        // whenever the usage shapes differ. Streaming-time
        // `usage` is preserved upstream by
        // `HistoryLoader.applyUsagePreservation` which splices
        // it into the server copy before `append` runs, so the
        // dedup layer can stay usage-blind.
        let data = "\(roleForHash)|\(textForHash)|\(tsBucket)".data(using: .utf8) ?? Data()
        let hash = SHA256.hash(data: data)
        return hash.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Normalizes text for the dedup hash only (view still sees
    /// the original bytes). Strips characters that have no effect
    /// on human-visible content but create byte-level differences
    /// that defeat dedup:
    ///
    /// - U+FE0E / U+FE0F (text/emoji presentation selectors) — the
    ///   same glyph can be rendered either as text or as an emoji;
    ///   different server encoders can pick different selectors,
    ///   producing two different byte sequences for the same
    ///   visible character (user-reported 2026-07-06,
    ///   CACHE[30] vs CACHE[32] in the device log: `🌤️` U+1F324
    ///   U+FE0F vs `🌤` U+1F324).
    /// - U+200D (zero-width joiner) and U+FEFF (BOM / zero-width
    ///   no-break space) — invisible joiners that change the byte
    ///   length of compound emoji sequences.
    /// - U+2028 / U+2029 (LINE / PARAGRAPH SEPARATOR) — alternate
    ///   newline forms that some emitters send instead of `\n`.
    ///
    /// The hash input is meant to answer "is this the same message
    /// a human would consider the same?" — invisible variation
    /// selectors don't change that answer. The view keeps the
    /// original text (so the user sees exactly what the server
    /// sent).
    static func normalizeTextForDedupHash(_ text: String) -> String {
        var result = text
        for scalar in ["\u{FE0E}", "\u{FE0F}", "\u{200D}", "\u{FEFF}", "\u{2028}", "\u{2029}"] {
            result = result.replacingOccurrences(of: scalar, with: "")
        }
        return result
    }

    /// Strips a trailing `exit=<code> duration=<ms>ms` (or either
    /// half, in either order) from a toolResult body for dedup
    /// hashing only. Idempotent: returns the input unchanged if
    /// the pattern is not present.
    ///
    /// `EventInterpreter.command_output (end)` appends the trailer
    /// at line ~1242 only on the modern path; the legacy
    /// `item` (end) / `tool` (result) paths do NOT. Stripping
    /// here means the two writes of the same logical tool
    /// execution hash identically. See the method doc on
    /// `dedupKey(for:)` for the failure log.
    static func stripToolResultTrailer(_ text: String) -> String {
        // Match `exit=<int>` and `duration=<int>ms` as optional
        // standalone halves, in either order, at the end of the
        // text after optional trailing whitespace/newlines.
        let pattern = #"(?:\s+(?:exit=-?\d+|duration=\d+ms))+\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let stripped = regex.stringByReplacingMatches(
            in: text, range: range, withTemplate: "")
        return stripped
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
