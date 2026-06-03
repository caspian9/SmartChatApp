import ComposableArchitecture
import Foundation
import OpenClawChatUI
import OSLog
import OpenClawKit
import os

private let logger = Logger(subsystem: "SmartChatApp", category: "NativeChatViewModel")
private let osLog = OSLog(subsystem: "SmartChatApp.NativeChatViewModel", category: "debug")

private func lastSelectedSessionKey(for profileId: UUID) -> String {
    "lastSelectedSession_\(profileId.uuidString)"
}

@Reducer
struct NativeChatViewModel {
    @ObservableState
    struct State: Equatable {
        var selectedProfileId: UUID? = nil
        var sessions: [OpenClawChatSessionEntry] = []
        var selectedSession: OpenClawChatSessionEntry?
        var messages: [ChatMessage] = []
        var inputText: String = ""
        var isLoading: Bool = false
        var isSending: Bool = false
        var isSwitchingGateway: Bool = false
        var error: String?
        var isRestoringFromCache: Bool = false
        var needsScrollToBottom: Bool = false
        var scrollTrigger: Int = 0
        var cacheLoadCounter: Int = 0
    }

    enum Action: Equatable {
        case loadSessions
        case loadedSessions([OpenClawChatSessionEntry])
        case selectSession(OpenClawChatSessionEntry)
        case createSession
        case sessionCreated(String)
        case setSelectedProfile(UUID?)
        case switchProfile(UUID)
        case finishSwitchingGateway
        case updateInputText(String)
        case sendMessage
        case loadHistory
        case loadedCachedHistory([ChatMessage], isRestoring: Bool)
        /// Network-fetched history with the session key it was fetched for.
        /// The reducer verifies `state.selectedSession?.key` still matches
        /// before applying — this replaces the previous
        /// `SessionManager.getCurrentSessionKey()` guard, which was racy
        /// because `makeTransport("")` from `loadSessions` overwrites that
        /// field on a sibling task and caused cache-cleared re-entries to
        /// silently drop the history result.
        case loadedNetworkHistory(sessionKey: String, messages: [ChatMessage])
        case receiveMessage(ChatMessage)
        case setError(String?)
        case setSending(Bool)
        case scrollToBottom
        case setNeedsScrollToBottom(Bool)
        case incrementScrollTrigger
        case appendNewMessages([ChatMessage])
        case loadMoreHistory
        case loadedMoreHistory([ChatMessage], hasMore: Bool)
        case incrementCacheCounter
    }

    @Dependency(\.continuousClock) var clock

    // Static guard to prevent concurrent loadHistory
    private static let loadHistoryLock = NSLock()
    private static var inFlightLoadHistory: String? = nil

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .setSelectedProfile(let profileId):
                if state.selectedProfileId != profileId {
                    state.selectedProfileId = profileId
                }
                return .none

            case .loadSessions:
                logger.log("SMAlog: loadSessions called")
                guard let profileId = state.selectedProfileId else {
                    logger.log("SMAlog: loadSessions skipped - no selected profile")
                    return .none
                }
                let profileIdCapture = profileId
                // First load from cache for fast display
                if let cached = SessionCache.load(for: profileId), !cached.isEmpty {
                    logger.log("SMAlog: Loaded \(cached.count) cached sessions for profile \(profileIdCapture.uuidString.prefix(8))")
                    state.sessions = cached
                    state.isRestoringFromCache = true

                    // Try to restore last selected session first
                    let lastKey = UserDefaults.standard.string(forKey: lastSelectedSessionKey(for: profileIdCapture))
                    if let key = lastKey, let lastSession = cached.first(where: { $0.key == key }) {
                        state.selectedSession = lastSession
                        logger.log("SMAlog: restored last selected session: \(String(lastSession.key.prefix(12)))")
                    } else if state.selectedSession == nil, let first = cached.first {
                        // Auto-select first session if none selected and no restore
                        state.selectedSession = first
                        logger.log("SMAlog: Auto-selected first session: \(String(first.key.prefix(12)))")
                    }
                    state.isRestoringFromCache = false
                } else {
                    logger.log("SMAlog: No cached sessions found for profile \(profileIdCapture.uuidString.prefix(8))")
                }
                // Then fetch from network (even on cache hit) so the
                // selected session's totals/timestamps reflect the latest
                // server state. The cache is for fast display only; without
                // this, re-entering NativeChat would show stale model/tokens.
                state.isLoading = true
                state.error = nil
                return .merge(
                    .send(.loadHistory),
                    .run { send in
                        Task {
                            do {
                                try await SessionManager.shared.ensureConnected()
                                try await Task.sleep(for: .milliseconds(100))
                                let transport = await SessionManager.shared.makeTransport(sessionKey: "")
                                let response = try await transport.listSessions(limit: 50)
                                logger.log("SMAlog: Loaded \(response.sessions.count) sessions")
                                await send(.loadedSessions(response.sessions))
                            } catch {
                                logger.log("SMAlog: Load sessions error: \(error.localizedDescription)")
                                try? await Task.sleep(for: .milliseconds(500))
                                do {
                                    try await SessionManager.shared.ensureConnected()
                                    let transport = await SessionManager.shared.makeTransport(sessionKey: "")
                                    let response = try await transport.listSessions(limit: 50)
                                    await send(.loadedSessions(response.sessions))
                                } catch {
                                    logger.log("SMAlog: Load sessions retry failed: \(error.localizedDescription)")
                                    await send(.loadedSessions([]))
                                }
                            }
                        }
                    }
                )

