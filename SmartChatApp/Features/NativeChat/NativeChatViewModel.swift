import Foundation
import os
import SwiftUI
import OpenClawChatUI
import OpenClawKit

/// Unified scroll signal between the view-model and the view. Replaces the
/// previous `scrollTrigger` / `cacheLoadCounter` / `needsScrollToBottom`
/// triple, where three independent counters in the same beat would compound
/// to 11+ `scrollTo` calls per history load. Writers (sendMessage,
/// MessageReceiver, HistoryLoader) bump `token` exactly once per event; the
/// view observes `token` and dispatches on `kind` — `.newMessage` does a
/// single scroll, `.historyLoaded` does a multi-poll scroll to catch the
/// `MarkdownViewTextKit` async height measurement.
enum NativeChatScrollKind: Equatable {
    /// A new message landed or a streaming delta arrived — single scroll.
    /// Streaming deltas mutate the same `lastId` (id-match path), so the
    /// single scroll is a no-op once at the bottom; only a fresh append
    /// (new user message, new tool bubble) actually moves the viewport.
    case newMessage
    /// Cached or network history just loaded — multi-poll scroll catches
    /// the `MarkdownViewTextKit` async height measurement. Gated on
    /// `!userHasScrolled` so reading history isn't yanked to the bottom.
    case historyLoaded
    /// Manual pull-up refresh landed new messages — single scroll, no
    /// `userHasScrolled` gate. The user explicitly pulled up to fetch,
    /// so they want the scroll to land on the new message even if they
    /// had previously scrolled away from the bottom.
    case manualRefresh
}

struct NativeChatScrollRequest: Equatable {
    var token: Int
    var kind: NativeChatScrollKind
    /// When true, the view ignores `userHasScrolled` and forces a scroll
    /// to the last message. Set by the HistoryLoader when the user
    /// switched sessions (`sessionKey` changed since the last load) — in
    /// that case the viewport is on the previous session's anchor and a
    /// userHasScrolled=true (set while reading the old session) would
    /// otherwise prevent the viewport from following the new session.
    /// For the same-session-history-load case (entering NativeChat,
    /// in-app refresh), this stays false so reading history isn't
    /// yanked to the bottom.
    var forceScroll: Bool = false
    static let initial = NativeChatScrollRequest(token: 0, kind: .newMessage)
}

@MainActor
@Observable
final class NativeChatViewModel {
    // MARK: - State
    //
    // The previous @Reducer version had a `struct State: Equatable` with
    // `@ObservableState` macro and an `enum Action` driving a `Reduce` body.
    // Migrated to @MainActor @Observable class: each former state field is a
    // stored property (with `private(set)` when only the model writes it),
    // and each former action case is a method below.

    var selectedProfileId: UUID?
    var sessions: [OpenClawChatSessionEntry] = []
    var selectedSession: OpenClawChatSessionEntry?
    var inputText: String = ""
    var isLoading: Bool = false
    var isSending: Bool = false
    var isSwitchingGateway: Bool = false
    var error: String?
    var isRestoringFromCache: Bool = false
    /// True while a user-initiated pull-up refresh is in flight. The
    /// view's `refreshIndicator` reads this to show the spinner; the
    /// HistoryLoader's `defer` block resets it to false when the
    /// network task completes (success or error).
    var isManualRefreshing: Bool = false
    /// Unified scroll signal. See `NativeChatScrollRequest` doc for the
    /// rationale. Each writer must increment the token exactly once per
    /// event — multiple increments in the same beat used to produce
    /// visible up-down jitter when the viewport kept re-anchoring against
    /// different layout states.
    var scrollRequest: NativeChatScrollRequest = .initial
    /// Watchdog for `isSending = true`. If `lifecycle end` (or any
    /// terminal signal) doesn't arrive within `sendTimeout`, the
    /// watchdog flips `isSending` back to false and surfaces a
    /// timeout error. Without this, a `chat.send` that the gateway
    /// accepted but never followed up with a lifecycle event (e.g.,
    /// dropped WebSocket frame, server crash mid-run) would leave
    /// the chat input permanently disabled and the spinner spinning
    /// — even after the user navigates away and back, because the
    /// `isSending` flag is the only thing the view observes. We
    /// hold the watchdog task here (instead of inside `sendMessage`'s
    /// `Task { }`) so `lifecycle end` can cancel it from a different
    /// async context.
    @ObservationIgnored
    private var sendTimeoutTask: Task<Void, Never>?
    /// How long to wait between `chat.send` succeeding and a terminal
    /// `lifecycle end` event arriving before declaring the run
    /// orphaned. Tuned to comfortably exceed the longest legitimate
    /// agent run (long thinking + multi-step tool calls can take
    /// 30-60s) while still being short enough that a stuck UI
    /// recovers within human attention span. Override via
    /// `setSendTimeout(_:)` for tests.
    @ObservationIgnored
    private var sendTimeout: Duration = .seconds(90)
    /// Cached `OpenClawChatMessage` → `ChatMessage` conversion keyed by
    /// session. The view's `messages` computed property used to do
    /// this conversion inline on every body evaluation: for a 200-
    /// message history, every `expandedMessageIds` mutation, every
    /// `scrollRequest` token change, every store write re-ran the
    /// full `ChatMessageConverter.toChatMessage` pass plus a
    /// 200-element `map` to merge `isUserExpanded` — easily a few
    /// hundred ms of main-thread work per scroll-frame in some
    /// configurations.
    ///
    /// The cache invalidates when `MessageCacheStore.version` changes
    /// (i.e., on any `messagesBySession[sessionKey] = ...` write via
    /// `setMessages`). The previous id-list fingerprint
    /// (`chatMessagesSourceIdsBySession`) was too narrow: streaming
    /// deltas share an id with the previous frame but carry a
    /// longer text, so a delta-only update left the id-list
    /// unchanged and the cache returned a stale `text=""` entry —
    /// the bubble kept showing the typing indicator. Version is a
    /// per-write monotonic counter bumped in `MessageCacheStore`'s
    /// `setMessages` helper, so any source change invalidates.
    @ObservationIgnored
    private var chatMessagesBySession: [String: [ChatMessage]] = [:]
    @ObservationIgnored
    private var chatMessagesCachedVersionBySession: [String: Int] = [:]
    /// TEMP DIAG: tracks the last `store.version` for which we
    /// emitted the per-message DIAG dump. `chatMessages(for:)`
    /// is a computed property called by the view on every render
    /// frame, so without this gate the DIAG log would print
    /// dozens of copies per scroll, drowning out the signal.
    /// Only log when the version changes (= a real write
    /// happened in the store) AND the user has the
    /// `logsNativeChat` Settings toggle on.
    @ObservationIgnored
    private var chatMessagesDiagVersionBySession: [String: Int] = [:]
    /// `pendingBySession` removed — streaming bubbles now go
    /// directly to `MessageCacheStore` via id-upsert (same path
    /// as final), see `MessageReceiver.receiveMessage`. The
    /// previous in-memory pending tier caused "bubbles disappear
    /// on completion" because `clearPending` nixed the entire
    /// list (including any other in-flight runs) when the
    /// lifecycle=end landed.
    @ObservationIgnored

