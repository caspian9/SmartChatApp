import XCTest
import OpenClawChatUI
@testable import SmartChatApp

/// G4 (audit 2026-07-07): regression coverage for
/// `sortForDisplay`. The 2026-07-06 sort regression was that
/// the chat event (carrying the final thinking block) often
/// arrived AFTER `lifecycle=end` (carrying the assistant
/// final) on the wire, so a pure timestamp sort rendered
/// `response → thinking`. The fix introduced
/// `endedAt`-priority within a single runId.
///
/// Addendum (audit 2026-07-07): the `endedAt`-priority
/// branch was originally dead code because the store
/// round-trip (`ChatMessage → OpenClawChatMessage →
/// ChatMessage`) drops `runId`. The follow-up P1 fix
/// extended `StreamingMetadata` with `runId` and overlays
/// it in `applyStreamingMetadata` — so this file's
/// `test_sortForDisplay_endedAtWinsOverSeqWithinRun`
/// can now verify the priority path. The pre-fix
/// behavior (cross-run fallback to `receivedAt`) is also
/// tested by the second test as a regression guard.
@MainActor
final class NativeChatViewModelSortTests: XCTestCase {
    private var vm: NativeChatViewModel!
    private var store: MessageCacheStore!
    private var fakeStorage: FakeMessageCacheStorage!

    override func setUp() async throws {
        fakeStorage = FakeMessageCacheStorage()
        store = MessageCacheStore(storage: fakeStorage)
        vm = NativeChatViewModel(store: store)
        vm.selectedSession = makeTestSession()
        CollapseStateCache.shared.clear()
    }

    override func tearDown() async throws {
        CollapseStateCache.shared.clear()
        vm = nil
        store = nil
        fakeStorage = nil
    }

    // MARK: - endedAt-priority (now working)

    /// Within a single run, an entry with an earlier
    /// `endedAt` sorts BEFORE an entry with a later
    /// `endedAt`, even when the seq values would suggest
    /// the opposite order. This is the core G4 contract.
    ///
    /// Wire-order: assistant text arrives FIRST (seq=1),
    /// then the tool result (seq=2), then the FINAL
    /// thinking block (seq=3). The correct display order
    /// is by server-side end-time (endedAt ASC):
    ///   toolResult (endedAt=t1) → thinking (endedAt=t2) → assistant (endedAt=t3)
    /// The seq values 1,2,3 are the REVERSE of endedAt
    /// order for at least one pair (seq=2 → endedAt=t1,
    /// seq=1 → endedAt=t3). Without the endedAt-priority
    /// fix + runId preservation overlay, the sort would
    /// fall through to receivedAt and produce the wire
    /// order [assistant, toolResult, thinking] instead.
    func test_sortForDisplay_endedAtWinsOverSeqWithinRun() async throws {
        let runId = "r-sort-endedAt"
        let baseTs: Double = 1_783_000_000_000

        // Send the assistant final FIRST (wire seq=1)
        // but its endedAt is the LATEST in the run.
        await sendChatMessage(
            runId: runId,
            id: "\(runId):assistant:0",
            text: "assistant-final",
            timestamp: Date(timeIntervalSince1970: baseTs / 1000),
            role: "assistant",
            state: "final",
            seq: 1,
            startedAt: Date(timeIntervalSince1970: baseTs / 1000),
            endedAt: Date(timeIntervalSince1970: (baseTs + 3_000) / 1000))

        // Send the toolResult SECOND (wire seq=2)
        // but its endedAt is EARLIER.
        await sendChatMessage(
            runId: runId,
            id: "\(runId):toolResult:abc",
            text: "tool-result-body",
            timestamp: Date(timeIntervalSince1970: baseTs / 1000),
            role: "toolResult",
            state: "final",
            seq: 2,
            startedAt: Date(timeIntervalSince1970: baseTs / 1000),
            endedAt: Date(timeIntervalSince1970: (baseTs + 1_000) / 1000))

        // Send the thinking LAST (wire seq=3) but
        // its endedAt is BETWEEN the other two.
        await sendChatMessage(
            runId: runId,
            id: "\(runId):thinking",
            text: "reasoning chain",
            timestamp: Date(timeIntervalSince1970: baseTs / 1000),
            role: "thinking",
            state: "final",
            seq: 3,
            startedAt: nil,
            endedAt: Date(timeIntervalSince1970: (baseTs + 2_000) / 1000))

        let rendered = vm.chatMessages(for: "session-1")
        let renderedRoles = rendered.map(\.role)
        // Expected order by endedAt ascending:
        //   toolResult (t1) → thinking (t2) → assistant (t3)
        XCTAssertEqual(renderedRoles, ["toolResult", "thinking", "assistant"],
            "G4: sortForDisplay must use endedAt (not seq) within a run. " +
            "Expected [toolResult, thinking, assistant] by endedAt ascending, got \(renderedRoles). " +
            "Without the runId-preservation overlay + endedAt-priority fix, the wire-order seq would " +
            "produce [assistant, toolResult, thinking].")
    }

