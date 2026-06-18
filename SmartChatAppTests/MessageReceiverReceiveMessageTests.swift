import XCTest
import OpenClawChatUI
@testable import SmartChatApp

@MainActor
final class MessageReceiverReceiveMessageTests: XCTestCase {
    private var receiver: MessageReceiver!
    private var store: MessageCacheStore!
    private var fakeStorage: FakeMessageCacheStorage!
    private var vm: NativeChatViewModel!

    override func setUp() async throws {
        fakeStorage = FakeMessageCacheStorage()
        store = MessageCacheStore(storage: fakeStorage)
        vm = NativeChatViewModel(store: store)  // inject the test store
        // vm.init already wires messageReceiver.viewModel = self
        // and injects the store — no further setup needed here.
        receiver = vm.messageReceiver
        // Tests need selectedSession to provide a sessionKey,
        // otherwise receiveMessage's guard let will early-return.
        vm.selectedSession = makeTestSession()
        // Isolate CollapseStateCache.shared side effects across tests.
        CollapseStateCache.shared.clear()
    }

    override func tearDown() async throws {
        CollapseStateCache.shared.clear()
        receiver = nil
        store = nil
        fakeStorage = nil
        vm = nil
    }

    func test_streamingMessage_appendsToStore() async throws {
        // No persist gate: state="streaming" → upsert into the
        // store directly. The streaming placeholder is visible
        // to both the store AND the merged view (no separate
        // pending tier). The id-based replace (see test below)
        // handles the streaming→final transition in place.
        let key = "session-1"
        let chat = makeChat(text: "delta", state: "streaming")
        await receiver.receiveMessage(chat)

        let messages = store.messages(for: key, since: nil)
        XCTAssertEqual(messages.count, 1, "streaming delta enters the store directly (no persist gate)")
        XCTAssertEqual(messages.first?.content.first?.text, "delta")
        // The merged view sees the same entry (read straight from
        // the store — no pending overlay).
        let merged = vm.chatMessages(for: key)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.text, "delta")
        XCTAssertEqual(merged.first?.role, "assistant")
    }

    func test_finalMessage_appendsToStore() async throws {
        // state="final" → upsert into the cache (same path as
        // streaming — no gate).
        let key = "session-1"
        let chat = makeChat(text: "done", state: "final")
        await receiver.receiveMessage(chat)

        let messages = store.messages(for: key, since: nil)
        XCTAssertEqual(messages.count, 1, "final message enters the persistent cache")
        XCTAssertEqual(messages.first?.content.first?.text, "done")
    }

    func test_streamingThenFinal_storesOnlyFinal_viaIdReplace() async throws {
        // The id-based upsert is the key behavior: streaming and
        // final share the same `id=runId`, so the second
        // receiveMessage call replaces the first in place. After
        // 2 streaming deltas + 1 final (all sharing runId), the
        // store has exactly 1 entry — the final. No clearPending
        // call needed (and indeed no longer exists — removed
        // when the persist gate collapsed).
        let key = "session-1"
        let runId = "f1e2d3c4-b5a6-7890-1234-56789abcdef0"
        await receiver.receiveMessage(makeChat(id: runId, text: "", state: "streaming"))
        await receiver.receiveMessage(makeChat(id: runId, text: "ha", state: "streaming"))
        await receiver.receiveMessage(makeChat(id: runId, text: "hello there", state: "final"))

        let messages = store.messages(for: key, since: nil)
        XCTAssertEqual(messages.count, 1, "store has only the final entry (streaming placeholders replaced in place by id)")
        XCTAssertEqual(messages.first?.content.first?.text, "hello there")
        // The merged view also contains only the final entry.
        let merged = vm.chatMessages(for: key)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.text, "hello there")
    }

    func test_lifecycleEnd_setsIsUserExpandedInCollapseCache() async {
        let id = "msg-final-1"
        let chat = makeChat(id: id, text: "done", state: "final")
        await receiver.receiveMessage(chat)
        XCTAssertTrue(CollapseStateCache.shared.isExpanded(id))
    }

    func test_scrollRequestBumpedOnNewMessage() async {
        let originalToken = vm.scrollRequest.token
        await receiver.receiveMessage(makeChat(text: "x", state: "streaming"))
        XCTAssertEqual(vm.scrollRequest.token, originalToken &+ 1)
        XCTAssertEqual(vm.scrollRequest.kind, .newMessage)
    }

    func test_streamingMetadata_overlaysAfterStoreRoundTrip() async throws {
        // The SDK's OpenClawChatMessage doesn't carry `seq` /
        // `startedAt` / `endedAt`, so the store round-trip
        // silently nils them. The VM's `streamingMetadataBySession`
        // overlay cache (populated by `recordStreamingMetadata` in
        // `MessageReceiver.receiveMessage` BEFORE upsert, applied
        // at `chatMessages(for:)` read time) restores them for
        // in-session display so the view's footer
        // `Text("#\(seq)")`, `Text(formatTime(startedAt))`, and
        // `Text("→ \(formatTime(endedAt))")` are not blank during
        // streaming.
        let key = "session-1"
        let runId = "r-meta-1"
        let streamingStart = Date(timeIntervalSince1970: 1_700_000_001)
        let streamingEnd = Date(timeIntervalSince1970: 1_700_000_005)
        let placeholder = ChatMessage(
            id: runId, text: "", timestamp: Date(),
            role: "assistant", state: "streaming", runId: runId, seq: 7,
            startedAt: streamingStart, endedAt: nil,
            livenessState: "working",
            inputTokens: nil, outputTokens: nil, cacheRead: nil, cacheWrite: nil,
            toolCallId: nil, toolName: nil, stopReason: nil)
        await receiver.receiveMessage(placeholder)

        // After upsert, the store's OpenClawChatMessage has nil
        // for seq/startedAt/endedAt (the SDK can't carry them).
        let stored = store.messages(for: key, since: nil)
        XCTAssertEqual(stored.count, 1)
        // But the merged view sees the overlay metadata restored.
        let merged = vm.chatMessages(for: key)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.seq, 7, "seq is overlaid from the in-memory metadata cache")
        XCTAssertEqual(merged.first?.startedAt, streamingStart,
                       "startedAt is overlaid (view can show the bubble's HH:mm)")
        XCTAssertNil(merged.first?.endedAt, "endedAt is still nil — placeholder has no end time yet")

        // Final arrives with a different endedAt (lifecycle=end
        // timestamp). The overlay for this runId is overwritten
        // with the final's metadata.
        let finalStart = Date(timeIntervalSince1970: 1_700_000_010)
        let finalEnd = Date(timeIntervalSince1970: 1_700_000_015)
        let finalMsg = ChatMessage(
            id: runId, text: "hello there", timestamp: Date(),
            role: "assistant", state: "final", runId: runId, seq: 7,
            startedAt: finalStart, endedAt: finalEnd,
            livenessState: nil,
            inputTokens: 10, outputTokens: 20, cacheRead: nil, cacheWrite: nil,
            toolCallId: nil, toolName: nil, stopReason: nil)
        await receiver.receiveMessage(finalMsg)
        let finalMerged = vm.chatMessages(for: key)
        XCTAssertEqual(finalMerged.count, 1, "id-replace: same runId → 1 entry, not 2")
        XCTAssertEqual(finalMerged.first?.seq, 7)
        XCTAssertEqual(finalMerged.first?.startedAt, finalStart,
                       "startedAt is overwritten with the final's start (overlay keyed by id)")
        XCTAssertEqual(finalMerged.first?.endedAt, finalEnd,
                       "endedAt is now set — view can show 'HH:mm → HH:mm'")
    }

    func test_streamingMetadata_clearedOnSessionSwitch() async throws {
        // `clearMemory(for:)` (called by `SessionCoordinator`
        // before switching sessions) must also clear the
        // streaming-metadata overlay — the new session should
        // not inherit the old session's seq/start/end metadata
        // (the bubble ids would collide on hydration, leading
        // to wrong footer text).
        let oldKey = "old-session"
        let newKey = "new-session"
        vm.selectedSession = makeTestSession(key: oldKey)
        let runId = "r-clear-1"
        await receiver.receiveMessage(ChatMessage(
            id: runId, text: "x", timestamp: Date(),
            role: "assistant", state: "final", runId: runId, seq: 99,
            startedAt: Date(), endedAt: Date(),
            livenessState: nil,
            inputTokens: nil, outputTokens: nil, cacheRead: nil, cacheWrite: nil,
            toolCallId: nil, toolName: nil, stopReason: nil))
        let oldMerged = vm.chatMessages(for: oldKey)
        XCTAssertEqual(oldMerged.first?.seq, 99, "old session has seq=99")

        // Switch to new session. clearMemory fires from
        // SessionCoordinator in production; we call it directly
        // here to test the contract.
        vm.clearMemory(for: oldKey)
        vm.selectedSession = makeTestSession(key: newKey)

        // The same bubble id in the new session should NOT
        // inherit the old session's seq=99 — clearMemory wiped it.
        // We can't easily read the new session's overlay without
        // writing a bubble there, but we can verify the OLD
        // session's overlay was cleared: re-querying chatMessages
        // for the old key should produce a bubble WITHOUT seq=99
        // (because the conversion cache is also wiped, and the
        // overlay is gone, so the metadata fallback is nil).
        // Note: the store still HAS the bubble; we're only
        // checking the VM-side state.
        // Re-read oldKey after a no-op upsert to bump the
        // version (forces a re-conversion).
        await receiver.receiveMessage(ChatMessage(
            id: "noop", text: "noop", timestamp: Date(),
            role: "user", state: "final", runId: nil, seq: nil,
            startedAt: nil, endedAt: nil,
            livenessState: nil,
            inputTokens: nil, outputTokens: nil, cacheRead: nil, cacheWrite: nil,
            toolCallId: nil, toolName: nil, stopReason: nil))
        let reQueryOld = vm.chatMessages(for: oldKey)
        // The "noop" upsert records seq=nil for itself; the old
        // "r-clear-1" bubble's overlay entry was wiped, so its
        // seq is nil in the re-conversion. (If clearMemory DIDN'T
        // wipe the overlay, the seq would still be 99 here.)
        XCTAssertNil(reQueryOld.first(where: { $0.id == runId })?.seq,
                     "old session's streaming metadata must be cleared on clearMemory")
    }

    // MARK: - Helpers

    private func makeTestSession(key: String = "session-1") -> OpenClawChatSessionEntry {
        OpenClawChatSessionEntry(
            key: key,
            kind: "test",
            displayName: "Test Session",
            surface: nil,
            subject: nil,
            room: nil,
            space: nil,
            updatedAt: nil,
            sessionId: nil,
            systemSent: nil,
            abortedLastRun: nil,
            thinkingLevel: nil,
            verboseLevel: nil,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: nil,
            modelProvider: nil,
            model: nil,
            contextTokens: nil,
            thinkingLevels: nil,
            thinkingOptions: nil,
            thinkingDefault: nil
        )
    }

    private func makeChat(id: String = "msg-1", text: String = "x",
                          state: String = "streaming") -> ChatMessage {
        ChatMessage(
            id: id, text: text, timestamp: Date(),
            role: "assistant", state: state, runId: "run-1", seq: nil,
            startedAt: Date(), endedAt: state == "final" ? Date() : nil,
            livenessState: state == "streaming" ? "working" : nil,
            inputTokens: nil, outputTokens: nil, cacheRead: nil, cacheWrite: nil,
            toolCallId: nil, toolName: nil, stopReason: nil)
    }
}
