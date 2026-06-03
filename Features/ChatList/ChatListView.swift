import SwiftUI
import ComposableArchitecture

struct ChatListView: View {
    let store: StoreOf<ChatListFeature>

    var body: some View {
        List {
            ForEach(store.sessions) { session in
                NavigationLink(destination: ChatView(
                    store: Store(
                        initialState: ChatFeature.State(session: session),
                        reducer: { ChatFeature() }
                    )
                )) {
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
                for index in indexSet {
                    store.send(.deleteSession(store.sessions[index].id))
                }
            }
        }
        .listStyle(.plain)
        .background(Color.black)
        .navigationTitle("Chats")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { store.send(.createSession) }) {
                    Image(systemName: "square.and.pencil")
                        .foregroundColor(Color(hex: "10A37F"))
                }
            }
        }
        .onAppear { store.send(.loadSessions) }
    }
}