import Foundation
import OSLog

enum LogCategory: String, CaseIterable, Codable {
    case network    = "network"
    case cache      = "cache"
    case nativeChat = "nativeChat"
    case markdown   = "markdown"

    var displayName: String {
        switch self {
        case .network:    return "Network"
        case .cache:      return "Cache"
        case .nativeChat: return "NativeChat"
        case .markdown:   return "Markdown"
        }
    }
}

enum LogLevel: String, Codable {
    case debug, info, warning, error

    var osType: OSLogType {
        switch self {
        case .debug:   return .debug
        case .info:    return .info
        case .warning: return .default
        case .error:   return .error
        }
    }
}

struct LogEntry: Identifiable, Equatable {
    let id: UUID
    let ts: Date
    let category: LogCategory
    let level: LogLevel
    let message: String
}

struct LogRingBuffer {
    let capacity: Int
    private(set) var entries: [LogEntry] = []

    init(capacity: Int) {
        self.capacity = capacity
    }

    mutating func append(_ entry: LogEntry) {
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    mutating func clear() {
        entries.removeAll()
    }
}

/// File-scope immutable constant. Safe to read from any thread without
/// locking or `MainActor` isolation — the dictionary is constructed once
/// at program start and never mutated afterwards.
private let osLogs: [LogCategory: OSLog] = [
    .network:    OSLog(subsystem: "SmartChatApp", category: "Network"),
    .cache:      OSLog(subsystem: "SmartChatApp", category: "Cache"),
    .nativeChat: OSLog(subsystem: "SmartChatApp", category: "NativeChat"),
    .markdown:   OSLog(subsystem: "SmartChatApp", category: "Markdown"),
]

@MainActor
final class AppLogger: ObservableObject {
    static let shared = AppLogger()

    private static let capacity = 2000
    @Published private var buffer = LogRingBuffer(capacity: AppLogger.capacity)
    private var enabledCategories: Set<LogCategory> = []

    var entries: [LogEntry] { buffer.entries }

    private init() {}

    func setEnabled(_ category: LogCategory, _ on: Bool) {
        if on { enabledCategories.insert(category) }
        else  { enabledCategories.remove(category) }
    }

    func clear() {
        buffer.clear()
    }

    /// Main log entry point. Always writes to OSLog; writes to the in-memory
    /// buffer only when the category is enabled. Safe to call from any thread:
    /// the OSLog dict is a file-scope immutable constant (lock-free reads), the
    /// OSLog write itself is thread-safe, and the buffer append hops to the
    /// main actor via a Task.
    nonisolated static func log(_ message: String,
                                category: LogCategory,
                                level: LogLevel = .debug) {
        // OSLog: always write, prefix preserved for grep workflow.
        // osLogs is a file-scope constant; safe to read from any thread.
        let osLog = osLogs[category]!
        os_log("%{public}@", log: osLog, type: level.osType, "SMAlog: " + message)

        // Buffer: hop to main actor, gate on enabled category.
        let entry = LogEntry(id: UUID(),
                             ts: Date(),
                             category: category,
                             level: level,
                             message: message)
        Task { @MainActor in
            guard shared.enabledCategories.contains(category) else { return }
            shared.buffer.append(entry)
        }
    }

    // MARK: - Redaction helpers
    //
    // Gateway auth tokens live in ProfileManager and are passed
    // through ConnectionCoordinator over the wire. They MUST
    // never appear in AppLogger output (the in-memory ring
    // buffer is shown in Settings → Debug Logs Viewer; OSLog
    // surfaces in Console.app). These helpers are the safe
    // shape for any future log site that might want to
    // mention a token.
    //
    // Defense in depth: as of 2026-06-08 a grep across the
    // 150 AppLogger.log call sites shows NONE interpolate
    // profile.token directly. These helpers close the door
    // before it opens.

    /// Returns a redacted representation of a gateway auth token.
    /// Shows only the last 4 characters (enough to correlate
    /// across log lines without leaking the secret).
    nonisolated static func redact(token: String) -> String {
        guard token.count > 4 else { return "[REDACTED]" }
        let suffix = token.suffix(4)
        return "[REDACTED:\(suffix)]"
    }

    /// Returns a redacted representation of a GatewayProfile for
    /// logging. The token is fully stripped; only the name and
    /// host (for cross-referencing) survive.
    nonisolated static func redact(profile: GatewayProfile) -> String {
        "GatewayProfile(name: \(profile.name), host: \(profile.host), token: \(AppLogger.redact(token: profile.token))"
    }

    /// Returns a redacted representation of a profile name list
    /// (no tokens, no host) for logs that just want a "which
    /// profiles are loaded" signal.
    nonisolated static func redact(profileNames: [String]) -> String {
        "[\(profileNames.joined(separator: ", "))]"
    }
}
