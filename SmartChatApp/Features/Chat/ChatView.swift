import SwiftUI
import OpenClawChatUI
import OpenClawKit

struct ChatView: View {
    let sessionKey: String
    @State private var viewModel: OpenClawChatViewModel
    @ObservedObject private var cardRegistry = CardRegistry.shared

    init(sessionKey: String, transport: any OpenClawChatTransport) {
        self.sessionKey = sessionKey
        _viewModel = State(initialValue: OpenClawChatViewModel(
            sessionKey: sessionKey,
            transport: transport,
            prefersExplicitThinkingLevel: false,
            onThinkingLevelChanged: nil
        ))
    }

    var body: some View {
        ZStack {
            OpenClawChatView(
                viewModel: viewModel,
                showsSessionSwitcher: false,
                style: .standard,
                markdownVariant: .standard,
                userAccent: Color(hex: "10A37F"),
                showsAssistantTrace: false
            )

            // Overlay cards for pending tool calls
            if !viewModel.pendingToolCalls.isEmpty {
                VStack {
                    Spacer()
                    PendingCardsView(toolCalls: viewModel.pendingToolCalls)
                        .padding()
                }
            }
        }
    }
}

struct PendingCardsView: View {
    let toolCalls: [OpenClawChatPendingToolCall]

    var body: some View {
        VStack(spacing: 8) {
            ForEach(toolCalls) { call in
                if let cardView = CardRegistry.shared.createCard(for: call.name, arguments: call.args) {
                    cardView
                } else {
                    PendingToolCallView(call: call)
                }
            }
        }
    }
}

struct PendingToolCallView: View {
    let call: OpenClawChatPendingToolCall

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)

            Text(displayName)
                .font(.footnote)
                .lineLimit(1)

            Spacer()
        }
        .padding(12)
        .background(Color.white.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var displayName: String {
        let display = ToolDisplayRegistry.resolve(name: call.name, args: call.args)
        return "\(display.emoji) \(display.label)"
    }
}

struct ToolCallCardView: View {
    let toolName: String
    let arguments: AnyCodable?

    var body: some View {
        if let cardView = CardRegistry.shared.createCard(for: toolName, arguments: arguments) {
            cardView
        } else {
            EmptyView()
        }
    }
}
