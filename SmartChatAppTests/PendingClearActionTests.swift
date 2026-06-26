import XCTest
@testable import SmartChatApp

/// Pins the per-case copy of `PendingClearAction` (the
/// confirmation dialog source-of-truth for the destructive
/// Settings buttons, issue #30). The user-visible alert wording
/// lives in one place (the enum's computed properties), and
/// these tests prevent accidental rewording that would weaken
/// the "names the data at risk" requirement.
///
/// Pure-logic tests — no SwiftUI rendering. Mirrors the
/// `EditProfileSheetTests.matchesHost` precedent for testing
/// without ViewInspector.
final class PendingClearActionTests: XCTestCase {

    func test_sessionCacheTitleAndMessage() {
        let action = PendingClearAction.sessionCache
        XCTAssertEqual(action.title, "Clear Session Cache?")
        XCTAssertTrue(action.message.contains("session"),
                      "message should name the data at risk: \(action.message)")
        XCTAssertFalse(action.message.contains("message"),
                       "session-only message should not mention message cache: \(action.message)")
    }

    func test_messageCacheTitleAndMessage() {
        let action = PendingClearAction.messageCache
        XCTAssertEqual(action.title, "Clear Message Cache?")
        XCTAssertTrue(action.message.contains("message"),
                      "message should name the data at risk: \(action.message)")
        XCTAssertFalse(action.message.contains("OSLog"),
                       "message-cache message should not mention logs: \(action.message)")
    }

    func test_allCachesTitleNamesBothTargets() {
        let action = PendingClearAction.allCaches
        XCTAssertEqual(action.title, "Clear All Caches?")
        XCTAssertTrue(action.message.contains("session"),
                      "combined message must mention sessions: \(action.message)")
        XCTAssertTrue(action.message.contains("message"),
                      "combined message must mention messages: \(action.message)")
    }

    func test_logsTitleAndMessage() {
        let action = PendingClearAction.logs
        XCTAssertEqual(action.title, "Clear Logs?")
        XCTAssertTrue(action.message.contains("log") || action.message.contains("Log"),
                      "logs message should mention logs: \(action.message)")
        // Issue #30: scope the destructive action so the user
        // knows OSLog system entries are not affected.
        XCTAssertTrue(action.message.contains("OSLog") || action.message.contains("in-memory"),
                      "logs message should scope the clear: \(action.message)")
    }

    func test_allCasesHaveUniqueTitles() {
        let titles = PendingClearAction.allCases.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count,
                       "duplicate titles would confuse users: \(titles)")
    }

    func test_allCasesHaveNonEmptyMessages() {
        for action in PendingClearAction.allCases {
            XCTAssertFalse(action.message.isEmpty,
                           "\(action) has empty message - would leave the user guessing")
        }
    }
}