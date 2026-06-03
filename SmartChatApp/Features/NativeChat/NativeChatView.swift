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
        VStack(spacing: 0) {
            if !store.sessions.isEmpty {
                SessionPickerView(
                    sessions: store.sessions,
                    selectedSession: Binding(
                        get: { store.selectedSession },
                        set: { newValue in
                            if let s = newValue {
                                store.send(.selectSession(s))
                            }
                        }
                    )
                )
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(store.messages) { message in
                            MessageBubbleView(message: message)
                                .id(message.id)
                                .onTapGesture {
                                    isInputFocused = false
                                }
                        }
                    }
                    .padding(.vertical, 8)
                    .onAppear {
                        // Scroll to bottom immediately when view appears with cached messages
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            scrollToBottom(proxy: proxy)
                        }
                    }
                }
                .onTapGesture {
                    isInputFocused = false
                }
                .onChange(of: isInputFocused) { focused in
                    // Delay scroll to ensure keyboard animation completes
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        scrollToBottom(proxy: proxy)
                    }
                }
                .onChange(of: store.messages) { _ in
                    // Scroll to bottom when messages change (including streaming updates)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        scrollToBottom(proxy: proxy)
                    }
                }
                .onChange(of: store.selectedSession) { _ in
                    // Scroll to bottom when session changes
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        scrollToBottom(proxy: proxy)
                    }
                }
            }

            ChatInputView(
                inputText: Binding(
                    get: { store.inputText },
                    set: { store.send(.updateInputText($0)) }
                ),
                isSending: store.isSending,
                onSend: {
                    store.send(.sendMessage)
                }
            )
            .focused($isInputFocused)
        }
        .background(theme.background)
        .navigationTitle("NativeChat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: {
                    store.send(.createSession)
                }) {
                    Image(systemName: "plus")
                        .foregroundColor(theme.primary)
                }
            }
        }
        .onAppear {
            logger.log("SMAlog: NativeChatView onAppear called")
            store.send(.loadSessions)
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        if let lastMessage = store.messages.last {
            proxy.scrollTo(lastMessage.id, anchor: .bottom)
        }
    }
}