    // MARK: - Cross-run fallback (the path that runs for persisted history)

    /// When two entries have DIFFERENT effective runIds,
    /// sortForDisplay falls through to the cross-run
    /// branch which uses `receivedAt` (the wall-clock of
    /// the most recent `receiveMessage` call for that id).
    /// Earlier `receivedAt` → sorts first.
    ///
    /// This is the path that runs for persisted history
    /// entries that never went through the streaming
    /// receiveMessage path.
    func test_sortForDisplay_crossRunFallback_usesReceivedAt() async throws {
        // Two bubbles from DIFFERENT runs with NO
        // `endedAt` (both nil). After the cross-run
        // fallback's `endedAt ?? receivedAt ?? timestamp`
        // hierarchy (FIX-9 follow-up #2 in
        // `NativeChatViewModel`), both fall through to
        // `receivedAt` — the wall-clock arrival time at
        // the client. The test verifies the
        // `receivedAt` fallback works when `endedAt` is
        // unavailable (e.g., for user messages, for
        // thinking bubbles, or for historical entries
        // that never went through the streaming path).
        //
        // (Pre-FIX-9-follow-up-#2, the cross-run fallback
        // was `receivedAt ?? timestamp` — strictly
        // receivedAt. The test originally set non-nil
        // `endedAt` values to verify that endedAt does
        // NOT apply across different runIds. After the
        // fix, endedAt IS applied across different runIds
        // (it's server event time, runId-independent), so
        // the test must use nil endedAt to exercise the
        // receivedAt fallback path.)
        let now = Date()
        await sendChatMessage(
            runId: "run-X",
            id: "run-X:toolResult:abc",
            text: "X-result",
            timestamp: now,
            role: "toolResult",
            state: "final",
            seq: 1,
            startedAt: now,
            endedAt: nil)
        // Sleep 5ms so receivedAt is strictly increasing.
        try await Task.sleep(nanoseconds: 5_000_000)
        await sendChatMessage(
            runId: "run-Y",
            id: "run-Y:toolResult:def",
            text: "Y-result",
            timestamp: now,
            role: "toolResult",
            state: "final",
            seq: 1,
            startedAt: now,
            endedAt: nil)

        let rendered = vm.chatMessages(for: "session-1")
            .filter { $0.role == "toolResult" }
        let renderedTexts = rendered.map(\.text)
        // receivedAt ascending → X first (earlier arrival),
        // Y second (later arrival). Both have nil
        // endedAt, so the sort falls through to
        // receivedAt. (Pre-FIX-9-follow-up-#2 the
        // assertion was about endedAt not being used
        // across different runIds; after the fix, endedAt
        // IS used across different runIds, so the test
        // asserts on the receivedAt fallback instead.)
        XCTAssertEqual(renderedTexts, ["X-result", "Y-result"],
            "G4: cross-run fallback uses receivedAt (wall-clock arrival) " +
            "when endedAt is unavailable. Got \(renderedTexts) instead of " +
            "[X-result, Y-result].")
    }

    // MARK: - Persisted history without streaming overlay

