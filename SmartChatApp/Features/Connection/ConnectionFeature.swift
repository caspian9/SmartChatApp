import SwiftUI
import ComposableArchitecture
import OpenClawKit

@Reducer
struct ConnectionFeature {
    @ObservableState
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
                let serverURL = state.serverURL
                let authToken = state.authToken
                return .run { send in
                    do {
                        guard let url = URL(string: serverURL) else {
                            await send(.connectionFailed("Invalid URL"))
                            return
                        }
                        let client = GatewayClient()
                        try await client.connect(gatewayURL: url, authToken: authToken)
                        try await client.disconnect()
                        await send(.connectionSucceeded)
                    } catch {
                        await send(.connectionFailed(error.localizedDescription))
                    }
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
