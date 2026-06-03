import SwiftUI
import ComposableArchitecture
import OSLog

private let logger = Logger(subsystem: "SmartChatApp", category: "NativeChatView")

struct NativeChatView: View {
    @Environment(\.theme) private var theme
    @StateObject private var store = StoreOf<NativeChatViewModel>(initialState: NativeChatViewModel.State()) {
        NativeChatViewModel()
    }
    @FocusState private var isInputFocused: Bool
    @State private var scrollToMessageId: String?
    @State private var triggerCount: Int = 0

    init() {
        logger.log("SMAlog: NativeChatView init")
    }

    var body: some View {
        content
            .background(theme.background)
            .navigationTitle("NativeChat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarItem }
            .onAppear {
                logger.log("SMAlog: NativeChatView onAppear called")
                store.send(.loadSessions)
            }
    }

    private var toolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(action: { store.send(.createSession) }) {
                Image(systemName: "plus").foregroundColor(theme.primary)
            }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            sessionPicker
            scrollView
            chatInput
        }
    }

    @ViewBuilder
    private var sessionPicker: some View {
        if !store.sessions.isEmpty {
            SessionPickerView(
                sessions: store.sessions,
                selectedSession: Binding(
                    get: { store.selectedSession },
                    set: { newValue in
                        if let s = newValue { store.send(.selectSession(s)) }
                    }
                )
            )
        }
    }

    private var scrollView: some View {
        messageScrollView
    }

    @ViewBuilder
    private var messageScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                messageList
            }
            .onTapGesture { isInputFocused = false }
            .onAppear {
                logger.log("SMAlog: messageScrollView onAppear, messages: \(store.messages.count)")
            }
            .onChange(of: store.scrollTrigger) { [self] newValue in
                guard newValue != triggerCount else { return }
                triggerCount = newValue
                let lastId = store.messages.last?.id
                logger.log("SMAlog: scrollTrigger changed to \(newValue), lastId: \(lastId?.prefix(8) ?? "nil")")
                if let id = lastId {
                    logger.log("SMAlog: triggering immediate scroll to \(String(id.prefix(8)))")
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
            .onChange(of: store.needsScrollToBottom) { needsScroll in
                if needsScroll {
                    let lastId = store.messages.last?.id
                    logger.log("SMAlog: needsScrollToBottom true, lastId: \(lastId?.prefix(8) ?? "nil")")
                    if let id = lastId {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                    // Reset immediately after scroll attempt
                    DispatchQueue.main.async { [weak store] in
                        store?.send(.setNeedsScrollToBottom(false))
                    }
                }
            }
        }
    }

    private var messageList: some View {
        LazyVStack(spacing: 0) {
            ForEach(store.messages) { message in
                MessageBubbleView(message: message)
                    .id(message.id)
            }
        }
        .padding(.vertical, 8)
    }

    private var chatInput: some View {
        ChatInputView(
            inputText: Binding(
                get: { store.inputText },
                set: { newValue in
                    store.send(.updateInputText(newValue))
                }
            ),
            isSending: store.isSending,
            onSend: {
                store.send(.sendMessage)
            }
        )
        .focused($isInputFocused)
    }
}