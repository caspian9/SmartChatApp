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
    /// Test-only seam for `fetchAndMergeFromNetwork`. The default
    /// closure goes through `SessionManager.shared`; tests inject
    /// a fake transport so they don't need a live gateway. The
    /// closure is `@MainActor`-isolated because callers (and
    /// `fetchAndMergeFromNetwork`) are main-actor. Production
    /// code never touches this — it's set in tests only.
    @ObservationIgnored
    var transportFactory: (@MainActor (String) async throws -> (any OpenClawChatTransport))?

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

        // Acquire lock for the background-task path only (not for
        // the sync cache-hydrate below). The previous design held
        // the per-session `loadHistoryLock` across both the sync
        // AND the background task, so a quick A→B→A switch sequence
        // would hit `loadHistory(A)` while the original A's
        // background task still held the lock and return early —
        // `hydrateSync(A)` was skipped, the in-memory store for A
        // stayed empty (cleared by `selectSession`'s `clearMemory(A)`),
        // and the user saw A as a blank slate on switch-back. The
        // user-reported symptom: "cache sometimes doesn't show up
        // when switching sessions". The fix: only the background
        // task needs serialization (to prevent two concurrent
        // network fetches racing on the same `replaceForSession`).
        // The sync part is idempotent (`hydrateSync` re-reads the
        // same disk content, scrollRequest is a value type) and
        // cheap, so
        // re-running it on a quick re-entry is correct and free.
        // The lock is acquired at the dispatch site (see below) so
        // the sync cache-hydrate is no longer gated on a possibly-
        // still-in-flight background task from a prior call.

        let taskIdStr = String(UUID().uuidString.prefix(8))

        // === Phase A (synchronous, on @MainActor): cache-first display ===
        // User's explicit feedback: "network can run in background".
        // The old flow was:
        //   await store.hydrate  ← actor hop, blocks scrollRequest
        //   scrollRequest(.historyLoaded)
        //   await fetchAndMergeFromNetwork  ← ensureConnected + RTT
        // The new flow:
        //   hydrateSync (UserDefaults read on MainActor, no actor hop)
        //   scrollRequest(.historyLoaded)  ← fires NOW, before network
        //   Task { fetchAndMergeFromNetwork }  ← background, doesn't block
        // This addresses:
        //   - "large cache entry is slow" — hydrateSync is ~1 JSON decode, no hop
        //   - "session switch is not smooth" — scroll fires before any network
        //   - "blank/slow on re-entry" — view sees messages immediately
        //   - "not at the bottom" — scrollRequest lands on a populated tree
        store?.hydrateSync(for: sessionKey)
        // Precompute the CollapseStateCache for the cache-loaded set.
        // Background (Task.detached) so the boundingRect work doesn't
        // block the main thread on entry. The MarkdownCache is no
        // longer precomputed here — its `needsMarkdown(for:)` is now
        // lazy and content-keyed, so the 2000-regex up-front cost is
        // eliminated (LazyVStack only renders 5-10 visible bubbles
        // per body evaluation).
        if let openclawMessages = store?.messages(for: sessionKey, since: nil) {
            let chatMessages = openclawMessages.flatMap { msg in
                ChatMessageConverter.toChatMessage(from: msg)
            }
            Task.detached(priority: .userInitiated) {
                let alreadyCached = await MainActor.run {
                    CollapseStateCache.shared.shouldCollapseCachedIds()
                }
                let values = CollapseStateCache.precomputeValues(
                    for: chatMessages, alreadyCachedIds: alreadyCached)
                await MainActor.run {
                    CollapseStateCache.shared.applyPrecomputedValues(values)
                }
            }
        }
        // Fire scrollRequest immediately so the view scrolls to the
        // bottom of the cache-first tree. The multi-poll cascade in
        // the view catches any subsequent re-measurement. The 2nd
        // `lastLoadedSessionKey` capture also happens here (on
        // @MainActor, before launching the background task) so
        // the network's `hasNewContent` branch sees the right
        // forceScroll signal.
        let forceScroll = (self.lastLoadedSessionKey != sessionKey)
        let currentToken = viewModel?.scrollRequest.token ?? 0
        viewModel?.scrollRequest = NativeChatScrollRequest(
            token: currentToken &+ 1,
            kind: .historyLoaded,
            forceScroll: forceScroll
        )

        // === Phase B (background, off the main path): network sync ===
        // Run as a separate Task so the user's UI thread is not
        // blocked on `ensureConnected` / `requestHistory`. The
        // network task may fail silently (weak network), but the
        // user is already looking at their cached history. This is
        // the user's explicit requirement: "for weak-network
        // environments, don't let the network affect rendering; the
        // network can run in the background".
        //
        // Lock is acquired HERE (not at the top of `loadHistory`) so
        // that a quick A→B→A switch can re-run the sync cache-hydrate
        // for A even while A's prior background task is still in
        // flight. Two concurrent network fetches for the same
        // session would race on `replaceForSession` — the lock
        // serializes the network step, while leaving the cache
        // step free.
        let alreadyInFlight = Self.loadHistoryLock.withLock { state -> Bool in
            let isInFlight = state == sessionKey
            if !isInFlight { state = sessionKey }
            return isInFlight
        }
        if alreadyInFlight {
            AppLogger.log("[loadHistory] background fetch already in flight for \(sessionKeyPreview), skipping network step (cache hydrate still ran above)",
                         category: .nativeChat)
            return
        }
        Task { [sessionKey, sessionKeyPreview, isRestoring, taskIdStr, forceScroll] in
            AppLogger.log("[\(taskIdStr)] loadHistory network Task started, sessionKey: \(sessionKeyPreview)",
                         category: .nativeChat)
            defer {
                Self.loadHistoryLock.withLock { state in
                    if state == sessionKey { state = nil }
                }
            }
            await fetchAndMergeFromNetwork(
                sessionKey: sessionKey,
                sessionKeyPreview: sessionKeyPreview,
                taskIdStr: taskIdStr,
                scrollKind: .historyLoaded
            )
            // Update lastLoadedSessionKey AFTER the network step
            // so the next same-session loadHistory doesn't
            // forceScroll (i.e. respects userHasScrolled).
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
    ///
    /// Visibility: `internal` (no `private` / `fileprivate`) so the
    /// `HistoryLoaderAppendTests` can drive it directly with a
    /// fake transport. The test seam is `transportFactory`; in
    /// production the closure is nil and we go through
    /// `SessionManager.shared` as before.
    func fetchAndMergeFromNetwork(
        sessionKey: String,
        sessionKeyPreview: String,
        taskIdStr: String,
        scrollKind: NativeChatScrollKind
    ) async {
        do {
            let transport: any OpenClawChatTransport
            if let factory = transportFactory {
                // Test path: the closure provides a transport
                // directly (no live gateway needed). Skip the
                // `ensureConnected` call so the test doesn't
                // depend on a real SessionManager.
                transport = try await factory(sessionKey)
            } else {
                try await SessionManager.shared.ensureConnected()
                transport = await SessionManager.shared.makeTransport(sessionKey: sessionKey)
            }
            let history = try await transport.requestHistory(sessionKey: sessionKey)

            // Staleness check: the user may have switched to a
            // different session while the request was in flight.
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

            // Convert the server payload to OpenClawChatMessage.
            var openclawMessages: [OpenClawChatMessage] = (history.messages ?? []).enumerated().compactMap {
                index, anyCodable -> OpenClawChatMessage? in
                guard let msg = try? JSONDecoder().decode(OpenClawChatMessage.self,
                                                          from: JSONEncoder().encode(anyCodable)) else {
                    AppLogger.log("[\(taskIdStr)] message[\(index)] failed to decode",
                                 category: .nativeChat, level: .warning)
                    return nil
                }
                return msg
            }

            // Per-message content log for dedupKey diagnosis. The
            // user reported the streaming-vs-server dedup is still
            // leaving duplicates on the wire, AND that the log
            // for history[19] was truncated at 60 chars — they
            // need the full content of `text` / `thinking` /
            // `arguments` to grep for the exact phrasing the
            // dedupKey is comparing. We log the full content of
            // every content block (no prefix truncation) plus a
            // per-message summary line. The log is gated on
            // `logsNativeChat` AND `logsNativeChatHistory`
            // (Settings → Debug & Logs → NativeChat Logs → History
            // Dump) so production logs aren't polluted. The
            // `[history]` prefix after `[taskIdStr]` distinguishes
            // these verbose per-message dumps from other
            // `[taskIdStr]` status lines in the same file
            // (e.g. the single-line "fetchAndMergeFromNetwork: N
            // raw messages" at line 260), making `grep '\[history\]'`
            // a clean way to extract just the dump output.
            for (index, msg) in openclawMessages.enumerated() {
                if !ConfigurationManager.shared.logsNativeChat { break }
                if !ConfigurationManager.shared.logsNativeChatHistory { break }
                let contentCount = msg.content.count
                for (ci, c) in msg.content.enumerated() {
                    let cType = c.type ?? "?"
                    let cText = c.text ?? ""
                    let cName = c.name ?? ""
                    let cArgs = c.arguments.map { String(describing: $0.value) } ?? ""
                    let cThinking = c.thinking ?? ""
                    let cId = c.id ?? ""
                    AppLogger.log(
                        "[\(taskIdStr)] [history] history[\(index)].content[\(ci)]: type=\(cType) id=\(cId) name=\(cName) text=\"\(cText)\" thinking=\"\(cThinking)\" arguments=\(cArgs)",
                        category: .nativeChat)
                }
                AppLogger.log(
                    "[\(taskIdStr)] [history] history[\(index)] summary: id=\(msg.id.uuidString.prefix(8)) role=\(msg.role) ts=\(msg.timestamp ?? -1) toolCallId=\(msg.toolCallId ?? "nil") toolName=\(msg.toolName ?? "nil") contentCount=\(contentCount)",
                    category: .nativeChat)
            }

            // Weak-network guard: if the response decoded but yielded
            // 0 messages, do NOT call replaceForSession. The storage
            // layer has its own short-circuit (defense in depth) but
            // logging at the source helps tell "server said empty"
            // from "decode failed" in user logs. Without this, the
            // store would be wiped and the view would show nothing
            // even though the connection is healthy.
            guard !openclawMessages.isEmpty else {
                AppLogger.log(
                    "[\(taskIdStr)] fetchAndMergeFromNetwork: server returned 0 decodable messages, keeping existing in-memory data (likely weak/intermittent network)",
                    category: .nativeChat, level: .warning)
                return
            }

            // Compute hasNewContent BEFORE any store write. The store's
            // `lastSeenTimestamp` is updated by the write itself, so
            // a check after the write would always be false
            // (newMax == lastSeen post-write) and we'd never fire a
            // scrollRequest for genuine new content. Computing it
            // against the pre-write lastSeen is the only way
            // `hasNewContent` can be a real signal.
            //
            // We SKIP the write when hasNewContent is false so the
            // bubble identities stay stable. A same-content re-fetch
            // from the server carries server-assigned UUIDs that
            // differ from the client-streaming synthesized UUIDs, so
            // a no-op write would swap the in-memory array and force
            // ForEach to re-render identical-looking bubbles with new
            // ids — MarkdownViewTextKit re-measures async, the
            // defaultScrollAnchor re-positions, and the user sees a
            // chaotic "messages jumping, scroll bar not at bottom"
            // state. Skipping the swap when the server is just
            // confirming what we already have keeps bubble
            // identities stable, no re-render, no jump.
            let newMaxTimestamp = openclawMessages.compactMap(\.timestamp).max()
            let hasNewContent = self.hasNewContent(
                newMaxTimestamp: newMaxTimestamp, sessionKey: sessionKey)

            if hasNewContent {
                AppLogger.log(
                    "[\(taskIdStr)] fetchAndMergeFromNetwork: new content (newMax=\(newMaxTimestamp ?? -1)), scrollKind=\(scrollKind)",
                    category: .nativeChat)
                // Preserves the streaming-time `usage` block on the
                // INCOMING server messages before the append. The
                // server's `chat.history` omits `usage`, but the
                // local cache (which the user populated during
                // streaming) has it. Previously this lived inside
                // `MessageCacheStorage.replaceForSession` and ran
                // on every entry being written; now that we use
                // `append`, the merge does not touch existing
                // entries' `usage`, so the preservation has to run
                // on the incoming array before it lands. Without
                // this, every refresh would silently erase the
                // "↑input ↓output ↑cacheRead ↓cacheWrite" footer.
                openclawMessages = applyUsagePreservation(
                    to: openclawMessages, sessionKey: sessionKey)
                // Write the server payload onto the cache via
                // `append` instead of `replaceForSession`. The
                // previous `replaceForSession` wiped the session
                // first, which erased client-only messages (the
                // user's outgoing text bubble before the server
                // confirmed it) and any client-side artifacts the
                // server doesn't re-emit. `append` relies on
                // `MessageCacheStorage.append`'s id-dedup +
                // content-dedup to absorb overlaps; the same
                // dedup logic that prevents duplicate bubbles
                // also prevents the merge from re-creating
                // entries that already exist locally.
                await store?.append(openclawMessages, for: sessionKey)
                // DIAG: confirm the post-append state. Pairs with
                // the agent-delta post-upsert log — together they
                // disambiguate "stream bubble not in store
                // (upsert was dropped)" from "stream bubble wiped
                // by history (chat.history ran after stream)".
                if ConfigurationManager.shared.logsNativeChat {
                    let postHistory = await store?.messages(for: sessionKey, since: nil) ?? []
                    let firstIds = postHistory.prefix(3)
                        .map { String($0.id.uuidString.prefix(8)) }
                        .joined(separator: ",")
                    AppLogger.log(
                        "[\(taskIdStr)] post-append in store: bubbleCount=\(postHistory.count) firstIds=[\(firstIds)]",
                        category: .nativeChat)
                }
                // The previous implementation only honored signal 1, so a
                // same-session pull-to-refresh left userHasScrolled=true
                // (set by the pull gesture's scroll phase) gating the
                // scrollTo — the viewport stayed at the pull-gesture end
                // position with the new content layered above the old
                // scroll offset. The `NativeChatScrollKind.manualRefresh`
                // docstring already says "no userHasScrolled gate"; this
                // is the implementation matching the contract.
                let isCrossSession = currentKey.map { $0 != self.lastLoadedSessionKey } ?? false
                let forceScroll = isCrossSession || scrollKind == .manualRefresh
                if let currentKey { self.lastLoadedSessionKey = currentKey }
                let currentToken = viewModel?.scrollRequest.token ?? 0
                viewModel?.scrollRequest = NativeChatScrollRequest(
                    token: currentToken &+ 1,
                    kind: scrollKind,
                    forceScroll: forceScroll
                )
            } else {
                AppLogger.log(
                    "[\(taskIdStr)] fetchAndMergeFromNetwork: no new content (newMax=\(newMaxTimestamp ?? -1) <= lastSeen), skipping replaceForSession + scroll to avoid bubble re-creation",
                    category: .nativeChat)
            }
        } catch {
            AppLogger.log(
                "[\(taskIdStr)] fetchAndMergeFromNetwork error: \(error.localizedDescription)",
                category: .nativeChat, level: .error)
        }
    }

    /// Mirrors the usage-preservation pass that lived in
    /// `MessageCacheStorage.replaceForSession`. The previous
    /// code wiped-and-replaced the session on every server
    /// fetch, and the preservation logic ran inline. Now that
    /// `fetchAndMergeFromNetwork` uses `append` (which doesn't
    /// touch existing entries' usage), the preservation logic
    /// must run on the INCOMING `openclawMessages` array
    /// BEFORE the append — splicing the streaming-time `usage`
    /// block from the local cache into any incoming message
    /// whose text + role + timestamp matches. Without this,
    /// the bubble's `↑input ↓output ↑cacheRead ↓cacheWrite`
    /// footer silently disappears on the first refresh of any
    /// session (issue #36).
    ///
    /// Returns the modified array (NOT the count of preserved
    /// entries — the caller passes it straight into
    /// `store.append`). Returning the array keeps the merge
    /// call site a one-liner.
    private func applyUsagePreservation(
        to messages: [OpenClawChatMessage],
        sessionKey: String
    ) -> [OpenClawChatMessage] {
        let existing = store?.messages(for: sessionKey) ?? []
        guard !existing.isEmpty else { return messages }
        var preservedCount = 0
        let preserved = messages.map { incoming in
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
                "[HistoryLoader applyUsagePreservation] sessionKey=\(String(sessionKey.prefix(8))) preserved usage from \(preservedCount) streaming entries",
                category: .nativeChat)
        }
        return preserved
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
