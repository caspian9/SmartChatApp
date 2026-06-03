import SwiftUI
import OpenClawChatUI

public struct ChatCardOverlay<Content: View>: View {
    let content: Content
    @ObservedObject private var cardRegistry = CardRegistry.shared

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .overlay(
                CardOverlayView()
            )
    }
}

struct CardOverlayView: View {
    @ObservedObject private var cardRegistry = CardRegistry.shared
    @State private var pendingCards: [String: Any] = [:]

    var body: some View {
        // This is a placeholder - actual integration requires modifying OpenClawChatUI
        // or creating a custom transport that intercepts tool call events
        EmptyView()
    }
}

public struct ToolCallCardView: View {
    let toolName: String
    let arguments: AnyCodable?
    @ObservedObject private var cardRegistry = CardRegistry.shared

    public init(toolName: String, arguments: AnyCodable?) {
        self.toolName = toolName
        self.arguments = arguments
    }

    public var body: some View {
        if let cardView = cardRegistry.createCard(for: toolName, arguments: arguments) {
            cardView
        } else {
            EmptyView()
        }
    }
}
