import XCTest
@testable import SmartChatApp
@testable import OpenClawProtocol

final class NativeChatViewModelFormatterTests: XCTestCase {
    var sut: NativeChatViewModel!

    override func setUp() {
        super.setUp()
        sut = NativeChatViewModel()
    }

    // MARK: - formatToolCallText

    func testFormatToolCallText_nilArgs_returnsName() {
        XCTAssertEqual(sut.formatToolCallText(name: "read_file", args: nil), "read_file")
    }

    func testFormatToolCallText_stringArgs_returnsNameColonString() {
        XCTAssertEqual(
            sut.formatToolCallText(name: "read_file", args: "path/to/x.txt"),
            "read_file: path/to/x.txt"
        )
    }

    func testFormatToolCallText_emptyStringArgs_returnsName() {
        XCTAssertEqual(sut.formatToolCallText(name: "read_file", args: ""), "read_file")
    }

    func testFormatToolCallText_emptyName_returnsEmpty() {
        XCTAssertEqual(sut.formatToolCallText(name: "", args: "anything"), "")
    }

    func testFormatToolCallText_dictArgs_serializesAsJSON() {
        let result = sut.formatToolCallText(
            name: "read_file",
            args: ["path": "x.txt"] as [String: Any]
        )
        XCTAssertTrue(result.hasPrefix("read_file: "))
        XCTAssertTrue(result.contains("\"path\""))
        XCTAssertTrue(result.contains("\"x.txt\""))
    }

    func testFormatToolCallText_arrayArgs_serializesAsJSON() {
        let result = sut.formatToolCallText(
            name: "batch",
            args: ["a", "b", "c"] as [Any]
        )
        XCTAssertTrue(result.hasPrefix("batch: "))
        XCTAssertTrue(result.contains("\"a\""))
    }

    // MARK: - formatToolResultText

    func testFormatToolResultText_nil_returnsEmpty() {
        XCTAssertEqual(sut.formatToolResultText(result: nil), "")
    }

    func testFormatToolResultText_string_returnsUnchanged() {
        XCTAssertEqual(sut.formatToolResultText(result: "OK"), "OK")
    }

    func testFormatToolResultText_dict_returnsPrettyJSON() {
        let result = sut.formatToolResultText(
            result: ["status": "ok", "code": 200] as [String: Any]
        )
        XCTAssertTrue(result.contains("\"status\""))
        XCTAssertTrue(result.contains("\"ok\""))
        XCTAssertTrue(result.contains("200"))
        // Pretty-printed JSON contains newlines between keys
        XCTAssertTrue(result.contains("\n"))
    }

    // MARK: - formatAnyCodableValue

    func testFormatString_returnsValue() {
        XCTAssertEqual(sut.formatAnyCodableValue("hello"), "hello")
    }

    func testFormatString_empty_returnsEmpty() {
        XCTAssertEqual(sut.formatAnyCodableValue(""), "")
    }

    func testFormatString_whitespaceOnly_returnsEmpty() {
        XCTAssertEqual(sut.formatAnyCodableValue("   \n  "), "")
    }

    func testFormatString_multiline_returnsFirstLine() {
        XCTAssertEqual(sut.formatAnyCodableValue("line1\nline2\nline3"), "line1")
    }

    func testFormatString_over160Chars_isTruncated() {
        let s = String(repeating: "x", count: 200)
        let result = sut.formatAnyCodableValue(s)
        // 157 chars + ellipsis = 158 total
        XCTAssertEqual(result.count, 158)
        XCTAssertTrue(result.hasSuffix("…"))
    }

    func testFormatInt_returnsString() {
        XCTAssertEqual(sut.formatAnyCodableValue(42), "42")
    }

    func testFormatDouble_returnsString() {
        XCTAssertEqual(sut.formatAnyCodableValue(3.14), "3.14")
    }

    func testFormatBool_true() {
        XCTAssertEqual(sut.formatAnyCodableValue(true), "true")
    }

    func testFormatBool_false() {
        XCTAssertEqual(sut.formatAnyCodableValue(false), "false")
    }

    func testFormatArray_threeItems_joined() {
        XCTAssertEqual(sut.formatAnyCodableValue(["a", "b", "c"]), "a, b, c")
    }

    func testFormatArray_fiveItems_truncatedWithEllipsis() {
        let result = sut.formatAnyCodableValue(["a", "b", "c", "d", "e"])
        XCTAssertEqual(result, "a, b, c…")
    }

    func testFormatArray_empty_returnsEmpty() {
        XCTAssertEqual(sut.formatAnyCodableValue([String]()), "")
    }

    func testFormatAnyDict_prefersNameKey() {
        let result = sut.formatAnyCodableValue(
            ["name": "read_file", "id": "1"] as [String: Any]
        )
        XCTAssertEqual(result, "read_file")
    }

    func testFormatAnyDict_skipsEmptyPreferredKeyFallsToId() {
        let result = sut.formatAnyCodableValue(
            ["name": "", "id": "1"] as [String: Any]
        )
        XCTAssertEqual(result, "1")
    }

    func testFormatAnyDict_prefersCommandKey() {
        let result = sut.formatAnyCodableValue(
            ["command": "ls -la"] as [String: Any]
        )
        XCTAssertEqual(result, "ls -la")
    }

    func testFormatAnyCodableDict_usesGenericScanForUnknownKey() {
        let result = sut.formatAnyCodableValue(["unknown": AnyCodable("fallback_value")])
        XCTAssertEqual(result, "fallback_value")
    }
}
