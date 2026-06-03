import XCTest
@testable import SmartChatApp
@testable import OpenClawChatUI
import OpenClawProtocol

/// Simulates gateway agent event payloads exactly as the server emits them and
/// verifies the iOS payload decoder round-trips them into the shape the
/// ViewModel's `extractString` / `extractDouble` helpers expect.
///
/// This is the first link in the chain that the user reported as broken:
/// thinking/tool/toolResult events not appearing in the chat. If decoding
/// produces the right shape, the bug is downstream (ViewModel or view layer);
/// if it doesn't, the bug is here.
final class AgentEventParsingTests: XCTestCase {

    // MARK: - thinking event

    func testThinkingEventDecodesTextField() throws {
        // Exact JSON shape emitted by the gateway's
        // src/agents/pi-embedded-subscribe.ts emitAgentEvent call:
        //   data: { text: trimmed, delta }
        let json = """
        {
          "runId": "run-1",
          "seq": 5,
          "stream": "thinking",
          "ts": 1717200000000,
          "data": {
            "text": "I need to think about this carefully.",
            "delta": "delta-chunk"
          }
        }
        """
        let data = json.data(using: .utf8)!
        let payload = try JSONDecoder().decode(OpenClawAgentEventPayload.self, from: data)

        XCTAssertEqual(payload.stream, "thinking")
        XCTAssertEqual(payload.runId, "run-1")
        XCTAssertEqual(payload.seq, 5)
        XCTAssertNotNil(payload.data["text"])
        XCTAssertEqual(payload.data["text"]?.value as? String, "I need to think about this carefully.")
        XCTAssertEqual(payload.data["delta"]?.value as? String, "delta-chunk")
    }

    // MARK: - tool start event

    func testToolStartEventDecodesArgsDict() throws {
        // Gateway shape: data: { phase: "start", name, toolCallId, args: {...} }
        let json = """
        {
          "runId": "run-1",
          "seq": 6,
          "stream": "tool",
          "ts": 1717200001000,
          "data": {
            "phase": "start",
            "name": "read_file",
            "toolCallId": "call-abc-123",
            "args": {
              "path": "/tmp/foo.txt",
              "maxLines": 50
            }
          }
        }
        """
        let data = json.data(using: .utf8)!
        let payload = try JSONDecoder().decode(OpenClawAgentEventPayload.self, from: data)

        XCTAssertEqual(payload.stream, "tool")
        XCTAssertEqual(payload.data["phase"]?.value as? String, "start")
        XCTAssertEqual(payload.data["name"]?.value as? String, "read_file")
        XCTAssertEqual(payload.data["toolCallId"]?.value as? String, "call-abc-123")
        // args is itself a dict; extractString returns nil for it but the
        // ViewModel reads it via data["args"] directly.
        XCTAssertNotNil(payload.data["args"])
        XCTAssertNotNil(payload.data["args"]?.value as? [String: AnyCodable])
    }

    // MARK: - tool result event

    func testToolResultEventDecodesResultContent() throws {
        // Gateway shape: data: { phase: "result", name, toolCallId, meta,
        //   isError, result: { content: [{ type: "text", text: "..." }] } }
        let json = """
        {
          "runId": "run-1",
          "seq": 7,
          "stream": "tool",
          "ts": 1717200002000,
          "data": {
            "phase": "result",
            "name": "read_file",
            "toolCallId": "call-abc-123",
            "meta": null,
            "isError": false,
            "result": {
              "content": [
                { "type": "text", "text": "hello world" }
              ]
            }
          }
        }
        """
        let data = json.data(using: .utf8)!
        let payload = try JSONDecoder().decode(OpenClawAgentEventPayload.self, from: data)

        XCTAssertEqual(payload.stream, "tool")
        XCTAssertEqual(payload.data["phase"]?.value as? String, "result")
        XCTAssertEqual(payload.data["isError"]?.value as? Bool, false)
        // AnyCodable round-trips nested JSON objects as [String: AnyCodable]
        // and arrays as [AnyCodable]. The ViewModel reaches into them in the
        // same shape, so this is the contract the parser must preserve.
        let result = payload.data["result"]?.value as? [String: AnyCodable]
        XCTAssertNotNil(result)
        let content = result?["content"]?.value as? [AnyCodable]
        XCTAssertNotNil(content)
        let first = content?.first?.value as? [String: AnyCodable]
        XCTAssertEqual(first?["text"]?.value as? String, "hello world")
    }

    // MARK: - lifecycle end event with usage

    func testLifecycleEndEventDecodesUsageTokens() throws {
        // Gateway shape: data: { phase: "end", endedAt, usage: { input, output, cacheRead, cacheWrite } }
        let json = """
        {
          "runId": "run-1",
          "seq": 99,
          "stream": "lifecycle",
          "ts": 1717200099000,
          "data": {
            "phase": "end",
            "endedAt": 1717200099000,
            "usage": {
              "input": 123,
              "output": 456,
              "cacheRead": 78,
              "cacheWrite": 9
            }
          }
        }
        """
        let data = json.data(using: .utf8)!
        let payload = try JSONDecoder().decode(OpenClawAgentEventPayload.self, from: data)

        XCTAssertEqual(payload.stream, "lifecycle")
        // The ViewModel reads usage as both the nested dict and the flat
        // top-level fields. Verify both shapes come through unchanged.
        let usage = payload.data["usage"]?.value as? [String: AnyCodable]
        XCTAssertNotNil(usage)
        XCTAssertEqual(usage?["input"]?.value as? Int, 123)
        XCTAssertEqual(usage?["output"]?.value as? Int, 456)
        XCTAssertEqual(usage?["cacheRead"]?.value as? Int, 78)
        XCTAssertEqual(usage?["cacheWrite"]?.value as? Int, 9)
    }

