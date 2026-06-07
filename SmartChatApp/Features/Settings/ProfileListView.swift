import SwiftUI

struct ProfileListView: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var profileManager = ProfileManager.shared
    @Bindable private var connectionState = ConnectionState.shared
    @State private var showDeleteAlert = false
    @State private var profileToDelete: GatewayProfile?

    @Binding var showNewProfileSheet: Bool
    var refreshTrigger: Bool

    let onEditProfile: (GatewayProfile) -> Void

    init(showNewProfileSheet: Binding<Bool> = .constant(false), refreshTrigger: Bool = false, onEditProfile: @escaping (GatewayProfile) -> Void = { _ in }) {
        _showNewProfileSheet = showNewProfileSheet
        self.refreshTrigger = refreshTrigger
        self.onEditProfile = onEditProfile
    }

    var body: some View {
        Group {
            if profileManager.profiles.isEmpty {
                emptyState
            } else {
                profileList
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
        Text("Add a profile via the + button above")
            .font(.subheadline)
            .foregroundColor(theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var profileList: some View {
        ForEach(profileManager.profiles) { profile in
            ProfileRow(
                profile: profile,
                isActive: profileManager.activeProfile?.id == profile.id,
                isConnecting: isProfileConnecting(profile),
                isConnected: isProfileConnected,
                isButtonDisabled: isButtonDisabled(for: profile),
                onButtonTap: { await handleButtonTap(for: profile) },
                onEdit: { onEditProfile(profile) },
                onRequestDelete: {
                    profileToDelete = profile
                    showDeleteAlert = true
                }
            )
        }
    }

    private var isProfileConnected: Bool {
        if case .connected = connectionState.phase { return true }
        return false
    }

    private func isProfileConnecting(_ profile: GatewayProfile) -> Bool {
        // Spinner should only appear on the active profile's row — non-active
        // rows must remain clickable so the user can click "Switch" to
        // cancel the in-flight attempt and switch to a different profile.
        guard profileManager.activeProfile?.id == profile.id else { return false }
        switch (connectionState.phase, profile.role) {
        case (.connecting(let role), .operatorOnly): return role == .`operator`
        case (.connecting(let role), .nodeOnly): return role == .node
        case (.connecting(let role), .operatorAndNode): return role == .`operator` || role == .node
        default: return false
        }
    }

    private func isButtonDisabled(for profile: GatewayProfile) -> Bool {
        let isActive = profileManager.activeProfile?.id == profile.id
        return isActive && isProfileConnecting(profile)
    }

    private func handleButtonTap(for profile: GatewayProfile) async {
        if profile.isActive {
            if case .connected = connectionState.phase {
                await SessionManager.shared.disconnect()
            } else {
                do {
                    try await SessionManager.shared.connectWithProfile(profile)
                } catch {
                    AppLogger.log("Connect failed: \(error)", category: .network)
                }
            }
        } else {
            // Disconnect current, then activate + connect new.
            // `switchToProfile` is the canonical flow: it disconnects
            // any live connection first, then activates + connects,
            // so the button never briefly shows "Disconnect" for a
            // profile that isn't actually connected yet.
            await ProfileManager.shared.switchToProfile(profile)
        }
    }
}

/// Single profile row. Owns its own `isFailedFlashActive` so a failed
/// connect flashes only this row (not all rows in the list). `lastError`
/// is only set for the active profile's connect attempt, so the row
/// gates the flash on `isActive` defensively.
private struct ProfileRow: View {
    @Environment(\.theme) private var theme
    @Bindable private var connectionState = ConnectionState.shared

    let profile: GatewayProfile
    let isActive: Bool
    let isConnecting: Bool
    let isConnected: Bool
    let isButtonDisabled: Bool
    let onButtonTap: () async -> Void
    let onEdit: () -> Void
    let onRequestDelete: () -> Void

    @State private var isFailedFlashActive = false
    @State private var flashTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color(hex: profile.colorTag))
                .frame(width: 12, height: 12)

            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .font(.body)
                    .fontWeight(.medium)
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
                Task { await onButtonTap() }
            } label: {
                ZStack {
                    if isConnecting {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                    }
                    if isFailedFlashActive {
                        Text("Failed")
                            .foregroundColor(.red)
                    }
                    Text(isActive ? (isConnected ? "Disconnect" : "Connect") : "Switch")
                        .opacity((isConnecting || isFailedFlashActive) ? 0 : 1)
                }
            }
            .font(.caption)
            .foregroundColor(theme.primary)
            .disabled(isButtonDisabled)
            .buttonStyle(.bordered)
            .frame(height: 28)

            Button {
                onEdit()
            } label: {
                Image(systemName: "pencil")
                    .font(.caption)
                    .foregroundColor(theme.primary)
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onChange(of: connectionState.lastError) { _, newError in
            // lastError is set for the active profile's connect attempt;
            // gate the flash on isActive so non-active rows can never
            // flash (e.g., if a stale value lingers across a switch).
            guard isActive else { return }
            flashTask?.cancel()
            if newError == nil {
                // A new connect attempt is starting (setConnecting clears
                // lastError), or a successful connect cleared it. Either
                // way, the previous failure is no longer the current
                // state — clear the flash so the spinner / "Connect" /
                // "Disconnect" label can take over. Without this, an
                // auto-retry that succeeds leaves the row stuck on
                // "Failed" because the cancelled flashTask never resets
                // the flag.
                isFailedFlashActive = false
                return
            }
            flashTask = Task {
                isFailedFlashActive = true
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if !Task.isCancelled {
                    isFailedFlashActive = false
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                onRequestDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}
