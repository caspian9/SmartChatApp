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
                                            await handleTransportEvent(evt, sessionKey: sessionKey, send: send)
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
                    // Update existing message (streaming text update)
                    var existingMessage = state.messages[existingIndex]
                    existingMessage.text = message.text
                    existingMessage.state = message.state
                    if message.startedAt != nil { existingMessage.startedAt = message.startedAt }
                    if message.endedAt != nil { existingMessage.endedAt = message.endedAt }
                    if message.livenessState != nil { existingMessage.livenessState = message.livenessState }
                    if message.seq != nil { existingMessage.seq = message.seq }
                    state.messages[existingIndex] = existingMessage
                    logger.log("SMAlog: updated message: \(message.id), text length: \(message.text.count), state: \(message.state)")
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
            }
        }
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

            if phase == "start" {
                // Start of a new run
                let message = ChatMessage(
                    id: runId,
                    text: "",
                    timestamp: timestamp,
                    role: "assistant",
                    state: "streaming",
                    runId: runId,
                    seq: nil,
                    startedAt: startedAtMs > 0 ? Date(timeIntervalSince1970: startedAtMs / 1000) : timestamp,
                    endedAt: nil,
                    livenessState: livenessState,
                    toolCallId: nil,
                    toolName: nil,
                    stopReason: nil
                )
                await send(.receiveMessage(message))
                logger.log("SMAlog: agent start - runId: \(runId), startedAt: \(startedAtMs)")
            } else if phase == "end" {
                // End of run - update existing message or create final message
                let message = ChatMessage(
                    id: runId,
                    text: "",
                    timestamp: timestamp,
                    role: "assistant",
                    state: "final",
                    runId: runId,
                    seq: nil,
                    startedAt: startedAtMs > 0 ? Date(timeIntervalSince1970: startedAtMs / 1000) : nil,
                    endedAt: endedAtMs > 0 ? Date(timeIntervalSince1970: endedAtMs / 1000) : timestamp,
                    livenessState: livenessState,
                    toolCallId: nil,
                    toolName: nil,
                    stopReason: nil
                )
                await send(.receiveMessage(message))
                logger.log("SMAlog: agent end - runId: \(runId), endedAt: \(endedAtMs)")
                // Reset sending state when run ends
                await send(.setSending(false))
            } else {
                // Assistant stream - update text with delta
                let text = extractString(from: data, key: "text") ?? ""
                let _ = extractString(from: data, key: "delta")

                if !text.isEmpty {
                    let message = ChatMessage(
                        id: runId,
                        text: text,
                        timestamp: timestamp,
                        role: "assistant",
                        state: "streaming",
                        runId: runId,
                        seq: nil,
                        startedAt: nil,
                        endedAt: nil,
                        livenessState: livenessState,
                        toolCallId: nil,
                        toolName: nil,
                        stopReason: nil
                    )
                    await send(.receiveMessage(message))
                    logger.log("SMAlog: agent text - runId: \(runId), text length: \(text.count)")
                }
            }

        case .chat(let payload):
            logger.log("SMAlog: chat event - state: \(payload.state ?? "nil")")
            if let msgAny = payload.message {
                guard let data = try? JSONEncoder().encode(msgAny),
                      let chatMsg = try? JSONDecoder().decode(OpenClawChatMessage.self, from: data) else {
                    logger.log("SMAlog: failed to decode chat message")
                    return
                }
                var text = ""
                for contentItem in chatMsg.content {
                    if let t = contentItem.text, !t.isEmpty {
                        text = t
                        break
                    }
                }
                let message = ChatMessage(
                    id: chatMsg.id.uuidString,
                    text: text,
                    timestamp: Date(timeIntervalSince1970: (chatMsg.timestamp ?? 0) / 1000),
                    role: chatMsg.role,
                    state: payload.state ?? "final",
                    runId: payload.runId,
                    seq: nil,
                    startedAt: nil,
                    endedAt: nil,
                    livenessState: nil,
                    toolCallId: chatMsg.toolCallId,
                    toolName: chatMsg.toolName,
                    stopReason: chatMsg.stopReason
                )
                await send(.receiveMessage(message))
            }

        case .sessionMessage, .tick, .seqGap:
            // Ignored
            break

        case .health(let ok):
            logger.log("SMAlog: health check: \(ok)")
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
}