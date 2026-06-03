import SwiftUI

struct ChatView: View {
    @State private var session: ChatSession
    @State private var inputText: String = ""
    @State private var isStreaming: Bool = false
    @State private var streamingContent: String = ""
    @State private var isConnected: Bool = false

    init(session: ChatSession) {
        _session = State(initialValue: session)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(session.messages) { message in
                            MessageRowView(message: message)
                                .id(message.id)
                        }

                        if isStreaming && !streamingContent.isEmpty {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "brain")
                                    .foregroundColor(.purple)
                                    .frame(width: 30, height: 30)
                                    .background(Circle().fill(Color.purple.opacity(0.2)))

                                Text(streamingContent)
                                    .font(.body)
                                    .foregroundColor(.white)
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                        }
                    }
                    .padding(.horizontal)
                }
                .onChange(of: session.messages.count) { _, _ in
                    if let lastMessage = session.messages.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()
                .background(Color.gray.opacity(0.3))

            InputBarView(
                text: $inputText,
                isStreaming: isStreaming,
                onSend: sendMessage,
                onAbort: abortStreaming
            )
        }
        .background(Color.black)
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: toggleConnection) {
                    Image(systemName: isConnected ? "wifi" : "wifi.slash")
                        .foregroundColor(isConnected ? Color(hex: "10A37F") : .red)
                }
            }
        }
    }

    private func sendMessage() {
        let userMessage = Message(role: .user, content: inputText)
        session.messages.append(userMessage)
        inputText = ""
        isStreaming = true
        streamingContent = ""

        Task {
            try? await Task.sleep(for: .seconds(2))
            let assistantMessage = Message(
                role: .assistant,
                content: "This is a mock response. Connect to OpenClaw Gateway for real responses."
            )
            session.messages.append(assistantMessage)
            isStreaming = false
            streamingContent = ""
        }
    }

    private func abortStreaming() {
        isStreaming = false
        streamingContent = ""
    }

    private func toggleConnection() {
        isConnected.toggle()
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
