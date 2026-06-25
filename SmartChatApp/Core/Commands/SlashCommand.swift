import Foundation
import OpenClawProtocol

public enum CommandSource: String, Codable, Sendable, Hashable {
    case local
    case server
}

public typealias LocalExecutor =
    @Sendable ([String]) async throws -> SlashCommandResult

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
    /// Normalizes the id and aliases to start with `/` — the
    /// gateway's `commands.list` response is inconsistent about
    /// whether `name` includes the leading slash (some entries
    /// arrive as `commands`, others as `/commands`), and the
    /// autocomplete popup / `filter(_:)` / `parse(_:)` all assume
    /// the canonical `/`-prefixed form. Without normalization,
    /// typing `/com` wouldn't surface a server entry whose name is
    /// `commands`, and the popup would render "commands" instead
    /// of "/commands".
    public static func fromCommandEntry(_ entry: CommandEntry) -> SlashCommand {
        let syntax = synthesizeArgumentSyntax(from: entry.args)
        let normalizedId = Self.normalizeSlash(entry.name)
        // Normalize first, then dedup against the normalized id.
        // The raw `name` may differ from a raw alias only by the
        // missing leading `/` (e.g. name="help", alias="/help" — the
        // server's two duplicate entries would survive a naive
        // `$0 != entry.name` filter and end up as duplicate
        // normalized aliases on the SlashCommand).
        let normalizedAliases = (entry.textaliases ?? [])
            .map(Self.normalizeSlash)
            .filter { $0 != normalizedId }
        return SlashCommand(
            id: normalizedId,
            description: entry.description,
            argumentSyntax: syntax,
            aliases: normalizedAliases,
            source: .server,
            executor: nil
        )
    }

    /// Prepend `/` if not already present. Idempotent on already-
    /// normalized inputs (`/help` → `/help`).
    private static func normalizeSlash(_ s: String) -> String {
        s.hasPrefix("/") ? s : "/" + s
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
