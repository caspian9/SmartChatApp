import SwiftUI

struct MessageBubbleView: View {
    @Environment(\.theme) private var theme
    let message: ChatMessage

    @State private var animationOffset: CGFloat = 0

    var body: some View {
        HStack {
            if message.isOutgoing {
                Spacer()
            }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 4) {
                // Show text or placeholder for streaming
                if message.text.isEmpty {
                    if message.state == "streaming" {
                        TypingIndicatorView(color: message.isOutgoing ? .white : theme.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(message.isOutgoing ? theme.primary : theme.cardBackground)
                            .cornerRadius(12)
                    } else {
                        Text("")
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(message.text)
                            .font(.body)
                            .foregroundColor(message.isOutgoing ? .white : theme.textPrimary)

                        // Streaming indicator inside bubble - show bouncing dots
                        if message.state == "streaming" && !message.isOutgoing {
                            HStack(spacing: 4) {
                                TypingIndicatorView()
                                    .padding(.top, 4)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(message.isOutgoing ? theme.primary : theme.cardBackground)
                    .cornerRadius(12)
                }

                // Seq badge for AI messages
                if !message.isOutgoing, let seq = message.seq {
                    HStack(spacing: 4) {
                        Text("#\(seq)")
                            .font(.caption2)
                            .foregroundColor(theme.textSecondary)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(theme.inputBackground)
                    .cornerRadius(4)
                }

                // Action bar
                HStack(spacing: 16) {
                    Button {
                        UIPasteboard.general.string = message.text
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                            .foregroundColor(theme.textSecondary)
                    }

                    Button {
                        // Forward action - TODO
                    } label: {
                        Image(systemName: "arrowshape.turn.up.right")
                            .font(.caption)
                            .foregroundColor(theme.textSecondary)
                    }

                    Button {
                        // Favorite action - TODO
                    } label: {
                        Image(systemName: "star")
                            .font(.caption)
                            .foregroundColor(theme.textSecondary)
                    }
                }
                .padding(.top, 2)

                HStack(spacing: 8) {
                    if let startedAt = message.startedAt {
                        Text(formatTime(startedAt))
                            .font(.caption2)
                            .foregroundColor(theme.textSecondary)
                    }
                    if let endedAt = message.endedAt {
                        Text("→ \(formatTime(endedAt))")
                            .font(.caption2)
                            .foregroundColor(theme.textSecondary)
                    }
                    if message.livenessState == "working" && message.state == "streaming" {
                        Text("●")
                            .font(.caption2)
                            .foregroundColor(.green)
                    }
                }
            }

            if !message.isOutgoing {
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    private func formatTime(_ timestamp: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }
}

struct TypingIndicatorView: View {
    @State private var animationOffset: CGFloat = 0
    var color: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                    .offset(y: animationOffset(for: index))
            }
        }
        .onAppear {
            withAnimation(Animation.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                animationOffset = -3
            }
        }
    }

    private func animationOffset(for index: Int) -> CGFloat {
        let delays: [Double] = [0, 0.15, 0.3]
        let progress = (animationOffset + 5) / 10
        return sin(progress * .pi + delays[index]) * 3
    }
}

struct ChatMessage: Identifiable, Equatable {
    let id: String
    var text: String
    let timestamp: Date
    let role: String
    var state: String  // "streaming", "final"
    let runId: String?
    var seq: Int?
    var startedAt: Date?
    var endedAt: Date?
    var livenessState: String?
    let toolCallId: String?
    let toolName: String?
    let stopReason: String?

    var isOutgoing: Bool {
        role.lowercased() == "user"
    }

    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        // Compare all fields to ensure proper view updates
        lhs.id == rhs.id &&
        lhs.text == rhs.text &&
        lhs.timestamp == rhs.timestamp &&
        lhs.role == rhs.role &&
        lhs.state == rhs.state &&
        lhs.seq == rhs.seq &&
        lhs.startedAt == rhs.startedAt &&
        lhs.endedAt == rhs.endedAt &&
        lhs.livenessState == rhs.livenessState
    }
}