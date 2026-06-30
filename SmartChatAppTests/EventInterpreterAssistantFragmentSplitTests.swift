import XCTest
import OpenClawChatUI
import OpenClawProtocol
@testable import SmartChatApp

/// Regression for the user-reported EFB69836 weather run on
/// 2026-06-29: when the LLM emits text between tool invocations
/// ("thinking aloud"), each tool boundary should finalize the prior
/// text as its own assistant bubble rather than letting the
/// LCP-12 partial-overlap rewrite stitch the prior fragment's tail
/// onto the new fragment's head — the symptom on the device was one
/// large bubble containing all four segments concatenated with
/// Frankenstein prefixes ("Saturday is **July 4**. Let me get that
/// specific day.Found it. From the 15-day forecast data:...").
///
/// The fix: each `item phase=start` event finalizes the previously
/// accumulated assistant text into a `state=final` bubble keyed by
/// `<runId>:assistant:<N>`, then increments N so the next fragment
/// writes to a different id slot. With four events of interest
/// (preamble + three thinking segments + response), the test asserts
/// one bubble per segment.
@MainActor
final class EventInterpreterAssistantFragmentSplitTests: XCTestCase {
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

    /// Send the same sequence the EFB69836 weather run produced —
    /// four assistant text segments separated by tool boundaries —
    /// and assert four assistant bubbles come out, each with the
    /// expected text. The current implementation keys bubble ids on
    /// `<runId>:assistant:<N>`, so the deterministic-UUID converter
    /// keeps each fragment as a separate cache entry.
    func test_fourFragmentsBetweenToolBoundaries_eachIsItsOwnBubble() async throws {
        let runId = "r-frag-1"
        let canonicalA = "tc-A"
        let canonicalB = "tc-B"
        let canonicalC = "tc-C"
        // Timestamps are hand-picked small ints so the test reads
        // deterministically (the store sorts ascending; we only assert
        // assistant text equality, not exact ordering).
        let t0: Int = 100  // lifecycle start
        let t1: Int = 200  // assistant delta #1 — pre-tool
        let t2: Int = 300  // item phase=start (tool A) — finalizes #1
        let t3: Int = 400  // assistant delta #2 — inter-tool
        let t4: Int = 500  // item phase=start (tool B) — finalizes #2
        let t5: Int = 600  // assistant delta #3 — inter-tool
        let t6: Int = 700  // item phase=start (tool C) — finalizes #3
        let t7: Int = 800  // assistant delta #4 — response
        let t8: Int = 900  // lifecycle end — finalizes #4

        // Lifecycle start.
        await interpreter.handleTransportEvent(
            .agent(makeAgentEvent(
                runId: runId, seq: 1, stream: "lifecycle", ts: t0,
                data: ["phase": AnyCodable("start"),
                       "startedAt": AnyCodable(Double(t0))])),
            sessionKey: "session-1")

        // Fragment 1 — pre-tool preamble.
        await interpreter.handleTransportEvent(
            .agent(makeAssistantDelta(
                runId: runId, seq: 2, ts: t1,
                text: "preamble thinking")),
            sessionKey: "session-1")
        // The streaming bubble is at id `<runId>:assistant:0` —
        // a different UUID than the lifecycle=start placeholder
        // (also `<runId>:assistant:0`) wait — both same id, so
        // upsert merges onto the placeholder slot. The text
        // round-trips through the SDK and comes back via
        // `content.first.text`. We expect ONE assistant bubble
        // carrying the streaming delta's text.
        XCTAssertEqual(
            storedAssistantCount(), 1,
            "Pre-tool fragment should be one streaming bubble (assistant:0) before the first item phase=start")
        XCTAssertEqual(
            storedAssistantTexts(), ["preamble thinking"])

        // Tool A — its start fires `finalizeAssistantFragmentIfAny`,
        // which stamps fragment 1 with state=final on the SAME id.
        await interpreter.handleTransportEvent(
            .agent(makeItemEvent(
                runId: runId, ts: t2, canonical: canonicalA,
                phase: "start")),
            sessionKey: "session-1")
        XCTAssertEqual(
            storedAssistantCount(), 1,
            "After tool A starts, fragment 1 should still be 1 bubble (finalize upserts onto the same id)")

        // Fragment 2 — between tools. The streaming delta creates
        // a NEW bubble at id `<runId>:assistant:1` (different UUID
        // because the suffix changed), so the count grows.
        await interpreter.handleTransportEvent(
            .agent(makeAssistantDelta(
                runId: runId, seq: 3, ts: t3,
                text: "thinking between tools")),
            sessionKey: "session-1")
        XCTAssertEqual(
            storedAssistantCount(), 2,
            "Fragment 2 is a NEW bubble (id assistant:1) — count should grow to 2")

        // Tool B — fragment 2 finalizes onto assistant:1.
        await interpreter.handleTransportEvent(
            .agent(makeItemEvent(
                runId: runId, ts: t4, canonical: canonicalB,
                phase: "start")),
            sessionKey: "session-1")
        XCTAssertEqual(
            storedAssistantCount(), 2,
            "Tool B start fires finalize → fragment 2 marks state=final on its existing id (count stays at 2)")

        // Fragment 3 — inter-tool again.
        await interpreter.handleTransportEvent(
            .agent(makeAssistantDelta(
                runId: runId, seq: 4, ts: t5,
                text: "another model thought")),
            sessionKey: "session-1")
        XCTAssertEqual(
            storedAssistantCount(), 3,
            "Fragment 3 is yet another bubble (assistant:2)")

        // Tool C — fragment 3 finalizes.
        await interpreter.handleTransportEvent(
            .agent(makeItemEvent(
                runId: runId, ts: t6, canonical: canonicalC,
                phase: "start")),
            sessionKey: "session-1")
        XCTAssertEqual(
            storedAssistantCount(), 3,
            "Tool C start fires finalize, count stays at 3")

        // Fragment 4 — the final response.
        await interpreter.handleTransportEvent(
            .agent(makeAssistantDelta(
                runId: runId, seq: 5, ts: t7,
                text: "the actual answer")),
            sessionKey: "session-1")
        XCTAssertEqual(
            storedAssistantCount(), 4,
            "Fragment 4 creates assistant:3 (the response bubble)")

        // Lifecycle end finalizes fragment 4 onto assistant:3.
        await interpreter.handleTransportEvent(
            .agent(makeLifecycleEnd(
                runId: runId, seq: 6, ts: t8)),
            sessionKey: "session-1")

        let finalTexts = storedAssistantTexts()
        XCTAssertEqual(
            finalTexts,
            ["preamble thinking",
             "thinking between tools",
             "another model thought",
             "the actual answer"],
            "Four assistant fragments should each carry its own text — no stitching across tool boundaries (Frankenstein regression guard)")
    }

