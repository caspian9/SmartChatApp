import ComposableArchitecture
import Foundation
import OpenClawChatUI
import OSLog
import OpenClawKit
import os

private let logger = Logger(subsystem: "SmartChatApp", category: "NativeChatViewModel")
private let osLog = OSLog(subsystem: "SmartChatApp.NativeChatViewModel", category: "debug")

private let lastSelectedSessionKey = "lastSelectedSessionKey"

@Reducer
struct NativeChatViewModel {
    @ObservableState
    struct State: Equatable {
        var sessions: [OpenClawChatSessionEntry] = []
        var selectedSession: OpenClawChatSessionEntry?
        var messages: [ChatMessage] = []
        var inputText: String = ""
        var isLoading: Bool = false
        var isSending: Bool = false
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
        case updateInputText(String)
        case sendMessage
        case loadHistory
        case loadedCachedHistory([ChatMessage], isRestoring: Bool)
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
            case .loadSessions:
                logger.log("SMAlog: loadSessions called")
                // First load from cache for fast display
                if let cached = SessionCache.load(), !cached.isEmpty {
                    logger.log("SMAlog: Loaded \(cached.count) cached sessions")
                    state.sessions = cached
                    state.isRestoringFromCache = true

                    // Try to restore last selected session first
                    let lastKey = UserDefaults.standard.string(forKey: lastSelectedSessionKey)
                    if let key = lastKey, let lastSession = cached.first(where: { $0.key == key }) {
                        state.selectedSession = lastSession
                        logger.log("SMAlog: restored last selected session: \(String(lastSession.key.prefix(12)))")
                        return .send(.loadHistory)
                    }

                    // Auto-select first session if none selected and no restore
                    if state.selectedSession == nil, let first = cached.first {
                        state.selectedSession = first
                        logger.log("SMAlog: Auto-selected first session: \(String(first.key.prefix(12)))")
                        return .send(.loadHistory)
                    }
                    state.isRestoringFromCache = false
                } else {
                    logger.log("SMAlog: No cached sessions found")
                }
                // Then fetch from network
                state.isLoading = true
                state.error = nil
                return .run { send in
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

            case .loadedSessions(let sessions):
                state.sessions = sessions
                state.isLoading = false
                SessionCache.save(sessions)

                // Try to restore last selected session and update with latest data from network
                let lastKey = UserDefaults.standard.string(forKey: lastSelectedSessionKey)
                if let key = lastKey, let updatedSession = sessions.first(where: { $0.key == key }) {
                    state.selectedSession = updatedSession
                    logger.log("SMAlog: restored and updated session: \(String(updatedSession.key.prefix(12))), tokens: \(updatedSession.totalTokens ?? -1)")
                    // Reload history with updated session info to refresh provider/model/tokens display
                    return .send(.loadHistory)
                }

                // Auto-select first session if none selected
                if state.selectedSession == nil, let first = sessions.first {
                    state.selectedSession = first
                    logger.log("SMAlog: auto-selected first session: \(String(first.key.prefix(12)))")
                    return .send(.loadHistory)
                }
                return .none

            case .selectSession(let session):
                let previousKey = state.selectedSession?.key
                state.selectedSession = session

                // Only clear messages if switching to a different session
                if previousKey != session.key {
                    state.messages = []
                    state.isRestoringFromCache = true
                }

                // Save selected session key
                UserDefaults.standard.set(session.key, forKey: lastSelectedSessionKey)
                logger.log("SMAlog: saved selected session: \(String(session.key.prefix(12)))")
                return .send(.loadHistory)

            case .createSession:
                state.isLoading = true
                return .run { send in
                    Task {
                        do {
                            try await SessionManager.shared.ensureConnected()
                            let sessionKey = try await SessionManager.shared.createSession()
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
                return .none

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
                    stopReason: nil
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
                            // Send cached messages to UI even if network fails
                            await send(.loadedCachedHistory(chatMessages, isRestoring: cachedIsRestoring))
                        }

                        // Then fetch from network
                        do {
                            try await SessionManager.shared.ensureConnected()
                            let transport = await SessionManager.shared.makeTransport(sessionKey: cachedSessionKey)
                            let history = try await transport.requestHistory(sessionKey: cachedSessionKey)

                            // Check if this is still the current session before updating UI
                            guard let currentSession = await SessionManager.shared.getCurrentSessionKey(),
                                  currentSession == cachedSessionKey else {
                                logger.log("SMAlog: Session changed, discarding history for: \(cachedSessionKeyPreview)")
                                return
                            }

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
                            // This prevents flickering when cache and network return the same data
                            if cachedMessages.isEmpty {
                                // No cache was shown, this is first data load
                                await send(.loadedCachedHistory(finalChatMessages, isRestoring: false))
                            } else if finalChatMessages.count > cachedMessages.count {
                                // New messages were added
                                await send(.loadedCachedHistory(finalChatMessages, isRestoring: false))
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
                        logger.log("SMAlog: receiveMessage updated text, new len: \(existingMessage.text.count)")
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
                    logger.log("SMAlog: updated message: \(message.id), text length: \(existingMessage.text.count), state: \(message.state)")
                } else {
                    // New message
                    state.messages.append(message)
                    state.scrollTrigger += 1
                    logger.log("SMAlog: receiveMessage new - id: \(String(message.id.prefix(8))), text len: \(message.text.count), state: \(message.state)")
                }
                // When state is final, message reception is complete - reset sending state
                if message.state == "final" {
                    // Cache the final message
                    if let sessionKey = state.selectedSession?.key,
                       let openClawMsg = createOpenClawChatMessage(from: message) {
                        Task {
                            await MessageCache.shared.appendMessages([openClawMsg], for: sessionKey)
                        }
                    }
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
        return OpenClawChatMessage(
            id: uuid,
            role: chatMessage.role,
            content: [OpenClawChatMessageContent(type: "text", text: chatMessage.text, thinking: nil, thinkingSignature: nil, mimeType: nil, fileName: nil, content: nil, id: nil, name: nil, arguments: nil)],
            timestamp: chatMessage.timestamp.timeIntervalSince1970 * 1000,
            toolCallId: chatMessage.toolCallId,
            toolName: chatMessage.toolName,
            usage: nil,
            stopReason: chatMessage.stopReason
        )
    }

    private func handleTransportEvent(_ event: OpenClawChatTransportEvent, sessionKey: String, send: Send<Action>) async {
        switch event {
        case .agent(let payload):
            logger.log("SMAlog: agent event - stream: \(payload.stream), runId: \(payload.runId)")
            let runId = payload.runId
            let ts = payload.ts ?? 0
            let timestamp = Date(timeIntervalSince1970: Double(ts) / 1000)
            let data = payload.data

            // Extract seq from payload (not from data)
            let seq = payload.seq

            // Extract phase
            let phase = extractString(from: data, key: "phase")
            let startedAtMs = extractDouble(from: data, key: "startedAt")
            let endedAtMs = extractDouble(from: data, key: "endedAt")
            let livenessState = extractString(from: data, key: "livenessState")

            if phase == "start" {
                // Start of a new run
                logger.log("SMAlog: agent start - runId: \(runId), seq: \(seq ?? -1), startedAt: \(startedAtMs)")
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
                    stopReason: nil
                )
                await send(.receiveMessage(message))
                logger.log("SMAlog: agent start - runId: \(runId), seq: \(seq ?? -1), startedAt: \(startedAtMs)")
            } else if phase == "end" {
                // End of run - preserve existing text, just update state and endedAt
                logger.log("SMAlog: agent end - processing data, keys: \(data.keys.map { $0 })")
                for (key, value) in data {
                    logger.log("SMAlog: data key: \(key), value: \(String(describing: value.value))")
                }
                // Extract tokens from nested usage structure
                var inputTokens: Int?
                var outputTokens: Int?
                var cacheRead: Int?
                var cacheWrite: Int?
                // Check for usage dictionary
                if let usage = data["usage"]?.value as? [String: Any] {
                    logger.log("SMAlog: found usage dict: \(String(describing: usage))")
                    if let input = usage["input"] as? Int { inputTokens = input }
                    if let output = usage["output"] as? Int { outputTokens = output }
                    if let cr = usage["cacheRead"] as? Int { cacheRead = cr }
                    if let cw = usage["cacheWrite"] as? Int { cacheWrite = cw }
                } else if let usage = data["usage"] {
                    logger.log("SMAlog: usage found but not dict: \(String(describing: usage.value))")
                } else {
                    logger.log("SMAlog: no usage key found in data")
                }
                // Also check for top-level token fields
                if inputTokens == nil, let input = data["inputTokens"]?.value as? Int { inputTokens = input }
                if outputTokens == nil, let output = data["outputTokens"]?.value as? Int { outputTokens = output }
                if cacheRead == nil, let cr = data["cacheRead"]?.value as? Int { cacheRead = cr }
                if cacheWrite == nil, let cw = data["cacheWrite"]?.value as? Int { cacheWrite = cw }
                logger.log("SMAlog: agent end - tokens: input: \(inputTokens ?? -1), output: \(outputTokens ?? -1), cacheRead: \(cacheRead ?? -1), cacheWrite: \(cacheWrite ?? -1)")
                let message = ChatMessage(
                    id: runId,
                    text: "",  // Will be ignored in receiveMessage - preserve existing
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
                    stopReason: nil
                )
                await send(.receiveMessage(message))
                logger.log("SMAlog: agent end - runId: \(runId), seq: \(seq ?? -1), endedAt: \(endedAtMs)")
                // Reset sending state when run ends
                await send(.setSending(false))
            } else {
                // Assistant stream - update text with delta
                let text = extractString(from: data, key: "text") ?? ""

                logger.log("SMAlog: agent else branch - text len: \(text.count), phase: \(phase ?? "nil")")
                if !text.isEmpty {
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
                        stopReason: nil
                    )
                    await send(.receiveMessage(message))
                    logger.log("SMAlog: agent text - runId: \(runId), seq: \(seq ?? -1), text length: \(text.count)")
                }
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

    private func formatAnyCodableValue(_ value: Any) -> String {
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
}