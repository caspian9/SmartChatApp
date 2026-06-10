import Foundation
import OpenClawProtocol

/// Narrow seam for the upstream `commands.list` RPC. Keeping the
/// protocol method count to one (string-in / string-out) means
/// the production adapter (Task 7) and the test fake (Task 5)
/// have identical surface area. `AnyObject` so the production
/// adapter can be a reference type and the fake is one too;
/// `Sendable` because the class is `@MainActor`-isolated and
/// must travel across `await` boundaries.
@MainActor
public protocol ServerCommandTransport: AnyObject, Sendable {
    func send(method: String, paramsJSON: String) async throws -> String
}

@MainActor
open class ServerCommandSource {
    public private(set) var entries: [CommandEntry] = []
    public private(set) var isFetched: Bool = false
    public private(set) var lastError: Error?

    private let transport: ServerCommandTransport?
    private let retryDelay: Duration

    public init(transport: ServerCommandTransport? = nil,
                retryDelay: Duration = .seconds(5)) {
        self.transport = transport
        self.retryDelay = retryDelay
    }

    open func contains(_ token: String) -> Bool {
        let normalized = token.lowercased()
        return entries.contains { entry in
            entry.name.lowercased() == normalized
                || (entry.textaliases ?? []).contains(where: {
                    $0.lowercased() == normalized
                })
        }
    }

    open var all: [SlashCommand] {
        entries.map(SlashCommand.fromCommandEntry)
    }

    /// Fetch server-known commands. Atomic swap on success, single
    /// retry on failure, never throws. Logging is routed through
    /// `AppLogger` (the project-wide seam) rather than `os.Logger`
    /// directly so the in-memory ring buffer in Settings → Debug
    /// & Logs can capture these lines too.
    public func refresh() async {
        guard let transport else {
            AppLogger.log("No transport wired; refresh is a no-op",
                          category: .commands,
                          level: .debug)
            return
        }
        do {
            let json = try await transport.send(
                method: "commands.list",
                paramsJSON: "{\"includeArgs\":true,\"scope\":\"text\"}"
            )
            let data = Data(json.utf8)
            let result = try JSONDecoder().decode(
                CommandsListResult.self, from: data
            )
            self.entries = result.commands  // atomic swap
            self.isFetched = true
            self.lastError = nil
            AppLogger.log("Fetched \(result.commands.count) server commands",
                          category: .commands,
                          level: .info)
        } catch {
            self.lastError = error
            AppLogger.log("commands.list failed: \(error.localizedDescription); retrying once",
                          category: .commands,
                          level: .warning)
            try? await Task.sleep(for: retryDelay)
            do {
                let json = try await transport.send(
                    method: "commands.list",
                    paramsJSON: "{\"includeArgs\":true,\"scope\":\"text\"}"
                )
                let data = Data(json.utf8)
                let result = try JSONDecoder().decode(
                    CommandsListResult.self, from: data
                )
                self.entries = result.commands
                self.isFetched = true
                self.lastError = nil
                AppLogger.log("Fetched \(result.commands.count) server commands after retry",
                              category: .commands,
                              level: .info)
            } catch {
                self.lastError = error
                self.isFetched = false
                AppLogger.log("commands.list retry failed: \(error.localizedDescription)",
                              category: .commands,
                              level: .warning)
            }
        }
    }
}
