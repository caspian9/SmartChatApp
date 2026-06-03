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

enum Theme {
    static let background = Color(hex: "000000")
    static let cardBackground = Color(hex: "1E1E1E")
    static let userMessageBackground = Color(hex: "2E2E2E")
    static let assistantMessageBackground = Color(hex: "343541")
    static let primary = Color(hex: "10A37F")
    static let inputBackground = Color(hex: "40414F")
    static let textPrimary = Color(hex: "ECECF1")
    static let textSecondary = Color(hex: "ACACBE")

    static let cornerRadius: CGFloat = 12
    static let padding: CGFloat = 16
    static let spacing: CGFloat = 12
}
