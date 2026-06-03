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

    private var effectiveColorScheme: ColorScheme? {
        switch config.appearanceTheme {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    private var preferredScheme: ColorScheme? {
        switch config.appearanceTheme {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    private var currentTheme: Theme {
        Theme(colorScheme: effectiveColorScheme ?? .dark)
    }
}