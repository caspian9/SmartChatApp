import SwiftUI
import OpenClawChatUI
import OpenClawKit

struct ChatView: View {
    let sessionKey: String
    let sessionEntry: OpenClawChatSessionEntry?
    @State private var viewModel: ChatViewModel
    private let transport: any OpenClawChatTransport
    private let onAppear: () -> Void

    init(sessionKey: String, sessionEntry: OpenClawChatSessionEntry? = nil, transport: any OpenClawChatTransport, onAppear: @escaping () -> Void = {}) {
        self.sessionKey = sessionKey
        self.sessionEntry = sessionEntry
        self.transport = transport
        self.onAppear = onAppear
        _viewModel = State(initialValue: ChatViewModel(
            sessionKey: sessionKey,
            transport: transport,
            onThinkingLevelChanged: nil
        ))
    }

    var body: some View {
        OpenClawChatView(
            viewModel: viewModel,
            showsSessionSwitcher: false,
            style: .standard,
            markdownVariant: .standard,
            userAccent: Color(hex: "10A37F"),
            showsAssistantTrace: true
        )
        .onAppear { onAppear() }
        .task {
            try? await transport.setActiveSessionKey(sessionKey)
            viewModel.load()
        }
    }
}