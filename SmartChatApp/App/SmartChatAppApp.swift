import SwiftUI

@main
struct SmartChatAppApp: App {
    @StateObject private var config = ConfigurationManager.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .onAppear {
                    ProfileManager.shared.migrateFromLegacyConfig()
                }
        }
    }
}

struct RootView: View {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var systemColorScheme
    @StateObject private var config = ConfigurationManager.shared

    var body: some View {
        NavigationStack {
            HomeView()
        }
        .preferredColorScheme(preferredScheme)
        .environment(\.theme, currentTheme)
        .task {
            if config.autoConnectOnLaunch && config.isConfigured {
                try? await SessionManager.shared.ensureConnected()
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
