import XCTest
import OpenClawProtocol
@testable import SmartChatApp

@MainActor
final class SlashCommandRouterTests: XCTestCase {
    private func makeSUT(
        localCommands: [SlashCommand] = [],
        serverEntries: [CommandEntry] = []
    ) -> SlashCommandRouter {
        let local = FakeLocalRegistry(commands: localCommands)
        let server = FakeServerSource(entries: serverEntries)
        return SlashCommandRouter(local: local, server: server)
    }

    // --- Category A: pure local ---

    func test_dispatch_categoryA_returnsExecute_withBubble() async {
        let cmd = SlashCommand(
            id: "/clear", description: "d", source: .local,
            executor: { _ in .bubble("done") }
        )
        let r = makeSUT(localCommands: [cmd])
        let dispatch = await r.dispatch("/clear")
        guard case .execute(let result) = dispatch else {
            return XCTFail("expected .execute, got \(dispatch)")
        }
        guard case .bubble(let text) = result else {
            return XCTFail("expected .bubble")
        }
        XCTAssertEqual(text, "done")
    }

    // --- Category B: local aggregation ---

    func test_dispatch_categoryB_returnsExecute_withClearAndBubble() async {
        let cmd = SlashCommand(
            id: "/clear", description: "d", source: .local,
            executor: { _ in .clearAndBubble("cleared") }
        )
        let r = makeSUT(localCommands: [cmd])
        let dispatch = await r.dispatch("/clear")
        guard case .execute(.clearAndBubble(let text)) = dispatch else {
            return XCTFail("expected .clearAndBubble")
        }
        XCTAssertEqual(text, "cleared")
    }

    // --- Category C: server-known ---

    func test_dispatch_categoryC_returnsPassthrough_serverKnown() async {
        let entry = CommandEntry(
            name: "/status", nativename: nil, textaliases: nil,
            description: "d", category: nil,
            source: .init("native"), scope: .init("text"),
            acceptsargs: false, args: nil
        )
        let r = makeSUT(serverEntries: [entry])
        let dispatch = await r.dispatch("/status")
        guard case .passthrough = dispatch else {
            return XCTFail("expected .passthrough, got \(dispatch)")
        }
    }

    // --- Category D: unknown ---

    func test_dispatch_categoryD_returnsPassthrough_unknown() async {
        let r = makeSUT()
        let dispatch = await r.dispatch("/foo")
        guard case .passthrough = dispatch else {
            return XCTFail("expected .passthrough, got \(dispatch)")
        }
    }

    // --- Priority + normalization ---

    func test_dispatch_localPriorityOverServer() async {
        let localCmd = SlashCommand(
            id: "/help", description: "local", source: .local,
            executor: { _ in .bubble("LOCAL") }
        )
        let serverEntry = CommandEntry(
            name: "/help", nativename: nil, textaliases: nil,
            description: "server", category: nil,
            source: .init("native"), scope: .init("text"),
            acceptsargs: false, args: nil
        )
        let r = makeSUT(localCommands: [localCmd],
                        serverEntries: [serverEntry])
        let dispatch = await r.dispatch("/help")
        guard case .execute(let result) = dispatch else {
            return XCTFail("local must win on collision")
        }
        guard case .bubble(let text) = result else {
            return XCTFail("expected .bubble from local")
        }
        XCTAssertEqual(text, "LOCAL")
    }

    func test_dispatch_normalized_caseInsensitive() async {
        let cmd = SlashCommand(
            id: "/help", description: "d", source: .local,
            executor: { _ in .silent }
        )
        let r = makeSUT(localCommands: [cmd])
        let dispatch = await r.dispatch("/HELP")
        guard case .execute = dispatch else {
            return XCTFail("expected .execute (case-insensitive)")
        }
    }

    func test_dispatch_handlesTrailingWhitespace() async {
        let cmd = SlashCommand(
            id: "/help", description: "d", source: .local,
            executor: { _ in .silent }
        )
        let r = makeSUT(localCommands: [cmd])
        let dispatch = await r.dispatch("/help   ")
        guard case .execute = dispatch else {
            return XCTFail("expected .execute (trim)")
        }
    }

    func test_dispatch_handlesArgsSplit() async {
        var captured: [String] = []
        let exec: LocalExecutor = { args in
            captured = args
            return .silent
        }
        let cmd = SlashCommand(
            id: "/foo", description: "d", source: .local,
            executor: exec
        )
        let r = makeSUT(localCommands: [cmd])
        _ = await r.dispatch("/foo a b c")
        XCTAssertEqual(captured, ["a", "b", "c"])
    }

