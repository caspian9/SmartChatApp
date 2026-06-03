import ComposableArchitecture
import Foundation
import OpenClawChatUI
import OSLog
import OpenClawKit

private let logger = Logger(subsystem: "SmartChatApp", category: "NativeChatViewModel")

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
    }

    @Dependency(\.continuousClock) var clock

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .loadSessions:
                logger.log("SMAlog: loadSessions called")
                // First load from cache
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
                            // Ensure connected first, with retry
                            try await SessionManager.shared.ensureConnected()
                            // Small delay to ensure connection is stable
                            try await Task.sleep(for: .milliseconds(100))
                            let transport = await SessionManager.shared.makeTransport(sessionKey: "")
                            let response = try await transport.listSessions(limit: 50)
                            logger.log("SMAlog: Loaded \(response.sessions.count) sessions")
                            await send(.loadedSessions(response.sessions))
                        } catch {
                            logger.log("SMAlog: Load sessions error: \(error.localizedDescription)")
                            // Retry once after a short delay
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

                // Try to restore last selected session
                let lastKey = UserDefaults.standard.string(forKey: lastSelectedSessionKey)
                if let key = lastKey, let lastSession = sessions.first(where: { $0.key == key }) {
                    state.selectedSession = lastSession
                    logger.log("SMAlog: restored last selected session: \(String(lastSession.key.prefix(12)))")
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
                                    logger.log("SMAlog: message[\(index)] failed to decode as OpenClawChatMessage")
                                    return nil
                                }
                                var text = ""
                                for contentItem in msg.content {
                                    if let t = contentItem.text, !t.isEmpty {
                                        text = t.trimmingCharacters(in: .whitespacesAndNewlines)
                                        break
                                    }
                                }
                                if text.isEmpty {
                                    return nil
                                }
                                let ts = msg.timestamp ?? 0
                                let msgId = msg.id.uuidString
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
                state.needsScrollToBottom = false
                state.isSending = false
                return .none

            case .receiveMessage(let message):
                // Check if this is an update to existing message or new message
                if let existingIndex = state.messages.firstIndex(where: { $0.id == message.id }) {
                    // Update existing message (streaming text update)
                    var existingMessage = state.messages[existingIndex]
                    // Only update text if new text is not empty (preserve content on end phase)
                    if !message.text.isEmpty {
                        existingMessage.text = message.text
                    }
                    existingMessage.state = message.state
                    if message.startedAt != nil { existingMessage.startedAt = message.startedAt }
                    if message.endedAt != nil { existingMessage.endedAt = message.endedAt }
                    if message.livenessState != nil { existingMessage.livenessState = message.livenessState }
                    if message.seq != nil { existingMessage.seq = message.seq }
                    state.messages[existingIndex] = existingMessage
                    logger.log("SMAlog: updated message: \(message.id), text length: \(existingMessage.text.count), state: \(message.state)")
                } else {
                    // New message
                    state.messages.append(message)
                    logger.log("SMAlog: added new message: \(message.id), state: \(message.state)")
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

            // Extract phase
            let phase = extractString(from: data, key: "phase")
            let startedAtMs = extractDouble(from: data, key: "startedAt")
            let endedAtMs = extractDouble(from: data, key: "endedAt")
            let livenessState = extractString(from: data, key: "livenessState")
            let seq = extractInt(from: data, key: "seq")

            if phase == "start" {
                // Start of a new run
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
                // End of run
                let message = ChatMessage(
                    id: runId,
                    text: "",
                    timestamp: timestamp,
                    role: "assistant",
                    state: "final",
                    runId: runId,
                    seq: seq,
                    startedAt: startedAtMs > 0 ? Date(timeIntervalSince1970: startedAtMs / 1000) : nil,
                    endedAt: endedAtMs > 0 ? Date(timeIntervalSince1970: endedAtMs / 1000) : timestamp,
                    livenessState: livenessState,
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