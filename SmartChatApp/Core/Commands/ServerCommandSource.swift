import Foundation
import OpenClawProtocol

@MainActor
public class ServerCommandSource {
    public private(set) var entries: [CommandEntry] = []
    public private(set) var isFetched: Bool = false
    public private(set) var lastError: Error?

    public init() {}

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

    /// Stub. Full implementation in Task 5.
    public func refresh() async {
        // No-op when no transport wired (Task 5 adds the seam).
    }
}
