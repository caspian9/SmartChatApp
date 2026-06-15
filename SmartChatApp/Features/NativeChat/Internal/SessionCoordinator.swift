import SwiftUI
import OpenClawChatUI

@MainActor
final class SessionCoordinator {
    weak var viewModel: NativeChatViewModel?

    private func lastSelectedSessionKey(for profileId: UUID) -> String {
        "lastSelectedSession_\(profileId.uuidString)"
    }

    func loadSessions() {
        guard let vm = viewModel else { return }
        AppLogger.log("loadSessions called", category: .nativeChat)
        guard let profileId = vm.selectedProfileId else {
            AppLogger.log("loadSessions skipped - no selected profile", category: .nativeChat, level: .warning)
            return
        }
        let profileIdCapture = profileId
        // First load from cache for fast display
        if let cached = SessionCache.load(for: profileId), !cached.isEmpty {
            AppLogger.log("Loaded \(cached.count) cached sessions for profile \(profileIdCapture.uuidString.prefix(8))", category: .nativeChat)
            vm.sessions = cached
            vm.isRestoringFromCache = true

            // Try to restore last selected session first
            let lastKey = UserDefaults.standard.string(forKey: lastSelectedSessionKey(for: profileIdCapture))
            if let key = lastKey, let lastSession = cached.first(where: { $0.key == key }) {
                vm.selectedSession = lastSession
                AppLogger.log("restored last selected session: \(String(lastSession.key.prefix(12)))", category: .nativeChat)
            } else if vm.selectedSession == nil, let first = cached.first {
                // Auto-select first session if none selected and no restore
                vm.selectedSession = first
                AppLogger.log("Auto-selected first session: \(String(first.key.prefix(12)))", category: .nativeChat)
            }
            vm.isRestoringFromCache = false
        } else {
            AppLogger.log("No cached sessions found for profile \(profileIdCapture.uuidString.prefix(8))", category: .nativeChat)
        }
        // Then fetch from network (even on cache hit) so the
        // selected session's totals/timestamps reflect the latest
        // server state. The cache is for fast display only; without
        // this, re-entering NativeChat would show stale model/tokens.
        vm.isLoading = true
        vm.error = nil
        vm.loadHistory()
        Task {
            do {
                try await SessionManager.shared.ensureConnected()
                try await Task.sleep(for: .milliseconds(100))
                let transport = await SessionManager.shared.makeTransport(sessionKey: "")
                let response = try await transport.listSessions(limit: 50)
                AppLogger.log("Loaded \(response.sessions.count) sessions", category: .nativeChat)
                self.loadedSessions(response.sessions)
            } catch {
                AppLogger.log("Load sessions error: \(error.localizedDescription)", category: .nativeChat, level: .error)
                try? await Task.sleep(for: .milliseconds(500))
                do {
                    try await SessionManager.shared.ensureConnected()
                    let transport = await SessionManager.shared.makeTransport(sessionKey: "")
                    let response = try await transport.listSessions(limit: 50)
                    self.loadedSessions(response.sessions)
                } catch {
                    AppLogger.log("Load sessions retry failed: \(error.localizedDescription)", category: .nativeChat, level: .error)
                    // Weak-network guard (mirrors the MessageCacheStorage
                    // / MessageCacheStore / HistoryLoader empty-payload
                    // fix): the cache-first step at the top of
                    // `loadSessions` already populated `vm.sessions`
                    // from `SessionCache.load`, which the picker is
                    // already rendering. Wiping with `loadedSessions([])`
                    // here would blank the picker even though the user
                    // has data and the connection is *transiently* down.
                    // Leave the cached sessions in place; just clear the
                    // loading flag and surface the error. Matches
                    // `switchProfile`'s behavior on the same failure.
                    self.viewModel?.isLoading = false
                    self.viewModel?.error = error.localizedDescription
                }
            }
        }
    }

