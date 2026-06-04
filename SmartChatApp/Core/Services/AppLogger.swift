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

@MainActor
final class AppLogger: ObservableObject {
    static let shared = AppLogger()

    private static let capacity = 2000
    @Published private var buffer = LogRingBuffer(capacity: AppLogger.capacity)
    private var enabledCategories: Set<LogCategory> = []

    private let osLogs: [LogCategory: OSLog] = [
        .network:    OSLog(subsystem: "SmartChatApp", category: "Network"),
        .cache:      OSLog(subsystem: "SmartChatApp", category: "Cache"),
        .nativeChat: OSLog(subsystem: "SmartChatApp", category: "NativeChat"),
        .markdown:   OSLog(subsystem: "SmartChatApp", category: "Markdown"),
    ]

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
    /// buffer only when the category is enabled. Safe to call from any thread.
    static func log(_ message: String,
                    category: LogCategory,
                    level: LogLevel = .debug) {
        // OSLog: always write, prefix preserved for grep workflow.
        let osLog = MainActor.assumeIsolated { shared.osLogs[category]! }
            // assumeIsolated is safe: osLogs is immutable after init.
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
}
