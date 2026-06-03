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
    @State private var isUserScrolling = false
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
                // Scroll to bottom immediately without animation
                if let lastId = store.messages.last?.id {
                    proxy.scrollTo(lastId, anchor: .bottom)
                }
            }
            .onChange(of: store.messages.count) { count in
                logger.log("SMAlog: messages.count changed to \(count)")
                if !isUserScrolling {
                    scheduleScroll(proxy: proxy)
                }
            }
            .onChange(of: store.scrollTrigger) { [self] newValue in
                guard newValue != triggerCount else { return }
                triggerCount = newValue
                let lastId = store.messages.last?.id
                logger.log("SMAlog: scrollTrigger changed to \(newValue), lastId: \(lastId?.prefix(8) ?? "nil")")
                if let id = lastId, !isUserScrolling {
                    logger.log("SMAlog: triggering immediate scroll to \(String(id.prefix(8)))")
                    DispatchQueue.main.async {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: store.needsScrollToBottom) { needsScroll in
                if needsScroll {
                    let lastId = store.messages.last?.id
                    logger.log("SMAlog: needsScrollToBottom true, lastId: \(lastId?.prefix(8) ?? "nil")")
                    if let id = lastId {
                        DispatchQueue.main.async {
                            proxy.scrollTo(id, anchor: .bottom)
                        }
                        // Reset after scrolling
                        store.send(.setNeedsScrollToBottom(false))
                    }
                }
            }
            .onChange(of: store.isSending) { isSending in
                logger.log("SMAlog: isSending changed to \(isSending)")
                if !isSending {
                    isUserScrolling = false
                }
            }
            .onChange(of: isInputFocused) { focused in
                logger.log("SMAlog: isInputFocused changed to \(focused)")
                if !isUserScrolling {
                    scheduleScroll(proxy: proxy)
                }
            }
        }
    }

    private func scheduleScroll(proxy: ScrollViewProxy) {
        let lastId = store.messages.last?.id
        guard let id = lastId else { return }
        logger.log("SMAlog: scheduleScroll to \(String(id.prefix(8))), isUserScrolling: \(isUserScrolling)")
        for i in 0..<5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.1) {
                proxy.scrollTo(id, anchor: .bottom)
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
                    isUserScrolling = false
                }
            ),
            isSending: store.isSending,
            onSend: {
                isUserScrolling = false
                store.send(.sendMessage)
            }
        )
        .focused($isInputFocused)
    }
}