import Foundation
import os
import SwiftUI
import OpenClawChatUI
import OpenClawProtocol

@MainActor
final class HistoryLoader {
    weak var viewModel: NativeChatViewModel?
    /// Cache store reference for water-line based "has new content?" checks.
    /// Held `weak` to avoid a retain cycle: `NativeChatViewModel` owns both
    /// this loader and the store, so a strong reference here would create
    /// `VM → Loader → Store → ...` cycle (the store itself is held strongly
    /// by the VM, but the loader's reference would still keep it alive past
    /// the VM's natural dealloc). `weak` matches the `viewModel` pattern
    /// used everywhere else in this loader. Set via VM init or directly in
    /// tests.
    weak var store: MessageCacheStore?

    // Per-session-key reentrancy guard for `loadHistory()`. The class is
    // @MainActor; this static is deliberately outside the actor so
    // concurrent Task launches can race for the lock without bouncing
    // through main. The state is held inside the lock itself so we never
    // touch a `nonisolated(unsafe)` global directly from async code.
    // `@ObservationIgnored` is required because the surrounding VM uses
    // `@Observable` and we don't want this static to be observed.
    @ObservationIgnored
    private static let loadHistoryLock = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// Tracks the last session key we ran a `loadHistory` for, so the
    /// next call can tell whether the session actually changed. Used to
    /// set `forceScroll` on the scroll request: when the user switches
    /// sessions, the new load must scroll to the bottom regardless of
    /// `userHasScrolled` (set while reading the previous session). When
    /// the same session re-loads (entering NativeChat, re-fetch), we
    /// respect `userHasScrolled` so reading history isn't yanked down.
    @ObservationIgnored
    private var lastLoadedSessionKey: String?