    func loadedSessions(_ sessions: [OpenClawChatSessionEntry]) {
        guard let vm = viewModel else { return }
        let prevSelectedKey = vm.selectedSession?.key
        let prevSelectedModel = vm.selectedSession?.model
        let prevSelectedTokens = vm.selectedSession?.totalTokens
        let prevSelectedUpdatedAt = vm.selectedSession?.updatedAt
        AppLogger.log("[loadedSessions DIAG] prev selected: key=\(String(prevSelectedKey?.prefix(12) ?? "nil")) model=\(prevSelectedModel ?? "nil") tokens=\(prevSelectedTokens ?? -1) updatedAt=\(prevSelectedUpdatedAt ?? -1)", category: .nativeChat)
        AppLogger.log("[loadedSessions DIAG] incoming: count=\(sessions.count) first.model=\(sessions.first?.model ?? "nil") first.tokens=\(sessions.first?.totalTokens ?? -1) first.updatedAt=\(sessions.first?.updatedAt ?? -1)", category: .nativeChat)

        vm.sessions = sessions
        vm.isLoading = false
        if let profileId = vm.selectedProfileId {
            SessionCache.save(sessions, for: profileId)
        }

        // Try to restore last selected session and update with latest data from network
        if let profileId = vm.selectedProfileId,
           let key = UserDefaults.standard.string(forKey: lastSelectedSessionKey(for: profileId)),
           let updatedSession = sessions.first(where: { $0.key == key }) {
            let sameKey = updatedSession.key == prevSelectedKey
            let sameModel = updatedSession.model == prevSelectedModel
            let sameTokens = updatedSession.totalTokens == prevSelectedTokens
            let sameUpdatedAt = updatedSession.updatedAt == prevSelectedUpdatedAt
            AppLogger.log("[loadedSessions DIAG] branch=lastKeyMatch key=\(String(updatedSession.key.prefix(12))) newModel=\(updatedSession.model ?? "nil") newTokens=\(updatedSession.totalTokens ?? -1) newUpdatedAt=\(updatedSession.updatedAt ?? -1) sameKey=\(sameKey ? 1 : 0) sameModel=\(sameModel ? 1 : 0) sameTokens=\(sameTokens ? 1 : 0) sameUpdatedAt=\(sameUpdatedAt ? 1 : 0)", category: .nativeChat)
            vm.selectedSession = updatedSession
            // Only re-load history if the selection actually changed
            // (e.g., user opened NativeChat, then `loadedSessions`
            // restored a *different* session than the cache had). If
            // the same key was already selected from cache, the
            // first `loadHistory()` in `loadSessions` already loaded
            // the history; a second call here would fire another
            // `.historyLoaded` scrollRequest, causing the viewport
            // to jump a second time during entry.
            if !sameKey {
                vm.loadHistory()
            }
            return
        }

        // Auto-select first session if none selected
        if vm.selectedSession == nil, let first = sessions.first {
            vm.selectedSession = first
            AppLogger.log("[loadedSessions DIAG] branch=autoFirst key=\(String(first.key.prefix(12)))", category: .nativeChat)
            vm.loadHistory()
            return
        }
        // No branch matched: a selectedSession was set from cache but lastKey
        // didn't match (or no lastKey). Refresh the selectedSession in place
        // from the network response so the header reflects the latest
        // provider/model/tokens, even when the user is just re-entering.
        if let currentKey = prevSelectedKey,
           let refreshed = sessions.first(where: { $0.key == currentKey }) {
            vm.selectedSession = refreshed
            AppLogger.log("[loadedSessions DIAG] branch=inPlaceRefresh key=\(String(currentKey.prefix(12))) newModel=\(refreshed.model ?? "nil") newTokens=\(refreshed.totalTokens ?? -1) newUpdatedAt=\(refreshed.updatedAt ?? -1)", category: .nativeChat)
        } else {
            AppLogger.log("[loadedSessions DIAG] branch=noMatch prevKey=\(String(prevSelectedKey?.prefix(12) ?? "nil")) sessionsCount=\(sessions.count)", category: .nativeChat)
        }
    }

