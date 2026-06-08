import Foundation
import os
import SwiftUI
import OpenClawChatUI
import OpenClawProtocol

@MainActor
final class HistoryLoader {
    weak var viewModel: NativeChatViewModel?

    // Per-session-key reentrancy guard for `loadHistory()`. The class is
    // @MainActor; this static is deliberately outside the actor so
    // concurrent Task launches can race for the lock without bouncing
    // through main. The state is held inside the lock itself so we never
    // touch a `nonisolated(unsafe)` global directly from async code.
    // `@ObservationIgnored` is required because the surrounding VM uses
    // `@Observable` and we don't want this static to be observed.
    @ObservationIgnored
    private static let loadHistoryLock = OSAllocatedUnfairLock<String?>(initialState: nil)

    func loadHistory() {
        guard let vm = viewModel, let session = vm.selectedSession else { return }
        let sessionKey = session.key
        let sessionKeyPreview = String(sessionKey.prefix(8))
        // Capture isRestoring BEFORE resetting
        let isRestoring = vm.isRestoringFromCache
        vm.isRestoringFromCache = false

        let cachedSessionKey = sessionKey
        let cachedSessionKeyPreview = sessionKeyPreview
        let cachedIsRestoring = isRestoring

        // Acquire lock BEFORE creating task closure to prevent concurrent Tasks
        let alreadyInProgress = Self.loadHistoryLock.withLock { state -> Bool in
            let isInProgress = state == cachedSessionKey
            if !isInProgress {
                state = cachedSessionKey
            }
            return isInProgress
        }
        if alreadyInProgress {
            AppLogger.log("[loadHistory] already in progress for \(cachedSessionKeyPreview)", category: .nativeChat)
        }

        let taskIdStr = String(UUID().uuidString.prefix(8))

        Task { [cachedSessionKey, cachedSessionKeyPreview, cachedIsRestoring, taskIdStr] in
            AppLogger.log("[\(taskIdStr)] loadHistory Task started, sessionKey: \(cachedSessionKeyPreview)", category: .nativeChat)
            defer {
                Self.loadHistoryLock.withLock { state in
                    if state == cachedSessionKey {
                        state = nil
                    }
                }
            }
            // Load cache first and send to UI immediately
            let cachedMessages = await MessageCache.shared.getMessages(for: cachedSessionKey)
            AppLogger.log("cache returned \(cachedMessages.count) messages, sessionKey: \(cachedSessionKeyPreview)", category: .nativeChat)
            if !cachedMessages.isEmpty {
                let chatMessages = cachedMessages.compactMap { msg in ChatMessageConverter.toChatMessage(from: msg) }
                AppLogger.log("Loaded \(chatMessages.count) cached messages for session: \(cachedSessionKeyPreview), isRestoring: \(cachedIsRestoring)", category: .nativeChat)
                // Precompute collapse and markdown states BEFORE sending to UI
                await MainActor.run {
                    MarkdownCache.shared.precomputeForMessages(chatMessages)
                    CollapseStateCache.shared.precompute(for: chatMessages)
                }
                // Send cached messages to UI
                self.loadedCachedHistory(chatMessages, isRestoring: cachedIsRestoring)
            }

            // Then fetch from network (multi-poll scroll: history-load bubbles
            // render through UIViewRepresentable which measures async).
            await self.fetchAndMergeFromNetwork(
                sessionKey: cachedSessionKey,
                sessionKeyPreview: cachedSessionKeyPreview,
                taskIdStr: taskIdStr,
                cachedMessagesCount: cachedMessages.count,
                scrollKind: .historyLoaded
            )
        }
    }

    private func loadedCachedHistory(_ messages: [ChatMessage], isRestoring: Bool) {
        guard let vm = viewModel else { return }
        AppLogger.log("loadedCachedHistory setting \(messages.count) messages, isRestoring: \(isRestoring)", category: .nativeChat)
        // Precompute BEFORE setting `vm.messages`: the view re-renders
        // synchronously off the assignment, and `MessageBubbleView`
        // reads `MarkdownCache.needsMarkdown(id)` for each message.
        // If the precompute is deferred (Task + MainActor.run), the view
        // sees `false` for any new IDs and renders raw markdown text
        // instead of the rendered card. The incremental cache makes
        // this a no-op for IDs already cached.
        MarkdownCache.shared.precomputeForMessages(messages)
        CollapseStateCache.shared.precompute(for: messages)
        vm.messages = messages
        // Single scroll request — the view's multi-poll handler covers
        // the `MarkdownViewTextKit` async height measurement.
        vm.scrollRequest = NativeChatScrollRequest(token: vm.scrollRequest.token &+ 1, kind: .historyLoaded)
    }

