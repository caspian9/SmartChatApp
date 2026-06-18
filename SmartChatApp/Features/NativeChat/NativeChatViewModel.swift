import Foundation
import os
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
    /// In-flight streaming delta buffer, held **in memory only**
    /// and never written to the persistent `MessageCacheStore`.
    /// `MessageReceiver` attaches entries here when
    /// `state != "final"`, and writes to the cache when
    /// `state == "final"`. The key trade-off: session switches
    /// and app backgrounding lose intermediate streaming deltas,
    /// but the `lifecycle=start` placeholder and the
    /// `lifecycle=end` final both survive in the cache — the
    /// user does not lose the two endpoints of a complete
    /// response. The intermediate deltas (typing-indicator
    /// phase) are not perceptually important to preserve.
    /// `@ObservationIgnored` because the view reads
    /// `chatMessages(for:)` (which merges pending with cache),
    /// not `pending` directly.
    @ObservationIgnored
    private var pendingBySession: [String: [ChatMessage]] = [:]

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

    init(store: MessageCacheStore = MessageCacheStore.shared) {
        self.store = store
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
    }

    // MARK: - Public API (called by NativeChatView)

    /// Returns the cached `ChatMessage` array for `sessionKey`,
    /// converting from the underlying `OpenClawChatMessage` list
    /// on first read (or when `MessageCacheStore.version` advances).
    /// Merges the cache with pending (`pendingBySession`).
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
        let pending = pendingBySession[sessionKey] ?? []
        if ConfigurationManager.shared.logsNativeChat,
           chatMessagesDiagVersionBySession[sessionKey] != version,
           !pending.isEmpty {
            for (i, m) in pending.enumerated() {
                AppLogger.log(
                    "[chatMessages DIAG] session=\(String(sessionKey.prefix(8))) PENDING[\(i)] id=\(String(m.id.prefix(12))) role=\(m.role) state=\(m.state ?? "nil") text=\"\(String(m.text.prefix(60)))\"",
                    category: .nativeChat)
            }
        }
        let merged = pending.isEmpty ? cached : mergePending(pending, into: cached)
        // TEMP DIAG: dump the post-merge ChatMessage array the view
        // is about to render. Same version gate as the CACHE dump
        // above. Will be removed once the duplicate-bubble diagnosis
        // is complete.
        if ConfigurationManager.shared.logsNativeChat,
           chatMessagesDiagVersionBySession[sessionKey] != version {
            for (i, m) in merged.enumerated() {
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
        return sortForDisplay(merged)
    }

    private func sortForDisplay(_ messages: [ChatMessage]) -> [ChatMessage] {
        return messages.sorted { a, b in
            // Same non-nil runId → seq (server's monotonic order).
            // Missing `seq` falls back to Int.max (i.e., sort last
            // among the run's events), then to timestamp as the
            // final tie-breaker.
            if let runA = a.runId, let runB = b.runId, runA == runB {
                let seqA = a.seq ?? Int.max
                let seqB = b.seq ?? Int.max
                if seqA != seqB { return seqA < seqB }
                if a.timestamp != b.timestamp { return a.timestamp < b.timestamp }
            }
            // Different runs (or either has nil runId) → timestamp
            return a.timestamp < b.timestamp
        }
    }

    /// PERSIST GATE companion: attaches a streaming delta to
    /// pending and invalidates the `chatMessagesBySession`
    /// conversion cache so the view re-evaluates on next read.
    func appendPending(_ message: ChatMessage, for sessionKey: String) {
        var pending = pendingBySession[sessionKey] ?? []
        if let idx = pending.firstIndex(where: { $0.id == message.id }) {
            pending[idx] = message
        } else {
            pending.append(message)
        }
        pendingBySession[sessionKey] = pending
        chatMessagesBySession[sessionKey] = nil
        chatMessagesCachedVersionBySession[sessionKey] = nil
    }

    /// PERSIST GATE companion: the final message has been
    /// upserted into the cache; any in-flight streaming deltas
    /// are now obsolete — clear them so the view does not stack
    /// stale pending on top of the cached final. Called by
    /// `EventInterpreter` after the lifecycle=end `receiveMessage`
    /// completes.
    func clearPending(for sessionKey: String) {
        if pendingBySession[sessionKey]?.isEmpty == false {
            pendingBySession[sessionKey] = nil
            chatMessagesBySession[sessionKey] = nil
            chatMessagesCachedVersionBySession[sessionKey] = nil
        }
    }

    /// Clears all in-memory derived state for a session. Called
    /// by `SessionCoordinator` before switching sessions.
    /// `store.clearMemory(for:)` clears the store's in-memory
    /// copy; this method clears the VM's own pending and
    /// conversion caches.
    func clearMemory(for sessionKey: String) {
        pendingBySession[sessionKey] = nil
        chatMessagesBySession[sessionKey] = nil
        chatMessagesCachedVersionBySession[sessionKey] = nil
    }

    /// Merges pending entries on top of the cache while
    /// preserving the cache's native order. Walks the cache in
    /// order, replacing or appending pending entries by id —
    /// no re-sort, no `Array(byId.values).sorted(...)` (which
    /// would re-order entries with identical `startedAt`).
    private func mergePending(_ pending: [ChatMessage], into cached: [ChatMessage]) -> [ChatMessage] {
        var pendingById: [String: ChatMessage] = [:]
        for msg in pending { pendingById[msg.id] = msg }
        var result: [ChatMessage] = []
        result.reserveCapacity(cached.count + pending.count)
        var pendingIdsUsed: Set<String> = []
        for msg in cached {
            if let pendingVersion = pendingById[msg.id] {
                result.append(pendingVersion)
                pendingIdsUsed.insert(msg.id)
            } else {
                result.append(msg)
            }
        }
        for msg in pending where !pendingIdsUsed.contains(msg.id) {
            result.append(msg)
        }
        return result
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

    func sendMessage() {
        guard !inputText.isEmpty else { return }
        guard let session = selectedSession else { return }
        isSending = true
        let text = inputText
        let sessionKey = session.key
        let textPreview = String(text.prefix(100))
        AppLogger.log("sendMessage role=user text_len=\(text.count) text_preview=\(textPreview)", category: .nativeChat)
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
            }
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
