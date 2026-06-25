import XCTest
import OpenClawProtocol
@testable import SmartChatApp

final class SlashCommandStructTests: XCTestCase {
    func test_slashCommand_isHashable() {
        let a = SlashCommand(
            id: "/help", description: "Show this help",
            argumentSyntax: nil, aliases: ["/h"],
            source: .local, executor: nil
        )
        let b = SlashCommand(
            id: "/help", description: "Show this help",
            argumentSyntax: nil, aliases: ["/h"],
            source: .local, executor: nil
        )
        let set: Set<SlashCommand> = [a, b]
        XCTAssertEqual(set.count, 1, "Two equal SlashCommands must collapse in a Set")
    }

    func test_slashCommand_equalityIgnoresExecutor() {
        let exec: LocalExecutor = { _ in .silent }
        let a = SlashCommand(
            id: "/foo", description: "d", argumentSyntax: nil,
            aliases: [], source: .local, executor: exec
        )
        let b = SlashCommand(
            id: "/foo", description: "d", argumentSyntax: nil,
            aliases: [], source: .local, executor: exec
        )
        XCTAssertEqual(a, b)
    }

    func test_commandSource_isCodableRoundTrip() throws {
        let original = CommandSource.server
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CommandSource.self, from: data)
        XCTAssertEqual(decoded, .server)
    }

    func test_slashCommandResult_switchesAreExhaustive() {
        let cases: [SlashCommandResult] = [
            .bubble("hi"),
            .clearAndBubble("hi"),
            .silent
        ]
        for c in cases {
            switch c {
            case .bubble, .clearAndBubble, .silent:
                continue
            }
        }
    }

    func test_fromCommandEntry_synthesizesArgumentSyntax_fromFirstRequiredArg() {
        let entry = CommandEntry(
            name: "/switch", nativename: nil, textaliases: nil,
            description: "Switch profile", category: nil,
            source: .init("native"), scope: .init("text"),
            acceptsargs: true,
            args: [["name": .init("profile"), "required": .init(true)]]
        )
        let cmd = SlashCommand.fromCommandEntry(entry)
        XCTAssertEqual(cmd.argumentSyntax, "<profile>")
    }

    func test_fromCommandEntry_synthesizesArgumentSyntax_fromFirstOptionalArg() {
        let entry = CommandEntry(
            name: "/set", nativename: nil, textaliases: nil,
            description: "Set value", category: nil,
            source: .init("native"), scope: .init("text"),
            acceptsargs: true,
            args: [["name": .init("name"), "required": .init(false)]]
        )
        let cmd = SlashCommand.fromCommandEntry(entry)
        XCTAssertEqual(cmd.argumentSyntax, "[name]")
    }

    func test_fromCommandEntry_handlesNoArgs() {
        let entry = CommandEntry(
            name: "/help", nativename: nil, textaliases: nil,
            description: "Help", category: nil,
            source: .init("native"), scope: .init("text"),
            acceptsargs: false, args: nil
        )
        let cmd = SlashCommand.fromCommandEntry(entry)
        XCTAssertNil(cmd.argumentSyntax)
        XCTAssertEqual(cmd.source, .server)
        XCTAssertNil(cmd.executor)
    }

    func test_fromCommandEntry_mapsTextAliases() {
        let entry = CommandEntry(
            name: "/help", nativename: nil,
            textaliases: ["/h", "/?"],
            description: "Help", category: nil,
            source: .init("native"), scope: .init("text"),
            acceptsargs: false, args: nil
        )
        let cmd = SlashCommand.fromCommandEntry(entry)
        XCTAssertEqual(Set(cmd.aliases), Set(["/h", "/?"]))
    }

    /// Gateway `commands.list` is inconsistent about whether `name`
    /// carries the leading slash. We always want the canonical
    /// `/`-prefixed form so the autocomplete popup renders
    /// "/commands" (not "commands") and the user's `/com` query
    /// matches `/commands`.
    func test_fromCommandEntry_normalizesIdPrefix_whenMissing() {
        let entry = CommandEntry(
            name: "commands", nativename: nil, textaliases: nil,
            description: "List commands", category: nil,
            source: .init("native"), scope: .init("text"),
            acceptsargs: false, args: nil
        )
        let cmd = SlashCommand.fromCommandEntry(entry)
        XCTAssertEqual(cmd.id, "/commands",
            "Server command names without leading / must be normalized")
    }

    func test_fromCommandEntry_idempotent_whenPrefixAlreadyPresent() {
        let entry = CommandEntry(
            name: "/help", nativename: nil, textaliases: nil,
            description: "Help", category: nil,
            source: .init("native"), scope: .init("text"),
            acceptsargs: false, args: nil
        )
        let cmd = SlashCommand.fromCommandEntry(entry)
        XCTAssertEqual(cmd.id, "/help",
            "Already-prefixed names must not get a second /")
    }

    func test_fromCommandEntry_normalizesAliasesPrefix_whenMissing() {
        let entry = CommandEntry(
            name: "help", nativename: nil,
            textaliases: ["h", "?"],
            description: "Help", category: nil,
            source: .init("native"), scope: .init("text"),
            acceptsargs: false, args: nil
        )
        let cmd = SlashCommand.fromCommandEntry(entry)
        XCTAssertEqual(Set(cmd.aliases), Set(["/h", "/?"]),
            "Aliases without leading / must also be normalized")
    }

    func test_fromCommandEntry_dropsAliasEqualToName_afterNormalization() {
        // If gateway sends name="help" + textaliases=["help"],
        // the dedup-by-name filter must still drop the alias after
        // normalization (name normalizes to "/help", alias normalizes
        // to "/help" too — still equal, still dropped).
        let entry = CommandEntry(
            name: "help", nativename: nil,
            textaliases: ["help"],
            description: "Help", category: nil,
            source: .init("native"), scope: .init("text"),
            acceptsargs: false, args: nil
        )
        let cmd = SlashCommand.fromCommandEntry(entry)
        XCTAssertEqual(cmd.id, "/help")
        XCTAssertEqual(cmd.aliases, [],
            "Alias equal to normalized id must be dropped")
    }
}
