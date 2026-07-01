import SwiftUI

struct ViewHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct MessageBubbleView: View {
    @Environment(\.theme) private var theme
    let message: ChatMessage
    /// Invoked when the user taps "Show more..." to expand this bubble,
    /// or when an external caller (e.g. `MessageReceiver` at `lifecycle
    /// end`) wants to mark it expanded. The callback is responsible for
    /// writing through to `viewModel.messages[i] = updated` so the
    /// `@Observable` setter on the store fires and the parent view
    /// re-evaluates body. `MessageBubbleView` itself no longer reaches
    /// into any external collapse-state cache — `isExpanded` reads
    /// directly off `message.isUserExpanded`, so the value travels with
    /// the message through the new `MessageCacheStore` SoT
    /// (refresh, session switch, history replace) without any cache
    /// tracking dependency.
    var onExpandChange: (Bool) -> Void

    @ObservedObject private var collapseCache = CollapseStateCache.shared

    private let maxCollapsedLines: Int = 8
    private let maxCollapsedHeight: CGFloat = 150

    private func truncateToLines(_ text: String, maxLines: Int) -> String {
        let lines = text.components(separatedBy: "\n")
        if lines.count <= maxLines {
            return text
        }
        return lines.prefix(maxLines).joined(separator: "\n")
    }

