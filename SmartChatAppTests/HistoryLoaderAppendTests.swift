import XCTest
import OpenClawChatUI
import OpenClawProtocol
@testable import SmartChatApp

/// Tests for issue #36's HistoryLoader change: the network
/// fetch path now uses `MessageCacheStore.append` instead of
/// `MessageCacheStorage.replaceForSession`. The wipe-and-replace
/// approach dropped client-only messages (the user-sent text
/// bubble for which the server hasn't yet emitted a history
/// record) and wiped streaming-time `usage` data; the new
/// append-only path merges the server payload onto whatever
/// the local cache already has.
///
/// The transport seam is `HistoryLoader.transportFactory`: a
/// test-injectable closure that returns a fake `OpenClawChatTransport`.
/// Production code uses the default (SessionManager.shared).
///
/// We use the production `MessageCacheStorage` (with a clean
/// UserDefaults suite per test) instead of `FakeMessageCacheStorage`
/// because the production storage has the dedup logic these
/// tests depend on (id-dedup + content-dedup). The fake is
/// simpler and tuned for `MessageCacheStoreTests`, where
/// content-dedup would break the `lastSeenTimestamp`
/// assertions.
@MainActor
final class HistoryLoaderAppendTests: XCTestCase {
    private var loader: HistoryLoader!
    private var vm: NativeChatViewModel!
    private var store: MessageCacheStore!
    private var storage: MessageCacheStorage!
    private var defaults: UserDefaults!
    private var fakeTransport: FakeHistoryTransport!
    private let testSuite = "test.openclaw.history-loader-append.\(UUID().uuidString)"

    override func setUp() async throws {
        await SessionManager.shared.disconnect()
        defaults = UserDefaults(suiteName: testSuite)!
        defaults.removePersistentDomain(forName: testSuite)
        storage = MessageCacheStorage(defaults: defaults)
        store = MessageCacheStore(storage: storage)
        vm = NativeChatViewModel(store: store)
        loader = HistoryLoader()
        loader.viewModel = vm
        loader.store = store
        fakeTransport = FakeHistoryTransport()
        loader.transportFactory = { [fakeTransport] _ in
            // Strong capture: the test owns `fakeTransport` as
            // a stored property for the test's lifetime, and the
            // closure runs synchronously during the awaited
            // `fetchAndMergeFromNetwork`. A weak capture here
            // would risk dropping the ref if the test setup ran
            // on a different actor than the loader.
            return fakeTransport
        }
    }

    override func tearDown() async throws {
        await SessionManager.shared.disconnect()
        loader = nil
        vm = nil
        store = nil
        storage = nil
        defaults?.removePersistentDomain(forName: testSuite)
        defaults = nil
        fakeTransport = nil
    }

    // MARK: - Test 1: client-only messages survive the merge
    //
    // Regression for the user-reported "my outgoing text bubble
    // disappeared after the network refresh" bug. With
    // `replaceForSession`, the server's history wipe erased the
    // client-only user message that hadn't yet been
    // server-confirmed. The append path keeps the cache and
    // merges the server payload on top.

    func test_fetchAndMergeFromNetwork_usesAppend_keepsClientOnlyMessages() async throws {
        let key = "session-1"
        vm.selectedSession = makeSession(key: key)
        let clientOnly = makeMsg(
            id: UUID(), role: "user", text: "client only",
            timestamp: 1000)
        let serverA = makeMsg(
            id: UUID(), role: "assistant", text: "A", timestamp: 2000)
        let serverB = makeMsg(
            id: UUID(), role: "assistant", text: "B", timestamp: 3000)
        let serverC = makeMsg(
            id: UUID(), role: "assistant", text: "C", timestamp: 4000)
        await store.append([clientOnly], for: key)
        await storage.flushPendingWrites()
        fakeTransport.payload = makeHistoryPayload(
            sessionKey: key, messages: [serverA, serverB, serverC])

        await loader.fetchAndMergeFromNetwork(
            sessionKey: key,
            sessionKeyPreview: String(key.prefix(8)),
            taskIdStr: "test1",
            scrollKind: .historyLoaded
        )

        let stored = store.messages(for: key)
        XCTAssertEqual(stored.count, 4,
                       "client-only user message must survive the merge (no wipe)")
        XCTAssertEqual(stored.map { $0.content.first?.text },
                       ["client only", "A", "B", "C"],
                       "messages must be in chronological order")
    }

