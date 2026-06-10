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

    // --- Task 5 additions ---

    func test_refresh_populatesFromTransport() async {
        let transport = FakeTransport()
        transport.responses["commands.list"] = """
        {"commands":[
          {"name":"/status","description":"Show status",
           "acceptsArgs":false,"source":"native","scope":"text"}
        ]}
        """
        let s = ServerCommandSource(transport: transport)
        await s.refresh()
        XCTAssertTrue(s.isFetched)
        XCTAssertTrue(s.contains("/status"))
        XCTAssertEqual(s.entries.first?.description, "Show status")
        XCTAssertNil(s.lastError)
    }

    func test_refresh_retriesOnceOnFailure() async {
        let transport = FakeTransport()
        transport.failures["commands.list"] = 1
        transport.responses["commands.list"] = """
        {"commands":[
          {"name":"/x","description":"d",
           "acceptsArgs":false,"source":"native","scope":"text"}
        ]}
        """
        let s = ServerCommandSource(transport: transport,
                                    retryDelay: .zero)
        await s.refresh()
        XCTAssertTrue(s.isFetched)
    }

    func test_refresh_marksUnfetchedAfterTwoFailures() async {
        let transport = FakeTransport()
        transport.failures["commands.list"] = 99
        let s = ServerCommandSource(transport: transport,
                                    retryDelay: .zero)
        await s.refresh()
        XCTAssertFalse(s.isFetched)
        XCTAssertNotNil(s.lastError)
    }

    func test_refresh_handlesMalformedJSON() async {
        let transport = FakeTransport()
        transport.responses["commands.list"] = "not json at all"
        let s = ServerCommandSource(transport: transport,
                                    retryDelay: .zero)
        await s.refresh()
        XCTAssertFalse(s.isFetched)
        XCTAssertNotNil(s.lastError)
    }
}
