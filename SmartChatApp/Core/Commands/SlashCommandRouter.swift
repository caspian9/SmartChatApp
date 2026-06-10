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
        if let cmd = local.lookup(parsed.token) {
            guard let exec = cmd.executor else {
                // Local hit with no executor is a registry
                // configuration bug — surface it instead of
                // silently falling through to the server (which
                // could be category C for a different command).
                return .execute(.bubble(
                    "Local command \(cmd.id) has no executor"
                ))
            }
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
        return .passthrough
    }
}