    // MARK: - Test 2: content-dedup catches server returning same content twice
    //
    // A buggy server or a relay that double-emits could send the
    // same logical message twice in one history response. Because
    // the SDK's `OpenClawChatMessage.CodingKeys` omits `id` (a
    // known limitation, see `PersistedMessageEnvelope` for the
    // disk-round-trip workaround), each server-side decode gets
    // a fresh UUID. So the dedup that catches this is
    // **content-dedup** (same role + same text), not id-dedup.
    // The store ends up with 2 entries (the
    // existing serverA from the pre-populate + the new serverB);
    // the duplicate A is dropped.

    func test_fetchAndMergeFromNetwork_contentDedup_serverReturnsSameMessageTwice_appendsOnce() async throws {
        let key = "session-1"
        vm.selectedSession = makeSession(key: key)
        let serverA = makeMsg(
            id: UUID(), role: "assistant", text: "duplicate A", timestamp: 2000)
        let serverADup = makeMsg(
            id: UUID(), role: "assistant", text: "duplicate A", timestamp: 2000)
        let serverB = makeMsg(
            id: UUID(), role: "assistant", text: "B", timestamp: 3000)
        await store.append([serverA], for: key)
        await storage.flushPendingWrites()
        // Server returns [serverA (same content, fresh id), serverB].
        // Content-dedup keeps the existing serverA, appends serverB.
        // Note: the SDK regenerates ids on decode, so even if the
        // server included the same id on the wire, the in-memory
        // copy would have a fresh UUID.
        fakeTransport.payload = makeHistoryPayload(
            sessionKey: key, messages: [serverADup, serverB])

        await loader.fetchAndMergeFromNetwork(
            sessionKey: key,
            sessionKeyPreview: String(key.prefix(8)),
            taskIdStr: "test2",
            scrollKind: .historyLoaded
        )

        let stored = store.messages(for: key)
        XCTAssertEqual(stored.count, 2,
                       "content-dedup must drop the duplicate A; only serverB is new")
        XCTAssertEqual(stored.map { $0.content.first?.text }, ["duplicate A", "B"])
    }

    // MARK: - Test 3: streaming-time `usage` preserved across merge
    //
    // Regression for the user-reported "input / output / cache
    // tokens disappeared after refresh" bug. The server's
    // `chat.history` payload omits the streaming-time `usage`
    // block. With `replaceForSession`, the wipe + replace dropped
    // the streaming-time `usage` data. With `append`, the
    // existing entry's `usage` is preserved (last-write-wins
    // content dedup keeps the existing entry by id).

