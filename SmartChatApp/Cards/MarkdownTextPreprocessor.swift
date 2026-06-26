import Foundation

/// Preprocesses assistant text for the `MarkdownCardView` rendering
/// path. See `MarkdownTextPreprocessorTests` and
/// `MarkdownTextPreprocessorIntegrationTests` for the regression
/// rationale (issue #23).
///
/// `MarkdownCardView` hands its `content` to `MarkdownViewTextKit`,
/// a CommonMark renderer from `MarkdownDisplayView`. Per the CommonMark
/// spec, a single newline is a "soft break" — rendered as a space.
/// Server responses use single newlines for visual line breaks (e.g.
/// multi-step progress lists), so the final bubble came out as a
/// single space-joined paragraph.
///
/// Streaming bubbles are unaffected because they render via SwiftUI
/// `Text(...)`, which preserves newlines natively. Only the post-
/// `lifecycle=end` markdown view hits this, so the conversion lives
/// at the view layer — `ChatMessage.text` stays a faithful copy of
/// the server payload.
///
/// Conversion rule: any newline whose immediate neighbors are BOTH
/// not newlines becomes a CommonMark hard break (two trailing spaces
/// followed by a newline). `swift-markdown` emits a `LineBreak` AST
/// node for this pattern, and `MarkdownDisplayView`'s renderer
/// translates that node into a real line break (`renderLineBreak`
/// returns "\n").
///
/// Why not raw HTML (`<br>`)? `MarkdownDisplayView.renderInlineHTML`
/// does not interpret raw HTML — it renders it as literal text in the
/// code font. `<br>` would appear in the bubble as the literal text
/// "<br>" rather than as a break, which would be worse than the
/// original bug. Two-trailing-spaces is the only CommonMark hard-break
/// form that survives the pipeline end-to-end.
enum MarkdownTextPreprocessor {
    /// Convert "lone" newlines to CommonMark hard breaks; leave
    /// paragraph separators (two adjacent newlines) untouched.
    ///
    /// The match uses negative lookbehind and negative lookahead
    /// to find a newline that is NOT adjacent to another newline.
    /// Both assertions are bounded to a single character, so the
    /// scan is linear-time regardless of input length — no ReDoS
    /// risk.
    static func preservingSingleNewlines(_ text: String) -> String {
        return text.replacingOccurrences(
            of: "(?<!\n)\n(?!\n)",
            with: "  \n",
            options: .regularExpression
        )
    }
}