            case .loadedSessions(let sessions):
                let prevSelectedKey = state.selectedSession?.key
                let prevSelectedModel = state.selectedSession?.model
                let prevSelectedTokens = state.selectedSession?.totalTokens
                let prevSelectedUpdatedAt = state.selectedSession?.updatedAt
                logger.log("SMAlog: [loadedSessions DIAG] prev selected: key=\(String(prevSelectedKey?.prefix(12) ?? "nil")) model=\(prevSelectedModel ?? "nil") tokens=\(prevSelectedTokens ?? -1) updatedAt=\(prevSelectedUpdatedAt ?? -1)")
                logger.log("SMAlog: [loadedSessions DIAG] incoming: count=\(sessions.count) first.model=\(sessions.first?.model ?? "nil") first.tokens=\(sessions.first?.totalTokens ?? -1) first.updatedAt=\(sessions.first?.updatedAt ?? -1)")

                state.sessions = sessions
                state.isLoading = false
                if let profileId = state.selectedProfileId {
                    SessionCache.save(sessions, for: profileId)
                }

                // Try to restore last selected session and update with latest data from network
                if let profileId = state.selectedProfileId,
                   let key = UserDefaults.standard.string(forKey: lastSelectedSessionKey(for: profileId)),
                   let updatedSession = sessions.first(where: { $0.key == key }) {
                    state.selectedSession = updatedSession
                    let sameKey = updatedSession.key == prevSelectedKey
                    let sameModel = updatedSession.model == prevSelectedModel
                    let sameTokens = updatedSession.totalTokens == prevSelectedTokens
                    let sameUpdatedAt = updatedSession.updatedAt == prevSelectedUpdatedAt
                    logger.log("SMAlog: [loadedSessions DIAG] branch=lastKeyMatch key=\(String(updatedSession.key.prefix(12))) newModel=\(updatedSession.model ?? "nil") newTokens=\(updatedSession.totalTokens ?? -1) newUpdatedAt=\(updatedSession.updatedAt ?? -1) sameKey=\(sameKey ? 1 : 0) sameModel=\(sameModel ? 1 : 0) sameTokens=\(sameTokens ? 1 : 0) sameUpdatedAt=\(sameUpdatedAt ? 1 : 0)")
                    // Reload history with updated session info to refresh provider/model/tokens display
                    return .send(.loadHistory)
                }

                // Auto-select first session if none selected
                if state.selectedSession == nil, let first = sessions.first {
                    state.selectedSession = first
                    logger.log("SMAlog: [loadedSessions DIAG] branch=autoFirst key=\(String(first.key.prefix(12)))")
                    return .send(.loadHistory)
                }
                // No branch matched: a selectedSession was set from cache but lastKey
                // didn't match (or no lastKey). Refresh the selectedSession in place
                // from the network response so the header reflects the latest
                // provider/model/tokens, even when the user is just re-entering.
                if let currentKey = prevSelectedKey,
                   let refreshed = sessions.first(where: { $0.key == currentKey }) {
                    state.selectedSession = refreshed
                    logger.log("SMAlog: [loadedSessions DIAG] branch=inPlaceRefresh key=\(String(currentKey.prefix(12))) newModel=\(refreshed.model ?? "nil") newTokens=\(refreshed.totalTokens ?? -1) newUpdatedAt=\(refreshed.updatedAt ?? -1)")
                } else {
                    logger.log("SMAlog: [loadedSessions DIAG] branch=noMatch prevKey=\(String(prevSelectedKey?.prefix(12) ?? "nil")) sessionsCount=\(sessions.count)")
                }
                return .none

            case .selectSession(let session):
                let previousKey = state.selectedSession?.key
                // Pick the freshest instance from state.sessions (rather than
                // the one passed in, which may be from a stale dropdown).
                // This keeps the second-line provider/model/totalTokens/updatedAt
                // in sync with whatever the most recent session-list fetch
                // produced.
                if let fresh = state.sessions.first(where: { $0.key == session.key }) {
                    state.selectedSession = fresh
                } else {
                    state.selectedSession = session
                }

