import SwiftUI
import OpenClawChatUI
import OpenClawKit

struct ChatView: View {
    let sessionKey: String
    @State private var viewModel: OpenClawChatViewModel
    @State private var isDisconnecting = false

    init(sessionKey: String, transport: any OpenClawChatTransport) {
        self.sessionKey = sessionKey
        _viewModel = State(initialValue: OpenClawChatViewModel(
            sessionKey: sessionKey,
            transport: transport,
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
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: disconnectSession) {
                    if isDisconnecting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Disconnect")
                            .foregroundColor(.red)
                    }
                }
                .disabled(isDisconnecting)
            }
        }
    }

    private func disconnectSession() {
        isDisconnecting = true
        Task {
            if let transport = viewModel.transport as? GatewayChatTransport {
                await transport.disconnect()
            }
            await MainActor.run {
                isDisconnecting = false
            }
        }
    }
}

struct PendingCardsView: View {
    let toolCalls: [OpenClawChatPendingToolCall]

    var body: some View {
        VStack(spacing: 8) {
            ForEach(toolCalls) { call in
                PendingToolCallView(call: call)
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