    /// Persisted entries without any streaming overlay
    /// (e.g., server-history entries that never went
    /// through `receiveMessage`) must sort by their
    /// `timestamp` field — the cross-run fallback when
    /// `receivedAt` is unavailable. This is the typical
    /// case for a user who opens a session that was
    /// never streamed in this launch.
    func test_sortForDisplay_persistedEntriesWithoutOverlay_usesTimestamp() async throws {
        // Bypass the streaming path entirely. Inject
        // raw OpenClawChatMessages directly into the
        // store. These entries have no metadata overlay
        // (receivedAt is nil), so the sort falls back
        // to `timestamp`.
        let now = Date()
        let earlier = OpenClawChatMessage(
            id: UUID(), role: "user",
            content: [OpenClawChatMessageContent(
                type: "text", text: "earlier user msg",
                thinking: nil, thinkingSignature: nil, mimeType: nil,
                fileName: nil, content: nil, id: nil, name: nil,
                arguments: nil)],
            timestamp: now.addingTimeInterval(-3600).timeIntervalSince1970 * 1000,
            toolCallId: nil, toolName: nil,
            usage: nil, stopReason: nil, errorMessage: nil)
        let later = OpenClawChatMessage(
            id: UUID(), role: "assistant",
            content: [OpenClawChatMessageContent(
                type: "text", text: "later assistant msg",
                thinking: nil, thinkingSignature: nil, mimeType: nil,
                fileName: nil, content: nil, id: nil, name: nil,
                arguments: nil)],
            timestamp: now.timeIntervalSince1970 * 1000,
            toolCallId: nil, toolName: nil,
            usage: nil, stopReason: nil, errorMessage: nil)
        await store.append([earlier, later], for: "session-1")

        let rendered = vm.chatMessages(for: "session-1")
        let texts = rendered.map(\.text)
        XCTAssertEqual(texts, ["earlier user msg", "later assistant msg"],
            "G4: persisted entries without metadata overlay must sort by `timestamp`. " +
            "Got \(texts) instead of [earlier, later]. " +
            "This pins the historical-load ordering.")
    }

    // MARK: - Paired toolCall / toolResult (FIX-9 follow-up, 2026-07-08)

    /// When a toolCall and toolResult share the same
    /// `toolCallId`, the toolCall must sort BEFORE the
    /// toolResult regardless of the underlying timestamp
    /// order. This is a structural semantic (call → result
    /// pairing) and not a heuristic — even if the gateway
    /// emits the `command_output (end)` BEFORE the
    /// `item phase=start` (server out-of-order, or client
    /// processing out-of-order), the user must see the call
    /// above the result, never below.
    ///
    /// Without this fix, the cross-run fallback sorts by
    /// `receivedAt ?? timestamp`. If toolResult's ts (or
    /// receivedAt) is EARLIER than toolCall's, the sort
    /// puts toolResult first — the user-reported
    /// 2026-07-08 regression (CACHE[22] toolCall ts=873980,
    /// CACHE[24] toolResult ts=874812 → sort puts toolCall
    /// before toolResult is CORRECT, but in the reverse
    /// case the user saw toolResult above toolCall).
    func test_sortForDisplay_pairedToolCallToolResult_sameId_callFirst() async throws {
        // Simulate the user-reported case where the
        // toolResult lands with an EARLIER timestamp than
        // the toolCall (server emitted command_output
        // before item phase=start, or the client
        // processed them out of order). Without the
        // tie-breaker, the sort would put toolResult
        // FIRST.
        let now = Date()
        let toolCallTs = now.addingTimeInterval(5).timeIntervalSince1970 * 1000  // 5s later
        let toolResultTs = now.timeIntervalSince1970 * 1000                     // now (earlier)
        let toolCallId = "tc-1"
        let toolCallMsg = OpenClawChatMessage(
            id: UUID(), role: "toolCall",
            content: [OpenClawChatMessageContent(
                type: "text", text: "ToolCall: exec",
                thinking: nil, thinkingSignature: nil, mimeType: nil,
                fileName: nil, content: nil, id: nil, name: nil,
                arguments: nil)],
            timestamp: toolCallTs,
            toolCallId: toolCallId, toolName: "exec",
            usage: nil, stopReason: nil, errorMessage: nil)
        let toolResultMsg = OpenClawChatMessage(
            id: UUID(), role: "toolResult",
            content: [OpenClawChatMessageContent(
                type: "text", text: "result body",
                thinking: nil, thinkingSignature: nil, mimeType: nil,
                fileName: nil, content: nil, id: nil, name: nil,
                arguments: nil)],
            timestamp: toolResultTs,
            toolCallId: toolCallId, toolName: "exec",
            usage: nil, stopReason: nil, errorMessage: nil)
        await store.append([toolCallMsg, toolResultMsg], for: "session-1")
        let rendered = vm.chatMessages(for: "session-1")
        let renderedRoles = rendered.map(\.role)
        XCTAssertEqual(renderedRoles, ["toolCall", "toolResult"],
            "FIX-9 follow-up: toolCall and toolResult sharing the same toolCallId must sort as [call, result] regardless of timestamp order — got \(renderedRoles) instead of [toolCall, toolResult]. Without the structural tie-breaker, the toolResult's earlier ts would put it above the toolCall (the user-reported 2026-07-08 display regression).")
    }