    // MARK: - Collaborators

    let messageReceiver: MessageReceiver
    let historyLoader: HistoryLoader
    let eventInterpreter: EventInterpreter
    let sessionCoordinator: SessionCoordinator
    /// Cache store — single source of truth for persisted messages
    /// (refactor: message-cache-sot). Held by the VM so the loader and
    /// view can read from one `@Observable` instance. `@ObservationIgnored`
    /// because the VM's observers care about the store's contents
    /// (queried through `store.messages(for:)`), not the store reference
    /// itself. Defaulted to `.shared` so existing `NativeChatViewModel()`
    /// call sites in tests continue to work without an explicit injection.
    @ObservationIgnored
    let store: MessageCacheStore

// MARK: - Slash commands
    //
    // The router is the dispatch seam: it inspects the user's input
    // and either returns a `SlashCommandResult` to render locally
    // (categories A and B) or hands the text back to be sent as a
    // regular message (categories C and D, plus non-slash input).
    // The server handles the text — the LLM recognizes the slash
    // pattern, no special `kind` field needed.
    let slashCommandRouter: SlashCommandRouter
    let serverCommandSource: ServerCommandSource
    #if DEBUG
    /// Test-only seam. `sendAsMessage` invokes this closure
    /// instead of going through `SessionManager.shared` when set.
/// Production wiring leaves it `nil`; tests inject a closure
    /// that records the call on a FakeTransport.
    var sendInterceptor: (@MainActor (String) async -> Void)?
    #endif
    /// Top-5 candidates for the autocomplete popup. Refreshed
    /// via `updateAutocomplete(_:)` as the user types in the
    /// input field.
    var autocompleteCandidates: [SlashCommand] = []

    init(
        store: MessageCacheStore = MessageCacheStore.shared,
        slashCommandRouter: SlashCommandRouter? = nil,
        serverCommandSource: ServerCommandSource? = nil,
        sendInterceptor: (@MainActor (String) async -> Void)? = nil
    ) {
        let local = LocalCommandRegistry()
        let server = serverCommandSource ?? ServerCommandSource(
            transport: SessionManagerTransport()
        )
        let router = slashCommandRouter ?? SlashCommandRouter(
            local: local, server: server
        )
        self.store = store
        self.slashCommandRouter = router
        self.serverCommandSource = server
        #if DEBUG
        self.sendInterceptor = sendInterceptor
        #endif
        self.messageReceiver = MessageReceiver()
        self.historyLoader = HistoryLoader()
        self.eventInterpreter = EventInterpreter()
        self.sessionCoordinator = SessionCoordinator()
        self.messageReceiver.viewModel = self
        self.messageReceiver.store = store
        self.historyLoader.viewModel = self
        self.historyLoader.store = store
        self.eventInterpreter.viewModel = self
        self.sessionCoordinator.viewModel = self
        // Wire context for /help (merged list), /clear (clear
        // messages), and /connect (active profile name).
        local.context = self
        startConnectionObserver()
    }

