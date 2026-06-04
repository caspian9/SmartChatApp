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
