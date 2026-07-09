import XCTest
import OpenClawChatUI
@testable import SmartChatApp

/// Routing gate tests for issue #34: nested agent-run events
/// whose runId doesn't belong to the currently-selected session
/// must be rejected by `MessageReceiver.receiveMessage`. The
/// VM owns the runId → sessionKey map (populated in
/// `handleTransportEvent` before dispatching to
/// `EventInterpreter`); the gate consults it via
/// `viewModel.route(for:)` and rejects mismatches.
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

    func test_route_unmappedRunId_fallsThroughToSelectedSession() {
        // First time we see a runId, no mapping exists yet →
        // fall through to the currently-selected session. The
        // first-event-wins path in `handleTransportEvent` will
        // populate the map for subsequent events.
        let target = vm.route(for: "fresh-runId")
        XCTAssertEqual(target, "session-A",
                       "unmapped runId must fall through to selectedSession")
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