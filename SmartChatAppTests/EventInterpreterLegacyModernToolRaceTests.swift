import XCTest
import OpenClawChatUI
import OpenClawProtocol
@testable import SmartChatApp

/// Regression for the user-reported post-PR-#49 stream-time
/// symptoms (logged 2026-07-02):
///
/// 1. `toolResult` bubbles appeared with `startedAt: nil` even
///    though the tool definitely started before the result
///    arrived. The bubble's footer showed only the end time.
///
/// 2. `toolCall` / `toolResult` / `assistant` bubbles appeared
///    duplicated during a single stream — one user-visible bubble
///    per logical event was the contract.
///
/// Both symptoms trace back to the same architectural hole:
/// `EventInterpreter` runs TWO parallel paths for tool events
/// (the legacy `stream: "tool"` and the modern `stream: "item"`
/// + `stream: "command_output"`). Both paths assume the
/// `toolCallId` they read from the server is the SAME identifier
/// used by the other path. When the server emits legacy + modern
/// events for the same logical tool with DIFFERENT toolCallIds,
/// the two paths write to different `id` namespaces (e.g.
/// `<runId>:toolResult:<legacyId>` vs `<runId>:toolResult:<modernId>`)
/// and the upsert can no longer collapse them into one bubble.
/// When the server uses the SAME toolCallId across both paths,
/// the legacy path's `toolStartedAtByCall.removeValue` clears the
/// entry before the modern path reads it, dropping startedAt to
/// nil.
///
/// These tests pin both failure modes so a future change to the
/// event handler can't regress either of them silently.
@MainActor
final class EventInterpreterLegacyModernToolRaceTests: XCTestCase {
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

    // MARK: - Bug #1: toolResult startedAt missing when legacy + modern race

    /// When the server emits both the legacy `tool phase=start` /
    /// `tool phase=result` AND the modern `item phase=start` /
    /// `command_output phase=end` for the SAME logical tool
    /// (sharing the same `toolCallId`), the modern toolResult
    /// ChatMessage must still carry `startedAt` from the recorded
    /// start. The legacy path's `toolStartedAtByCall.removeValue`
    /// cleanup happens INSIDE the legacy handler — without a fix,
    /// it fires before the modern `command_output (end)` reads
    /// the entry, dropping startedAt to nil on the modern
    /// toolResult (which is the bubble that survives, since it
    /// arrives last and replaces by id).
    func test_legacyAndModernShareToolCallId_modernToolResultCarriesStartedAt() async throws {
        let runId = "r-race-share"
        // Issue #34 strict gate: register the runId with the test session
        // (mirrors the chat-event path that production uses to populate the runId → sessionKey map)
        vm.recordRunSession("session-1", for: runId, overwriteIfExisting: true)
        let sharedId = "tc_shared_1"
        let t0: Int = 1_000

        // Lifecycle start.
        await interpreter.handleTransportEvent(
            .agent(makeAgentEvent(
                runId: runId, seq: 1, stream: "lifecycle", ts: t0,
                data: ["phase": AnyCodable("start"),
                       "startedAt": AnyCodable(Double(t0))])),
            sessionKey: "session-1")

        // 1. Modern item phase=start sets toolStartedAtByCall
        //    for (runId, sharedId).
        await sendItemStart(
            runId: runId, ts: t0 + 100, canonical: sharedId,
            toolCallId: sharedId, kind: "tool")

        // 2. Legacy tool phase=start OVERWRITES the same
        //    toolStartedAtByCall entry with the legacy ts (close
        //    enough — both should produce a non-nil startedAt).
        await sendLegacyToolStart(
            runId: runId, ts: t0 + 110, toolCallId: sharedId)

        // 3. Legacy tool phase=result — reads toolStartedAt,
        //    writes toolResult bubble, CLEARS toolStartedAt.
        //    (This is the line that drops the entry before the
        //    modern path reads it.)
        await sendLegacyToolResult(
            runId: runId, ts: t0 + 200, toolCallId: sharedId,
            resultText: "legacy result body")

        // 4. Modern command_output phase=end — reads
        //    toolStartedAt (NOW NIL because of step 3's cleanup).
        //    Without a fix, this writes a toolResult with
        //    startedAt: nil, which the upsert then makes the
        //    visible bubble's value.
        await sendCommandOutput(
            runId: runId, ts: t0 + 300, canonical: sharedId,
            toolCallId: sharedId, phase: "end",
            output: "modern result body")

        let toolResults = vm.chatMessages(for: "session-1")
            .filter { $0.role == "toolResult" }
        XCTAssertEqual(toolResults.count, 1,
            "Expected exactly one toolResult bubble for one logical tool call — got \(toolResults.count)")
        XCTAssertNotNil(toolResults.first?.startedAt,
            "toolResult.startedAt must NOT be nil even when the legacy tool-result handler clears toolStartedAtByCall before the modern command_output (end) reads it. text=\(String(toolResults.first?.text.prefix(40) ?? ""))")
    }

