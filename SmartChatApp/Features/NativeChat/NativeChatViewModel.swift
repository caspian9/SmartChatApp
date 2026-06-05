import Foundation
import os
import OpenClawChatUI
import OpenClawKit

private func lastSelectedSessionKey(for profileId: UUID) -> String {
    "lastSelectedSession_\(profileId.uuidString)"
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
    private(set) var isLoading: Bool = false
    var isSending: Bool = false
    private(set) var isSwitchingGateway: Bool = false
    var error: String?
    var isRestoringFromCache: Bool = false
    var needsScrollToBottom: Bool = false
    var scrollTrigger: Int = 0
    var cacheLoadCounter: Int = 0

    // MARK: - Collaborators

    let messageReceiver: MessageReceiver
    let historyLoader: HistoryLoader
    let eventInterpreter: EventInterpreter

    init() {
        self.messageReceiver = MessageReceiver()
        self.historyLoader = HistoryLoader()
        self.eventInterpreter = EventInterpreter()
        self.messageReceiver.viewModel = self
        self.historyLoader.viewModel = self
        self.eventInterpreter.viewModel = self
    }

    // MARK: - Public API (called by NativeChatView)

    func setSelectedProfile(_ profileId: UUID?) {
        if selectedProfileId != profileId {
            selectedProfileId = profileId
        }
    }

    func loadSessions() {
        AppLogger.log("loadSessions called", category: .nativeChat)
        guard let profileId = selectedProfileId else {
            AppLogger.log("loadSessions skipped - no selected profile", category: .nativeChat, level: .warning)
            return
        }
        let profileIdCapture = profileId
        // First load from cache for fast display
        if let cached = SessionCache.load(for: profileId), !cached.isEmpty {
            AppLogger.log("Loaded \(cached.count) cached sessions for profile \(profileIdCapture.uuidString.prefix(8))", category: .nativeChat)
            sessions = cached
            isRestoringFromCache = true

            // Try to restore last selected session first
            let lastKey = UserDefaults.standard.string(forKey: lastSelectedSessionKey(for: profileIdCapture))
            if let key = lastKey, let lastSession = cached.first(where: { $0.key == key }) {
                selectedSession = lastSession
                AppLogger.log("restored last selected session: \(String(lastSession.key.prefix(12)))", category: .nativeChat)
            } else if selectedSession == nil, let first = cached.first {
                // Auto-select first session if none selected and no restore
                selectedSession = first
                AppLogger.log("Auto-selected first session: \(String(first.key.prefix(12)))", category: .nativeChat)
            }
            isRestoringFromCache = false
        } else {
            AppLogger.log("No cached sessions found for profile \(profileIdCapture.uuidString.prefix(8))", category: .nativeChat)
        }
        // Then fetch from network (even on cache hit) so the
        // selected session's totals/timestamps reflect the latest
        // server state. The cache is for fast display only; without
        // this, re-entering NativeChat would show stale model/tokens.
        isLoading = true
        error = nil
        loadHistory()
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
        let prevSelectedKey = selectedSession?.key
        let prevSelectedModel = selectedSession?.model
        let prevSelectedTokens = selectedSession?.totalTokens
        let prevSelectedUpdatedAt = selectedSession?.updatedAt
        AppLogger.log("[loadedSessions DIAG] prev selected: key=\(String(prevSelectedKey?.prefix(12) ?? "nil")) model=\(prevSelectedModel ?? "nil") tokens=\(prevSelectedTokens ?? -1) updatedAt=\(prevSelectedUpdatedAt ?? -1)", category: .nativeChat)
        AppLogger.log("[loadedSessions DIAG] incoming: count=\(sessions.count) first.model=\(sessions.first?.model ?? "nil") first.tokens=\(sessions.first?.totalTokens ?? -1) first.updatedAt=\(sessions.first?.updatedAt ?? -1)", category: .nativeChat)

        self.sessions = sessions
        isLoading = false
        if let profileId = selectedProfileId {
            SessionCache.save(sessions, for: profileId)
        }

        // Try to restore last selected session and update with latest data from network
        if let profileId = selectedProfileId,
           let key = UserDefaults.standard.string(forKey: lastSelectedSessionKey(for: profileId)),
           let updatedSession = sessions.first(where: { $0.key == key }) {
            selectedSession = updatedSession
            let sameKey = updatedSession.key == prevSelectedKey
            let sameModel = updatedSession.model == prevSelectedModel
            let sameTokens = updatedSession.totalTokens == prevSelectedTokens
            let sameUpdatedAt = updatedSession.updatedAt == prevSelectedUpdatedAt
            AppLogger.log("[loadedSessions DIAG] branch=lastKeyMatch key=\(String(updatedSession.key.prefix(12))) newModel=\(updatedSession.model ?? "nil") newTokens=\(updatedSession.totalTokens ?? -1) newUpdatedAt=\(updatedSession.updatedAt ?? -1) sameKey=\(sameKey ? 1 : 0) sameModel=\(sameModel ? 1 : 0) sameTokens=\(sameTokens ? 1 : 0) sameUpdatedAt=\(sameUpdatedAt ? 1 : 0)", category: .nativeChat)
            // Reload history with updated session info to refresh provider/model/tokens display
            loadHistory()
            return
        }

        // Auto-select first session if none selected
        if selectedSession == nil, let first = sessions.first {
            selectedSession = first
            AppLogger.log("[loadedSessions DIAG] branch=autoFirst key=\(String(first.key.prefix(12)))", category: .nativeChat)
            loadHistory()
            return
        }
        // No branch matched: a selectedSession was set from cache but lastKey
        // didn't match (or no lastKey). Refresh the selectedSession in place
        // from the network response so the header reflects the latest
        // provider/model/tokens, even when the user is just re-entering.
        if let currentKey = prevSelectedKey,
           let refreshed = sessions.first(where: { $0.key == currentKey }) {
            selectedSession = refreshed
            AppLogger.log("[loadedSessions DIAG] branch=inPlaceRefresh key=\(String(currentKey.prefix(12))) newModel=\(refreshed.model ?? "nil") newTokens=\(refreshed.totalTokens ?? -1) newUpdatedAt=\(refreshed.updatedAt ?? -1)", category: .nativeChat)
        } else {
            AppLogger.log("[loadedSessions DIAG] branch=noMatch prevKey=\(String(prevSelectedKey?.prefix(12) ?? "nil")) sessionsCount=\(sessions.count)", category: .nativeChat)
        }
    }

    func selectSession(_ session: OpenClawChatSessionEntry) {
        let previousKey = selectedSession?.key
        // Pick the freshest instance from sessions (rather than
        // the one passed in, which may be from a stale dropdown).
        // This keeps the second-line provider/model/totalTokens/updatedAt
        // in sync with whatever the most recent session-list fetch
        // produced.
        if let fresh = sessions.first(where: { $0.key == session.key }) {
            selectedSession = fresh
        } else {
            selectedSession = session
        }

        // Only clear messages if switching to a different session
        let didSwitch = previousKey != session.key
        if didSwitch {
            messages = []
            isRestoringFromCache = true
        }

        // Save selected session key (per profile)
        if let profileId = selectedProfileId {
            UserDefaults.standard.set(session.key, forKey: lastSelectedSessionKey(for: profileId))
        }
        AppLogger.log("saved selected session: \(String(session.key.prefix(12)))", category: .nativeChat)
        if didSwitch {
            Task { @MainActor in
                MarkdownStreamManager.shared.releaseAll()
            }
            loadSessions()
            loadHistory()
        } else {
            loadHistory()
        }
    }

    func switchProfile(_ newProfileId: UUID) {
        if newProfileId == selectedProfileId {
            return
        }
        let previousProfileId = selectedProfileId
        selectedProfileId = newProfileId
        selectedSession = nil
        messages = []
        isSwitchingGateway = true
        error = nil
        AppLogger.log("switchProfile from \(previousProfileId?.uuidString.prefix(8) ?? "nil") to \(newProfileId.uuidString.prefix(8))", category: .nativeChat)

        // Load cache immediately for fast display, consistent with loadSessions flow
        var hasCache = false
        if let cached = SessionCache.load(for: newProfileId), !cached.isEmpty {
            sessions = cached
            isRestoringFromCache = true
            let lastKey = UserDefaults.standard.string(forKey: lastSelectedSessionKey(for: newProfileId))
            if let key = lastKey, let lastSession = cached.first(where: { $0.key == key }) {
                selectedSession = lastSession
            } else if let first = cached.first {
                selectedSession = first
            }
            isRestoringFromCache = false
            hasCache = true
        } else {
            sessions = []
            isRestoringFromCache = false
            isLoading = true
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
                self.loadHistory()
            }

            let profile = await MainActor.run {
                ProfileManager.shared.getProfile(id: profileIdCapture)
            }
            guard let profile = profile else {
                AppLogger.log("switchProfile - profile not found", category: .nativeChat, level: .warning)
                self.setError("Profile not found")
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
                self.setError(error.localizedDescription)
            }
            self.finishSwitchingGateway()
        }
    }

    func createSession() {
        isLoading = true
        // If the user has a session selected, scope the new session
        // to that session's agent instead of the gateway's default
        // agent. Keys have the form `agent:<agentId>:<rest>`, so
        // segment index 1 carries the agent id. If the key doesn't
        // match the expected shape (e.g. legacy "global"/"unknown"
        // sentinels), fall through to `nil` and let the gateway
        // pick its default.
        let selectedAgentId: String? = {
            guard let key = selectedSession?.key else { return nil }
            let parts = key.split(separator: ":")
            guard parts.count >= 2 else { return nil }
            let candidate = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            return candidate.isEmpty ? nil : candidate
        }()
        AppLogger.log("createSession - using selected agentId: \(selectedAgentId ?? "<default>")", category: .nativeChat)
        let agentIdCapture = selectedAgentId

        // When we have a specific agent, request a custom key of the
        // shape `agent:<id>:<clientLabel>:<uuid>` so the new session
        // is tagged with the client app name in the session list
        // (visible in the session picker). The gateway lowercases the
        // entire key during normalization, so "SmartChatApp" is
        // stored as "smartchatapp" server-side. Read the label from
        // CFBundleDisplayName so a future rename of the app
        // automatically tracks the bundle.
        let clientLabel = Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String
            ?? "SmartChatApp"
        let customKey: String? = {
            guard let agent = agentIdCapture, !agent.isEmpty else { return nil }
            return "agent:\(agent):\(clientLabel):\(UUID().uuidString.lowercased())"
        }()
        if let customKey {
            AppLogger.log("createSession - requesting custom key: \(customKey)", category: .nativeChat)
        }

        Task {
            do {
                try await SessionManager.shared.ensureConnected()
                let sessionKey = try await SessionManager.shared.createSession(
                    agentId: agentIdCapture,
                    customKey: customKey
                )
                AppLogger.log("Created session: \(String(sessionKey))", category: .nativeChat)
                self.sessionCreated(sessionKey)
                self.loadSessions()
            } catch {
                AppLogger.log("Create session error: \(error.localizedDescription)", category: .nativeChat, level: .error)
                self.setError(error.localizedDescription)
            }
        }
    }

    func sessionCreated(_ sessionKey: String) {
        AppLogger.log("Session created callback: \(sessionKey)", category: .nativeChat)
        isLoading = false
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
        selectSession(newEntry)
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
                        await MainActor.run {
                            Task {
                                // Only handle events for current session (check via SessionManager)
                                let currentKey = await SessionManager.shared.getCurrentSessionKey()
                                if currentKey == sessionKey {
                                    await self.handleTransportEvent(evt, sessionKey: sessionKey)
                                }
                            }
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
            } catch {
                AppLogger.log("Send message error: \(error.localizedDescription)", category: .nativeChat, level: .error)
                self.setError(error.localizedDescription)
                self.setSending(false)
            }
        }
    }

    func loadHistory() {
        historyLoader.loadHistory()
    }

    func loadMoreHistory() {}

    func receiveMessage(_ message: ChatMessage) {
        messageReceiver.receiveMessage(message)
    }

    private func setError(_ error: String?) {
        self.error = error
        isLoading = false
        isSending = false
    }

    private func setSending(_ value: Bool) {
        isSending = value
    }

    func scrollToBottom() {
        needsScrollToBottom = true
    }

    private func setNeedsScrollToBottom(_ needsScroll: Bool) {
        needsScrollToBottom = needsScroll
    }

    private func incrementScrollTrigger() {
        scrollTrigger += 1
    }

    private func loadedMoreHistory(_ messages: [ChatMessage], hasMore: Bool) {
        // No-op for now; placeholder for future pagination.
    }

    private func finishSwitchingGateway() {
        isSwitchingGateway = false
        isLoading = false
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
