import ComposableArchitecture
import Foundation
import OpenClawChatUI
import OSLog
import OpenClawKit

private let logger = Logger(subsystem: "SmartChatApp", category: "NativeChatViewModel")

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
        var streamingText: String = ""
        var streamingMessageId: String?
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
        case receiveMessage(ChatMessage)
        case setError(String?)
        case setSending(Bool)
        case updateStreamingText(String)
        case clearStreamingText
        case setStreamingMessageId(String?)
        case startStreamingMessage(id: String, text: String)
    }

    @Dependency(\.continuousClock) var clock

    private var eventTask: Task<Void, Never>?

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .loadSessions:
                state.isLoading = true
                state.error = nil
                return .run { send in
                    Task {
                        do {
                            try await SessionManager.shared.ensureConnected()
                            let transport = await SessionManager.shared.makeTransport(sessionKey: "")
                            let response = try await transport.listSessions(limit: 50)
                            logger.log("SMAlog: Loaded \(response.sessions.count) sessions")
                            await send(.loadedSessions(response.sessions))
                        } catch {
                            logger.log("SMAlog: Load sessions error: \(error.localizedDescription)")
                            await send(.loadedSessions([]))
                        }
                    }
                }

            case .loadedSessions(let sessions):
                state.sessions = sessions
                state.isLoading = false
                if let first = sessions.first {
                    let firstKeyPreview = String(first.key.prefix(12))
                    logger.log("SMAlog: first session key: \(firstKeyPreview), surface: \(first.surface ?? "nil")")
                }
                if state.selectedSession == nil, let first = sessions.first {
                    state.selectedSession = first
                    logger.log("SMAlog: auto-selected session: \(String(first.key.prefix(12)))")
                    return .send(.loadHistory)
                }
                return .none

            case .selectSession(let session):
                state.selectedSession = session
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
                state.streamingMessageId = nil
                state.streamingText = ""
                let text = state.inputText
                let sessionKey = session.key
                let messageId = UUID().uuidString
                let message = ChatMessage(
                    id: messageId,
                    text: text,
                    isOutgoing: true,
                    timestamp: Date()
                )
                state.messages.append(message)
                state.inputText = ""
                // Capture streaming text value before escaping closure
                let initialStreamingText = state.streamingText
                // Start listening for events before sending
                return .run { send in
                    Task {
                        do {
                            try await SessionManager.shared.ensureConnected()
                            let transport = await SessionManager.shared.makeTransport(sessionKey: sessionKey)
                            // Start event listening task
                            Task {
                                for await evt in transport.events() {
                                    await MainActor.run {
                                        Task {
                                            await handleEvent(evt, sessionKey: sessionKey, send: send, currentStreamingText: initialStreamingText)
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
                return .run { send in
                    Task {
                        do {
                            try await SessionManager.shared.ensureConnected()
                            let transport = await SessionManager.shared.makeTransport(sessionKey: sessionKey)
                            let history = try await transport.requestHistory(sessionKey: sessionKey)
                            let messageCount = history.messages?.count ?? 0
                            logger.log("SMAlog: Loaded \(messageCount) history messages for session: \(sessionKeyPreview)")
                            let chatMessages: [ChatMessage] = (history.messages ?? []).enumerated().compactMap { index, anyCodable -> ChatMessage? in
                                guard let msg = try? JSONDecoder().decode(OpenClawChatMessage.self, from: JSONEncoder().encode(anyCodable)) else {
                                    logger.log("SMAlog: message[\(index)] failed to decode as OpenClawChatMessage")
                                    return nil
                                }
                                let isOutgoing = msg.role.lowercased() == "user"
                                var text = ""
                                for contentItem in msg.content {
                                    if let t = contentItem.text, !t.isEmpty {
                                        text = t
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
                                    isOutgoing: isOutgoing,
                                    timestamp: Date(timeIntervalSince1970: ts / 1000)
                                )
                            }
                            logger.log("SMAlog: chatMessages count: \(chatMessages.count)")
                            await send(.loadedHistory(chatMessages))
                        } catch {
                            logger.log("SMAlog: Load history error: \(error.localizedDescription)")
                            await send(.loadedHistory([]))
                        }
                    }
                }

            case .loadedHistory(let messages):
                state.messages = messages
                state.isSending = false
                return .none

            case .receiveMessage(let message):
                // Deduplicate: only add if message with same ID doesn't exist
                if !state.messages.contains(where: { $0.id == message.id }) {
                    state.messages.append(message)
                }
                // If this message completes a streaming message, clear streaming state
                if state.streamingMessageId == message.id {
                    state.streamingMessageId = nil
                    state.streamingText = ""
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

            case .updateStreamingText(let text):
                // Only update streamingText state for UI display
                // Do NOT add to messages array during streaming
                state.streamingText = text
                return .none

            case .clearStreamingText:
                state.streamingText = ""
                return .none

            case .setStreamingMessageId(let id):
                state.streamingMessageId = id
                return .none

            case .startStreamingMessage(let id, let text):
                state.streamingMessageId = id
                state.streamingText = text
                let message = ChatMessage(
                    id: id,
                    text: text,
                    isOutgoing: false,
                    timestamp: Date()
                )
                state.messages.append(message)
                return .none
            }
        }
    }

    private func handleEvent(_ event: OpenClawChatTransportEvent, sessionKey: String, send: Send<Action>, currentStreamingText: String) async {
        switch event {
        case .chat(let payload):
            logger.log("SMAlog: chat event received")
            if let msgAny = payload.message {
                guard let data = try? JSONEncoder().encode(msgAny),
                      let chatMsg = try? JSONDecoder().decode(OpenClawChatMessage.self, from: data) else {
                    logger.log("SMAlog: failed to decode chat message")
                    return
                }
                let isOutgoing = chatMsg.role.lowercased() == "user"
                var text = ""
                for contentItem in chatMsg.content {
                    if let t = contentItem.text, !t.isEmpty {
                        text = t
                        break
                    }
                }
                if !text.isEmpty {
                    // If we have accumulated streaming text, use that instead of the event text
                    let finalText = currentStreamingText.isEmpty ? text : currentStreamingText
                    let message = ChatMessage(
                        id: chatMsg.id.uuidString,
                        text: finalText,
                        isOutgoing: isOutgoing,
                        timestamp: Date(timeIntervalSince1970: (chatMsg.timestamp ?? 0) / 1000)
                    )
                    // Clear streaming state when chat event completes
                    await send(.clearStreamingText)
                    await send(.receiveMessage(message))
                }
            }
        case .sessionMessage(let payload):
            logger.log("SMAlog: sessionMessage event received")
            if let msg = payload.message {
                let isOutgoing = msg.role.lowercased() == "user"
                var text = ""
                for contentItem in msg.content {
                    if let t = contentItem.text, !t.isEmpty {
                        text = t
                        break
                    }
                }
                if !text.isEmpty {
                    // If we have accumulated streaming text, use that instead
                    let finalText = currentStreamingText.isEmpty ? text : currentStreamingText
                    let message = ChatMessage(
                        id: msg.id.uuidString,
                        text: finalText,
                        isOutgoing: isOutgoing,
                        timestamp: Date(timeIntervalSince1970: (msg.timestamp ?? 0) / 1000)
                    )
                    // Clear streaming state when session message event completes
                    await send(.clearStreamingText)
                    await send(.receiveMessage(message))
                }
            }
        case .agent(let payload):
            logger.log("SMAlog: agent event - stream: \(payload.stream)")
            // Handle streaming text from agent events - only update streamingText
            if payload.stream == "assistant", let text = payload.data["text"]?.value as? String {
                await send(.updateStreamingText(text))
            }
        case .tick:
            break
        case .health(let ok):
            logger.log("SMAlog: health check: \(ok)")
        case .seqGap:
            logger.log("SMAlog: seqGap event")
        }
    }
}