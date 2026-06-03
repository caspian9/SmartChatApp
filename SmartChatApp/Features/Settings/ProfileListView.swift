import SwiftUI

struct ProfileListView: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var profileManager = ProfileManager.shared
    @State private var showDeleteAlert = false
    @State private var profileToDelete: GatewayProfile?

    // Edit state
    @State private var isEditing = false
    @State private var editingProfileId: UUID?
    @State private var editName = ""
    @State private var editHost = ""
    @State private var editPort = "443"
    @State private var editToken = ""
    @State private var editTlsEnabled = true
    @State private var isTesting = false
    @State private var isConnected = false
    @State private var testResult: String?
    @State private var testStatus: TestStatus = .idle

    enum TestStatus {
        case idle, testing, success, failure
    }

    @Binding var showNewProfileSheet: Bool

    init(showNewProfileSheet: Binding<Bool> = .constant(false)) {
        _showNewProfileSheet = showNewProfileSheet
    }

    private func startEditing(_ profile: GatewayProfile) {
        editingProfileId = profile.id
        editName = profile.name
        editHost = profile.host
        editPort = String(profile.port)
        editToken = profile.token
        editTlsEnabled = profile.tlsEnabled
        isEditing = true
        checkConnectionStatus()
    }

    private func checkConnectionStatus() {
        Task {
            let connected = await SessionManager.shared.connectionStatus
            await MainActor.run {
                isConnected = connected
            }
        }
    }

    private func saveEdit() {
        guard let id = editingProfileId,
              let portInt = Int(editPort) else { return }
        ProfileManager.shared.updateProfile(id: id, name: editName, colorTag: "#10A37F", host: editHost, port: portInt, token: editToken, tlsEnabled: editTlsEnabled)
        isEditing = false
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
        Group {
            if profileManager.profiles.isEmpty {
                emptyState
            } else {
                profileList
            }
        }
        .sheet(isPresented: $isEditing) {
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
                            .disabled(editHost.isEmpty || editToken.isEmpty || isTesting)
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
                        Button("Save") {
                            saveEdit()
                        }
                        .disabled(editName.isEmpty || editHost.isEmpty || editToken.isEmpty)
                    }
                }
                .navigationTitle("Edit Profile")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            isEditing = false
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showNewProfileSheet) {
            ProfileEditSheet(profile: nil) { name, colorTag, host, port, token, tlsEnabled in
                _ = ProfileManager.shared.addProfile(name: name, colorTag: colorTag, host: host, port: port, token: token, tlsEnabled: tlsEnabled)
            }
        }
        .alert("Delete Profile", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                if let profile = profileToDelete {
                    ProfileManager.shared.deleteProfile(id: profile.id)
                }
            }
        } message: {
            Text("Are you sure you want to delete this profile?")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("No Gateway Profiles")
                .font(.headline)
                .foregroundColor(theme.textPrimary)
            Text("Add a profile to connect to a Gateway")
                .font(.subheadline)
                .foregroundColor(theme.textSecondary)
            Button {
                showNewProfileSheet = true
            } label: {
                Label("Add Profile", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private var profileList: some View {
        ForEach(profileManager.profiles) { profile in
            HStack(spacing: 12) {
                Circle()
                    .fill(Color(hex: profile.colorTag))
                    .frame(width: 12, height: 12)

                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                        .font(.subheadline)
                        .foregroundColor(theme.textPrimary)
                        .lineLimit(1)
                    Text(profile.host)
                        .font(.caption)
                        .foregroundColor(theme.textSecondary)
                        .lineLimit(1)
                }

                Spacer()

                if profile.isActive {
                    Image(systemName: "checkmark")
                        .foregroundColor(theme.primary)
                }

                Button {
                    Task {
                        await ProfileManager.shared.switchToProfile(profile)
                    }
                } label: {
                    Text(profile.isActive ? "Reconnect" : "Connect")
                        .font(.caption)
                        .foregroundColor(theme.primary)
                }
                .buttonStyle(.bordered)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .contextMenu {
                Button {
                    startEditing(profile)
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    profileToDelete = profile
                    showDeleteAlert = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }
}