    func test_fetchAndMergeFromNetwork_streamingUsagePreserved_afterMerge() async throws {
        let key = "session-1"
        vm.selectedSession = makeSession(key: key)
        let sharedId = UUID()
        let streamingUsage = makeUsageSentinel(input: 1234)
        let streamed = OpenClawChatMessage(
            id: sharedId, role: "assistant",
            content: [OpenClawChatMessageContent(
                type: "text", text: "final answer", thinking: nil,
                thinkingSignature: nil, mimeType: nil, fileName: nil,
                content: nil)],
            timestamp: 2000, toolCallId: nil, toolName: nil,
            usage: streamingUsage, stopReason: nil, errorMessage: nil)
        await store.append([streamed], for: key)
        await storage.flushPendingWrites()
        // Server returns the same logical message (same text +
        // role + same timestamp) but with `usage: nil` — the
        // typical shape of `chat.history`.
        let serverCopy = OpenClawChatMessage(
            id: sharedId, role: "assistant",
            content: [OpenClawChatMessageContent(
                type: "text", text: "final answer", thinking: nil,
                thinkingSignature: nil, mimeType: nil, fileName: nil,
                content: nil)],
            timestamp: 2000, toolCallId: nil, toolName: nil,
            usage: nil, stopReason: nil, errorMessage: nil)
        fakeTransport.payload = makeHistoryPayload(
            sessionKey: key, messages: [serverCopy])

        await loader.fetchAndMergeFromNetwork(
            sessionKey: key,
            sessionKeyPreview: String(key.prefix(8)),
            taskIdStr: "test3",
            scrollKind: .historyLoaded
        )

        let stored = store.messages(for: key)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.usage?.input, 1234,
                       "streaming-time usage must survive the server merge (input=1234, server omitted it)")
    }

    // MARK: - Test 4: streaming-time `usage` preserved when ids differ
    //
    // C1 follow-up: the test above (`streamingUsagePreserved_afterMerge`)
    // uses `sharedId` for both the streamed and server copies. With
    // matching ids, `MessageCacheStorage.append`'s new id-dedup drops
    // the server copy BEFORE `applyUsagePreservation` has a chance to
    // run — so that test passes by id-dedup, not by the splice. This
    // test covers the realistic production case: the SDK's
    // `OpenClawChatMessage.CodingKeys` omits `id` (see
    // `PersistedMessageEnvelope`), so every server-side decode gets
    // a fresh UUID, and the streamed (client-side synthesized) id
    // never matches the server's id. The dedup that actually saves
    // the streaming-time usage in production is therefore the
    // KEEP-on-content-match branch of `append` — the existing entry
    // stays, with its original `usage` intact.
    //
    // Asserts the user-visible contract: streaming-time `usage`
    // survives the merge even when ids differ. (`applyUsagePreservation`
    // runs first to splice usage into the server copy, then
    // content-dedup drops the server copy and keeps the streamed one.
    // The end state is the same: usage preserved.)

    func test_fetchAndMergeFromNetwork_streamingUsagePreserved_differentIds_afterMerge() async throws {
        let key = "session-1"
        vm.selectedSession = makeSession(key: key)
        let streamedId = UUID()
        let serverId = UUID()
        let streamingUsage = makeUsageSentinel(input: 1234)
        let streamed = OpenClawChatMessage(
            id: streamedId, role: "assistant",
            content: [OpenClawChatMessageContent(
                type: "text", text: "final answer", thinking: nil,
                thinkingSignature: nil, mimeType: nil, fileName: nil,
                content: nil)],
            timestamp: 2000, toolCallId: nil, toolName: nil,
            usage: streamingUsage, stopReason: nil, errorMessage: nil)
        await store.append([streamed], for: key)
        await storage.flushPendingWrites()
        // Server returns the same logical message (same text +
        // role + same timestamp) but with a FRESH id and
        // `usage: nil` — the typical shape of `chat.history`
        // after the SDK drops `id` on JSON decode.
        let serverCopy = OpenClawChatMessage(
            id: serverId, role: "assistant",
            content: [OpenClawChatMessageContent(
                type: "text", text: "final answer", thinking: nil,
                thinkingSignature: nil, mimeType: nil, fileName: nil,
                content: nil)],
            timestamp: 2000, toolCallId: nil, toolName: nil,
            usage: nil, stopReason: nil, errorMessage: nil)
        fakeTransport.payload = makeHistoryPayload(
            sessionKey: key, messages: [serverCopy])

        await loader.fetchAndMergeFromNetwork(
            sessionKey: key,
            sessionKeyPreview: String(key.prefix(8)),
            taskIdStr: "test4",
            scrollKind: .historyLoaded
        )

        let stored = store.messages(for: key)
        XCTAssertEqual(stored.count, 1,
                       "content-dedup must keep the streamed entry; the fresh-id server copy is dropped")
        XCTAssertEqual(stored.first?.usage?.input, 1234,
                       "streaming-time usage must survive even when the server copy has a different id (input=1234, server omitted it)")
        XCTAssertEqual(stored.first?.id, streamedId,
                       "the entry that survives is the streamed (client-synthesized) one — content-dedup keeps it by KEEP-on-content-match")
    }

    // MARK: - Helpers

    private func makeMsg(id: UUID = UUID(), role: String = "assistant",
                         text: String = "x",
                         timestamp: Double = 1000) -> OpenClawChatMessage {
        OpenClawChatMessage(
            id: id, role: role,
            content: [OpenClawChatMessageContent(
                type: "text", text: text, thinking: nil,
                thinkingSignature: nil, mimeType: nil, fileName: nil,
                content: nil)],
            timestamp: timestamp, toolCallId: nil, toolName: nil,
            usage: nil, stopReason: nil, errorMessage: nil)
    }

    /// `fetchAndMergeFromNetwork` reads `viewModel.selectedSession`
    /// to check that the user hasn't switched sessions since the
    /// network call started. Tests need a selected session set so
    /// the staleness guard doesn't fire and the merge runs.
    private func makeSession(key: String) -> OpenClawChatSessionEntry {
        OpenClawChatSessionEntry(
            key: key, kind: "test", displayName: "Test Session",
            surface: nil, subject: nil, room: nil, space: nil,
            updatedAt: nil, sessionId: nil, systemSent: nil,
            abortedLastRun: nil, thinkingLevel: nil, verboseLevel: nil,
            inputTokens: nil, outputTokens: nil, totalTokens: nil,
            modelProvider: nil, model: nil, contextTokens: nil,
            thinkingLevels: nil, thinkingOptions: nil,
            thinkingDefault: nil)
    }

    /// Round-trip a usage sentinel through JSONEncoder/JSONDecoder
    /// the same way `ChatMessageConverter.toOpenClawChatMessage`
    /// does for `usage` — `OpenClawChatUsage` has no memberwise
    /// init, only `Codable` synthesis.
    private func makeUsageSentinel(input: Int) -> OpenClawChatUsage {
        let payload: [String: Any] = [
            "input": input, "output": -1, "cacheRead": -1,
            "cacheWrite": -1, "total": -1
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return try! JSONDecoder().decode(OpenClawChatUsage.self, from: data)
    }

    /// Builds an `OpenClawChatHistoryPayload` from a sessionKey +
    /// message list. The struct has no memberwise init in the
    /// SDK (only `Codable` synthesis), so we build the JSON by
    /// encoding each message individually and assembling the
    /// top-level dict. Mirrors the approach used by
    /// `GatewayChatTransport.payloadWithEmptyMessages`.
    private func makeHistoryPayload(
        sessionKey: String,
        messages: [OpenClawChatMessage]
    ) -> OpenClawChatHistoryPayload {
        let encoder = JSONEncoder()
        let messageDicts: [[String: Any]] = messages.map { msg in
            let data = (try? encoder.encode(msg)) ?? Data()
            let obj = try? JSONSerialization.jsonObject(with: data)
            return (obj as? [String: Any]) ?? [:]
        }
        let topLevel: [String: Any] = [
            "sessionKey": sessionKey,
            "messages": messageDicts
        ]
        let data = try! JSONSerialization.data(withJSONObject: topLevel)
        return try! JSONDecoder().decode(
            OpenClawChatHistoryPayload.self, from: data)
    }
}

