import Foundation
import OpenClawChatUI

@MainActor
final class MessageReceiver {
    weak var viewModel: NativeChatViewModel?
    weak var store: MessageCacheStore?

    func receiveMessage(_ message: ChatMessage) {
        guard let store = store else { return }
        guard let sessionKey = viewModel?.selectedSession?.key else { return }

        // 1. ChatMessage → OpenClawChatMessage (synthetic id is
        //    derived by ChatMessageConverter — see its
        //    `deterministicUUID(from:)` helper).
        guard let openclaw = ChatMessageConverter.toOpenClawChatMessage(from: message) else {
            return
        }

        // 2. Write to the store: use upsert instead of append.
        //    During streaming, the same runId will receiveMessage
        //    dozens of times (each delta carries a longer
        //    cumulative text). With append + content-dedup, the
        //    store would accumulate N entries with the same id but
        //    different texts, and the view's ForEach behaviour
        //    around duplicate ids is undefined — manifesting as
        //    "bubble flashes then disappears" or "stuck on first
        //    frame". Upsert replaces by id, so streaming always
        //    has exactly 1 entry whose text tracks the latest delta.
        Task { @MainActor in
            await store.upsert([openclaw], for: sessionKey)
        }

        // 3. Trigger scrollRequest.
        // forceScroll = isSending so the viewport follows the streaming
        // response even when `userHasScrolled` has been set true (e.g.,
        // the user scrolled up to read history before sending, or the
        // `sendMessage` `scrollTo` itself triggered `.onScrollPhaseChange
        // .decelerating` and pinned the flag). Without this, the
        // received deltas hit the view's `if userHasScrolled, !forceScroll
        // { return }` gate and silently no-op — the user sees the
        // sent bubble land at the bottom (forceScroll: true from
        // sendMessage) but the streaming response grow in place
        // *above* wherever the viewport ended up, never yanking it
        // back. The standard chat UX is "lock to the bottom while a
        // run is in flight"; post-streaming tool results / late final
        // messages (when isSending is false) keep respecting
        // userHasScrolled, so the user can scroll up to read
        // history after the response completes without being yanked.
        let currentToken = viewModel?.scrollRequest.token ?? 0
        let isInFlight = viewModel?.isSending ?? false
        viewModel?.scrollRequest = NativeChatScrollRequest(
            token: currentToken &+ 1,
            kind: .newMessage,
            forceScroll: isInFlight
        )

        // 4. Final messages (lifecycle=end, completed tool, command
        //    output end) get marked user-expanded so the bubble stays
        //    fully open after the next refresh. NOT setting
        //    `isSending = false` here — any "final" message (a tool
        //    result, a completed command_output) would otherwise
        //    flip the flag while the run is still producing more
        //    bubbles. The proper reset path is `EventInterpreter`
        //    `lifecycle=end` → `viewModel.resetSendState()` (which
        //    also cancels the watchdog).
        if message.state == "final" {
            CollapseStateCache.shared.setExpanded(message.id, true)
        }
    }

    func appendNewMessages(_ newMessages: [ChatMessage]) {
        guard let store = store else { return }
        guard let sessionKey = viewModel?.selectedSession?.key else { return }
        let openclawMessages = newMessages.compactMap {
            ChatMessageConverter.toOpenClawChatMessage(from: $0)
        }
        // Bulk insert path (history re-load fallback). Distinct ids,
        // append is the right semantic; content-dedup catches any
        // duplicates the server might re-emit.
        Task { @MainActor in
            await store.append(openclawMessages, for: sessionKey)
        }
        let currentToken = viewModel?.scrollRequest.token ?? 0
        viewModel?.scrollRequest = NativeChatScrollRequest(
            token: currentToken &+ 1,
            kind: .newMessage
        )
    }
}
