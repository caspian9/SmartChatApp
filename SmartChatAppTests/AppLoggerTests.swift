import XCTest
@testable import SmartChatApp

final class LogRingBufferTests: XCTestCase {

    private func entry(_ msg: String) -> LogEntry {
        LogEntry(id: UUID(), ts: Date(), category: .network, level: .debug, message: msg)
    }

    func test_append_storesEntry() {
        var buf = LogRingBuffer(capacity: 3)
        buf.append(entry("a"))
        XCTAssertEqual(buf.entries.map(\.message), ["a"])
    }

    func test_append_underCapacity_keepsAll() {
        var buf = LogRingBuffer(capacity: 3)
        buf.append(entry("a"))
        buf.append(entry("b"))
        XCTAssertEqual(buf.entries.map(\.message), ["a", "b"])
    }

    func test_append_atCapacity_keepsAll() {
        var buf = LogRingBuffer(capacity: 3)
        buf.append(entry("a"))
        buf.append(entry("b"))
        buf.append(entry("c"))
        XCTAssertEqual(buf.entries.map(\.message), ["a", "b", "c"])
    }

    func test_append_overCapacity_evictsOldest() {
        var buf = LogRingBuffer(capacity: 3)
        buf.append(entry("a"))
        buf.append(entry("b"))
        buf.append(entry("c"))
        buf.append(entry("d"))
        XCTAssertEqual(buf.entries.map(\.message), ["b", "c", "d"])
    }

    func test_append_farOverCapacity_keepsLastNOnly() {
        var buf = LogRingBuffer(capacity: 2)
        for i in 0..<10 {
            buf.append(entry("\(i)"))
        }
        XCTAssertEqual(buf.entries.map(\.message), ["8", "9"])
    }

    func test_clear_emptiesBuffer() {
        var buf = LogRingBuffer(capacity: 3)
        buf.append(entry("a"))
        buf.append(entry("b"))
        buf.clear()
        XCTAssertTrue(buf.entries.isEmpty)
    }
}

@MainActor
final class AppLoggerTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        AppLogger.shared.clear()
        for cat in LogCategory.allCases {
            AppLogger.shared.setEnabled(cat, false)
        }
    }

    func test_log_disabledCategory_doesNotEnterBuffer() async {
        AppLogger.shared.setEnabled(.network, false)
        AppLogger.log("hello", category: .network)
        await Task.yield()
        XCTAssertTrue(AppLogger.shared.entries.isEmpty)
    }

    func test_log_enabledCategory_entersBuffer() async {
        AppLogger.shared.setEnabled(.network, true)
        AppLogger.log("hello", category: .network)
        await Task.yield()
        XCTAssertEqual(AppLogger.shared.entries.count, 1)
        XCTAssertEqual(AppLogger.shared.entries.first?.message, "hello")
        XCTAssertEqual(AppLogger.shared.entries.first?.category, .network)
    }

    func test_log_onlyEnabledCategoriesEnterBuffer() async {
        AppLogger.shared.setEnabled(.network, true)
        AppLogger.shared.setEnabled(.cache, false)
        AppLogger.log("net", category: .network)
        AppLogger.log("cache", category: .cache)
        await Task.yield()
        XCTAssertEqual(AppLogger.shared.entries.map(\.message), ["net"])
    }

    func test_setEnabled_falseAfterTrue_subsequentLogsDropped() async {
        AppLogger.shared.setEnabled(.network, true)
        AppLogger.log("a", category: .network)
        await Task.yield()
        AppLogger.shared.setEnabled(.network, false)
        AppLogger.log("b", category: .network)
        await Task.yield()
        XCTAssertEqual(AppLogger.shared.entries.map(\.message), ["a"])
    }

    func test_clear_emptiesEntries() async {
        AppLogger.shared.setEnabled(.network, true)
        AppLogger.log("a", category: .network)
        AppLogger.log("b", category: .network)
        await Task.yield()
        AppLogger.shared.clear()
        XCTAssertTrue(AppLogger.shared.entries.isEmpty)
    }

    func test_log_level_isCapturedInEntry() async {
        AppLogger.shared.setEnabled(.network, true)
        AppLogger.log("warn msg", category: .network, level: .warning)
        await Task.yield()
        XCTAssertEqual(AppLogger.shared.entries.first?.level, .warning)
    }

    func test_log_fromBackgroundActor_entersBuffer() async {
        AppLogger.shared.setEnabled(.network, true)
        // Detached task: explicitly NOT on the main actor.
        await Task.detached {
            AppLogger.log("from background", category: .network)
        }.value
        // Yield to let the buffer-append Task run on main actor.
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(AppLogger.shared.entries.first?.message, "from background")
    }
}
