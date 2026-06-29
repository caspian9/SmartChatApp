import Foundation
import Markdown
import SwiftUI

/// Walks a `swift-markdown` AST and produces a styled
/// `AttributedString` ready for SwiftUI `Text` rendering.
///
/// Replaces the previous `MarkdownCardView → MarkdownViewTextKit`
/// (third-party `MarkdownDisplayView`) path that flickered on the
/// streaming→final transition on device 2026-06-29 (the
/// third-party library ran a multi-pass TextKit layout whose
/// `onHeightChange` callback fired repeatedly during the transition,
/// driving a SwiftUI layout feedback loop that the user saw as
/// bubble-content jitter). Building the attributed string in a
/// single pass and rendering it through SwiftUI's native
/// `Text(_: AttributedString)` skips the height-binding
/// feedback loop entirely — `Text(attributedString)`'s intrinsic
/// size is computed once per `content` change, with no
/// asynchronous re-measurement.
///
/// The parser used here is `swift-markdown` (already a transitive
/// dependency via `MarkdownDisplayView`; lifted to a direct
/// `SmartChatApp` dependency in `project.yml` so this file can
/// `import Markdown` directly). `swift-markdown` produces a
/// full CommonMark AST — `Document.children` walks top-level
/// blocks, each block has its own `children` for inline content
/// (text, emphasis, strong, code, links, line breaks). We visit
/// each node once, applying the corresponding `AttributeContainer`
/// style (font, foreground, link).
///
/// Hard-break handling (`\n` → line break) preserves the
/// `MarkdownTextPreprocessor.preservingSingleNewlines` rule from
/// issue #23: lone newlines become CommonMark hard breaks
/// (`  \n`), which `swift-markdown` parses as a `LineBreak` AST
/// node that we translate to `AttributedString` `\n`.
///
/// Trade-offs vs the previous `MarkdownViewTextKit` path:
///   - **Gained**: zero-height-binding feedback, no flicker, no
///     `UIViewRepresentable` lifecycle complications, no
///     `MarkdownStreamManager` fallback cache.
///   - **Lost**: table layout (we render as plain text), fenced
///     code-block syntax highlighting (we render as monospaced
///     text), HTML passthrough (we drop the raw HTML rather than
///     escaping). For our assistant reply stream these features
///     were rarely exercised by the model and the simplicity win
///     outweighs the loss.
enum MarkdownToAttributedString {
    /// Render a CommonMark-marked string into a styled
    /// `AttributedString`. The caller passes the theme so the
    /// output matches the rest of the chat bubble styling. The
    /// `baseFont` is applied to plain text; headings, strong,
    /// emphasis, and code override it.
    static func render(_ text: String, theme: Theme, baseFont: Font = .body) -> AttributedString {
        let preprocessed = MarkdownTextPreprocessor.preservingSingleNewlines(text)
        let document = Document(parsing: preprocessed)
        var result = AttributedString()
        var isFirstBlock = true
        for child in document.children {
            if !isFirstBlock {
                // Block-level separator. swift-markdown models
                // adjacent block elements as siblings; we use a
                // single newline to keep paragraphs visually
                // separated without an extra blank line.
                result.append(AttributedString("\n"))
            }
            isFirstBlock = false
            renderBlock(child, into: &result, theme: theme, baseFont: baseFont)
        }
        return result
    }

    // MARK: - Block dispatch

    private static func renderBlock(
        _ block: Markup,
        into result: inout AttributedString,
        theme: Theme,
        baseFont: Font
    ) {
        switch block {
        case let heading as Heading:
            renderHeading(heading, into: &result, theme: theme)
        case let paragraph as Paragraph:
            renderInlineChildren(of: paragraph, into: &result, theme: theme, baseFont: baseFont)
        case let list as UnorderedList:
            renderUnorderedList(list, into: &result, theme: theme, baseFont: baseFont)
        case let list as OrderedList:
            renderOrderedList(list, into: &result, theme: theme, baseFont: baseFont)
        case let blockQuote as BlockQuote:
            renderBlockQuote(blockQuote, into: &result, theme: theme, baseFont: baseFont)
        case let codeBlock as CodeBlock:
            renderCodeBlock(codeBlock, into: &result, theme: theme)
        case let html as HTMLBlock:
            // Drop raw HTML rather than rendering it as code (the
            // previous MarkdownViewTextKit path displayed `<br>`
            // as the literal text "<br>" — same outcome we get
            // here, but without the extra dependency on the
            // third-party lib's HTML handling). `HTMLBlock` exposes
            // its source via `rawHTML` (not `plainText`); we render
            // it as visible text so the user sees the raw `<tag>`
            // rather than silently dropping it.
            result.append(AttributedString(html.rawHTML))
        case let thematic as ThematicBreak:
            renderThematicBreak(into: &result)
        default:
            // Catch-all for block types we don't have a specialized
            // renderer for (tables, etc.). Walk the inline
            // children so any text + emphasis + strong inside
            // still gets the right styling; missing structure
            // (e.g. table cell borders) shows as plain lines.
            renderInlineChildren(of: block, into: &result, theme: theme, baseFont: baseFont)
        }
    }

