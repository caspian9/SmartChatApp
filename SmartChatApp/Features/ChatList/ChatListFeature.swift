import ComposableArchitecture
import SwiftUI
import OpenClawChatUI

@Reducer
struct ChatListFeature {
    struct State: Equatable {
        var sessions: [OpenClawChatSessionEntry] = []
        var isLoading = false
        var error: String?
    }

    enum Action: Equatable {
        case loadSessions
        case loadedSessions([OpenClawChatSessionEntry])
        case createSession
        case deleteSession(String)
        case selectSession(OpenClawChatSessionEntry)
    }

    @Dependency(\.continuousClock) var clock

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .loadSessions:
                state.isLoading = true
                return .run { send in
                    try await clock.sleep(for: .milliseconds(500))
                    let mockSessions: [OpenClawChatSessionEntry] = []
                    await send(.loadedSessions(mockSessions))
                }

            case .loadedSessions(let sessions):
                state.sessions = sessions
                state.isLoading = false
                return .none

            case .createSession:
                let newSession = OpenClawChatSessionEntry(
                    key: UUID().uuidString,
                    kind: "chat",
                    displayName: "New Chat",
                    surface: nil,
                    subject: nil,
                    room: nil,
                    space: nil,
                    updatedAt: Date().timeIntervalSince1970,
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
                    contextTokens: nil,
                    thinkingLevels: nil,
                    thinkingOptions: nil,
                    thinkingDefault: nil
                )
                state.sessions.insert(newSession, at: 0)
                return .none

            case .deleteSession(let key):
                state.sessions.removeAll { $0.key == key }
                return .none

            case .selectSession:
                return .none
            }
        }
    }
}
