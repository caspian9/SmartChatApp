import SwiftUI
import OpenClawChatUI
import OpenClawKit

struct ChatListView: View {
    @Environment(\.theme) private var theme
    @State private var sessions: [OpenClawChatSessionEntry] = []
    @State private var isLoading = false
    @State private var showError = false

    private var activeProfileId: UUID? {
        ProfileManager.shared.activeProfile?.id
    }

    var body: some View {
        List {
            if isLoading && sessions.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowBackground(theme.cardBackground)
            }

            ForEach(sessions) { session in
                NavigationLink(destination: sessionView(for: session)) {
                    SessionRowView(session: session)
                }
                .listRowBackground(theme.cardBackground)
            }
        }
        .listStyle(.plain)
        .background(theme.background)
        .refreshable {
            await refreshFromNetwork()
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
                        .foregroundColor(theme.primary)
                }
            }
        }
        .task {
            loadFromCacheThenRefresh()
        }
    }

    private func loadFromCacheThenRefresh() {
        // Load from cache first for instant display
        if let profileId = activeProfileId, let cached = SessionCache.load(for: profileId) {
            sessions = cached
            isLoading = false
        } else {
            isLoading = true
        }

        // Refresh from network in background
        Task {
            await refreshFromNetwork()
        }
    }

    private func refreshFromNetwork() async {
        do {
            try await SessionManager.shared.ensureConnected()
            let transport = await SessionManager.shared.makeTransport(sessionKey: "")
            let response = try await transport.listSessions(limit: 50)
            await MainActor.run {
                sessions = response.sessions
                isLoading = false
                if let profileId = activeProfileId {
                    SessionCache.save(response.sessions, for: profileId)
                }
            }
        } catch {
            await MainActor.run {
                isLoading = false
            }
        }
    }

    @ViewBuilder
    private func sessionView(for session: OpenClawChatSessionEntry) -> some View {
        // `makeTransport` is now actor-isolated and async, but a
        // @ViewBuilder function cannot `await` (and `body` is sync, so
        // we cannot bubble async up either). Load the transport inside
        // a small wrapper view's `.task` and pass it in once available.
        SessionChatView(
            session: session,
            onAppear: {
                Task {
                    try? await SessionManager.shared.ensureConnected()
                }
            }
        )
    }

    private func createSession() {
        Task {
            do {
                try await SessionManager.shared.ensureConnected()
                let sessionKey = try await SessionManager.shared.createSession()
                let transport = await SessionManager.shared.makeTransport(sessionKey: sessionKey)
                let response = try await transport.listSessions(limit: 50)
                await MainActor.run {
                    sessions = response.sessions
                    if let profileId = activeProfileId {
                        SessionCache.save(response.sessions, for: profileId)
                    }
                }
            } catch {
                print("Failed to create session: \(error)")
            }
        }
    }
}

struct SessionRowView: View {
    @Environment(\.theme) private var theme
    let session: OpenClawChatSessionEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(session.displayName ?? String(session.key.prefix(8)))
                    .font(.headline)
                    .foregroundColor(theme.textPrimary)
                    .lineLimit(1)

                Spacer()

                VStack(alignment: .center, spacing: 2) {
                    if let model = session.model {
                        Text(model)
                            .font(.caption2)
                            .foregroundColor(theme.textPrimary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(theme.primary.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    if let modelProvider = session.modelProvider {
                        Text(modelProvider)
                            .font(.caption2)
                            .foregroundColor(theme.textSecondary)
                    }
                }
            }

            HStack(spacing: 12) {
                if let updatedAt = session.updatedAt {
                    Text(formatDate(updatedAt))
                        .font(.caption)
                        .foregroundColor(theme.textSecondary)
                }

                if let tokens = session.totalTokens {
                    Text("\(tokens) tokens")
                        .font(.caption)
                        .foregroundColor(theme.textSecondary)
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

/// Loads a `OpenClawChatTransport` for `session` in a `.task` and only
/// then constructs `ChatView`. Required because `SessionManager.makeTransport`
/// is now actor-isolated and async, but a @ViewBuilder function called
/// from `body` (sync) cannot `await` it directly.
private struct SessionChatView: View {
    let session: OpenClawChatSessionEntry
    let onAppear: () -> Void
    @State private var transport: (any OpenClawChatTransport)?

    var body: some View {
        Group {
            if let transport {
                ChatView(
                    sessionKey: session.key,
                    sessionEntry: session,
                    transport: transport,
                    onAppear: onAppear
                )
            } else {
                Color.clear
            }
        }
        .task {
            transport = await SessionManager.shared.makeTransport(sessionKey: session.key)
        }
    }
}