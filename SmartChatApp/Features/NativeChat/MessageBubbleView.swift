import SwiftUI
import OSLog

private let bubbleLog = OSLog(subsystem: "SmartChatApp.MessageBubble", category: "debug")

struct ViewHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct MessageBubbleView: View {
    @Environment(\.theme) private var theme
    let message: ChatMessage

    @State private var animationOffset: CGFloat = 0
    @State private var isExpanded: Bool = false
    @State private var measuredHeight: CGFloat = 0
    @State private var isMarkdownCollapsed: Bool = false
    @State private var cachedShouldCollapse: Bool = false
    @State private var cachedLineCount: Int = 0
    @State private var lastTextForCollapse: String = ""
    @State private var lastTextForMarkdown: String = ""
    @State private var lastMarkdownState: Bool = false

    private let maxCollapsedLines: Int = 8
    private let maxCollapsedHeight: CGFloat = 150

    private func updateCollapseCache() {
        if lastTextForCollapse != message.text {
            lastTextForCollapse = message.text
            cachedLineCount = computeLineCount()
            cachedShouldCollapse = computeShouldCollapse()
            os_log("SMAlog: [collapse] id=%{public}s text_len=%{public}d lines=%{public}d height=%{public}.1f collapse=%{public}03d", log: bubbleLog, type: .debug, String(message.id.prefix(8)), message.text.count, cachedLineCount, message.text.boundingRect(with: CGSize(width: UIScreen.main.bounds.width * 0.65, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height, cachedShouldCollapse ? 1 : 0)
        }
    }

    private var shouldRenderMarkdown: Bool {
        guard !message.isOutgoing && !message.text.isEmpty else { return false }
        guard message.role != "toolResult" && message.role != "thinking" else { return false }
        return MarkdownCache.shared.needsMarkdown(for: message.id)
    }

    private func computeLineCount() -> Int {
        let textHeight = message.text.boundingRect(
            with: CGSize(width: UIScreen.main.bounds.width * 0.65, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).height
        let lineHeight: CGFloat = 20
        let count = Int(ceil(textHeight / lineHeight))
        os_log("SMAlog: [computeLineCount] id=%{public}s text_len=%{public}d height=%{public}.1f count=%{public}d", log: bubbleLog, type: .debug, String(message.id.prefix(8)), message.text.count, textHeight, count)
        return count
    }

    private func computeShouldCollapse() -> Bool {
        if message.seq != nil {
            os_log("SMAlog: [computeShouldCollapse] id=%{public}s result=000 reason=seq", log: bubbleLog, type: .debug, String(message.id.prefix(8)))
            return false
        }
        let textHeight = message.text.boundingRect(
            with: CGSize(width: UIScreen.main.bounds.width * 0.65, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).height
        os_log("SMAlog: [computeShouldCollapse] id=%{public}s seq=nil lines=%{public}d height=%{public}.1f threshold=%{public}.1f", log: bubbleLog, type: .debug, String(message.id.prefix(8)), cachedLineCount, textHeight, maxCollapsedHeight + 10)
        if cachedLineCount < 4 {
            os_log("SMAlog: [computeShouldCollapse] id=%{public}s result=000 reason=lines<4 (count=%{public}d)", log: bubbleLog, type: .debug, String(message.id.prefix(8)), cachedLineCount)
            return false
        }
        if textHeight <= maxCollapsedHeight + 20 && cachedLineCount <= 8 {
            os_log("SMAlog: [computeShouldCollapse] id=%{public}s result=000 reason=within_tolerance", log: bubbleLog, type: .debug, String(message.id.prefix(8)))
            return false
        }
        let result = textHeight >= maxCollapsedHeight + 10
        os_log("SMAlog: [computeShouldCollapse] id=%{public}s result=%{public}03d", log: bubbleLog, type: .debug, String(message.id.prefix(8)), result ? 1 : 0)
        return result
    }

    var body: some View {
        HStack {
            if message.isOutgoing {
                Spacer()
            }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 4) {
                bubbleContent

                HStack(spacing: 8) {
                    if !message.isOutgoing, let seq = message.seq {
                        Text("#\(seq)")
                            .font(.caption2)
                            .foregroundColor(theme.textSecondary)
                    }

                    if message.role == "toolResult" {
                        Text("ToolResult")
                            .font(.caption2)
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.purple)
                            .cornerRadius(4)
                    }

                    if message.role == "thinking" {
                        Text("Thinking")
                            .font(.caption2)
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue)
                            .cornerRadius(4)
                    }

                    if message.role == "toolCall" {
                        Text("ToolCall")
                            .font(.caption2)
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange)
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

                HStack(spacing: 16) {
                    Button {
                        UIPasteboard.general.string = message.text
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                            .foregroundColor(theme.textSecondary)
                    }

                    Button {
                    } label: {
                        Image(systemName: "arrowshape.turn.up.right")
                            .font(.caption)
                            .foregroundColor(theme.textSecondary)
                    }

                    Button {
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
            let shouldMd = shouldRenderMarkdown
            if shouldMd {
                MarkdownCardView(content: message.text)
                    .frame(minHeight: 30, alignment: .topLeading)
                    .background(
                        GeometryReader { geo in
                            Color.clear.onAppear {
                                measuredHeight = geo.size.height
                                isMarkdownCollapsed = geo.size.height > maxCollapsedHeight && !isExpanded
                            }
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: isExpanded ? nil : safeHeight, alignment: .topLeading)
                    .clipped()
            } else if message.role == "thinking" {
                ThinkingCardView(content: message.text)
                    .frame(maxWidth: .infinity, maxHeight: isExpanded ? nil : safeHeight, alignment: .topLeading)
                    .clipped()
            } else if message.role == "toolResult" {
                Text(formatJsonText(message.text))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(message.isOutgoing ? .white : theme.textPrimary)
                    .lineLimit(shouldCollapse ? (isExpanded ? nil : maxCollapsedLines) : nil)
                    .fixedSize(horizontal: false, vertical: true)
            } else if message.role == "toolCall" {
                Text(message.text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(message.isOutgoing ? .white : theme.textPrimary)
                    .lineLimit(shouldCollapse ? (isExpanded ? nil : maxCollapsedLines) : nil)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(message.text)
                    .font(.body)
                    .foregroundColor(message.isOutgoing ? .white : theme.textPrimary)
                    .lineLimit(isExpanded ? nil : maxCollapsedLines)
            }

            if shouldCollapse && !isExpanded {
                Button {
                    isExpanded = true
                } label: {
                    Text("Show more...")
                        .font(.caption)
                        .foregroundColor(message.isOutgoing ? .white.opacity(0.8) : theme.primary)
                }
                .padding(.top, 4)
            }
        }
    }

    private var shouldShowExpandButton: Bool {
        let should = message.isOutgoing == false && !message.text.isEmpty && shouldCollapse && !isExpanded
        os_log("SMAlog: [shouldShowExpandButton] id=%{public}s should=%{public}03d", log: bubbleLog, type: .debug, String(message.id.prefix(8)), should ? 1 : 0)
        return should
    }

    private var shouldCollapse: Bool {
        CollapseStateCache.shared.shouldCollapse(for: message)
    }

    private var safeHeight: CGFloat {
        CollapseStateCache.shared.safeCollapseHeight(for: message) ?? maxCollapsedHeight
    }

    private var lineCount: Int {
        cachedLineCount
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
    var state: String
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
