import Foundation
import OpenClawChatUI

@MainActor
final class MessageReceiver {
    weak var viewModel: NativeChatViewModel?
    weak var store: MessageCacheStore?

    func receiveMessage(_ message: ChatMessage) {
        guard let store = store else { return }
        guard let sessionKey = viewModel?.selectedSession?.key else { return }

        // 1. ChatMessage → OpenClawChatMessage(synthetic id 由 ChatMessageConverter 兜底)
        guard let openclaw = ChatMessageConverter.toOpenClawChatMessage(from: message) else {
            return
        }

        // 2. 写 store(内部 dedup + 持久化)
        Task { @MainActor in
            await store.append([openclaw], for: sessionKey)
        }

        // 3. 触发 scrollRequest
        let currentToken = viewModel?.scrollRequest.token ?? 0
        viewModel?.scrollRequest = NativeChatScrollRequest(
            token: currentToken &+ 1,
            kind: .newMessage
        )

        // 4. Lifecycle end: mark isUserExpanded(bug 1 修复核心,保留)
        if message.state == "final" {
            CollapseStateCache.shared.setExpanded(message.id, true)
            viewModel?.isSending = false
        }
    }

    func appendNewMessages(_ newMessages: [ChatMessage]) {
        guard let store = store else { return }
        guard let sessionKey = viewModel?.selectedSession?.key else { return }
        let openclawMessages = newMessages.compactMap {
            ChatMessageConverter.toOpenClawChatMessage(from: $0)
        }
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
