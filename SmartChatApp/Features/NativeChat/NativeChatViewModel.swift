import ComposableArchitecture
import Foundation
import OpenClawChatUI

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
    }

    enum Action: Equatable {
        case loadSessions
        case loadedSessions([OpenClawChatSessionEntry])
        case selectSession(OpenClawChatSessionEntry)
        case updateInputText(String)
        case sendMessage
        case loadHistory
        case loadedHistory([ChatMessage])
        case receiveMessage(ChatMessage)
    }

    @Dependency(\.continuousClock) var clock

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .loadSessions:
                state.isLoading = true
                return .run { send in
                    try await clock.sleep(for: .milliseconds(100))
                    await send(.loadedSessions([]))
                }

            case .loadedSessions(let sessions):
                state.sessions = sessions
                state.isLoading = false
                if state.selectedSession == nil, let first = sessions.first {
                    state.selectedSession = first
                }
                return .none

            case .selectSession(let session):
                state.selectedSession = session
                return .send(.loadHistory)

            case .updateInputText(let text):
                state.inputText = text
                return .none

            case .sendMessage:
                guard !state.inputText.isEmpty,
                      let session = state.selectedSession else {
                    return .none
                }
                let text = state.inputText
                let message = ChatMessage(
                    id: UUID().uuidString,
                    text: text,
                    isOutgoing: true,
                    timestamp: Date()
                )
                state.messages.append(message)
                state.inputText = ""
                return .none

            case .loadHistory:
                return .run { send in
                    await send(.loadedHistory([]))
                }

            case .loadedHistory(let messages):
                state.messages = messages
                return .none

            case .receiveMessage(let message):
                state.messages.append(message)
                return .none
            }
        }
    }
}