    func test_dispatch_handlesMultiline_takesFirstLine() async {
        let cmd = SlashCommand(
            id: "/help", description: "d", source: .local,
            executor: { _ in .bubble("hit") }
        )
        let r = makeSUT(localCommands: [cmd])
        let dispatch = await r.dispatch("/help\nignored line two")
        guard case .execute = dispatch else {
            return XCTFail("expected .execute")
        }
    }

    func test_dispatch_returnsPassthroughWhenNoSlash() async {
        let r = makeSUT()
        let dispatch = await r.dispatch("hello world")
        guard case .passthrough = dispatch else {
            return XCTFail("expected .passthrough")
        }
    }

    func test_dispatch_executorThrows_returnsBubbleWithError() async {
        struct Boom: LocalizedError {
            var errorDescription: String? { "kapow" }
        }
        let cmd = SlashCommand(
            id: "/foo", description: "d", source: .local,
            executor: { _ in throw Boom() }
        )
        let r = makeSUT(localCommands: [cmd])
        let dispatch = await r.dispatch("/foo")
        guard case .execute(let result) = dispatch,
              case .bubble(let text) = result else {
            return XCTFail("expected .bubble on error")
        }
        XCTAssertTrue(text.contains("Command failed"))
        XCTAssertTrue(text.contains("kapow"))
    }

    func test_dispatch_executorSilent() async {
        let cmd = SlashCommand(
            id: "/disconnect", description: "d", source: .local,
            executor: { _ in .silent }
        )
        let r = makeSUT(localCommands: [cmd])
        let dispatch = await r.dispatch("/disconnect")
        guard case .execute(.silent) = dispatch else {
            return XCTFail("expected .execute(.silent)")
        }
    }

    func test_dispatch_serverAliasMatch_resolvesCategoryC() async {
        // /h is a server alias for /help. local has nothing.
        // Expected: category C (passthrough), since local doesn't
        // know /h.
        let entry = CommandEntry(
            name: "/help", nativename: nil,
            textaliases: ["/h"],
            description: "d", category: nil,
            source: .init("native"), scope: .init("text"),
            acceptsargs: false, args: nil
        )
        let r = makeSUT(serverEntries: [entry])
        let dispatch = await r.dispatch("/h")
        guard case .passthrough = dispatch else {
            return XCTFail("server alias match → category C")
        }
    }

    // --- Task 4 follow-up: alias dispatch (local) + lone-`/` + executor-nil ---

    func test_dispatch_localAliasMatch_resolvesCategoryA() async {
        // Local /help has alias /h; typing /h should resolve to /help
        // and execute locally (category A), not fall through to
        // server passthrough.
        let exec: LocalExecutor = { _ in .bubble("HELP HIT") }
        let cmd = SlashCommand(
            id: "/help", description: "d", aliases: ["/h"],
            source: .local, executor: exec
        )
        let r = makeSUT(localCommands: [cmd])
        let dispatch = await r.dispatch("/h")
        guard case .execute(let result) = dispatch,
              case .bubble(let text) = result else {
            return XCTFail("local alias /h → /help must execute locally")
        }
        XCTAssertEqual(text, "HELP HIT")
    }

    func test_dispatch_loneSlash_returnsPassthrough() async {
        // Typing just `/` (with no command name) has no local
        // match and no server match — should fall through to D.
        let r = makeSUT()
        let dispatch = await r.dispatch("/")
        guard case .passthrough = dispatch else {
            return XCTFail("lone / should be category D (no match)")
        }
    }

    func test_dispatch_localHitWithNilExecutor_surfacesAsErrorBubble() async {
        // A local entry exists but has no executor — should NOT
        // fall through to the server. Should be treated as a
        // registry configuration bug and surfaced as a bubble.
        let cmd = SlashCommand(
            id: "/foo", description: "d", aliases: [],
            source: .local, executor: nil
        )
        let r = makeSUT(localCommands: [cmd])
        let dispatch = await r.dispatch("/foo")
        guard case .execute(let result) = dispatch,
              case .bubble(let text) = result else {
            return XCTFail("local hit without executor must surface bubble")
        }
        XCTAssertTrue(text.contains("no executor"))
    }

    // --- merged ---

    func test_merged_groupsLocalFirst() {
        let localCmd = SlashCommand(
            id: "/help", description: "d", source: .local,
            executor: { _ in .silent }
        )
        let serverEntry = CommandEntry(
            name: "/status", nativename: nil, textaliases: nil,
            description: "d", category: nil,
            source: .init("native"), scope: .init("text"),
            acceptsargs: false, args: nil
        )
        let r = makeSUT(localCommands: [localCmd],
                        serverEntries: [serverEntry])
        XCTAssertEqual(r.merged.map(\.source), [.local, .server])
    }