                // Only clear messages if switching to a different session
                let didSwitch = previousKey != session.key
                if didSwitch {
                    state.messages = []
                    state.isRestoringFromCache = true
                }

                // Save selected session key (per profile)
                if let profileId = state.selectedProfileId {
                    UserDefaults.standard.set(session.key, forKey: lastSelectedSessionKey(for: profileId))
                }
                logger.log("SMAlog: saved selected session: \(String(session.key.prefix(12)))")
                if didSwitch {
                    return .merge(
                        .run { _ in
                            await MainActor.run {
                                MarkdownStreamManager.shared.releaseAll()
                            }
                        },
                        .send(.loadSessions),
                        .send(.loadHistory)
                    )
                }
                return .send(.loadHistory)

            case .switchProfile(let newProfileId):
                if newProfileId == state.selectedProfileId {
                    return .none
                }
                let previousProfileId = state.selectedProfileId
                state.selectedProfileId = newProfileId
                state.selectedSession = nil
                state.messages = []
                state.isSwitchingGateway = true
                state.error = nil
                logger.log("SMAlog: switchProfile from \(previousProfileId?.uuidString.prefix(8) ?? "nil") to \(newProfileId.uuidString.prefix(8))")

                // Load cache immediately for fast display, consistent with loadSessions flow
                var hasCache = false
                if let cached = SessionCache.load(for: newProfileId), !cached.isEmpty {
                    state.sessions = cached
                    state.isRestoringFromCache = true
                    let lastKey = UserDefaults.standard.string(forKey: lastSelectedSessionKey(for: newProfileId))
                    if let key = lastKey, let lastSession = cached.first(where: { $0.key == key }) {
                        state.selectedSession = lastSession
                    } else if let first = cached.first {
                        state.selectedSession = first
                    }
                    state.isRestoringFromCache = false
                    hasCache = true
                } else {
                    state.sessions = []
                    state.isRestoringFromCache = false
                    state.isLoading = true
                }

                let profileIdCapture = newProfileId
                let hadCache = hasCache
                return .run { send in
                    Task {
                        // Release any active stream holders from the previous profile/session
                        await MainActor.run {
                            MarkdownStreamManager.shared.releaseAll()
                        }
                        // If we have a cached session selected, kick off history load
                        // so the chat panel isn't empty while we wait for the network switch
                        if hadCache {
                            await send(.loadHistory)
                        }

                        let profile = await MainActor.run {
                            ProfileManager.shared.getProfile(id: profileIdCapture)
                        }
                        guard let profile = profile else {
                            logger.log("SMAlog: switchProfile - profile not found")
                            await send(.setError("Profile not found"))
                            return
                        }
                        await ProfileManager.shared.switchToProfile(profile)
                        logger.log("SMAlog: switchProfile - active profile switched, fetching network sessions")

                        // Fetch from network now that the new gateway is connected
                        do {
                            try await SessionManager.shared.ensureConnected()
                            try await Task.sleep(for: .milliseconds(100))
                            let transport = await SessionManager.shared.makeTransport(sessionKey: "")
                            let response = try await transport.listSessions(limit: 50)
                            await send(.loadedSessions(response.sessions))
                        } catch {
                            logger.log("SMAlog: Load sessions after switch error: \(error.localizedDescription)")
                            // Cache (if any) is already shown, so just clear the loading flag
                            await send(.setError(error.localizedDescription))
                        }
                        await send(.finishSwitchingGateway)
                    }
                }

            case .finishSwitchingGateway:
                state.isSwitchingGateway = false
                state.isLoading = false
                return .none