    func selectSession(_ session: OpenClawChatSessionEntry) {
        guard let vm = viewModel else { return }
        let previousKey = vm.selectedSession?.key
        // No-op when the user re-selects the current session. Without
        // this guard, the `loadHistory()` below fires another
        // `.historyLoaded` scrollRequest and yanks the viewport to
        // the bottom even though the user is just re-tapping the
        // current session. Session metadata (model, tokens, updatedAt)
        // is already in sync — `loadedSessions` updates it in place
        // from the network response.
        if previousKey == session.key {
            AppLogger.log("selectSession: same key as current, no-op (\(String(session.key.prefix(12))))", category: .nativeChat)
            return
        }
        // Reset manual-expanded bubbles. Per the user requirement:
        // expanded bubbles only collapse on session switch / view
        // exit. Switching sessions matches that reset condition —
        // the new session's bubbles start in the collapsed form
        // (driven by `shouldCollapse`), and any stale IDs from the
        // previous session can never reappear in this one's
        // `expandedMessageIds` set. Done BEFORE switching
        // selectedSession so the cache state matches the view
        // expectation (no risk of the previous session's expanded
        // state leaking into the new session's first render).
        let didSwitch = previousKey != session.key
        if didSwitch {
            vm.isRestoringFromCache = true
            CollapseStateCache.shared.clear()
        }

        // Save selected session key (per profile) BEFORE the
        // `loadSessions()` call below — `loadSessions()`'s cache
        // branch reads `lastSelectedSessionKey` to restore the
        // selection, and we want it to see the *new* key, not the
        // previous one.
        if let profileId = vm.selectedProfileId {
            UserDefaults.standard.set(session.key, forKey: lastSelectedSessionKey(for: profileId))
        }
        AppLogger.log("saved selected session: \(String(session.key.prefix(12)))", category: .nativeChat)

        if didSwitch {
            // CRITICAL ORDERING. The previous implementation
            // switched `vm.selectedSession` first, then called
            // `clearMemory(A)`, then `loadHistory()` (which
            // `hydrateSync`-populates `store[B]`). The view's
            // `messages` computed property read
            // `store[vm.selectedSession.key]`, so for the ~50-300ms
            // window between the `selectedSession` flip and
            // `hydrateSync(B)`, the view evaluated `store[B] ?? []`
            // = `[]` — empty viewport, "messages disappear" symptom
            // the user reported as "session-switch flicker, then
            // blank, then messages won't show".
            //
            // Fix: do the structural writes that the view depends
            // on in a strict order so the view never sees
            // `selectedSession = B` while `store[B]` is still empty:
            //   1. Release the streaming markdown holders from the
            //      previous session (so a stale in-progress stream
            //      doesn't keep a Cell in the LazyVStack alive).
            //   2. Call `loadSessions()` (sync, on @MainActor) —
            //      this sets `vm.selectedSession` to the new key
            //      (via the cache branch's `restored last selected
            //      session` path) AND runs `loadHistory()`'s
            //      `hydrateSync(B)` synchronously. After this call,
            //      `store[B]` is populated, so the view's next
            //      body eval reads the new content.
            //   3. `loadHistory()` again — `loadSessions()` already
            //      calls it once, but on a cross-session switch the
            //      HistoryLoader's per-session lock is held by the
            //      background task from the previous session's
            //      initial load, so the first `loadHistory()` call
            //      short-circuits to "cache hydrate still ran above"
            //      (the cache branch ran; only the network task was
            //      skipped). The explicit second `loadHistory()`
            //      here is needed only to fire the new
            //      `.historyLoaded` scrollRequest with the new
            //      `lastLoadedSessionKey != sessionKey` force-scroll
            //      signal (since `HistoryLoader.lastLoadedSessionKey`
            //      is an instance var on the loader, not on the VM,
            //      and the previous session's loadHistory call left
            //      it pointing at the old key).
            //   4. NOW clear the outgoing session's memory — at
            //      this point `store[B]` is populated, so the view
            //      won't render an empty list when the `store[A] =
            //      []` write lands. The view's `messages` computed
            //      property reads `store[vm.selectedSession.key]`,
            //      not `store[A]`, so wiping A is a no-op for
            //      rendering. (`clearMemory` is still useful for
            //      reclaiming memory; we just delay it so the
            //      view's transition isn't interrupted by an
            //      empty-`store[B]` window.)
            Task { @MainActor in
                MarkdownStreamManager.shared.releaseAll()
            }
            // `loadSessions` reads the new `lastSelectedSessionKey`
            // we just wrote to UserDefaults and assigns
            // `vm.selectedSession` accordingly. Then it calls
            // `vm.loadHistory()` synchronously, which does
            // `store.hydrateSync(for: newKey)` — this populates
            // `store[newKey]` BEFORE returning, so by the time we
            // reach `loadHistory()` on the next line, the store
            // is already ready and the view's body re-eval will
            // see the new content.
            vm.loadSessions()
            // Second `loadHistory` for the new force-scroll signal
            // (see the long block above for why one call isn't
            // enough on a cross-session switch).
            vm.loadHistory()
            // Drop the outgoing session's in-memory bubbles so they
            // don't accumulate across many session switches, but
            // KEEP the disk copy (so a subsequent switch-back under
            // weak network has a cache to fall back on, and the
            // Settings page "Message Cache" stat still reflects the
            // user's true session count — the previous wipe-and-
            // reload implementation dropped the stat to 1 when the
            // user reported "I switched between 2 sessions but
            // cache info only shows 1 session"). Done LAST, after
            // `store[B]` is populated, so the view never reads
            // an empty `store[B]` while we're transitioning.
            if let oldKey = previousKey {
                MessageCacheStore.shared.clearMemory(for: oldKey)
            }
        }
        // No `else` branch: if the session key did not change,
        // the short-circuit above already returned, so we never
        // reach this point with `!didSwitch` (previousKey==session.key
        // case).
    }

