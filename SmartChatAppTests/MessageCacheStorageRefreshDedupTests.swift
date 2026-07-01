import XCTest
import OpenClawChatUI
@testable import SmartChatApp

/// Tests for the post-PR-#43 refresh bug: assistant AND user
/// bubbles appear as duplicates after the user pulls to refresh
/// following a streamed completion.
///
/// Root-cause hypothesis (to be confirmed): `MessageCacheStorage.append`'s
/// `dedupKey` buckets on `Int64(timestamp / 10_000)` (10s windows), but in
/// production the streaming-side entry's `timestamp` and the server's
/// `chat.history.ts` for the same logical message can drift by more than
/// 10 seconds — e.g., the device-local `Date()` at send-time vs the
/// gateway-arrival timestamp on the user message echo, or the
/// `lifecycle=start` wall-clock on the device vs the server's own
/// recording of the same event. When the drift crosses a bucket
/// boundary, the dedup misses and both entries survive as independent
/// bubbles.
///
/// PR #43 ran the suite at 280 tests / 0 failures before merge, but
/// `HistoryLoaderAppendTests.test_fetchAndMergeFromNetwork_streamingUsagePreserved_differentIds_afterMerge`
/// only covers the happy path where streamed.ts == server.ts. It does
/// not exercise the cross-bucket drift that production exhibits.
///
/// Tests below pin the contract: refresh after streaming completion
/// must not introduce additional bubble entries beyond what the
/// streaming path already wrote.
final class MessageCacheStorageRefreshDedupTests: XCTestCase {
    private let testSuite = "test.openclaw.refresh-dedup.\(UUID().uuidString)"
    private var defaults: UserDefaults!
    private var storage: MessageCacheStorage!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: testSuite)!
        defaults.removePersistentDomain(forName: testSuite)
        storage = MessageCacheStorage(defaults: defaults)
    }

    override func tearDown() async throws {
        defaults?.removePersistentDomain(forName: testSuite)
        defaults = nil
        storage = nil
    }

    // MARK: - Helpers

    private func makeMsg(id: UUID = UUID(), role: String = "assistant",
                         text: String = "hello",
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

    // MARK: - Test 1: user bubble echo across 10s bucket boundary

    /// Production repro: `NativeChatViewModel.sendAsMessage`
    /// (Features/NativeChat/NativeChatViewModel.swift:681-739)
    /// writes the outgoing user message at `timestamp = Date()`,
    /// then the gateway echoes the message back as a `chat` event
    /// that flows through `MessageReceiver.receiveMessage`. The
    /// echo event carries a server-side timestamp (the moment the
    /// gateway observed the message), which typically lands a few
    /// seconds to tens of seconds after the device-local send.
    /// When the drift crosses the 10-second `dedupKey` bucket
    /// boundary, the two entries are treated as distinct and the
    /// user bubble appears twice in the chat list.
    func test_append_userEcho_acrossBucketBoundary_dedups() async {
        let key = "session-1"
        // Device-local send at the millisecond boundary.
        let deviceSendTs: Double = 1_700_000_005_000
        // Server-arrival timestamp 15 seconds later (deliberately
        // straddles the 10s `Int64(ts / 10_000)` bucket boundary at
        // 1_700_000_010_000 / 10_000 = 170000001).
        let serverEchoTs: Double = 1_700_000_020_000
        await storage.append(
            [makeMsg(id: UUID(), role: "user", text: "Hello",
                     timestamp: deviceSendTs)],
            for: key)
        await storage.append(
            [makeMsg(id: UUID(), role: "user", text: "Hello",
                     timestamp: serverEchoTs)],
            for: key)
        let loaded = await storage.load(for: key)
        XCTAssertEqual(loaded.count, 1,
                       "user bubble echo across bucket boundary must dedup to one entry, but got \(loaded.count)")
    }

    // MARK: - Test 2: assistant streamed-final vs server copy across bucket

    /// Production repro: streamed assistant final written at
    /// `timestamp = chosenAnchor = lifecycle=start wall-clock on
    /// device`. Server's `chat.history.ts` for the same logical
    /// message uses the moment the gateway first saw the run
    /// start, not the moment the device received
    /// `lifecycle=start`. On a flaky WebSocket that gap routinely
    /// exceeds 10 seconds, splitting the two entries into
    /// different `dedupKey` buckets.
    func test_append_assistantStreamedFinalVsServer_acrossBucketBoundary_dedups() async {
        let key = "session-1"
        // Streamed final written at device wall-clock (lifecycle=start arrival).
        let streamedTs: Double = 1_700_000_003_500
        // Server `chat.history.ts` 12 seconds later — different bucket.
        let serverTs: Double = 1_700_000_015_500
        await storage.append(
            [makeMsg(id: UUID(), role: "assistant", text: "final answer",
                     timestamp: streamedTs)],
            for: key)
        await storage.append(
            [makeMsg(id: UUID(), role: "assistant", text: "final answer",
                     timestamp: serverTs)],
            for: key)
        let loaded = await storage.load(for: key)
        XCTAssertEqual(loaded.count, 1,
                       "streamed-vs-server assistant copies across bucket boundary must dedup, but got \(loaded.count)")
    }

    // MARK: - Test 3: same role/text but ts in different bucket — control

    /// Negative control: when ts are in the SAME 10s bucket,
    /// existing dedup already works (verified by
    /// `HistoryLoaderAppendTests.test_..._differentIds_afterMerge`).
    /// This test pins that the bucket-alignment is the actual
    /// discriminator — when the values align, dedup catches the
    /// duplicate; when they don't, it doesn't. Failure here would
    /// indicate the dedup is broken beyond a bucket issue (i.e., a
    /// completely separate bug).
    func test_append_assistantSameBucket_dedups_regressionControl() async {
        let key = "session-1"
        // Both in bucket 1_700_000_000 / 10_000 = 170000000.
        let ts1: Double = 1_700_000_003_000
        let ts2: Double = 1_700_000_007_000
        await storage.append(
            [makeMsg(id: UUID(), role: "assistant", text: "hi",
                     timestamp: ts1)],
            for: key)
        await storage.append(
            [makeMsg(id: UUID(), role: "assistant", text: "hi",
                     timestamp: ts2)],
            for: key)
        let loaded = await storage.load(for: key)
        XCTAssertEqual(loaded.count, 1)
    }

    // MARK: - Test 4: same session, separately-timestamped user + assistant

    /// End-to-end shape of the user's bug report: a single chat
    /// turn produces a user bubble plus an assistant bubble, both
    /// streamed-through, and a subsequent refresh fetches the
    /// server's authoritative copy of the same turn with a fresh
    /// timestamp and fresh UUIDs. After the refresh, the cache
    /// must still contain exactly one user entry and one
    /// assistant entry — not two of each.
    func test_append_fullTurnRefresh_acrossBucket_noDuplication() async {
        let key = "session-1"
        // Streaming-side entries.
        let streamUserTs: Double = 1_700_000_001_000
        let streamAssistantTs: Double = 1_700_000_002_500
        await storage.append(
            [makeMsg(id: UUID(), role: "user", text: "Hi",
                     timestamp: streamUserTs)],
            for: key)
        await storage.append(
            [makeMsg(id: UUID(), role: "assistant", text: "Hello!",
                     timestamp: streamAssistantTs)],
            for: key)
        let midCount = await storage.load(for: key)
        XCTAssertEqual(midCount.count, 2)
        // Server-side copies — same text, fresh ids, drifted timestamps.
        // User echo: 13s later (crosses the 10s bucket). Assistant:
        // 14s later (also crosses).
        await storage.append(
            [makeMsg(id: UUID(), role: "user", text: "Hi",
                     timestamp: 1_700_000_014_000)],
            for: key)
        await storage.append(
            [makeMsg(id: UUID(), role: "assistant", text: "Hello!",
                     timestamp: 1_700_000_016_500)],
            for: key)
        let loaded = await storage.load(for: key)
        XCTAssertEqual(loaded.count, 2,
                       "after refresh, the cache must still hold 2 entries (one user, one assistant); got \(loaded.count)")
        let byRole = Dictionary(grouping: loaded, by: { $0.role })
        XCTAssertEqual(byRole["user"]?.count, 1,
                       "user bubble should be one entry; got \(byRole["user"]?.count ?? 0)")
        XCTAssertEqual(byRole["assistant"]?.count, 1,
                       "assistant bubble should be one entry; got \(byRole["assistant"]?.count ?? 0)")
    }
}