    // MARK: - Bug #2: duplicate bubbles when legacy + modern use different toolCallIds

    /// When the server emits the legacy `tool phase=result` AND
    /// the modern `command_output phase=end` for the same logical
    /// tool but with DIFFERENT toolCallIds, the two paths write
    /// to different `<runId>:toolResult:<...>` ids. The upsert
    /// can't collapse them, so the user sees two toolResult
    /// bubbles for one tool call.
    ///
    /// The right resolution is for the legacy toolCallId to be
    /// aliased to the modern canonical id (or vice versa) — or
    /// for content-dedup at the storage layer to drop one. The
    /// current implementation relies on the server guaranteeing
    /// shared ids; when that contract breaks, content-dedup at
    /// the cache layer is the last line of defense.
    func test_legacyAndModernDifferInToolCallId_onlyOneToolResultBubble() async throws {
        let runId = "r-race-diff"
        // Issue #34 strict gate: register the runId with the test session
        // (mirrors the chat-event path that production uses to populate the runId → sessionKey map)
        vm.recordRunSession("session-1", for: runId, overwriteIfExisting: true)
        let modernId = "tc_modern_1"
        let legacyId = "tc_legacy_1"
        let t0: Int = 2_000

        await interpreter.handleTransportEvent(
            .agent(makeAgentEvent(
                runId: runId, seq: 1, stream: "lifecycle", ts: t0,
                data: ["phase": AnyCodable("start"),
                       "startedAt": AnyCodable(Double(t0))])),
            sessionKey: "session-1")

        // Modern path starts.
        await sendItemStart(
            runId: runId, ts: t0 + 100, canonical: modernId,
            toolCallId: modernId, kind: "tool")

        // Legacy path starts (DIFFERENT toolCallId).
        await sendLegacyToolStart(
            runId: runId, ts: t0 + 110, toolCallId: legacyId)

        // Both paths produce a result with the SAME content
        // (the same logical tool's output, surfaced through
        // both transports).
        let sharedResultText = "shared tool output body"
        await sendLegacyToolResult(
            runId: runId, ts: t0 + 200, toolCallId: legacyId,
            resultText: sharedResultText)
        await sendCommandOutput(
            runId: runId, ts: t0 + 300, canonical: modernId,
            toolCallId: modernId, phase: "end",
            output: sharedResultText)

        let toolResults = vm.chatMessages(for: "session-1")
            .filter { $0.role == "toolResult" }
        XCTAssertEqual(toolResults.count, 1,
            "Different legacy/modern toolCallIds must NOT produce two toolResult bubbles for one logical tool — got \(toolResults.count). text=\(toolResults.map { String($0.text.prefix(20)) })")
    }

    // MARK: - Bug #2 mirror: assistant + toolCall duplicate surface