    func loadHistory() {
        guard let vm = viewModel, let session = vm.selectedSession else { return }
        let sessionKey = session.key
        let sessionKeyPreview = String(sessionKey.prefix(8))
        // Capture isRestoring BEFORE resetting
        let isRestoring = vm.isRestoringFromCache
        vm.isRestoringFromCache = false

        // Acquire lock BEFORE creating task closure to prevent concurrent Tasks
        let alreadyInProgress = Self.loadHistoryLock.withLock { state -> Bool in
            let isInProgress = state == sessionKey
            if !isInProgress { state = sessionKey }
            return isInProgress
        }
        if alreadyInProgress {
            AppLogger.log("[loadHistory] already in progress for \(sessionKeyPreview)",
                         category: .nativeChat)
        }

        let taskIdStr = String(UUID().uuidString.prefix(8))

        Task { [sessionKey, sessionKeyPreview, isRestoring, taskIdStr] in
            AppLogger.log("[\(taskIdStr)] loadHistory Task started, sessionKey: \(sessionKeyPreview)",
                         category: .nativeChat)
            defer {
                Self.loadHistoryLock.withLock { state in
                    if state == sessionKey { state = nil }
                }
            }

            // 1. 从磁盘 hydrate 进 store 内存
            await store?.hydrate(for: sessionKey)
            // 2. precompute caches(view 端依赖) — 需要把 OpenClawChatMessage
            //    转成 ChatMessage,因为 caches 是按 ChatMessage id 索引的
            if let openclawMessages = store?.messages(for: sessionKey, since: nil) {
                let chatMessages = openclawMessages.compactMap { msg in
                    ChatMessageConverter.toChatMessage(from: msg)
                }
                await MainActor.run {
                    MarkdownCache.shared.precomputeForMessages(chatMessages)
                    CollapseStateCache.shared.precompute(for: chatMessages)
                }
            }
            // 3. 触发 historyLoaded multi-poll scroll(forceScroll = true 首次)
            // Do NOT update lastLoadedSessionKey yet — we want
            // fetchAndMergeFromNetwork's hasNewContent branch to also
            // see forceScroll=true on the cross-session transition, so
            // the post-network-arrival scrollRequest (fired after the
            // server response lands the messages in the store) is
            // forced and lands the viewport at the new bottom.
            let forceScroll = (self.lastLoadedSessionKey != sessionKey)
            let currentToken = viewModel?.scrollRequest.token ?? 0
            viewModel?.scrollRequest = NativeChatScrollRequest(
                token: currentToken &+ 1,
                kind: .historyLoaded,
                forceScroll: forceScroll
            )
            // 4. 拉网络(走 store.append + hasNewContent 判定)
            await fetchAndMergeFromNetwork(
                sessionKey: sessionKey,
                sessionKeyPreview: sessionKeyPreview,
                taskIdStr: taskIdStr,
                scrollKind: .historyLoaded
            )
            // 5. 现在才更新 lastLoadedSessionKey:之后的同 session 重新
            // 进入 (loadHistory 再次被同一 session 触发) 不会 forceScroll。
            self.lastLoadedSessionKey = sessionKey
        }
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

            // No cache step: the user is already looking at the cache. The
            // water-line `hasNewContent` check in `fetchAndMergeFromNetwork`
            // is the new comparison base.
            await self.fetchAndMergeFromNetwork(
                sessionKey: sessionKey,
                sessionKeyPreview: sessionKeyPreview,
                taskIdStr: taskIdStr,
                scrollKind: .manualRefresh
            )
        }
    }

    /// Network step shared by `loadHistory()` and `refreshFromServer()`.
    /// Fetches the latest 100 messages via the transport, writes them
    /// to the per-session `MessageCacheStore` (which dedupes + persists),
    /// then conditionally fires a scroll request based on the water-line
    /// `hasNewContent` check.
    ///
    /// `scrollKind` is the scroll request kind to fire on success. The
    /// caller picks `.historyLoaded` (multi-poll) or `.manualRefresh`
    /// (single scroll, bypasses `userHasScrolled`).
    private func fetchAndMergeFromNetwork(
        sessionKey: String,
        sessionKeyPreview: String,
        taskIdStr: String,
        scrollKind: NativeChatScrollKind
    ) async {
        do {
            try await SessionManager.shared.ensureConnected()
            let transport = await SessionManager.shared.makeTransport(sessionKey: sessionKey)
            let history = try await transport.requestHistory(sessionKey: sessionKey)

            // Staleness check:user 可能已经切到其他 session
            let currentKey = viewModel?.selectedSession?.key
            if currentKey != sessionKey {
                AppLogger.log(
                    "[\(taskIdStr)] fetchAndMergeFromNetwork dropped: session \(sessionKeyPreview) no longer selected",
                    category: .nativeChat, level: .warning)
                return
            }

            let messageCount = history.messages?.count ?? 0
            AppLogger.log(
                "[\(taskIdStr)] fetchAndMergeFromNetwork: \(messageCount) raw messages for session: \(sessionKeyPreview)",
                category: .nativeChat)

            // 把 server payload 转成 OpenClawChatMessage
            let openclawMessages: [OpenClawChatMessage] = (history.messages ?? []).enumerated().compactMap {
                index, anyCodable -> OpenClawChatMessage? in
                guard let msg = try? JSONDecoder().decode(OpenClawChatMessage.self,
                                                          from: JSONEncoder().encode(anyCodable)) else {
                    AppLogger.log("[\(taskIdStr)] message[\(index)] failed to decode",
                                 category: .nativeChat, level: .warning)
                    return nil
                }
                return msg
            }

            // 写 store(内存 + 磁盘 dedup-by-content)
            await store?.append(openclawMessages, for: sessionKey)

            // 计算 hasNewContent
            let newMaxTimestamp = openclawMessages.compactMap(\.timestamp).max()
            let hasNewContent = self.hasNewContent(
                newMaxTimestamp: newMaxTimestamp, sessionKey: sessionKey)

            if hasNewContent {
                AppLogger.log(
                    "[\(taskIdStr)] fetchAndMergeFromNetwork: new content (newMax=\(newMaxTimestamp ?? -1)), scrollKind=\(scrollKind)",
                    category: .nativeChat)
                // 触发 scrollRequest(forceScroll 由调用方传)
                let forceScroll = currentKey.map { $0 != self.lastLoadedSessionKey } ?? false
                if let currentKey { self.lastLoadedSessionKey = currentKey }
                let currentToken = viewModel?.scrollRequest.token ?? 0
                viewModel?.scrollRequest = NativeChatScrollRequest(
                    token: currentToken &+ 1,
                    kind: scrollKind,
                    forceScroll: forceScroll
                )
            } else {
                AppLogger.log(
                    "[\(taskIdStr)] fetchAndMergeFromNetwork: no new content (newMax=\(newMaxTimestamp ?? -1) <= lastSeen), skipping scroll",
                    category: .nativeChat)
            }
        } catch {
            AppLogger.log(
                "[\(taskIdStr)] fetchAndMergeFromNetwork error: \(error.localizedDescription)",
                category: .nativeChat, level: .error)
        }
    }
}

extension HistoryLoader {
    /// Water-line based "has new content?" check.
    /// Returns true if the incoming batch advances past the last seen
    /// timestamp for this session. Used by `fetchAndMergeFromNetwork`
    /// to decide whether to fire a scroll request.
    /// - Returns: true when `newMaxTimestamp` is non-nil AND either
    ///   (a) the session has never been seen (lastSeen is nil), or
    ///   (b) `newMaxTimestamp > lastSeen`.
    func hasNewContent(newMaxTimestamp: Double?, sessionKey: String) -> Bool {
        guard let newMax = newMaxTimestamp else { return false }
        guard let lastSeen = store?.lastSeenTimestamp(for: sessionKey) else { return true }
        return newMax > lastSeen
    }
}
