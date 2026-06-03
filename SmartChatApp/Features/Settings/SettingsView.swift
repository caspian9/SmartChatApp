import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(\.theme) private var theme
    @StateObject private var config = ConfigurationManager.shared
    @State private var showNewProfile = false
    @State private var editingProfile: GatewayProfile?
    @State private var sessionCacheCount: Int = 0
    @State private var messageCacheStats: (sessionCount: Int, messageCount: Int) = (0, 0)

    private static let buildDate: Date = {
        return Date()
    }()

    private var buildDateString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Self.buildDate)
    }

    private var openClawVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                ProfileListView(showNewProfileSheet: $showNewProfile) { profile in
                    editingProfile = profile
                }

                DisclosureGroup("Advanced") {
                    Toggle("Auto-connect on Launch", isOn: $config.autoConnectOnLaunch)
                    Toggle("Gateway Debug Logs", isOn: $config.gatewayDebugLogs)
                        .onChange(of: config.gatewayDebugLogs) { _, newValue in
                            Task {
                                await SessionManager.shared.setDebugLoggingEnabled(newValue)
                            }
                        }
                    Toggle("Discovery Debug Logs", isOn: $config.discoveryDebugLogs)
                        .onChange(of: config.discoveryDebugLogs) { _, newValue in
                            Task {
                                await SessionManager.shared.setDiscoveryDebugLoggingEnabled(newValue)
                            }
                        }
                    NavigationLink("Discovery Logs") {
                        DiscoveryLogsView()
                    }
                }
            } header: {
                HStack {
                    Text("Gateway")
                    Spacer()
                    Button {
                        showNewProfile = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(.blue)
                            .font(.system(size: 18))
                    }
                }
            }

            Section("Device") {
                HStack {
                    Text("Name")
                    Spacer()
                    TextField("Device Name", text: $config.deviceDisplayName)
                        .multilineTextAlignment(.trailing)
                        .foregroundColor(theme.textSecondary)
                }

                HStack {
                    Text("Device ID")
                    Spacer()
                    Text("—")
                        .foregroundColor(theme.textSecondary)
                }
            }

            Section("Capabilities") {
                Toggle("Camera", isOn: $config.cameraEnabled)
                Toggle("Location", isOn: $config.locationEnabled)
                Toggle("Voice Wake", isOn: $config.voiceWakeEnabled)
            }

            Section("Appearance") {
                Picker("Theme", selection: $config.appearanceTheme) {
                    ForEach(AppearanceTheme.allCases, id: \.self) { theme in
                        Text(theme.rawValue).tag(theme)
                    }
                }
            }

            Section("Cache") {
                HStack {
                    Text("Session Cache")
                    Spacer()
                    Text("\(sessionCacheCount) sessions")
                        .foregroundColor(theme.textSecondary)
                }

                HStack {
                    Text("Message Cache")
                    Spacer()
                    Text("\(messageCacheStats.messageCount) messages (\(messageCacheStats.sessionCount) sessions)")
                        .foregroundColor(theme.textSecondary)
                }

                Button("Clear Session Cache") {
                    SessionCache.clear()
                    sessionCacheCount = 0
                }
                .foregroundColor(.red)

                Button("Clear Message Cache") {
                    Task {
                        await MessageCache.shared.clearAll()
                        await MainActor.run {
                            messageCacheStats = (0, 0)
                        }
                    }
                }
                .foregroundColor(.red)

                Button("Clear All Caches") {
                    SessionCache.clear()
                    Task {
                        await MessageCache.shared.clearAll()
                    }
                    sessionCacheCount = 0
                    messageCacheStats = (0, 0)
                }
                .foregroundColor(.red)
            }

            Section("About") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text("1.0.0")
                        .foregroundColor(theme.textSecondary)
                }

                HStack {
                    Text("Build")
                    Spacer()
                    Text(buildDateString)
                        .foregroundColor(theme.textSecondary)
                }
            }
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $showNewProfile) {
            ProfileEditSheet(profile: nil) { name, colorTag, host, port, token, tlsEnabled in
                _ = ProfileManager.shared.addProfile(name: name, colorTag: colorTag, host: host, port: port, token: token, tlsEnabled: tlsEnabled)
            }
        }
        .sheet(item: $editingProfile) { profile in
            EditProfileSheet(profile: profile) { name, colorTag, host, port, token, tlsEnabled in
                ProfileManager.shared.updateProfile(id: profile.id, name: name, colorTag: colorTag, host: host, port: port, token: token, tlsEnabled: tlsEnabled)
            } onDelete: { id in
                ProfileManager.shared.deleteProfile(id: id)
            }
        }
        .task {
            await SessionManager.shared.setDebugLoggingEnabled(config.gatewayDebugLogs)
            await SessionManager.shared.setDiscoveryDebugLoggingEnabled(config.discoveryDebugLogs)
            await loadCacheStats()
        }
    }

    private func loadCacheStats() async {
        if let cached = SessionCache.load() {
            await MainActor.run {
                sessionCacheCount = cached.count
            }
        }
        let stats = await MessageCache.shared.getStats()
        await MainActor.run {
            messageCacheStats = stats
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
    .preferredColorScheme(.dark)
}
