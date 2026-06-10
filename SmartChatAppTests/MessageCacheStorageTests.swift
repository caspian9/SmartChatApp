import XCTest
import OpenClawChatUI
@testable import SmartChatApp

final class MessageCacheStorageTests: XCTestCase {
    private let testSuite = "test.openclaw.messages.\(UUID().uuidString)"
    private var defaults: UserDefaults!
    private var storage: MessageCacheStorage!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: testSuite)!
        defaults.removePersistentDomain(forName: testSuite)
        storage = MessageCacheStorage(defaults: defaults, maxLocalMessages: 200)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: testSuite)
    }

    func test_load_unknownSession_returnsEmpty() async {
        let result = await storage.load(for: "nonexistent")
        XCTAssertEqual(result.count, 0)
    }
}
