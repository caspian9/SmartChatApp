import SwiftUI
import ComposableArchitecture

struct ConnectionView: View {
    let store: StoreOf<ConnectionFeature>

    var body: some View {
        WithViewStore(store, observe: { $0 }) { viewStore in
            Form {
                Section("Server Configuration") {
                    TextField("Gateway URL", text: viewStore.binding(\.serverURL))
                        .textContentType(.URL)
                        .autocapitalization(.none)
                        .keyboardType(.URL)

                    SecureField("Auth Token", text: viewStore.binding(\.authToken))
                        .textContentType(.password)
                }

                Section {
                    if viewStore.isConnecting {
                        HStack {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle())
                            Text("Connecting...")
                                .foregroundColor(.gray)
                        }
                    } else {
                        Button(action: { viewStore.send(.connect) }) {
                            HStack {
                                Spacer()
                                Text(viewStore.isConnected ? "Disconnect" : "Connect")
                                    .foregroundColor(viewStore.isConnected ? .red : Color(hex: "10A37F"))
                                Spacer()
                            }
                        }
                        .disabled(viewStore.serverURL.isEmpty)
                    }
                }

                if let error = viewStore.error {
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
}
