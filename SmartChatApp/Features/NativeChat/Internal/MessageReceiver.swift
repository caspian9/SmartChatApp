import SwiftUI
import OpenClawChatUI

@MainActor
final class MessageReceiver {
    weak var viewModel: NativeChatViewModel?

    /// Apply an incoming `ChatMessage` to the view-model's `messages` array.
    /// Three merge paths: id-match (streaming update), role+text+timestamp
    /// similar-match (cache ↔ streaming id mismatch), or fresh insert.
    /// Mirrors `NativeChatViewModel.receiveMessage` from the pre-refactor VM.
    func receiveMessage(_ message: ChatMessage) {
        guard let vm = viewModel else { return }
        if let existingIndex = vm.messages.firstIndex(where: { $0.id == message.id }) {
            var existingMessage = vm.messages[existingIndex]
            AppLogger.log("receiveMessage update - id: \(String(message.id.prefix(8))), existingIndex: \(existingIndex), newText len: \(message.text.count), existingText len: \(existingMessage.text.count), state: \(message.state)", category: .nativeChat)
            if !message.text.isEmpty {
                existingMessage.text = message.text
                AppLogger.log("receiveMessage updated text, new len: \(existingMessage.text.count), prev state: \(existingMessage.state), new state: \(message.state)", category: .nativeChat)
            } else {
                AppLogger.log("receiveMessage SKIPPED text update (empty), prev state: \(existingMessage.state), new state: \(message.state)", category: .nativeChat, level: .warning)
            }
            existingMessage.state = message.state
            if message.startedAt != nil { existingMessage.startedAt = message.startedAt }
            if message.endedAt != nil { existingMessage.endedAt = message.endedAt }
            if message.livenessState != nil { existingMessage.livenessState = message.livenessState }
            if message.seq != nil { existingMessage.seq = message.seq }
            if message.inputTokens != nil { existingMessage.inputTokens = message.inputTokens }
            if message.outputTokens != nil { existingMessage.outputTokens = message.outputTokens }
            if message.cacheRead != nil { existingMessage.cacheRead = message.cacheRead }
            if message.cacheWrite != nil { existingMessage.cacheWrite = message.cacheWrite }
            vm.messages[existingIndex] = existingMessage
            AppLogger.log("updated message: \(message.id), text length: \(existingMessage.text.count), FINAL state: \(existingMessage.state)", category: .nativeChat)
        } else {
            let similarIndex = vm.messages.firstIndex { existing in
                existing.role == message.role &&
                existing.text == message.text &&
                abs(existing.timestamp.timeIntervalSince(message.timestamp)) < 60.0
            }
            if let similarIndex = similarIndex {
                var existingMessage = vm.messages[similarIndex]
                AppLogger.log("receiveMessage similar-match - newId=\(String(message.id.prefix(8))) existingId=\(String(existingMessage.id.prefix(8))) idx=\(similarIndex) state=\(message.state)", category: .nativeChat)
                if !message.text.isEmpty {
                    existingMessage.text = message.text
                }
                existingMessage.state = message.state
                if message.startedAt != nil { existingMessage.startedAt = message.startedAt }
                if message.endedAt != nil { existingMessage.endedAt = message.endedAt }
                if message.livenessState != nil { existingMessage.livenessState = message.livenessState }
                if message.seq != nil { existingMessage.seq = message.seq }
                if message.inputTokens != nil { existingMessage.inputTokens = message.inputTokens }
                if message.outputTokens != nil { existingMessage.outputTokens = message.outputTokens }
                if message.cacheRead != nil { existingMessage.cacheRead = message.cacheRead }
                if message.cacheWrite != nil { existingMessage.cacheWrite = message.cacheWrite }
                vm.messages[similarIndex] = existingMessage
            } else {
                if let last = vm.messages.last, last.state != "final" {
                    vm.messages.insert(message, at: vm.messages.count - 1)
                    AppLogger.log("receiveMessage new (inserted before last, lastState=\(last.state)) - id: \(String(message.id.prefix(8))), text len: \(message.text.count), state: \(message.state)", category: .nativeChat)
                } else {
                    vm.messages.append(message)
                    AppLogger.log("receiveMessage new (appended) - id: \(String(message.id.prefix(8))), text len: \(message.text.count), state: \(message.state)", category: .nativeChat)
                }
            }
        }
        // Single scroll request per receiveMessage call regardless of
        // which merge path was taken (id-match, similar-match, or fresh
        // insert). Multiple fires in the same beat used to compound with
        // HistoryLoader's triggers to produce visible jitter.
        vm.scrollRequest = NativeChatScrollRequest(token: vm.scrollRequest.token &+ 1, kind: .newMessage)
        if message.state == "final" {
            // Intentionally do NOT write the streaming copy to the
            // cache here. The agent-end event payload does not carry
            // usage tokens, so the streaming copy's dedup key
            // (`role|text|bucket|usage`) differs from the network's
            // server-stored message (which has the full usage).
            // Writing the streaming copy would cause both versions
            // to land in the cache — and on re-entry, both would
            // display, with the streaming copy missing the 4 token
            // values. loadHistory's network fetch is the
            // authoritative cache writer and runs on every entry.
            vm.isSending = false
        }
    }

    /// Append new messages from the transport without going through dedup.
    /// Used for bulk operations (not currently exercised by any caller
    /// in the production code path, but kept for parity with the VM's
    /// pre-refactor surface).
    func appendNewMessages(_ newMessages: [ChatMessage]) {
        guard let vm = viewModel else { return }
        if newMessages.isEmpty {
            AppLogger.log("appendNewMessages - no new messages", category: .nativeChat)
            return
        }
        AppLogger.log("appendNewMessages appending \(newMessages.count) messages", category: .nativeChat)
        vm.messages.append(contentsOf: newMessages)
        vm.scrollRequest = NativeChatScrollRequest(token: vm.scrollRequest.token &+ 1, kind: .newMessage)
    }
}
