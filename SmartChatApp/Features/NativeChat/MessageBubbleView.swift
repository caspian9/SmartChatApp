import SwiftUI

struct MessageBubbleView: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.isOutgoing {
                Spacer()
            }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 4) {
                // Show text or placeholder for streaming
                if message.text.isEmpty {
                    if message.state == "streaming" {
                        Text("...")
                            .font(.body)
                            .foregroundColor(.gray)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    } else {
                        Text("")
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                } else {
                    MarkdownText(text: message.text, isOutgoing: message.isOutgoing)
                }

                HStack(spacing: 8) {
                    if let startedAt = message.startedAt {
                        Text(formatTime(startedAt))
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
                    if let endedAt = message.endedAt {
                        Text("→ \(formatTime(endedAt))")
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
                    if message.livenessState == "working" && message.state == "streaming" {
                        Text("●")
                            .font(.caption2)
                            .foregroundColor(.green)
                    } else if message.state == "streaming" && message.text.isEmpty {
                        Text("接收中...")
                            .font(.caption2)
                            .foregroundColor(.gray)
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

struct MarkdownText: View {
    let text: String
    let isOutgoing: Bool

    private var isLikelyMarkdown: Bool {
        // Check for common markdown patterns
        let patterns = ["# ", "## ", "### ", "```", "**", "__", "* ", "- ", "| ", "```"]
        for pattern in patterns {
            if text.contains(pattern) {
                return true
            }
        }
        return false
    }

    var body: some View {
        if isLikelyMarkdown {
            // Try full markdown parsing for block-level elements
            if let attributedString = try? AttributedString(markdown: text, options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .full
            )) {
                Text(attributedString)
                    .font(.body)
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(isOutgoing ? Color(hex: "10A37F") : Color(hex: "1E1E1E"))
                    .cornerRadius(12)
            } else {
                // Fallback to plain text
                Text(text)
                    .font(.body)
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(isOutgoing ? Color(hex: "10A37F") : Color(hex: "1E1E1E"))
                    .cornerRadius(12)
            }
        } else {
            // Plain text - no markdown parsing needed
            Text(text)
                .font(.body)
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isOutgoing ? Color(hex: "10A37F") : Color(hex: "1E1E1E"))
                .cornerRadius(12)
        }
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
        lhs.id == rhs.id &&
        lhs.text == rhs.text &&
        lhs.state == rhs.state &&
        lhs.startedAt == rhs.startedAt &&
        lhs.endedAt == rhs.endedAt &&
        lhs.livenessState == rhs.livenessState
    }
}