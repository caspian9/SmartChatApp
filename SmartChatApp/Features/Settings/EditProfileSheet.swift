import SwiftUI

struct EditProfileSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let profile: GatewayProfile
    let onSave: (String, String, String, Int, String, Bool) -> Void
    let onDelete: (UUID) -> Void

    @State private var editName: String
    @State private var editHost: String
    @State private var editPort: String
    @State private var editToken: String
    @State private var editTlsEnabled: Bool
    @State private var isTesting = false
    @State private var isConnected = false
    @State private var testResult: String?
    @State private var testStatus: TestStatus = .idle

    enum TestStatus {
        case idle, testing, success, failure
    }

    init(profile: GatewayProfile, onSave: @escaping (String, String, String, Int, String, Bool) -> Void, onDelete: @escaping (UUID) -> Void) {
        self.profile = profile
        self.onSave = onSave
        self.onDelete = onDelete
        _editName = State(initialValue: profile.name)
        _editHost = State(initialValue: profile.host)
        _editPort = State(initialValue: String(profile.port))
        _editToken = State(initialValue: profile.token)
        _editTlsEnabled = State(initialValue: profile.tlsEnabled)
    }

    private func testConnection() {
        guard !editHost.isEmpty else { return }

        isTesting = true
        testResult = nil
        testStatus = .testing

        let port = Int(editPort) ?? 443
        let scheme = editTlsEnabled ? "wss" : "ws"
        let urlString = "\(scheme)://\(editHost):\(port)/gateway"

        guard let url = URL(string: urlString) else {
            isTesting = false
            testStatus = .failure
            testResult = "Invalid URL"
            return
        }

        Task {
            do {
                try await SessionManager.shared.connectWithRole(gatewayURL: url, authToken: editToken, role: .operatorAndNode)
                await MainActor.run {
                    isTesting = false
                    testStatus = .success
                    testResult = "Connected"
                    isConnected = true
                }
            } catch {
                await MainActor.run {
                    isTesting = false
                    testStatus = .failure
                    testResult = "Connection failed: \(error.localizedDescription)"
                    isConnected = false
                }
            }
        }
    }

    private func disconnectConnection() {
        Task {
            await SessionManager.shared.disconnect()
            await MainActor.run {
                isConnected = false
                testResult = "Disconnected"
                testStatus = .idle
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Profile") {
                    TextField("Name", text: $editName)
                        .foregroundColor(theme.textPrimary)
                }

                Section("Gateway Configuration") {
                    TextField("Host (e.g., api.openclaw.ai)", text: $editHost)
                        .foregroundColor(theme.textPrimary)
                        .textContentType(.URL)
                        .autocapitalization(.none)
                        .keyboardType(.URL)

                    TextField("Port", text: $editPort)
                        .foregroundColor(theme.textPrimary)
                        .keyboardType(.numberPad)

                    Toggle("Use TLS/SSL", isOn: $editTlsEnabled)
                        .foregroundColor(theme.textPrimary)
                }

                Section("Authentication") {
                    SecureField("Auth Token", text: $editToken)
                        .foregroundColor(theme.textPrimary)
                        .textContentType(.password)
                }

                Section {
                    HStack {
                        Button(action: isConnected ? disconnectConnection : testConnection) {
                            HStack {
                                Spacer()
                                if isTesting {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle())
                                    Text("Connecting...")
                                } else if isConnected {
                                    Image(systemName: "link.badge.plus")
                                    Text("Disconnect")
                                        .foregroundColor(.red)
                                } else {
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                    Text("Connect")
                                }
                                Spacer()
                            }
                        }
                        .disabled(isTesting)
                    }

                    if let result = testResult {
                        HStack(spacing: 4) {
                            Image(systemName: testStatus == TestStatus.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                            Text(result)
                        }
                        .font(.subheadline)
                        .foregroundColor(testStatus == TestStatus.success ? .green : .red)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        onDelete(profile.id)
                        dismiss()
                    } label: {
                        HStack {
                            Spacer()
                            Image(systemName: "trash")
                            Text("Delete Profile")
                            Spacer()
                        }
                        .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Save") {
                        let port = Int(editPort) ?? 443
                        onSave(editName, "#10A37F", editHost, port, editToken, editTlsEnabled)
                        dismiss()
                    }
                    .disabled(editName.isEmpty)
                }
            }
        }
    }
}
