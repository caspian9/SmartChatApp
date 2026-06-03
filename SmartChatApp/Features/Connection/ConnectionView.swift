import SwiftUI
import ComposableArchitecture

struct ConnectionView: View {
    let store: StoreOf<ConnectionFeature>

    var body: some View {
        Form {
            Section("Server Configuration") {
                TextField("Gateway URL", text: binding(for: \.serverURL))
                    .textContentType(.URL)
                    .autocapitalization(.none)
                    .keyboardType(.URL)

                SecureField("Auth Token", text: binding(for: \.authToken))
                    .textContentType(.password)
            }

            Section {
                if store.state.isConnecting {
                    HStack {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                        Text("Connecting...")
                            .foregroundColor(.gray)
                    }
                } else {
                    Button(action: { store.send(.connect) }) {
                        HStack {
                            Spacer()
                            Text(store.state.isConnected ? "Disconnect" : "Connect")
                                .foregroundColor(store.state.isConnected ? .red : Color(hex: "10A37F"))
                            Spacer()
                        }
                    }
                    .disabled(store.state.serverURL.isEmpty)
                }
            }

            if let error = store.state.error {
                Section {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }
        }
        .navigationTitle("Connection")
    }

    private func binding(for keyPath: WritableKeyPath<ConnectionFeature.State, String>) -> Binding<String> {
        Binding(
            get: { store.state[keyPath: keyPath] },
            set: { newValue in
                if keyPath == \.serverURL {
                    store.send(.serverURLChanged(newValue))
                } else if keyPath == \.authToken {
                    store.send(.authTokenChanged(newValue))
                }
            }
        )
    }
}
