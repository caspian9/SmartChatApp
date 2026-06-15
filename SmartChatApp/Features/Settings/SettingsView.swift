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
                Toggle("Collapse long messages", isOn: $config.collapseLongMessages)
                Toggle("Render markdown", isOn: $config.renderMarkdown)
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
                        await MessageCacheStore.shared.clearAll()
                        // BUG FIX: the previous version fired `clearAll`
                        // in a Task and returned immediately, so the
                        // on-screen "X messages (Y sessions)" row kept
                        // showing the pre-clear count. The user
                        // reported "the Clear Message Cache button
                        // doesn't work" because the count never went
                        // to 0. Re-read stats after the clear
                        // completes so the UI reflects the new
                        // (empty) state.
                        let stats = await MessageCacheStore.shared.stats()
                        await MainActor.run {
                            messageCacheStats = stats
                        }
                    }
                }
                .foregroundColor(.red)

                Button("Clear All Caches") {
                    SessionCache.clearAll()
                    sessionCacheCount = 0
                    Task {
                        await MessageCacheStore.shared.clearAll()
                        // See the comment on the "Clear Message Cache"
                        // button above: clearAll() is async (it
                        // hits the disk through the storage actor), so
                        // we have to await and re-read stats to
                        // refresh the message count row.
                        let stats = await MessageCacheStore.shared.stats()
                        await MainActor.run {
                            messageCacheStats = stats
                        }
                    }
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
        // Re-read stats on every appear. `.task` only fires on the
        // view's first appear (and on identity change); when the
        // user pops back from NativeChat — having switched sessions
        // and written new messages to disk — the existing `.task`
        // block does not re-run, and the "X messages (Y sessions)"
        // row shows the stale pre-visit count. `.onAppear` re-fires
        // every time the view enters the foreground (including
        // coming back from a push pop), so the count always
        // reflects the current on-disk state.
        .onAppear {
            Task { await loadCacheStats() }
        }
    }

    private func loadCacheStats() async {
        let count = SessionCache.totalSessionCount()
        // BUG FIX: the previous version only set `sessionCacheCount`
        // and left `messageCacheStats` at its default `(0, 0)`, so
        // the "Message Cache" row in the Cache section always read
        // "0 messages (0 sessions)" no matter how many messages the
        // user had cached. `MessageCacheStore.shared.stats()` reads
        // from disk across every persisted session (not just the
        // ones hydrated into memory), so the count reflects the
        // actual on-disk state.
        let messageStats = await MessageCacheStore.shared.stats()
        await MainActor.run {
            sessionCacheCount = count
            messageCacheStats = messageStats
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
    .preferredColorScheme(.dark)
}