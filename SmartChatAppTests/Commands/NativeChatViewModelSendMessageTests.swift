import XCTest
import OpenClawChatUI
import OpenClawProtocol
@testable import SmartChatApp

@MainActor
final class NativeChatViewModelSendMessageTests: XCTestCase {
    private let testSessionKey = "test"

    private func makeSUT() -> (
        NativeChatViewModel, FakeTransport,
        FakeLocalRegistry, FakeServerSource
    ) {
        let transport = FakeTransport()
        // Per-test isolated store: avoid `MessageCacheStore.shared`
        // (which is a singleton backed by on-disk UserDefaults) so
        // prior tests' messages don't leak into this test's
        // assertions.
        let store = MessageCacheStore(storage: FakeMessageCacheStorage())
        let local = FakeLocalRegistry(commands: [
            SlashCommand(
                id: "/help", description: "Show this help",
                source: .local,
                executor: { _ in .bubble("HELP TEXT") }
            ),
            SlashCommand(
                id: "/clear", description: "Clear chat",
                source: .local,
                executor: { _ in .clearAndBubble("Chat cleared") }
            )
        ])
        let server = FakeServerSource(entries: [
            CommandEntry(
                name: "/status", nativename: nil, textaliases: nil,
                description: "d", category: nil,
                source: .init("native"), scope: .init("text"),
                acceptsargs: false, args: nil
            )
        ])
        let router = SlashCommandRouter(local: local, server: server)
        // The interceptor closure stands in for the real
        // SessionManager plumbing. In production the VM goes
        // straight to `SessionManager.shared.ensureConnected()` +
        // `makeTransport(...)`; in tests the closure records the
        // call on the FakeTransport and returns immediately.
        let vm = NativeChatViewModel(
            store: store,
            slashCommandRouter: router,
            serverCommandSource: server,
            sendInterceptor: { @MainActor text in
                transport.recordSendMessageCall(text: text)
            }
        )
        vm.selectedSession = makeTestSession(key: testSessionKey)
        return (vm, transport, local, server)
    }

    /// Reads the VM's persisted chat history for `testSessionKey`
    /// via `MessageCacheStore` (the SoT after the message-cache-sot
    /// refactor) and converts back to `ChatMessage` for assertions.
    /// Flattens because each `OpenClawChatMessage` may carry
    /// multiple `ChatMessage` parts.
    private func currentMessages(_ vm: NativeChatViewModel) -> [ChatMessage] {
        vm.store.messages(for: testSessionKey)
            .flatMap { ChatMessageConverter.toChatMessage(from: $0) }
    }

    private func makeTestSession(key: String) -> OpenClawChatSessionEntry {
        OpenClawChatSessionEntry(
            key: key,
            kind: nil,
            displayName: nil,
            surface: nil,
            subject: nil,
            room: nil,
            space: nil,
            updatedAt: nil,
            sessionId: nil,
            systemSent: nil,
            abortedLastRun: nil,
            thinkingLevel: nil,
            verboseLevel: nil,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: nil,
            modelProvider: nil,
            model: nil,
            contextTokens: nil
        )
    }

    // --- Category A: pure local ---

