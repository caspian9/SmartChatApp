import XCTest
@testable import SmartChatApp

@MainActor
final class LocalCommandRegistryTests: XCTestCase {
    func test_registerAll_populatesV1Set() {
        let r = LocalCommandRegistry()
        let ids = Set(r.all.map(\.id))
        // v1 set per spec; future additions show up here automatically
        XCTAssertTrue(ids.contains("/help"))
        XCTAssertTrue(ids.contains("/clear"))
        XCTAssertTrue(ids.contains("/connect"))
        XCTAssertTrue(ids.contains("/disconnect"))
        XCTAssertTrue(ids.contains("/profiles"))
    }

    func test_lookup_returnsCommandForKnownToken() {
        let r = LocalCommandRegistry()
        XCTAssertEqual(r.lookup("/help")?.description,
                       "Show available commands")
        XCTAssertEqual(r.lookup("/clear")?.description,
                       "Clear chat history")
        XCTAssertEqual(r.lookup("/connect")?.description,
                       "Reconnect to gateway")
        XCTAssertEqual(r.lookup("/disconnect")?.description,
                       "Disconnect from gateway")
        XCTAssertEqual(r.lookup("/profiles")?.description,
                       "List gateway profiles")
    }

    func test_lookup_returnsNilForUnknownToken() {
        let r = LocalCommandRegistry()
        XCTAssertNil(r.lookup("/foo"))
        XCTAssertNil(r.lookup("/"))
    }

    func test_lookup_isCaseInsensitive() {
        let r = LocalCommandRegistry()
        XCTAssertNotNil(r.lookup("/HELP"))
        XCTAssertNotNil(r.lookup("/Help"))
    }

    func test_lookup_normalizesLeadingSlashContract() {
        let r = LocalCommandRegistry()
        XCTAssertNil(r.lookup("help"),
            "lookup expects the leading slash; parseFirstToken enforces this")
    }

    func test_all_commandsHaveExecutor() {
        let r = LocalCommandRegistry()
        for cmd in r.all {
            XCTAssertNotNil(cmd.executor,
                "Local command \(cmd.id) must have an executor")
            XCTAssertEqual(cmd.source, .local)
        }
    }

    // --- Extensibility ---

    func test_register_extendsRegistryAtRuntime() {
        let r = LocalCommandRegistry()
        let initialCount = r.all.count
        r.register(.init(
            id: "/theme", description: "Change theme",
            source: .local, executor: { _ in .bubble("ok") }
        ))
        XCTAssertEqual(r.all.count, initialCount + 1)
        XCTAssertNotNil(r.lookup("/theme"))
    }

    func test_register_overwritesExistingEntry() {
        let r = LocalCommandRegistry()
        r.register(.init(
            id: "/help", description: "new help",
            source: .local, executor: { _ in .bubble("new") }
        ))
        XCTAssertEqual(r.lookup("/help")?.description, "new help")
    }
}
