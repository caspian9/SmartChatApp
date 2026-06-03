import SwiftUI
import OpenClawChatUI
import OSLog

private let logger = Logger(subsystem: "SmartChatApp", category: "SessionPickerView")

struct SessionPickerView: View {
    @Environment(\.theme) private var theme
    let sessions: [OpenClawChatSessionEntry]
    @Binding var selectedSession: OpenClawChatSessionEntry?
    let profiles: [GatewayProfile]
    let selectedProfileId: UUID?
    let onProfileChange: (UUID) -> Void

    @State private var selectedAgentId: String?
    @State private var selectedChannel: String?

    private func extractAgentId(from key: String) -> String {
        let parts = key.split(separator: ":")
        if parts.count >= 2 {
            return String(parts[1])
        }
        return "Unknown"
    }

    private func extractChannel(from key: String) -> String {
        let parts = key.split(separator: ":")
        if parts.count >= 3 {
            let channel = String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines)
            return channel.isEmpty ? "Unknown" : channel
        }
        return "Unknown"
    }

    private func extractSessionUuid(from key: String) -> String {
        let parts = key.split(separator: ":")
        if parts.count >= 4 {
            return String(parts[3])
        }
        return String(key.suffix(8))
    }

    /// Full label used inside the Session menu. Shows `displayName` if set,
    /// else the full segment[3] UUID.
    private func sessionLabelFull(_ session: OpenClawChatSessionEntry) -> String {
        if let name = session.displayName, !name.isEmpty {
            return name
        }
        return extractSessionUuid(from: session.key)
    }

    /// Short label used as the Session dropdown's button text. `displayName`
    /// is shown in full (names are short); the UUID is truncated to 8 chars
    /// + ellipsis so the header stays compact while the menu still shows the
    /// full UUID.
    private func sessionLabelShort(_ session: OpenClawChatSessionEntry) -> String {
        if let name = session.displayName, !name.isEmpty {
            return name
        }
        let uuid = extractSessionUuid(from: session.key)
        if uuid.count <= 8 { return uuid }
        return String(uuid.prefix(8)) + "…"
    }

    private var agents: [String] {
        Array(Set(sessions.map { extractAgentId(from: $0.key) })).sorted()
    }

    private var channels: [String] {
        guard let agentId = selectedAgentId else { return [] }
        let agentSessions = sessions.filter { extractAgentId(from: $0.key) == agentId }
        return Array(Set(agentSessions.map { extractChannel(from: $0.key) })).sorted()
    }

    private var sessionList: [OpenClawChatSessionEntry] {
        guard let agentId = selectedAgentId, let channel = selectedChannel else { return [] }
        return sessions
            .filter {
                extractAgentId(from: $0.key) == agentId &&
                extractChannel(from: $0.key) == channel
            }
            .sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
    }

    private var selectedProfileName: String {
        guard let id = selectedProfileId, let profile = profiles.first(where: { $0.id == id }) else {
            return profiles.first?.name ?? "No Gateway"
        }
        return profile.name
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                // Gateway picker
                Menu {
                    ForEach(profiles) { profile in
                        Button(action: {
                            if profile.id != selectedProfileId {
                                onProfileChange(profile.id)
                            }
                        }) {
                            HStack {
                                Circle()
                                    .fill(Color(hex: profile.colorTag))
                                    .frame(width: 8, height: 8)
                                Text(profile.name)
                                if selectedProfileId == profile.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        if let id = selectedProfileId, let profile = profiles.first(where: { $0.id == id }) {
                            Circle()
                                .fill(Color(hex: profile.colorTag))
                                .frame(width: 8, height: 8)
                        }
                        Text(selectedProfileName)
                            .font(.caption)
                            .foregroundColor(theme.textPrimary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(theme.inputBackground)
                    .cornerRadius(8)
                }
                .frame(width: UIScreen.main.bounds.width * 0.2)

                // Agent picker
                Menu {
                    ForEach(agents, id: \.self) { agent in
                        Button(action: {
                            if selectedAgentId != agent {
                                selectedAgentId = agent
                                // Reset channel to first available in new agent
                                let newChannels = channelsForAgent(agent)
                                selectedChannel = newChannels.first
                                // Auto-select first session of (new agent, new channel)
                                if let ch = selectedChannel,
                                   let first = sessions.first(where: {
                                       extractAgentId(from: $0.key) == agent &&
                                       extractChannel(from: $0.key) == ch
                                   }) {
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
                .frame(width: UIScreen.main.bounds.width * 0.17)

                // Channel picker (segment[2] of key)
                Menu {
                    ForEach(channels, id: \.self) { channel in
                        Button(action: {
                            if selectedChannel != channel {
                                selectedChannel = channel
                                // Auto-select first session of (current agent, new channel)
                                if let agent = selectedAgentId,
                                   let first = sessions.first(where: {
                                       extractAgentId(from: $0.key) == agent &&
                                       extractChannel(from: $0.key) == channel
                                   }) {
                                    selectedSession = first
                                }
                            }
                        }) {
                            HStack {
                                Text(channel)
                                if selectedChannel == channel {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Text(selectedChannel ?? "")
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

                // Session picker (displayName or full UUID in menu; truncated in header)
                Menu {
                    ForEach(sessionList) { session in
                        Button(action: {
                            selectedSession = session
                        }) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(sessionLabelFull(session))
                                        .lineLimit(1)
                                    if let kind = session.kind {
                                        Text(kind)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                if selectedSession?.key == session.key {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Text(selectedSession.map(sessionLabelShort) ?? "")
                        .font(.caption)
                        .foregroundColor(theme.textPrimary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(theme.inputBackground)
                        .cornerRadius(8)
                }
                .frame(width: UIScreen.main.bounds.width * 0.25)

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
            if let session = selectedSession {
                selectedAgentId = extractAgentId(from: session.key)
                selectedChannel = extractChannel(from: session.key)
            } else if let first = sessions.first {
                selectedAgentId = extractAgentId(from: first.key)
                selectedChannel = extractChannel(from: first.key)
                selectedSession = first
            }
        }
        .onChange(of: selectedSession) { newSession in
            if let session = newSession {
                let agentId = extractAgentId(from: session.key)
                let channel = extractChannel(from: session.key)
                if selectedAgentId != agentId {
                    selectedAgentId = agentId
                }
                if selectedChannel != channel {
                    selectedChannel = channel
                }
            }
        }
    }

    /// Helper used inside the agent Menu's action to look up the new agent's
    /// channels. We can't use the `channels` computed property here because
    /// `selectedAgentId` has already been updated to the new value — that
    /// would reflect the *new* agent's channels (which is what we want), but
    /// inline keeps the action self-contained and matches the
    /// `selectedAgentId = agent` ordering.
    private func channelsForAgent(_ agent: String) -> [String] {
        let agentSessions = sessions.filter { extractAgentId(from: $0.key) == agent }
        return Array(Set(agentSessions.map { extractChannel(from: $0.key) })).sorted()
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
                    Text("\(tokens)")
                        .font(.caption2)
                        .foregroundColor(.green)
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
        selectedSession: .constant(nil),
        profiles: [],
        selectedProfileId: nil,
        onProfileChange: { _ in }
    )
    .background(Color.gray)
}