    private var shouldRenderMarkdown: Bool {
        // User-toggled global: when off, never render markdown — the
        // bubble shows the raw source so the user can see exactly
        // what the model emitted (e.g., `**bold**` stays literal).
        // The role / outgoing / empty-text pre-filters live inside
        // `MarkdownCache.needsMarkdown(for:)` so the cache lookup
        // and the result can't diverge between writers.
        guard ConfigurationManager.shared.renderMarkdown else { return false }
        return MarkdownCache.shared.needsMarkdown(for: message)
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

                    let badge = MessageBubbleBadgeResolver.badge(for: message)
                    if badge != .none {
                        // Decorative metadata tag — the bubble's role is
                        // already conveyed by alignment (outgoing/incoming)
                        // and styling, so hiding the chip from VoiceOver
                        // keeps the bubble's accessibility tree focused on
                        // the message content. If a user wants the chip
                        // surfaced as a label later, swap this for
                        // `.accessibilityLabel(badge.label)`.
                        Text(badge.label)
                            .font(.caption2)
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(badge.backgroundColor(theme: theme))
                            .cornerRadius(4)
                            .accessibilityHidden(true)
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
        // No `.onAppear` rehydration: the `isExpanded` computed reads
        // `collapseCache.isExpanded(id)` from `body`, and SwiftUI's
        // observation tracking handles all of the re-evaluation. The
        // cache is `@Observable`, so the view registers a dependency
        // on `expandedMessageIds` at first body computation; the
        // `Show more` button mutates the cache; the bubble re-renders.
    }

    @ViewBuilder
    private var bubbleContent: some View {
        // System bubbles render their own chrome (muted
        // card + 3pt left bar) inside the `system` role branch of
        // `messageText`. Skip the standard bubble padding/background/
        // cornerRadius here so the system bubble doesn't get
        // double-wrapped.
        if message.role == "system" {
            messageText
        } else if message.text.isEmpty {
            // Show 3 dots while waiting for the first streaming delta. Once
            // `message.text` becomes non-empty, the outer `if` falls through
            // to the text branch and this indicator is no longer rendered,
            // so the dots naturally disappear the moment content arrives.
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
                // Trailing typing dots for non-assistant, non-user streaming
                // roles (thinking, toolCall, toolResult). Only emitted while
                // `state == "streaming"` — when the message reaches `final`,
                // we drop the slot entirely so the bubble collapses to its
                // real height instead of leaving a 10pt blank row under the
                // text. The 10pt height jump is intentional: it's a clear
                // visual signal that the message is done, and the next user
                // gesture (tap to focus input, scroll) immediately anchors
                // the viewport to the new bottom via scrollTo.
                if !message.isOutgoing && message.role != "assistant" && message.state == "streaming" {
                    TypingIndicatorView()
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
            if isAssistantStreaming {
                // Streaming: render the partial text as raw characters.
                // Markdown formatting is intentionally NOT applied here —
                // the prior `StreamingMarkdownCardView` path routed through
                // `MarkdownViewTextKit` (MarkdownDisplayView) with
                // `typewriterTextMode = .append`, which appends the new
                // characters but does not re-parse the markdown AST on
                // every incremental push. Net effect: the user saw
                // `**condition** clear` with the `**` markers visible
                // (raw text), and the markdown only got applied on the
                // `state == "final"` view swap (`MarkdownCardView`,
                // which sets `view.markdown = markdown` for a one-shot
                // full render). So the streaming view's nominal
                // "markdown formatting" was never visible during
                // streaming — and exit/re-enter (forcing a fresh
                // MarkdownCardView) is what the user relied on to see
                // formatted text. Making it explicit: during streaming
                // we render raw text via SwiftUI `Text`; on the
                // streaming→final transition the view swaps to
                // `MarkdownCardView` for the one-shot full markdown
                // parse. This removes the third-party streaming
                // markdown path (and its TextKit-based height tracking)
                // from the streaming hot loop, and makes the raw→formatted
                // transition an explicit design point rather than a
                // library accident.
                Text(message.text)
                    .font(.body)
                    .foregroundColor(message.isOutgoing ? .white : theme.textPrimary)
            } else {
                let shouldMd = shouldRenderMarkdown
                // Build 7526: collapsed markdown renders as plain
                // text + `lineLimit` instead of `MarkdownCardView`
                // with `.frame(height:).clipped()`. The original
                // `MarkdownCardView.frame(height: 150).clipped()`
                // shape was the user-reported "1. extra blank lines
                // between messages / 2. overlapping messages / 5. last
                // message bottom not at the bottom" root cause on
                // device build 7544. The `MessageTableView`
                // (UITableView-based) architecture that used to
                // host these bubbles amplified the problem: a
                // `UIHostingController` wrapping this
                // `MessageBubbleView` reported the SwiftUI view's
                // `intrinsicContentSize` (= the full natural
                // markdown height, e.g. 1000+ pt for a 1000-char
                // markdown) up to the cell's Auto Layout, and
                // `.clipped()` is a visual-only modifier that
                // does NOT shrink the reported intrinsic content
                // size. So the cell's actual layout height was
                // 1000+ pt (the cell frame matched `heightForRowAt`'s
                // 220 pt, but the hosting view overflowed past it),
                // `scrollToRow(.bottom)` skipped past the real last
                // cell by hundreds of points, and the user saw
                // visual "overlap" + "empty gap" + "bottom is wrong".
                // `Text + lineLimit` is a real layout cap: SwiftUI's
                // Text layout is `lineLimit`-aware and reports the
                // truncated height (8 × lineHeight) as the view's
                // intrinsic content size. The user-visible change:
                // collapsed bubbles show raw text (no markdown
                // rendering — `**bold**` stays literal, lists stay
                // flat). The expanded state keeps the full markdown
                // rendering, so tapping "Show more..." still gives
                // the user the rendered view.
                //
                // Build 7526's switch to pure SwiftUI
                // `ScrollView { LazyVStack }` (deleting
                // `MessageTableView` and `MessageHeightCache`)
                // means there's no UITableView cell + hosting-
                // controller overflow path left to fight. The
                // collapsed cap (Build 7525) is now both
                // necessary (real layout cap) and sufficient
                // (no second-layer hosting-controller drift on
                // top of it).
                if shouldCollapse && !isExpanded && message.state != "streaming"
                    && message.role != "system" {
                    // Collapse check fires FIRST for non-system roles
                    // so long text→raw text + lineLimit (per the
                    // Build 7525 root-cause fix). The `role != "system"`
                    // carve-out keeps system messages on the dedicated
                    // system-card branch below: a 65-line `/help` reply
                    // has its own bordered card (left bar + 1pt hairline
                    // + monospaced text), not the unstyled truncated
                    // text view the collapse path produces. The system
                    // card is content-shaped (column-aligned command
                    // names); truncating it mid-list would be worse than
                    // letting it grow, so we skip collapse for this
                    // role entirely. User can still scroll past a tall
                    // system bubble like any other chat content.
                    Text(plainTextForCollapse)
                        .font(roleTextFont)
                        .foregroundColor(message.isOutgoing ? .white : theme.textPrimary)
                        .lineLimit(collapseLineLimit)
                } else if shouldMd && message.role != "system" {
                    // Same role carve-out as the collapse branch:
                    // system role ALWAYS uses the dedicated system
                    // card (left bar + 1pt hairline + monospaced
                    // text), even when the text happens to match a
                    // markdown pattern. The /profiles reply's
                    // `* name\n  name` lines, for example, trip the
                    // list-item regex (`^[\-\*]\s`) and would
                    // otherwise route to `MarkdownCardView`, which
                    // doesn't apply the system chrome. The system
                    // card is the canonical render for the role; the
                    // formatter is the source of truth for layout
                    // (column-aligned monospaced text), so handing
                    // the same text to a markdown parser would
                    // mangle the alignment.
                    MarkdownCardView(content: message.text)
                } else if message.role == "thinking" {
                    ThinkingCardView(content: message.text)
                        .lineLimit(collapseLineLimit)
                } else if message.role == "toolResult" {
                    Text(formatJsonText(message.text))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(message.isOutgoing ? .white : theme.textPrimary)
                        .lineLimit(collapseLineLimit)
                } else if message.role == "toolCall" {
                    Text(message.text)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(message.isOutgoing ? .white : theme.textPrimary)
                        .lineLimit(collapseLineLimit)
                } else if message.role == "system" {
                    HStack(alignment: .top, spacing: 0) {
                        Rectangle()
                            .fill(theme.primary)
                            .frame(width: 3)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(message.text)
                                // Monospaced so the column alignment that
                                // `LocalCommandRegistry.formatHelpList`
                                // builds via space-padding survives into
                                // rendering. Without `.monospaced`, each
                                // character gets a different width and the
                                // command-name column drifts to the right
                                // for shorter ids (`/acp [action]` ends up
                                // visually offset from `/clear           `).
                                // The `.secondary` color + 14pt size keeps
                                // the visual weight consistent with other
                                // system messages (e.g. "/clear" →
                                // "Chat cleared") that don't have alignment
                                // — the monospace glyphs read as "tabular
                                // info" without feeling like a code block.
                                .font(.system(size: 14, design: .monospaced))
                                .foregroundColor(theme.textPrimary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                    // Full-opacity card on the theme's `cardBackground`
                    // (white in light mode, near-black in dark) so the
                    // system bubble reads as a distinct panel against
                    // the chat's `background` (light gray / pure black).
                    // The earlier `.opacity(0.6)` made the card
                    // effectively invisible on light backgrounds
                    // because the 60% white blended into the 96% white
                    // parent. A 1pt hairline border + corner radius
                    // preserve the card shape even when the card and
                    // chat background land on similar shades.
                    .background(theme.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(theme.textSecondary.opacity(0.2),
                                    lineWidth: 0.5)
                    )
                    .cornerRadius(8)
                } else {
                    Text(message.text)
                        .font(.body)
                        .foregroundColor(message.isOutgoing ? .white : theme.textPrimary)
                        .lineLimit(collapseLineLimit)
                }
            }

            if shouldCollapse && !isExpanded && message.state != "streaming"
                    && message.role != "system" {
                // Same carve-out as the collapse branch in
                // `messageText`: system messages don't get the
                // "Show more..." button because they always render
                // their full content in the system card (see the
                // matching comment in `messageText` for why
                // truncating a column-aligned command list is
                // worse than letting it grow).
                Button {
                    // Hand off to the parent so it can do
                    // `viewModel.messages[i] = updated` (which fires
                    // the `@Observable` setter on `messages` and
                    // re-evaluates this view's body with the new
                    // `isUserExpanded = true`).
                    onExpandChange(true)
                } label: {
                    Text("Show more...")
                        .font(.caption)
                        .foregroundColor(message.isOutgoing ? .white.opacity(0.8) : theme.primary)
                }
                .padding(.top, 4)
            }
        }
    }

    /// Streaming assistant message: route to real streaming markdown view.
    /// Markdown plain text is also fine here (MarkdownViewTextKit renders plain text).
    /// When the user toggled off "Render markdown", we fall through to the
    /// plain `Text` branch in `messageText` even during streaming.
    private var isAssistantStreaming: Bool {
        guard ConfigurationManager.shared.renderMarkdown else { return false }
        return message.state == "streaming" && !message.isOutgoing && message.role == "assistant"
    }

    /// User-driven expand state. Reads directly off `message.isUserExpanded`
    /// — the value travels with the message through the new
    /// `MessageCacheStore` SoT (refresh, session switch,
    /// history replace). No external cache tracking required: when
    /// `onExpandChange(true)` writes through to
    /// `CollapseStateCache.shared.setExpanded(msg.id, true)` (the parent view's job), the
    /// `@Observable` setter on `messages` fires, the parent re-evaluates
    /// `ForEach`, and the new `message` (with `isUserExpanded = true`)
    /// reaches this view's body. `HistoryLoader` is responsible for
    /// merging old `isUserExpanded` values into freshly-networked
    /// messages so refresh doesn't drop the user's expand state.
    private var isExpanded: Bool {
        message.isUserExpanded ?? false
    }

    private var collapseLineLimit: Int? {
        // User-toggled global: when off, never cap the line count —
        // the bubble always renders the full text. Default ON.
        if !ConfigurationManager.shared.collapseLongMessages {
            return nil
        }
        // During streaming and for fresh (this-session) messages, show the
        // full text. Collapse only applies to history messages that were
        // already huge when the user opened the chat.
        if message.state == "streaming" || message.isFresh {
            return nil
        }
        return isExpanded ? nil : maxCollapsedLines
    }

    private var shouldShowExpandButton: Bool {
        let should = message.isOutgoing == false && !message.text.isEmpty && shouldCollapse && !isExpanded
        return should
    }

    private var shouldCollapse: Bool {
        // User-toggled global: when off, never collapse any message —
        // the bubble always renders the full text. Default ON.
        if !ConfigurationManager.shared.collapseLongMessages {
            return false
        }
        // Fresh messages (arrived in this chat session) stay fully expanded.
        // Collapse only applies to history messages loaded when the user
        // re-enters the native chat page.
        if message.isFresh {
            return false
        }
        // Already-expanded messages (user tapped Show more, or
        // `MessageReceiver` marked at lifecycle end) should never
        // auto-collapse, even after a fresh history load —
        // `CollapseStateCache.shared.expandedMessageIds` persists
        // across reloads, and `NativeChatView.messages` re-merges
        // it on every body evaluation.
        if message.isUserExpanded == true {
            return false
        }
        return CollapseStateCache.shared.shouldCollapse(for: message)
    }

    private func formatTime(_ timestamp: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }

    /// Text payload rendered in the collapsed state. Matches the
    /// non-markdown role branches' payloads so collapsed toolResult
    /// bubbles still show pretty-printed JSON (not raw JSON string)
    /// and collapsed thinking / toolCall / plain bubbles show raw
    /// text. The collapsed path bypasses `MarkdownCardView` entirely
    /// — see the Build 7525 comment in `messageText` for why.
    private var plainTextForCollapse: String {
        if message.role == "toolResult" {
            return formatJsonText(message.text)
        }
        return message.text
    }

    /// Font used for the collapsed-state `Text`. Mirrors the
    /// non-markdown role branches so collapsed `toolCall` /
    /// `toolResult` bubbles use the monospaced caption font and
    /// everything else uses `.body`.
    private var roleTextFont: Font {
        switch message.role {
        case "toolCall", "toolResult":
            return .system(.caption, design: .monospaced)
        default:
            return .body
        }
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
    /// True for messages that arrived in the current chat session (sent
    /// by the user or streamed from the agent). False for messages loaded
    /// from history.
    var isFresh: Bool = false
    /// Wall-clock time of the LAST `MessageReceiver.receiveMessage`
    /// call for this id. Used by the view-layer sort to put the
    /// most recently updated streaming bubble at the bottom (the
    /// persisted `timestamp` is the run's start time, not the latest
    /// activity time, so without this field a fresh final from an
    /// older run would sort BELOW a still-streaming placeholder from
    /// a newer run). In-memory only — defaults nil; the VM's
    /// streaming-metadata overlay populates it for in-session
    /// bubbles. Historical bubbles (loaded from `chat.history` on
    /// session open) have no overlay, so the sort falls back to
    /// `timestamp`.
    var receivedAt: Date? = nil
    /// User-driven expand state. Lives on the message struct so the
    /// parent view's `messages` computed property can merge it from
    /// `CollapseStateCache.expandedMessageIds` per render. `nil` until
    /// the user taps "Show more..." (or `MessageReceiver` marks it at
    /// `lifecycle end`); then `true` keeps the bubble expanded, `false`
    /// collapses it. **Included in `==` below** — when the parent
    /// produces a new ChatMessage with a different `isUserExpanded`,
    /// SwiftUI's ForEach diff must see it as != so the child
    /// `MessageBubbleView.body` re-evaluates and the bubble actually
    /// expands. The legacy rationale for excluding it (EventInterpreter
    /// / MessageReceiver array diffs churning on expand toggles) no
    /// longer applies in the new `MessageCacheStore` architecture —
    /// those writers go through `store.append` / `store.upsert`,
    /// not through a per-VM `messages` array.
    var isUserExpanded: Bool? = nil

    var isOutgoing: Bool {
        role.lowercased() == "user"
    }

    /// The converter's per-source shared fields. Most fields
    /// (timestamp, seq, startedAt, endedAt, state, usage, toolCall*)
    /// are shared across every ChatMessage emitted from a single
    /// `OpenClawChatMessage` (text vs. thinking entries); the
    /// converter passes them in this struct so it can build each
    /// entry without repeating 12+ named arguments. Kept here
    /// (not in the converter file) so the file that owns the
    /// `ChatMessage` type also owns the type that drives its
    /// secondary init.
    struct ChatMessageBaseFields {
        let timestamp: Date
        let seq: Int?
        let startedAt: Date?
        let endedAt: Date?
        let state: String
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheRead: Int?
        let cacheWrite: Int?
        let toolCallId: String?
        let toolName: String?
        let stopReason: String?
    }

    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        // All view-rendering fields are included. The previous
        // implementation omitted `inputTokens` / `outputTokens` /
        // `cacheRead` / `cacheWrite` / `toolCallId` / `toolName` /
        // `stopReason`, which caused a streaming delta that only
        // updated usage numbers to look "equal" to the previous
        // value — `ForEach` would skip the re-render and the
        // metadata HStack would stay stale until the next text
        // change. Including them here closes that gap.
        lhs.id == rhs.id &&
        lhs.text == rhs.text &&
        lhs.timestamp == rhs.timestamp &&
        lhs.role == rhs.role &&
        lhs.state == rhs.state &&
        lhs.runId == rhs.runId &&
        lhs.seq == rhs.seq &&
        lhs.startedAt == rhs.startedAt &&
        lhs.endedAt == rhs.endedAt &&
        lhs.livenessState == rhs.livenessState &&
        lhs.inputTokens == rhs.inputTokens &&
        lhs.outputTokens == rhs.outputTokens &&
        lhs.cacheRead == rhs.cacheRead &&
        lhs.cacheWrite == rhs.cacheWrite &&
        lhs.toolCallId == rhs.toolCallId &&
        lhs.toolName == rhs.toolName &&
        lhs.stopReason == rhs.stopReason &&
        lhs.isFresh == rhs.isFresh &&
        lhs.isUserExpanded == rhs.isUserExpanded
    }
}

extension ChatMessage {
    /// Convenience initializer for the converter. Lives in
    /// an extension (NOT in the struct body) so the auto-
    /// synthesized memberwise init is still generated — adding
    /// the explicit init in the struct body would suppress it
    /// and break every existing call site (e.g. `sendMessage`'s
    /// user-bubble construction) that uses positional args.
    init(id: String, text: String, role: String, base: ChatMessageBaseFields) {
        self.id = id
        self.text = text
        self.timestamp = base.timestamp
        self.role = role
        self.state = base.state
        self.runId = nil
        self.seq = base.seq
        self.startedAt = base.startedAt
        self.endedAt = base.endedAt
        self.livenessState = nil
        self.inputTokens = base.inputTokens
        self.outputTokens = base.outputTokens
        self.cacheRead = base.cacheRead
        self.cacheWrite = base.cacheWrite
        self.toolCallId = base.toolCallId
        self.toolName = base.toolName
        self.stopReason = base.stopReason
        self.isFresh = false
        self.isUserExpanded = nil
    }
}
