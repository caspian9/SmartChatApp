import XCTest
import OpenClawChatUI
@testable import SmartChatApp

/// Routing gate tests for issue #34 (strict-policy variant):
/// nested agent-run events whose runId doesn't belong to the
/// currently-selected session must not be upserted into the
/// user's view. The VM owns the runId → sessionKey map; only
/// the chat event's `chat.sessionKey` is authoritative
/// (overwriteIfExisting: true). Agent events alone do NOT
/// pre-claim the runId — they are buffered in
/// `pendingAgentBuffer` until a chat event confirms the
/// sessionKey (flush) or the timeout fallback fires
/// (assume selectedSession).
///
/// The `MessageReceiver.receiveMessage` gate consults
/// `viewModel.route(for:)` and either:
///   1. accepts (map hit matches selectedSession, OR runId is nil)
///   2. buffers (unmapped non-final runId)
///   3. rejects (map hit ≠ selectedSession, OR unmapped final)
@MainActor
final class MessageReceiverRoutingTests: XCTestCase {
    private var receiver: MessageReceiver!
    private var store: MessageCacheStore!
    private var fakeStorage: FakeMessageCacheStorage!
    private var vm: NativeChatViewModel!

    override func setUp() async throws {
        fakeStorage = FakeMessageCacheStorage()
        store = MessageCacheStore(storage: fakeStorage)
        vm = NativeChatViewModel(store: store)
        receiver = vm.messageReceiver
        vm.selectedSession = makeTestSession(key: "session-A")
        CollapseStateCache.shared.clear()
    }

    override func tearDown() async throws {
        CollapseStateCache.shared.clear()
        receiver = nil
        store = nil
        fakeStorage = nil
        vm = nil
    }

    // MARK: - route(for:) — pure VM map lookup

    func test_route_runIdNil_fallsThroughToSelectedSession() {
        // Messages with no runId (user-sent bubbles, slash-command
        // echoes, system bubbles) always route to the
        // currently-selected session regardless of map state.
        let target = vm.route(for: nil)
        XCTAssertEqual(target, "session-A")
    }

    func test_route_unmappedRunId_returnsNil_strictGate() {
        // Strict gate (replaces first-event-wins): an unmapped
        // runId must NOT be silently routed to the currently-
        // selected session. Doing so would leak nested agent
        // runs into the parent session's view. Instead, return
        // nil so `MessageReceiver` can buffer the message in
        // `pendingAgentBuffer` until a chat event confirms the
        // true sessionKey.
        let target = vm.route(for: "fresh-runId")
        XCTAssertNil(target,
                     "unmapped runId must return nil under strict gate; the receiver buffers instead of routing")
    }

    func test_route_mappedRunId_returnsMappedSession() {
        // After `recordRunSession(_, _, overwriteIfExisting: true)`,
        // the runId resolves to the SDK-provided session key —
        // even if the user has navigated away.
        vm.recordRunSession("session-B", for: "nested-runId", overwriteIfExisting: true)
        // User navigates to session-C; runId should still resolve to B.
        vm.selectedSession = makeTestSession(key: "session-C")
        XCTAssertEqual(vm.route(for: "nested-runId"), "session-B",
                       "mapped runId must return the mapped session regardless of current selection")
    }

    // MARK: - recordRunSession — first-event-wins for .agent, overwrite for .chat

    func test_recordRunSession_overwriteIfExistingTrue_overwrites() {
        // `.chat` events use overwriteIfExisting: true; they can
        // correct a wrong first-event-wins guess from an earlier `.agent`.
        vm.recordRunSession("session-A", for: "runId-1")
        vm.recordRunSession("session-C", for: "runId-1", overwriteIfExisting: true)
        XCTAssertEqual(vm.route(for: "runId-1"), "session-C",
                       "overwriteIfExisting: true must overwrite any prior mapping")
    }

