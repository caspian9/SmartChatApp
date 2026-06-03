import SwiftUI
import OpenClawChatUI

struct SessionTabBar: View {
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
        .background(Color(hex: "1E1E1E"))
    }
}

struct SessionTab: View {
    let session: OpenClawChatSessionEntry
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(session.displayName ?? String(session.key.prefix(8)))
                .font(.caption)
                .foregroundColor(isSelected ? .white : .gray)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color(hex: "10A37F") : Color(hex: "2A2A2A"))
                .cornerRadius(16)
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel("Session: \(String(session.key.prefix(12)))")
    }
}