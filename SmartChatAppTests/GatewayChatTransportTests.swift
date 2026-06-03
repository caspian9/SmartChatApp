import XCTest
@testable import SmartChatApp
@testable import OpenClawChatUI

final class GatewayChatTransportTests: XCTestCase {

    func testSendMessageJSONConstruction() throws {
        // Test that JSON string building works without crashing
        let sessionKey = "test-session"
        let message = "Hello World"
        let idempotencyKey = "test-key"

        var jsonParts = [
            "\"\("key")\": \"\(sessionKey)\"",
            "\"\("message")\": \"\(message)\"",
            "\"\("idempotencyKey")\": \"\(idempotencyKey)\""
        ]
        let jsonString = "{\(jsonParts.joined(separator: ", "))}"

        XCTAssertTrue(jsonString.contains("\"key\": \"test-session\""))
        XCTAssertTrue(jsonString.contains("\"message\": \"Hello World\""))
        XCTAssertTrue(jsonString.contains("\"idempotencyKey\": \"test-key\""))
    }

    func testSendMessageResponseParsing() throws {
        let json = "{\"runId\": \"test-key\", \"status\": \"started\"}"
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(OpenClawChatSendResponse.self, from: data)

        XCTAssertEqual(response.runId, "test-key")
        XCTAssertEqual(response.status, "started")
    }

    func testListSessionsResponseParsing() throws {
        let json = """
        {"sessions": [], "count": 0, "ts": 1234567890.0}
        """
        let data = json.data(using: .utf8)!

        struct ListSessionsRaw: Decodable {
            let sessions: [OpenClawChatSessionEntry]
            let count: Int?
            let ts: Double?
            let path: String?
        }

        let raw = try JSONDecoder().decode(ListSessionsRaw.self, from: data)
        XCTAssertEqual(raw.count, 0)
        XCTAssertEqual(raw.ts, 1234567890.0)
    }

    func testOpenClawChatEventPayloadEncoding() throws {
        let payload = OpenClawChatEventPayload(
            runId: "run-1",
            sessionKey: "main",
            state: "final",
            message: nil,
            errorMessage: nil
        )

        let data = try JSONEncoder().encode(payload)
        let jsonString = String(data: data, encoding: .utf8)!

        XCTAssertTrue(jsonString.contains("\"runId\""))
        XCTAssertTrue(jsonString.contains("\"main\""))
        XCTAssertTrue(jsonString.contains("\"final\""))
    }

    func testOpenClawAgentEventPayloadEncoding() throws {
        let payload = OpenClawAgentEventPayload(
            runId: "run-1",
            seq: 1,
            stream: "assistant",
            ts: 1234567890,
            data: [:]
        )

        let data = try JSONEncoder().encode(payload)
        let jsonString = String(data: data, encoding: .utf8)!

        XCTAssertTrue(jsonString.contains("\"runId\""))
        XCTAssertTrue(jsonString.contains("\"assistant\""))
    }
}