            case .createSession:
                state.isLoading = true
                // If the user has a session selected, scope the new session
                // to that session's agent instead of the gateway's default
                // agent. Keys have the form `agent:<agentId>:<rest>`, so
                // segment index 1 carries the agent id. If the key doesn't
                // match the expected shape (e.g. legacy "global"/"unknown"
                // sentinels), fall through to `nil` and let the gateway
                // pick its default.
                let selectedAgentId: String? = {
                    guard let key = state.selectedSession?.key else { return nil }
                    let parts = key.split(separator: ":")
                    guard parts.count >= 2 else { return nil }
                    let candidate = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                    return candidate.isEmpty ? nil : candidate
                }()
                logger.log("SMAlog: createSession - using selected agentId: \(selectedAgentId ?? "<default>")")
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
                    logger.log("SMAlog: createSession - requesting custom key: \(customKey)")
                }

                return .run { send in
                    Task {
                        do {
                            try await SessionManager.shared.ensureConnected()
                            let sessionKey = try await SessionManager.shared.createSession(
                                agentId: agentIdCapture,
                                customKey: customKey
                            )
                            logger.log("SMAlog: Created session: \(String(sessionKey))")
                            await send(.sessionCreated(sessionKey))
                            await send(.loadSessions)
                        } catch {
                            logger.log("SMAlog: Create session error: \(error.localizedDescription)")
                            await send(.setError(error.localizedDescription))
                        }
                    }
                }

            case .sessionCreated(let sessionKey):
                logger.log("SMAlog: Session created callback: \(sessionKey)")
                state.isLoading = false
                // Build a minimal entry from the new key. The next loadSessions
                // (already dispatched by .createSession's run block) will
                // replace this with the full entry (model, tokens, etc.) via
                // .loadedSessions' in-place refresh on matching key.
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
                return .send(.selectSession(newEntry))

            case .updateInputText(let text):
                state.inputText = text
                return .none

            case .sendMessage:
                guard !state.inputText.isEmpty else {
                    return .none
                }
                guard let session = state.selectedSession else {
                    return .none
                }
                state.isSending = true
                let text = state.inputText
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
                state.messages.append(message)
                state.inputText = ""
                // Cache user message
                Task {
                    if let msg = createOpenClawChatMessage(from: message) {
                        await MessageCache.shared.appendMessages([msg], for: sessionKey)
                    }
                }
                // sessionKey already captured above, use it directly
                return .run { send in
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
                                                await handleTransportEvent(evt, sessionKey: sessionKey, send: send)
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
                            logger.log("SMAlog: Message sent, waiting for response...")
                        } catch {
                            logger.log("SMAlog: Send message error: \(error.localizedDescription)")
                            await send(.setError(error.localizedDescription))
                            await send(.setSending(false))
                        }
                    }
                }

            case .loadHistory:
                guard let session = state.selectedSession else {
                    return .none
                }
                let sessionKey = session.key
                let sessionKeyPreview = String(sessionKey.prefix(8))
                // Capture isRestoring BEFORE resetting
                let isRestoring = state.isRestoringFromCache
                state.isRestoringFromCache = false

                let cachedSessionKey = sessionKey
                let cachedSessionKeyPreview = sessionKeyPreview
                let cachedIsRestoring = isRestoring

                // Acquire lock BEFORE creating .run closure to prevent concurrent Tasks
                Self.loadHistoryLock.lock()
                let alreadyInProgress = Self.inFlightLoadHistory == cachedSessionKey
                if alreadyInProgress {
                    Self.loadHistoryLock.unlock()
                    logger.log("SMAlog: [loadHistory] already in progress for \(cachedSessionKeyPreview)")
                } else {
                    Self.inFlightLoadHistory = cachedSessionKey
                    Self.loadHistoryLock.unlock()
                }

                let taskIdStr = String(UUID().uuidString.prefix(8))

                return .run { [cachedSessionKey, cachedSessionKeyPreview, cachedIsRestoring, taskIdStr] send in
                    Task {
                        logger.log("SMAlog: [\(taskIdStr)] loadHistory Task started, sessionKey: \(cachedSessionKeyPreview)")
                        defer {
                            Self.loadHistoryLock.lock()
                            if Self.inFlightLoadHistory == cachedSessionKey {
                                Self.inFlightLoadHistory = nil
                            }
                            Self.loadHistoryLock.unlock()
                        }
                        // Load cache first and send to UI immediately
                        let cachedMessages = await MessageCache.shared.getMessages(for: cachedSessionKey)
                        logger.log("SMAlog: cache returned \(cachedMessages.count) messages, sessionKey: \(cachedSessionKeyPreview)")
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
                            logger.log("SMAlog: Loaded \(chatMessages.count) cached messages for session: \(cachedSessionKeyPreview), isRestoring: \(cachedIsRestoring)")
                            // Precompute collapse and markdown states BEFORE sending to UI
                            await MainActor.run {
                                MarkdownCache.shared.precomputeForMessages(chatMessages)
                                CollapseStateCache.shared.precompute(for: chatMessages)
                            }
                            // Send cached messages to UI
                            await send(.loadedCachedHistory(chatMessages, isRestoring: cachedIsRestoring))
                        }

                        // Then fetch from network
                        do {
                            try await SessionManager.shared.ensureConnected()
                            let transport = await SessionManager.shared.makeTransport(sessionKey: cachedSessionKey)
                            let history = try await transport.requestHistory(sessionKey: cachedSessionKey)

                            // Staleness check moved to the reducer: this run
                            // dispatches `.loadedNetworkHistory` carrying the
                            // session key, and the reducer verifies
                            // `state.selectedSession?.key` still matches
                            // before applying. The old check used
                            // `SessionManager.getCurrentSessionKey()`, which
                            // is overwritten by `loadSessions`'s concurrent
                            // `makeTransport("")` and caused the history to
                            // be silently dropped when the message cache was
                            // empty (so this is the only path that can
                            // repopulate the UI).

                            let messageCount = history.messages?.count ?? 0
                            logger.log("SMAlog: Loaded \(messageCount) history messages for session: \(cachedSessionKeyPreview)")
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
                                        hasToolCall = true
                                        // Format toolCall info as text
                                        var callText = "ToolCall: \(name)"
                                        if let arguments = contentItem.arguments {
                                            // Format all key-value pairs from arguments
                                            var argsLines: [String] = []
                                            if let dict = arguments.value as? [String: AnyCodable] {
                                                for (key, anyCodable) in dict {
                                                    let valueStr: String
                                                    if key == "command", let str = anyCodable.value as? String {
                                                        valueStr = str
                                                    } else {
                                                        valueStr = formatAnyCodableValue(anyCodable.value)
                                                    }
                                                    if !valueStr.isEmpty {
                                                        argsLines.append("\(key): \(valueStr)")
                                                    }
                                                }
                                            } else if let dict = arguments.value as? [String: Any] {
                                                for (key, value) in dict {
                                                    let valueStr: String
                                                    if key == "command", let str = value as? String {
                                                        valueStr = str
                                                    } else {
                                                        valueStr = formatAnyCodableValue(value)
                                                    }
                                                    if !valueStr.isEmpty {
                                                        argsLines.append("\(key): \(valueStr)")
                                                    }
                                                }
                                            }
                                            if !argsLines.isEmpty {
                                                callText += "\n" + argsLines.joined(separator: "\n")
                                            }
                                        }
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
                                os_log("SMAlog: history msg[%{public}d] contentItems=%{public}d text_len=%{private}d role=%{public}s", log: osLog, type: .debug, index, msg.content.count, text.count, role)
                                if text.isEmpty {
                                    os_log("SMAlog: history msg[%{public}d] skipped - empty text, content: %{public}s", log: osLog, type: .debug, index, String(describing: msg.content))
                                    return nil
                                }
                                let ts = msg.timestamp ?? 0
                                let msgId = msg.id.uuidString
                                let textPreview = String(text.prefix(100))
                                os_log("SMAlog: history msg[%{public}d] role=%{public}s toolName=%{public}s toolCallId=%{public}s text_len=%{public}s text_preview=%{public}s", log: osLog, type: .debug, index, role, msg.toolName ?? "nil", msg.toolCallId ?? "nil", "\(text.count)", textPreview)
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
                            logger.log("SMAlog: chatMessages count=\(chatMessages.count)")
                            // Cache the fetched messages (setMessages handles deduplication)
                            let openClawMessages = chatMessages.compactMap { createOpenClawChatMessage(from: $0) }
                            logger.log("SMAlog: openClawMessages count=\(openClawMessages.count)")
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
                            logger.log("SMAlog: [\(taskIdStr)] finalCachedMessages from cache: \(finalChatMessages.count)")

                            // Only update UI if we didn't already show cache, or if there are new messages
                            // This prevents flickering when cache and network return the same data.
                            // The reducer-side check in `loadedNetworkHistory` handles the
                            // "user switched sessions" case so we don't need a
                            // `getCurrentSessionKey()` guard here.
                            if cachedMessages.isEmpty {
                                // No cache was shown, this is first data load
                                await send(.loadedNetworkHistory(sessionKey: cachedSessionKey, messages: finalChatMessages))
                            } else if finalChatMessages.count > cachedMessages.count {
                                // New messages were added
                                await send(.loadedNetworkHistory(sessionKey: cachedSessionKey, messages: finalChatMessages))
                            } else {
                                logger.log("SMAlog: [\(taskIdStr)] Network returned same messages as cache, skipping UI update")
                            }
                        } catch {
                            logger.log("SMAlog: Load history error: \(error.localizedDescription)")
                        }
                    }
                }

            case .loadedCachedHistory(let messages, let isRestoring):
                logger.log("SMAlog: loadedCachedHistory setting \(messages.count) messages, isRestoring: \(isRestoring)")
                state.messages = messages
                state.scrollTrigger += 1
                state.cacheLoadCounter += 1
                // Precompute markdown and collapse states synchronously on main actor, then force refresh
                return .run { [messages] send in
                    Task {
                        await MainActor.run {
                            MarkdownCache.shared.precomputeForMessages(messages)
                            CollapseStateCache.shared.precompute(for: messages)
                        }
                        // Force view refresh after cache is populated
                        await send(.incrementCacheCounter)
                    }
                }

            case .loadedNetworkHistory(let sessionKey, let messages):
                // Drop the result if the user has switched to a different
                // session since this fetch started. Comparing against
                // `state.selectedSession?.key` (the only source of truth
                // for what the user is looking at) avoids the race the
                // old `SessionManager.getCurrentSessionKey()` guard had
                // with the concurrent `makeTransport("")` from
                // `loadSessions`.
                let currentKey = state.selectedSession?.key
                if currentKey != sessionKey {
                    let currentKeyLog = currentKey ?? "nil"
                    logger.log("SMAlog: loadedNetworkHistory dropped: session \(String(sessionKey.prefix(8))) is no longer selected (current: \(String(currentKeyLog.prefix(8))))")
                    return .none
                }
                logger.log("SMAlog: loadedNetworkHistory applying \(messages.count) messages for session: \(String(sessionKey.prefix(8)))")
                state.messages = messages
                state.scrollTrigger += 1
                state.cacheLoadCounter += 1
                return .run { [messages] send in
                    Task {
                        await MainActor.run {
                            MarkdownCache.shared.precomputeForMessages(messages)
                            CollapseStateCache.shared.precompute(for: messages)
                        }
                        await send(.incrementCacheCounter)
                    }
                }

            case .incrementCacheCounter:
                state.cacheLoadCounter += 1
                return .none

            case .appendNewMessages(let newMessages):
                if newMessages.isEmpty {
                    logger.log("SMAlog: appendNewMessages - no new messages")
                    return .none
                }
                logger.log("SMAlog: appendNewMessages appending \(newMessages.count) messages")
                state.messages.append(contentsOf: newMessages)
                state.needsScrollToBottom = true
                return .none

            case .receiveMessage(let message):
                // Check if this is an update to existing message or new message
                if let existingIndex = state.messages.firstIndex(where: { $0.id == message.id }) {
                    // Update existing message (streaming text update)
                    var existingMessage = state.messages[existingIndex]
                    logger.log("SMAlog: receiveMessage update - id: \(String(message.id.prefix(8))), existingIndex: \(existingIndex), newText len: \(message.text.count), existingText len: \(existingMessage.text.count), state: \(message.state)")
                    // Only update text if new text is not empty (preserve content on end phase)
                    if !message.text.isEmpty {
                        existingMessage.text = message.text
                        logger.log("SMAlog: receiveMessage updated text, new len: \(existingMessage.text.count), prev state: \(existingMessage.state), new state: \(message.state)")
                    } else {
                        logger.log("SMAlog: receiveMessage SKIPPED text update (empty), prev state: \(existingMessage.state), new state: \(message.state)")
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
                    state.messages[existingIndex] = existingMessage
                    state.scrollTrigger += 1
                    logger.log("SMAlog: updated message: \(message.id), text length: \(existingMessage.text.count), FINAL state: \(existingMessage.state)")
                } else {
                    // Fallback: id mismatch between streaming (id=runId) and cached
                    // (id=server-id) can cause a second copy of the same logical
                    // message to be appended. Match by role+text+timestamp and
                    // update in place so the display doesn't accumulate duplicates
                    // while the cache dedup (role|text|timestamp|usage) keeps
                    // the disk count stable.
                    let similarIndex = state.messages.firstIndex { existing in
                        existing.role == message.role &&
                        existing.text == message.text &&
                        abs(existing.timestamp.timeIntervalSince(message.timestamp)) < 60.0
                    }
                    if let similarIndex = similarIndex {
                        var existingMessage = state.messages[similarIndex]
                        os_log("SMAlog: receiveMessage similar-match - newId=%{public}s existingId=%{public}s idx=%{public}d state=%{public}s", log: osLog, type: .debug, String(message.id.prefix(8)), String(existingMessage.id.prefix(8)), similarIndex, message.state)
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
                        state.messages[similarIndex] = existingMessage
                        state.scrollTrigger += 1
                    } else {
                        // New message
                        state.messages.append(message)
                        state.scrollTrigger += 1
                        logger.log("SMAlog: receiveMessage new - id: \(String(message.id.prefix(8))), text len: \(message.text.count), state: \(message.state)")
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
                    return .send(.setSending(false))
                }
                return .none

            case .setError(let error):
                state.error = error
                state.isLoading = false
                state.isSending = false
                return .none

            case .setSending(let value):
                state.isSending = value
                return .none

            case .scrollToBottom:
                state.needsScrollToBottom = true
                return .none

            case .setNeedsScrollToBottom(let needsScroll):
                state.needsScrollToBottom = needsScroll
                return .none

            case .incrementScrollTrigger:
                state.scrollTrigger += 1
                return .none

            case .loadMoreHistory, .loadedMoreHistory:
                return .none
            }
        }
    }

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

    private func handleTransportEvent(_ event: OpenClawChatTransportEvent, sessionKey: String, send: Send<Action>) async {
        switch event {
        case .agent(let payload):
            logger.log("SMAlog: agent event - stream: \(payload.stream), runId: \(payload.runId), data keys: \(payload.data.keys.map { $0 })")
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
                    logger.log("SMAlog: agent lifecycle start - runId: \(runId), seq: \(seq ?? -1), startedAt: \(startedAtMs)")
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
                    await send(.receiveMessage(message))
                } else if phase == "end" {
                    // End of run. The previous implementation keyed off phase=end
                    // for every event, which caused tool end phases to prematurely
                    // finalize the run and reset sending. With stream-based dispatch,
                    // only the actual lifecycle end reaches here, so the run-level
                    // state (tokens, endedAt, setSending(false)) is correctly tied
                    // to the real terminal signal.
                    logger.log("SMAlog: agent lifecycle end - runId: \(runId), data keys: \(data.keys.map { $0 })")
                    var inputTokens: Int?
                    var outputTokens: Int?
                    var cacheRead: Int?
                    var cacheWrite: Int?
                    if let usage = data["usage"]?.value as? [String: Any] {
                        logger.log("SMAlog: found usage dict: \(String(describing: usage))")
                        if let input = usage["input"] as? Int { inputTokens = input }
                        if let output = usage["output"] as? Int { outputTokens = output }
                        if let cr = usage["cacheRead"] as? Int { cacheRead = cr }
                        if let cw = usage["cacheWrite"] as? Int { cacheWrite = cw }
                    }
                    if inputTokens == nil, let input = data["inputTokens"]?.value as? Int { inputTokens = input }
                    if outputTokens == nil, let output = data["outputTokens"]?.value as? Int { outputTokens = output }
                    if cacheRead == nil, let cr = data["cacheRead"]?.value as? Int { cacheRead = cr }
                    if cacheWrite == nil, let cw = data["cacheWrite"]?.value as? Int { cacheWrite = cw }
                    logger.log("SMAlog: agent lifecycle end - tokens: input: \(inputTokens ?? -1), output: \(outputTokens ?? -1), cacheRead: \(cacheRead ?? -1), cacheWrite: \(cacheWrite ?? -1)")
                    // Flush the markdown stream buffer and read the full accumulated
                    // text so it can be persisted. Deltas carry the full cumulative
                    // string per chunk; MarkdownViewTextKit holds the real body until
                    // end() releases it. Without this flush, the cache write below
                    // captures an empty body and the assistant reply is lost.
                    let fullText: String = await MainActor.run {
                        MarkdownStreamManager.shared.end(messageId: runId)
                        return MarkdownStreamManager.shared.currentText(for: runId) ?? ""
                    }
                    logger.log("SMAlog: agent lifecycle end - fullText len: \(fullText.count) for runId: \(runId)")
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
                    await send(.receiveMessage(message))
                    // Holder no longer needed — SwiftUI flips to the static
                    // MarkdownCardView once state becomes "final", so the streaming
                    // view is dismantled. Release to bound memory across many turns.
                    await MainActor.run {
                        MarkdownStreamManager.shared.release(messageId: runId)
                    }
                    // Only the real terminal signal resets the sending flag.
                    await send(.setSending(false))
                }
            case "assistant":
                // Server sends the FULL cumulative text on every chunk (see
                // OpenClawChatUI/ChatViewModel.handleAgentEvent for the reference
                // behavior). Hand the cumulative string to the holder; it computes
                // the actual incremental suffix and feeds only that to the stream.
                // Without this we render `ABC` + `ABCDE` + `ABCDEF` as
                // `ABCABCDEABCDEF`. The placeholder at id=runId absorbs this update.
                let text = extractString(from: data, key: "text") ?? ""
                logger.log("SMAlog: agent assistant delta - text len: \(text.count)")
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
                await send(.receiveMessage(message))
            case "thinking":
                // Thinking deltas are emitted as a separate stream from the
                // assistant text — they don't share an id with the assistant
                // placeholder. Use a synthetic id so the message dedups against
                // itself across deltas and renders as a thinking bubble.
                let text = extractString(from: data, key: "text") ?? ""
                logger.log("SMAlog: agent thinking delta - text len: \(text.count)")
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
                await send(.receiveMessage(message))
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
                    logger.log("SMAlog: agent tool event missing toolCallId, skipping. data keys: \(data.keys.map { $0 })")
                    return
                }
                let toolName = extractString(from: data, key: "name") ?? ""
                if phase == "start" {
                    let text = formatToolCallText(name: toolName, args: data["args"]?.value)
                    logger.log("SMAlog: agent tool start - tool: \(toolName), callId: \(toolCallId)")
                    let message = ChatMessage(
                        id: "\(runId):tool:\(toolCallId)",
                        text: text,
                        timestamp: timestamp,
                        role: "toolCall",
                        state: "final",
                        runId: runId,
                        seq: nil,
                        startedAt: timestamp,
                        endedAt: nil,
                        livenessState: nil,
                        toolCallId: toolCallId,
                        toolName: toolName,
                        stopReason: nil,
                        isFresh: true
                    )
                    await send(.receiveMessage(message))
                } else if phase == "update" {
                    // Intermediate state. Refresh the toolCall bubble with the
                    // latest args/progress so the user sees the tool is alive.
                    let text = formatToolCallText(name: toolName, args: data["args"]?.value)
                    logger.log("SMAlog: agent tool update - tool: \(toolName), callId: \(toolCallId), text len: \(text.count)")
                    let message = ChatMessage(
                        id: "\(runId):tool:\(toolCallId)",
                        text: text,
                        timestamp: timestamp,
                        role: "toolCall",
                        state: "final",
                        runId: runId,
                        seq: nil,
                        startedAt: nil,
                        endedAt: nil,
                        livenessState: nil,
                        toolCallId: toolCallId,
                        toolName: toolName,
                        stopReason: nil,
                        isFresh: true
                    )
                    await send(.receiveMessage(message))
                } else if phase == "result" {
                    let resultValue = data["result"]?.value
                    let text = formatToolResultText(result: resultValue)
                    let isError = (data["isError"]?.value as? Bool) ?? false
                    logger.log("SMAlog: agent tool result - tool: \(toolName), callId: \(toolCallId), isError: \(isError), text len: \(text.count)")
                    let message = ChatMessage(
                        id: "\(runId):toolResult:\(toolCallId)",
                        text: text,
                        timestamp: timestamp,
                        role: "toolResult",
                        state: "final",
                        runId: runId,
                        seq: nil,
                        startedAt: nil,
                        endedAt: timestamp,
                        livenessState: nil,
                        toolCallId: toolCallId,
                        toolName: toolName,
                        stopReason: isError ? "error" : nil,
                        isFresh: true
                    )
                    await send(.receiveMessage(message))
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
                    logger.log("SMAlog: agent item event missing itemId, skipping. keys: \(data.keys.map { $0 })")
                    return
                }
                let itemPhase = extractString(from: data, key: "phase")
                let kind = extractString(from: data, key: "kind") ?? "tool"
                let name = extractString(from: data, key: "name") ?? ""
                let title = extractString(from: data, key: "title") ?? name
                let status = extractString(from: data, key: "status")
                let progressText = extractString(from: data, key: "progressText")
                let summary = extractString(from: data, key: "summary")
                let errorText = extractString(from: data, key: "error")
                let toolCallId = extractString(from: data, key: "toolCallId")
                logger.log("SMAlog: agent item - kind: \(kind), phase: \(itemPhase ?? "nil"), itemId: \(itemId), status: \(status ?? "?")")
                // Build text representation for the toolCall bubble. Title
                // carries the human-readable action; progressText is appended
                // during running state so the user sees the tool is alive.
                var callText = title
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
                            seq: nil,
                            startedAt: nil,
                            endedAt: timestamp,
                            livenessState: nil,
                            toolCallId: toolCallId,
                            toolName: name,
                            stopReason: (errorText != nil) ? "error" : nil,
                            isFresh: true
                        )
                        await send(.receiveMessage(message))
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
                    seq: nil,
                    startedAt: nil,
                    endedAt: itemPhase == "end" ? timestamp : nil,
                    livenessState: nil,
                    toolCallId: toolCallId,
                    toolName: name,
                    stopReason: nil,
                    isFresh: true
                )
                await send(.receiveMessage(message))
            case "command_output":
                // Per-item command output stream. For exec/bash tools the
                // result body arrives here in `output` (incremental on
                // `phase: "delta"`, final on `phase: "end"`). Accumulate into
                // a toolResult bubble keyed by itemId.
                guard let itemId = extractString(from: data, key: "itemId") else {
                    logger.log("SMAlog: agent command_output missing itemId, skipping. keys: \(data.keys.map { $0 })")
                    return
                }
                let outputPhase = extractString(from: data, key: "phase")
                let output = extractString(from: data, key: "output") ?? ""
                let toolName = extractString(from: data, key: "name") ?? ""
                let exitCode = extractInt(from: data, key: "exitCode")
                let durationMs = extractInt(from: data, key: "durationMs")
                logger.log("SMAlog: agent command_output - phase: \(outputPhase ?? "nil"), itemId: \(itemId), output len: \(output.count), exitCode: \(exitCode.map(String.init) ?? "nil")")
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
                    seq: nil,
                    startedAt: nil,
                    endedAt: outputPhase == "end" ? timestamp : nil,
                    livenessState: nil,
                    toolCallId: nil,
                    toolName: toolName,
                    stopReason: exitCode.map { $0 != 0 ? "error" : nil } ?? nil,
                    isFresh: true
                )
                await send(.receiveMessage(message))
            default:
                // plan, approval, patch, compaction, error — not yet surfaced.
                logger.log("SMAlog: agent unhandled stream: \(payload.stream), data keys: \(data.keys.map { $0 })")
            }

        case .chat, .sessionMessage, .tick, .seqGap, .health:
            // Ignored - only agent events are used for messages
            break
        }
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