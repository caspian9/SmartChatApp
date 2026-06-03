import SwiftUI

struct ProfileListView: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var profileManager = ProfileManager.shared
    @State private var showDeleteAlert = false
    @State private var profileToDelete: GatewayProfile?

    @Binding var showNewProfileSheet: Bool
    let onEditProfile: (GatewayProfile) -> Void

    init(showNewProfileSheet: Binding<Bool> = .constant(false), onEditProfile: @escaping (GatewayProfile) -> Void = { _ in }) {
        _showNewProfileSheet = showNewProfileSheet
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
