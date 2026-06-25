import Foundation
import OpenClawProtocol

/// Narrow seam for the upstream `commands.list` RPC. Returns
/// `Data` (not `String`) because the underlying `ConnectionTransport`
/// already produces `Data` and the only consumer here is
/// `JSONDecoder().decode(_:from:)` which wants `Data` — a `String`
/// round-trip would just be a wasted UTF-8 encode + decode.
///
/// `AnyObject` so the production adapter can be a reference type
/// and the fake is one too; `Sendable` because the class is
/// `@MainActor`-isolated and must travel across `await` boundaries.
@MainActor
public protocol ServerCommandTransport: AnyObject, Sendable {
    func send(method: String, paramsJSON: String) async throws -> Data
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
            let data = try await transport.send(
                method: "commands.list",
                paramsJSON: "{\"includeArgs\":true,\"scope\":\"text\"}"
            )
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
                let data = try await transport.send(
                    method: "commands.list",
                    paramsJSON: "{\"includeArgs\":true,\"scope\":\"text\"}"
                )
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
