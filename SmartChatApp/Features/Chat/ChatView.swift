import SwiftUI
import OpenClawChatUI
import OpenClawKit

struct ChatView: View {
    let sessionKey: String
    @State private var viewModel: OpenClawChatViewModel
    private let transport: any OpenClawChatTransport
    private let onAppear: () -> Void

    init(sessionKey: String, transport: any OpenClawChatTransport, onAppear: @escaping () -> Void = {}) {
        self.sessionKey = sessionKey
        self.transport = transport
        self.onAppear = onAppear
        _viewModel = State(initialValue: OpenClawChatViewModel(
            sessionKey: sessionKey,
            transport: transport,
            onThinkingLevelChanged: nil
        ))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            OpenClawChatView(
                viewModel: viewModel,
                showsSessionSwitcher: false,
                style: .standard,
                markdownVariant: .standard,
                userAccent: Color(hex: "10A37F"),
                showsAssistantTrace: false
            )

            if !viewModel.pendingToolCalls.isEmpty {
                toolCallsOverlay
            }
        }
        .onAppear { onAppear() }
    }

    private var toolCallsOverlay: some View {
        VStack {
            Spacer()
            VStack(spacing: 8) {
                ForEach(viewModel.pendingToolCalls) { call in
                    PendingToolCallView(call: call)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 60)
        }
    }
}

struct PendingToolCallView: View {
    let call: OpenClawChatPendingToolCall

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(.white)

            Text(displayName)
                .font(.subheadline)
                .foregroundColor(.white)
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var displayName: String {
        let display = ToolDisplayRegistry.resolve(name: call.name, args: call.args)
        return "\(display.emoji) \(display.label)"
    }
}
