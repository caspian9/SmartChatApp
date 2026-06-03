import SwiftUI
import ComposableArchitecture

struct ConnectionView: View {
    @StateObject private var store = StoreOf<ConnectionFeature>(initialState: ConnectionFeature.State()) {
        ConnectionFeature()
    }
    @State private var serverURL: String = ""
    @State private var authToken: String = ""

    var body: some View {
        Form {
            Section("Server Configuration") {
                TextField("Gateway URL", text: $serverURL)
                    .textContentType(.URL)
                    .autocapitalization(.none)
                    .keyboardType(.URL)
                    .onChange(of: serverURL) { newValue in
                        store.send(.serverURLChanged(newValue))
                    }

                SecureField("Auth Token", text: $authToken)
                    .textContentType(.password)
                    .onChange(of: authToken) { newValue in
                        store.send(.authTokenChanged(newValue))
                    }
            }

            Section {
                Button(action: {
                    store.send(.connect)
                }) {
                    HStack {
                        Spacer()
                        Text(store.state.isConnecting ? "Connecting..." : (store.state.isConnected ? "Disconnect" : "Connect"))
                            .foregroundColor(store.state.isConnected ? .red : Color(hex: "10A37F"))
                        Spacer()
                    }
                }
                .disabled(serverURL.isEmpty)
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
}
