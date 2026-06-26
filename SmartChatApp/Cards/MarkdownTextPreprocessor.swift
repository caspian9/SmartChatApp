import Foundation

/// Preprocesses assistant text for the `MarkdownCardView` rendering
/// path. See `MarkdownTextPreprocessorTests` for the regression
/// rationale (issue #23).
///
/// `MarkdownCardView` hands its `content` to `MarkdownViewTextKit`,
/// a CommonMark renderer from `MarkdownDisplayView`. CommonMark
/// collapses a single newline to a space (it's a "soft break"), so
/// server responses that use single newlines for visual line breaks
/// came out as a single paragraph in the final bubble.
///
/// Streaming bubbles are unaffected because they render via SwiftUI
/// `Text(...)` (which preserves newlines). Only the post-`lifecycle=end`
/// markdown view hits this, so the conversion is applied at the view
/// layer (here) — `ChatMessage.text` stays a faithful copy of the
/// server payload.
///
/// Conversion rule: any newline whose immediate neighbors are BOTH
/// not newlines becomes a CommonMark hard break (`<br>` followed by
/// a newline). `MarkdownViewTextKit` honors raw HTML per the CommonMark
/// spec, so the renderer emits a real line break instead of a space.
/// Adjacent paragraph separators (two newlines in a row) are left
/// alone — touching them would collapse paragraph breaks into hard
/// breaks and change visual layout.
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
            with: "<br>\n",
            options: .regularExpression
        )
    }
}