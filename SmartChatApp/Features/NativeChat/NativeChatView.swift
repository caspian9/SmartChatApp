import SwiftUI
import ComposableArchitecture

struct NativeChatView: View {
    let store: StoreOf<NativeChatViewModel>
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let session = store.selectedSession {
                SessionTabBar(
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
                    LazyVStack(spacing: 0) {
                        ForEach(store.messages) { message in
                            MessageBubbleView(message: message)
                                .id(message.id)
                                .onTapGesture {
                                    isInputFocused = false
                                }
                        }
                    }
                    .padding(.vertical, 8)
                    .onChange(of: store.messages.count) { _ in
                        if !store.isRestoringFromCache {
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
        .background(Color.black)
        .navigationTitle("NativeChat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: {
                    store.send(.createSession)
                }) {
                    Image(systemName: "plus")
                        .foregroundColor(Color(hex: "10A37F"))
                }
            }
        }
        .onAppear {
            store.send(.loadSessions)
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        if let lastMessage = store.messages.last {
            withAnimation(.easeOut(duration: 0.25)) {
                proxy.scrollTo(lastMessage.id, anchor: .bottom)
            }
        }
    }
}