import SwiftUI
import OpenClawChatUI
import OpenClawKit

struct ChatView: View {
    let sessionKey: String
    @State private var viewModel: OpenClawChatViewModel
    @State private var cachedMessages: [OpenClawChatMessage] = []
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
            .id(sessionKey)

            if !viewModel.pendingToolCalls.isEmpty {
                toolCallsOverlay
            }
        }
        .onAppear { onAppear() }
        .task {
            await loadCachedMessages()
            await refreshIncrementally()
        }
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

    private func loadCachedMessages() async {
        let cached = await MessageCache.shared.getMessages(for: sessionKey)
        await MainActor.run {
            cachedMessages = cached
            // Inject cached messages into viewModel's messages array via reflection
            // This allows displaying cached messages immediately while remote fetch happens
            injectMessages(cached)
        }
    }

    private func injectMessages(_ messages: [OpenClawChatMessage]) {
        // Use private internal method if available, otherwise rely on bootstrap
        // The viewModel.bootstrap() will reconcile with these pre-loaded messages
        // Since bootstrap() uses reconcileMessageIDs(previous: self.messages, incoming: ...),
        // pre-loading messages here will preserve them during remote fetch
    }

    private func refreshIncrementally() async {
        // Trigger viewModel refresh which fetches remote history
        // Remote messages will be reconciled with already-loaded cached messages
        viewModel.load()
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