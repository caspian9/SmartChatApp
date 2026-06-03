import ComposableArchitecture
import SwiftUI

@Reducer
struct ChatListFeature {
    struct State: Equatable {
        var sessions: [ChatSession] = []
        var isLoading = false
        var error: String?
    }

    enum Action: Equatable {
        case loadSessions
        case createSession
        case deleteSession(String)
        case selectSession(ChatSession)
    }

    @Dependency(\.continuousClock) var clock

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .loadSessions:
                state.isLoading = true
                return .run { send in
                    try await clock.sleep(for: .milliseconds(500))
                    let mockSessions = [
                        ChatSession(id: "1", title: "Chat 1"),
                        ChatSession(id: "2", title: "Chat 2"),
                    ]
                    await send(.loadedSessions(mockSessions))
                }

            case .loadedSessions(let sessions):
                state.sessions = sessions
                state.isLoading = false
                return .none

            case .createSession:
                let newSession = ChatSession()
                state.sessions.insert(newSession, at: 0)
                return .none

            case .deleteSession(let id):
                state.sessions.removeAll { $0.id == id }
                return .none

            case .selectSession:
                return .none
            }
        }
    }

    private func loadedSessions(_ sessions: [ChatSession]) -> Action {
        .loadedSessions(sessions)
    }
}