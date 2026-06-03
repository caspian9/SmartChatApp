import SwiftUI
import ComposableArchitecture

struct NativeChatView: View {
    let store: StoreOf<NativeChatViewModel>

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

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.messages) { message in
                        MessageBubbleView(message: message)
                    }
                }
                .padding(.vertical, 8)
            }

            ChatInputView(
                inputText: Binding(
                    get: { store.inputText },
                    set: { store.send(.updateInputText($0)) }
                ),
                onSend: {
                    store.send(.sendMessage)
                }
            )
        }
        .background(Color.black)
        .navigationTitle("NativeChat")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            store.send(.loadSessions)
            store.send(.loadHistory)
        }
    }
}