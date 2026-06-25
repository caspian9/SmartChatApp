import XCTest
@testable import SmartChatApp

@MainActor
final class LocalCommandRegistryTests: XCTestCase {
    func test_registerAll_populatesV1Set() {
        let r = LocalCommandRegistry()
        let ids = Set(r.all.map(\.id))
        // v1 set per spec; future additions show up here automatically
        XCTAssertTrue(ids.contains("/help"))
        XCTAssertTrue(ids.contains("/clear"))
        XCTAssertTrue(ids.contains("/connect"))
        XCTAssertTrue(ids.contains("/disconnect"))
        XCTAssertTrue(ids.contains("/profiles"))
    }

    func test_lookup_returnsCommandForKnownToken() {
        let r = LocalCommandRegistry()
        XCTAssertEqual(r.lookup("/help")?.description,
                       "Show available commands")
        XCTAssertEqual(r.lookup("/clear")?.description,
                       "Clear chat history")
        XCTAssertEqual(r.lookup("/connect")?.description,
                       "Reconnect to gateway")
        XCTAssertEqual(r.lookup("/disconnect")?.description,
                       "Disconnect from gateway")
        XCTAssertEqual(r.lookup("/profiles")?.description,
                       "List gateway profiles")
    }

    func test_lookup_returnsNilForUnknownToken() {
        let r = LocalCommandRegistry()
        XCTAssertNil(r.lookup("/foo"))
        XCTAssertNil(r.lookup("/"))
    }

    func test_lookup_isCaseInsensitive() {
        let r = LocalCommandRegistry()
        XCTAssertNotNil(r.lookup("/HELP"))
        XCTAssertNotNil(r.lookup("/Help"))
    }

    func test_lookup_normalizesLeadingSlashContract() {
        let r = LocalCommandRegistry()
        XCTAssertNil(r.lookup("help"),
            "lookup expects the leading slash; parseFirstToken enforces this")
    }

    func test_all_commandsHaveExecutor() {
        let r = LocalCommandRegistry()
        for cmd in r.all {
            XCTAssertNotNil(cmd.executor,
                "Local command \(cmd.id) must have an executor")
            XCTAssertEqual(cmd.source, .local)
        }
    }

    // --- Extensibility ---

    func test_register_extendsRegistryAtRuntime() {
        let r = LocalCommandRegistry()
        let initialCount = r.all.count
        r.register(.init(
            id: "/theme", description: "Change theme",
            source: .local, executor: { _ in .bubble("ok") }
        ))
        XCTAssertEqual(r.all.count, initialCount + 1)
        XCTAssertNotNil(r.lookup("/theme"))
    }

    func test_register_overwritesExistingEntry() {
        let r = LocalCommandRegistry()
        r.register(.init(
            id: "/help", description: "new help",
            source: .local, executor: { _ in .bubble("new") }
        ))
        XCTAssertEqual(r.lookup("/help")?.description, "new help")
    }

    // --- /help formatter ---

    func test_help_alignsDescriptionColumnByGroup() {
        // The /help output is rendered with a monospaced font in the
        // system bubble (see MessageBubbleView's `system`-role
        // branch). The description column must line up across rows
        // in each group, regardless of whether entries have an
        // `argumentSyntax` or how long the id is. The previous
        // formatter padded only the syntax portion to 14 chars, so
        // `/acp [action]` and `/activation [mode]` ended up visually
        // offset by 6 chars. The fix computes the column width from
        // the longest id+syntax in the group.
        let r = LocalCommandRegistry()
        let cmds: [SlashCommand] = [
            SlashCommand(id: "/clear", description: "Clear chat history",
                         source: .local, executor: { _ in .silent }),
            SlashCommand(id: "/connect", description: "Reconnect",
                         source: .local, executor: { _ in .silent }),
            SlashCommand(id: "/help", description: "Show help",
                         argumentSyntax: "[topic]",
                         source: .local, executor: { _ in .silent }),
            SlashCommand(id: "/acp", description: "Manage ACP",
                         argumentSyntax: "[action]",
                         source: .server, executor: nil),
            SlashCommand(id: "/activation", description: "Set mode",
                         argumentSyntax: "[mode]",
                         source: .server, executor: nil),
        ]
        let rendered = r.helpText(for: cmds)
        let lines = rendered.split(separator: "\n").map(String.init)
        let dataLines = lines.filter { $0.hasPrefix("  /") }

        // Walk each line and find the x-offset where the description
        // starts (after the indent + id + optional syntax + gap).
        // Two passes — one for the local group (first 3 entries),
        // one for the server group (last 2) — to check alignment
        // separately per group (the gap between Local and Server is
        // a heading line that intentionally resets).
        let localData = dataLines.filter { line in
            ["  /clear", "  /connect", "  /help [topic]"]
                .contains(where: { line.hasPrefix($0) })
        }
        let serverData = dataLines.filter { line in
            ["  /acp [action]", "  /activation [mode]"]
                .contains(where: { line.hasPrefix($0) })
        }
        XCTAssertEqual(descriptionOffsets(of: localData), 1,
            "Local-group description column should align; rendered:\n\(rendered)")
        XCTAssertEqual(descriptionOffsets(of: serverData), 1,
            "Server-group description column should align; rendered:\n\(rendered)")
    }

    /// Returns the number of distinct x-offsets at which the
    /// description column starts across the given lines. 1 = aligned.
    /// Walks each line and finds the *first* run of 2+ consecutive
    /// spaces after the indent — the formatter sizes the gap so it
    /// is at least 2 spaces, and always uses ≥2 spaces for the gap
    /// (shorter id+optional-syntax rows get a longer gap to fill
    /// `colWidth`). The description starts immediately after that
    /// run, so finding the offset of the next non-space char gives
    /// the description column.
    private func descriptionOffsets(of lines: [String]) -> Int {
        let offsets: [Int] = lines.map { line in
            var idx = line.index(line.startIndex, offsetBy: 2)
            // Scan for a run of 2+ spaces.
            var consecutiveSpaces = 0
            var gapEnd = idx
            while idx < line.endIndex {
                if line[idx] == " " {
                    consecutiveSpaces += 1
                    if consecutiveSpaces >= 2 { gapEnd = line.index(after: idx) }
                } else {
                    consecutiveSpaces = 0
                }
                idx = line.index(after: idx)
            }
            return line.distance(from: line.startIndex, to: gapEnd)
        }
        return Set(offsets).count
    }
}
