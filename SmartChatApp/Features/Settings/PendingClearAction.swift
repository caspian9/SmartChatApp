import Foundation

/// Identifies which destructive Settings action the user is
/// confirming. One alert handles all four cases; the enum
/// carries the per-case title + message so the alert body
/// matches the data at risk (issue #30).
///
/// `Identifiable` so the `alert(item:)` modifier can drive
/// presentation from `@State PendingClearAction?`. `CaseIterable`
/// so the tests can iterate every case without hard-coding the
/// list (catches missing-case regressions if a new destructive
/// button is added later).
///
/// File-scope (not nested in `SettingsView`) so the test target
/// can reach it via `@testable import SmartChatApp`. Mirrors the
/// `EditProfileSheet.matchesHost` precedent for testing
/// without ViewInspector.
enum PendingClearAction: Identifiable, CaseIterable {
    case sessionCache
    case messageCache
    case allCaches
    case logs

    var id: Self { self }

    /// Short, title-cased label shown as the alert title.
    /// Every title ends with `?` — SwiftUI's `.alert` does not
    /// append punctuation automatically, and the question form
    /// reinforces that the alert is a confirmation, not a
    /// notification.
    var title: String {
        switch self {
        case .sessionCache: return "Clear Session Cache?"
        case .messageCache: return "Clear Message Cache?"
        case .allCaches:    return "Clear All Caches?"
        case .logs:         return "Clear Logs?"
        }
    }

    /// One-sentence explanation of what will be erased. The
    /// combined `.allCaches` case names both targets so the user
    /// knows exactly what they're committing to. The `.logs`
    /// case scopes the action to the in-memory ring buffer so
    /// the user understands OSLog system entries are not
    /// affected.
    var message: String {
        switch self {
        case .sessionCache:
            return "All cached sessions will be removed. They will repopulate on next connect."
        case .messageCache:
            return "All cached messages across every session will be permanently deleted."
        case .allCaches:
            return "Both the session cache and the message cache will be permanently cleared."
        case .logs:
            return "The in-memory debug log ring buffer will be cleared. OSLog entries are not affected."
        }
    }
}