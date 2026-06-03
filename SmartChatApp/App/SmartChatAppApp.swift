import SwiftUI

@main
struct SmartChatAppApp: App {
    @StateObject private var config = ConfigurationManager.shared
    @Environment(\.colorScheme) private var systemColorScheme

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                HomeView()
            }
            .preferredColorScheme(preferredScheme)
            .environment(\.theme, currentTheme)
        }
    }

    private var effectiveColorScheme: ColorScheme {
        switch config.appearanceTheme {
        case .system:
            return systemColorScheme ?? .dark
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
        Theme(colorScheme: effectiveColorScheme)
    }
}