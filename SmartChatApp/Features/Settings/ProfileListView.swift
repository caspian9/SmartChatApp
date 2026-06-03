import SwiftUI
import SwiftData

struct ProfileListView: View {
    @Environment(\.theme) private var theme
    @Query(sort: \GatewayProfile.createdAt) private var profiles: [GatewayProfile]
    @State private var selectedProfile: GatewayProfile?
    @State private var showDeleteAlert = false
    @State private var profileToDelete: GatewayProfile?

    @Binding var showNewProfileSheet: Bool

    init(showNewProfileSheet: Binding<Bool> = .constant(false)) {
        _showNewProfileSheet = showNewProfileSheet
    }

    var body: some View {
        Group {
            if profiles.isEmpty {
                emptyState
            } else {
                profileList
            }
        }
        .sheet(item: $selectedProfile) { profile in
            ProfileEditSheet(profile: profile) { name, colorTag, host, port, token, tlsEnabled in
                ProfileManager.shared.updateProfile(profile, name: name, colorTag: colorTag, host: host, port: port, token: token, tlsEnabled: tlsEnabled)
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
                    ProfileManager.shared.deleteProfile(profile)
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
        ForEach(profiles) { profile in
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
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .contextMenu {
                Button {
                    selectedProfile = profile
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