    func test_recordRunSession_overwriteIfExistingFalse_isFirstEventWins() {
        // `.agent` events use overwriteIfExisting: false (default);
        // the FIRST recorded session wins; subsequent non-overwriting
        // writes are no-ops.
        vm.recordRunSession("session-A", for: "runId-1")
        vm.recordRunSession("session-D", for: "runId-1")  // ignored
        XCTAssertEqual(vm.route(for: "runId-1"), "session-A",
                       "non-overwriting write after the first must be a no-op")
    }

    // MARK: - clearMemory — drops entries for the cleared session

    func test_clearMemory_filtersMapBySession() {
        // Two runIds, one mapped to A, one to B. clearMemory(A)
        // must drop the A entry; the B entry stays.
        // (route(for:) falls through to selectedSession?.key for
        // unmapped runIds, so to verify the A entry is actually
        // dropped we set selectedSession to nil first — fallback
        // then resolves to nil, distinct from a successful lookup.)
        vm.recordRunSession("session-A", for: "runId-A")
        vm.recordRunSession("session-B", for: "runId-B", overwriteIfExisting: true)

        vm.clearMemory(for: "session-A")
        vm.selectedSession = nil

        XCTAssertNil(vm.route(for: "runId-A"),
                     "cleared session's runIds must no longer resolve (no selectedSession fallback)")
        XCTAssertEqual(vm.route(for: "runId-B"), "session-B",
                       "unrelated session's runIds must remain intact")
    }

    // MARK: - End-to-end: the gate rejects nested-run writes

    func test_gate_rejectsNestedRunMessage_doesNotUpsertStore() async {
        // Scenario from issue #34: user is in session-A, agent
        // starts a nested run on session-B. Simulate by
        // recording the runId → B mapping, then receiving a
        // message with that runId while selectedSession is A.
        vm.recordRunSession("session-B", for: "nested-runId", overwriteIfExisting: true)

        let msg = ChatMessage(
            id: "nested-runId", text: "I'm the nested reply",
            timestamp: Date(),
            role: "assistant", state: "final", runId: "nested-runId", seq: 1,
            startedAt: Date(), endedAt: Date(),
            livenessState: nil,
            inputTokens: nil, outputTokens: nil, cacheRead: nil, cacheWrite: nil,
            toolCallId: nil, toolName: nil, stopReason: nil)

        await receiver.receiveMessage(msg)

        // session-A's store must NOT contain the nested reply.
        let aMessages = store.messages(for: "session-A", since: nil)
        XCTAssertTrue(aMessages.isEmpty,
                      "session-A's store must not contain the nested reply (issue #34 root cause)")

        // session-B's store is also empty — the gate rejected
        // the write entirely (we don't write to the nested
        // session's store from the receiver; that would require
        // a separate path). The user will see the nested run's
        // output when they navigate to B and refresh from the
        // server.
        let bMessages = store.messages(for: "session-B", since: nil)
        XCTAssertTrue(bMessages.isEmpty,
                      "gate rejects; nested session's store is not auto-populated from a parent-session event")
    }

    func test_gate_acceptsOwnRunMessage_upsertsStore() async {
        // Sanity check the gate doesn't over-reject: a message
        // whose runId maps to the currently-selected session
        // must pass through to the store.
        vm.recordRunSession("session-A", for: "own-runId")

        let msg = ChatMessage(
            id: "own-runId", text: "own reply",
            timestamp: Date(),
            role: "assistant", state: "final", runId: "own-runId", seq: 1,
            startedAt: Date(), endedAt: Date(),
            livenessState: nil,
            inputTokens: nil, outputTokens: nil, cacheRead: nil, cacheWrite: nil,
            toolCallId: nil, toolName: nil, stopReason: nil)

        await receiver.receiveMessage(msg)

        let aMessages = store.messages(for: "session-A", since: nil)
        XCTAssertEqual(aMessages.count, 1, "matching runId must upsert into the store")
        XCTAssertEqual(aMessages.first?.content.first?.text, "own reply")
    }

