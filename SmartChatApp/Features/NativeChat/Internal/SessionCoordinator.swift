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
                    self.loadedSessions([])
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
            vm.selectedSession = updatedSession
            let sameKey = updatedSession.key == prevSelectedKey
            let sameModel = updatedSession.model == prevSelectedModel
            let sameTokens = updatedSession.totalTokens == prevSelectedTokens
            let sameUpdatedAt = updatedSession.updatedAt == prevSelectedUpdatedAt
            AppLogger.log("[loadedSessions DIAG] branch=lastKeyMatch key=\(String(updatedSession.key.prefix(12))) newModel=\(updatedSession.model ?? "nil") newTokens=\(updatedSession.totalTokens ?? -1) newUpdatedAt=\(updatedSession.updatedAt ?? -1) sameKey=\(sameKey ? 1 : 0) sameModel=\(sameModel ? 1 : 0) sameTokens=\(sameTokens ? 1 : 0) sameUpdatedAt=\(sameUpdatedAt ? 1 : 0)", category: .nativeChat)
            // Reload history with updated session info to refresh provider/model/tokens display
            vm.loadHistory()
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
        // Pick the freshest instance from sessions (rather than
        // the one passed in, which may be from a stale dropdown).
        // This keeps the second-line provider/model/totalTokens/updatedAt
        // in sync with whatever the most recent session-list fetch
        // produced.
        if let fresh = vm.sessions.first(where: { $0.key == session.key }) {
            vm.selectedSession = fresh
        } else {
            vm.selectedSession = session
        }

        // Only clear messages if switching to a different session
        let didSwitch = previousKey != session.key
        if didSwitch {
            vm.messages = []
            vm.isRestoringFromCache = true
        }

        // Save selected session key (per profile)
        if let profileId = vm.selectedProfileId {
            UserDefaults.standard.set(session.key, forKey: lastSelectedSessionKey(for: profileId))
        }
        AppLogger.log("saved selected session: \(String(session.key.prefix(12)))", category: .nativeChat)
        if didSwitch {
            Task { @MainActor in
                MarkdownStreamManager.shared.releaseAll()
            }
            vm.loadSessions()
            vm.loadHistory()
        } else {
            vm.loadHistory()
        }
    }

    func switchProfile(_ newProfileId: UUID) {
        guard let vm = viewModel else { return }
        if newProfileId == vm.selectedProfileId {
            return
        }
        let previousProfileId = vm.selectedProfileId
        vm.selectedProfileId = newProfileId
        vm.selectedSession = nil
        vm.messages = []
        vm.isSwitchingGateway = true
        vm.error = nil
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
