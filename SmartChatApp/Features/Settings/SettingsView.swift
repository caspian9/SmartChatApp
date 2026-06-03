import SwiftUI
import ComposableArchitecture

struct SettingsView: View {
    let store: StoreOf<SettingsFeature>

    var body: some View {
        Form {
            Section("Server") {
                TextField("Gateway URL", text: $store.state.serverURL)
                    .textContentType(.URL)

                SecureField("Auth Token", text: $store.state.authToken)
            }

            Section("Appearance") {
                Toggle("Dark Mode", isOn: $store.state.isDarkMode)
            }

            Section("About") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text("1.0.0")
                        .foregroundColor(.gray)
                }
            }
        }
        .navigationTitle("Settings")
    }
}