    func test_gate_acceptsRunIdNilMessage_upsertsStore() async {
        // runId == nil bubbles (user-sent, slash-command echoes)
        // are always local-to-session — the gate must not
        // reject them.
        let userMsg = ChatMessage(
            id: "user-msg-1", text: "hello",
            timestamp: Date(),
            role: "user", state: "final", runId: nil, seq: nil,
            startedAt: nil, endedAt: nil,
            livenessState: nil,
            inputTokens: nil, outputTokens: nil, cacheRead: nil, cacheWrite: nil,
            toolCallId: nil, toolName: nil, stopReason: nil)

        await receiver.receiveMessage(userMsg)

        let messages = store.messages(for: "session-A", since: nil)
        XCTAssertEqual(messages.count, 1, "runId=nil messages must be accepted")
    }

    // MARK: - Pending buffer (strict gate)

    func test_gate_unmappedNonFinalMessage_isBufferedNotUpserted() async {
        // Strict gate: an agent event for an unmapped runId must
        // NOT be written to the cache. It's buffered in
        // `pendingAgentBuffer` until a chat event confirms the
        // sessionKey. This is the leak fix — pre-fix code would
        // auto-claim the runId for the selected session and write
        // the bubble to the wrong cache.
        let streamingMsg = ChatMessage(
            id: "stream-1", text: "ha",
            timestamp: Date(),
            role: "assistant", state: "streaming",
            runId: "fresh-runId", seq: 1,
            startedAt: Date(), endedAt: nil,
            livenessState: nil,
            inputTokens: nil, outputTokens: nil, cacheRead: nil, cacheWrite: nil,
            toolCallId: nil, toolName: nil, stopReason: nil)

        await receiver.receiveMessage(streamingMsg)

        // Cache MUST be empty — strict gate rejected the write.
        let aMessages = store.messages(for: "session-A", since: nil)
        XCTAssertTrue(aMessages.isEmpty,
                      "unmapped runId streaming message must not leak into the selected session's cache")
    }

    func test_gate_unmappedFinalMessage_isRejectedNotBuffered() async {
        // Final messages from unconfirmed runs are rejected
        // outright (not buffered). Buffering a final message
        // would let it land in the cache once the chat event
        // arrives, but the streaming path's
        // `id = "<runId>:assistant:N"` namespace can collide
        // with the buffered final's id. The chat event will
        // bring its own complete message, and `chat.history`
        // will repopulate any historical run on the right
        // session anyway. Buffering non-final only is the safe
        // choice.
        let finalMsg = ChatMessage(
            id: "final-1", text: "complete",
            timestamp: Date(),
            role: "assistant", state: "final",
            runId: "fresh-runId", seq: 1,
            startedAt: Date(), endedAt: Date(),
            livenessState: nil,
            inputTokens: nil, outputTokens: nil, cacheRead: nil, cacheWrite: nil,
            toolCallId: nil, toolName: nil, stopReason: nil)

        await receiver.receiveMessage(finalMsg)

        let aMessages = store.messages(for: "session-A", since: nil)
        XCTAssertTrue(aMessages.isEmpty,
                      "unmapped runId final message must be rejected; chat.history is the source of truth")
    }

    func test_buffer_flush_routesBufferedMessagesToCorrectSession() async {
        // Simulate the protocol: agent event for an unmapped
        // runId arrives first (buffered). Then a chat event
        // arrives with `chat.sessionKey = B`, confirming the
        // run is for session B. The buffer must flush through
        // `receiveMessage` and the bubble must land in B's
        // cache (not A's, which the user is currently viewing).
        let streamingMsg = ChatMessage(
            id: "stream-1", text: "ha",
            timestamp: Date(),
            role: "assistant", state: "streaming",
            runId: "nested-runId", seq: 1,
            startedAt: Date(), endedAt: nil,
            livenessState: nil,
            inputTokens: nil, outputTokens: nil, cacheRead: nil, cacheWrite: nil,
            toolCallId: nil, toolName: nil, stopReason: nil)
        await receiver.receiveMessage(streamingMsg)

        // Simulate the chat event handler: record runId → B
        // and flush the buffer.
        vm.recordRunSession("session-B", for: "nested-runId", overwriteIfExisting: true)
        await vm.flushPending(for: "nested-runId")

        // User is still in A; the bubble for runId=nested-runId
        // must NOT land in A's cache. The MessageReceiver gate
        // rejects because route(for: nested-runId) = B ≠ A.
        let aMessages = store.messages(for: "session-A", since: nil)
        XCTAssertTrue(aMessages.isEmpty,
                      "buffered message flushed to wrong session: nested run bubbled into parent's view (issue #34 root cause)")

        // Switch to B; the message must now be visible.
        vm.selectedSession = makeTestSession(key: "session-B")
        let bMessages = store.messages(for: "session-B", since: nil)
        XCTAssertEqual(bMessages.count, 1, "buffered message must land in the confirmed session's cache")
    }

