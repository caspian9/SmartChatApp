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
                scheduleScroll(proxy: proxy)
            }
            .onChange(of: store.messages.count) { count in
                logger.log("SMAlog: messages.count changed to \(count)")
                scheduleScroll(proxy: proxy)
            }
        }
    }

    private func scheduleScroll(proxy: ScrollViewProxy) {
        let lastId = store.messages.last?.id
        guard let id = lastId else { return }
        logger.log("SMAlog: scheduleScroll to \(String(id.prefix(8)))")
        // Schedule multiple scroll attempts to handle slow rendering
        for i in 0..<5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.1) {
                logger.log("SMAlog: scroll attempt \(i+1)")
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
                set: { store.send(.updateInputText($0)) }
            ),
            isSending: store.isSending,
            onSend: { store.send(.sendMessage) }
        )
        .focused($isInputFocused)
    }
}