    func test_merged_dedupesLocalOverServer() {
        let localCmd = SlashCommand(
            id: "/help", description: "local-help",
            source: .local, executor: { _ in .silent }
        )
        let serverEntry = CommandEntry(
            name: "/help", nativename: nil, textaliases: nil,
            description: "server-help", category: nil,
            source: .init("native"), scope: .init("text"),
            acceptsargs: false, args: nil
        )
        let r = makeSUT(localCommands: [localCmd],
                        serverEntries: [serverEntry])
        let merged = r.merged
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.description, "local-help")
    }

    // --- filter ---

    func test_filter_empty_returnsEmpty() {
        // The popup must not float above the input box before the
        // user has typed anything. Empty input -> no candidates,
        // regardless of how many commands exist in the registry.
        let entries = (0..<10).map { i in
            CommandEntry(
                name: "/c\(i)", nativename: nil, textaliases: nil,
                description: "d\(i)", category: nil,
                source: .init("native"), scope: .init("text"),
                acceptsargs: false, args: nil
            )
        }
        let r = makeSUT(serverEntries: entries)
        XCTAssertTrue(r.filter("").isEmpty)
        XCTAssertTrue(r.filter("   ").isEmpty,
                      "whitespace-only input is treated as empty")
    }

    func test_filter_nonSlashText_returnsEmpty() {
        // Lock in the contract: candidates only show for slash input.
        // Plain text must not surface partial matches.
        let a = SlashCommand(id: "/help", description: "d",
                             source: .local, executor: { _ in .silent })
        let r = makeSUT(localCommands: [a])
        XCTAssertTrue(r.filter("hello").isEmpty)
        XCTAssertTrue(r.filter("h").isEmpty)
    }

    func test_filter_slashAlone_returnsTop5() {
        let entries = (0..<10).map { i in
            CommandEntry(
                name: "/c\(i)", nativename: nil, textaliases: nil,
                description: "d\(i)", category: nil,
                source: .init("native"), scope: .init("text"),
                acceptsargs: false, args: nil
            )
        }
        let r = makeSUT(serverEntries: entries)
        XCTAssertEqual(r.filter("/").count, 5)
    }

    func test_filter_prefixMatch() {
        let a = SlashCommand(id: "/help", description: "d",
                             source: .local, executor: { _ in .silent })
        let b = CommandEntry(
            name: "/hello", nativename: nil, textaliases: nil,
            description: "d", category: nil,
            source: .init("native"), scope: .init("text"),
            acceptsargs: false, args: nil
        )
        let r = makeSUT(localCommands: [a], serverEntries: [b])
        let result = r.filter("/h")
        XCTAssertEqual(result.map(\.id).sorted(), ["/hello", "/help"])
    }

    func test_filter_aliasMatch() {
        let a = SlashCommand(
            id: "/help", description: "d",
            aliases: ["/h"], source: .local,
            executor: { _ in .silent }
        )
        let r = makeSUT(localCommands: [a])
        XCTAssertEqual(r.filter("/h").map(\.id), ["/help"])
    }

    func test_filter_noMatch_returnsEmpty() {
        let a = SlashCommand(id: "/help", description: "d",
                             source: .local, executor: { _ in .silent })
        let r = makeSUT(localCommands: [a])
        XCTAssertTrue(r.filter("/xyz").isEmpty)
    }

    func test_filter_isCaseInsensitive() {
        let a = SlashCommand(id: "/help", description: "d",
                             source: .local, executor: { _ in .silent })
        let r = makeSUT(localCommands: [a])
        XCTAssertEqual(r.filter("/H").map(\.id), ["/help"])
        XCTAssertEqual(r.filter("/HELP").map(\.id), ["/help"])
    }
}

// --- fakes ---

@MainActor
final class FakeLocalRegistry: LocalCommandRegistry {
    private let fakeCommands: [SlashCommand]
    init(commands: [SlashCommand]) {
        self.fakeCommands = commands
        super.init()
    }
    override func lookup(_ token: String) -> SlashCommand? {
        let n = token.lowercased()
        return fakeCommands.first { cmd in
            cmd.id.lowercased() == n
                || cmd.aliases.contains(where: { $0.lowercased() == n })
        }
    }
    override var all: [SlashCommand] { fakeCommands }
}

@MainActor
final class FakeServerSource: ServerCommandSource {
    private let fakeEntries: [CommandEntry]
    init(entries: [CommandEntry]) {
        self.fakeEntries = entries
        super.init()
    }
    override var all: [SlashCommand] {
        fakeEntries.map(SlashCommand.fromCommandEntry)
    }
}
