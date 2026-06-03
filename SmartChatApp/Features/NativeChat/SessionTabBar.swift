import SwiftUI
import OpenClawChatUI

struct SessionTabBar: View {
    @Environment(\.theme) private var theme
    let sessions: [OpenClawChatSessionEntry]
    @Binding var selectedSession: OpenClawChatSessionEntry?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(sessions) { session in
                    SessionTab(
                        session: session,
                        isSelected: selectedSession?.key == session.key,
                        action: {
                            selectedSession = session
                        }
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(theme.cardBackground)
    }
}

struct SessionTab: View {
    @Environment(\.theme) private var theme
    let session: OpenClawChatSessionEntry
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(session.displayName ?? String(session.key.prefix(8)))
                .font(.caption)
                .foregroundColor(isSelected ? .white : theme.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? theme.primary : theme.inputBackground)
                .cornerRadius(16)
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel("Session: \(String(session.key.prefix(12)))")
    }
}