    private static func renderHeading(
        _ heading: Heading,
        into result: inout AttributedString,
        theme: Theme
    ) {
        let font: Font
        switch heading.level {
        case 1: font = .system(size: 22, weight: .bold)
        case 2: font = .system(size: 20, weight: .bold)
        case 3: font = .system(size: 18, weight: .semibold)
        case 4: font = .system(size: 16, weight: .semibold)
        case 5: font = .system(size: 14, weight: .medium)
        default: font = .system(size: 13, weight: .medium)
        }
        var run = AttributedString()
        renderInlineChildren(of: heading, into: &run, theme: theme, baseFont: font)
        // Headings get a trailing newline so the next block starts
        // on a new line — the block separator added by the parent
        // already handles block-to-block spacing, but explicit
        // runs help Text lay out the heading cleanly.
        run.append(AttributedString("\n"))
        result.append(run)
    }

    private static func renderUnorderedList(
        _ list: UnorderedList,
        into result: inout AttributedString,
        theme: Theme,
        baseFont: Font
    ) {
        for child in list.children {
            guard let item = child as? ListItem else { continue }
            result.append(AttributedString("• "))
            // The ListItem's children may include paragraphs (the
            // first one always does) and nested lists. Render
            // each child as its own block to preserve the visual
            // structure.
            var firstInline = true
            for itemChild in item.children {
                if firstInline, let paragraph = itemChild as? Paragraph {
                    renderInlineChildren(of: paragraph, into: &result, theme: theme, baseFont: baseFont)
                    firstInline = false
                } else if let nestedList = itemChild as? UnorderedList {
                    renderUnorderedList(nestedList, into: &result, theme: theme, baseFont: baseFont)
                } else if let nestedList = itemChild as? OrderedList {
                    renderOrderedList(nestedList, into: &result, theme: theme, baseFont: baseFont)
                } else {
                    renderBlock(itemChild, into: &result, theme: theme, baseFont: baseFont)
                }
            }
            result.append(AttributedString("\n"))
        }
    }

    private static func renderOrderedList(
        _ list: OrderedList,
        into result: inout AttributedString,
        theme: Theme,
        baseFont: Font
    ) {
        // `swift-markdown` exposes `OrderedList.startIndex` (1-based
        // by default; the model rarely overrides it) so we can use
        // it as the visible number for each item.
        var index = list.startIndex
        for child in list.children {
            guard let item = child as? ListItem else { continue }
            result.append(AttributedString("\(index). "))
            var firstInline = true
            for itemChild in item.children {
                if firstInline, let paragraph = itemChild as? Paragraph {
                    renderInlineChildren(of: paragraph, into: &result, theme: theme, baseFont: baseFont)
                    firstInline = false
                } else if let nestedList = itemChild as? UnorderedList {
                    renderUnorderedList(nestedList, into: &result, theme: theme, baseFont: baseFont)
                } else if let nestedList = itemChild as? OrderedList {
                    renderOrderedList(nestedList, into: &result, theme: theme, baseFont: baseFont)
                } else {
                    renderBlock(itemChild, into: &result, theme: theme, baseFont: baseFont)
                }
            }
            result.append(AttributedString("\n"))
            index += 1
        }
    }

    private static func renderBlockQuote(
        _ quote: BlockQuote,
        into result: inout AttributedString,
        theme: Theme,
        baseFont: Font
    ) {
        // Stylize each child run with a left-aligned accent (a
        // single "│ " prefix) so the user can visually distinguish
        // blockquotes from regular paragraphs without needing
        // background fills (which would compete with the bubble's
        // own card background).
        for child in quote.children {
            result.append(AttributedString("│ "))
            renderBlock(child, into: &result, theme: theme, baseFont: baseFont)
        }
    }

