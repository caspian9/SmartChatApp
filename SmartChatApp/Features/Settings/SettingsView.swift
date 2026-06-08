import SwiftUI
import UIKit
import OpenClawKit

struct SettingsView: View {
    @Environment(\.theme) private var theme
    @StateObject private var config = ConfigurationManager.shared
    @State private var editingProfile: GatewayProfile?
    @State private var isCreatingNew = false
    @State private var showProfileSheet = false
    @State private var sessionCacheCount: Int = 0
    @State private var messageCacheStats: (sessionCount: Int, messageCount: Int) = (0, 0)
    @State private var profileListRefresh: Bool = false

    /// App version + build display, read from the installed bundle.
    ///
    /// `CFBundleShortVersionString` (MARKETING_VERSION in
    /// config/Version.xcconfig) and `CFBundleVersion` (CURRENT_PROJECT_VERSION,
    /// populated at build time by scripts/inject-build-timestamp.sh) come
    /// from the Info.plist embedded in the .app.
    ///
    /// `SMARTCHATAPPGitSHA` is a non-standard Info.plist key injected via
    /// the `$(SMARTCHATAPP_GIT_SHA)` xcconfig placeholder. It's used for
    /// dev-only display (Settings → About) and never reaches CFBundleVersion
    /// — that field must stay a pure integer for App Store Connect.
    ///
    /// Reading from the bundle (instead of `Date()`) means the value is
    /// stable across cold restarts: it reflects when the .app was built,
    /// not when the user launched it.
    private struct AppVersion {
        let marketing: String
        let build: String

        static let current: AppVersion = {
            let info = Bundle.main.infoDictionary
            let marketing = info?["CFBundleShortVersionString"] as? String ?? "0.0.1"
            let buildNumber = info?["CFBundleVersion"] as? String ?? "0"
            let rawSha = info?["SMARTCHATAPPGitSHA"] as? String ?? ""
            let sha = rawSha.isEmpty ? nil : rawSha
            return AppVersion(
                marketing: marketing,
                build: formatBuild(buildNumber: buildNumber, sha: sha)
            )
        }()

        /// Build a human-readable build string.
        ///
        /// - Debug: include the SHA so devs can tell "I built 5 min ago"
        ///   from "I built before the last commit" at a glance.
        /// - Release: show only the integer — users get the Apple-mandated
        ///   build number, no internal info leaks.
        private static func formatBuild(buildNumber: String, sha: String?) -> String {
            #if DEBUG
            if let sha = sha {
                return "\(buildNumber).\(sha)"
            }
            return "\(buildNumber) (local)"
            #else
            _ = sha
            return buildNumber
            #endif
        }
    }

    var body: some View {
        Form {
            Section {
                ProfileListView(showNewProfileSheet: $isCreatingNew, refreshTrigger: profileListRefresh) { profile in
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
                        isCreatingNew = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(.blue)
                            .font(.system(size: 18))
                    }
                }
            }

            Section("Device") {
                HStack {
                    Text("App Name")
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String ?? "SmartChatApp")
                        .foregroundColor(theme.textSecondary)
                }

                HStack {
                    Text("Model")
                    Spacer()
                    Text(UIDevice.current.model)
                        .foregroundColor(theme.textSecondary)
                }

                HStack {
                    Text("System")
                    Spacer()
                    Text(UIDevice.current.systemName + " " + UIDevice.current.systemVersion)
                        .foregroundColor(theme.textSecondary)
                }

                HStack {
                    Text("Device ID")
                    Spacer()
                    Text(String(DeviceIdentityStore.loadOrCreate().deviceId.prefix(16)))
                        .foregroundColor(theme.textSecondary)
                }
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
                    SessionCache.clearAll()
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
                    SessionCache.clearAll()
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
                    Text(AppVersion.current.marketing)
                        .foregroundColor(theme.textSecondary)
                }

                HStack {
                    Text("Build")
                    Spacer()
                    Text(AppVersion.current.build)
                        .foregroundColor(theme.textSecondary)
                }
            }

            Section("Debug & Logs") {
                Toggle("Network Logs", isOn: $config.logsNetwork)
                Toggle("Cache Logs", isOn: $config.logsCache)
                Toggle("NativeChat Logs", isOn: $config.logsNativeChat)
                Toggle("Markdown Logs", isOn: $config.logsMarkdown)

                NavigationLink("Debug Logs Viewer") {
                    DebugLogsView()
                }

                Button("Clear Logs") {
                    AppLogger.shared.clear()
                }
                .foregroundColor(.red)
            }
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $showProfileSheet) {
            EditProfileSheet(profile: editingProfile) { name, colorTag, host, port, token, tlsEnabled, role, enabledCaps in
                if let profile = editingProfile {
                    ProfileManager.shared.updateProfile(id: profile.id, name: name, colorTag: colorTag, host: host, port: port, token: token, tlsEnabled: tlsEnabled, role: role, enabledCaps: enabledCaps)
                } else {
                    _ = ProfileManager.shared.addProfile(name: name, colorTag: colorTag, host: host, port: port, token: token, tlsEnabled: tlsEnabled, role: role, enabledCaps: enabledCaps)
                }
            } onDelete: { id in
                ProfileManager.shared.deleteProfile(id: id)
            } onCancel: {
                editingProfile = nil
                isCreatingNew = false
            }
        }
        .onChange(of: isCreatingNew) { _, newValue in
            if newValue {
                editingProfile = nil
                showProfileSheet = true
            }
        }
        .onChange(of: editingProfile) { _, newValue in
            if newValue != nil {
                showProfileSheet = true
            }
        }
        .onChange(of: showProfileSheet) { _, newValue in
            if !newValue {
                editingProfile = nil
                isCreatingNew = false
                profileListRefresh.toggle()
            }
        }
        .task {
            await SessionManager.shared.setDebugLoggingEnabled(config.gatewayDebugLogs)
            await SessionManager.shared.setDiscoveryDebugLoggingEnabled(config.discoveryDebugLogs)
            await loadCacheStats()
        }
    }

    private func loadCacheStats() async {
        let count = SessionCache.totalSessionCount()
        await MainActor.run {
            sessionCacheCount = count
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