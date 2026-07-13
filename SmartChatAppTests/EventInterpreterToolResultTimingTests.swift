import XCTest
import OpenClawChatUI
import OpenClawProtocol
@testable import SmartChatApp

/// Regression for the user-reported scenario on 2026-06-30 with
/// runId 178660A3-1C79-4EBE-AC1F-9DEEA11C103B: the toolResult
/// bubble for "Weather report: Beijing..." had no start time in
/// the bubble footer (only end time). Same symptom path the
/// stream=assistant post-upsert log could not cross-check
/// (`bubbleExists=false` due to the id change to
/// `<runId>:assistant:<N>`).
///
/// The bubble's `startedAt` field comes from the streaming-
/// metadata overlay (the SDK's `OpenClawChatMessage` doesn't
/// carry `startedAt`/`endedAt`). When `chatMessages(for:)`
/// reads back, `applyStreamingMetadata` looks up the bubble by
/// `msg.id` and overlays `startedAt`/`endedAt` from the
/// metadata recorded by `recordStreamingMetadata` at upsert
/// time. If the lookup fails (because the metadata was recorded
/// under a different key than the bubble's `msg.id`), the
/// overlay silently drops both fields.
///
/// This test runs the exact event sequence the user reported
/// and asserts the toolResult bubble carries BOTH `startedAt`
/// and `endedAt` after the view-side overlay.
@MainActor
final class EventInterpreterToolResultTimingTests: XCTestCase {
    private var vm: NativeChatViewModel!
    private var store: MessageCacheStore!
    private var fakeStorage: FakeMessageCacheStorage!
    private var interpreter: EventInterpreter!

    override func setUp() async throws {
        fakeStorage = FakeMessageCacheStorage()
        store = MessageCacheStore(storage: fakeStorage)
        vm = NativeChatViewModel(store: store)
        vm.selectedSession = makeTestSession()
        interpreter = vm.eventInterpreter
        CollapseStateCache.shared.clear()
    }

    override func tearDown() async throws {
        CollapseStateCache.shared.clear()
        vm = nil
        store = nil
        fakeStorage = nil
        interpreter = nil
    }

    /// The user's reported sequence: two TOOLS in a single run
    /// (tool 1: read, tool 2: exec fetch w1, tool 3: exec fetch w2).
    /// The user's screenshot shows the SECOND toolResult (#27,
    /// "Weather report: Beijing...") is missing its start-time
    /// footer while the FIRST toolResult (#16, "Beijing: ...")
    /// renders both start and end correctly. This test runs the
    /// full two-tool sequence and asserts BOTH toolResults
    /// carry `startedAt` after the streaming-metadata overlay.
    func test_twoSequentialTools_bothToolResultsCarryStartedAt() async throws {
        let runId = "r-tr-timing-2"
        // Issue #34 strict gate: register the runId with the test session
        // (mirrors the chat-event path that production uses to populate the runId → sessionKey map)
        vm.recordRunSession("session-1", for: runId, overwriteIfExisting: true)

        // Tool A canonical.
        let toolA = "call_00_A"
        // Tool B canonical.
        let toolB = "call_00_B"

        // Lifecycle start (ts=1000 simulated seconds).
        await interpreter.handleTransportEvent(
            .agent(makeAgentEvent(
                runId: runId, seq: 1, stream: "lifecycle", ts: 1_000,
                data: ["phase": AnyCodable("start"),
                       "startedAt": AnyCodable(Double(1_000))])),
            sessionKey: "session-1")

        // --- TOOL A (mimics the user's tool 2 "Beijing") ---
        await sendItemStart(runId: runId, ts: 1_500, canonical: toolA, kind: "tool")
        await sendItemStart(runId: runId, ts: 1_501, canonical: toolA, kind: "command")
        await sendCommandOutput(runId: runId, ts: 1_600, canonical: toolA, phase: "delta", output: "Beijing: in-progress")
        await sendItemEnd(runId: runId, ts: 1_700, canonical: toolA, kind: "tool")
        await sendItemEnd(runId: runId, ts: 1_701, canonical: toolA, kind: "command",
                          summary: "Beijing: 🌦️ ...\nexit=0 duration=1297ms")
        await sendCommandOutput(runId: runId, ts: 1_702, canonical: toolA, phase: "end",
                               output: "Beijing: 🌦️ ...\nexit=0 duration=1297ms")

        // --- TOOL B (mimics the user's tool 3 "Weather report") ---
        // Same toolKey suffix but DIFFERENT canonical — exercises
        // the bug where tool A's cleanup of `toolStartedAtByCall`
        // for canonical A would clobber tool B's key (it shouldn't,
        // because keys differ; but if it did, #27 would lose
        // its startedAt because tool A's cleanup cleared the
        // SHARED dict entry).
        await sendItemStart(runId: runId, ts: 2_000, canonical: toolB, kind: "tool")
        await sendItemStart(runId: runId, ts: 2_001, canonical: toolB, kind: "command")
        await sendCommandOutput(runId: runId, ts: 2_100, canonical: toolB, phase: "delta", output: "Weather report: in-progress")
        await sendItemEnd(runId: runId, ts: 2_200, canonical: toolB, kind: "tool")
        await sendItemEnd(runId: runId, ts: 2_201, canonical: toolB, kind: "command",
                          summary: "Weather report: Beijing...")
        await sendCommandOutput(runId: runId, ts: 2_202, canonical: toolB, phase: "end",
                               output: "Weather report: Beijing...\nexit=0 duration=803ms")

        // Both toolResult bubbles should carry startedAt.
        let toolResults = vm.chatMessages(for: "session-1")
            .filter { $0.role == "toolResult" }
        XCTAssertEqual(toolResults.count, 2,
            "Expected one toolResult per tool — got \(toolResults.count)")

        for result in toolResults {
            XCTAssertNotNil(
                result.startedAt,
                "toolResult.startedAt must NOT be nil — text=\(String(result.text.prefix(40))) id=\(result.id)")
            XCTAssertNotNil(
                result.endedAt,
                "toolResult.endedAt must NOT be nil — text=\(String(result.text.prefix(40))) id=\(result.id)")
        }
    }

