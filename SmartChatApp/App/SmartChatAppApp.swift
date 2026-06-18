import SwiftUI

@main
struct SmartChatAppApp: App {
    @StateObject private var config = ConfigurationManager.shared

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

struct RootView: View {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var config = ConfigurationManager.shared
    @Bindable private var connectionState = ConnectionState.shared

    var body: some View {
        NavigationStack {
            HomeView()
        }
        .preferredColorScheme(preferredScheme)
        .environment(\.theme, currentTheme)
        .task {
            if config.autoConnectOnLaunch && ProfileManager.shared.activeProfile != nil {
                try? await SessionManager.shared.ensureConnected()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Safety net: when the app returns to the foreground after
            // the SDK's WebSocket dropped, kick a fresh connect attempt
            // so the UI doesn't get stuck on "Reconnecting..." with no
            // visible activity. Primary recovery is now `onConnected` in
            // `ConnectionCoordinator` (handles both foreground and
            // background reconnects); this handler covers the rare case
            // where the SDK never reconnects at all (e.g., permanent
            // network outage) so the user has to manually open the app
            // to retry.
            switch newPhase {
            case .background, .inactive:
                // Flush any pending debounced disk writes before
                // iOS suspends the process. Without this, a
                // streaming burst that's mid-debounce when the
                // user backgrounds the app can lose the last
                // ~100ms of writes (the in-memory cache survives,
                // but the disk does not — a crash or force-quit
                // would lose the streamed progress). The flush
                // is async; iOS gives us up to ~30s before
                // suspending, which is plenty for the JSON
                // encode + UserDefaults write to land. Calling
                // this when `pendingDiskWrites` is empty is a
                // no-op (the `for` loop over an empty set exits
                // immediately).
                AppLogger.log("scenePhase=\(newPhase == .background ? "background" : "inactive"); flushing pending disk writes", category: .cache)
                Task {
                    await MessageCacheStorage.shared.flushPendingWrites()
                }
            case .active:
                guard ProfileManager.shared.activeProfile != nil else { return }
                // Only act on .reconnecting — respect explicit user
                // disconnects (state == .disconnected) and in-flight
                // connects (state == .connecting).
                if case .reconnecting = ConnectionState.shared.phase {
                    AppLogger.log("App became active while reconnecting; triggering ensureConnected", category: .network)
                    Task {
                        do {
                            try await SessionManager.shared.ensureConnected()
                        } catch {
                            AppLogger.log("Foreground reconnect failed: \(error.localizedDescription)", category: .network, level: .error)
                        }
                    }
                }
            @unknown default:
                break
            }
        }
    }

    private var colorSchemeForTheme: ColorScheme {
        switch config.appearanceTheme {
        case .system:
            return systemColorScheme
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    private var preferredScheme: ColorScheme? {
        config.appearanceTheme == .system ? nil : colorSchemeForTheme
    }

    private var currentTheme: Theme {
        Theme(colorScheme: colorSchemeForTheme)
    }
}
