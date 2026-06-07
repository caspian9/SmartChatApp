import SwiftUI
import OpenClawKit

struct EditProfileSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let profile: GatewayProfile?
    let onSave: (String, String, String, Int, String, Bool, GatewayConnectionRole, Set<String>) -> Void
    let onDelete: ((UUID) -> Void)?
    let onCancel: (() -> Void)?

    @State private var editName: String = ""
    @State private var editColorTag: String = "#10A37F"
    @State private var editHost: String = ""
    @State private var editPort: String = "443"
    @State private var editToken: String = ""
    @State private var editTlsEnabled: Bool = true
    @State private var editRole: GatewayConnectionRole = .operatorAndNode
    @State private var editEnabledCaps: Set<String> = []
    @Bindable private var connectionState = ConnectionState.shared

    /// Caps exposed in the picker. `device` is intentionally omitted — it's
    /// always advertised by SessionManager regardless of profile state.
    /// `voiceWake` and `watch` are omitted too: neither maps to a `node.invoke`
    /// command set on iOS-as-node (voice wake is an in-app trigger; an iPhone
    /// is not a watch).
    private static let selectableCaps: [OpenClawCapability] = [
        .camera, .location, .screen, .canvas, .browser,
        .talk, .photos, .contacts, .calendar, .reminders, .motion,
    ]

    private func capLabel(_ cap: OpenClawCapability) -> String {
        switch cap {
        case .canvas: return "Canvas"
        case .browser: return "Browser"
        case .camera: return "Camera"
        case .screen: return "Screen"
        case .voiceWake: return "Voice Wake"
        case .talk: return "Talk"
        case .location: return "Location"
        case .device: return "Device"
        case .watch: return "Watch"
        case .photos: return "Photos"
        case .contacts: return "Contacts"
        case .calendar: return "Calendar"
        case .reminders: return "Reminders"
        case .motion: return "Motion"
        }
    }

    private var isConnectEnabled: Bool {
        !editHost.isEmpty && isValidHost && !isProfileConnecting
    }

    private var isDisconnectEnabled: Bool {
        isProfileConnected
    }

    private var isProfileConnecting: Bool {
        if case .connecting = connectionState.phase { return true }
        return false
    }

    private var isProfileConnected: Bool {
        if case .connected = connectionState.phase { return true }
        return false
    }

    private var isValidHost: Bool {
        let cleanHost = Self.cleanHost(editHost)
        guard !cleanHost.isEmpty else { return false }
        // Basic host validation: not empty, no spaces
        // Accept domain format (e.g., api.example.com) or IP format (e.g., 192.168.1.1)
        let domainPattern = "^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?(\\.[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?)+$"
        let ipPattern = "^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$"

        let domainRegex = try? NSRegularExpression(pattern: domainPattern, options: .caseInsensitive)
        let ipRegex = try? NSRegularExpression(pattern: ipPattern, options: .caseInsensitive)

        let range = NSRange(cleanHost.startIndex..., in: cleanHost)
        let isDomain = domainRegex?.firstMatch(in: cleanHost, options: [], range: range) != nil
        let isIP = ipRegex?.firstMatch(in: cleanHost, options: [], range: range) != nil

        return isDomain || isIP
    }

    private static func cleanHost(_ input: String) -> String {
        var host = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip scheme if present
        if host.hasPrefix("https://") {
            host = String(host.dropFirst(8))
        } else if host.hasPrefix("http://") {
            host = String(host.dropFirst(7))
        }
        // Strip trailing slash
        if host.hasSuffix("/") {
            host = String(host.dropLast())
        }
        return host
    }

    private var isNewProfile: Bool {
        profile == nil
    }

    private let colorOptions = ["#10A37F", "#3B82F6", "#F97316", "#EF4444", "#8B5CF6"]

    init(profile: GatewayProfile?, onSave: @escaping (String, String, String, Int, String, Bool, GatewayConnectionRole, Set<String>) -> Void, onDelete: ((UUID) -> Void)? = nil, onCancel: (() -> Void)? = nil) {
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
            _editRole = State(initialValue: profile.role)
            _editEnabledCaps = State(initialValue: profile.enabledCaps)
        }
    }

    private func testConnection() {
        guard !editHost.isEmpty else {
            AppLogger.log("Test connection aborted: host is empty", category: .network)
            return
        }
        guard isValidHost else {
            AppLogger.log("Test connection aborted: invalid host format", category: .network)
            return
        }

        let port = Int(editPort) ?? 443
        let cleanHost = Self.cleanHost(editHost)
        let url = SessionManager.shared.gatewayURL(host: cleanHost, port: port, tlsEnabled: editTlsEnabled)

        Task {
            do {
                try await SessionManager.shared.connectWithRole(gatewayURL: url, authToken: editToken, role: editRole, enabledCaps: editEnabledCaps)
            } catch {
                AppLogger.log("Test connection failed: \(error.localizedDescription)", category: .network, level: .error)
            }
        }
    }

    private func disconnectConnection() {
        Task {
            await SessionManager.shared.disconnect()
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

                    Picker("Role", selection: $editRole) {
                        ForEach(GatewayConnectionRole.allCases, id: \.self) { role in
                            Text(role.rawValue).tag(role)
                        }
                    }
                }

                Section("Capabilities") {
                    HStack {
                        Text("Device")
                            .foregroundColor(theme.textPrimary)
                        Spacer()
                        Text("always on")
                            .font(.caption)
                            .foregroundColor(theme.textSecondary)
                    }
                    ForEach(Self.selectableCaps, id: \.self) { cap in
                        Toggle(capLabel(cap), isOn: Binding(
                            get: { editEnabledCaps.contains(cap.rawValue) },
                            set: { isOn in
                                if isOn {
                                    editEnabledCaps.insert(cap.rawValue)
                                } else {
                                    editEnabledCaps.remove(cap.rawValue)
                                }
                            }
                        ))
                        .foregroundColor(theme.textPrimary)
                    }
                }

                Section("Authentication") {
                    SecureField("Auth Token", text: $editToken)
                        .foregroundColor(theme.textPrimary)
                        .textContentType(.password)
                }

                Section {
                    HStack {
                        Button(action: isProfileConnected ? disconnectConnection : testConnection) {
                            HStack {
                                Spacer()
                                if isProfileConnecting {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle())
                                    Text("Connecting...")
                                } else if isProfileConnected {
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
                        .disabled(isProfileConnecting)
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
                        let cleanHost = Self.cleanHost(editHost)
                        onSave(editName, editColorTag, cleanHost, port, editToken, editTlsEnabled, editRole, editEnabledCaps)
                        dismiss()
                    }
                    .disabled(editName.isEmpty)
                }
            }
        }
    }
}
