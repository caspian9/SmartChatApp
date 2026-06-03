import ComposableArchitecture
import Foundation

@Reducer
struct ConnectionFeature {
    struct State: Equatable {
        var serverURL: String = ""
        var authToken: String = ""
        var isConnecting = false
        var isConnected = false
        var error: String?
    }

    enum Action: Equatable {
        case serverURLChanged(String)
        case authTokenChanged(String)
        case connect
        case disconnect
        case connectionSucceeded
        case connectionFailed(String)
    }

    @Dependency(\.continuousClock) var clock

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .serverURLChanged(let url):
                state.serverURL = url
                return .none

            case .authTokenChanged(let token):
                state.authToken = token
                return .none

            case .connect:
                guard !state.serverURL.isEmpty else {
                    state.error = "Server URL is required"
                    return .none
                }
                state.isConnecting = true
                state.error = nil
                return .run { send in
                    try await clock.sleep(for: .seconds(1))
                    await send(.connectionSucceeded)
                }

            case .disconnect:
                state.isConnected = false
                state.isConnecting = false
                return .none

            case .connectionSucceeded:
                state.isConnecting = false
                state.isConnected = true
                return .none

            case .connectionFailed(let error):
                state.isConnecting = false
                state.error = error
                return .none
            }
        }
    }
}