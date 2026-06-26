import XCTest
@testable import SmartChatApp

/// Regression: issue #23 — `MarkdownCardView` routes the final
/// assistant text through `MarkdownViewTextKit` (a CommonMark
/// renderer from `MarkdownDisplayView`). CommonMark collapses a
/// single `\n` to a space, so server responses that use single `\n`
/// for visual line breaks came out as a single paragraph in the
/// final bubble.
///
/// The streaming path is unaffected because it uses SwiftUI
/// `Text(message.text)` directly (preserves `\n`). Only the post-
/// `lifecycle=end` markdown render hits this. The fix preprocesses
/// the text right before it enters `MarkdownViewTextKit`:
/// single `\n` (not adjacent to another `\n`) becomes a CommonMark
/// hard break (`<br>\n`), so the renderer emits a real line break
/// instead of a space. `\n\n` paragraph breaks are left alone.
///
/// `MarkdownTextPreprocessor.preservingSingleNewlines` is the
/// single source of truth for the conversion. `MarkdownCardView`
/// calls it in `body` before constructing `MarkdownViewRepresentable`.
final class MarkdownTextPreprocessorTests: XCTestCase {
    func test_preservingSingleNewlines_emptyString_isUnchanged() {
        XCTAssertEqual(
            MarkdownTextPreprocessor.preservingSingleNewlines(""),
            ""
        )
    }

    func test_preservingSingleNewlines_textWithoutNewlines_isUnchanged() {
        let input = "Hello, world"
        XCTAssertEqual(
            MarkdownTextPreprocessor.preservingSingleNewlines(input),
            input
        )
    }

    func test_preservingSingleNewlines_singleNewline_betweenLines_becomesHardBreak() {
        // Repro from issue #23 (2026-06-25 device log). Server payload
        // contains a list of single-newline-separated lines; the bubble
        // should render one line per row, not one space-joined paragraph.
        let input = "行 1：数据加载中...\n行 2：正在处理请求...\n行 3：API 调用成功 ✅"
        let expected = "行 1：数据加载中...<br>\n行 2：正在处理请求...<br>\n行 3：API 调用成功 ✅"
        XCTAssertEqual(
            MarkdownTextPreprocessor.preservingSingleNewlines(input),
            expected
        )
    }

    func test_preservingSingleNewlines_paragraphBreaks_arePreserved() {
        // `\n\n` is the CommonMark paragraph separator. The conversion
        // MUST leave adjacent `\n\n` alone — replacing the middle `\n`
        // would collapse the paragraph break into a hard break and
        // change visual layout.
        let input = "First paragraph.\n\nSecond paragraph."
        XCTAssertEqual(
            MarkdownTextPreprocessor.preservingSingleNewlines(input),
            input
        )
    }

    func test_preservingSingleNewlines_trailingSingleNewline_isConverted() {
        // Edge case: a trailing single `\n` is preceded by a non-`\n`
        // char and followed by end-of-string. It SHOULD be converted,
        // so the renderer doesn't drop a trailing visual line break.
        let input = "Hello\n"
        let expected = "Hello<br>\n"
        XCTAssertEqual(
            MarkdownTextPreprocessor.preservingSingleNewlines(input),
            expected
        )
    }

    func test_preservingSingleNewlines_leadingSingleNewline_isConverted() {
        // Edge case: a leading single `\n` is followed by a non-`\n`
        // char and preceded by start-of-string. It SHOULD be converted.
        let input = "\nHello"
        let expected = "<br>\nHello"
        XCTAssertEqual(
            MarkdownTextPreprocessor.preservingSingleNewlines(input),
            expected
        )
    }
}
