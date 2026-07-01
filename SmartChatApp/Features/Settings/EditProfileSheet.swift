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
    @State private var isFailedFlashActive = false
    @State private var flashTask: Task<Void, Never>?
    /// Snapshot of the form fields as they were when the sheet
    /// opened (issue #29). For existing profiles this is the
    /// loaded `GatewayProfile`'s fields; for new profiles it's
    /// `nil` and we fall through to `ProfileFormSnapshot.empty`
    /// so the alert only fires on real edits.
    @State private var originalSnapshot: ProfileFormSnapshot?
    /// Drives the Save / Don't Save / Cancel alert when the user
    /// taps Cancel on a dirty form.
    @State private var showUnsavedChangesAlert: Bool = false
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
        // Gate on the active profile: only the active profile's
        // row should show the spinner. When the sheet is editing
        // a non-active or new profile, fall back to `.operatorAndNode`
        // (matches the `editRole` default) and let the ID-mismatch
        // path return false. Pure decision lives in
        // `ProfileConnectionState` for testability (issue #35).
        let activeId = ProfileManager.shared.activeProfile?.id
        let profileId = profile?.id ?? activeId
        let profileRole = profile?.role ?? .operatorAndNode
        guard let profileId else { return false }
        return ProfileConnectionState.isProfileConnecting(
            activeProfileId: activeId,
            profileId: profileId,
            profileRole: profileRole,
            phase: connectionState.phase
        )
    }

    private var isProfileConnected: Bool {
        if case .connected = connectionState.phase { return true }
        return false
    }

    private var isProfileFailed: Bool {
        if case .disconnected = connectionState.phase, connectionState.lastError != nil {
            return true
        }
        return false
    }

    /// True when the sheet is editing the profile that's currently
    /// `isActive` in `ProfileManager`. New profiles (`profile == nil`)
    /// are never "active" — they take the test path.
    private var isEditingActiveProfile: Bool {
        guard let profile = profile else { return false }
        return profile.id == ProfileManager.shared.activeProfile?.id
    }

    private var isValidHost: Bool {
        let cleanHost = Self.cleanHost(editHost)
        guard !cleanHost.isEmpty else { return false }
        // Basic host validation: not empty, no spaces
        // Accept domain format (e.g., api.example.com) or IP format (e.g., 192.168.1.1)
        //
        // The IP alternations are disjoint numeric ranges (see
        // matchesHost) so each octet has exactly one matching path.
        // The previous form had an ambiguous sub-pattern that
        // matched a single octet in several ways, and three
        // repetitions of that ambiguity produced exponential
        // backtracking on crafted input starting with "0.0"
        // repeated (flagged by CodeQL swift/redos, alert #1).
        // Disjoint ranges + literal dot separators cap the
        // engine's work at O(n).
        return Self.matchesHost(cleanHost)
    }

    /// Build a snapshot of the live form state. Reconstructed on
    /// every body re-eval (cheap — eight value copies), so the
    /// comparison against `originalSnapshot` always reflects the
    /// current edit buffer. Used by `hasUnsavedChanges` to drive
    /// the Save / Don't Save / Cancel alert (issue #29).
    private var currentSnapshot: ProfileFormSnapshot {
        ProfileFormSnapshot(
            name: editName,
            colorTag: editColorTag,
            host: editHost,
            port: Int(editPort) ?? 443,
            token: editToken,
            tlsEnabled: editTlsEnabled,
            role: editRole,
            enabledCaps: editEnabledCaps
        )
    }

    /// One-line forwarder to `ProfileFormSnapshot.hasUnsavedChanges`.
    /// `nil` original → new profile (baseline = `.empty`).
    /// `non-nil` original → existing profile (baseline = loaded snapshot).
    private var hasUnsavedChanges: Bool {
        ProfileFormSnapshot.hasUnsavedChanges(
            original: originalSnapshot,
            current: currentSnapshot
        )
    }

    /// Internal so `EditProfileSheetTests` can assert on the regex
    /// without spinning up a SwiftUI view. Kept fileprivate to the
    /// same module — the view is the only consumer in production.
    static func matchesHost(_ cleanHost: String) -> Bool {
        // Disjoint alternations: each label accepts `[a-zA-Z0-9-]*`
        // (no dots) so the inner repetition is unambiguous. The
        // previous form `[a-zA-Z0-9.-]*` allowed dots inside labels,
        // and combined with the outer `\\.[a-zA-Z0-9]...` repetition
        // gave CodeQL's ReDoS analyzer something to flag. The
        // disjoint form is also empirically fast (verified at 0.0000s
        // for 200-char "0." × 100 inputs).
        let domainPattern = "^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$"
        let ipPattern = "^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])(\\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])){3}$"
        guard !cleanHost.isEmpty else { return false }
        guard let domainRegex = try? NSRegularExpression(pattern: domainPattern, options: .caseInsensitive),
              let ipRegex = try? NSRegularExpression(pattern: ipPattern, options: .caseInsensitive) else {
            return false
        }
        let range = NSRange(cleanHost.startIndex..., in: cleanHost)
        return domainRegex.firstMatch(in: cleanHost, options: [], range: range) != nil
            || ipRegex.firstMatch(in: cleanHost, options: [], range: range) != nil
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
        // Capture the snapshot used by the unsaved-changes diff
        // (issue #29). For new profiles this stays `nil` and
        // `ProfileFormSnapshot.hasUnsavedChanges` falls through
        // to `.empty` — any user input on a new profile counts
        // as an edit.
        _originalSnapshot = State(
            initialValue: profile.map(ProfileFormSnapshot.init(from:))
        )
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

    /// Test path used when the sheet is editing a non-active profile (or
    /// a brand-new profile). Probes connectivity via
    /// `SessionManager.testConnect`, which sets `state.testInProgress` /
    /// `state.testLastResult` instead of mutating the main `state.phase`.
    private func runTestConnection() {
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
                try await SessionManager.shared.testConnect(
                    gatewayURL: url,
                    authToken: editToken,
                    role: editRole,
                    enabledCaps: editEnabledCaps
                )
            } catch {
                // testConnect already updates state.testLastResult; just log here.
                AppLogger.log("Test connection failed: \(error.localizedDescription)", category: .network, level: .error)
            }
        }
    }

    private func disconnectConnection() {
        Task {
            await SessionManager.shared.disconnect()
        }
    }

    /// Called from the Cancel toolbar button (issue #29). If the
    /// form is clean, dismiss immediately. If dirty, present the
    /// Save / Don't Save / Cancel alert so the user can't lose
    /// edits by accident. The swipe-down / outside-tap paths are
    /// handled separately by `.interactiveDismissDisabled`
    /// below — they're silently blocked when dirty, so the user
    /// is forced through the alert (the standard iOS pattern for
    /// dirty-form sheets).
    private func requestDismiss() {
        if hasUnsavedChanges {
            showUnsavedChangesAlert = true
        } else {
            onCancel?()
            dismiss()
        }
    }

    /// Commit + dismiss. Used by both the toolbar Save button and
    /// the alert's Save option (so the user can commit from either
    /// path). The view-side cleanups (parent state reset via
    /// `onCancel`) are NOT called here — `onSave` is the parent's
    /// success path and resets its own state.
    private func saveAndDismiss() {
        let port = Int(editPort) ?? 443
        let cleanHost = Self.cleanHost(editHost)
        onSave(
            editName, editColorTag, cleanHost, port, editToken,
            editTlsEnabled, editRole, editEnabledCaps
        )
        dismiss()
    }

    /// Connect / Disconnect button for the sheet when it's editing the
    /// currently-active profile. Uses the main `state.phase` and flashes
    /// "Failed" for 1s when `state.lastError` flips to a non-nil value.
    @ViewBuilder
    private var activeProfileButtonSection: some View {
        HStack {
            Button(action: isProfileConnected ? disconnectConnection : testConnection) {
                HStack {
                    Spacer()
                    if isFailedFlashActive {
                        Text("Failed").foregroundColor(.red)
                    } else if isProfileConnecting {
                        // `.id(isProfileConnecting)` forces a fresh
                        // ProgressView on each true→false→true
                        // transition so the spinner's animation
                        // timer can't pause across refreshes
                        // (issue #35).
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                            .id(isProfileConnecting)
                        Text("Connecting...")
                    } else if isProfileConnected {
                        Image(systemName: "link.badge.plus")
                        Text("Disconnect").foregroundColor(.red)
                    } else {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                        Text("Connect")
                    }
                    Spacer()
                }
            }
            .disabled(isProfileConnecting)
        }
        if let error = connectionState.lastError, isProfileFailed {
            Text(error)
                .font(.caption)
                .foregroundColor(.red)
                .lineLimit(3)
        }
    }

    /// "Test Connection" button for the sheet when it's editing a
    /// non-active profile (or a brand-new one). Uses `testConnect` so the
    /// main `state.phase` is left alone. Reads `testInProgress` /
    /// `testLastResult` to surface the outcome.
    @ViewBuilder
    private var testConnectionButtonSection: some View {
        HStack {
            Button(action: runTestConnection) {
                HStack {
                    Spacer()
                    if connectionState.testInProgress {
                        ProgressView().progressViewStyle(CircularProgressViewStyle())
                        Text("Testing...")
                    } else if case .success = connectionState.testLastResult {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Test Passed").foregroundColor(.green)
                    } else if case .failure = connectionState.testLastResult {
                        Image(systemName: "xmark.circle.fill")
                        Text("Test Failed").foregroundColor(.red)
                    } else {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                        Text("Test Connection")
                    }
                    Spacer()
                }
            }
            .disabled(connectionState.testInProgress || !isConnectEnabled)
        }
        if case .failure(let reason) = connectionState.testLastResult {
            Text(reason)
                .font(.caption)
                .foregroundColor(.red)
                .lineLimit(3)
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
                    if isEditingActiveProfile {
                        activeProfileButtonSection
                    } else {
                        testConnectionButtonSection
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
            // Block the swipe-down / outside-tap dismiss paths when
            // the form is dirty (issue #29). The user must go
            // through the Cancel button → alert (or Save), so we
            // never silently lose edits.
            .interactiveDismissDisabled(hasUnsavedChanges)
            .alert("Unsaved Changes", isPresented: $showUnsavedChangesAlert) {
                Button("Save") { saveAndDismiss() }
                Button("Don't Save", role: .destructive) {
                    onCancel?()
                    dismiss()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("You have unsaved changes. Save them, discard them, or keep editing.")
            }
            .onChange(of: connectionState.lastError) { _, newError in
                guard isEditingActiveProfile else { return }
                flashTask?.cancel()
                guard newError != nil else { return }
                flashTask = Task {
                    isFailedFlashActive = true
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if !Task.isCancelled {
                        isFailedFlashActive = false
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Routed through `requestDismiss` so the
                    // unsaved-changes alert fires on a dirty
                    // form (issue #29). Clean forms dismiss
                    // immediately, as before.
                    Button("Cancel", action: requestDismiss)
                }
                ToolbarItem(placement: .primaryAction) {
                    // Routed through `saveAndDismiss` so the
                    // alert's Save button and the toolbar Save
                    // button share one commit+dismiss path.
                    Button("Save", action: saveAndDismiss)
                        .disabled(editName.isEmpty)
                }
            }
        }
    }
}