    func switchProfile(_ newProfileId: UUID) {
        guard let vm = viewModel else { return }
        if newProfileId == vm.selectedProfileId {
            return
        }
        let previousProfileId = vm.selectedProfileId
        vm.selectedProfileId = newProfileId
        vm.selectedSession = nil
        vm.isSwitchingGateway = true
        vm.error = nil
        // Reset manual-expanded bubbles. Profile switch is a hard
        // boundary — the new profile's sessions are a different
        // message space, so any persisted expand IDs from the old
        // profile are stale and must not leak across.
        CollapseStateCache.shared.clear()
        // Hard-clear every session key in the store. Profile switch
        // is a clean slate — old messages have no business surviving
        // a gateway change. Per spec §4.4 (profile switch).
        Task { @MainActor in
            await MessageCacheStore.shared.clearAll()
        }
        AppLogger.log("switchProfile from \(previousProfileId?.uuidString.prefix(8) ?? "nil") to \(newProfileId.uuidString.prefix(8))", category: .nativeChat)

        // Load cache immediately for fast display, consistent with loadSessions flow
        var hasCache = false
        if let cached = SessionCache.load(for: newProfileId), !cached.isEmpty {
            vm.sessions = cached
            vm.isRestoringFromCache = true
            let lastKey = UserDefaults.standard.string(forKey: lastSelectedSessionKey(for: newProfileId))
            if let key = lastKey, let lastSession = cached.first(where: { $0.key == key }) {
                vm.selectedSession = lastSession
            } else if let first = cached.first {
                vm.selectedSession = first
            }
            vm.isRestoringFromCache = false
            hasCache = true
        } else {
            vm.sessions = []
            vm.isRestoringFromCache = false
            vm.isLoading = true
        }

        let profileIdCapture = newProfileId
        let hadCache = hasCache
        Task {
            // Release any active stream holders from the previous profile/session
            await MainActor.run {
                MarkdownStreamManager.shared.releaseAll()
            }
            // If we have a cached session selected, kick off history load
            // so the chat panel isn't empty while we wait for the network switch
            if hadCache {
                vm.loadHistory()
            }

            let profile = await MainActor.run {
                ProfileManager.shared.getProfile(id: profileIdCapture)
            }
            guard let profile = profile else {
                AppLogger.log("switchProfile - profile not found", category: .nativeChat, level: .warning)
                vm.error = "Profile not found"
                return
            }
            await ProfileManager.shared.switchToProfile(profile)
            AppLogger.log("switchProfile - active profile switched, fetching network sessions", category: .nativeChat)

            // Fetch from network now that the new gateway is connected
            do {
                try await SessionManager.shared.ensureConnected()
                try await Task.sleep(for: .milliseconds(100))
                let transport = await SessionManager.shared.makeTransport(sessionKey: "")
                let response = try await transport.listSessions(limit: 50)
                self.loadedSessions(response.sessions)
            } catch {
                AppLogger.log("Load sessions after switch error: \(error.localizedDescription)", category: .nativeChat, level: .error)
                // Cache (if any) is already shown, so just clear the loading flag
                vm.error = error.localizedDescription
            }
            vm.isSwitchingGateway = false
            vm.isLoading = false
        }
    }