    // MARK: - Connection observer
    //
    // Polls `ConnectionState.shared.phase` once a second and fires
    // `serverCommandSource.refresh()` on every transition into
    // `.connected`. The seam (SessionManagerTransport -> coordinator
    // .request) goes through the operator connection, so a refresh
    // before connect would just fail. The observer waits for the
    // next disconnect before refreshing again, so a long-lived
    // chat doesn't keep hammering the gateway.

    private var connectionObserverTask: Task<Void, Never>?

    private func startConnectionObserver() {
        connectionObserverTask?.cancel()
        connectionObserverTask = Task { [weak self] in
            while !Task.isCancelled {
                let phase = await MainActor.run { ConnectionState.shared.phase }
                if case .connected = phase {
                    await self?.serverCommandSource.refresh()
                    // Stay parked here while connected; break out
                    // when the connection drops so the outer loop
                    // re-evaluates and refreshes on the next
                    // reconnect.
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(1))
                        let s = await MainActor.run { ConnectionState.shared.phase }
                        if case .connected = s { continue }
                        break
                    }
                } else {
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    // MARK: - Public API (called by NativeChatView)

    /// Returns the cached `ChatMessage` array for `sessionKey`,
    /// converting from the underlying `OpenClawChatMessage` list
    /// on first read (or when `MessageCacheStore.version` advances).
    /// Streaming bubbles are already in the store (routed by
    /// `MessageReceiver.receiveMessage` with id-upsert), so no
    /// in-memory merge is needed.
    /// Preserves the cache's native order to avoid
    /// `Array(byId.values).sorted(...)` re-ordering entries
    /// with identical `startedAt` (a stable-order regression
    /// risk). The view's `messages` computed property is the
    /// sole caller.
    ///
    /// @Observable tracking: the SwiftUI Observation framework
    /// only tracks *direct* property accesses inside the body.
    /// Reading `store.messagesBySession[sessionKey]` through this
    /// method body would NOT register tracking on the property
    /// itself — only on whatever the method body reads first,
    /// which is `store.version`. That works today because every
    /// write path bumps `version` via `setMessages`, but it's
    /// fragile: a future writer that mutated `messagesBySession`
    /// without bumping `version` would silently miss the
    /// invalidation. The c0f1f8e fix (the original branch's
    /// direct-property-access pattern) addressed this; it was
    /// later reverted by b731a91 in favor of the conversion cache.
    ///
    /// The fix is to ALWAYS read `store.messagesBySession[sessionKey]`
    /// at the top of this method — the read registers tracking
    /// on the @Observable property, and the conversion cache
    /// short-circuits the (potentially expensive) flatMap over
    /// the array. The cost is one dict lookup per call (vs. zero
    /// before, on cache hits); the benefit is robust tracking
    /// that doesn't depend on a "version always tracks content"
    /// invariant maintained by every future writer.
    func chatMessages(for sessionKey: String) -> [ChatMessage] {
        let version = store.version
        // ALAWYS read the @Observable messagesBySession[sessionKey]
        // — this is the only line that registers tracking on the
        // actual data property. The dict lookup result is
        // intentionally unused in the cache-hit path; see the
        // method doc for the rationale.
        let _ = store.messagesBySession[sessionKey]
        let cached: [ChatMessage]
        if let hit = chatMessagesBySession[sessionKey],
           chatMessagesCachedVersionBySession[sessionKey] == version {
            cached = hit
        } else {
            let openclaw = store.messagesBySession[sessionKey] ?? []
            // TEMP DIAG: dump raw cache layer BEFORE the converter
            // hides the duplication. Gated on `logsNativeChat` AND
            // on `store.version` actually advancing (see
            // `chatMessagesDiagVersionBySession`) so the dump only
            // fires when the store's content changed, not on every
            // view re-render frame.
            if ConfigurationManager.shared.logsNativeChat,
               chatMessagesDiagVersionBySession[sessionKey] != version {
                for (i, m) in openclaw.enumerated() {
                    let textPreview = String(
                        m.content.compactMap { $0.text }
                            .joined(separator: " | ")
                            .prefix(60))
                    let thinkingPreview = String(
                        m.content.compactMap { $0.thinking }
                            .joined(separator: " | ")
                            .prefix(40))
                    AppLogger.log(
                        "[chatMessages DIAG] session=\(String(sessionKey.prefix(8))) CACHE[\(i)] id=\(m.id.uuidString.prefix(12)) role=\(m.role) ts=\(m.timestamp ?? -1) text=\"\(textPreview)\" thinking=\"\(thinkingPreview)\"",
                        category: .nativeChat)
                }
            }
            // The converter returns [ChatMessage] — flatMap because
            // a single OpenClawChatMessage (e.g. `[text, thinking]`
            // bundle) can emit 2 ChatMessages (assistant + thinking).
            let converted = openclaw.flatMap { msg in
                ChatMessageConverter.toChatMessage(from: msg)
            }
            chatMessagesBySession[sessionKey] = converted
            chatMessagesCachedVersionBySession[sessionKey] = version
            chatMessagesDiagVersionBySession[sessionKey] = version
            cached = converted
        }
        // (No pending merge — streaming bubbles now go through
        // the store via id-upsert. See MessageReceiver.receiveMessage.)
        // TEMP DIAG: dump the ChatMessage array the view is
        // about to render. Version-gated so it only fires on
        // real writes (not every body re-eval).
        if ConfigurationManager.shared.logsNativeChat,
           chatMessagesDiagVersionBySession[sessionKey] != version {
            for (i, m) in cached.enumerated() {
                let textPreview = String(m.text.prefix(60))
                AppLogger.log(
                    "[chatMessages DIAG] session=\(String(sessionKey.prefix(8))) [\(i)] id=\(String(m.id.prefix(12))) role=\(m.role) state=\(m.state ?? "nil") text=\"\(textPreview)\"",
                    category: .nativeChat)
            }
            chatMessagesDiagVersionBySession[sessionKey] = version
        }
        // Per-run display ordering: the order of events within
        // a single `runId` is determined by the **server's per-run
        // monotonic `seq`** (payload.seq), not the wall-clock
        // arrival time. The user-reported bug was that the chat
        // event (carrying the final thinking block) often arrived
        // AFTER `lifecycle=end` (carrying the response), so a
        // pure timestamp sort rendered `response → thinking` —
        // the user saw the answer before its reasoning. The seq
        // sort fixes this: every event within a run has a `seq`
        // from the server, and the server's order is the actual
        // reasoning order (whatever it is — `toolCall →
        // toolResult → thinking → assistant` is also valid if the
        // model decides to think AFTER the tool result). A fixed
        // phase priority (e.g., always thinking < toolCall <
        // assistant) was the first attempt but is wrong: it
        // forces a fixed order even when the server's order
        // differs. Using `seq` lets the server's actual order win.
        // Across runs (different `runId`, or `runId: nil` for
        // the user bubble), fall back to timestamp.
        // Overlay the in-session streaming metadata (seq /
        // startedAt / endedAt / receivedAt) BEFORE sorting, so
        // the sort can use the overlaid `receivedAt` (the
        // wall-clock of the most recent `receiveMessage` call
        // for this id) as the cross-run sort key. Without this
        // ordering, the sort would use the persisted
        // `timestamp` (the run's start time), which puts the
        // most recently active streaming bubble at the TOP —
        // the user-reported bug.
        let withMeta = applyStreamingMetadata(cached, for: sessionKey)
        let sorted = sortForDisplay(withMeta)
        // DIAG: confirms whether the runId's bubble made it into
        // the merged view. Pair this with the post-upsert log in
        // EventInterpreter to disambiguate "upsert was dropped"
        // (in-store bubble exists but view doesn't show it) from
        // "upsert was lost" (in-store bubble doesn't exist).
        // Gated on the user's `logsNativeChat` Settings toggle
        // (default ON in debug, OFF in release) so production
        // log volume is unaffected.
        if ConfigurationManager.shared.logsNativeChat {
            for msg in sorted.prefix(3) {
                AppLogger.log(
                    "[chatMessages VIEW-DIAG] session=\(String(sessionKey.prefix(8))) id=\(String(msg.id.prefix(12))) role=\(msg.role) state=\(msg.state ?? "nil") textLen=\(msg.text.count) seq=\(msg.seq ?? -1) startedAt=\(msg.startedAt != nil) endedAt=\(msg.endedAt != nil) textPreview=\"\(String(msg.text.prefix(40)))\(msg.text.count > 40 ? "…(\(msg.text.count))" : "")\"",
                    category: .nativeChat)
            }
        }
        return sorted
    }

    /// Overlay in-session streaming metadata (seq /
    /// startedAt / endedAt) onto a `ChatMessage` array. The
    /// metadata dict is populated by `MessageReceiver` BEFORE
    /// upsert (the store can't carry these fields) and read
    /// here. Without this, the view's footer
    /// `Text("#\(seq)") Text(formatTime(startedAt)) Text("→ \(formatTime(endedAt))")`
    /// would be missing for every streaming bubble.
    private func applyStreamingMetadata(_ messages: [ChatMessage], for sessionKey: String) -> [ChatMessage] {
        let metadata = streamingMetadataBySession[sessionKey] ?? [:]
        if metadata.isEmpty { return messages }
        return messages.map { msg in
            guard let m = metadata[msg.id] else { return msg }
            var withMeta = msg
            withMeta.seq = m.seq ?? msg.seq
            withMeta.startedAt = m.startedAt ?? msg.startedAt
            withMeta.endedAt = m.endedAt ?? msg.endedAt
            withMeta.receivedAt = m.receivedAt
            return withMeta
        }
    }

    private func sortForDisplay(_ messages: [ChatMessage]) -> [ChatMessage] {
        return messages.sorted { a, b in
            // Same non-nil runId → seq (server's monotonic order).
            // Missing `seq` falls back to Int.max (i.e., sort last
            // among the run's events), then to `receivedAt ?? timestamp`
            // as the final tie-breaker. `receivedAt` (set by
            // `recordStreamingMetadata` from `Date()`) is the
            // wall-clock time of the most recent
            // `receiveMessage` call for this id — using it as
            // the tie-breaker puts the most recently active
            // bubble at the bottom within a run.
            if let runA = a.runId, let runB = b.runId, runA == runB {
                let seqA = a.seq ?? Int.max
                let seqB = b.seq ?? Int.max
                if seqA != seqB { return seqA < seqB }
                let timeA = a.receivedAt ?? a.timestamp
                let timeB = b.receivedAt ?? b.timestamp
                if timeA != timeB { return timeA < timeB }
            }
            // Different runs (or either has nil runId) → use
            // `receivedAt` for in-session streaming bubbles
            // (the user expects the most recently updated
            // streaming bubble at the bottom of the list) and
            // fall back to `timestamp` for historical bubbles
            // (no overlay, defaults to the persisted value,
            // which is the run's start time as supplied by
            // chat.history).
            let timeA = a.receivedAt ?? a.timestamp
            let timeB = b.receivedAt ?? b.timestamp
            return timeA < timeB
        }
    }

    /// `appendPending` / `clearPending` / `mergePending` removed —
    /// streaming bubbles now go directly to `MessageCacheStore`
    /// via id-upsert (same path as final), see
    /// `MessageReceiver.receiveMessage`.

    /// Clears all in-memory derived state for a session. Called
    /// by `SessionCoordinator` before switching sessions.
    /// `store.clearMemory(for:)` clears the store's in-memory
    /// copy; this method clears the VM's own conversion caches
    /// and the streaming-metadata overlay cache (no more
    /// pending tier — see `MessageReceiver`).
    func clearMemory(for sessionKey: String) {
        chatMessagesBySession[sessionKey] = nil
        chatMessagesCachedVersionBySession[sessionKey] = nil
        streamingMetadataBySession[sessionKey] = nil
    }

    /// Drops the cached `ChatMessage` array for `sessionKey` so
    /// the next `chatMessages(for:)` call does a fresh conversion.
    /// Kept as a no-op for backwards compatibility with any
    /// external callers — the version-based cache invalidates
    /// automatically on any `setMessages` write in the store.
    func invalidateChatMessagesCache(for sessionKey: String) {
        chatMessagesBySession[sessionKey] = nil
        chatMessagesCachedVersionBySession[sessionKey] = nil
    }

    // MARK: - Streaming metadata overlay

    /// Captured streaming metadata (`seq` / `startedAt` /
    /// `endedAt`) keyed by session then message id. The SDK's
    /// `OpenClawChatMessage` doesn't carry these fields — its
    /// `CodingKeys` omits them and the writer at
    /// `ChatMessageConverter.toOpenClawChatMessage` drops them
    /// because the SDK init can't accept them. The store
    /// round-trip therefore silently nils them on read.
    /// `MessageReceiver` captures them here BEFORE upsert;
    /// `chatMessages(for:)` overlays them onto the converted
    /// `ChatMessage` array on read. In-memory only (no
    /// persistence) — after app restart the messages are
    /// historical and the view shows them without the
    /// seq/start/end footer anyway.
    struct StreamingMetadata {
        let seq: Int?
        let startedAt: Date?
        let endedAt: Date?
        /// Wall-clock time of the last `MessageReceiver.receiveMessage`
        /// call for this id. Used by `sortForDisplay` to put the
        /// most recently updated streaming bubble at the bottom
        /// across runIds (the persisted `timestamp` is the run's
        /// start time, which puts the FINAL of an older run BELOW
        /// the placeholder of a newer run — opposite of the user's
        /// "latest update at the bottom" expectation).
        let receivedAt: Date
    }

    /// In-memory overlay for `seq` / `startedAt` / `endedAt`.
    @ObservationIgnored
    private var streamingMetadataBySession: [String: [String: StreamingMetadata]] = [:]

    /// Record `seq`/`startedAt`/`endedAt` from an incoming
    /// message so the view can render them after the store
    /// round-trip drops them. Called by `MessageReceiver`
    /// BEFORE the `store.upsert` (the message retains the
    /// metadata at the call site; the store receives the
    /// SDK-shaped message without it).
    func recordStreamingMetadata(for message: ChatMessage) {
        guard let sessionKey = selectedSession?.key else { return }
        // The overlay key must match what `chatMessages(for:)`
        // sees on read — the post-conversion UUID string. A
        // streaming placeholder uses `id: runId` (a non-UUID
        // string like "r-meta-1"); `toOpenClawChatMessage`
        // maps that to a deterministic UUID via
        // `ChatMessageConverter.deterministicUUID(from:)`.
        // `toChatMessage` reads it back as the UUID string.
        // Storing metadata under the raw runId would miss every
        // lookup; normalize to the deterministic UUID here.
        let normalizedId: String
        if UUID(uuidString: message.id) != nil {
            normalizedId = message.id
        } else {
            normalizedId = ChatMessageConverter.deterministicUUID(from: message.id).uuidString
        }
        let metadata = StreamingMetadata(
            seq: message.seq,
            startedAt: message.startedAt,
            endedAt: message.endedAt,
            receivedAt: Date()
        )
        var perSession = streamingMetadataBySession[sessionKey] ?? [:]
        perSession[normalizedId] = metadata
        streamingMetadataBySession[sessionKey] = perSession
        // The conversion cache (chatMessagesBySession) holds
        // ChatMessages WITHOUT the metadata; invalidate it so
        // the next read re-converts + re-overlays.
        chatMessagesBySession[sessionKey] = nil
        chatMessagesCachedVersionBySession[sessionKey] = nil
    }

    func setSelectedProfile(_ profileId: UUID?) {
        if selectedProfileId != profileId {
            selectedProfileId = profileId
        }
    }

    func loadSessions() {
        sessionCoordinator.loadSessions()
    }

    func loadedSessions(_ sessions: [OpenClawChatSessionEntry]) {
        sessionCoordinator.loadedSessions(sessions)
    }

    func selectSession(_ session: OpenClawChatSessionEntry) {
        sessionCoordinator.selectSession(session)
    }

    func switchProfile(_ newProfileId: UUID) {
        sessionCoordinator.switchProfile(newProfileId)
    }

    func createSession() {
        sessionCoordinator.createSession()
    }

    func sessionCreated(_ sessionKey: String) {
        sessionCoordinator.sessionCreated(sessionKey)
    }

    func sendMessage() async {
        guard !inputText.isEmpty else { return }
        guard let sessionKey = selectedSession?.key else { return }
        let text = inputText
        withAnimation(.easeInOut(duration: 0.18)) {
            inputText = ""
            autocompleteCandidates = []
        }

        let dispatch = await slashCommandRouter.dispatch(text)
        switch dispatch {
        case .execute(let result):
            await handleCommandResult(result, sessionKey: sessionKey)
        case .passthrough:
            await sendAsMessage(text)
        }
    }

    private func handleCommandResult(_ result: SlashCommandResult, sessionKey: String) async {
        switch result {
        case .bubble(let text):
            await appendSystemBubble(text, sessionKey: sessionKey)
        case .clearAndBubble(let text):
            // The clear + append happens here (awaited) so the
            // bubble lands AFTER the wipe on the store actor.
            // LocalCommandRegistry's /clear executor also calls
            // `LocalCommandContext.clearLocalMessages()` before
            // returning `.clearAndBubble` — that path is a
            // fire-and-forget Task and may not have completed by
            // the time we get here. Awaiting the clear here is the
            // authoritative one; the protocol call is kept for
            // symmetry with future local commands that want to
            // clear without going through the router.
            await store.clear(for: sessionKey)
            await appendSystemBubble(text, sessionKey: sessionKey)
        case .silent:
            break
        }
        isSending = false
        scrollRequest = NativeChatScrollRequest(
            token: scrollRequest.token &+ 1, kind: .newMessage
        )
    }

    private func appendSystemBubble(_ text: String, sessionKey: String) async {
        let msg = ChatMessage(
            id: UUID().uuidString, text: text, timestamp: Date(),
            role: "system", state: "final", runId: nil, seq: nil,
            startedAt: nil, endedAt: nil, livenessState: nil,
            toolCallId: nil, toolName: nil, stopReason: nil,
            isFresh: true
        )
        // Persist via the cache store (single source of truth). The
        // view observes `store.messages(for: sessionKey)` and will
        // pick this up via the store's @Observable change notification.
        if let openclaw = ChatMessageConverter.toOpenClawChatMessage(from: msg) {
            await store.append([openclaw], for: sessionKey)
        }
    }

    private func sendAsMessage(_ text: String) async {
        guard let session = selectedSession else { return }
        isSending = true
        let sessionKey = session.key
        let textPreview = String(text.prefix(100))
AppLogger.log(
            "sendMessage role=user text_len=\(text.count) text_preview=\(textPreview)",
            category: .nativeChat
        )
        let message = ChatMessage(
            id: UUID().uuidString,
            text: text,
            timestamp: Date(),
            role: "user",
            state: "final",
            runId: nil,
            seq: nil,
            startedAt: nil,
            endedAt: nil,
            livenessState: nil,
            toolCallId: nil,
            toolName: nil,
            stopReason: nil,
            isFresh: true
        )
        // Without this scroll request, the viewport stays at the
        // pre-send position until `isSending` flips false (lifecycle end,
        // which can be 10+ seconds for a long response). The view's
        // `.newMessage` handler scrolls to the new last id (this very
        // user message) so the user sees the bubble land at the bottom.
//
        // Bump the scroll request AFTER the user bubble lands in the
        // store. If we bump it before `store.append`, the multi-poll
        // scroll handler runs and targets `bottomAnchorId` before the
        // user bubble exists, so the viewport stays at the pre-send
        // position until the first streaming delta bumps `scrollRequest`
        // again (UX gap of ~1-10s where the user-sent bubble is missing).
        inputText = ""
        // Persist user message to the cache store (single source of
        // truth for the view's message list). The view reads from
        // `viewModel.store.messagesBySession` via the new computed
        // property in `NativeChatView`, so the bubble appears without
        // needing a per-VM message array mirror.
        if let openclaw = ChatMessageConverter.toOpenClawChatMessage(from: message) {
            Task { @MainActor in
                await store.append([openclaw], for: sessionKey)
                // forceScroll: true — the user just sent a message
                // and explicitly wants the viewport to land on it.
                // Without this, the view's `.newMessage` handler
                // gates on `!userHasScrolled`, so a user who scrolled
                // up to read history before sending would not see
                // their outgoing message land at the bottom.
                scrollRequest = NativeChatScrollRequest(
                    token: scrollRequest.token &+ 1,
                    kind: .newMessage,
                    forceScroll: true
                )
            }
        }
// Test seam: when a `sendInterceptor` closure was injected,
        // invoke it and return — the real SessionManager + transport
        // dance is bypassed. The `sendInterceptor` property itself is
        // DEBUG-only (so production builds can't even reference it),
        // and production code always falls through to the real
        // transport below.
        #if DEBUG
        if let interceptor = sendInterceptor {
            await interceptor(text)
            isSending = false
            return
        }
#endif
        Task {
            do {
                try await SessionManager.shared.ensureConnected()
                let transport = await SessionManager.shared.makeTransport(sessionKey: sessionKey)
                // Re-assert the session's server-level reasoning gate
                // before every send. Without reasoningLevel = "stream",
                // the openclaw server's subscribeEmbeddedAgentSession:172
                // short-circuits and never emits stream=thinking events —
                // even when the provider emits reasoning blocks. Until
                // a per-session UI exists, hardcode "medium" (the
                // server's default for the current model). This is
                // best-effort: a failure here must NOT fail the user's
                // send, since the agent run can still proceed without
                // the thinking stream.
                do {
                    try await transport.setSessionThinking(
                        sessionKey: sessionKey,
                        thinkingLevel: "medium"
                    )
                } catch {
                    AppLogger.log(
                        "setSessionThinking pre-send failed: \(error.localizedDescription)",
                        category: .nativeChat,
                        level: .warning
                    )
                }
                // Start event listening task - pass sessionKey to check later
                Task {
                    for await evt in transport.events() {
                        // Read the user's current view from our own state
                        // (the single source of truth). The previous
                        // SessionManager.getCurrentSessionKey() check
                        // raced against loadSessions' `makeTransport("")`
                        // which clobbered `currentSessionKey` for the
                        // duration of the refresh. The enclosing Task
                        // inherits this type's @MainActor isolation, so a
                        // direct read of `self.selectedSession?.key` is
                        // safe here — no MainActor.run round-trip needed.
                        let currentKey = self.selectedSession?.key
                        if currentKey == sessionKey {
                            await self.handleTransportEvent(evt, sessionKey: sessionKey)
                        }
                    }
                }
                // Send message
                _ = try await transport.sendMessage(
                    sessionKey: sessionKey,
                    message: text,
                    thinking: "",
                    idempotencyKey: UUID().uuidString,
                    attachments: []
                )
                AppLogger.log("Message sent, waiting for response...", category: .nativeChat)
                // Arm the watchdog AFTER the RPC has been accepted.
                // If we armed it before the await, the timeout would
                // include the chat.send RTT (which is 35s ceiling in
                // the gateway transport) plus the agent run — the
                // user-perceived "still spinning" window would be
                // much larger than the configured 90s. Starting here
                // means the watchdog's 90s budget is for "server
                // accepted but never followed up with lifecycle end",
                // which is the only failure mode we can recover from
                // by force-resetting isSending.
                self.armSendTimeout()
            } catch {
                AppLogger.log("Send message error: \(error.localizedDescription)", category: .nativeChat, level: .error)
                self.setError(error.localizedDescription)
                // `setError` already calls `setSending(false)` which
                // also cancels any pending watchdog.
                self.setSending(false)
            }
        }
    }

    /// Refresh the autocomplete popup candidates for the given
    /// input. Called by the view on every keystroke. Wrapped in
    /// `withAnimation` so the popup's `.transition(.move(...))`
    /// actually animates (SwiftUI only animates view-tree changes
    /// when the mutation is inside a `withAnimation` block or
    /// behind a `.animation(_:value:)` modifier).
    public func updateAutocomplete(_ text: String) {
        withAnimation(.easeInOut(duration: 0.18)) {
            autocompleteCandidates = slashCommandRouter.filter(text)
        }
    }

    func loadHistory() {
        historyLoader.loadHistory()
    }

    /// Reset `isSending` to false and cancel the send-watching
    /// watchdog. Called from `EventInterpreter` when a terminal
    /// `lifecycle end` event arrives, which is the normal
    /// post-response signal. Going through this method (instead of
    /// a direct `isSending = false` assignment) ensures the
    /// watchdog gets cancelled; otherwise a `lifecycle end` that
    /// lands within the timeout window would still race against
    /// the watchdog's pending reset (harmless, but wastes a Task
    /// wakeup and is harder to reason about).
    func resetSendState() {
        setSending(false)
    }

    /// User-initiated pull-up refresh. Re-runs the network step of
    /// `loadHistory()` for the current session without showing the
    /// cache first (the user is already looking at the cache). Sets
    /// `isManualRefreshing = true` for the duration so the view can
    /// show a spinner. Re-entrancy is guarded by the same per-session
    /// lock as `loadHistory()`. On new messages, fires a
    /// `.manualRefresh` scroll request (single scroll, bypasses
    /// `userHasScrolled`); on no new messages or network error, stays
    /// silent.
    func refreshFromServer() {
        historyLoader.refreshFromServer()
    }

    func loadMoreHistory() {}

    func receiveMessage(_ message: ChatMessage) async {
        await messageReceiver.receiveMessage(message)
    }

    private func setError(_ error: String?) {
        self.error = error
        isLoading = false
        setSending(false)
    }

    private func setSending(_ value: Bool) {
        isSending = value
        // Cancel the watchdog on every transition. The watchdog's
        // job is to flip `isSending` back to false if no terminal
        // event lands in time; once `isSending` is false (or being
        // re-armed by a fresh `sendMessage`), the watchdog for the
        // previous run is moot. `lifecycle end` and the catch
        // branch both go through `setSending(false)`, so this single
        // cancel point covers every legitimate reset path.
        sendTimeoutTask?.cancel()
        sendTimeoutTask = nil
    }

    /// Arm the `isSending` watchdog. If `lifecycle end` doesn't
    /// arrive within `sendTimeout`, this flips `isSending` back to
    /// false and surfaces a timeout error. Called from `sendMessage`
    /// after `chat.send` is dispatched. Re-arming is a no-op if a
    /// watchdog is already running.
    private func armSendTimeout() {
        sendTimeoutTask?.cancel()
        let timeout = sendTimeout
        sendTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                // Cancelled (lifecycle end arrived in time, or the
                // user sent another message). Nothing to do.
                return
            }
            // Timed out. Only flip state if we're still waiting on
            // the same run — re-check inside the actor, since the
            // user may have cancelled-and-resent in the meantime.
            await MainActor.run {
                guard let self else { return }
                guard self.isSending else { return }
                AppLogger.log("sendMessage watchdog fired after \(timeout) — no lifecycle end; resetting isSending and surfacing timeout", category: .nativeChat, level: .warning)
                self.setError("Request timed out after \(timeout.components.seconds)s with no reply; please retry.")
            }
        }
    }

