import Foundation
import SwiftUI

@MainActor
final class CardRegistry: ObservableObject {
    static let shared = CardRegistry()

    private init() {}

    @ViewBuilder
    func createCard(for toolCall: ToolCall) -> some View {
        switch toolCall.name {
        case "music_search":
            MusicCardContent(toolCall: toolCall)
        case "video_search":
            VideoCardContent(toolCall: toolCall)
        case "open_url":
            ButtonCardContent(toolCall: toolCall, actionTitle: "Open Link")
        case "image":
            ImageCardContent(toolCall: toolCall)
        default:
            UnknownCardView(toolCall: toolCall)
        }
    }

    func canHandle(_ toolCall: ToolCall) -> Bool {
        ["music_search", "video_search", "open_url", "image"].contains(toolCall.name)
    }
}

struct UnknownCardView: View {
    let toolCall: ToolCall

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Unknown Tool: \(toolCall.name)")
                .font(.headline)
                .foregroundColor(.white)

            Text(toolCall.arguments)
                .font(.caption)
                .foregroundColor(.gray)
                .padding(8)
                .background(Color.black.opacity(0.3))
                .cornerRadius(8)
        }
        .padding()
        .background(Color.gray.opacity(0.2))
        .cornerRadius(12)
    }
}

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
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }
}
