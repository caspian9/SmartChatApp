import SwiftUI
import OpenClawChatUI
import OSLog

private let logger = Logger(subsystem: "SmartChatApp", category: "SessionPickerView")

struct SessionPickerView: View {
    @Environment(\.theme) private var theme
    let sessions: [OpenClawChatSessionEntry]
    @Binding var selectedSession: OpenClawChatSessionEntry?

    @State private var selectedAgentId: String?
    @State private var selectedName: String?

    private func extractAgentId(from key: String) -> String {
        let parts = key.split(separator: ":")
        if parts.count >= 2 {
            return String(parts[1])
        }
        return "Unknown"
    }

    private var agents: [String] {
        let uniqueAgents = Set(sessions.map { extractAgentId(from: $0.key) })
        return Array(uniqueAgents).sorted()
    }

    private var filteredSessions: [OpenClawChatSessionEntry] {
        guard let agentId = selectedAgentId else { return sessions }
        return sessions.filter { extractAgentId(from: $0.key) == agentId }
    }

    private var names: [String] {
        let uniqueNames = Set(filteredSessions.compactMap { $0.displayName ?? String($0.key.prefix(8)) })
        return Array(uniqueNames).sorted()
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 12) {
                // Agent picker
                Menu {
                    ForEach(agents, id: \.self) { agent in
                        Button(action: {
                            // Only update if changing to a different agent
                            if selectedAgentId != agent {
                                selectedAgentId = agent
                                // Clear name only when agent changes
                                selectedName = nil
                                // Auto-select first session of this agent
                                if let first = filteredSessions.first(where: { self.extractAgentId(from: $0.key) == agent }) {
                                    selectedSession = first
                                }
                            }
                        }) {
                            HStack {
                                Text(agent)
                                if selectedAgentId == agent {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Text(selectedAgentId ?? "")
                        .font(.caption)
                        .foregroundColor(theme.textPrimary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(theme.inputBackground)
                        .cornerRadius(8)
                }
                .frame(width: UIScreen.main.bounds.width * 0.2)

                // Name picker
                Menu {
                    ForEach(names, id: \.self) { name in
                        Button(action: {
                            selectedName = name
                            // Find and select the session with this name
                            if let session = filteredSessions.first(where: { ($0.displayName ?? String($0.key.prefix(8))) == name }) {
                                selectedSession = session
                            }
                        }) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(name)
                                    if let session = filteredSessions.first(where: { ($0.displayName ?? String($0.key.prefix(8))) == name }),
                                       let kind = session.kind {
                                        Text(kind)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                if selectedName == name {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Text(selectedName ?? "")
                        .font(.caption)
                        .foregroundColor(theme.textPrimary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(theme.inputBackground)
                        .cornerRadius(8)
                }
                .frame(width: UIScreen.main.bounds.width * 0.3)

                Spacer()
            }

            // Current session info
            currentSessionInfo()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(theme.cardBackground)
        .onAppear {
            logger.log("SMAlog: SessionPickerView onAppear, sessions: \(self.sessions.count)")
            // Initialize selection based on current selected session
            if let session = selectedSession {
                selectedAgentId = extractAgentId(from: session.key)
                selectedName = session.displayName ?? String(session.key.prefix(8))
            } else if let first = sessions.first {
                // Auto-select first session if none selected
                selectedAgentId = extractAgentId(from: first.key)
                selectedName = first.displayName ?? String(first.key.prefix(8))
                selectedSession = first
            }
        }
        .onChange(of: selectedSession) { newSession in
            if let session = newSession {
                let agentId = extractAgentId(from: session.key)
                let name = session.displayName ?? String(session.key.prefix(8))
                if selectedAgentId != agentId {
                    selectedAgentId = agentId
                }
                if selectedName != name {
                    selectedName = name
                }
            }
        }
    }

    @ViewBuilder
    private func currentSessionInfo() -> some View {
        if let session = selectedSession {
            HStack(spacing: 8) {
                if let provider = session.modelProvider {
                    Text(provider)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.2))
                        .cornerRadius(4)
                }
                if let model = session.model {
                    Text(model)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.2))
                        .cornerRadius(4)
                }
                if let tokens = session.totalTokens {
                    Text("\(tokens) tokens")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if let updatedAt = session.updatedAt {
                    Text(formatDate(updatedAt))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func formatDate(_ timestamp: Double) -> String {
        let date = Date(timeIntervalSince1970: timestamp / 1000)
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

#Preview {
    SessionPickerView(
        sessions: [],
        selectedSession: .constant(nil)
    )
    .background(Color.gray)
}