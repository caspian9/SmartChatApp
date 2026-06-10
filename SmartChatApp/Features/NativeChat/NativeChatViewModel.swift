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
    var messages: [ChatMessage] = []
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
        self.historyLoader.viewModel = self
        self.historyLoader.store = store
        self.eventInterpreter.viewModel = self
        self.sessionCoordinator.viewModel = self
    }

    // MARK: - Public API (called by NativeChatView)

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
        print("SMAlog: sendMessage role=user text_len=\(text.count) text_preview=\(textPreview)")
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
        messages.append(message)
        // Without this scroll request, the viewport stays at the
        // pre-send position until `isSending` flips false (lifecycle end,
        // which can be 10+ seconds for a long response). The view's
        // `.newMessage` handler scrolls to the new last id (this very
        // user message) so the user sees the bubble land at the bottom.
        scrollRequest = NativeChatScrollRequest(token: scrollRequest.token &+ 1, kind: .newMessage)
        inputText = ""
        // Cache user message
        Task {
            if let msg = self.createOpenClawChatMessage(from: message) {
                await MessageCache.shared.appendMessages([msg], for: sessionKey)
            }
        }
        Task {
            do {
                try await SessionManager.shared.ensureConnected()
                let transport = await SessionManager.shared.makeTransport(sessionKey: sessionKey)
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

    func receiveMessage(_ message: ChatMessage) {
        messageReceiver.receiveMessage(message)
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
                self.setError("请求超时(\(timeout.components.seconds)s)未收到回复,请重试")
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

    private func createOpenClawChatMessage(from chatMessage: ChatMessage) -> OpenClawChatMessage? {
        guard let uuid = UUID(uuidString: chatMessage.id) else { return nil }
        // Build usage if we have token data - encode as JSON then decode to OpenClawChatUsage
        var usage: OpenClawChatUsage? = nil
        if chatMessage.inputTokens != nil || chatMessage.outputTokens != nil || chatMessage.cacheRead != nil || chatMessage.cacheWrite != nil {
            var usageData: [String: AnyCodable] = [:]
            if let input = chatMessage.inputTokens { usageData["input"] = AnyCodable(input) }
            if let output = chatMessage.outputTokens { usageData["output"] = AnyCodable(output) }
            if let cr = chatMessage.cacheRead { usageData["cacheRead"] = AnyCodable(cr) }
            if let cw = chatMessage.cacheWrite { usageData["cacheWrite"] = AnyCodable(cw) }
            if let data = try? JSONEncoder().encode(usageData),
               let decoded = try? JSONDecoder().decode(OpenClawChatUsage.self, from: data) {
                usage = decoded
            }
        }
        return OpenClawChatMessage(
            id: uuid,
            role: chatMessage.role,
            content: [OpenClawChatMessageContent(type: "text", text: chatMessage.text, thinking: nil, thinkingSignature: nil, mimeType: nil, fileName: nil, content: nil, id: nil, name: nil, arguments: nil)],
            timestamp: chatMessage.timestamp.timeIntervalSince1970 * 1000,
            toolCallId: chatMessage.toolCallId,
            toolName: chatMessage.toolName,
            usage: usage,
            stopReason: chatMessage.stopReason
        )
    }
}