    /// Negative case: two toolCalls with DIFFERENT
    /// toolCallIds must NOT force-call-first — they have
    /// no pair relationship, so the normal timestamp
    /// ordering wins. This pins that the tie-breaker is
    /// strictly scoped to a matching toolCallId pair.
    func test_sortForDisplay_unrelatedToolCalls_normalTimestampOrder() async throws {
        let now = Date()
        let tc1Ts = now.timeIntervalSince1970 * 1000
        let tc2Ts = now.addingTimeInterval(1).timeIntervalSince1970 * 1000
        let tc1 = OpenClawChatMessage(
            id: UUID(), role: "toolCall",
            content: [OpenClawChatMessageContent(
                type: "text", text: "call 1",
                thinking: nil, thinkingSignature: nil, mimeType: nil,
                fileName: nil, content: nil, id: nil, name: nil,
                arguments: nil)],
            timestamp: tc1Ts,
            toolCallId: "tc-1", toolName: "exec",
            usage: nil, stopReason: nil, errorMessage: nil)
        let tc2 = OpenClawChatMessage(
            id: UUID(), role: "toolCall",
            content: [OpenClawChatMessageContent(
                type: "text", text: "call 2",
                thinking: nil, thinkingSignature: nil, mimeType: nil,
                fileName: nil, content: nil, id: nil, name: nil,
                arguments: nil)],
            timestamp: tc2Ts,
            toolCallId: "tc-2", toolName: "exec",
            usage: nil, stopReason: nil, errorMessage: nil)
        await store.append([tc1, tc2], for: "session-1")
        let rendered = vm.chatMessages(for: "session-1")
        let texts = rendered.map(\.text)
        XCTAssertEqual(texts, ["call 1", "call 2"],
            "FIX-9 follow-up: unrelated toolCalls (different toolCallIds) must sort by timestamp, NOT by call-first tie-breaker — got \(texts) instead of [call 1, call 2].")
    }

    // MARK: - Server-event-time sort (FIX-9 follow-up #2, 2026-07-08)