    /// G3 (audit 2026-07-07): `command_output (end)` must
    /// clear `accumulatedToolOutputByCall[toolKey]` so a
    /// subsequent call reusing the same `toolKey` (the
    /// upstream call id is the same; the server resets
    /// its counter on a fresh agent session) starts with
    /// an empty accumulator instead of inheriting the
    /// previous call's text.
    ///
    /// Without this, two distinct tool invocations could
    /// appear to share a single bubble — the second's
    /// `command_output (delta)` would append to the first's
    /// accumulated text, and the user would see both
    /// invocations' output in one bubble.
    func test_commandOutputAccumulatorReusedAfterPhaseEnd_startsFresh() async throws {
        let runId = "r-tr-reuse"
        // Issue #34 strict gate: register the runId with the test session
        // (mirrors the chat-event path that production uses to populate the runId → sessionKey map)
        vm.recordRunSession("session-1", for: runId, overwriteIfExisting: true)
        let canonical = "call_00_reuse"

        // Lifecycle start.
        await interpreter.handleTransportEvent(
            .agent(makeAgentEvent(
                runId: runId, seq: 1, stream: "lifecycle", ts: 1_000,
                data: ["phase": AnyCodable("start"),
                       "startedAt": AnyCodable(Double(1_000))])),
            sessionKey: "session-1")

        // First call: completes normally. End phase should
        // clear the accumulator.
        await sendItemStart(runId: runId, ts: 1_500, canonical: canonical, kind: "tool")
        await sendItemStart(runId: runId, ts: 1_501, canonical: canonical, kind: "command")
        await sendCommandOutput(runId: runId, ts: 1_600, canonical: canonical,
                                phase: "delta", output: "FIRST: chunk-1\n")
        await sendCommandOutput(runId: runId, ts: 1_650, canonical: canonical,
                                phase: "delta", output: "FIRST: chunk-2\n")
        await sendCommandOutput(runId: runId, ts: 1_700, canonical: canonical,
                                phase: "end",
                                output: "FIRST: full body\n")

        // Capture the first call's toolResult. The accumulated
        // body is "FIRST: chunk-1\nFIRST: chunk-2\nFIRST: full
        // body\n" (plus the exit/duration trailer appended at
        // line 1378 of EventInterpreter).
        let firstResults = vm.chatMessages(for: "session-1")
            .filter { $0.role == "toolResult" }
        XCTAssertGreaterThanOrEqual(firstResults.count, 1,
            "first call must produce at least one toolResult bubble")
        let firstText = firstResults.last?.text ?? ""
        XCTAssertTrue(firstText.contains("FIRST:"),
            "first toolResult must contain the FIRST: marker — got: \(String(firstText.prefix(120)))")

        // Second call reusing the same toolKey/canonical.
        // If `command_output (end)` did NOT clear the
        // accumulator (regression), the next delta would
        // append to the FIRST's accumulated text and the
        // bubble would contain "FIRST: ... SECOND: ...".
        await sendItemStart(runId: runId, ts: 3_000, canonical: canonical, kind: "tool")
        await sendItemStart(runId: runId, ts: 3_001, canonical: canonical, kind: "command")
        await sendCommandOutput(runId: runId, ts: 3_100, canonical: canonical,
                                phase: "delta", output: "SECOND: chunk-1\n")
        await sendCommandOutput(runId: runId, ts: 3_150, canonical: canonical,
                                phase: "delta", output: "SECOND: chunk-2\n")
        await sendCommandOutput(runId: runId, ts: 3_200, canonical: canonical,
                                phase: "end",
                                output: "SECOND: full body\n")

        // The latest toolResult (the second call's) must NOT
        // contain the FIRST call's text. If it does, the
        // accumulator wasn't reset on phase=end.
        let allResults = vm.chatMessages(for: "session-1")
            .filter { $0.role == "toolResult" }
        let latest = allResults.last?.text ?? ""
        XCTAssertFalse(latest.contains("FIRST:"),
            "G3: latest toolResult leaked FIRST call's text into the SECOND call's bubble — accumulator was not cleared on phase=end. Latest text: \(String(latest.prefix(200)))")
        XCTAssertTrue(latest.contains("SECOND:"),
            "G3: latest toolResult must contain the SECOND: marker — got: \(String(latest.prefix(120)))")
    }

