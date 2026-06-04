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
