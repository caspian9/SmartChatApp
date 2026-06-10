import XCTest
import OpenClawProtocol
@testable import SmartChatApp

@MainActor
final class ServerCommandSourceTests: XCTestCase {
    func test_init_isEmpty() {
        let s = ServerCommandSource()
        XCTAssertTrue(s.entries.isEmpty)
        XCTAssertFalse(s.isFetched)
        XCTAssertNil(s.lastError)
    }

    func test_contains_returnsFalseWhenEmpty() {
        let s = ServerCommandSource()
        XCTAssertFalse(s.contains("/foo"))
    }

    func test_refresh_noopWithoutTransport() async {
        let s = ServerCommandSource()  // transport defaults to nil
        await s.refresh()
        XCTAssertTrue(s.entries.isEmpty)
        XCTAssertFalse(s.isFetched)
    }
}
