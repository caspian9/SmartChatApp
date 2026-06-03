import SwiftUI

struct ProfileListView: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var profileManager = ProfileManager.shared
    @State private var showDeleteAlert = false
    @State private var profileToDelete: GatewayProfile?

    // Edit state
    @State private var editingProfile: GatewayProfile?
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

    var body: some View {
        Group {
            if profileManager.profiles.isEmpty {
                emptyState
            } else {
                profileList
            }
        }
        .sheet(item: $editingProfile) { profile in
            EditProfileSheet(profile: profile) { name, colorTag, host, port, token, tlsEnabled in
                ProfileManager.shared.updateProfile(id: profile.id, name: name, colorTag: colorTag, host: host, port: port, token: token, tlsEnabled: tlsEnabled)
            } onDelete: { id in
                ProfileManager.shared.deleteProfile(id: id)
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

                Button {
                    editingProfile = profile
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
