import Foundation
import OpenClawChatUI

@MainActor
final class MessageReceiver {
    weak var viewModel: NativeChatViewModel?
    weak var store: MessageCacheStore?

    /// Routes incoming messages directly to the persistent
    /// `MessageCacheStore` via `upsert` — no in-memory pending
    /// layer. Both streaming (state="streaming") and final
    /// (state="final") bubbles go through the same write path;
    /// `MessageCacheStorage.upsert` keys on `OpenClawChatMessage.id`
    /// (= `runId` for assistant deltas, deterministic per-runId
    /// for thinking/tool), so N streaming deltas sharing one
    /// runId collapse to a single in-place update whose text
    /// grows monotonically. When the lifecycle=end final
    /// arrives with the same runId, the upsert replaces the
    /// streaming placeholder with the final version (state=
    /// "final", full text).
    ///
    /// Issue #34 strict gate (issue #34 leak fix): the gate
    /// consults `viewModel.route(for:)` and either:
    ///   1. accepts (map hit matches selectedSession, OR runId is nil)
    ///   2. buffers (unmapped non-final runId)
    ///   3. rejects (map hit ≠ selectedSession, OR unmapped final)
    ///
    /// Why not gate by state (the old "persist gate"): the
    /// streaming placeholder and the final share the same id,
    /// so the gate's "ephemeral vs persistent" split was
    /// unnecessary indirection. It also caused "bubbles
    /// disappear on completion" because the lifecycle=end
    /// path nixed the entire pending list (including any
    /// other in-flight runs). Routing everything through the
    /// store with id-upsert makes the lifecycle=end transition
    /// a natural in-place replacement, not a nuke-and-rebuild.
    func receiveMessage(_ message: ChatMessage) async {
        guard let store = store else { return }

        // Issue #34 routing gate (strict policy): see docstring
        // above. The gate consults the VM's `runSessionKeyByRunId`
        // map (populated by `chat.sessionKey` in
        // `handleTransportEvent`) and:
        //   - accepts the message if the runId maps to the
        //     currently-selected session (or runId is nil);
        //   - buffers it in `pendingAgentBuffer` if the runId
        //     is unmapped AND non-final (will be flushed when
        //     the chat event confirms the sessionKey);
        //   - rejects it otherwise.
        guard let targetSessionKey = viewModel?.route(for: message.runId) else {
            if let runId = message.runId, message.state != "final" {
                viewModel?.bufferPendingAgent(message, for: runId)
            } else if let runId = message.runId {
                AppLogger.log(
                    "nested-run rejected (final, unmapped): runId=\(runId) role=\(message.role) state=\(message.state)",
                    category: .nativeChat, level: .debug)
            }
            return
        }
        guard targetSessionKey == viewModel?.selectedSession?.key else {
            AppLogger.log(
                "nested-run rejected: runId=\(message.runId ?? "nil") target=\(targetSessionKey) selected=\(viewModel?.selectedSession?.key ?? "nil") role=\(message.role)",
                category: .nativeChat, level: .debug)
            return
        }

        let sessionKey = targetSessionKey

        // 1. ChatMessage → OpenClawChatMessage
        guard let openclaw = ChatMessageConverter.toOpenClawChatMessage(from: message) else {
            return
        }

        // 2. Capture streaming metadata BEFORE upsert. The
        // SDK's `OpenClawChatMessage` can't carry `seq` /
        // `startedAt` / `endedAt`, so the toOpenClawChatMessage
        // call above drops them — they would be lost on the
        // store round-trip and the view's footer
        // ("#\(seq)", "HH:mm" start time, "→ HH:mm" end time)
        // would be missing for every streaming bubble. The
        // VM caches them in-memory and overlays on
        // `chatMessages(for:)` read.
        viewModel?.recordStreamingMetadata(for: message)

        // 3. Upsert. Same code path for streaming and final;
        // the store keys on id (runId-derived), so deltas
        // collapse and final replaces placeholder in place.
        await store.upsert([openclaw], for: sessionKey)

        // 4. Trigger scrollRequest
        let currentToken = viewModel?.scrollRequest.token ?? 0
        let isInFlight = viewModel?.isSending ?? false
        viewModel?.scrollRequest = NativeChatScrollRequest(
            token: currentToken &+ 1,
            kind: .newMessage,
            forceScroll: isInFlight
        )

        // 5. Mark final messages as user-expanded so the bubble
        // opens to its full content by default. Streaming
        // bubbles (state != "final") keep their default
        // collapse state.
        if message.state == "final" {
            CollapseStateCache.shared.setExpanded(message.id, true)
        }
    }

    /// Force-routes a buffered message to a specific sessionKey,
    /// bypassing the gate's session-mismatch check. Called from
    /// `VM.flushPending(for:)` after a chat event has confirmed
    /// the runId → sessionKey mapping. The buffer flush MUST NOT
    /// go through `receiveMessage(_:)` because the user is
    /// typically still viewing a DIFFERENT session while a
    /// nested run's chat event arrives; the gate would reject
    /// the message and the buffer would be discarded.
    ///
    /// The sessionKey passed in is the one the chat event
    /// declared — it's authoritative and trumps the gate. Once
    /// the user navigates to that session, the buffered bubble
    /// (or its final replacement) will be visible.
    func flushToSession(_ message: ChatMessage, sessionKey: String) async {
        guard let store = store else { return }
        guard let openclaw = ChatMessageConverter.toOpenClawChatMessage(from: message) else {
            return
        }
        viewModel?.recordStreamingMetadata(for: message)
        await store.upsert([openclaw], for: sessionKey)
        let currentToken = viewModel?.scrollRequest.token ?? 0
        let isInFlight = viewModel?.isSending ?? false
        viewModel?.scrollRequest = NativeChatScrollRequest(
            token: currentToken &+ 1,
            kind: .newMessage,
            forceScroll: isInFlight
        )
        if message.state == "final" {
            CollapseStateCache.shared.setExpanded(message.id, true)
        }
    }
}
