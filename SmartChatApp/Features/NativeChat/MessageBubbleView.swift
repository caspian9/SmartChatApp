import SwiftUI

struct MessageBubbleView: View {
    @Environment(\.theme) private var theme
    let message: ChatMessage

    @State private var animationOffset: CGFloat = 0
    @State private var isExpanded: Bool = false

    private let maxCollapsedLines: Int = 8
    private let maxCollapsedHeight: CGFloat = 150

    var body: some View {
        HStack {
            if message.isOutgoing {
                Spacer()
            }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 4) {
                bubbleContent

                HStack(spacing: 8) {
                    // Seq badge for AI messages
                    if !message.isOutgoing, let seq = message.seq {
                        Text("#\(seq)")
                            .font(.caption2)
                            .foregroundColor(theme.textSecondary)
                    }

                    // ToolResult badge
                    if message.role == "toolResult" {
                        Text("ToolResult")
                            .font(.caption2)
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.purple)
                            .cornerRadius(4)
                    }

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
                    // Token usage display
                    if let input = message.inputTokens, let output = message.outputTokens {
                        Text("↑\(input) ↓\(output)")
                            .font(.caption2)
                            .foregroundColor(theme.textSecondary)
                    }
                    if let cacheRead = message.cacheRead {
                        Text("↑\(cacheRead)")
                            .font(.caption2)
                            .foregroundColor(.green)
                    }
                    if let cacheWrite = message.cacheWrite {
                        Text("↓\(cacheWrite)")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                    if message.livenessState == "working" && message.state == "streaming" {
                        Text("●")
                            .font(.caption2)
                            .foregroundColor(.green)
                    }
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
            }

            if !message.isOutgoing {
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var bubbleContent: some View {
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
                messageText

                // Streaming indicator inside bubble
                if message.state == "streaming" && !message.isOutgoing {
                    TypingIndicatorView()
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(message.isOutgoing ? theme.primary : theme.cardBackground)
            .cornerRadius(12)
        }
    }

    @ViewBuilder
    private var messageText: some View {
        VStack(alignment: .leading, spacing: 4) {
            if shouldRenderMarkdown && message.role != "toolResult" {
                MarkdownCardView(content: message.text)
                    .frame(minHeight: 30)
            } else if message.role == "toolResult" {
                Text(formatJsonText(message.text))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(message.isOutgoing ? .white : theme.textPrimary)
                    .lineLimit(shouldCollapse ? (isExpanded ? nil : maxCollapsedLines) : nil)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(message.text)
                    .font(.body)
                    .foregroundColor(message.isOutgoing ? .white : theme.textPrimary)
                    .lineLimit(shouldCollapse ? (isExpanded ? nil : maxCollapsedLines) : nil)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if shouldShowExpandButton && !shouldRenderMarkdown {
                Button {
                    withAnimation {
                        isExpanded = true
                    }
                } label: {
                    Text("Show more...")
                        .font(.caption)
                        .foregroundColor(message.isOutgoing ? .white.opacity(0.8) : theme.primary)
                }
                .padding(.top, 4)
            }
        }
    }

    private var shouldRenderMarkdown: Bool {
        guard !message.isOutgoing && !message.text.isEmpty else { return false }
        return CardRegistry.containsMarkdown(content: message.text)
    }

    private var shouldShowExpandButton: Bool {
        guard message.isOutgoing == false && !message.text.isEmpty else { return false }
        return shouldCollapse && !isExpanded
    }

    private var shouldCollapse: Bool {
        // If message has seq, it's from streaming - never collapse
        if message.seq != nil {
            return false
        }
        // Check if text exceeds roughly the line limit
        let textHeight = message.text.boundingRect(
            with: CGSize(width: UIScreen.main.bounds.width * 0.65, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).height
        return textHeight > maxCollapsedHeight
    }

    private func formatTime(_ timestamp: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }

    private func formatJsonText(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data),
              let prettyData = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted),
              let prettyString = String(data: prettyData, encoding: .utf8) else {
            return text
        }
        return prettyString
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
    var inputTokens: Int?
    var outputTokens: Int?
    var cacheRead: Int?
    var cacheWrite: Int?
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