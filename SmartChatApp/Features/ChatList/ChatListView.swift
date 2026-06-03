import SwiftUI
import ComposableArchitecture

struct ChatListView: View {
    @State private var sessions: [ChatSession] = []
    @State private var isLoading = false

    var body: some View {
        List {
            ForEach(sessions) { session in
                NavigationLink(destination: ChatView(session: session)) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.title)
                            .font(.headline)
                            .foregroundColor(.white)

                        if let lastMessage = session.messages.last {
                            Text(lastMessage.content)
                                .font(.caption)
                                .foregroundColor(.gray)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .listRowBackground(Color(hex: "1E1E1E"))
            }
            .onDelete { indexSet in
                sessions.remove(atOffsets: indexSet)
            }
        }
        .listStyle(.plain)
        .background(Color.black)
        .navigationTitle("Chats")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: createSession) {
                    Image(systemName: "square.and.pencil")
                        .foregroundColor(Color(hex: "10A37F"))
                }
            }
        }
        .onAppear { loadSessions() }
    }

    private func loadSessions() {
        isLoading = true
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            sessions = [
                ChatSession(id: "1", title: "Chat 1"),
                ChatSession(id: "2", title: "Chat 2"),
            ]
            isLoading = false
        }
    }

    private func createSession() {
        let newSession = ChatSession()
        sessions.insert(newSession, at: 0)
    }
}
