import Foundation

@MainActor
public final class SlashCommandRouter {
    public enum Dispatch: Sendable {
        case execute(SlashCommandResult)
        case passthrough
    }

    private let local: LocalCommandRegistry
    private let server: ServerCommandSource

    public init(local: LocalCommandRegistry,
                server: ServerCommandSource) {
        self.local = local
        self.server = server
    }

    /// Parse a /command into (token, args).
    /// Returns nil for non-slash input.
    public func parse(_ text: String) -> (token: String, args: [String])? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }

        let firstLine = trimmed
            .split(separator: "\n", maxSplits: 1,
                   omittingEmptySubsequences: true)
            .first.map(String.init) ?? trimmed

        let parts = firstLine.split(whereSeparator: { $0.isWhitespace })
        guard let first = parts.first else { return nil }
        let token = "/" + first.dropFirst().lowercased()
        let args = parts.dropFirst().map(String.init)
        return (token, args)
    }

    public func dispatch(_ text: String) async -> Dispatch {
        guard let parsed = parse(text) else { return .passthrough }
        if let cmd = local.lookup(parsed.token), let exec = cmd.executor {
            let result: SlashCommandResult
            do {
                result = try await exec(parsed.args)
            } catch {
                result = .bubble(
                    "Command failed: \(error.localizedDescription)"
                )
            }
            return .execute(result)
        }
        if server.contains(parsed.token) { return .passthrough }
        return .passthrough
    }
}
