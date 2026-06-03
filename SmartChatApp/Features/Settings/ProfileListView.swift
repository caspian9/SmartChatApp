import SwiftUI

struct ProfileListView: View {
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \GatewayProfile.createdAt) private var profiles: [GatewayProfile]
    @State private var showEditSheet = false
    @State private var editingProfile: GatewayProfile?
    @State private var showDeleteAlert = false
    @State private var profileToDelete: GatewayProfile?

    private let colorOptions = ["#10A37F", "#3B82F6", "#F97316", "#EF4444", "#8B5CF6"]

    var body: some View {
        Group {
            if profiles.isEmpty {
                emptyState
            } else {
                profileList
            }
        }
        .sheet(isPresented: $showEditSheet) {
            ProfileEditSheet(profile: editingProfile) { name, colorTag, host, port, token, tlsEnabled in
                if let profile = editingProfile {
                    ProfileManager.shared.updateProfile(profile, name: name, colorTag: colorTag, host: host, port: port, token: token, tlsEnabled: tlsEnabled)
                }
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
                editingProfile = nil
                showEditSheet = true
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
                    Text(profile.host)
                        .font(.caption)
                        .foregroundColor(theme.textSecondary)
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
                    Text("Connect")
                        .font(.caption)
                        .foregroundColor(theme.primary)
                }
                .disabled(profile.isActive)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .contextMenu {
                Button {
                    editingProfile = profile
                    showEditSheet = true
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