    private func loadedMoreHistory(_ messages: [ChatMessage], hasMore: Bool) {
        // No-op for now; placeholder for future pagination.
    }

    // MARK: - Transport event handling

    private func handleTransportEvent(_ event: OpenClawChatTransportEvent, sessionKey: String) async {
        await eventInterpreter.handleTransportEvent(event, sessionKey: sessionKey)
    }

    // MARK: - Helpers

    // (no helpers — ChatMessageConverter handles ChatMessage ↔ OpenClawChatMessage)
}

// MARK: - LocalCommandContext
//
// The local registry holds a weak ref to the view-model so the
// built-in /help, /clear, /connect, /profiles commands can read
// merged state (merged command list, message store, active
// profile) without coupling the registry to the view-model type.
extension NativeChatViewModel: LocalCommandContext {
    func clearLocalMessages() {
        // Called by LocalCommandRegistry's /clear executor before
        // returning `.clearAndBubble("Chat cleared")` to the router.
        // The actual clear runs in a Task so we don't block the
        // synchronous MainActor.run site; the subsequent bubble
        // append (via `handleCommandResult`) is queued after this
        // on the store actor, so the bubble lands in a cleared
        // session.
        guard let sessionKey = selectedSession?.key else { return }
        Task { @MainActor in
            await store.clear(for: sessionKey)
        }
    }
    var mergedCommands: [SlashCommand] {
        slashCommandRouter.merged
    }
    var activeProfileName: String {
        ProfileManager.shared.profiles
            .first(where: { $0.isActive })?.name ?? "gateway"
    }
}

// MARK: - SessionManagerTransport
//
// Production adapter from `ServerCommandTransport` to
// `SessionManager.request`. The seam landed in 982a1de:
// `SessionManager.request` -> `ConnectionCoordinator.request` ->
// the private `operatorTransport.request`. This struct is the
// only place slash-command code knows about SessionManager; the
// rest of the system talks to the narrow `ServerCommandTransport`
// protocol so tests can swap in a fake.
private final class SessionManagerTransport: ServerCommandTransport, @unchecked Sendable {
    func send(method: String, paramsJSON: String) async throws -> Data {
        try await SessionManager.shared.request(
            method: method,
            paramsJSON: paramsJSON,
            timeoutSeconds: 15
        )
    }
}
