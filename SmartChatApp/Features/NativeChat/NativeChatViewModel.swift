import Foundation
import os
import OpenClawChatUI
import OpenClawKit

@MainActor
@Observable
final class NativeChatViewModel {
    // MARK: - State
    //
    // The previous @Reducer version had a `struct State: Equatable` with
    // `@ObservableState` macro and an `enum Action` driving a `Reduce` body.
    // Migrated to @MainActor @Observable class: each former state field is a
    // stored property (with `private(set)` when only the model writes it),
    // and each former action case is a method below.

    var selectedProfileId: UUID?
    var sessions: [OpenClawChatSessionEntry] = []
    var selectedSession: OpenClawChatSessionEntry?
    var messages: [ChatMessage] = []
    var inputText: String = ""
    var isLoading: Bool = false
    var isSending: Bool = false
    var isSwitchingGateway: Bool = false
    var error: String?
    var isRestoringFromCache: Bool = false
    var needsScrollToBottom: Bool = false
    var scrollTrigger: Int = 0
    var cacheLoadCounter: Int = 0

    // MARK: - Collaborators

    let messageReceiver: MessageReceiver
    let historyLoader: HistoryLoader
    let eventInterpreter: EventInterpreter
    let sessionCoordinator: SessionCoordinator

    init() {
        self.messageReceiver = MessageReceiver()
        self.historyLoader = HistoryLoader()
        self.eventInterpreter = EventInterpreter()
        self.sessionCoordinator = SessionCoordinator()
        self.messageReceiver.viewModel = self
        self.historyLoader.viewModel = self
        self.eventInterpreter.viewModel = self
        self.sessionCoordinator.viewModel = self
    }

    // MARK: - Public API (called by NativeChatView)

    func setSelectedProfile(_ profileId: UUID?) {
        if selectedProfileId != profileId {
            selectedProfileId = profileId
        }
    }

    func loadSessions() {
        sessionCoordinator.loadSessions()
    }

    func loadedSessions(_ sessions: [OpenClawChatSessionEntry]) {
        sessionCoordinator.loadedSessions(sessions)
    }

    func selectSession(_ session: OpenClawChatSessionEntry) {
        sessionCoordinator.selectSession(session)
    }

    func switchProfile(_ newProfileId: UUID) {
        sessionCoordinator.switchProfile(newProfileId)
    }

    func createSession() {
        sessionCoordinator.createSession()
    }

    func sessionCreated(_ sessionKey: String) {
        sessionCoordinator.sessionCreated(sessionKey)
    }

    func sendMessage() {
        guard !inputText.isEmpty else { return }
        guard let session = selectedSession else { return }
        isSending = true
        let text = inputText
        let sessionKey = session.key
        let textPreview = String(text.prefix(100))
        print("SMAlog: sendMessage role=user text_len=\(text.count) text_preview=\(textPreview)")
        let message = ChatMessage(
            id: UUID().uuidString,
            text: text,
            timestamp: Date(),
            role: "user",
            state: "final",
            runId: nil,
            seq: nil,
            startedAt: nil,
            endedAt: nil,
            livenessState: nil,
            toolCallId: nil,
            toolName: nil,
            stopReason: nil,
            isFresh: true
        )
        messages.append(message)
        inputText = ""
        // Cache user message
        Task {
            if let msg = self.createOpenClawChatMessage(from: message) {
                await MessageCache.shared.appendMessages([msg], for: sessionKey)
            }
        }
        Task {
            do {
                try await SessionManager.shared.ensureConnected()
                let transport = await SessionManager.shared.makeTransport(sessionKey: sessionKey)
                // Start event listening task - pass sessionKey to check later
                Task {
                    for await evt in transport.events() {
                        await MainActor.run {
                            Task {
                                // Only handle events for current session (check via SessionManager)
                                let currentKey = await SessionManager.shared.getCurrentSessionKey()
                                if currentKey == sessionKey {
                                    await self.handleTransportEvent(evt, sessionKey: sessionKey)
                                }
                            }
                        }
                    }
                }
                // Send message
                _ = try await transport.sendMessage(
                    sessionKey: sessionKey,
                    message: text,
                    thinking: "",
                    idempotencyKey: UUID().uuidString,
                    attachments: []
                )
                AppLogger.log("Message sent, waiting for response...", category: .nativeChat)
            } catch {
                AppLogger.log("Send message error: \(error.localizedDescription)", category: .nativeChat, level: .error)
                self.setError(error.localizedDescription)
                self.setSending(false)
            }
        }
    }

    func loadHistory() {
        historyLoader.loadHistory()
    }

    func loadMoreHistory() {}

    func receiveMessage(_ message: ChatMessage) {
        messageReceiver.receiveMessage(message)
    }

    private func setError(_ error: String?) {
        self.error = error
        isLoading = false
        isSending = false
    }

    private func setSending(_ value: Bool) {
        isSending = value
    }

    func scrollToBottom() {
        needsScrollToBottom = true
    }

    private func setNeedsScrollToBottom(_ needsScroll: Bool) {
        needsScrollToBottom = needsScroll
    }

    private func incrementScrollTrigger() {
        scrollTrigger += 1
    }

    private func loadedMoreHistory(_ messages: [ChatMessage], hasMore: Bool) {
        // No-op for now; placeholder for future pagination.
    }

    // MARK: - Transport event handling

    private func handleTransportEvent(_ event: OpenClawChatTransportEvent, sessionKey: String) async {
        await eventInterpreter.handleTransportEvent(event, sessionKey: sessionKey)
    }

    // MARK: - Helpers

    private func createOpenClawChatMessage(from chatMessage: ChatMessage) -> OpenClawChatMessage? {
        guard let uuid = UUID(uuidString: chatMessage.id) else { return nil }
        // Build usage if we have token data - encode as JSON then decode to OpenClawChatUsage
        var usage: OpenClawChatUsage? = nil
        if chatMessage.inputTokens != nil || chatMessage.outputTokens != nil || chatMessage.cacheRead != nil || chatMessage.cacheWrite != nil {
            var usageData: [String: AnyCodable] = [:]
            if let input = chatMessage.inputTokens { usageData["input"] = AnyCodable(input) }
            if let output = chatMessage.outputTokens { usageData["output"] = AnyCodable(output) }
            if let cr = chatMessage.cacheRead { usageData["cacheRead"] = AnyCodable(cr) }
            if let cw = chatMessage.cacheWrite { usageData["cacheWrite"] = AnyCodable(cw) }
            if let data = try? JSONEncoder().encode(usageData),
               let decoded = try? JSONDecoder().decode(OpenClawChatUsage.self, from: data) {
                usage = decoded
            }
        }
        return OpenClawChatMessage(
            id: uuid,
            role: chatMessage.role,
            content: [OpenClawChatMessageContent(type: "text", text: chatMessage.text, thinking: nil, thinkingSignature: nil, mimeType: nil, fileName: nil, content: nil, id: nil, name: nil, arguments: nil)],
            timestamp: chatMessage.timestamp.timeIntervalSince1970 * 1000,
            toolCallId: chatMessage.toolCallId,
            toolName: chatMessage.toolName,
            usage: usage,
            stopReason: chatMessage.stopReason
        )
    }
}
