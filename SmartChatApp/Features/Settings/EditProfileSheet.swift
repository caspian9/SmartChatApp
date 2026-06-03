import SwiftUI

struct EditProfileSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let profile: GatewayProfile?
    let onSave: (String, String, String, Int, String, Bool) -> Void
    let onDelete: ((UUID) -> Void)?
    let onCancel: (() -> Void)?

    @State private var editName: String = ""
    @State private var editColorTag: String = "#10A37F"
    @State private var editHost: String = ""
    @State private var editPort: String = "443"
    @State private var editToken: String = ""
    @State private var editTlsEnabled: Bool = true
    @State private var isTesting = false
    @State private var isConnected = false
    @State private var testResult: String?
    @State private var testStatus: TestStatus = .idle

    enum TestStatus {
        case idle, testing, success, failure, invalid
    }

    private var isConnectEnabled: Bool {
        !editHost.isEmpty && isValidHost && !isTesting && !isConnected
    }

    private var isDisconnectEnabled: Bool {
        isConnected && !isTesting
    }

    private var isValidHost: Bool {
        let host = editHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return false }
        // Basic host validation: not empty, no spaces
        // Accept domain format (e.g., api.example.com) or IP format (e.g., 192.168.1.1)
        let domainPattern = "^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?(\\.[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?)+$"
        let ipPattern = "^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$"

        let domainRegex = try? NSRegularExpression(pattern: domainPattern, options: .caseInsensitive)
        let ipRegex = try? NSRegularExpression(pattern: ipPattern, options: .caseInsensitive)

        let range = NSRange(host.startIndex..., in: host)
        let isDomain = domainRegex?.firstMatch(in: host, options: [], range: range) != nil
        let isIP = ipRegex?.firstMatch(in: host, options: [], range: range) != nil

        return isDomain || isIP
    }

    private var isNewProfile: Bool {
        profile == nil
    }

    private let colorOptions = ["#10A37F", "#3B82F6", "#F97316", "#EF4444", "#8B5CF6"]

    init(profile: GatewayProfile?, onSave: @escaping (String, String, String, Int, String, Bool) -> Void, onDelete: ((UUID) -> Void)? = nil, onCancel: (() -> Void)? = nil) {
        self.profile = profile
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
        if let profile = profile {
            _editName = State(initialValue: profile.name)
            _editColorTag = State(initialValue: profile.colorTag)
            _editHost = State(initialValue: profile.host)
            _editPort = State(initialValue: String(profile.port))
            _editToken = State(initialValue: profile.token)
            _editTlsEnabled = State(initialValue: profile.tlsEnabled)
        }
    }

    private func testConnection() {
        if editHost.isEmpty {
            testStatus = .invalid
            testResult = "Host is required"
            return
        }
        if !isValidHost {
            testStatus = .invalid
            testResult = "Invalid host format"
            return
        }

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

                    HStack {
                        Text("Color")
                        Spacer()
                        ForEach(colorOptions, id: \.self) { color in
                            Circle()
                                .fill(Color(hex: color))
                                .frame(width: 24, height: 24)
                                .overlay(
                                    Circle()
                                        .stroke(editColorTag == color ? Color.primary : Color.clear, lineWidth: 2)
                                )
                                .onTapGesture {
                                    editColorTag = color
                                }
                        }
                    }
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

                if !isNewProfile {
                    Section {
                        Button(role: .destructive) {
                            if let profile = profile {
                                onDelete?(profile.id)
                            }
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
            }
            .navigationTitle(isNewProfile ? "New Profile" : "Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel?()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Save") {
                        let port = Int(editPort) ?? 443
                        onSave(editName, editColorTag, editHost, port, editToken, editTlsEnabled)
                        dismiss()
                    }
                    .disabled(editName.isEmpty || editHost.isEmpty || editToken.isEmpty)
                }
            }
        }
    }
}