    /// When the modern path's `item phase=start` (kind=tool) and
    /// the legacy path's `tool phase=start` fire for the same
    /// logical call with different toolCallIds, two toolCall
    /// bubbles appear. The user's screenshot showed this as
    /// "toolCall duplicates".
    func test_legacyAndModernDifferInToolCallId_onlyOneToolCallBubble() async throws {
        let runId = "r-race-tc"
        // Issue #34 strict gate: register the runId with the test session
        // (mirrors the chat-event path that production uses to populate the runId → sessionKey map)
        vm.recordRunSession("session-1", for: runId, overwriteIfExisting: true)
        let modernId = "tc_modern_tc"
        let legacyId = "tc_legacy_tc"
        let t0: Int = 3_000

        await interpreter.handleTransportEvent(
            .agent(makeAgentEvent(
                runId: runId, seq: 1, stream: "lifecycle", ts: t0,
                data: ["phase": AnyCodable("start"),
                       "startedAt": AnyCodable(Double(t0))])),
            sessionKey: "session-1")

        await sendItemStart(
            runId: runId, ts: t0 + 100, canonical: modernId,
            toolCallId: modernId, kind: "tool")
        await sendLegacyToolStart(
            runId: runId, ts: t0 + 110, toolCallId: legacyId)

        let toolCalls = vm.chatMessages(for: "session-1")
            .filter { $0.role == "toolCall" }
        XCTAssertEqual(toolCalls.count, 1,
            "Different legacy/modern toolCallIds must NOT produce two toolCall bubbles for one logical tool — got \(toolCalls.count)")
    }

    // MARK: - Event builders

    private func sendItemStart(runId: String, ts: Int, canonical: String,
                               toolCallId: String, kind: String) async {
        await interpreter.handleTransportEvent(
            .agent(makeAgentEvent(
                runId: runId, seq: 1, stream: "item", ts: ts,
                data: [
                    "itemId": AnyCodable(canonical),
                    "toolCallId": AnyCodable(toolCallId),
                    "kind": AnyCodable(kind),
                    "name": AnyCodable("exec"),
                    "phase": AnyCodable("start"),
                ])),
            sessionKey: "session-1")
    }

    private func sendCommandOutput(runId: String, ts: Int, canonical: String,
                                   toolCallId: String, phase: String,
                                   output: String) async {
        await interpreter.handleTransportEvent(
            .agent(makeAgentEvent(
                runId: runId, seq: 1, stream: "command_output", ts: ts,
                data: [
                    "itemId": AnyCodable(canonical),
                    "toolCallId": AnyCodable(toolCallId),
                    "name": AnyCodable("exec"),
                    "phase": AnyCodable(phase),
                    "output": AnyCodable(output),
                ])),
            sessionKey: "session-1")
    }

    private func sendLegacyToolStart(runId: String, ts: Int,
                                     toolCallId: String) async {
        await interpreter.handleTransportEvent(
            .agent(makeAgentEvent(
                runId: runId, seq: 1, stream: "tool", ts: ts,
                data: [
                    "toolCallId": AnyCodable(toolCallId),
                    "name": AnyCodable("exec"),
                    "phase": AnyCodable("start"),
                ])),
            sessionKey: "session-1")
    }

    private func sendLegacyToolResult(runId: String, ts: Int,
                                      toolCallId: String,
                                      resultText: String) async {
        await interpreter.handleTransportEvent(
            .agent(makeAgentEvent(
                runId: runId, seq: 1, stream: "tool", ts: ts,
                data: [
                    "toolCallId": AnyCodable(toolCallId),
                    "name": AnyCodable("exec"),
                    "phase": AnyCodable("result"),
                    "result": AnyCodable(resultText),
                ])),
            sessionKey: "session-1")
    }

    private func makeTestSession() -> OpenClawChatSessionEntry {
        OpenClawChatSessionEntry(
            key: "session-1", kind: "test",
            displayName: "Test Session",
            surface: nil, subject: nil, room: nil, space: nil,
            updatedAt: nil, sessionId: nil, systemSent: nil,
            abortedLastRun: nil, thinkingLevel: nil, verboseLevel: nil,
            inputTokens: nil, outputTokens: nil, totalTokens: nil,
            modelProvider: nil, model: nil, contextTokens: nil,
            thinkingLevels: nil, thinkingOptions: nil, thinkingDefault: nil)
    }

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
}