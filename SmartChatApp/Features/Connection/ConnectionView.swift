import SwiftUI
import ComposableArchitecture

struct ConnectionView: View {
    @StateObject private var store = StoreOf<ConnectionFeature>(ConnectionFeature())
    @State private var serverURL: String = ""
    @State private var authToken: String = ""

    var body: some View {
        Form {
            Section("Server Configuration") {
                TextField("Gateway URL", text: $serverURL)
                    .textContentType(.URL)
                    .autocapitalization(.none)
                    .keyboardType(.URL)
                    .onChange(of: serverURL) { _, newValue in
                        store.send(.serverURLChanged(newValue))
                    }

                SecureField("Auth Token", text: $authToken)
                    .textContentType(.password)
                    .onChange(of: authToken) { _, newValue in
                        store.send(.authTokenChanged(newValue))
                    }
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
                    Button(action: {
                        store.send(.connect)
                    }) {
                        HStack {
                            Spacer()
                            Text(store.isConnected ? "Disconnect" : "Connect")
                                .foregroundColor(store.isConnected ? .red : Color(hex: "10A37F"))
                            Spacer()
                        }
                    }
                    .disabled(serverURL.isEmpty)
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
}
