import SwiftUI
import UIKit
import OpenClawKit

struct SettingsView: View {
    @Environment(\.theme) private var theme
    /// Custom back-button pop. The system-supplied back button is
    /// hidden and replaced with a custom button in the toolbar
    /// (see `.toolbar { ... }` below) so we can dim it while the
    /// destructive confirmation dialog is up — keeping the chevron
    /// visible avoids the "button disappears and reappears" jolt
    /// of `navigationBarBackButtonHidden(pendingClear != nil)`.
    @Environment(\.dismiss) private var dismiss
    @StateObject private var config = ConfigurationManager.shared
    @State private var editingProfile: GatewayProfile?
    @State private var isCreatingNew = false
    @State private var showProfileSheet = false
    @State private var sessionCacheCount: Int = 0
    @State private var messageCacheStats = MessageCacheStats(sessionCount: 0, messageCount: 0, oldestTimestamp: nil, newestTimestamp: nil)
    @State private var profileListRefresh: Bool = false
    /// Drives the destructive-action confirmation alert (issue #30).
    /// `nil` = no alert shown; non-nil = alert for that case.
    /// Set by each destructive button; cleared by Cancel / after
    /// the destructive button completes.
    @State private var pendingClear: PendingClearAction?
    @State private var chatDiagExpanded: Bool = false

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
                Toggle("Show thinking", isOn: $config.showThinking)
                Toggle("Show tool calls", isOn: $config.showToolCalls)
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
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(messageCacheStats.messageCount) messages (\(messageCacheStats.sessionCount) sessions)")
                            .foregroundColor(theme.textSecondary)
                        if let oldest = messageCacheStats.oldestTimestamp,
                           let newest = messageCacheStats.newestTimestamp {
                            Text("\(formatDate(oldest)) → \(formatDate(newest))")
                                .font(.caption2)
                                .foregroundColor(theme.textSecondary)
                        }
                    }
                }

                Button("Clear Session Cache") {
                    pendingClear = .sessionCache
                }
                .foregroundColor(.red)

                Button("Clear Message Cache") {
                    pendingClear = .messageCache
                }
                .foregroundColor(.red)

                Button("Clear All Caches") {
                    pendingClear = .allCaches
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
                Toggle("Raw Cache Dump", isOn: $config.logsChatMessagesCacheDump)
                    .padding(.leading, 16)
                Toggle("View Render Dump", isOn: $config.logsChatMessagesRenderDump)
                    .padding(.leading, 16)
                Toggle("History Dump", isOn: $config.logsNativeChatHistory)
                    .padding(.leading, 16)
                Toggle("Markdown Logs", isOn: $config.logsMarkdown)

                NavigationLink("Debug Logs Viewer") {
                    DebugLogsView()
                }

                Button("Clear Logs") {
                    pendingClear = .logs
                }
                .foregroundColor(.red)
            }
        }
        .navigationTitle("Settings")
        .toolbar {
            // Custom back button (issue #40 follow-up). The system
            // back button is hidden (`.navigationBarBackButtonHidden`
            // below) and replaced with a custom button in the
            // leading slot — so we can dim it via foreground color
            // and disable it while the destructive confirmation
            // dialog is up, instead of hiding it entirely. The
            // visual avoids the "button disappears and reappears"
            // jolt of toggling `.navigationBarBackButtonHidden` on
            // every `pendingClear` flip. `dismiss()` is provided by
            // the `@Environment(\.dismiss)` declared above; called
            // from a NavigationStack-pushed view it pops the
            // navigation stack (same effect as the system back
            // button).
            //
            // **Visual treatment while disabled.** Foreground color
            // swaps from `.tint` to `Color.secondary`, not
            // `.opacity(...)`. The opacity-fade approach grays the
            // chevron by alpha-blending it with the background (the
            // glyph becomes semi-transparent → it appears faded
            // and "washed out" against the navigation bar). The
            // color-swap keeps the glyph at full opacity and just
            // shifts its base hue from accent blue to system
            // secondary, which is a medium gray that adapts to
            // light/dark mode — the chevron stays visually present
            // (no jump) and clearly inactive. `Color.secondary` is
            // the iOS-native dimmed control color and is the same
            // shade SwiftUI uses for disabled toolbar buttons by
            // default.
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(pendingClear != nil)
                .foregroundStyle(pendingClear != nil ? Color.secondary : Color.accentColor)
            }

            // Persistent connection indicator (issue #35 follow-up).
            // The spinner lives in the navigation toolbar so it is
            // never destroyed by the Form/List row recycling — it is
            // continuously visible while any profile is connecting,
            // regardless of scroll state. The row button no longer
            // carries its own spinner (which was being torn down with
            // the row).
            ToolbarItem(placement: .topBarTrailing) {
                if case .connecting = ConnectionState.shared.phase,
                   let name = ProfileManager.shared.activeProfile?.name {
                    HStack(spacing: 6) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                            .controlSize(.small)
                        Text("Connecting to \(name)")
                            .font(.caption)
                            .foregroundColor(theme.textSecondary)
                    }
                }
            }
        }
        // Always hide the system back button — the leading
        // `ToolbarItem` above is the only back affordance on this
        // view, so we control its enabled/disabled state on
        // `pendingClear` flips (see the toolbar block).
        .navigationBarBackButtonHidden(true)
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
        // Destructive-action confirmation (issue #30 / #40).
        //
        // Replaced the system `.alert(item:)` with a custom
        // `ConfirmationDialog` overlay (issue #40). SwiftUI's
        // system alert is presented in a separate UIWindow above
        // the app's view hierarchy; on iOS 17/18 the hit-test
        // handoff after Cancel/Clear introduces a perceptible
        // scroll/pan lock on the Settings form. The
        // in-hierarchy overlay dismisses into the same hit-test
        // tree, so the form is ready for gestures immediately.
        //
        // The dialog source-of-truth is still `PendingClearAction`
        // — title and message come from the enum's computed
        // properties, so the existing 6 `PendingClearActionTests`
        // continue to pin the destructive-action copy. The
        // `.animation(_:value:)` drives only the card's
        // `.scale.combined(with: .opacity)` transition — the scrim
        // has no transition (intentional, see
        // `ConfirmationDialog.swift`) so it disappears on the next
        // frame after `pendingClear` flips to `nil`, leaving the
        // Settings form immediately ready for scroll/pan gestures.
        .overlay {
            if let action = pendingClear {
                ConfirmationDialog(
                    title: action.title,
                    message: action.message,
                    destructiveTitle: "Clear",
                    onConfirm: {
                        performClear(action)
                        pendingClear = nil
                    },
                    onCancel: {
                        pendingClear = nil
                    }
                )
            }
        }
        .animation(.easeInOut(duration: 0.18), value: pendingClear != nil)
        // Strict-modal guard for issue #40 follow-up: the only
        // clickable area while the destructive confirmation is up
        // is Cancel and Clear inside the dialog. Two layers cover
        // the rest:
        //   1. Custom back button (in `.toolbar` above) is
        //      `.disabled(pendingClear != nil)` and visually
        //      greyed (opacity 0.35) so the chevron stays in
        //      place — no "blink out / blink in" jolt when the
        //      dialog opens or closes.
        //   2. Scrim inside `ConfirmationDialog` (with
        //      `.contentShape(Rectangle())` and no
        //      `.onTapGesture`) absorbs taps on every other part
        //      of the screen — form rows, the rest of the screen.
        //
        // `pendingClear = nil` → button enables + opacity 1.0
        // + scrim removed → form is immediately interactive.
    }

    /// Executes the destructive action the user just confirmed.
    /// Mirrors the inline logic the buttons had before the
    /// confirmation flow was added (issue #30). The async re-read
    /// of `messageCacheStats` is required because
    /// `MessageCacheStore.clearAll()` is async on the storage
    /// actor — see the BUG FIX comment at the original button.
    ///
    /// Issue #48 (sub-item 4 of #36): the "fully empty cache"
    /// contract after a clear is broader than just wiping
    /// `MessageCacheStorage`. The view-layer caches
    /// (`CollapseStateCache.expandedMessageIds`,
    /// `shouldCollapseCache`, `safeHeightCache`; `MarkdownCache`)
    /// are also keyed on the now-gone messages and would leave
    /// orphaned entries — a user who manually expanded a bubble,
    /// then cleared the cache, would otherwise carry the old
    /// expanded-id set into the next session (those ids no longer
    /// match anything in `MessageCacheStorage`; harmless today
    /// because `MessageBubbleView.isUserExpanded` only checks
    /// membership, but it's a latent correctness drift). Cleared
    /// alongside the persistent storage on `.messageCache` and
    /// `.allCaches` to honor the contract; `.sessionCache` only
    /// touches session-list keys, not message data, so it does
    /// NOT clear them.
    private func performClear(_ action: PendingClearAction) {
        switch action {
        case .sessionCache:
            SessionCache.clearAll()
            sessionCacheCount = 0
        case .messageCache:
            Task { @MainActor in
                CollapseStateCache.shared.clear()
                MarkdownCache.shared.clear()
                await MessageCacheStore.shared.clearAll()
                let stats = await MessageCacheStore.shared.stats()
                messageCacheStats = stats
            }
        case .allCaches:
            SessionCache.clearAll()
            sessionCacheCount = 0
            Task { @MainActor in
                CollapseStateCache.shared.clear()
                MarkdownCache.shared.clear()
                await MessageCacheStore.shared.clearAll()
                let stats = await MessageCacheStore.shared.stats()
                messageCacheStats = stats
            }
        case .logs:
            AppLogger.shared.clear()
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

    /// Format a `MessageCacheStats` timestamp (milliseconds since
    /// epoch — see `MessageCacheStorage.append`'s tsBucket math:
    /// `tsBucket = Int64(ts / 10_000)`) into a short "MMM d"
    /// display string. Returns the formatted string. The
    /// milliseconds-to-seconds conversion is the divide-by-1000
    /// here; the SDK's timestamp unit is milliseconds.
    private func formatDate(_ timestamp: Double) -> String {
        let date = Date(timeIntervalSince1970: timestamp / 1000)
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
    .preferredColorScheme(.dark)
}