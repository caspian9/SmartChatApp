import Foundation

@MainActor
public protocol LocalCommandContext: AnyObject, Sendable {
    func clearLocalMessages()
    var mergedCommands: [SlashCommand] { get }
    var activeProfileName: String { get }
}

@MainActor
public class LocalCommandRegistry {
    public weak var context: LocalCommandContext?

    private var commands: [String: SlashCommand] = [:]

    public init() { registerAll() }

    /// Re-runs registration. Idempotent (replace-or-add).
    public func registerAll() {
        // /help — category B (aggregation)
        register(.init(
            id: "/help",
            description: "Show available commands",
            source: .local,
            executor: { [weak self] _ in
                let text = await MainActor.run { [weak self] in
                    let list = self?.context?.mergedCommands ?? []
                    return self?.formatHelpList(list) ?? ""
                }
                return .bubble(text)
            }
        ))
        // /clear — category A (pure local)
        register(.init(
            id: "/clear",
            description: "Clear chat history",
            source: .local,
            executor: { [weak self] _ in
                await MainActor.run { [weak self] in
                    self?.context?.clearLocalMessages()
                }
                return .clearAndBubble("Chat cleared")
            }
        ))
        // /connect — category A
        register(.init(
            id: "/connect",
            description: "Reconnect to gateway",
            source: .local,
            executor: { [weak self] _ in
                let name = await MainActor.run { [weak self] in
                    self?.context?.activeProfileName ?? "gateway"
                }
                Task { @MainActor in
                    try? await SessionManager.shared.ensureConnected()
                }
                return .bubble("Connecting to \(name)...")
            }
        ))
        // /disconnect — category A (silent)
        register(.init(
            id: "/disconnect",
            description: "Disconnect from gateway",
            source: .local,
            executor: { _ in
                Task { @MainActor in
                    await SessionManager.shared.disconnect()
                }
                return .silent
            }
        ))
        // /profiles — category A
        register(.init(
            id: "/profiles",
            description: "List gateway profiles",
            source: .local,
            executor: { _ in
                let names = await MainActor.run {
                    ProfileManager.shared.profiles
                        .map { p in p.isActive ? "* \(p.name)" : "  \(p.name)" }
                        .joined(separator: "\n")
                }
                return .bubble(names.isEmpty
                    ? "(no profiles configured)"
                    : names)
            }
        ))
    }

    public func register(_ cmd: SlashCommand) {
        commands[cmd.id.lowercased()] = cmd
    }

    open func lookup(_ token: String) -> SlashCommand? {
        let normalized = token.lowercased()
        // O(n) scan: n is bounded by registered local count
        // (v1: 5, future: tens at most). An O(1) alias-keyed
        // map is a future optimization if this becomes hot.
        return commands.values.first { cmd in
            cmd.id.lowercased() == normalized
                || cmd.aliases.contains(where: { $0.lowercased() == normalized })
        }
    }

    open var all: [SlashCommand] {
        Array(commands.values).sorted { $0.id < $1.id }
    }

    /// Public test seam for the `/help` formatter. The runtime path
    /// (the `/help` executor closure) invokes `formatHelpList` with
    /// the context's `mergedCommands` and wraps the result in a
    /// `.bubble(text)` `SlashCommandResult`. Tests need to call the
    /// formatter directly to assert on its column alignment without
    /// standing up a full VM context, so we re-export it here. Marked
    /// `open` (not `public`) so subclasses can still override the
    /// formatting if they want a different layout.
    open func helpText(for commands: [SlashCommand]) -> String {
        formatHelpList(commands)
    }

    private nonisolated func formatHelpList(_ list: [SlashCommand]) -> String {
        let local = list.filter { $0.source == .local }
        let server = list.filter { $0.source == .server }
        // Compute the longest `id + " " + syntax` once per group so the
        // description column starts at the same x-offset for every row
        // (the previous `formatLine` padded only the syntax to a fixed
        // 14 chars, which drifted when the id was shorter or longer than
        // the syntax — `/acp [action]` and `/activation [mode]` ended
        // up with their descriptions offset by 6 chars under monospaced
        // rendering). The whole-table max keeps the layout tight
        // without over-padding the longest row.
        var out = "Available commands:\n"
        if !local.isEmpty {
            out += "\n── Local (\(local.count)) ──\n"
            out += formatGroup(local)
        }
        if !server.isEmpty {
            out += "\n\n── Server (\(server.count)) ──\n"
            out += formatGroup(server)
        } else {
            out += "\n\n── Server (unavailable) ──\n"
            out += "Server command list could not be\n"
            out += "fetched. Reconnect and try /help\n"
            out += "again to see server cmds."
        }
        return out
    }

    private nonisolated func formatGroup(_ cmds: [SlashCommand]) -> String {
        let widths = cmds.map { cmd -> Int in
            let syntax = cmd.argumentSyntax.map { " \($0)" } ?? ""
            return cmd.id.count + syntax.count
        }
        let colWidth = (widths.max() ?? 0) + 2  // +2 = at least 2 spaces of gap
        return cmds.map { cmd in
            let syntax = cmd.argumentSyntax.map { " \($0)" } ?? ""
            let idSyntax = "\(cmd.id)\(syntax)"
            // Pad right of `idSyntax` with literal spaces so the
            // description column starts at the same x-offset
            // across all rows in the group. The `String.padding`
            // API family is fiddly here — its `startingAt:` variant
            // inserts at the given index (not appends), and
            // Foundation's `stringByPaddingToLength` throws
            // NSException when `startingAt` is at-or-past
            // `endIndex` — so build the gap directly.
            let padCount = max(0, colWidth - idSyntax.count)
            let gap = String(repeating: " ", count: padCount)
            return "  " + idSyntax + gap + cmd.description
        }.joined(separator: "\n")
    }
}
