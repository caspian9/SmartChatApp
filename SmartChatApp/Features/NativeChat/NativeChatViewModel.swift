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
    /// N5 (audit 2026-07-07): per-session flag for the
    /// "old-format entries detected" migration log.
    /// `sortForDisplay` switched to prioritize `endedAt`
    /// within a run; entries persisted BEFORE that change
    /// lack `endedAt` and would silently fall back to
    /// `Date.distantPast` (placing them BEFORE newer
    /// same-run entries). Log once per session per launch
    /// so the user can recognize that an old session may
    /// render with the wrong order until the entries are
    /// re-saved with `endedAt` populated. Re-entering the
    /// session on next launch will refresh the entries
    /// (the `lifecycle=end` upsert carries `endedAt`).
    @ObservationIgnored
    private var endedAtMigrationLoggedSessions: Set<String> = []
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
               ConfigurationManager.shared.logsChatMessagesCacheDump,
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
            // N5 (audit 2026-07-07): one-time per-session
            // log when this session contains pre-sort-change
            // entries. The signature: at least one converted
            // entry carries a `runId` but no `endedAt`
            // AND no `seq` — that combination only matches
            // entries persisted before the
            // sortForDisplay endedAt-priority change
            // (2026-07-07), because post-change
            // streaming entries always carry both. New
            // entries written by `fetchAndMergeFromNetwork`
            // also lack `endedAt` (the server's chat.history
            // doesn't supply it), but those entries also
            // lack a `runId` (they're keyed by server UUID,
            // not the streaming runId) so they're
            // excluded by the `runId != nil` filter.
            //
            // Logged at `.info` so it's visible by
            // default but doesn't fire on every
            // `chatMessages(for:)` call.
            if !endedAtMigrationLoggedSessions.contains(sessionKey) {
                let needsMigration = converted.contains(where: { msg in
                    msg.runId != nil && msg.endedAt == nil && msg.seq == nil
                })
                if needsMigration {
                    AppLogger.log(
                        "[chatMessages] endedAt migration detected: session=\(String(sessionKey.prefix(8))) has entries with runId but no endedAt/seq — these are pre-2026-07-07 persisted entries; sortForDisplay will sort them with Date.distantPast until they're re-saved. Re-entering the session will refresh them on next streaming run.",
                        category: .nativeChat, level: .info)
                    endedAtMigrationLoggedSessions.insert(sessionKey)
                }
            }
        }
        // (No pending merge — streaming bubbles now go through
        // the store via id-upsert. See MessageReceiver.receiveMessage.)
        // TEMP DIAG: dump the ChatMessage array the view is
        // about to render. Version-gated so it only fires on
        // real writes (not every body re-eval).
        if ConfigurationManager.shared.logsNativeChat,
           ConfigurationManager.shared.logsChatMessagesRenderDump,
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
        // Gated on `logsNativeChat` AND `logsChatMessagesRenderDump`
        // (same toggle as the post-converter dump at line 264 — both
        // are view-side renders of the converted [ChatMessage]
        // array; this one fires after `applyStreamingMetadata` +
        // `sortForDisplay` and prints the top-3 of what the view
        // is about to render).
        if ConfigurationManager.shared.logsNativeChat,
           ConfigurationManager.shared.logsChatMessagesRenderDump {
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
            // Restore `runId` so `sortForDisplay` can group
            // same-run bubbles for the endedAt-priority branch.
            // `OpenClawChatMessage` has no `runId` field, so the
            // store round-trip drops it; without this overlay
            // every persisted bubble has `runId == nil` and the
            // sort always falls through to the cross-run branch.
            // Only overlay when the metadata has a non-nil
            // runId — a nil metadata runId (e.g. for a user
            // message that doesn't belong to a run) must not
            // overwrite a present `msg.runId`.
            if let overlayRunId = m.runId {
                withMeta.runId = overlayRunId
            }
            withMeta.seq = m.seq ?? msg.seq
            withMeta.startedAt = m.startedAt ?? msg.startedAt
            withMeta.endedAt = m.endedAt ?? msg.endedAt
            withMeta.receivedAt = m.receivedAt
            // Restore `state` (issue #47 bug 2): the converter
            // hardcodes `state = "final"` for every persisted
            // message, so without this overlay a streaming
            // placeholder reads as `"final"` to the view and the
            // `TypingIndicatorView` branch never fires. Only
            // overlay when the metadata has a non-nil state —
            // `nil` means the helper has no record (e.g. the
            // message predates this overlay's existence, or was
            // written by a path that doesn't call
            // `recordStreamingMetadata`); in that case trust the
            // converter's `"final"` so we don't accidentally
            // resurrect a finished bubble. The "streaming" value
            // is only ever captured from a `receiveMessage` call
            // that ran with `message.state == "streaming"`.
            if let overlayState = m.state {
                withMeta.state = overlayState
            }
            return withMeta
        }
    }

    private func sortForDisplay(_ messages: [ChatMessage]) -> [ChatMessage] {
        return messages.sorted { a, b in
            // Paired toolCall / toolResult structural tie-breaker
            // (FIX-9 follow-up, user-reported 2026-07-08, log
            // 08:55:20.913Z). The toolCall and toolResult
            // bubbles for a single execution share the same
            // `toolCallId` (set by both `case "item"` line 1361
            // and `case "command_output"` line 1485 in
            // `EventInterpreter`). They form a semantic pair
            // (call → result) and the call MUST appear before
            // the result in the view, regardless of arrival
            // order.
            //
            // Why this matters: when P1 fix (runId
            // preservation) is in place, both bubbles share
            // the same `runId` and the same-runId branch
            // (line 504) sorts by `endedAt` — the toolCall
            // has `endedAt == nil` → `Date.distantPast`, the
            // toolResult has `endedAt` from the
            // `command_output (end)` server ts, so the
            // toolCall sorts first. With P1 fix stashed (this
            // build), `runId` is nil and the sort falls
            // through to the cross-run branch (line 523) which
            // uses `receivedAt ?? timestamp` — and
            // `receivedAt` reflects the local arrival order.
            // When the gateway emits `command_output` events
            // BEFORE the `item phase=start` event for the
            // same tool (or the client processes them out of
            // order), the toolResult's `receivedAt` ends up
            // EARLIER than the toolCall's, and the cross-run
            // sort puts the toolResult ABOVE the toolCall —
            // exactly the user-reported display regression.
            //
            // The fix: detect a toolCall/toolResult pair by
            // matching `toolCallId` + role, and force the
            // call before the result. Symmetric for the
            // reversed a/b order. Applied as the FIRST check
            // in the closure so it overrides the timestamp-
            // based fallback below.
            if let tcA = a.toolCallId, !tcA.isEmpty,
               let tcB = b.toolCallId, !tcB.isEmpty,
               tcA == tcB {
                let isCallA = a.role == "toolCall"
                let isResultA = a.role == "toolResult"
                let isCallB = b.role == "toolCall"
                let isResultB = b.role == "toolResult"
                if isCallA && isResultB { return true }
                if isResultA && isCallB { return false }
                // Same role + same toolCallId — fall through
                // to the normal sort (rare: the streaming
                // path normally produces exactly one of each
                // per execution).
            }
            // Same non-nil runId → sort by the server's
            // event-time order. Priority:
            //   1. `endedAt` — the server's `payload.endedAt` /
            //      lifecycle=end / `command_output` (end) /
            //      `item` (end) timestamp. Reflects WHEN THE
            //      EVENT ACTUALLY HAPPENED on the server, not
            //      when the client received it. This is the
            //      correct sort key for inter-stream ordering
            //      (e.g. toolResult BEFORE assistant final
            //      when the server actually finished the tool
            //      before emitting the lifecycle=end, even if
            //      the wire order is reversed due to buffering
            //      or socket flush timing).
            //   2. `seq` — server's monotonic per-stream seq.
            //      Tiebreaker for events within the SAME
            //      stream that share an endedAt.
            //   3. `receivedAt ?? timestamp` — last resort,
            //      for events missing both `endedAt` and
            //      `seq`.
            if let runA = a.runId, let runB = b.runId, runA == runB {
                let endA = a.endedAt ?? Date.distantPast
                let endB = b.endedAt ?? Date.distantPast
                if endA != endB { return endA < endB }
                let seqA = a.seq ?? Int.max
                let seqB = b.seq ?? Int.max
                if seqA != seqB { return seqA < seqB }
                let timeA = a.receivedAt ?? a.timestamp
                let timeB = b.receivedAt ?? b.timestamp
                if timeA != timeB { return timeA < timeB }
            }
            // Different runs (or either has nil runId) —
            // server-side event time is the most accurate
            // signal. `endedAt` is the server's
            // `payload.endedAt` / lifecycle=end /
            // `command_output (end)` / `item` (end) timestamp
            // — it reflects WHEN THE EVENT ACTUALLY HAPPENED
            // on the server, not when the client received it.
            //
            // FIX-9 follow-up #2 (user-reported 2026-07-08,
            // log 09:01:58.618Z CACHE[27-29]): with P1 fix
            // (runId preservation) STASHED, the cross-run
            // fallback was `receivedAt ?? timestamp` —
            // sorting by client arrival order. When the
            // gateway's `command_output (end)` event
            // arrives at the device AFTER the subsequent
            // `lifecycle=end` (e.g., network jitter, gateway
            // buffer flush), the toolResult's `receivedAt`
            // is later than the assistant final's. The sort
            // then puts the toolResult BELOW the assistant
            // final — the user sees `toolCall → assistant →
            // toolResult` instead of the semantically correct
            // `toolCall → toolResult → assistant` (the tool
            // result is the input to the assistant's
            // response, so it must appear BEFORE the
            // response).
            //
            // The wire/server event times have a guaranteed
            // order: the tool finishes (`command_output end`)
            // before the lifecycle ends (`lifecycle end`).
            // Promoting `endedAt` to the primary cross-run
            // key recovers that semantic order. The
            // hierarchy:
            //   1. `endedAt` — server event completion
            //      time, when available.
            //   2. `receivedAt` — local arrival time, for
            //      streaming bubbles that haven't yet
            //      received a terminal event (toolCall with
            //      only `phase=start` so far — no `endedAt`
            //      until `phase=end`).
            //   3. `timestamp` — persisted field; for
            //      historical entries that never went
            //      through the streaming path (no metadata
            //      overlay). Defaults to the run's start
            //      time as supplied by `chat.history`.
            let timeA = a.endedAt ?? a.receivedAt ?? a.timestamp
            let timeB = b.endedAt ?? b.receivedAt ?? b.timestamp
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
        // Drop the runId → sessionKey entries for the session
        // being cleared — stale entries would pin a runId to a
        // session the user navigated away from.
        runSessionKeyByRunId = runSessionKeyByRunId.filter { $0.value != sessionKey }
        // Drop pending buffer entries mapped to the cleared
        // session — they belong to runs that were confirmed for
        // this session, no point holding them across a switch.
        for (runId, _) in pendingAgentBuffer {
            if runSessionKeyByRunId[runId] == sessionKey {
                dropPending(for: runId)
            }
        }
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

    // MARK: - Nested-run routing (issue #34)

    /// In-memory runId → sessionKey routing table. Not persisted;
    /// rebuilt on every chat event via `chat.sessionKey`. Strict
    /// policy: a runId only enters the map once a chat event with
    /// a non-nil `chat.sessionKey` confirms the run's true session.
    /// Agent events alone are NOT authoritative — they can fire for
    /// nested runs on OTHER sessions while the user is viewing the
    /// parent session, so pre-claiming them as "current session"
    /// would leak bubbles into the wrong view.
    /// `@ObservationIgnored` — internal bookkeeping, never read by
    /// views. Never call from a SwiftUI view `body` — non-observed
    /// property.
    @ObservationIgnored
    private var runSessionKeyByRunId: [String: String] = [:]

    /// In-memory buffer of ChatMessages whose runId is not yet
    /// confirmed (no chat event with `sessionKey` has arrived).
    /// Keyed by runId. Capacity-capped per runId (`pendingMaxPerRun`,
    /// default 50) to bound memory under pathological streams.
    /// Entries are flushed to the cache via `flushPending(for:)`
    /// once the runId's session is confirmed (chat event) or after
    /// `pendingTimeout` elapses (assume it was the current session).
    /// `@ObservationIgnored` — internal bookkeeping.
    @ObservationIgnored
    private var pendingAgentBuffer: [String: [ChatMessage]] = [:]

    /// Per-runId timeout tasks. Cancelled when the runId's session
    /// is confirmed before the timeout fires.
    @ObservationIgnored
    private var pendingFlushTasks: [String: Task<Void, Never>] = [:]

    /// Per-runId cap for `pendingAgentBuffer` to prevent unbounded
    /// growth in pathological cases (e.g., a nested run that never
    /// emits a chat event). When exceeded, the OLDEST buffered
    /// message is evicted (FIFO).
    private let pendingMaxPerRun: Int = 50

    /// How long to wait before flushing a runId's pending buffer to
    /// the currently-selected session. Long enough to cover a normal
    /// chat event's round-trip (a few hundred ms server-side); short
    /// enough that a user won't perceive a multi-second delay on
    /// the placeholder bubble.
    private let pendingTimeout: TimeInterval = 5.0

    /// Returns the session key the given `runId` belongs to.
    /// Returns nil for unmapped runIds — strict gate forces the
    /// caller to defer the message until a chat event confirms the
    /// session. `nil` runId (user-sent, slash echoes) falls through
    /// to `selectedSession?.key` — those messages are always
    /// local-to-session.
    func route(for runId: String?) -> String? {
        if let runId, let target = runSessionKeyByRunId[runId] {
            return target
        }
        if runId == nil { return selectedSession?.key }
        return nil
    }

    /// Records the session key for an incoming runId.
    /// `overwriteIfExisting == true` overwrites — used for
    /// SDK-declared `.chat.sessionKey` (the authoritative source).
    /// Without that flag, the FIRST recorded session wins; the
    /// recording is sticky across session switches (a run that
    /// started in A stays mapped to A even if the user navigates
    /// to B).
    func recordRunSession(_ sessionKey: String?, for runId: String, overwriteIfExisting: Bool = false) {
        if overwriteIfExisting || runSessionKeyByRunId[runId] == nil {
            runSessionKeyByRunId[runId] = sessionKey
        }
    }

    /// Buffers a ChatMessage whose runId is not yet confirmed.
    /// Called from `MessageReceiver.receiveMessage` when the gate
    /// rejects due to an unmapped runId. Caps the per-runId buffer
    /// at `pendingMaxPerRun` (FIFO eviction) and arms a flush
    /// timeout if one isn't already armed for this runId.
    func bufferPendingAgent(_ message: ChatMessage, for runId: String) {
        var buffer = pendingAgentBuffer[runId] ?? []
        if buffer.count >= pendingMaxPerRun {
            buffer.removeFirst(buffer.count - pendingMaxPerRun + 1)
        }
        buffer.append(message)
        pendingAgentBuffer[runId] = buffer
        // Arm the timeout only on the first message for a runId.
        if pendingFlushTasks[runId] == nil {
            pendingFlushTasks[runId] = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .seconds(self.pendingTimeout))
                if !Task.isCancelled {
                    await self.flushPendingAsTimeout(forRunId: runId)
                }
            }
        }
    }

    /// Flushes buffered messages for a runId once its session is
    /// confirmed by a chat event. Routes each buffered message
    /// directly to the runId's mapped sessionKey via
    /// `MessageReceiver.flushToSession` — bypassing the gate,
    /// because the user is typically still viewing a different
    /// session while a nested run's chat event arrives. The
    /// chat-event-declared sessionKey is authoritative; the gate
    /// would otherwise reject the buffered message and discard
    /// it. Cancels the runId's timeout task.
    func flushPending(for runId: String) async {
        pendingFlushTasks[runId]?.cancel()
        pendingFlushTasks[runId] = nil
        guard let buffered = pendingAgentBuffer[runId], !buffered.isEmpty else {
            pendingAgentBuffer[runId] = nil
            return
        }
        pendingAgentBuffer[runId] = nil
        let targetSessionKey = runSessionKeyByRunId[runId] ?? selectedSession?.key
        guard let targetSessionKey else { return }
        for message in buffered {
            await messageReceiver.flushToSession(message, sessionKey: targetSessionKey)
        }
    }

    /// Flushes buffered messages for a runId as a timeout fallback —
    /// assume the run was for the currently-selected session. Called
    /// when the chat event never arrived within `pendingTimeout`.
    /// Records the runId against the selected session first, so the
    /// gate's `route(for:)` returns the right target.
    private func flushPendingAsTimeout(forRunId runId: String) async {
        let target = selectedSession?.key
        if let target {
            recordRunSession(target, for: runId)
        }
        await flushPending(for: runId)
    }

    /// Drops any pending buffer entries for a runId. Used when a
    /// session is cleared (`clearMemory(for:)`) to prevent stale
    /// buffers from re-routing after the user navigates back.
    func dropPending(for runId: String) {
        pendingFlushTasks[runId]?.cancel()
        pendingFlushTasks[runId] = nil
        pendingAgentBuffer[runId] = nil
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
        /// The streaming run id (e.g. `<runId>:assistant:0` →
        /// `<runId>` extracted, or whatever the streaming path
        /// sets on `ChatMessage.runId`). Used by `sortForDisplay`
        /// to group same-run bubbles for the endedAt-priority
        /// branch — without this field, every persisted bubble
        /// has `runId == nil` after the store round-trip
        /// (`OpenClawChatMessage` has no `runId` field, so the
        /// round-trip drops it) and the sort's
        /// `if let runA = a.runId, runA == runB` guard is
        /// always false. Captured here so `applyStreamingMetadata`
        /// can restore it before sort.
        let runId: String?
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
        /// Streaming state (`"streaming"` vs `"final"`) at the
        /// last `receiveMessage` call. **Required** for the view's
        /// `TypingIndicatorView` + `#\(seq)` footer + `→ HH:MM`
        /// end-time footer to reflect "in-flight" vs "done": the
        /// `ChatMessageConverter` hardcodes every persisted
        /// message's `state` to `"final"` (the SDK's
        /// `OpenClawChatMessage` has no `state` field, so the
        /// round-trip collapses both streaming and final writes to
        /// `state == "final"`). Without this overlay the view
        /// sees a streaming placeholder as a finished bubble —
        /// no typing dots, but `#\(seq)` / `HH:mm` still show
        /// because those are overlaid separately. Captured here
        /// and restored by `applyStreamingMetadata` so the bubble
        /// re-acquires the in-flight state before render. Set to
        /// `nil` when the helper has no record (treated as
        /// "trust the converter's `final"`).
        let state: String?
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
            runId: message.runId,
            seq: message.seq,
            startedAt: message.startedAt,
            endedAt: message.endedAt,
            receivedAt: Date(),
            // Carry the in-flight flag through the store
            // round-trip. The `ChatMessageConverter` hardcodes
            // every persisted message's `state` to `"final"`
            // (the SDK's `OpenClawChatMessage` has no `state`
            // field); without this overlay the view sees a
            // streaming placeholder as finished — no typing dots
            // (issue #47 bug 2). See the `StreamingMetadata.state`
            // doc for the full rationale.
            state: message.state
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
            await handleCommandResult(text, result, sessionKey: sessionKey)
        case .passthrough:
            await sendAsMessage(text)
        }
    }

    private func handleCommandResult(_ text: String, _ result: SlashCommandResult, sessionKey: String) async {
        switch result {
        case .bubble(let resultText):
            await appendUserBubble(text, sessionKey: sessionKey)
            await appendSystemBubble(resultText, sessionKey: sessionKey)
        case .clearAndBubble(let resultText):
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
            await appendUserBubble(text, sessionKey: sessionKey)
            await appendSystemBubble(resultText, sessionKey: sessionKey)
        case .silent:
            await appendUserBubble(text, sessionKey: sessionKey)
        }
        isSending = false
        scrollRequest = NativeChatScrollRequest(
            token: scrollRequest.token &+ 1, kind: .newMessage
        )
    }

    /// Persists the user-typed text as a user-role bubble. Used by
    /// the slash-command path so local commands (e.g. `/help`,
    /// `/disconnect`) render with the same outgoing bubble shape as
    /// server commands — closing the UX gap where the user's typed
    /// input was invisible (issue #36).
    ///
    /// Mirrors `appendSystemBubble`'s shape but with `role: "user"`
    /// and no runId/seq metadata (slash commands don't enter a
    /// streaming run; the bubble is a final outgoing message).
    private func appendUserBubble(_ text: String, sessionKey: String) async {
        let msg = ChatMessage(
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
        if let openclaw = ChatMessageConverter.toOpenClawChatMessage(from: msg) {
            await store.append([openclaw], for: sessionKey)
        }
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
        // Record the runId → sessionKey mapping BEFORE
        // dispatching to EventInterpreter. The
        // `MessageReceiver.receiveMessage` gate (issue #34)
        // consults this map to reject events whose target
        // session ≠ the currently-selected session.
        //
        // Strict policy (replaces the first-event-wins version):
        //   - `.chat`: SDK-provided `chat.sessionKey` is the
        //     ONLY authoritative source. Record with
        //     `overwriteIfExisting: true` and flush any pending
        //     agent events buffered for this runId.
        //   - `.agent`: do NOT pre-claim the runId. The agent
        //     stream can fire for nested runs on OTHER sessions
        //     while the user is viewing the parent; claiming
        //     based on `selectedSession` would leak. The agent
        //     event's `runId` is held in `MessageReceiver`'s
        //     pending buffer until the chat event confirms.
        switch event {
        case .chat(let chat):
            if let runId = chat.runId, let chatSessionKey = chat.sessionKey {
                recordRunSession(chatSessionKey, for: runId, overwriteIfExisting: true)
                // Flush any agent events buffered for this runId;
                // the gate now passes because the map is set.
                await flushPending(for: runId)
            }
        case .agent:
            // No recording. The agent event's runId will be
            // resolved later, either by a chat event for the
            // same runId (flush) or by the timeout fallback
            // (assume selected session).
            break
        default:
            break
        }

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
// the private `operatorTransport.request`. This type is the
// only place slash-command code knows about SessionManager; the
// rest of the system talks to the narrow `ServerCommandTransport`
// protocol so tests can swap in a fake. Declared `final class`
// because `ServerCommandTransport` requires `AnyObject`; the
// class is stateless so `@unchecked Sendable` is safe.
private final class SessionManagerTransport: ServerCommandTransport, @unchecked Sendable {
    func send(method: String, paramsJSON: String) async throws -> Data {
        try await SessionManager.shared.request(
            method: method,
            paramsJSON: paramsJSON,
            timeoutSeconds: 15
        )
    }
}
