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
        case loadedHistory([ChatMessage])
        case loadedCachedHistory([ChatMessage], isRestoring: Bool)
        case receiveMessage(ChatMessage)
        case setError(String?)
        case setSending(Bool)
        case scrollToBottom
        case setNeedsScrollToBottom(Bool)
        case incrementScrollTrigger
    }

    @Dependency(\.continuousClock) var clock

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

                return .run { send in
                    Task {
                        logger.log("SMAlog: loadHistory Task started for session: \(sessionKeyPreview)")
                        // Always load cache first (messages already cleared in selectSession when switching)
                        let cachedMessages = await MessageCache.shared.getMessages(for: sessionKey)
                        logger.log("SMAlog: cache returned \(cachedMessages.count) messages for session: \(sessionKeyPreview)")
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
                            logger.log("SMAlog: Loaded \(chatMessages.count) cached messages for session: \(sessionKeyPreview), isRestoring: \(isRestoring)")
                            await send(.loadedCachedHistory(chatMessages, isRestoring: isRestoring))
                        }

                        // Then fetch from network
                        do {
                            try await SessionManager.shared.ensureConnected()
                            let transport = await SessionManager.shared.makeTransport(sessionKey: sessionKey)
                            let history = try await transport.requestHistory(sessionKey: sessionKey)

                            // Check if this is still the current session before updating UI
                            guard let currentSession = await SessionManager.shared.getCurrentSessionKey(),
                                  currentSession == sessionKey else {
                                logger.log("SMAlog: Session changed, discarding history for: \(sessionKeyPreview)")
                                return
                            }

                            let messageCount = history.messages?.count ?? 0
                            logger.log("SMAlog: Loaded \(messageCount) history messages for session: \(sessionKeyPreview)")
                            let chatMessages: [ChatMessage] = (history.messages ?? []).enumerated().compactMap { index, anyCodable -> ChatMessage? in
                                guard let msg = try? JSONDecoder().decode(OpenClawChatMessage.self, from: JSONEncoder().encode(anyCodable)) else {
                                    print("SMAlog: message[\(index)] failed to decode as OpenClawChatMessage, raw: \(String(describing: anyCodable))")
                                    return nil
                                }
                                var text = ""
                                for contentItem in msg.content {
                                    if let t = contentItem.text, !t.isEmpty {
                                        text = t.trimmingCharacters(in: .whitespacesAndNewlines)
                                        break
                                    }
                                }
                                os_log("SMAlog: history msg[%{public}d] contentItems=%{public}d text_len=%{private}d", log: osLog, type: .debug, index, msg.content.count, text.count)
                                if text.isEmpty {
                                    os_log("SMAlog: history msg[%{public}d] skipped - empty text, content: %{public}s", log: osLog, type: .debug, index, String(describing: msg.content))
                                    return nil
                                }
                                let ts = msg.timestamp ?? 0
                                let msgId = msg.id.uuidString
                                let textPreview = String(text.prefix(100))
                                os_log("SMAlog: history msg[%{public}d] role=%{public}s toolName=%{public}s toolCallId=%{public}s text_len=%{public}s text_preview=%{public}s", log: osLog, type: .debug, index, msg.role, msg.toolName ?? "nil", msg.toolCallId ?? "nil", "\(text.count)", textPreview)
                                return ChatMessage(
                                    id: msgId,
                                    text: text,
                                    timestamp: Date(timeIntervalSince1970: ts / 1000),
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
                            logger.log("SMAlog: chatMessages count: \(chatMessages.count)")
                            // Cache the fetched messages
                            let openClawMessages = chatMessages.compactMap { createOpenClawChatMessage(from: $0) }
                            await MessageCache.shared.setMessages(openClawMessages, for: sessionKey)
                            await send(.loadedHistory(chatMessages))
                        } catch {
                            logger.log("SMAlog: Load history error: \(error.localizedDescription)")
                        }
                    }
                }

            case .loadedCachedHistory(let messages, let isRestoring):
                logger.log("SMAlog: loadedCachedHistory setting \(messages.count) messages, isRestoring: \(isRestoring)")
                state.messages = messages
                // Force state change notification by setting a marker
                state.needsScrollToBottom = true
                logger.log("SMAlog: loadedCachedHistory set needsScrollToBottom=true, messages should update")
                return .none

            case .loadedHistory(let messages):
                // Always update messages - the comparison logic was causing issues
                // where UI didn't update when counts matched
                logger.log("SMAlog: loadedHistory updating messages, count: \(messages.count)")
                state.messages = messages
                state.needsScrollToBottom = true
                state.isSending = false
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
}