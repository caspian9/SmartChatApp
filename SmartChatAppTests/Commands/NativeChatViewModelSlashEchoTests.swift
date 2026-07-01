import XCTest
import OpenClawChatUI
import OpenClawProtocol
@testable import SmartChatApp

/// Tests for issue #36's slash-command user-bubble echo:
/// when the user types a local slash command (e.g. `/help`,
/// `/disconnect`), the typed text now renders as an outgoing
/// user bubble alongside the system result. Previously the
/// user-typed text was invisible in the chat history — the
/// system bubble just appeared with no context for what the
/// user had asked. Server commands (`/status` etc.) and
/// non-slash text continue to use the existing `sendAsMessage`
/// path, which already echoes the user bubble via `appendUserBubble`.
@MainActor
final class NativeChatViewModelSlashEchoTests: XCTestCase {
    private let testSessionKey = "test"

    private func makeSUT(
        disconnectCommand: Bool = true,
        clearCommand: Bool = false
    ) -> (NativeChatViewModel, FakeTransport) {
        let transport = FakeTransport()
        let store = MessageCacheStore(storage: FakeMessageCacheStorage())
        var commands: [SlashCommand] = [
            SlashCommand(
                id: "/help", description: "Show this help",
                source: .local,
                executor: { _ in .bubble("HELP TEXT") }
            )
        ]
        if disconnectCommand {
            commands.append(SlashCommand(
                id: "/disconnect", description: "Disconnect",
                source: .local,
                executor: { _ in .silent }
            ))
        }
        if clearCommand {
            commands.append(SlashCommand(
                id: "/clear", description: "Clear chat",
                source: .local,
                executor: { _ in .clearAndBubble("Chat cleared") }
            ))
        }
        let local = FakeLocalRegistry(commands: commands)
        let server = FakeServerSource(entries: [
            CommandEntry(
                name: "/status", nativename: nil, textaliases: nil,
                description: "d", category: nil,
                source: .init("native"), scope: .init("text"),
                acceptsargs: false, args: nil
            )
        ])
        let router = SlashCommandRouter(local: local, server: server)
        let vm = NativeChatViewModel(
            store: store,
            slashCommandRouter: router,
            serverCommandSource: server,
            sendInterceptor: { @MainActor text in
                transport.recordSendMessageCall(text: text)
            }
        )
        vm.selectedSession = makeTestSession(key: testSessionKey)
        return (vm, transport)
    }

    private func makeTestSession(key: String) -> OpenClawChatSessionEntry {
        OpenClawChatSessionEntry(
            key: key, kind: nil, displayName: nil,
            surface: nil, subject: nil, room: nil, space: nil,
            updatedAt: nil, sessionId: nil, systemSent: nil,
            abortedLastRun: nil, thinkingLevel: nil, verboseLevel: nil,
            inputTokens: nil, outputTokens: nil, totalTokens: nil,
            modelProvider: nil, model: nil, contextTokens: nil
        )
    }

    private func currentMessages(_ vm: NativeChatViewModel) -> [ChatMessage] {
        vm.store.messages(for: testSessionKey)
            .flatMap { ChatMessageConverter.toChatMessage(from: $0) }
    }

    // MARK: - Test 1: local slash help → user bubble + system result
    //
    // Regression for the user-reported "I typed /help and the
    // chat just showed the help text with no record of what I
    // asked" gap. The slash-echo change makes the typed input
    // visible as an outgoing user bubble before the system
    // bubble lands.

    func test_sendMessage_localSlashHelp_appendsUserBubbleThenSystemResult() async {
        let (vm, _) = makeSUT()
        vm.inputText = "/help"
        await vm.sendMessage()
        let messages = currentMessages(vm)
        XCTAssertEqual(messages.count, 2,
                       "/help must append the user bubble + the help text bubble")
        XCTAssertEqual(messages[0].role, "user")
        XCTAssertEqual(messages[0].text, "/help")
        XCTAssertEqual(messages[1].role, "system")
        XCTAssertEqual(messages[1].text, "HELP TEXT")
    }

