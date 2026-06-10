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
}
