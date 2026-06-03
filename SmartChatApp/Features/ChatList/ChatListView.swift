import SwiftUI
import OpenClawChatUI
import OpenClawKit

struct ChatListView: View {
    @State private var sessions: [OpenClawChatSessionEntry] = []
    @State private var isLoading = false
    @State private var selectedSessionKey: String?

    var body: some View {
        List {
            if isLoading && sessions.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowBackground(Color(hex: "1E1E1E"))
            }

            ForEach(sessions) { session in
                NavigationLink(destination: sessionView(for: session)) {
                    SessionRowView(session: session)
                }
                .listRowBackground(Color(hex: "1E1E1E"))
            }
            .onDelete { indexSet in
                // Handle delete if supported
            }
        }
        .listStyle(.plain)
        .background(Color.black)
        .refreshable {
            await loadSessionsAsync()
        }
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

    private func loadSessionsAsync() async {
        do {
            try await SessionManager.shared.ensureConnected()
            let transport = SessionManager.shared.makeTransport(sessionKey: "")
            let response = try await transport.listSessions(limit: 50)
            sessions = response.sessions
        } catch {
            print("Failed to load sessions: \(error)")
        }
    }

    @ViewBuilder
    private func sessionView(for session: OpenClawChatSessionEntry) -> some View {
        let transport = SessionManager.shared.makeTransport(sessionKey: session.key)
        ChatView(
            sessionKey: session.key,
            sessionEntry: session,
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
                try await SessionManager.shared.ensureConnected()
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
                try await SessionManager.shared.ensureConnected()
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
}

struct SessionRowView: View {
    let session: OpenClawChatSessionEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(session.displayName ?? String(session.key.prefix(8)))
                    .font(.headline)
                    .foregroundColor(.white)
                    .lineLimit(1)

                Spacer()

                VStack(alignment: .center, spacing: 2) {
                    if let model = session.model {
                        Text(model)
                            .font(.caption2)
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(hex: "10A37F").opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    if let modelProvider = session.modelProvider {
                        Text(modelProvider)
                            .font(.caption2)
                            .foregroundColor(Color(hex: "6B7280"))
                    }
                }
            }

            HStack(spacing: 12) {
                if let updatedAt = session.updatedAt {
                    Text(formatDate(updatedAt))
                        .font(.caption)
                        .foregroundColor(.gray)
                }

                if let inputTokens = session.inputTokens, let outputTokens = session.outputTokens {
                    Text("\(inputTokens + outputTokens) tokens")
                        .font(.caption)
                        .foregroundColor(.gray)
                }

                if let thinkingLevel = session.thinkingLevel, thinkingLevel != "off" {
                    Text("💭 \(thinkingLevel)")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            if session.abortedLastRun == true {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundColor(.orange)
                    Text("Run interrupted")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func formatDate(_ timestamp: Double) -> String {
        let date = Date(timeIntervalSince1970: timestamp / 1000)
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
