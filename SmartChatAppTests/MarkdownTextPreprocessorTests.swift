import XCTest
@testable import SmartChatApp

/// Unit tests for the byte-level transformation performed by
/// `MarkdownTextPreprocessor`. The "does this actually render as a
/// line break in the bubble" guarantee is provided by
/// `MarkdownTextPreprocessorIntegrationTests`, which parses the
/// preprocessed output through `swift-markdown` (the parser the
/// renderer uses under the hood) and asserts `LineBreak` AST nodes
/// are emitted.
///
/// These unit tests pin the contract of the regex replacement:
/// empty / no-newline / paragraph-break / leading / trailing cases
/// are handled as documented. They run fast and isolate the regex
/// from the parser dep — useful when refactoring the helper without
/// re-parsing the full markdown tree.
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
        // Each single \n becomes "  \n" (two trailing spaces + newline),
        // the CommonMark hard-break sequence. swift-markdown parses it
        // as a LineBreak AST node; MarkdownDisplayView renders it as a
        // real line break.
        let expected = "行 1：数据加载中...  \n行 2：正在处理请求...  \n行 3：API 调用成功 ✅"
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
        // char and followed by end-of-string. It SHOULD be converted —
        // the trailing `\n` becomes two spaces + newline, which the
        // CommonMark parser treats as a hard break at end-of-line.
        let input = "Hello\n"
        let expected = "Hello  \n"
        XCTAssertEqual(
            MarkdownTextPreprocessor.preservingSingleNewlines(input),
            expected
        )
    }

    func test_preservingSingleNewlines_leadingSingleNewline_isConverted() {
        // Edge case: a leading single `\n` is followed by a non-`\n`
        // char and preceded by start-of-string. It SHOULD be converted.
        // Result: leading two spaces + newline, which the CommonMark
        // parser ignores (no preceding content to break) and the
        // content after the newline renders on a fresh line.
        let input = "\nHello"
        let expected = "  \nHello"
        XCTAssertEqual(
            MarkdownTextPreprocessor.preservingSingleNewlines(input),
            expected
        )
    }
}