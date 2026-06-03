import ComposableArchitecture
import Foundation

@Reducer
struct SettingsFeature {
    struct State: Equatable {
        var serverURL: String = ""
        var authToken: String = ""
        var isDarkMode = true
    }

    enum Action: Equatable {
        case serverURLChanged(String)
        case authTokenChanged(String)
        case darkModeToggled(Bool)
        case saveSettings
    }

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .serverURLChanged(let url):
                state.serverURL = url
                return .none

            case .authTokenChanged(let token):
                state.authToken = token
                return .none

            case .darkModeToggled(let enabled):
                state.isDarkMode = enabled
                return .none

            case .saveSettings:
                return .none
            }
        }
    }
}