    // MARK: - Bubble lookup helpers

    /// Read the assistant bubbles from the VM's `chatMessages(for:)`
    /// reader (which runs `applyStreamingMetadata` + `sortForDisplay`).
    /// The store's lower-level `messages(for:)` API sorts by
    /// persisted timestamp only — and lifecycle=end's
    /// `chosenAnchor` writes the run-start time as the response's
    /// timestamp, which would put the response fragment FIRST in a
    /// pure-timestamp sort. The view's per-run sort uses
    /// `seq ?? Int.max` first and `receivedAt ?? timestamp` for the
    /// tie-break; the `seq` propagation in `finalizeAssistantFragmentIfAny`
    /// is what makes the four fragments come out in 1→2→3→4 order.
    private func storedAssistantTexts() -> [String] {
        vm.chatMessages(for: "session-1")
            .filter { $0.role == "assistant" }
            .map(\.text)
    }

    private func storedAssistantCount() -> Int {
        storedAssistantTexts().count
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

    private func makeAssistantDelta(
        runId: String, seq: Int, ts: Int, text: String
    ) -> OpenClawAgentEventPayload {
        makeAgentEvent(
            runId: runId, seq: seq, stream: "assistant", ts: ts,
            data: ["text": AnyCodable(text)])
    }

    private func makeItemEvent(
        runId: String, ts: Int, canonical: String, phase: String
    ) -> OpenClawAgentEventPayload {
        makeAgentEvent(
            runId: runId, seq: 1, stream: "item", ts: ts,
            data: [
                "itemId": AnyCodable(canonical),
                "toolCallId": AnyCodable(canonical),
                "kind": AnyCodable("tool"),
                "name": AnyCodable("exec"),
                "phase": AnyCodable(phase),
            ])
    }

    private func makeLifecycleEnd(runId: String, seq: Int, ts: Int) -> OpenClawAgentEventPayload {
        makeAgentEvent(
            runId: runId, seq: seq, stream: "lifecycle", ts: ts,
            data: [
                "phase": AnyCodable("end"),
                "endedAt": AnyCodable(Double(ts)),
            ])
    }
}
