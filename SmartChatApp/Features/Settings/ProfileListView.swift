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

    private var isAnyConnectInFlight: Bool {
        if case .connecting = connectionState.phase { return true }
        return false
    }

    private func isProfileConnecting(_ profile: GatewayProfile) -> Bool {
        switch (connectionState.phase, profile.role) {
        case (.connecting(let role), .operatorOnly): return role == .`operator`
        case (.connecting(let role), .nodeOnly): return role == .node
        case (.connecting(let role), .operatorAndNode): return role == .`operator` || role == .node
        default: return false
        }
    }

    private var profileList: some View {
        ForEach(profileManager.profiles) { profile in
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
                    Task {
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
                            ProfileManager.shared.activateProfile(profile)
                            do {
                                try await SessionManager.shared.connectWithProfile(profile)
                            } catch {
                                AppLogger.log("Connect failed: \(error)", category: .network)
                            }
                        }
                    }
                } label: {
                    ZStack {
                        if isProfileConnecting(profile) {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle())
                        }
                        let isThisActive = profileManager.activeProfile?.id == profile.id
                        let isConnected = { () -> Bool in
                            if case .connected = connectionState.phase { return true }
                            return false
                        }()
                        Text(isThisActive ? (isConnected ? "Disconnect" : "Connect") : "Switch")
                            .opacity(isProfileConnecting(profile) ? 0 : 1)
                    }
                }
                .font(.caption)
                .foregroundColor(theme.primary)
                .disabled(isAnyConnectInFlight)
                .buttonStyle(.bordered)
                .frame(height: 28)

                Button {
                    onEditProfile(profile)
                } label: {
                    Image(systemName: "pencil")
                        .font(.caption)
                        .foregroundColor(theme.primary)
                }
                .buttonStyle(.bordered)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
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
