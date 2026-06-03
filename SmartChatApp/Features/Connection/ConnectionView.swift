import SwiftUI
import ComposableArchitecture

struct ConnectionView: View {
    @State private var serverURL: String = ""
    @State private var authToken: String = ""
    @State private var isConnecting: Bool = false
    @State private var isConnected: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("Server Configuration") {
                TextField("Gateway URL", text: $serverURL)
                    .textContentType(.URL)
                    .autocapitalization(.none)
                    .keyboardType(.URL)

                SecureField("Auth Token", text: $authToken)
                    .textContentType(.password)
            }

            Section {
                if isConnecting {
                    HStack {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                        Text("Connecting...")
                            .foregroundColor(.gray)
                    }
                } else {
                    Button(action: connect) {
                        HStack {
                            Spacer()
                            Text(isConnected ? "Disconnect" : "Connect")
                                .foregroundColor(isConnected ? .red : Color(hex: "10A37F"))
                            Spacer()
                        }
                    }
                    .disabled(serverURL.isEmpty)
                }
            }

            if let error = errorMessage {
                Section {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }
        }
        .navigationTitle("Connection")
    }

    private func connect() {
        guard !serverURL.isEmpty else {
            errorMessage = "Server URL is required"
            return
        }
        isConnecting = true
        errorMessage = nil

        Task {
            try? await Task.sleep(for: .seconds(1))
            isConnecting = false
            isConnected = true
        }
    }
}
