import SwiftUI
import ComposableArchitecture

struct SettingsView: View {
    @State private var serverURL: String = ""
    @State private var authToken: String = ""
    @State private var isDarkMode: Bool = true

    var body: some View {
        Form {
            Section("Server") {
                TextField("Gateway URL", text: $serverURL)
                    .textContentType(.URL)

                SecureField("Auth Token", text: $authToken)
            }

            Section("Appearance") {
                Toggle("Dark Mode", isOn: $isDarkMode)
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
