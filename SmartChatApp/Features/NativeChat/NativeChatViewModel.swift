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
    private(set) var isSending: Bool = false
    private(set) var isSwitchingGateway: Bool = false
    var error: String?
    private(set) var isRestoringFromCache: Bool = false
    private(set) var needsScrollToBottom: Bool = false
    private(set) var scrollTrigger: Int = 0
    private(set) var cacheLoadCounter: Int = 0

    // MARK: - Static state (concurrency-safe via lock)
    //
    // Per-session-key reentrancy guard for `loadHistory()`. The class is
    // @MainActor; this static is deliberately outside the actor so
    // concurrent Task launches can race for the lock without bouncing
    // through main. The state is held inside the lock itself so we never
    // touch a `nonisolated(unsafe)` global directly from async code.

    @ObservationIgnored
    private static let loadHistoryLock = OSAllocatedUnfairLock<String?>(initialState: nil)

    init() {}

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
        guard let session = selectedSession else { return }
        let sessionKey = session.key
        let sessionKeyPreview = String(sessionKey.prefix(8))
        // Capture isRestoring BEFORE resetting
        let isRestoring = isRestoringFromCache
        isRestoringFromCache = false

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
                let chatMessages = cachedMessages.compactMap { msg -> ChatMessage? in
                    var text = ""
                    for contentItem in msg.content {
                        if let t = contentItem.text, !t.isEmpty {
                            text = t.trimmingCharacters(in: .whitespacesAndNewlines)
                            break
                        }
                    }
                    if text.isEmpty { return nil }
                    return ChatMessage(
                        id: msg.id.uuidString,
                        text: text,
                        timestamp: Date(timeIntervalSince1970: (msg.timestamp ?? 0) / 1000),
                        role: msg.role,
                        state: "final",
                        runId: nil,
                        seq: nil,
                        startedAt: nil,
                        endedAt: nil,
                        livenessState: nil,
                        inputTokens: msg.usage?.input,
                        outputTokens: msg.usage?.output,
                        cacheRead: msg.usage?.cacheRead,
                        cacheWrite: msg.usage?.cacheWrite,
                        toolCallId: msg.toolCallId,
                        toolName: msg.toolName,
                        stopReason: msg.stopReason
                    )
                }
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
                    var text = ""
                    var role = msg.role
                    for contentItem in msg.content {
                        if let t = contentItem.text, !t.isEmpty {
                            text = t.trimmingCharacters(in: .whitespacesAndNewlines)
                            break
                        }
                    }
                    // If no text, check for thinking content
                    if text.isEmpty {
                        for contentItem in msg.content {
                            if let thinking = contentItem.thinking, !thinking.isEmpty {
                                text = thinking.trimmingCharacters(in: .whitespacesAndNewlines)
                                role = "thinking"
                                break
                            }
                        }
                    }
                    // Append toolCall content if present (may append to existing text or create new entry)
                    var hasToolCall = false
                    var toolCallText = ""
                    for contentItem in msg.content {
                        if contentItem.type == "toolCall", let name = contentItem.name {
                            let callText = formatToolCallBubbleText(name: name, arguments: contentItem.arguments)
                            guard !callText.isEmpty else { continue }
                            hasToolCall = true
                            if toolCallText.isEmpty {
                                toolCallText = callText
                            } else {
                                toolCallText += "\n\n" + callText
                            }
                        }
                    }
                    if hasToolCall {
                        if text.isEmpty {
                            text = toolCallText
                            role = "toolCall"
                        } else {
                            text = text + "\n\n" + toolCallText
                        }
                    }
                    AppLogger.log("history msg[\(index)] contentItems=\(msg.content.count) text_len=\(text.count) role=\(role)", category: .nativeChat)
                    if text.isEmpty {
                        AppLogger.log("history msg[\(index)] skipped - empty text, content: \(String(describing: msg.content))", category: .nativeChat, level: .warning)
                        return nil
                    }
                    let ts = msg.timestamp ?? 0
                    let msgId = msg.id.uuidString
                    let textPreview = String(text.prefix(100))
                    AppLogger.log("history msg[\(index)] role=\(role) toolName=\(msg.toolName ?? "nil") toolCallId=\(msg.toolCallId ?? "nil") text_len=\(text.count) text_preview=\(textPreview)", category: .nativeChat)
                    return ChatMessage(
                        id: msgId,
                        text: text,
                        timestamp: Date(timeIntervalSince1970: ts / 1000),
                        role: role,
                        state: "final",
                        runId: nil,
                        seq: nil,
                        startedAt: nil,
                        endedAt: nil,
                        livenessState: nil,
                        inputTokens: msg.usage?.input,
                        outputTokens: msg.usage?.output,
                        cacheRead: msg.usage?.cacheRead,
                        cacheWrite: msg.usage?.cacheWrite,
                        toolCallId: msg.toolCallId,
                        toolName: msg.toolName,
                        stopReason: msg.stopReason
                    )
                }
                AppLogger.log("chatMessages count=\(chatMessages.count)", category: .nativeChat)
                // Cache the fetched messages (setMessages handles deduplication)
                let openClawMessages = chatMessages.compactMap { createOpenClawChatMessage(from: $0) }
                AppLogger.log("openClawMessages count=\(openClawMessages.count)", category: .nativeChat)
                await MessageCache.shared.setMessages(openClawMessages, for: cachedSessionKey)

                // Reload from cache to get accurate message count (cache now has all messages deduplicated)
                let finalCachedMessages = await MessageCache.shared.getMessages(for: cachedSessionKey)
                let finalChatMessages = finalCachedMessages.compactMap { msg -> ChatMessage? in
                    var text = ""
                    for contentItem in msg.content {
                        if let t = contentItem.text, !t.isEmpty {
                            text = t.trimmingCharacters(in: .whitespacesAndNewlines)
                            break
                        }
                    }
                    if text.isEmpty { return nil }
                    return ChatMessage(
                        id: msg.id.uuidString,
                        text: text,
                        timestamp: Date(timeIntervalSince1970: (msg.timestamp ?? 0) / 1000),
                        role: msg.role,
                        state: "final",
                        runId: nil,
                        seq: nil,
                        startedAt: nil,
                        endedAt: nil,
                        livenessState: nil,
                        inputTokens: msg.usage?.input,
                        outputTokens: msg.usage?.output,
                        cacheRead: msg.usage?.cacheRead,
                        cacheWrite: msg.usage?.cacheWrite,
                        toolCallId: msg.toolCallId,
                        toolName: msg.toolName,
                        stopReason: msg.stopReason
                    )
                }
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

    func loadMoreHistory() {}

    // MARK: - Private state mutators (formerly @Reducer actions called only from inside .run blocks)

    private func loadedCachedHistory(_ messages: [ChatMessage], isRestoring: Bool) {
        AppLogger.log("loadedCachedHistory setting \(messages.count) messages, isRestoring: \(isRestoring)", category: .nativeChat)
        self.messages = messages
        scrollTrigger += 1
        cacheLoadCounter += 1
        // Precompute markdown and collapse states synchronously on main actor, then force refresh
        Task { [messages] in
            await MainActor.run {
                MarkdownCache.shared.precomputeForMessages(messages)
                CollapseStateCache.shared.precompute(for: messages)
            }
            // Force view refresh after cache is populated
            self.incrementCacheCounter()
        }
    }

    private func loadedNetworkHistory(sessionKey: String, messages: [ChatMessage]) {
        // Drop the result if the user has switched to a different
        // session since this fetch started. Comparing against
        // `selectedSession?.key` (the only source of truth
        // for what the user is looking at) avoids the race the
        // old `SessionManager.getCurrentSessionKey()` guard had
        // with the concurrent `makeTransport("")` from
        // `loadSessions`.
        let currentKey = selectedSession?.key
        if currentKey != sessionKey {
            let currentKeyLog = currentKey ?? "nil"
            AppLogger.log("loadedNetworkHistory dropped: session \(String(sessionKey.prefix(8))) is no longer selected (current: \(String(currentKeyLog.prefix(8))))", category: .nativeChat, level: .warning)
            return
        }
        AppLogger.log("loadedNetworkHistory applying \(messages.count) messages for session: \(String(sessionKey.prefix(8)))", category: .nativeChat)
        self.messages = messages
        scrollTrigger += 1
        cacheLoadCounter += 1
        Task { [messages] in
            await MainActor.run {
                MarkdownCache.shared.precomputeForMessages(messages)
                CollapseStateCache.shared.precompute(for: messages)
            }
            self.incrementCacheCounter()
        }
    }

    private func incrementCacheCounter() {
        cacheLoadCounter += 1
    }

    private func appendNewMessages(_ newMessages: [ChatMessage]) {
        if newMessages.isEmpty {
            AppLogger.log("appendNewMessages - no new messages", category: .nativeChat)
            return
        }
        AppLogger.log("appendNewMessages appending \(newMessages.count) messages", category: .nativeChat)
        messages.append(contentsOf: newMessages)
        needsScrollToBottom = true
    }

    private func receiveMessage(_ message: ChatMessage) {
        // Check if this is an update to existing message or new message
        if let existingIndex = messages.firstIndex(where: { $0.id == message.id }) {
            // Update existing message (streaming text update)
            var existingMessage = messages[existingIndex]
            AppLogger.log("receiveMessage update - id: \(String(message.id.prefix(8))), existingIndex: \(existingIndex), newText len: \(message.text.count), existingText len: \(existingMessage.text.count), state: \(message.state)", category: .nativeChat)
            // Only update text if new text is not empty (preserve content on end phase)
            if !message.text.isEmpty {
                existingMessage.text = message.text
                AppLogger.log("receiveMessage updated text, new len: \(existingMessage.text.count), prev state: \(existingMessage.state), new state: \(message.state)", category: .nativeChat)
            } else {
                AppLogger.log("receiveMessage SKIPPED text update (empty), prev state: \(existingMessage.state), new state: \(message.state)", category: .nativeChat, level: .warning)
            }
            existingMessage.state = message.state
            if message.startedAt != nil { existingMessage.startedAt = message.startedAt }
            if message.endedAt != nil { existingMessage.endedAt = message.endedAt }
            if message.livenessState != nil { existingMessage.livenessState = message.livenessState }
            if message.seq != nil { existingMessage.seq = message.seq }
            if message.inputTokens != nil { existingMessage.inputTokens = message.inputTokens }
            if message.outputTokens != nil { existingMessage.outputTokens = message.outputTokens }
            if message.cacheRead != nil { existingMessage.cacheRead = message.cacheRead }
            if message.cacheWrite != nil { existingMessage.cacheWrite = message.cacheWrite }
            messages[existingIndex] = existingMessage
            scrollTrigger += 1
            AppLogger.log("updated message: \(message.id), text length: \(existingMessage.text.count), FINAL state: \(existingMessage.state)", category: .nativeChat)
        } else {
            // Fallback: id mismatch between streaming (id=runId) and cached
            // (id=server-id) can cause a second copy of the same logical
            // message to be appended. Match by role+text+timestamp and
            // update in place so the display doesn't accumulate duplicates
            // while the cache dedup (role|text|timestamp|usage) keeps
            // the disk count stable.
            let similarIndex = messages.firstIndex { existing in
                existing.role == message.role &&
                existing.text == message.text &&
                abs(existing.timestamp.timeIntervalSince(message.timestamp)) < 60.0
            }
            if let similarIndex = similarIndex {
                var existingMessage = messages[similarIndex]
                AppLogger.log("receiveMessage similar-match - newId=\(String(message.id.prefix(8))) existingId=\(String(existingMessage.id.prefix(8))) idx=\(similarIndex) state=\(message.state)", category: .nativeChat)
                if !message.text.isEmpty {
                    existingMessage.text = message.text
                }
                existingMessage.state = message.state
                if message.startedAt != nil { existingMessage.startedAt = message.startedAt }
                if message.endedAt != nil { existingMessage.endedAt = message.endedAt }
                if message.livenessState != nil { existingMessage.livenessState = message.livenessState }
                if message.seq != nil { existingMessage.seq = message.seq }
                if message.inputTokens != nil { existingMessage.inputTokens = message.inputTokens }
                if message.outputTokens != nil { existingMessage.outputTokens = message.outputTokens }
                if message.cacheRead != nil { existingMessage.cacheRead = message.cacheRead }
                if message.cacheWrite != nil { existingMessage.cacheWrite = message.cacheWrite }
                messages[similarIndex] = existingMessage
                scrollTrigger += 1
            } else {
                // New message. If the last message is still in
                // progress (state != "final"), insert just before it
                // so the in-progress assistant stays at the bottom of
                // the array and the new sub-event appears above it.
                // Otherwise (last is final, e.g. a previous run or
                // user message), append normally.
                if let last = messages.last, last.state != "final" {
                    messages.insert(message, at: messages.count - 1)
                    AppLogger.log("receiveMessage new (inserted before last, lastState=\(last.state)) - id: \(String(message.id.prefix(8))), text len: \(message.text.count), state: \(message.state)", category: .nativeChat)
                } else {
                    messages.append(message)
                    AppLogger.log("receiveMessage new (appended) - id: \(String(message.id.prefix(8))), text len: \(message.text.count), state: \(message.state)", category: .nativeChat)
                }
                scrollTrigger += 1
            }
        }
        // When state is final, message reception is complete - reset sending state
        if message.state == "final" {
            // Intentionally do NOT write the streaming copy to the
            // cache here. The agent-end event payload does not carry
            // usage tokens, so the streaming copy's dedup key
            // (`role|text|bucket|usage`) differs from the network's
            // server-stored message (which has the full usage).
            // Writing the streaming copy would cause both versions
            // to land in the cache — and on re-entry, both would
            // display, with the streaming copy missing the 4 token
            // values. loadHistory's network fetch is the
            // authoritative cache writer and runs on every entry.
            setSending(false)
        }
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
        switch event {
        case .agent(let payload):
            AppLogger.log("agent event - stream=\(payload.stream) runId=\(payload.runId) seq=\(payload.seq ?? -1) ts=\(payload.ts ?? 0) data=\(summarizeData(payload.data))", category: .nativeChat)
            let runId = payload.runId
            let ts = payload.ts ?? 0
            let timestamp = Date(timeIntervalSince1970: Double(ts) / 1000)
            let data = payload.data
            let seq = payload.seq
            let phase = extractString(from: data, key: "phase")
            let startedAtMs = extractDouble(from: data, key: "startedAt")
            let endedAtMs = extractDouble(from: data, key: "endedAt")
            let livenessState = extractString(from: data, key: "livenessState")

            switch payload.stream {
            case "lifecycle":
                if phase == "start" {
                    // Start of a new run. The lifecycle signal alone doesn't know
                    // what content is coming — it could be assistant text, thinking,
                    // or tool calls. Create a generic placeholder (id=runId) so the
                    // UI has a 3-dot indicator immediately. First real content
                    // (assistant/thinking/tool) creates its own sibling message with
                    // a typed id; assistant deltas also land on this placeholder
                    // since they share id=runId, so it doubles as the assistant
                    // bubble when text arrives.
                    AppLogger.log("agent lifecycle start - runId: \(runId), seq: \(seq ?? -1), startedAt: \(startedAtMs)", category: .nativeChat)
                    await MainActor.run {
                        MarkdownStreamManager.shared.holder(for: runId)
                        MarkdownCache.shared.setNeedsMarkdown(runId, value: true)
                    }
                    let message = ChatMessage(
                        id: runId,
                        text: "",
                        timestamp: timestamp,
                        role: "assistant",
                        state: "streaming",
                        runId: runId,
                        seq: seq,
                        startedAt: startedAtMs > 0 ? Date(timeIntervalSince1970: startedAtMs / 1000) : timestamp,
                        endedAt: nil,
                        livenessState: livenessState,
                        toolCallId: nil,
                        toolName: nil,
                        stopReason: nil,
                        isFresh: true
                    )
                    receiveMessage(message)
                } else if phase == "end" {
                    // End of run. The previous implementation keyed off phase=end
                    // for every event, which caused tool end phases to prematurely
                    // finalize the run and reset sending. With stream-based dispatch,
                    // only the actual lifecycle end reaches here, so the run-level
                    // state (tokens, endedAt, setSending(false)) is correctly tied
                    // to the real terminal signal.
                    AppLogger.log("agent lifecycle end - runId: \(runId), data keys: \(data.keys.map { $0 })", category: .nativeChat)
                    var inputTokens: Int?
                    var outputTokens: Int?
                    var cacheRead: Int?
                    var cacheWrite: Int?
                    if let usage = data["usage"]?.value as? [String: Any] {
                        AppLogger.log("found usage dict: \(String(describing: usage))", category: .nativeChat)
                        if let input = usage["input"] as? Int { inputTokens = input }
                        if let output = usage["output"] as? Int { outputTokens = output }
                        if let cr = usage["cacheRead"] as? Int { cacheRead = cr }
                        if let cw = usage["cacheWrite"] as? Int { cacheWrite = cw }
                    }
                    if inputTokens == nil, let input = data["inputTokens"]?.value as? Int { inputTokens = input }
                    if outputTokens == nil, let output = data["outputTokens"]?.value as? Int { outputTokens = output }
                    if cacheRead == nil, let cr = data["cacheRead"]?.value as? Int { cacheRead = cr }
                    if cacheWrite == nil, let cw = data["cacheWrite"]?.value as? Int { cacheWrite = cw }
                    AppLogger.log("agent lifecycle end - tokens: input: \(inputTokens ?? -1), output: \(outputTokens ?? -1), cacheRead: \(cacheRead ?? -1), cacheWrite: \(cacheWrite ?? -1)", category: .nativeChat)
                    // Flush the markdown stream buffer and read the full accumulated
                    // text so it can be persisted. Deltas carry the full cumulative
                    // string per chunk; MarkdownViewTextKit holds the real body until
                    // end() releases it. Without this flush, the cache write below
                    // captures an empty body and the assistant reply is lost.
                    let fullText: String = await MainActor.run {
                        MarkdownStreamManager.shared.end(messageId: runId)
                        return MarkdownStreamManager.shared.currentText(for: runId) ?? ""
                    }
                    AppLogger.log("agent lifecycle end - fullText len: \(fullText.count) for runId: \(runId)", category: .nativeChat)
                    let message = ChatMessage(
                        id: runId,
                        text: fullText,
                        timestamp: timestamp,
                        role: "assistant",
                        state: "final",
                        runId: runId,
                        seq: seq,
                        startedAt: startedAtMs > 0 ? Date(timeIntervalSince1970: startedAtMs / 1000) : nil,
                        endedAt: endedAtMs > 0 ? Date(timeIntervalSince1970: endedAtMs / 1000) : timestamp,
                        livenessState: livenessState,
                        inputTokens: inputTokens,
                        outputTokens: outputTokens,
                        cacheRead: cacheRead,
                        cacheWrite: cacheWrite,
                        toolCallId: nil,
                        toolName: nil,
                        stopReason: nil,
                        isFresh: true
                    )
                    receiveMessage(message)
                    // Holder no longer needed — SwiftUI flips to the static
                    // MarkdownCardView once state becomes "final", so the streaming
                    // view is dismantled. Release to bound memory across many turns.
                    await MainActor.run {
                        MarkdownStreamManager.shared.release(messageId: runId)
                    }
                    // Only the real terminal signal resets the sending flag.
                    setSending(false)
                }
            case "assistant":
                // Server sends the FULL cumulative text on every chunk (see
                // OpenClawChatUI/ChatViewModel.handleAgentEvent for the reference
                // behavior). Hand the cumulative string to the holder; it computes
                // the actual incremental suffix and feeds only that to the stream.
                // Without this we render `ABC` + `ABCDE` + `ABCDEF` as
                // `ABCABCDEABCDEF`. The placeholder at id=runId absorbs this update.
                let text = extractString(from: data, key: "text") ?? ""
                AppLogger.log("agent assistant delta - text len: \(text.count)", category: .nativeChat)
                guard !text.isEmpty else { return }
                await MainActor.run {
                    MarkdownStreamManager.shared.appendCumulative(messageId: runId, cumulative: text)
                }
                let message = ChatMessage(
                    id: runId,
                    text: text,
                    timestamp: timestamp,
                    role: "assistant",
                    state: "streaming",
                    runId: runId,
                    seq: seq,
                    startedAt: nil,
                    endedAt: nil,
                    livenessState: livenessState,
                    toolCallId: nil,
                    toolName: nil,
                    stopReason: nil,
                    isFresh: true
                )
                receiveMessage(message)
            case "thinking":
                // Thinking deltas are emitted as a separate stream from the
                // assistant text — they don't share an id with the assistant
                // placeholder. Use a synthetic id so the message dedups against
                // itself across deltas and renders as a thinking bubble.
                let text = extractString(from: data, key: "text") ?? ""
                AppLogger.log("agent thinking delta - text len: \(text.count)", category: .nativeChat)
                guard !text.isEmpty else { return }
                let message = ChatMessage(
                    id: "\(runId):thinking",
                    text: text,
                    timestamp: timestamp,
                    role: "thinking",
                    state: "final",
                    runId: runId,
                    seq: nil,
                    startedAt: nil,
                    endedAt: nil,
                    livenessState: nil,
                    toolCallId: nil,
                    toolName: nil,
                    stopReason: nil,
                    isFresh: true
                )
                receiveMessage(message)
            case "tool":
                // Tool events share stream="tool" and discriminate via phase.
                // - start: tool begins (name + args)
                // - update: tool sends an intermediate state (progress, partial
                //   result). Many tools skip this; bash/web_search do not.
                // - result: tool finished (result or error)
                // Each toolCallId gets its own synthetic id so concurrent tools
                // (or the same tool called twice in one run) don't collide.
                // This branch is only hit when verbose level is on (the modern
                // path goes through `stream: "item"` and `stream: "command_output"`
                // below).
                guard let toolCallId = extractString(from: data, key: "toolCallId") else {
                    AppLogger.log("agent tool event missing toolCallId, skipping. data keys: \(data.keys.map { $0 })", category: .nativeChat, level: .warning)
                    return
                }
                let toolName = extractString(from: data, key: "name") ?? ""
                if phase == "start" {
                    let text = formatToolCallBubbleText(name: toolName, arguments: data["args"])
                    AppLogger.log("agent tool start - tool: \(toolName), callId: \(toolCallId)", category: .nativeChat)
                    let message = ChatMessage(
                        id: "\(runId):tool:\(toolCallId)",
                        text: text,
                        timestamp: timestamp,
                        role: "toolCall",
                        state: "final",
                        runId: runId,
                        seq: seq,
                        startedAt: timestamp,
                        endedAt: nil,
                        livenessState: nil,
                        toolCallId: toolCallId,
                        toolName: toolName,
                        stopReason: nil,
                        isFresh: true
                    )
                    receiveMessage(message)
                } else if phase == "update" {
                    // Intermediate state. Refresh the toolCall bubble with the
                    // latest args/progress so the user sees the tool is alive.
                    let text = formatToolCallBubbleText(name: toolName, arguments: data["args"])
                    AppLogger.log("agent tool update - tool: \(toolName), callId: \(toolCallId), text len: \(text.count)", category: .nativeChat)
                    let message = ChatMessage(
                        id: "\(runId):tool:\(toolCallId)",
                        text: text,
                        timestamp: timestamp,
                        role: "toolCall",
                        state: "final",
                        runId: runId,
                        seq: seq,
                        startedAt: nil,
                        endedAt: nil,
                        livenessState: nil,
                        toolCallId: toolCallId,
                        toolName: toolName,
                        stopReason: nil,
                        isFresh: true
                    )
                    receiveMessage(message)
                } else if phase == "result" {
                    let resultValue = data["result"]?.value
                    let text = formatToolResultText(result: resultValue)
                    let isError = (data["isError"]?.value as? Bool) ?? false
                    AppLogger.log("agent tool result - tool: \(toolName), callId: \(toolCallId), isError: \(isError), text len: \(text.count)", category: .nativeChat)
                    let message = ChatMessage(
                        id: "\(runId):toolResult:\(toolCallId)",
                        text: text,
                        timestamp: timestamp,
                        role: "toolResult",
                        state: "final",
                        runId: runId,
                        seq: seq,
                        startedAt: startedAtMs > 0 ? Date(timeIntervalSince1970: startedAtMs / 1000) : nil,
                        endedAt: timestamp,
                        livenessState: nil,
                        toolCallId: toolCallId,
                        toolName: toolName,
                        stopReason: isError ? "error" : nil,
                        isFresh: true
                    )
                    receiveMessage(message)
                }
            case "item":
                // Modern tool/command/patch lifecycle events. Each toolCallId
                // emits one `item` event per kind: tool, command (bash/exec),
                // patch, search, analysis. We map them all to a toolCall
                // bubble keyed by itemId so concurrent tools don't collide.
                // For non-command kinds, the actual result content is in the
                // `stream: "tool"` event which is only emitted when verbose
                // level is on; without it the toolResult bubble only has
                // metadata (status/error). For command kind, the output
                // arrives via `stream: "command_output"` events.
                guard let itemId = extractString(from: data, key: "itemId") else {
                    AppLogger.log("agent item event missing itemId, skipping. keys: \(data.keys.map { $0 })", category: .nativeChat, level: .warning)
                    return
                }
                let itemPhase = extractString(from: data, key: "phase")
                let kind = extractString(from: data, key: "kind") ?? "tool"
                let name = extractString(from: data, key: "name") ?? ""
                let status = extractString(from: data, key: "status")
                let progressText = extractString(from: data, key: "progressText")
                let summary = extractString(from: data, key: "summary")
                let errorText = extractString(from: data, key: "error")
                let toolCallId = extractString(from: data, key: "toolCallId")
                let meta = extractString(from: data, key: "meta")
                AppLogger.log("agent item - kind: \(kind), phase: \(itemPhase ?? "nil"), itemId: \(itemId), status: \(status ?? "?")", category: .nativeChat)
                // Build text representation for the toolCall bubble. Use the
                // shared formatter so live bubbles match the history format
                // ("ToolCall: <name>" + "key: value" lines per arg). The
                // modern `item` event does not include the actual command
                // string in its data, so when args are missing the bubble
                // uses `meta` (server-side human-readable summary) as the
                // second line. When args are present (legacy `stream: "tool"`
                // path, or future server changes), they flow through
                // automatically. progressText is appended during running
                // state so the user sees the tool is alive.
                var callText = formatToolCallBubbleText(name: name, arguments: data["args"], meta: meta)
                if callText.isEmpty {
                    callText = "ToolCall: \(kind)"
                }
                if let progressText, !progressText.isEmpty {
                    callText += "\n" + progressText
                }
                if itemPhase == "end" {
                    // End phase. If there's a summary (e.g., command output
                    // captured at end), fold it into a toolResult bubble so
                    // the user can read what the tool produced. Otherwise just
                    // mark the toolCall as ended.
                    let resultText = summary ?? errorText ?? ""
                    if !resultText.isEmpty {
                        let message = ChatMessage(
                            id: "\(runId):itemResult:\(itemId)",
                            text: resultText,
                            timestamp: timestamp,
                            role: "toolResult",
                            state: "final",
                            runId: runId,
                            seq: seq,
                            startedAt: startedAtMs > 0 ? Date(timeIntervalSince1970: startedAtMs / 1000) : nil,
                            endedAt: timestamp,
                            livenessState: nil,
                            toolCallId: toolCallId,
                            toolName: name,
                            stopReason: (errorText != nil) ? "error" : nil,
                            isFresh: true
                        )
                        receiveMessage(message)
                    }
                }
                // Always update the toolCall bubble so start/update/end phases
                // surface a running indicator. In-place update by id matches
                // the same item across phases.
                let message = ChatMessage(
                    id: "\(runId):item:\(itemId)",
                    text: callText,
                    timestamp: timestamp,
                    role: "toolCall",
                    state: itemPhase == "end" ? "final" : "streaming",
                    runId: runId,
                    seq: seq,
                    startedAt: startedAtMs > 0 ? Date(timeIntervalSince1970: startedAtMs / 1000) : nil,
                    endedAt: itemPhase == "end" ? timestamp : nil,
                    livenessState: nil,
                    toolCallId: toolCallId,
                    toolName: name,
                    stopReason: nil,
                    isFresh: true
                )
                receiveMessage(message)
            case "command_output":
                // Per-item command output stream. For exec/bash tools the
                // result body arrives here in `output` (incremental on
                // `phase: "delta"`, final on `phase: "end"`). Accumulate into
                // a toolResult bubble keyed by itemId.
                guard let itemId = extractString(from: data, key: "itemId") else {
                    AppLogger.log("agent command_output missing itemId, skipping. keys: \(data.keys.map { $0 })", category: .nativeChat, level: .warning)
                    return
                }
                let outputPhase = extractString(from: data, key: "phase")
                let output = extractString(from: data, key: "output") ?? ""
                let toolName = extractString(from: data, key: "name") ?? ""
                let exitCode = extractInt(from: data, key: "exitCode")
                let durationMs = extractInt(from: data, key: "durationMs")
                AppLogger.log("agent command_output - phase: \(outputPhase ?? "nil"), itemId: \(itemId), output len: \(output.count), exitCode: \(exitCode.map(String.init) ?? "nil")", category: .nativeChat)
                var resultText = output
                if outputPhase == "end" {
                    // Append exit info so the bubble shows the command's
                    // disposition even if `output` is empty.
                    var trailer: [String] = []
                    if let exitCode { trailer.append("exit=\(exitCode)") }
                    if let durationMs { trailer.append("duration=\(durationMs)ms") }
                    if !trailer.isEmpty {
                        if !resultText.isEmpty { resultText += "\n" }
                        resultText += trailer.joined(separator: " ")
                    }
                }
                guard !resultText.isEmpty else { return }
                let message = ChatMessage(
                    id: "\(runId):itemResult:\(itemId)",
                    text: resultText,
                    timestamp: timestamp,
                    role: "toolResult",
                    state: outputPhase == "end" ? "final" : "streaming",
                    runId: runId,
                    seq: seq,
                    startedAt: startedAtMs > 0 ? Date(timeIntervalSince1970: startedAtMs / 1000) : nil,
                    endedAt: outputPhase == "end" ? timestamp : nil,
                    livenessState: nil,
                    toolCallId: nil,
                    toolName: toolName,
                    stopReason: exitCode.map { $0 != 0 ? "error" : nil } ?? nil,
                    isFresh: true
                )
                receiveMessage(message)
            default:
                // plan, approval, patch, compaction, error — not yet surfaced.
                AppLogger.log("agent UNHANDLED stream=\(payload.stream) runId=\(payload.runId) seq=\(payload.seq ?? -1) data=\(summarizeData(data))", category: .nativeChat)
            }

        case .chat(let chat):
            // Log full structure so we can see if server delivers thinking as
            // content blocks here (the 2026.5.28 model) vs as separate agent events.
            // Mirrors the sessionMessage log below so we can spot {type:"thinking", thinking:"..."} blocks.
            var role = "?"
            var blockSummaries: [String] = []
            if let msgAny = chat.message?.value {
                // AnyCodable stores dicts/arrays as [String: AnyCodable] / [AnyCodable] — unwrap recursively.
                let unwrapped = unwrapAnyCodable(msgAny)
                if let dict = unwrapped as? [String: Any] {
                    role = (dict["role"] as? String) ?? "?"
                    if let content = dict["content"] as? [Any] {
                        for (i, block) in content.enumerated() {
                            if let blockDict = block as? [String: Any] {
                                var parts: [String] = ["#\(i)"]
                                if let type = blockDict["type"] as? String { parts.append("type=\(type)") }
                                if let t = blockDict["text"] as? String, !t.isEmpty {
                                    let preview = t.prefix(80)
                                    parts.append("text=\"\(preview)\(t.count > 80 ? "…(\(t.count))" : "")\"")
                                }
                                if let th = blockDict["thinking"] as? String, !th.isEmpty {
                                    let preview = th.prefix(80)
                                    parts.append("thinking=\"\(preview)\(th.count > 80 ? "…(\(th.count))" : "")\"")
                                }
                                if let n = blockDict["name"] as? String { parts.append("name=\(n)") }
                                if let id = blockDict["id"] as? String { parts.append("id=\(id)") }
                                blockSummaries.append(parts.joined(separator: " "))
                            } else {
                                blockSummaries.append("#\(i)=<\(type(of: block))>")
                            }
                        }
                    } else if let content = dict["content"] {
                        blockSummaries = ["content=\(formatValue(content))"]
                    }
                } else if let str = unwrapped as? String {
                    blockSummaries = ["string=\"\(str.prefix(100))\""]
                }
            }
            AppLogger.log("chat event runId=\(chat.runId ?? "nil") sessionKey=\(chat.sessionKey ?? "nil") state=\(chat.state ?? "nil") role=\(role) blocks=[\(blockSummaries.joined(separator: " | "))] errorMessage=\(chat.errorMessage ?? "nil")", category: .nativeChat)

        case .sessionMessage(let sm):
            // History/event-stream messages are typed OpenClawChatMessage.
            var blockSummaries: [String] = []
            if let blocks = sm.message?.content {
                for (i, block) in blocks.enumerated() {
                    var parts: [String] = ["#\(i)", "type=\(block.type ?? "?")"]
                    if let t = block.text, !t.isEmpty { parts.append("text=\"\(t.prefix(80))\(t.count > 80 ? "…" : "")\"") }
                    if let th = block.thinking, !th.isEmpty { parts.append("thinking=\"\(th.prefix(80))\(th.count > 80 ? "…" : "")\"") }
                    if let n = block.name { parts.append("name=\(n)") }
                    if let id = block.id { parts.append("id=\(id)") }
                    blockSummaries.append(parts.joined(separator: " "))
                }
            }
            AppLogger.log("sessionMessage messageId=\(sm.messageId ?? "nil") messageSeq=\(sm.messageSeq ?? -1) role=\(sm.message?.role ?? "nil") blocks=[\(blockSummaries.joined(separator: " | "))]", category: .nativeChat)

        case .tick:
            AppLogger.log("transport tick", category: .nativeChat)
        case .seqGap:
            AppLogger.log("transport seqGap (out-of-order event detected)", category: .nativeChat)
        case .health(let ok):
            AppLogger.log("transport health ok=\(ok)", category: .nativeChat)
        }
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

    /// Render a data dict as a one-line string for logging. Long strings are
    /// truncated to keep log volume manageable.
    private func summarizeData(_ data: [String: AnyCodable]) -> String {
        let parts = data.keys.sorted().map { key -> String in
            guard let v = data[key]?.value else { return "\(key)=null" }
            return "\(key)=\(formatValue(v))"
        }
        return "{" + parts.joined(separator: ", ") + "}"
    }

    private func formatValue(_ v: Any) -> String {
        if let s = v as? String {
            let preview = s.prefix(120)
            return "\"\(preview)\(s.count > 120 ? "…(\(s.count))" : "")\""
        }
        if let b = v as? Bool { return "\(b)" }
        if let i = v as? Int { return "\(i)" }
        if let d = v as? Double { return "\(d)" }
        if let arr = v as? [Any] { return "[\(arr.count) items]" }
        if let dict = v as? [String: Any] { return "{\(dict.count) keys:\(dict.keys.sorted().prefix(8).joined(separator: ","))}" }
        if v is NSNull { return "null" }
        return "<\(type(of: v))>"
    }

    private func summarizeAny(_ v: Any, label: String) -> String {
        if let arr = v as? [Any] {
            let previews = arr.prefix(5).map { formatValue($0) }
            return "\(label)=[\(previews.joined(separator: ", "))\(arr.count > 5 ? ", +\(arr.count - 5) more" : "")]"
        }
        if let dict = v as? [String: Any] {
            return "\(label)=\(formatValue(v))"
        }
        return "\(label)=\(formatValue(v))"
    }

    /// Recursively unwraps `AnyCodable` so nested values are raw JSON types
    /// (`[String: Any]`, `[Any]`, `String`, etc.) instead of `AnyCodable` wrappers.
    /// `AnyCodable` stores dicts as `[String: AnyCodable]` and arrays as `[AnyCodable]`.
    private func unwrapAnyCodable(_ v: Any) -> Any {
        if let ac = v as? AnyCodable { return unwrapAnyCodable(ac.value) }
        if let arr = v as? [Any] { return arr.map { unwrapAnyCodable($0) } }
        if let arr = v as? [AnyCodable] { return arr.map { unwrapAnyCodable($0) } }
        if let dict = v as? [String: Any] { return dict.mapValues { unwrapAnyCodable($0) } }
        if let dict = v as? [String: AnyCodable] { return dict.mapValues { unwrapAnyCodable($0) } }
        return v
    }

    private func extractString(from data: [String: AnyCodable], key: String) -> String? {
        if let value = data[key] {
            if let str = value.value as? String {
                return str
            }
        }
        return nil
    }

    private func extractDouble(from data: [String: AnyCodable], key: String) -> Double {
        if let value = data[key] {
            if let d = value.value as? Double {
                return d
            }
            if let i = value.value as? Int {
                return Double(i)
            }
        }
        return 0
    }

    private func extractInt(from data: [String: AnyCodable], key: String) -> Int? {
        if let value = data[key] {
            if let i = value.value as? Int {
                return i
            }
        }
        return nil
    }

    func formatAnyCodableValue(_ value: Any) -> String {
        if let str = value as? String {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return "" }
            let first = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
            if first.count > 160 { return String(first.prefix(157)) + "…" }
            return first
        }
        if let num = value as? Int { return String(num) }
        if let num = value as? Double { return String(num) }
        if let bool = value as? Bool { return bool ? "true" : "false" }
        if let array = value as? [Any] {
            let items = array.compactMap { self.formatAnyCodableValue($0) }
            guard !items.isEmpty else { return "" }
            let preview = items.prefix(3).joined(separator: ", ")
            return items.count > 3 ? "\(preview)…" : preview
        }
        if let dict = value as? [String: Any] {
            let keys = ["name", "id", "command", "action", "path", "node", "nodeId"]
            for key in keys {
                if let label = dict[key] {
                    let str = formatAnyCodableValue(label)
                    if !str.isEmpty { return str }
                }
            }
        }
        if let dict = value as? [String: AnyCodable] {
            let keys = ["name", "id", "command", "action", "path", "node", "nodeId"]
            for key in keys {
                if let anyCodable = dict[key] {
                    let formatted = formatAnyCodableValue(anyCodable.value)
                    if !formatted.isEmpty { return formatted }
                }
            }
            // Generic scan for first non-empty string value
            for (_, anyCodable) in dict {
                let formatted = formatAnyCodableValue(anyCodable.value)
                if !formatted.isEmpty {
                    return formatted
                }
            }
        }
        return ""
    }

    /// Builds a short human-readable label for a tool call: "name: args".
    /// Falls back to a one-line JSON dump of args so the bubble has something
    /// to show even when no friendly field is present.
    func formatToolCallText(name: String, args: Any?) -> String {
        if name.isEmpty { return "" }
        guard let args else { return name }
        if let str = args as? String, !str.isEmpty {
            return "\(name): \(str)"
        }
        if let dict = args as? [String: Any] {
            if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.fragmentsAllowed, .sortedKeys]),
               let json = String(data: data, encoding: .utf8) {
                return "\(name): \(json)"
            }
        }
        if let arr = args as? [Any] {
            if let data = try? JSONSerialization.data(withJSONObject: arr, options: [.fragmentsAllowed, .sortedKeys]),
               let json = String(data: data, encoding: .utf8) {
                return "\(name): \(json)"
            }
        }
        return name
    }

    /// Renders a toolCall bubble's text. Three forms depending on what's available:
    /// ```
    /// // 1. history / legacy verbose=on — full key: value list from args
    /// ToolCall: <name>
    /// command: <cmd>
    /// timeout: <timeout>
    ///
    /// // 2. modern `item` event with meta — second line shows the action summary
    /// ToolCall: <name>
    /// with: <meta>
    ///
    /// // 3. modern `item` event without meta — name only
    /// ToolCall: <name>
    /// ```
    /// Shared by history and live paths so the format stays consistent.
    /// The modern `item` event does not include the actual command string in its
    /// data (server-side limitation, `AgentItemEventData` schema has no `command`
    /// field), so the bubble falls back to the server-provided `meta` summary.
    func formatToolCallBubbleText(name: String, arguments: AnyCodable?, meta: String? = nil) -> String {
        guard !name.isEmpty else { return "" }
        var callText = "ToolCall: \(name)"
        // 路径1：args 存在（history / legacy verbose=on）—— 走老格式
        if let arguments {
            var argsLines: [String] = []
            let appendArgLine: (String, Any) -> Void = { key, value in
                let valueStr: String
                if key == "command", let str = value as? String {
                    valueStr = str
                } else {
                    valueStr = self.formatAnyCodableValue(value)
                }
                if !valueStr.isEmpty {
                    argsLines.append("\(key): \(valueStr)")
                }
            }
            if let dict = arguments.value as? [String: AnyCodable] {
                for (key, anyCodable) in dict {
                    appendArgLine(key, anyCodable.value)
                }
            } else if let dict = arguments.value as? [String: Any] {
                for (key, value) in dict {
                    appendArgLine(key, value)
                }
            }
            if !argsLines.isEmpty {
                callText += "\n" + argsLines.joined(separator: "\n")
                return callText
            }
        }
        // 路径2：args 为空（现代 item 事件）—— 用 meta 拼第二行
        if let meta, !meta.isEmpty {
            callText += "\nwith: \(meta)"
        }
        return callText
    }

    /// Pretty-prints a tool result payload. JSON values get indented; raw
    /// strings pass through. The MessageBubbleView will further pretty-print
    /// anything it sees for `role == "toolResult"`, so this stays minimal.
    func formatToolResultText(result: Any?) -> String {
        guard let result else { return "" }
        if let str = result as? String { return str }
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .fragmentsAllowed, .sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return String(describing: result)
    }
}
