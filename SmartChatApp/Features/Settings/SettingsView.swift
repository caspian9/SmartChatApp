import SwiftUI
import ComposableArchitecture

struct SettingsView: View {
    let store: StoreOf<SettingsFeature>

    var body: some View {
        Form {
            Section("Server") {
                TextField("Gateway URL", text: binding(for: \.serverURL))
                    .textContentType(.URL)

                SecureField("Auth Token", text: binding(for: \.authToken))
            }

            Section("Appearance") {
                Toggle("Dark Mode", isOn: binding(for: \.isDarkMode))
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

    private func binding<T>(for keyPath: WritableKeyPath<SettingsFeature.State, T>) -> Binding<T> {
        Binding(
            get: { store[keyPath: keyPath] },
            set: { newValue in
                if keyPath == \.serverURL {
                    store.send(.serverURLChanged(newValue as! String))
                } else if keyPath == \.authToken {
                    store.send(.authTokenChanged(newValue as! String))
                } else if keyPath == \.isDarkMode {
                    store.send(.darkModeToggled(newValue as! Bool))
                }
            }
        )
    }
}
