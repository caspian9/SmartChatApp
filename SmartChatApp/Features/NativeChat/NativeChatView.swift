import SwiftUI

struct NativeChatView: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var profileManager = ProfileManager.shared
    @State private var viewModel = NativeChatViewModel()
    @FocusState private var isInputFocused: Bool
    /// Sticky flag: once the user has touched the scroll view, auto-scroll
    /// stops. Set by `.onScrollPhaseChange` when the phase becomes
    /// `.interacting` or `.decelerating`. Reset implicitly when the view
    /// identity is recreated (next time the user enters NativeChat). This
    /// prevents the historyLoaded multi-poll cascade and incoming-message
    /// scrolls from yanking the user back to the bottom while they're
    /// reading history above.
    @State private var userHasScrolled = false

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
            .onChange(of: profileManager.profiles) { _, _ in
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
            // the viewport. All scroll positioning is driven by the
            // single `scrollRequest` onChange below plus `isSending`
            // (send button ↔ ProgressView frame change) and `isInputFocused`
            // (keyboard up/down).
            .onTapGesture { isInputFocused = false }
            .onAppear {
                AppLogger.log("messageScrollView onAppear, messages: \(viewModel.messages.count)", category: .nativeChat)
            }
            .onScrollPhaseChange { _, newPhase in
                // `.interacting` fires while the user is actively
                // dragging; `.decelerating` covers the post-release
                // momentum. Either means the user has indicated scroll
                // intent, so future auto-scrolls are blocked. The flag is
                // sticky until the view is recreated — to resume
                // auto-scroll, the user leaves and re-enters NativeChat.
                if newPhase == .interacting || newPhase == .decelerating {
                    if !userHasScrolled {
                        AppLogger.log("userHasScrolled set to true (phase=\(newPhase))", category: .nativeChat)
                    }
                    userHasScrolled = true
                }
            }
            .onChange(of: viewModel.scrollRequest.token) { _, _ in
                let kind = viewModel.scrollRequest.kind
                let lastId = viewModel.messages.last?.id
                AppLogger.log("scrollRequest kind=\(kind), lastId: \(lastId?.prefix(8) ?? "nil"), userHasScrolled: \(userHasScrolled)", category: .nativeChat)
                guard let id = lastId else { return }
                switch kind {
                case .newMessage:
                    // Single scroll. Streaming deltas hit the id-match
                    // path in MessageReceiver — `lastId` is unchanged, so
                    // scrollTo is a no-op once at the bottom. A fresh
                    // append (user message, new tool bubble) lands at the
                    // bottom and gets a single scroll. Gated on
                    // `!userHasScrolled` so a user reading above is not
                    // yanked to the bottom by an incoming message.
                    if !userHasScrolled {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                case .historyLoaded:
                    // Multi-poll scroll: history-load bubbles render through
                    // UIViewRepresentable (MarkdownCardView) which measures
                    // its content height asynchronously on the UIKit thread.
                    // The first scrollTo races with the layout pass — the
                    // visible viewport is still showing the empty/short
                    // initial frame. The follow-up polls catch the bubble
                    // once MarkdownViewTextKit has actually measured in.
                    // Poll window is 0..2s to cover long histories on slower
                    // devices. Each poll checks `userHasScrolled` at
                    // execution time so the user can scroll up between
                    // polls to abort the cascade.
                    AppLogger.log("historyLoaded triggering multi-poll scroll to \(String(id.prefix(8))), userHasScrolled: \(userHasScrolled)", category: .nativeChat)
                    for delay in [0.0, 0.2, 0.5, 1.0, 2.0] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            if !userHasScrolled {
                                proxy.scrollTo(id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
            .onChange(of: viewModel.isSending) { _, isSending in
                AppLogger.log("isSending changed to \(isSending)", category: .nativeChat)
                if !isSending {
                    // isSending false means the chat input flipped from
                    // ProgressView (~20pt) back to the send Button (32pt),
                    // adding ~12pt to the input's height and shrinking the
                    // ScrollView's frame. `.defaultScrollAnchor(.bottom)`
                    // only re-anchors on content-size changes, not on the
                    // ScrollView's own frame changes — so the bottom of the
                    // content falls outside the viewport. Explicitly scroll
                    // to the last message to recover the bottom. Gated on
                    // `!userHasScrolled` so a user reading above is not
                    // yanked back when the input resizes.
                    if !userHasScrolled, let id = viewModel.messages.last?.id {
                        DispatchQueue.main.async {
                            proxy.scrollTo(id, anchor: .bottom)
                        }
                    }
                }
            }
            .onChange(of: isInputFocused) { _, focused in
                AppLogger.log("isInputFocused changed to \(focused)", category: .nativeChat)
                if !userHasScrolled, let id = viewModel.messages.last?.id {
                    DispatchQueue.main.async {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
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
                }
            ),
            isSending: viewModel.isSending,
            onSend: {
                isInputFocused = false
                viewModel.sendMessage()
            }
        )
        .focused($isInputFocused)
    }
}
