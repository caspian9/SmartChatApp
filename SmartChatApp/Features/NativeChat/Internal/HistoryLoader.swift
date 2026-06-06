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

            // Then fetch from network
            do {
                try await SessionManager.shared.ensureConnected()
                let transport = await SessionManager.shared.makeTransport(sessionKey: cachedSessionKey)
                let history = try await transport.requestHistory(sessionKey: cachedSessionKey)

                // Staleness check moved here: this task dispatches
                // `loadedNetworkHistory` carrying the session key, and
                // the method verifies `selectedSession?.key` still matches
                // before applying. The old check used
                // `SessionManager.getCurrentSessionKey()`, which
                // is overwritten by `loadSessions`'s concurrent
                // `makeTransport("")` and caused the history to
                // be silently dropped when the message cache was
                // empty (so this is the only path that can
                // repopulate the UI).

                let messageCount = history.messages?.count ?? 0
                AppLogger.log("Loaded \(messageCount) history messages for session: \(cachedSessionKeyPreview)", category: .nativeChat)
                let chatMessages: [ChatMessage] = (history.messages ?? []).enumerated().compactMap { index, anyCodable -> ChatMessage? in
                    guard let msg = try? JSONDecoder().decode(OpenClawChatMessage.self, from: JSONEncoder().encode(anyCodable)) else {
                        print("SMAlog: message[\(index)] failed to decode as OpenClawChatMessage, raw: \(String(describing: anyCodable))")
                        return nil
                    }
                    return ChatMessageConverter.toChatMessage(from: msg)
                }
                AppLogger.log("chatMessages count=\(chatMessages.count)", category: .nativeChat)
                // Cache the fetched messages (setMessages handles deduplication)
                let openClawMessages = chatMessages.compactMap { ChatMessageConverter.toOpenClawChatMessage(from: $0) }
                AppLogger.log("openClawMessages count=\(openClawMessages.count)", category: .nativeChat)
                await MessageCache.shared.setMessages(openClawMessages, for: cachedSessionKey)

                // Reload from cache to get accurate message count (cache now has all messages deduplicated)
                let finalCachedMessages = await MessageCache.shared.getMessages(for: cachedSessionKey)
                let finalChatMessages = finalCachedMessages.compactMap { msg in ChatMessageConverter.toChatMessage(from: msg) }
                AppLogger.log("[\(taskIdStr)] finalCachedMessages from cache: \(finalChatMessages.count)", category: .nativeChat)

                // Only update UI if we didn't already show cache, or if there are new messages
                // This prevents flickering when cache and network return the same data.
                // The check in `loadedNetworkHistory` handles the
                // "user switched sessions" case so we don't need a
                // `getCurrentSessionKey()` guard here.
                if cachedMessages.isEmpty {
                    // No cache was shown, this is first data load
                    self.loadedNetworkHistory(sessionKey: cachedSessionKey, messages: finalChatMessages)
                } else if finalChatMessages.count > cachedMessages.count {
                    // New messages were added
                    self.loadedNetworkHistory(sessionKey: cachedSessionKey, messages: finalChatMessages)
                } else {
                    AppLogger.log("[\(taskIdStr)] Network returned same messages as cache, skipping UI update", category: .nativeChat)
                }
            } catch {
                AppLogger.log("Load history error: \(error.localizedDescription)", category: .nativeChat, level: .error)
            }
        }
    }

    private func loadedCachedHistory(_ messages: [ChatMessage], isRestoring: Bool) {
        guard let vm = viewModel else { return }
        AppLogger.log("loadedCachedHistory setting \(messages.count) messages, isRestoring: \(isRestoring)", category: .nativeChat)
        vm.messages = messages
        // Single scroll request — the view's multi-poll handler covers
        // the `MarkdownViewTextKit` async height measurement. Precompute
        // runs in a Task without firing a second scroll request.
        vm.scrollRequest = NativeChatScrollRequest(token: vm.scrollRequest.token &+ 1, kind: .historyLoaded)
        Task { [messages] in
            await MainActor.run {
                MarkdownCache.shared.precomputeForMessages(messages)
                CollapseStateCache.shared.precompute(for: messages)
            }
        }
    }

    private func loadedNetworkHistory(sessionKey: String, messages: [ChatMessage]) {
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
            AppLogger.log("loadedNetworkHistory dropped: session \(String(sessionKey.prefix(8))) is no longer selected (current: \(String(currentKeyLog.prefix(8))))", category: .nativeChat, level: .warning)
            return
        }
        AppLogger.log("loadedNetworkHistory applying \(messages.count) messages for session: \(String(sessionKey.prefix(8)))", category: .nativeChat)
        vm.messages = messages
        vm.scrollRequest = NativeChatScrollRequest(token: vm.scrollRequest.token &+ 1, kind: .historyLoaded)
        Task { [messages] in
            await MainActor.run {
                MarkdownCache.shared.precomputeForMessages(messages)
                CollapseStateCache.shared.precompute(for: messages)
            }
        }
    }
}