    // MARK: - formatToolCallText / formatToolResultText

    /// Reproduces the user-facing bug where tool result bubbles appeared but
    /// with empty content. The formatter was casting AnyCodable values to
    /// `[String: Any]` / `[[String: Any]]`, which never matches the actual
    /// `[String: AnyCodable]` / `[AnyCodable]` shape produced by the JSON
    /// decoder, so the function silently fell through to the "Result" /
    /// "Error" fallback.
    func testFormatToolResultTextExtractsContentText() {
        let vm = NativeChatViewModel()
        // Build the same shape AnyCodable produces for a real tool result:
        // data["result"] -> AnyCodable with value: [String: AnyCodable] { "content": AnyCodable with value: [AnyCodable] }
        let contentItem: [String: AnyCodable] = ["type": AnyCodable("text"), "text": AnyCodable("hello world")]
        let contentArray: [AnyCodable] = [AnyCodable(contentItem)]
        let resultInner: [String: AnyCodable] = ["content": AnyCodable(contentArray)]
        let result = AnyCodable(resultInner)

        let formatted = vm.formatToolResultText(result: result, isError: false, toolName: "read_file")
        XCTAssertEqual(formatted, "Result: hello world",
                       "tool result should include the actual content text, not fall through to the 'Result' placeholder")
    }

    func testFormatToolResultTextFallsBackForError() {
        let vm = NativeChatViewModel()
        let formatted = vm.formatToolResultText(result: nil, isError: true, toolName: "boom")
        XCTAssertEqual(formatted, "Error")
    }

    func testFormatToolCallTextIncludesArgs() {
        let vm = NativeChatViewModel()
        // Real args shape: [String: AnyCodable]
        let args: [String: AnyCodable] = [
            "path": AnyCodable("/tmp/foo.txt"),
            "maxLines": AnyCodable(50),
        ]
        let formatted = vm.formatToolCallText(name: "read_file", args: AnyCodable(args))
        XCTAssertTrue(formatted.contains("ToolCall: read_file"), "should include the tool name header")
        XCTAssertTrue(formatted.contains("path: /tmp/foo.txt"), "should include the path arg")
        XCTAssertTrue(formatted.contains("maxLines: 50"), "should include the numeric arg")
    }

    /// The lifecycle-end handler reads `data["usage"]` to populate the
    /// "↑input ↓output" footer. The previous cast (to [String: Any]) silently
    /// never matched AnyCodable's real shape, so the footer was always empty
    /// even though the gateway does send the values.
    func testLifecycleUsageTokensAreReadable() throws {
        // The reducer's read path is private, but we can prove the contract
        // by reconstructing the exact same `value` cast it performs and
        // confirming the numbers come back.
        let json = """
        {
          "runId": "run-1",
          "seq": 1,
          "stream": "lifecycle",
          "ts": 1,
          "data": {
            "phase": "end",
            "endedAt": 1000,
            "usage": { "input": 100, "output": 200, "cacheRead": 30, "cacheWrite": 40 }
          }
        }
        """
        let payload = try JSONDecoder().decode(OpenClawAgentEventPayload.self, from: json.data(using: .utf8)!)
        let usage = payload.data["usage"]?.value as? [String: AnyCodable]
        XCTAssertNotNil(usage)
        XCTAssertEqual(usage?["input"]?.value as? Int, 100)
        XCTAssertEqual(usage?["output"]?.value as? Int, 200)
        XCTAssertEqual(usage?["cacheRead"]?.value as? Int, 30)
        XCTAssertEqual(usage?["cacheWrite"]?.value as? Int, 40)
    }

    // MARK: - cross-stream order

    func testCrossStreamEventsAllDecode() throws {
        // The order the gateway emits during one assistant turn:
        //   lifecycle start → thinking chunks → tool start/update/result →
        //   assistant chunks → lifecycle end.
        // All of them should round-trip with their data intact.
        let payloads: [(String, String)] = [
            ("lifecycle", #"{"phase":"start","startedAt":1000}"#),
            ("thinking", #"{"text":"pondering...","delta":"pondering..."}"#),
            ("tool", #"{"phase":"start","name":"read_file","toolCallId":"c1","args":{"path":"/a"}}"#),
            ("tool", #"{"phase":"result","name":"read_file","toolCallId":"c1","isError":false,"result":{"content":[{"type":"text","text":"contents"}]}}"#),
            ("assistant", #"{"text":"The answer is 42.","delta":"The answer is 42."}"#),
            ("lifecycle", #"{"phase":"end","endedAt":2000,"usage":{"input":10,"output":20}}"#),
        ]
        for (stream, dataJSON) in payloads {
            let json = """
            {"runId":"run-X","seq":1,"stream":"\(stream)","ts":1500,"data":\(dataJSON)}
            """
            let data = json.data(using: .utf8)!
            let payload = try JSONDecoder().decode(OpenClawAgentEventPayload.self, from: data)
            XCTAssertEqual(payload.stream, stream, "stream mismatch for \(stream)")
            XCTAssertFalse(payload.data.isEmpty, "data empty for \(stream)")
        }
    }
}
