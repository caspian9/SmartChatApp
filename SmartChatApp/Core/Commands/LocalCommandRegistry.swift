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

    private nonisolated func formatHelpList(_ list: [SlashCommand]) -> String {
        let local = list.filter { $0.source == .local }
        let server = list.filter { $0.source == .server }
        var out = "Available commands:\n"
        if !local.isEmpty {
            out += "\n── Local (\(local.count)) ──\n"
            out += local.map(formatLine).joined(separator: "\n")
        }
        if !server.isEmpty {
            out += "\n\n── Server (\(server.count)) ──\n"
            out += server.map(formatLine).joined(separator: "\n")
        } else {
            out += "\n\n── Server (unavailable) ──\n"
            out += "Server command list could not be\n"
            out += "fetched. Reconnect and try /help\n"
            out += "again to see server cmds."
        }
        return out
    }

    private nonisolated func formatLine(_ cmd: SlashCommand) -> String {
        let syntax = cmd.argumentSyntax.map { " \($0)" } ?? ""
        return "  \(cmd.id)\(syntax.padding(toLength: 14, withPad: " ", startingAt: 0))\(cmd.description)"
    }
}