    func test_buffer_flush_routesOwnSessionRunAfterClaim() async {
        // Normal case: user in A sends a message. The agent
        // event arrives with a new runId (unmapped). Strict
        // gate buffers it. The chat event then arrives with
        // `chat.sessionKey = A`, recording runId → A and
        // flushing. The message must land in A's cache.
        let streamingMsg = ChatMessage(
            id: "stream-1", text: "ha",
            timestamp: Date(),
            role: "assistant", state: "streaming",
            runId: "own-runId", seq: 1,
            startedAt: Date(), endedAt: nil,
            livenessState: nil,
            inputTokens: nil, outputTokens: nil, cacheRead: nil, cacheWrite: nil,
            toolCallId: nil, toolName: nil, stopReason: nil)
        await receiver.receiveMessage(streamingMsg)

        // Before chat event: cache is empty (buffered).
        let beforeClaim = store.messages(for: "session-A", since: nil)
        XCTAssertTrue(beforeClaim.isEmpty, "before chat event claim, buffered message must not be in cache")

        // Chat event claims the runId for A and flushes.
        vm.recordRunSession("session-A", for: "own-runId", overwriteIfExisting: true)
        await vm.flushPending(for: "own-runId")

        let afterClaim = store.messages(for: "session-A", since: nil)
        XCTAssertEqual(afterClaim.count, 1, "after chat event claim, buffered message must land in the confirmed session's cache")
    }

    func test_buffer_dropPending_removesBufferEntry() async {
        // `dropPending(for:)` is called from `clearMemory(for:)`
        // so a stale buffer for a different session doesn't
        // re-route after the user navigates back. Verify the
        // buffer is cleared.
        let msg = ChatMessage(
            id: "stream-1", text: "ha",
            timestamp: Date(),
            role: "assistant", state: "streaming",
            runId: "drop-runId", seq: 1,
            startedAt: Date(), endedAt: nil,
            livenessState: nil,
            inputTokens: nil, outputTokens: nil, cacheRead: nil, cacheWrite: nil,
            toolCallId: nil, toolName: nil, stopReason: nil)
        await receiver.receiveMessage(msg)

        // Before drop: buffer holds the message; if we now
        // record a different session for the runId, the flush
        // would land the message in that session. After drop,
        // the flush is a no-op.
        vm.dropPending(for: "drop-runId")
        vm.recordRunSession("session-C", for: "drop-runId", overwriteIfExisting: true)
        await vm.flushPending(for: "drop-runId")

        let cMessages = store.messages(for: "session-C", since: nil)
        XCTAssertTrue(cMessages.isEmpty,
                      "dropPending must remove the buffer entry; subsequent flush is a no-op")
    }

    // MARK: - Helpers

    private func makeTestSession(key: String) -> OpenClawChatSessionEntry {
        OpenClawChatSessionEntry(
            key: key, kind: "test", displayName: "Test",
            surface: nil, subject: nil, room: nil, space: nil,
            updatedAt: nil, sessionId: nil, systemSent: nil,
            abortedLastRun: nil, thinkingLevel: nil, verboseLevel: nil,
            inputTokens: nil, outputTokens: nil, totalTokens: nil,
            modelProvider: nil, model: nil, contextTokens: nil,
            thinkingLevels: nil, thinkingOptions: nil, thinkingDefault: nil)
    }
}