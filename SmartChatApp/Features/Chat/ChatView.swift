import SwiftUI
import OpenClawChatUI
import OpenClawKit

struct ChatView: View {
    let sessionKey: String
    @State private var viewModel: OpenClawChatViewModel

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
        OpenClawChatView(
            viewModel: viewModel,
            showsSessionSwitcher: false,
            style: .standard,
            markdownVariant: .standard,
            userAccent: Color(hex: "10A37F"),
            showsAssistantTrace: false
        )
    }
}
