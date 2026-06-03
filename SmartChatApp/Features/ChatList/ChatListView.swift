import SwiftUI
import OpenClawChatUI
import OpenClawKit

struct ChatListView: View {
    @State private var sessions: [OpenClawChatSessionEntry] = []
    @State private var isLoading = false
    @State private var selectedSessionKey: String?

    var body: some View {
        List {
            ForEach(sessions) { session in
                NavigationLink(destination: sessionView(for: session)) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.displayName ?? String(session.key.prefix(8)))
                            .font(.headline)
                            .foregroundColor(.white)

                        if let updatedAt = session.updatedAt {
                            Text(formatDate(updatedAt))
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .listRowBackground(Color(hex: "1E1E1E"))
            }
            .onDelete { indexSet in
                // Handle delete if supported
            }
        }
        .listStyle(.plain)
        .background(Color.black)
        .navigationTitle("Chats")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(action: createSession) {
                        Label("New Chat", systemImage: "square.and.pencil")
                    }
                    NavigationLink(destination: SettingsView()) {
                        Label("Settings", systemImage: "gear")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundColor(Color(hex: "10A37F"))
                }
            }
        }
        .onAppear { loadSessions() }
    }

    @ViewBuilder
    private func sessionView(for session: OpenClawChatSessionEntry) -> some View {
        let transport = SessionManager.shared.makeTransport(sessionKey: session.key)
        ChatView(
            sessionKey: session.key,
            transport: transport,
            onAppear: {
                Task {
                    try? await SessionManager.shared.ensureConnected()
                }
            }
        )
    }

    private func loadSessions() {
        isLoading = true
        Task {
            do {
                let transport = SessionManager.shared.makeTransport(sessionKey: "")
                let response = try await transport.listSessions(limit: 50)
                await MainActor.run {
                    sessions = response.sessions
                    isLoading = false
                }
            } catch {
                print("Failed to load sessions: \(error)")
                await MainActor.run {
                    isLoading = false
                }
            }
        }
    }

    private func createSession() {
        Task {
            do {
                let sessionKey = try await SessionManager.shared.createSession()
                let transport = SessionManager.shared.makeTransport(sessionKey: sessionKey)
                let response = try await transport.listSessions(limit: 50)
                await MainActor.run {
                    sessions = response.sessions
                }
            } catch {
                print("Failed to create session: \(error)")
            }
        }
    }

    private func formatDate(_ timestamp: Double) -> String {
        let date = Date(timeIntervalSince1970: timestamp)
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
