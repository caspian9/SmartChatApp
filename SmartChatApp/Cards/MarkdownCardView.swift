import SwiftUI
import OpenClawKit

// MARK: - Markdown card view (uses swift-markdown + AttributedString)
//
// Replaces the previous `MarkdownCardView → MarkdownViewTextKit`
// (third-party `MarkdownDisplayView`) path. The third-party lib
// ran a multi-pass TextKit layout whose `onHeightChange` callback
// fired repeatedly during streaming→final transition, driving a
// SwiftUI layout feedback loop that the user saw as bubble-content
// jitter on device 2026-06-29. Building the attributed string in
// a single pass via `MarkdownToAttributedString` and rendering it
// through SwiftUI's native `Text(_: AttributedString)` skips the
// height-binding feedback loop entirely.
//
// Used by `CardRegistry` for tool-result cards (`.markdown`
// cardType) and by `MessageBubbleView` for the assistant bubble's
// final state (replaces the previous `MarkdownCardView` mount).
struct MarkdownCardView: View {
    @Environment(\.theme) private var theme
    let content: String

    var body: some View {
        // `AttributedString`'s intrinsic size is computed once per
        // `content` change. Unlike the previous
        // `UIViewRepresentable`-wrapping `MarkdownViewTextKit`,
        // there is no asynchronous `onHeightChange` callback that
        // re-fires during layout settling — `Text(attributedString)`
        // reports its final size synchronously, so SwiftUI's layout
        // pass for this bubble doesn't oscillate.
        Text(MarkdownToAttributedString.render(content, theme: theme))
            .font(.body)
            .foregroundColor(theme.textPrimary)
            .textSelection(.enabled)
            // `OpenURLAction` reads from the environment (set by
            // the parent chat view) — `AttributedString.link`
            // attributes surface the destination here.
            .environment(\.openURL, OpenURLAction { url in
                UIApplication.shared.open(url)
                return .handled
            })
    }
}

// MARK: - Card registry helpers (unchanged)

public struct MarkdownCardData: Equatable {
    public let id: String
    public let content: String

    public init(id: String = UUID().uuidString, content: String) {
        self.id = id
        self.content = content
    }

    public static func == (lhs: MarkdownCardData, rhs: MarkdownCardData) -> Bool {
        lhs.id == lhs.id && lhs.content == rhs.content
    }
}

public struct MarkdownToolResult: CardToolResult {
    public let cardType: CardType = .markdown
    public let toolName: String = "markdown"

    public init() {}

    public func parseResult(from arguments: AnyCodable?) -> Any? {
        guard let dict = arguments?.value as? [String: Any],
              let content = dict["content"] as? String else { return nil }
        return MarkdownCardData(content: content)
    }
}