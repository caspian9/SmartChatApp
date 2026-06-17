import Foundation
import OpenClawChatUI

@MainActor
final class MessageReceiver {
    weak var viewModel: NativeChatViewModel?
    weak var store: MessageCacheStore?

    /// PERSIST GATE: dispatches by `state`. Messages with
    /// `state == "final"` are upserted into the cache; all
    /// other (streaming) messages are attached to the VM's
    /// `pendingBySession` (in-memory only — not persisted to
    /// the cache). Awaiting the upsert before returning
    /// eliminates the previous "pending cleared before upsert
    /// completed" race — the caller clears pending only after
    /// the upsert lands, so there is no window where the cache
    /// has no final but pending has already been cleared.
    func receiveMessage(_ message: ChatMessage) async {
        guard let store = store else { return }
        guard let sessionKey = viewModel?.selectedSession?.key else { return }

        // 1. ChatMessage → OpenClawChatMessage
        guard let openclaw = ChatMessageConverter.toOpenClawChatMessage(from: message) else {
            return
        }

        // 2. PERSIST GATE
        if message.state == "final" {
            await store.upsert([openclaw], for: sessionKey)
        } else {
            viewModel?.appendPending(message, for: sessionKey)
        }

        // 3. Trigger scrollRequest
        let currentToken = viewModel?.scrollRequest.token ?? 0
        let isInFlight = viewModel?.isSending ?? false
        viewModel?.scrollRequest = NativeChatScrollRequest(
            token: currentToken &+ 1,
            kind: .newMessage,
            forceScroll: isInFlight
        )

        // 4. Mark final messages as user-expanded so the bubble
        // opens to its full content by default.
        if message.state == "final" {
            CollapseStateCache.shared.setExpanded(message.id, true)
        }
    }

    func appendNewMessages(_ newMessages: [ChatMessage]) async {
        guard let store = store else { return }
        guard let sessionKey = viewModel?.selectedSession?.key else { return }
        let openclawMessages = newMessages.compactMap {
            ChatMessageConverter.toOpenClawChatMessage(from: $0)
        }
        // Bulk insert path. `await` lets the caller sequence the
        // append to completion before continuing.
        await store.append(openclawMessages, for: sessionKey)
        let currentToken = viewModel?.scrollRequest.token ?? 0
        viewModel?.scrollRequest = NativeChatScrollRequest(
            token: currentToken &+ 1,
            kind: .newMessage
        )
    }
}
