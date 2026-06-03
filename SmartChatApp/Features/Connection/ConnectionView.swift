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
                if store.isConnecting {
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
                            Text(store.isConnected ? "Disconnect" : "Connect")
                                .foregroundColor(store.isConnected ? .red : Color(hex: "10A37F"))
                            Spacer()
                        }
                    }
                    .disabled(store.serverURL.isEmpty)
                }
            }

            if let error = store.error {
                Section {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }
        }
        .navigationTitle("Connection")
    }

    private func binding<T>(for keyPath: WritableKeyPath<ConnectionFeature.State, T>) -> Binding<T> {
        Binding(
            get: { store[keyPath: keyPath] },
            set: { newValue in
                if keyPath == \.serverURL {
                    store.send(.serverURLChanged(newValue as! String))
                } else if keyPath == \.authToken {
                    store.send(.authTokenChanged(newValue as! String))
                }
            }
        )
    }
}