    private static func renderCodeBlock(
        _ code: CodeBlock,
        into result: inout AttributedString,
        theme: Theme
    ) {
        var run = AttributedString(code.code)
        run.font = .system(.footnote, design: .monospaced)
        run.backgroundColor = theme.textSecondary.opacity(0.08)
        // Code blocks are followed by an empty line for readability
        // when adjacent to other blocks; the parent block separator
        // already adds one newline, so this run's content gets one
        // implicit newline (the prefix added by the parent). We add
        // an explicit trailing newline inside the monospaced run to
        // terminate it cleanly.
        run.append(AttributedString("\n"))
        result.append(run)
    }

    private static func renderThematicBreak(into result: inout AttributedString) {
        // `---` in markdown renders as a horizontal rule. We emit
        // an em-dash placeholder line; the bubble's overall layout
        // doesn't need a real rendered `<hr>` for the chat use case.
        result.append(AttributedString("\n———\n"))
    }

    // MARK: - Inline dispatch

    /// Walk an inline container (paragraph, heading, list item, etc.)
    /// and append its inline children to `result` with per-node styling.
    /// `inlineChildren` only exists on types that conform to the
    /// `InlineContainer` protocol (Paragraph, Heading, etc.); the base
    /// `Markup.children` returns heterogeneous block+inline children.
    /// We cast to `InlineContainer` and fall back to filtering
    /// `children` for types that don't conform (e.g. block quotes
    /// holding nested blocks).
    private static func renderInlineChildren(
        of container: Markup,
        into result: inout AttributedString,
        theme: Theme,
        baseFont: Font
    ) {
        let inlineKids: [InlineMarkup]
        if let inlineContainer = container as? InlineContainer {
            inlineKids = Array(inlineContainer.inlineChildren)
        } else {
            inlineKids = container.children.compactMap { $0 as? InlineMarkup }
        }
        for child in inlineKids {
            renderInline(child, into: &result, theme: theme, baseFont: baseFont)
        }
    }

    private static func renderInline(
        _ inline: InlineMarkup,
        into result: inout AttributedString,
        theme: Theme,
        baseFont: Font
    ) {
        switch inline {
        case let text as Markdown.Text:
            var run = AttributedString(text.plainText)
            run.font = baseFont
            run.foregroundColor = theme.textPrimary
            result.append(run)
        case let softBreak as SoftBreak:
            // Soft break (a single `\n` not adjacent to another
            // newline in the source) becomes a literal newline.
            // The preprocessor converted lone newlines to CommonMark
            // hard breaks, so soft breaks are rare in practice — but
            // handle them for completeness (e.g. plain-text paste
            // that bypasses the preprocessor).
            result.append(AttributedString("\n"))
        case let lineBreak as LineBreak:
            // CommonMark hard break (`  \n` in source) becomes a
            // literal newline so the bubble respects the model's
            // visual line breaks.
            result.append(AttributedString("\n"))
        case let code as InlineCode:
            var run = AttributedString(code.code)
            run.font = .system(.footnote, design: .monospaced)
            run.backgroundColor = theme.textSecondary.opacity(0.08)
            result.append(run)
        case let emphasis as Emphasis:
            // Italic. Walk children with an italicized base font.
            renderInlineChildren(of: emphasis, into: &result, theme: theme, baseFont: baseFont.italic())
        case let strong as Strong:
            // Bold. Walk children with a bolded base font.
            renderInlineChildren(of: strong, into: &result, theme: theme, baseFont: baseFont.weight(.semibold))
        case let link as Markdown.Link:
            renderLink(link, into: &result, theme: theme, baseFont: baseFont)
        case let html as InlineHTML:
            // Drop inline HTML (the model emits `<br>` and similar;
            // we already convert the more common cases to native
            // nodes via the preprocessor, so anything reaching
            // here is best-effort plain text). `InlineHTML.rawHTML`
            // is the source fragment.
            result.append(AttributedString(html.rawHTML))
        default:
            // Unknown inline — best-effort plainText fallback.
            result.append(AttributedString(inline.plainText))
        }
    }

    private static func renderLink(
        _ link: Markdown.Link,
        into result: inout AttributedString,
        theme: Theme,
        baseFont: Font
    ) {
        var run = AttributedString()
        renderInlineChildren(of: link, into: &run, theme: theme, baseFont: baseFont)
        // `swift-markdown`'s `Link.destination` is the URL string;
        // we attach it as an `AttributedString.link` so SwiftUI's
        // `Text` opens it via `OpenURLAction` (the host view wires
        // `UIApplication.shared.open` for the actual launch).
        if let destination = URL(string: link.destination ?? "") {
            run.link = destination
        }
        // Underline + tint so the user can see the link visually.
        run.underlineStyle = .single
        run.foregroundColor = theme.primary
        result.append(run)
    }
}