    /// Apply merged history to the VM, with the staleness check
    /// (`vm.selectedSession?.key` still matches the session we fetched for).
    /// Renamed from the previous `loadedNetworkHistory` so both
    /// `.historyLoaded` and `.manualRefresh` paths can use it. The
    /// behavior is identical — the only thing that differs is the scroll
    /// kind the view will dispatch on.
    private func applyMergedHistory(sessionKey: String, messages: [ChatMessage], scrollKind: NativeChatScrollKind) {
        guard let vm = viewModel else { return }
        // Drop the result if the user has switched to a different
        // session since this fetch started. Comparing against
        // `selectedSession?.key` (the only source of truth
        // for what the user is looking at) avoids the race the
        // old `SessionManager.getCurrentSessionKey()` guard had
        // with the concurrent `makeTransport("")` from
        // `loadSessions`.
        let currentKey = vm.selectedSession?.key
        if currentKey != sessionKey {
            let currentKeyLog = currentKey ?? "nil"
            AppLogger.log("applyMergedHistory dropped: session \(String(sessionKey.prefix(8))) is no longer selected (current: \(String(currentKeyLog.prefix(8))))", category: .nativeChat, level: .warning)
            return
        }
        AppLogger.log("applyMergedHistory applying \(messages.count) messages for session: \(String(sessionKey.prefix(8))), kind=\(scrollKind)", category: .nativeChat)
        // Precompute BEFORE setting `vm.messages`: see `loadedCachedHistory`
        // for the full rationale. The pull-up refresh path goes
        // `refreshFromServer → fetchAndMergeFromNetwork → applyMergedHistory`,
        // and there is no cache-first precompute in that path, so the
        // precompute here is the only chance to populate the cache for
        // newly-arrived IDs before the view re-renders.
        MarkdownCache.shared.precomputeForMessages(messages)
        CollapseStateCache.shared.precompute(for: messages)
        vm.messages = messages
        vm.scrollRequest = NativeChatScrollRequest(token: vm.scrollRequest.token &+ 1, kind: scrollKind)
    }

    /// User-initiated pull-up refresh. Skips the cache-first step (the user
    /// is already looking at the cache) and runs the network step only.
    /// Fires `.manualRefresh` scroll kind on success so the view scrolls
    /// to the bottom even if `userHasScrolled` is true.
    func refreshFromServer() {
        guard let vm = viewModel, let session = vm.selectedSession else { return }
        let sessionKey = session.key
        let sessionKeyPreview = String(sessionKey.prefix(8))

        // Same per-session-key lock as loadHistory — prevents a manual
        // refresh from double-firing with an in-progress initial load.
        let alreadyInProgress = Self.loadHistoryLock.withLock { state -> Bool in
            let isInProgress = state == sessionKey
            if !isInProgress {
                state = sessionKey
            }
            return isInProgress
        }
        if alreadyInProgress {
            AppLogger.log("[refreshFromServer] already in progress for \(sessionKeyPreview)", category: .nativeChat)
            return
        }

        let taskIdStr = String(UUID().uuidString.prefix(8))

        // Outside the Task — synchronous, on @MainActor. Setting this
        // before the Task runs means the view's onEnded defer doesn't
        // see `isPullingUp = false` flip the indicator off before the
        // network flag takes over.
        vm.isManualRefreshing = true

        Task { [sessionKey, sessionKeyPreview, taskIdStr] in
            AppLogger.log("[\(taskIdStr)] refreshFromServer Task started", category: .nativeChat)
            defer {
                Self.loadHistoryLock.withLock { state in
                    if state == sessionKey {
                        state = nil
                    }
                }
                // Cleared even on early return / throw so the indicator
                // never gets stuck. Same @MainActor context as the
                // assignment above — no MainActor.run wrapping needed.
                vm.isManualRefreshing = false
            }

            // No cache step: the user is already looking at the cache. Use
            // vm.messages.count as the comparison base so we only update
            // the UI when network actually returned something new.
            await self.fetchAndMergeFromNetwork(
                sessionKey: sessionKey,
                sessionKeyPreview: sessionKeyPreview,
                taskIdStr: taskIdStr,
                cachedMessagesCount: vm.messages.count,
                scrollKind: .manualRefresh
            )
        }
    }