    func createSession() {
        guard let vm = viewModel else { return }
        vm.isLoading = true
        // If the user has a session selected, scope the new session
        // to that session's agent instead of the gateway's default
        // agent. Keys have the form `agent:<agentId>:<rest>`, so
        // segment index 1 carries the agent id. If the key doesn't
        // match the expected shape (e.g. legacy "global"/"unknown"
        // sentinels), fall through to `nil` and let the gateway
        // pick its default.
        let selectedAgentId: String? = {
            guard let key = vm.selectedSession?.key else { return nil }
            return SessionKey.parse(key).agentId
        }()
        AppLogger.log("createSession - using selected agentId: \(selectedAgentId ?? "<default>")", category: .nativeChat)

        let customKey: String? = {
            guard let agent = selectedAgentId, !agent.isEmpty else { return nil }
            let clientLabel = Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String
                ?? "SmartChatApp"
            return SessionKey.makeNew(agentId: agent, clientLabel: clientLabel)
        }()
        if let customKey {
            AppLogger.log("createSession - requesting custom key: \(customKey)", category: .nativeChat)
        }

        Task {
            do {
                try await SessionManager.shared.ensureConnected()
                let sessionKey = try await SessionManager.shared.createSession(
                    agentId: selectedAgentId,
                    customKey: customKey
                )
                AppLogger.log("Created session: \(String(sessionKey))", category: .nativeChat)
                self.sessionCreated(sessionKey)
                vm.loadSessions()
            } catch {
                AppLogger.log("Create session error: \(error.localizedDescription)", category: .nativeChat, level: .error)
                vm.error = error.localizedDescription
            }
        }
    }

    func sessionCreated(_ sessionKey: String) {
        guard let vm = viewModel else { return }
        AppLogger.log("Session created callback: \(sessionKey)", category: .nativeChat)
        vm.isLoading = false
        // Build a minimal entry from the new key. The next loadSessions
        // (already dispatched by createSession's task) will
        // replace this with the full entry (model, tokens, etc.) via
        // loadedSessions' in-place refresh on matching key.
        let newEntry = OpenClawChatSessionEntry(
            key: sessionKey,
            kind: nil,
            displayName: nil,
            surface: nil,
            subject: nil,
            room: nil,
            space: nil,
            updatedAt: nil,
            sessionId: nil,
            systemSent: nil,
            abortedLastRun: nil,
            thinkingLevel: nil,
            verboseLevel: nil,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: nil,
            modelProvider: nil,
            model: nil,
            contextTokens: nil
        )
        vm.selectSession(newEntry)
    }
}