    private func sendItemStart(runId: String, ts: Int, canonical: String, kind: String) async {
        await interpreter.handleTransportEvent(
            .agent(makeItemEvent(
                runId: runId, ts: ts, canonical: canonical,
                kind: kind, name: "exec",
                phase: "start", startedAt: ts - 10)),
            sessionKey: "session-1")
    }

    private func sendItemEnd(runId: String, ts: Int, canonical: String, kind: String,
                              summary: String? = nil) async {
        await interpreter.handleTransportEvent(
            .agent(makeItemEvent(
                runId: runId, ts: ts, canonical: canonical,
                kind: kind, name: "exec",
                phase: "end", startedAt: ts - 200, endedAt: ts,
                summary: summary)),
            sessionKey: "session-1")
    }

    private func sendCommandOutput(runId: String, ts: Int, canonical: String,
                                   phase: String, output: String) async {
        await interpreter.handleTransportEvent(
            .agent(makeCommandOutputEvent(
                runId: runId, ts: ts, canonical: canonical,
                phase: phase, output: output)),
            sessionKey: "session-1")
    }

    // MARK: - Test session

    private func makeTestSession() -> OpenClawChatSessionEntry {
        OpenClawChatSessionEntry(
            key: "session-1",
            kind: "test",
            displayName: "Test Session",
            surface: nil, subject: nil, room: nil, space: nil,
            updatedAt: nil, sessionId: nil, systemSent: nil, abortedLastRun: nil,
            thinkingLevel: nil, verboseLevel: nil, inputTokens: nil, outputTokens: nil,
            totalTokens: nil, modelProvider: nil, model: nil, contextTokens: nil,
            thinkingLevels: nil, thinkingOptions: nil, thinkingDefault: nil
        )
    }

    // MARK: - SDK constructor helpers (Codable round-trip)

    private func makeAgentEvent(
        runId: String, seq: Int? = 1, stream: String, ts: Int?,
        data: [String: AnyCodable]
    ) -> OpenClawAgentEventPayload {
        struct Wire: Codable {
            let runId: String
            let seq: Int?
            let stream: String
            let ts: Int?
            let data: [String: AnyCodable]
        }
        let wire = Wire(runId: runId, seq: seq, stream: stream, ts: ts, data: data)
        let json = try! JSONEncoder().encode(wire)
        return try! JSONDecoder().decode(OpenClawAgentEventPayload.self, from: json)
    }

    private func makeItemEvent(
        runId: String, ts: Int, canonical: String,
        kind: String, name: String,
        phase: String, startedAt: Int? = nil, endedAt: Int? = nil,
        summary: String? = nil
    ) -> OpenClawAgentEventPayload {
        var data: [String: AnyCodable] = [
            "itemId": AnyCodable("\(kind):\(canonical)"),
            "toolCallId": AnyCodable(canonical),
            "kind": AnyCodable(kind),
            "name": AnyCodable(name),
            "phase": AnyCodable(phase),
        ]
        if let startedAt { data["startedAt"] = AnyCodable(Double(startedAt)) }
        if let endedAt { data["endedAt"] = AnyCodable(Double(endedAt)) }
        if let summary { data["summary"] = AnyCodable(summary) }
        return makeAgentEvent(
            runId: runId, seq: 1, stream: "item", ts: ts, data: data)
    }

    private func makeCommandOutputEvent(
        runId: String, ts: Int, canonical: String,
        phase: String, output: String
    ) -> OpenClawAgentEventPayload {
        let data: [String: AnyCodable] = [
            "itemId": AnyCodable("command:\(canonical)"),
            "toolCallId": AnyCodable(canonical),
            "name": AnyCodable("exec"),
            "phase": AnyCodable(phase),
            "output": AnyCodable(output),
        ]
        return makeAgentEvent(
            runId: runId, seq: 1, stream: "command_output", ts: ts, data: data)
    }
}
