import XCTest
@testable import SmartChatApp

final class ConfigurationManagerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var testSuite: String!

    override func setUp() async throws {
        testSuite = "test.openclaw.config.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: testSuite)!
        defaults.removePersistentDomain(forName: testSuite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: testSuite)
    }

    func test_logsChatMessagesCacheDump_defaultsToFalse() {
        let key = "openclaw_logs_chat_messages_cache_dump"
        XCTAssertNil(defaults.object(forKey: key),
                     "precondition: defaults suite is clean")
        XCTAssertFalse(
            defaults.object(forKey: key) as? Bool ?? false,
            "precondition: UserDefaults fallback for unknown key is false"
        )
    }

    func test_logsChatMessagesRenderDump_defaultsToFalse() {
        let key = "openclaw_logs_chat_messages_render_dump"
        XCTAssertNil(defaults.object(forKey: key),
                     "precondition: defaults suite is clean")
        XCTAssertFalse(
            defaults.object(forKey: key) as? Bool ?? false,
            "precondition: UserDefaults fallback for unknown key is false"
        )
    }

    func test_logsChatMessagesCacheDump_roundTripsThroughUserDefaults() {
        defaults.set(true, forKey: "openclaw_logs_chat_messages_cache_dump")
        let reloaded = defaults.object(forKey: "openclaw_logs_chat_messages_cache_dump") as? Bool
        XCTAssertEqual(reloaded, true,
                       "UserDefaults must persist the cache-dump toggle across reads")
    }
}