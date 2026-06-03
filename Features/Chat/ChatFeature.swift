import ComposableArchitecture
import SwiftUI

@Reducer
struct ChatFeature {
    struct State: Equatable {
        var session: ChatSession
        var inputText: String = ""
        var isStreaming = false
        var streamingContent: String = ""
        var currentToolCall: ToolCall?
        var isConnected = false
        var error: String?
    }

    enum Action: Equatable {
        case inputTextChanged(String)
        case sendMessage
        case receiveChunk(String)
        case streamingCompleted
        case toolCallDetected(ToolCall)
        case toolResultSubmitted(String)
        case abortStreaming
        case connect
        case disconnect
        case connectionStatusChanged(Bool)
    }

    @Dependency(\.continuousClock) var clock

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .inputTextChanged(let text):
                state.inputText = text
                return .none

            case .sendMessage:
                let userMessage = Message(role: .user, content: state.inputText)
                state.session.messages.append(userMessage)
                state.inputText = ""
                state.isStreaming = true
                state.streamingContent = ""
                return .none

            case .receiveChunk(let chunk):
                state.streamingContent += chunk
                return .none

            case .streamingCompleted:
                let assistantMessage = Message(
                    role: .assistant,
                    content: state.streamingContent,
                    toolCalls: state.currentToolCall.map { [$0] }
                )
                state.session.messages.append(assistantMessage)
                state.isStreaming = false
                state.streamingContent = ""
                return .none

            case .toolCallDetected(let toolCall):
                state.currentToolCall = toolCall
                return .none

            case .toolResultSubmitted(let result):
                if var toolCall = state.currentToolCall {
                    toolCall.result = result
                    state.session.messages.append(Message(
                        role: .assistant,
                        content: "",
                        toolCalls: [toolCall]
                    ))
                    state.currentToolCall = nil
                }
                return .none

            case .abortStreaming:
                state.isStreaming = false
                state.streamingContent = ""
                return .none

            case .connect:
                state.isConnected = true
                return .none

            case .disconnect:
                state.isConnected = false
                return .none

            case .connectionStatusChanged(let connected):
                state.isConnected = connected
                return .none
            }
        }
    }
}