/// In-memory fake for `OpenClawChatTransport.requestHistory`.
/// Records the requested sessionKey and returns whatever the
/// test stashed in `payload`. All other protocol methods are
/// satisfied by the SDK's default extension implementations
/// (most throw "not supported by this transport"). The
/// `events()` extension returns an empty stream.
final class FakeHistoryTransport: OpenClawChatTransport, @unchecked Sendable {
    var payload: OpenClawChatHistoryPayload?
    var requestedKeys: [String] = []

    func requestHistory(sessionKey: String) async throws -> OpenClawChatHistoryPayload {
        requestedKeys.append(sessionKey)
        if let payload {
            return payload
        }
        // Empty fallback — build via JSON round-trip because
        // `OpenClawChatHistoryPayload` has no public memberwise
        // init in the SDK.
        let jsonStr = "{\"sessionKey\": \"\(sessionKey)\", \"messages\": []}"
        let data = jsonStr.data(using: .utf8)!
        return try JSONDecoder().decode(
            OpenClawChatHistoryPayload.self, from: data)
    }

    // Other protocol methods — only `requestHistory` is exercised
    // by `HistoryLoader.fetchAndMergeFromNetwork`. The SDK
    // extension provides defaults for `createSession`,
    // `setActiveSessionKey`, `waitForRunCompletion`,
    // `resetSession`, `compactSession`, `abortRun`,
    // `listSessions`, `listModels`, `setSessionModel`,
    // `setSessionThinking`. Three are NOT extended — provide
    // minimal stubs.

    func sendMessage(
        sessionKey: String, message: String, thinking: String,
        idempotencyKey: String,
        attachments: [OpenClawChatAttachmentPayload]
    ) async throws -> OpenClawChatSendResponse {
        throw URLError(.unsupportedURL)
    }
    func requestHealth(timeoutMs: Int) async throws -> Bool {
        return true
    }
    func events() -> AsyncStream<OpenClawChatTransportEvent> {
        AsyncStream { _ in }
    }
}