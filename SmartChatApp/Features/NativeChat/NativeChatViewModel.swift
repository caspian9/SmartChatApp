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
    }

    @Dependency(\.continuousClock) var clock

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
                let text = state.inputText
                let sessionKey = session.key
                let message = ChatMessage(
                    id: UUID().uuidString,
                    text: text,
                    isOutgoing: true,
                    timestamp: Date(),
                    role: "user",
                    state: "final",
                    runId: nil,
                    toolCallId: nil,
                    toolName: nil,
                    stopReason: nil
                )
                state.messages.append(message)
                state.inputText = ""
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
                                            await handleChatEvent(evt, sessionKey: sessionKey, send: send)
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
                                    timestamp: Date(timeIntervalSince1970: ts / 1000),
                                    role: msg.role,
                                    state: "final",
                                    runId: nil,
                                    toolCallId: msg.toolCallId,
                                    toolName: msg.toolName,
                                    stopReason: msg.stopReason
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
                // Check if this is an update to existing message or new message
                if let existingIndex = state.messages.firstIndex(where: { $0.id == message.id }) {
                    // Update existing message
                    var existingMessage = state.messages[existingIndex]
                    existingMessage.text = message.text
                    existingMessage.state = message.state
                    state.messages[existingIndex] = existingMessage
                    logger.log("SMAlog: updated existing message: \(message.id), state: \(message.state)")
                } else {
                    // New message
                    state.messages.append(message)
                    logger.log("SMAlog: added new message: \(message.id), state: \(message.state)")
                }
                // When state is final, message reception is complete - reset sending state
                if message.state == "final" {
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

            case .updateStreamingText(let text):
                state.streamingText = text
                return .none

            case .clearStreamingText:
                state.streamingText = ""
                return .none
            }
        }
    }

    private func handleChatEvent(_ event: OpenClawChatTransportEvent, sessionKey: String, send: Send<Action>) async {
        switch event {
        case .chat(let payload):
            logger.log("SMAlog: chat event - state: \(payload.state ?? "nil")")
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
                if !text.isEmpty || !isOutgoing {
                    let message = ChatMessage(
                        id: chatMsg.id.uuidString,
                        text: text,
                        isOutgoing: isOutgoing,
                        timestamp: Date(timeIntervalSince1970: (chatMsg.timestamp ?? 0) / 1000),
                        role: chatMsg.role,
                        state: payload.state ?? "in_progress",
                        runId: payload.runId,
                        toolCallId: chatMsg.toolCallId,
                        toolName: chatMsg.toolName,
                        stopReason: chatMsg.stopReason
                    )
                    await send(.receiveMessage(message))
                }
            }
        case .sessionMessage, .agent, .tick, .health, .seqGap:
            // Only handle .chat events, ignore others but log for debugging
            if case .agent(let payload) = event {
                logger.log("SMAlog: agent event - stream: \(payload.stream)")
            } else if case .health(let ok) = event {
                logger.log("SMAlog: health check: \(ok)")
            }
            break
        }
    }
}