    /// Network step shared by `loadHistory()` and `refreshFromServer()`.
    /// Fetches the latest 100 messages via the transport, merges them into
    /// the per-session cache (dedup via `MessageCache.setMessages`), and
    /// conditionally applies the result to the UI.
    ///
    /// `cachedMessagesCount` is the count of messages already shown to the
    /// user (ChatMessage count for `refreshFromServer`, OpenClawChatMessage
    /// count for `loadHistory` — see the call sites for context). Used as
    /// the threshold for the "did anything new arrive?" check.
    ///
    /// `scrollKind` is the scroll request kind to fire on success. The
    /// caller picks `.historyLoaded` (multi-poll) or `.manualRefresh`
    /// (single scroll, bypasses `userHasScrolled`).
    private func fetchAndMergeFromNetwork(
        sessionKey: String,
        sessionKeyPreview: String,
        taskIdStr: String,
        cachedMessagesCount: Int,
        scrollKind: NativeChatScrollKind
    ) async {
        do {
            try await SessionManager.shared.ensureConnected()
            let transport = await SessionManager.shared.makeTransport(sessionKey: sessionKey)
            let history = try await transport.requestHistory(sessionKey: sessionKey)

            // Staleness check moved here: this task dispatches
            // `applyMergedHistory` carrying the session key, and
            // the method verifies `selectedSession?.key` still matches
            // before applying. The old check used
            // `SessionManager.getCurrentSessionKey()`, which
            // is overwritten by `loadSessions`'s concurrent
            // `makeTransport("")` and caused the history to
            // be silently dropped when the message cache was
            // empty (so this is the only path that can
            // repopulate the UI).

            let messageCount = history.messages?.count ?? 0
            AppLogger.log("[\(taskIdStr)] fetchAndMergeFromNetwork: \(messageCount) raw messages for session: \(sessionKeyPreview)", category: .nativeChat)
            let chatMessages: [ChatMessage] = (history.messages ?? []).enumerated().compactMap { index, anyCodable -> ChatMessage? in
                guard let msg = try? JSONDecoder().decode(OpenClawChatMessage.self, from: JSONEncoder().encode(anyCodable)) else {
                    AppLogger.log("[\(taskIdStr)] message[\(index)] failed to decode", category: .nativeChat, level: .warning)
                    return nil
                }
                return ChatMessageConverter.toChatMessage(from: msg)
            }
            AppLogger.log("[\(taskIdStr)] chatMessages count=\(chatMessages.count)", category: .nativeChat)
            // Cache the fetched messages (setMessages handles deduplication)
            let openClawMessages = chatMessages.compactMap { ChatMessageConverter.toOpenClawChatMessage(from: $0) }
            AppLogger.log("[\(taskIdStr)] openClawMessages count=\(openClawMessages.count)", category: .nativeChat)
            await MessageCache.shared.setMessages(openClawMessages, for: sessionKey)

            // Reload from cache to get accurate message count (cache now has all messages deduplicated)
            let finalCachedMessages = await MessageCache.shared.getMessages(for: sessionKey)
            let finalChatMessages = finalCachedMessages.compactMap { msg in ChatMessageConverter.toChatMessage(from: msg) }
            AppLogger.log("[\(taskIdStr)] finalCachedMessages from cache: \(finalChatMessages.count)", category: .nativeChat)

            // Decide whether to apply the merged result to the UI.
            //
            // We compare ID SETS, not counts. Count comparison is
            // insufficient when the user is already at the request
            // limit (100 messages shown) and a new message arrives:
            // the server's `requestHistory` returns the *latest 100*
            // (hard cap in `GatewayChatTransport`), so the new
            // message replaces the oldest in the response. The cache
            // merges to 100 entries (dedup by content+timestamp
            // bucket), and `100 > 100` is false — the new message is
            // in the cache but the count check would silently skip
            // the UI update.
            //
            // The staleness check inside `applyMergedHistory` still
            // handles the "user switched sessions mid-fetch" race;
            // the ID diff here catches "new content arrived for the
            // same session" regardless of whether the count changed.
            let currentIds: Set<String> = Set(self.viewModel?.messages.map(\.id) ?? [])
            let newIds: Set<String> = Set(finalChatMessages.map(\.id))
            let hasNewContent = !newIds.subtracting(currentIds).isEmpty
            if hasNewContent {
                AppLogger.log("[\(taskIdStr)] fetchAndMergeFromNetwork: new IDs detected (current=\(cachedMessagesCount) final=\(finalChatMessages.count)), updating UI (kind=\(scrollKind))", category: .nativeChat)
                self.applyMergedHistory(sessionKey: sessionKey, messages: finalChatMessages, scrollKind: scrollKind)
            } else {
                AppLogger.log("[\(taskIdStr)] fetchAndMergeFromNetwork: no new IDs (current=\(cachedMessagesCount) final=\(finalChatMessages.count)), skipping UI update", category: .nativeChat)
            }
        } catch {
            AppLogger.log("[\(taskIdStr)] fetchAndMergeFromNetwork error: \(error.localizedDescription)", category: .nativeChat, level: .error)
        }
    }
}