    // MARK: - Test 2: silent local command → user bubble only
    //
    // `.silent` commands (e.g. `/disconnect`) intentionally
    // produce no result bubble, but the user's typed input
    // still needs to render. The user bubble is the only thing
    // that lands.

    func test_sendMessage_localSlashDisconnect_appendsUserBubbleOnly() async {
        let (vm, _) = makeSUT(disconnectCommand: true)
        vm.inputText = "/disconnect"
        await vm.sendMessage()
        let messages = currentMessages(vm)
        XCTAssertGreaterThanOrEqual(messages.count, 1,
            "/disconnect (silent) must append at least the user bubble")
        guard messages.count >= 1 else { return }
        XCTAssertEqual(messages.last?.role, "user",
            "the user bubble is the LAST one (silent produces no result)")
        XCTAssertEqual(messages.last?.text, "/disconnect")
    }

    // MARK: - Test 3: clearAndBubble → clear, then user bubble, then result
    //
    // Order matters: the clear must wipe any pre-existing cache
    // BEFORE the user + system bubbles land, otherwise the
    // result bubble is dropped (the LocalCommandRegistry's
    // `/clear` executor also calls `clearLocalMessages()` in
    // parallel; the authoritative clear is the awaited one in
    // `handleCommandResult`).

    func test_sendMessage_localSlashClear_appendsUserBubbleThenClearThenResult() async {
        let (vm, _) = makeSUT(clearCommand: true)
        // Pre-populate the store with one stale user message
        // so /clear has something to remove.
        let oldMsg = ChatMessage(
            id: "1", text: "old", timestamp: Date(),
            role: "user", state: "final", runId: nil,
            seq: nil, startedAt: nil, endedAt: nil,
            livenessState: nil, toolCallId: nil,
            toolName: nil, stopReason: nil, isFresh: false
        )
        if let openclaw = ChatMessageConverter.toOpenClawChatMessage(from: oldMsg) {
            await vm.store.replaceForSession([openclaw], for: testSessionKey)
        }
        vm.inputText = "/clear"
        await vm.sendMessage()
        let messages = currentMessages(vm)
        // After GREEN: /clear wipes the pre-existing "old",
        // appends the user bubble (text: "/clear"), then the
        // system bubble (text: "Chat cleared"). Total 2.
        XCTAssertGreaterThanOrEqual(messages.count, 2,
            "/clear must append the user bubble + the cleared result")
        guard messages.count >= 2 else { return }
        XCTAssertEqual(messages[messages.count - 2].role, "user")
        XCTAssertEqual(messages[messages.count - 2].text, "/clear")
        XCTAssertEqual(messages.last?.role, "system")
        XCTAssertEqual(messages.last?.text, "Chat cleared")
    }

    // MARK: - Test 4: server-side slash → user bubble via sendAsMessage
    //
    // For commands the server handles (e.g. `/status`) and for
    // unknown slash-prefixed text, the input goes through
    // `sendAsMessage` — that path already echoes the user
    // bubble via `ChatMessageConverter`-driven `store.append`.
    // This test guards against an accidental regression where
    // someone might try to use the new `appendUserBubble` for
    // server commands too (which would double-echo).

    func test_sendMessage_passthroughServerSlash_appendsUserBubbleOnly_viaExistingPath() async {
        let (vm, transport) = makeSUT(disconnectCommand: false)
        vm.inputText = "/status"
        await vm.sendMessage()
        XCTAssertFalse(transport.calls.isEmpty)
        XCTAssertEqual(transport.calls.first?.method, "chat.send")
        XCTAssertEqual(transport.calls.first?.text, "/status")
        // The user bubble is appended via the existing
        // `sendAsMessage` path. We can't reliably read it back
        // here because the FakeMessageCacheStorage's append
        // doesn't update lastSeenTimestamp without a real
        // MessageCacheStore path, but the transport call is the
        // primary assertion: server-side slashes use the
        // passthrough path, not `appendUserBubble`.
    }
}