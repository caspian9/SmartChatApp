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
    /// Why not gate by state (the old "persist gate"): the
    /// streaming placeholder and the final share the same
    /// id, so the gate's "ephemeral vs persistent" split was
    /// unnecessary indirection. It also caused "bubbles
    /// disappear on completion" because the lifecycle=end
    /// path nixed the entire pending list (including any
    /// other in-flight runs). Routing everything through the
    /// store with id-upsert makes the lifecycle=end transition
    /// a natural in-place replacement, not a nuke-and-rebuild.
    func receiveMessage(_ message: ChatMessage) async {
        guard let store = store else { return }

        // Issue #34 routing gate: ask the VM which session this
        // runId belongs to (via the runId → sessionKey map
        // populated in `handleTransportEvent`). If the resolved
        // target session ≠ the currently-selected session, the
        // event is from a nested agent run on a DIFFERENT
        // session and must not be upserted into the user's view.
        // Reject with a debug log so on-call can grep for the
        // cause if a leak resurfaces.
        guard let targetSessionKey = viewModel?.route(for: message.runId) else {
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

        // 3. Trigger scrollRequest
        let currentToken = viewModel?.scrollRequest.token ?? 0
        let isInFlight = viewModel?.isSending ?? false
        viewModel?.scrollRequest = NativeChatScrollRequest(
            token: currentToken &+ 1,
            kind: .newMessage,
            forceScroll: isInFlight
        )

        // 4. Mark final messages as user-expanded so the bubble
        // opens to its full content by default. Streaming
        // bubbles (state != "final") keep their default
        // collapse state.
        if message.state == "final" {
            CollapseStateCache.shared.setExpanded(message.id, true)
        }
    }
}
