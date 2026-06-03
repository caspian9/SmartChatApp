import SwiftUI
import ComposableArchitecture

struct ChatView: View {
    let store: StoreOf<ChatFeature>
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(store.state.session.messages) { message in
                            MessageRowView(message: message)
                                .id(message.id)
                        }

                        if store.state.isStreaming && !store.state.streamingContent.isEmpty {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "brain")
                                    .foregroundColor(.purple)
                                    .frame(width: 30, height: 30)
                                    .background(Circle().fill(Color.purple.opacity(0.2)))

                                Text(store.state.streamingContent)
                                    .font(.body)
                                    .foregroundColor(.white)
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                        }
                    }
                    .padding(.horizontal)
                }
                .onChange(of: store.state.session.messages.count) { _, _ in
                    if let lastMessage = store.state.session.messages.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()
                .background(Color.gray.opacity(0.3))

            InputBarView(
                text: $store.state.inputText,
                isStreaming: store.state.isStreaming,
                onSend: { store.send(.sendMessage) },
                onAbort: { store.send(.abortStreaming) }
            )
        }
        .background(Color.black)
        .navigationTitle(store.state.session.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { store.send(.connect) }) {
                    Image(systemName: store.state.isConnected ? "wifi" : "wifi.slash")
                        .foregroundColor(store.state.isConnected ? Color(hex: "10A37F") : .red)
                }
            }
        }
    }
}

struct InputBarView: View {
    @Binding var text: String
    let isStreaming: Bool
    let onSend: () -> Void
    let onAbort: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            TextField("Message...", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(hex: "40414F"))
                .cornerRadius(20)
                .foregroundColor(.white)
                .focused($isFocused)
                .lineLimit(1...5)

            if isStreaming {
                Button(action: onAbort) {
                    Image(systemName: "stop.circle.fill")
                        .font(.title)
                        .foregroundColor(.red)
                }
            } else {
                Button(action: onSend) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                        .foregroundColor(text.isEmpty ? .gray : Color(hex: "10A37F"))
                }
                .disabled(text.isEmpty)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(Color(hex: "343541"))
    }
}