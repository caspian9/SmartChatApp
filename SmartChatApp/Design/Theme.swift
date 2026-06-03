import SwiftUI

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

struct Theme {
    let colorScheme: ColorScheme

    var background: Color {
        colorScheme == .dark ? Color(hex: "000000") : Color(hex: "F6F6F6")
    }

    var cardBackground: Color {
        colorScheme == .dark ? Color(hex: "1E1E1E") : Color.white
    }

    var userMessageBackground: Color {
        colorScheme == .dark ? Color(hex: "2E2E2E") : Color(hex: "E8F5E9")
    }

    var assistantMessageBackground: Color {
        colorScheme == .dark ? Color(hex: "343541") : Color(hex: "F0F0F0")
    }

    var primary: Color {
        Color(hex: "10A37F")
    }

    var inputBackground: Color {
        colorScheme == .dark ? Color(hex: "40414F") : Color(hex: "EEEEEE")
    }

    var textPrimary: Color {
        colorScheme == .dark ? Color(hex: "ECECF1") : Color(hex: "1F1F1F")
    }

    var textSecondary: Color {
        colorScheme == .dark ? Color(hex: "ACACBE") : Color(hex: "666666")
    }

    static let cornerRadius: CGFloat = 12
    static let padding: CGFloat = 16
    static let spacing: CGFloat = 12
}

struct ThemeKey: EnvironmentKey {
    static let defaultValue: Theme = Theme(colorScheme: .dark)
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

extension View {
    func withTheme(_ colorScheme: ColorScheme) -> some View {
        let theme = Theme(colorScheme: colorScheme)
        return self.environment(\.theme, theme)
    }
}