    func test_sendMessage_localCategoryA_createsSystemBubble_noTransportCall() async {
        let (vm, transport, _, _) = makeSUT()
        vm.inputText = "/help"
        await vm.sendMessage()
        let messages = currentMessages(vm)
        // Issue #36: the user's typed input is now echoed as a
        // user-role bubble alongside the system result (was just
        // the system bubble pre-#36). Order: user (typed "/help")
        // then system ("HELP TEXT").
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].role, "user")
        XCTAssertEqual(messages[0].text, "/help")
        XCTAssertEqual(messages[1].role, "system")
        XCTAssertEqual(messages[1].text, "HELP TEXT")
        XCTAssertTrue(transport.calls.isEmpty,
            "Category A must not call transport")
    }

    // --- Category B: local aggregation ---

    func test_sendMessage_localCategoryB_clearAndBubble() async {
        let (vm, transport, _, _) = makeSUT()
        // Pre-populate the cache store with one stale user message
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
        // Issue #36: the user's typed "/clear" is now echoed as
        // a user-role bubble alongside the cleared result.
        // Order: user (typed "/clear"), system ("Chat cleared").
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].role, "user")
        XCTAssertEqual(messages[0].text, "/clear")
        XCTAssertEqual(messages[1].role, "system")
        XCTAssertEqual(messages[1].text, "Chat cleared")
        XCTAssertTrue(transport.calls.isEmpty)
    }

    // --- Category C: server-known ---

    func test_sendMessage_serverCategoryC_sendsAsMessage() async {
        let (vm, transport, _, _) = makeSUT()
        vm.inputText = "/status"
        await vm.sendMessage()
        XCTAssertFalse(transport.calls.isEmpty)
        XCTAssertEqual(transport.calls.first?.method, "chat.send")
        XCTAssertEqual(transport.calls.first?.text, "/status")
    }

    // --- Category D: unknown ---

    func test_sendMessage_unknownCategoryD_sendsAsMessage() async {
        let (vm, transport, _, _) = makeSUT()
        vm.inputText = "/foo"
        await vm.sendMessage()
        XCTAssertFalse(transport.calls.isEmpty)
        XCTAssertEqual(transport.calls.first?.text, "/foo")
    }

    // --- Non-slash: unchanged behavior ---

    func test_sendMessage_nonSlash_unchangedBehavior() async {
        let (vm, transport, _, _) = makeSUT()
        vm.inputText = "hello"
        await vm.sendMessage()
        XCTAssertFalse(transport.calls.isEmpty)
        XCTAssertEqual(transport.calls.first?.text, "hello")
    }

    // --- Local priority: server entry shadowed by local ---

    func test_sendMessage_localPriorityOverServer() async {
        // Override the local /status to verify local wins.
        let transport = FakeTransport()
        let local = FakeLocalRegistry(commands: [
            SlashCommand(
                id: "/status", description: "local-status",
                source: .local,
                executor: { _ in .bubble("LOCAL") }
            )
        ])
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
            store: MessageCacheStore(storage: FakeMessageCacheStorage()),
            slashCommandRouter: router,
            serverCommandSource: server,
            sendInterceptor: { @MainActor text in
                transport.recordSendMessageCall(text: text)
            }
        )
        vm.selectedSession = makeTestSession(key: testSessionKey)
        vm.inputText = "/status"
        await vm.sendMessage()
        // Issue #36: local /status now echoes the user bubble too.
        XCTAssertEqual(currentMessages(vm).first?.text, "/status")
        XCTAssertEqual(currentMessages(vm).last?.text, "LOCAL")
        XCTAssertTrue(transport.calls.isEmpty)
    }

    // --- Executor throw ---

    func test_sendMessage_executorThrow_createsErrorBubble() async {
        struct Boom: Error { var localizedDescription: String { "kapow" } }
        let transport = FakeTransport()
        let local = FakeLocalRegistry(commands: [
            SlashCommand(
                id: "/boom", description: "d", source: .local,
                executor: { _ in throw Boom() }
            )
        ])
        let server = FakeServerSource(entries: [])
        let router = SlashCommandRouter(local: local, server: server)
        let vm = NativeChatViewModel(
            store: MessageCacheStore(storage: FakeMessageCacheStorage()),
            slashCommandRouter: router,
            serverCommandSource: server,
            sendInterceptor: { @MainActor text in
                transport.recordSendMessageCall(text: text)
            }
        )
        vm.selectedSession = makeTestSession(key: testSessionKey)
        vm.inputText = "/boom"
        await vm.sendMessage()
        // Issue #36: the user's typed "/boom" is now echoed
        // before the error result. So the error bubble is the
        // LAST one, not the first.
        let messages = currentMessages(vm)
        XCTAssertEqual(messages.first?.text, "/boom",
            "user bubble echoes the typed input first")
        XCTAssertTrue(messages.last?.text.contains("Command failed") ?? false,
            "error bubble lands after the user echo")
    }
}