import Foundation
import SwiftUI

@MainActor
final class CardRegistry: ObservableObject {
    static let shared = CardRegistry()

    private var cards: [String: (ToolCall) -> any CardView] = [:]

    private init() {
        registerDefaultCards()
    }

    private func registerDefaultCards() {
        cards["music_search"] = { toolCall in
            MusicCardContent(toolCall: toolCall)
        }
        cards["video_search"] = { toolCall in
            VideoCardContent(toolCall: toolCall)
        }
        cards["open_url"] = { toolCall in
            ButtonCardContent(toolCall: toolCall, actionTitle: "Open Link")
        }
        cards["image"] = { toolCall in
            ImageCardContent(toolCall: toolCall)
        }
    }

    func register(_ cardType: String, factory: @escaping (ToolCall) -> any CardView) {
        cards[cardType] = factory
    }

    @ViewBuilder
    func createCard(for toolCall: ToolCall) -> some View {
        if let factory = cards[toolCall.name] {
            factory(toolCall)
        } else {
            UnknownCardView(toolCall: toolCall)
        }
    }

    func canHandle(_ toolCall: ToolCall) -> Bool {
        cards[toolCall.name] != nil
    }
}

protocol CardView: View {
    var toolCall: ToolCall { get }
}

struct UnknownCardView: CardView {
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
