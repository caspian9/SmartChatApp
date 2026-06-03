import SwiftUI

struct SettingsView: View {
    @StateObject private var config = ConfigurationManager.shared
    @State private var showConnectionSheet = false

    var body: some View {
        Form {
            Section("OpenClaw Gateway") {
                HStack {
                    Text("Gateway")
                    Spacer()
                    Text(config.isConfigured ? config.displayURL : "Not configured")
                        .foregroundColor(config.isConfigured ? .secondary : .gray)
                        .lineLimit(1)
                }

                HStack {
                    Text("Status")
                    Spacer()
                    Text(config.isConfigured ? "Configured" : "Not configured")
                        .foregroundColor(config.isConfigured ? Color(hex: "10A37F") : .gray)
                }

                Button("Configure Connection") {
                    showConnectionSheet = true
                }
                .foregroundColor(Color(hex: "10A37F"))
            }

            Section("Appearance") {
                Toggle("Dark Mode", isOn: .constant(true))
                    .disabled(true)
            }

            Section("About") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text("1.0.0")
                        .foregroundColor(.gray)
                }

                HStack {
                    Text("Build")
                    Spacer()
                    Text("1")
                        .foregroundColor(.gray)
                }
            }
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $showConnectionSheet) {
            ConnectionConfigSheet()
        }
    }
}

struct ConnectionConfigSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var config = ConfigurationManager.shared
    @State private var serverHost: String = ""
    @State private var serverPort: String = ""
    @State private var useTLS: Bool = true
    @State private var authToken: String = ""
    @State private var isTesting: Bool = false
    @State private var testResult: String?
    @State private var testStatus: TestStatus = .idle

    enum TestStatus {
        case idle, testing, success, failure
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Gateway Configuration") {
                    TextField("Host (e.g., api.openclaw.ai)", text: $serverHost)
                        .textContentType(.URL)
                        .autocapitalization(.none)
                        .keyboardType(.URL)

                    TextField("Port", text: $serverPort)
                        .keyboardType(.numberPad)

                    Toggle("Use TLS/SSL", isOn: $useTLS)
                }

                Section("Authentication") {
                    SecureField("Auth Token", text: $authToken)
                        .textContentType(.password)
                }

                Section {
                    Button(action: testConnection) {
                        HStack {
                            Spacer()
                            if isTesting {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle())
                                Text("Testing...")
                            } else {
                                Text("Save & Test Connection")
                            }
                            Spacer()
                        }
                    }
                    .disabled(serverHost.isEmpty || authToken.isEmpty || isTesting)

                    if let result = testResult {
                        HStack {
                            Image(systemName: testStatus == .success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(testStatus == .success ? Color(hex: "10A37F") : .red)
                            Text(result)
                                .foregroundColor(testStatus == .success ? Color(hex: "10A37F") : .red)
                        }
                    }
                }

                Section {
                    Button("Clear Configuration") {
                        config.clear()
                        serverHost = ""
                        serverPort = ""
                        useTLS = true
                        authToken = ""
                        testResult = nil
                    }
                    .foregroundColor(.red)
                }
            }
            .navigationTitle("Connection Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        config.gatewayHost = serverHost
                        config.gatewayPort = Int(serverPort) ?? 443
                        config.gatewayUseTLS = useTLS
                        config.authToken = authToken
                        dismiss()
                    }
                    .disabled(serverHost.isEmpty || authToken.isEmpty)
                }
            }
            .onAppear {
                serverHost = config.gatewayHost
                serverPort = config.gatewayPort > 0 ? String(config.gatewayPort) : "443"
                useTLS = config.gatewayUseTLS
                authToken = config.authToken
            }
        }
    }

    private func testConnection() {
        guard !serverHost.isEmpty else { return }

        isTesting = true
        testResult = nil
        testStatus = .testing

        let port = Int(serverPort) ?? 443
        let scheme = useTLS ? "wss" : "ws"
        let urlString = "\(scheme)://\(serverHost):\(port)/gateway"

        guard let url = URL(string: urlString) else {
            isTesting = false
            testStatus = .failure
            testResult = "Invalid URL"
            return
        }

        Task {
            do {
                let client = OpenClawClient(gatewayURL: url)
                _ = try await client.connect(authToken: authToken)
                await client.disconnect()

                await MainActor.run {
                    isTesting = false
                    testStatus = .success
                    testResult = "Connection successful!"
                }
            } catch {
                await MainActor.run {
                    isTesting = false
                    testStatus = .failure
                    testResult = "Connection failed: \(error.localizedDescription)"
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
    .preferredColorScheme(.dark)
}