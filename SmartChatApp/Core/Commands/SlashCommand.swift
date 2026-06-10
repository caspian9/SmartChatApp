import Foundation
import OpenClawProtocol

public enum CommandSource: String, Codable, Sendable, Hashable {
    case local
    case server
}

public typealias LocalExecutor =
    @Sendable ([String]) async -> SlashCommandResult

public struct SlashCommand: Identifiable, Hashable, Sendable {
    public let id: String
    public let description: String
    public let argumentSyntax: String?
    public let aliases: [String]
    public let source: CommandSource
    public let executor: LocalExecutor?

    public init(
        id: String,
        description: String,
        argumentSyntax: String? = nil,
        aliases: [String] = [],
        source: CommandSource,
        executor: LocalExecutor? = nil
    ) {
        self.id = id
        self.description = description
        self.argumentSyntax = argumentSyntax
        self.aliases = aliases
        self.source = source
        self.executor = executor
    }

    public static func == (lhs: SlashCommand, rhs: SlashCommand) -> Bool {
        lhs.id == rhs.id
            && lhs.description == rhs.description
            && lhs.argumentSyntax == rhs.argumentSyntax
            && lhs.aliases == rhs.aliases
            && lhs.source == rhs.source
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(description)
        hasher.combine(argumentSyntax)
        hasher.combine(aliases)
        hasher.combine(source)
    }
}

extension SlashCommand {
    /// Wrap an upstream `CommandEntry` (from OpenClawProtocol) as
    /// a `.server` `SlashCommand` for unified display and filtering.
    public static func fromCommandEntry(_ entry: CommandEntry) -> SlashCommand {
        let syntax = synthesizeArgumentSyntax(from: entry.args)
        let aliases = (entry.textaliases ?? []).filter { $0 != entry.name }
        return SlashCommand(
            id: entry.name,
            description: entry.description,
            argumentSyntax: syntax,
            aliases: aliases,
            source: .server,
            executor: nil
        )
    }

    private static func synthesizeArgumentSyntax(
        from args: [[String: AnyCodable]]?
    ) -> String? {
        guard let first = args?.first,
              let nameAny = first["name"],
              let name = nameAny.value as? String,
              !name.isEmpty else {
            return nil
        }
        let required = (first["required"]?.value as? Bool) ?? false
        return required ? "<\(name)>" : "[\(name)]"
    }
}
