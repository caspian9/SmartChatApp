import XCTest
import Markdown
@testable import SmartChatApp

/// Integration tests for `MarkdownTextPreprocessor`. The unit tests
/// in `MarkdownTextPreprocessorTests` pin the regex behavior; this
/// file pins the END-TO-END contract — that the preprocessor's
/// output is recognized by `swift-markdown` (the parser the
/// renderer uses under the hood) as CommonMark hard breaks.
///
/// This is the verification that catches the failure mode of the
/// original fix attempt (replacing `\n` with `<br>`), which
/// satisfied the unit tests but rendered as literal "<br>" text in
/// the bubble because `MarkdownDisplayView.renderInlineHTML` does
/// not interpret raw HTML.
final class MarkdownTextPreprocessorIntegrationTests: XCTestCase {
    /// Repro from issue #23 (2026-06-25 device log). After
    /// preprocessing, the AST must contain `LineBreak` nodes between
    /// the three progress lines — otherwise the renderer would
    /// collapse them back into a single space-joined paragraph.
    func test_preprocessorOutput_parsesAsCommonMarkHardBreaks() throws {
        let input = "行 1：数据加载中...\n行 2：正在处理请求...\n行 3：API 调用成功 ✅"
        let preprocessed = MarkdownTextPreprocessor.preservingSingleNewlines(input)

        let document = Document(parsing: preprocessed)
        let paragraph = try XCTUnwrap(document.child(at: 0) as? Paragraph,
            "Expected the first block to be a single paragraph (3 lines joined by hard breaks)")

        let children = Array(paragraph.children)
        let lineBreakCount = children.filter { $0 is LineBreak }.count
        XCTAssertEqual(lineBreakCount, 2,
            "Expected 2 hard-break LineBreak nodes between 3 lines, got \(lineBreakCount). AST children: \(children)")
    }

    /// `\n\n` paragraph separators must survive preprocessing —
    /// the preprocessor must NOT collapse them into hard breaks.
    func test_preprocessorOutput_paragraphBreakIsStillAParagraph() throws {
        let input = "First paragraph.\n\nSecond paragraph."
        let preprocessed = MarkdownTextPreprocessor.preservingSingleNewlines(input)

        let document = Document(parsing: preprocessed)
        let paragraphs = document.children.compactMap { $0 as? Paragraph }
        XCTAssertEqual(paragraphs.count, 2,
            "Expected 2 paragraph blocks separated by paragraph break, got \(paragraphs.count). Children: \(document.children)")
    }

    /// Sanity baseline: WITHOUT preprocessing, `swift-markdown` does
    /// NOT emit `LineBreak` for a single `\n`. Documents the bug
    /// baseline (issue #23) so the fix's added `LineBreak` nodes are
    /// attributable to the preprocessor and not to the parser
    /// changing under us.
    func test_unpreprocessed_singleNewline_isNotAHardBreak() throws {
        let input = "Line 1\nLine 2"
        let document = Document(parsing: input)
        let paragraph = try XCTUnwrap(document.child(at: 0) as? Paragraph)

        XCTAssertFalse(Array(paragraph.children).contains { $0 is LineBreak },
            "Baseline check: without preprocessing, swift-markdown should NOT emit a LineBreak for a single \\n")
    }
}