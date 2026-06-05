import SwiftUI

struct NativeChatView: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var profileManager = ProfileManager.shared
    @State private var viewModel = NativeChatViewModel()
    @FocusState private var isInputFocused: Bool
    @State private var isUserScrolling = false
    @State private var scrollToMessageId: String?
    @State private var triggerCount: Int = 0
    @State private var cacheLoadTriggerCount: Int = 0

    init() {
        AppLogger.log("NativeChatView init", category: .nativeChat)
    }

    var body: some View {
        content
            .background(theme.background)
            .navigationTitle("NativeChat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarItem }
            .onAppear {
                AppLogger.log("NativeChatView onAppear called", category: .nativeChat)
                if viewModel.selectedProfileId == nil {
                    viewModel.setSelectedProfile(profileManager.activeProfile?.id)
                }
                viewModel.loadSessions()
            }
            .onChange(of: profileManager.profiles) { _ in
                if let selectedId = viewModel.selectedProfileId,
                   !profileManager.profiles.contains(where: { $0.id == selectedId }) {
                    viewModel.setSelectedProfile(profileManager.activeProfile?.id)
                }
            }
    }

    private var toolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(action: { viewModel.createSession() }) {
                Image(systemName: "plus").foregroundColor(theme.primary)
            }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            sessionPicker
            scrollView
            chatInput
        }
    }

    @ViewBuilder
    private var sessionPicker: some View {
        if !viewModel.sessions.isEmpty {
            SessionPickerView(
                sessions: viewModel.sessions,
                selectedSession: Binding(
                    get: { viewModel.selectedSession },
                    set: { newValue in
                        if let s = newValue { viewModel.selectSession(s) }
                    }
                ),
                profiles: profileManager.profiles,
                selectedProfileId: viewModel.selectedProfileId,
                onProfileChange: { newId in
                    viewModel.switchProfile(newId)
                }
            )
        } else if !profileManager.profiles.isEmpty {
            // No sessions yet, but show gateway picker
            SessionPickerView(
                sessions: [],
                selectedSession: .constant(nil),
                profiles: profileManager.profiles,
                selectedProfileId: viewModel.selectedProfileId,
                onProfileChange: { newId in
                    viewModel.switchProfile(newId)
                }
            )
        }
    }

    private var scrollView: some View {
        messageScrollView
    }

    @ViewBuilder
    private var messageScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                messageList
            }
            // No `.defaultScrollAnchor(.bottom)`: that modifier re-anchors
            // on *any* content-size change, including the height growth
            // from a "show more" expansion. When a user scrolls into a
            // history view and expands a bubble, the chat's total height
            // grows and the anchor yanks the viewport down to the new
            // bottom, making the bubble appear to expand *upward* into
            // the viewport. We rely on the explicit `scrollTo` calls
            // below (scrollTrigger for streaming text, isSending for
            // stream end, messages.count for new messages, needsScroll-
            // ToBottom for explicit requests, cacheLoadCounter for
            // history load) to position the viewport deliberately.
            .onTapGesture { isInputFocused = false }
            .onAppear {
                AppLogger.log("messageScrollView onAppear, messages: \(viewModel.messages.count)", category: .nativeChat)
            }
            .onChange(of: viewModel.messages.count) { count in
                AppLogger.log("messages.count changed to \(count)", category: .nativeChat)
                if !isUserScrolling {
                    scheduleScroll(proxy: proxy)
                }
            }
            .onChange(of: viewModel.scrollTrigger) { [self] newValue in
                guard newValue != triggerCount else { return }
                triggerCount = newValue
                let lastId = viewModel.messages.last?.id
                AppLogger.log("scrollTrigger changed to \(newValue), lastId: \(lastId?.prefix(8) ?? "nil")", category: .nativeChat)
                if let id = lastId {
                    AppLogger.log("triggering immediate scroll to \(String(id.prefix(8)))", category: .nativeChat)
                    DispatchQueue.main.async {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: viewModel.cacheLoadCounter) { [self] newValue in
                guard newValue != cacheLoadTriggerCount else { return }
                cacheLoadTriggerCount = newValue
                let lastId = viewModel.messages.last?.id
                AppLogger.log("cacheLoadCounter changed to \(newValue), lastId: \(lastId?.prefix(8) ?? "nil")", category: .nativeChat)
                if let id = lastId {
                    // Multi-poll scroll: history-load bubbles render through
                    // UIViewRepresentable (MarkdownCardView) which measures
                    // its content height asynchronously on the UIKit thread.
                    // The first scrollTo races with the layout pass — the
                    // visible viewport is still showing the empty/short
                    // initial frame. The follow-up polls catch the bubble
                    // once MarkdownViewTextKit has actually measured in.
                    // Poll window is 0..2s to cover long histories on slower
                    // devices. Safe to multi-poll here because
                    // cacheLoadCounter never fires during streaming, so
                    // this does not reintroduce the send-time scroll
                    // stutter.
                    AppLogger.log("cacheLoadCounter triggering multi-poll scroll to \(String(id.prefix(8)))", category: .nativeChat)
                    for delay in [0.0, 0.2, 0.5, 1.0, 2.0] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            proxy.scrollTo(id, anchor: .bottom)
                        }
                    }
                }
            }
            .onChange(of: viewModel.needsScrollToBottom) { needsScroll in
                if needsScroll {
                    let lastId = viewModel.messages.last?.id
                    AppLogger.log("needsScrollToBottom true, lastId: \(lastId?.prefix(8) ?? "nil")", category: .nativeChat)
                    if let id = lastId {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: viewModel.isSending) { isSending in
                AppLogger.log("isSending changed to \(isSending)", category: .nativeChat)
                if !isSending {
                    isUserScrolling = false
                    // isSending false means the chat input flipped from
                    // ProgressView (~20pt) back to the send Button (32pt),
                    // adding ~12pt to the input's height and shrinking the
                    // ScrollView's frame. `.defaultScrollAnchor(.bottom)`
                    // only re-anchors on content-size changes, not on the
                    // ScrollView's own frame changes — so the bottom of the
                    // content falls outside the viewport. Explicitly scroll
                    // to the last message to recover the bottom.
                    if let id = viewModel.messages.last?.id {
                        DispatchQueue.main.async {
                            proxy.scrollTo(id, anchor: .bottom)
                        }
                    }
                }
            }
            .onChange(of: isInputFocused) { focused in
                AppLogger.log("isInputFocused changed to \(focused)", category: .nativeChat)
                if !isUserScrolling {
                    scheduleScroll(proxy: proxy)
                }
            }
        }
    }

    private func scheduleScroll(proxy: ScrollViewProxy) {
        let lastId = viewModel.messages.last?.id
        guard let id = lastId else { return }
        AppLogger.log("scheduleScroll to \(String(id.prefix(8))), isUserScrolling: \(isUserScrolling)", category: .nativeChat)
        // Single delayed scroll. The 5-poll variant was originally to catch
        // delayed layout, but combined with SwiftUI's scroll animation it
        // produced a visible up-down stutter when the keyboard dismissed
        // and a new message landed in the same beat. The ScrollView's
        // `.defaultScrollAnchor(.bottom)` handles the steady-state growth;
        // this single call is the safety net for the residual case.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            proxy.scrollTo(id, anchor: .bottom)
        }
    }

    private var messageList: some View {
        LazyVStack(spacing: 0) {
            ForEach(viewModel.messages) { message in
                MessageBubbleView(message: message)
                    .id(message.id)
            }
        }
        .padding(.vertical, 8)
    }

    private var chatInput: some View {
        ChatInputView(
            inputText: Binding(
                get: { viewModel.inputText },
                set: { newValue in
                    viewModel.inputText = newValue
                    isUserScrolling = false
                }
            ),
            isSending: viewModel.isSending,
            onSend: {
                isUserScrolling = false
                isInputFocused = false
                viewModel.sendMessage()
            }
        )
        .focused($isInputFocused)
    }
}