    /// When two bubbles belong to the same logical turn (the
    /// assistant final is a response TO the tool result), their
    /// DISPLAY order must match the server event order, not
    /// the client arrival order. With P1 fix (runId
    /// preservation) STASHED, the sort falls to the cross-run
    /// branch, which used `receivedAt ?? timestamp`. If the
    /// gateway's `command_output (end)` arrives at the
    /// device AFTER the subsequent `lifecycle=end` (network
    /// jitter / gateway buffer flush), the toolResult's
    /// `receivedAt` is later than the assistant's, and the
    /// sort puts the toolResult BELOW the assistant — the
    /// user sees `toolCall → assistant → toolResult` instead
    /// of the correct `toolCall → toolResult → assistant`.
    ///
    /// The fix: promote `endedAt` to the primary cross-run
    /// key. `endedAt` is the server's `payload.endedAt` /
    /// `command_output (end)` / `lifecycle=end` timestamp —
    /// wire order is guaranteed (tool finishes before
    /// lifecycle ends), so this recovers the correct
    /// semantic order regardless of client arrival.
    ///
    /// Test setup simulates the exact 2026-07-08 device log
    /// shape: toolResult has `endedAt = T_re` (server ts
    /// BEFORE the assistant's), but `receivedAt = T_post` (
    /// client arrival AFTER the assistant's — simulating
    /// late delivery).
    func test_sortForDisplay_serverEventTimeOverridesReceivedAt_ordering() async throws {
        // Server event times: tool finishes BEFORE lifecycle
        // ends. This is the wire order guarantee.
        let toolResultServerEnd = Date(timeIntervalSince1970: 1_783_501_270.000)  // T_re
        let assistantServerEnd = Date(timeIntervalSince1970: 1_783_501_274.000)   // T_le (4s later)
        // Client arrival times: toolResult delivered AFTER
        // assistant final (simulating the network-jitter
        // case from the 2026-07-08 device log).
        let toolResultArrived = Date(timeIntervalSince1970: 1_783_501_280.000)    // T_post
        let assistantArrived = Date(timeIntervalSince1970: 1_783_501_275.000)     // T2 (5s earlier than toolResult arrival)
        // Simulate two separate streaming calls:
        // 1. toolResult (with command_output end's server ts
        //    as endedAt) — arrives LATE on the client
        // 2. assistant (with lifecycle=end's server ts as
        //    endedAt) — arrives EARLY on the client
        let key = "session-1"
        let toolResultMsg = OpenClawChatMessage(
            id: UUID(), role: "toolResult",
            content: [OpenClawChatMessageContent(
                type: "text", text: "tool output body",
                thinking: nil, thinkingSignature: nil, mimeType: nil,
                fileName: nil, content: nil, id: nil, name: nil,
                arguments: nil)],
            // Persisted timestamp: the local Date() at
            // arrival (later than the assistant's arrival).
            timestamp: toolResultArrived.timeIntervalSince1970 * 1000,
            toolCallId: nil, toolName: nil,
            usage: nil, stopReason: nil, errorMessage: nil)
        let assistantMsg = OpenClawChatMessage(
            id: UUID(), role: "assistant",
            content: [OpenClawChatMessageContent(
                type: "text", text: "final response",
                thinking: nil, thinkingSignature: nil, mimeType: nil,
                fileName: nil, content: nil, id: nil, name: nil,
                arguments: nil)],
            timestamp: assistantArrived.timeIntervalSince1970 * 1000,
            toolCallId: nil, toolName: nil,
            usage: nil, stopReason: nil, errorMessage: nil)
        await store.append([toolResultMsg, assistantMsg], for: key)
        // Simulate the streaming-time recordStreamingMetadata
        // by writing the server `endedAt` into the VM's
        // metadata overlay. Without this overlay, the sort
        // has no access to endedAt (it's not persisted on
        // OpenClawChatMessage — only the SDK-side fields
        // are). The test's assertion only depends on
        // endedAt ordering, not receivedAt, so we let
        // `recordStreamingMetadata` capture `Date()` for
        // receivedAt (the test still exercises the cross-
        // run branch because runId is nil for both
        // messages — P1 fix is stashed).
        await injectStreamingEndedAt(
            messageId: toolResultMsg.id.uuidString,
            endedAt: toolResultServerEnd)
        await injectStreamingEndedAt(
            messageId: assistantMsg.id.uuidString,
            endedAt: assistantServerEnd)
        let rendered = vm.chatMessages(for: key)
        let renderedRoles = rendered.map(\.role)
        XCTAssertEqual(renderedRoles, ["toolResult", "assistant"],
            "FIX-9 follow-up #2: server event time (endedAt) must win over client arrival time (receivedAt) — toolResult with earlier server endedAt must sort BEFORE assistant with later server endedAt, even though toolResult arrived at the client later. Got \(renderedRoles) instead of [toolResult, assistant]. Regression: pre-fix `receivedAt ?? timestamp` put the late-arriving toolResult below the assistant.")
    }

    // MARK: - Helpers

    /// Test seam: write a single `(id, endedAt)` entry into
    /// the VM's `streamingMetadataBySession` for the active
    /// session. Calls the production `recordStreamingMetadata`
    /// (which writes only the metadata overlay, NOT the
    /// store) with a synthetic ChatMessage carrying the
    /// desired `endedAt`. `receivedAt` is whatever
    /// `recordStreamingMetadata` captures (current `Date()`)
    /// — irrelevant for the test assertion, which depends
    /// on endedAt ordering.
    private func injectStreamingEndedAt(
        messageId: String,
        endedAt: Date
    ) async {
        let message = ChatMessage(
            id: messageId,
            text: "",
            timestamp: endedAt,
            role: "assistant",  // role doesn't matter for the overlay
            state: "final",
            runId: nil,
            seq: nil,
            startedAt: nil,
            endedAt: endedAt,
            livenessState: nil,
            toolCallId: nil,
            toolName: nil,
            stopReason: nil,
            isFresh: false)
        vm.recordStreamingMetadata(for: message)
    }

    private func sendChatMessage(
        runId: String,
        id: String,
        text: String,
        timestamp: Date,
        role: String,
        state: String,
        seq: Int?,
        startedAt: Date?,
        endedAt: Date?
    ) async {
        // Issue #34 strict gate: register the runId with the test
        // session (mirrors the chat-event path that production
        // uses to populate the runId → sessionKey map). The
        // selectedSession is "session-1" (set in setUp).
        vm.recordRunSession("session-1", for: runId, overwriteIfExisting: true)
        let message = ChatMessage(
            id: id,
            text: text,
            timestamp: timestamp,
            role: role,
            state: state,
            runId: runId,
            seq: seq,
            startedAt: startedAt,
            endedAt: endedAt,
            livenessState: nil,
            toolCallId: nil,
            toolName: nil,
            stopReason: nil,
            isFresh: false)
        await vm.receiveMessage(message)
    }

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
}