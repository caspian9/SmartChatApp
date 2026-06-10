import SwiftUI

struct NativeChatView: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var profileManager = ProfileManager.shared
    @State private var viewModel = NativeChatViewModel()
    /// Observes user-driven expand state changes. The collapse cache is
    /// `@Published`-based (`ObservableObject`); the view's `messages`
    /// computed property reads `expandedMessageIds` to apply it per
    /// bubble, so SwiftUI needs this dependency to invalidate `body`
    /// when the user toggles a "Show more..." button.
    @ObservedObject private var collapseCache = CollapseStateCache.shared
    @FocusState private var isInputFocused: Bool
    /// Sticky flag: once the user has touched the scroll view, auto-scroll
    /// stops. Set by `.onScrollPhaseChange` when the phase becomes
    /// `.interacting` or `.decelerating`. Reset implicitly when the view
    /// identity is recreated (next time the user enters NativeChat). This
    /// prevents the historyLoaded multi-poll cascade and incoming-message
    /// scrolls from yanking the user back to the bottom while they're
    /// reading history above.
    @State private var userHasScrolled = false
    /// True when the message ScrollView's bottom edge is visible. Used
    /// to gate the pull-up gesture so it only responds when the user
    /// is at the bottom of the list (not when they're reading history
    /// above). Tracked via `onScrollGeometryChange` (iOS 17+).
    @State private var isAtBottom: Bool = true
    /// How far the user has pulled up beyond the bottom, in points.
    /// 0 when not pulling, up to `pullUpMaxOffset` when at the limit.
    /// Drives the `refreshIndicator`'s height for visual feedback.
    @State private var pullUpOffset: CGFloat = 0
    /// True once `pullUpOffset` exceeds the activation threshold (8pt).
    /// Used to distinguish "user is touching the screen" from "user
    /// is actually performing the pull gesture". Reset on release.
    @State private var isPullingUp: Bool = false

    /// Minimum pull distance before the refresh indicator appears.
    /// Prevents accidental triggers from light scroll momentum.
    private let pullUpActivationThreshold: CGFloat = 8
    /// Minimum pull distance at release to actually trigger the
    /// network refresh. Below this, the gesture snaps back to 0.
    private let pullUpTriggerThreshold: CGFloat = 40
    /// Maximum pull distance — beyond this the offset clamps. Prevents
    /// the gesture from racing past reasonable visual feedback.
    private let pullUpMaxOffset: CGFloat = 80
    /// Scroll-position tolerance for `isAtBottom`. Treats the user as
    /// "at the bottom" if the content's bottom edge is within 4pt of
    /// the viewport's bottom edge.
    private let isAtBottomEpsilon: CGFloat = 4

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
            // Overlay the pull-up refresh indicator on the bottom edge
            // of the ScrollView itself, so it floats *over* the last
            // message instead of pushing the message list up by 28pt
            // (which is what the old VStack bar did — covering the
            // bottom 28pt of the conversation). `.allowsHitTesting(false)`
            // keeps the spinner from intercepting touches, so the
            // DragGesture and tap-to-dismiss-keyboard still reach the
            // ScrollView underneath.
            .overlay(alignment: .bottom) {
                refreshIndicator
                    .allowsHitTesting(false)
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
            .onScrollGeometryChange(for: Bool.self) { geometry in
                // contentOffset.y is the viewport's top; containerSize
                // is the viewport height; contentSize is the total
                // content height. Distance from bottom = (content -
                // offset - viewport). Within epsilon means at-bottom.
                let distanceFromBottom = geometry.contentSize.height
                                      - geometry.contentOffset.y
                                      - geometry.containerSize.height
                return distanceFromBottom < isAtBottomEpsilon
            } action: { _, newIsAtBottom in
                if self.isAtBottom != newIsAtBottom {
                    self.isAtBottom = newIsAtBottom
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: pullUpActivationThreshold)
                    .onChanged { value in
                        // Disable the entire pull-up gesture while a
                        // message is in flight. `refreshFromServer` calls
                        // `applyMergedHistory` which does a wholesale
                        // `vm.messages = messages` replacement — that
                        // drops any in-memory streaming messages the
                        // EventInterpreter is mid-way through building
                        // (they don't exist in the server's history
                        // response yet, and EventInterpreter doesn't
                        // persist them to MessageCache on each delta).
                        // Letting a pull-up fire mid-stream would
                        // visibly lose the response. Same reasoning
                        // applies to history-only reloads; gating on
                        // `isSending` keeps the user's read intact.
                        guard !viewModel.isSending else { return }
                        // Only upward swipes (negative translation).
                        guard value.translation.height < 0 else { return }
                        // Gate the *initial* pull on `isAtBottom` (prevents
                        // the gesture from fighting with normal upward
                        // scroll through history). Once committed
                        // (`isPullingUp == true`), keep following the finger
                        // even if the ScrollView's rubber-banding has caused
                        // `onScrollGeometryChange` to flip `isAtBottom` back
                        // to false mid-pull.
                        if !isPullingUp, !isAtBottom { return }
                        let pullDistance = -value.translation.height
                        pullUpOffset = min(pullDistance, pullUpMaxOffset)
                        if !isPullingUp, pullUpOffset >= pullUpActivationThreshold {
                            isPullingUp = true
                        }
                    }
                    .onEnded { _ in
                        // Defer snap-back so the trigger check uses the
                        // final pullUpOffset / isPullingUp values.
                        defer {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                pullUpOffset = 0
                                isPullingUp = false
                            }
                        }
                        guard isPullingUp, pullUpOffset >= pullUpTriggerThreshold else { return }
                        viewModel.refreshFromServer()
                    }
            )
            .onAppear {
                AppLogger.log("messageScrollView onAppear, messages: \(messages.count)", category: .nativeChat)
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
                let forceScroll = viewModel.scrollRequest.forceScroll
                // Always scroll to the bottom anchor, not the last
                // message id. The anchor is a zero-height `Color.clear`
                // with a fixed id at the end of `messageList`; it
                // exists the moment the LazyVStack's contentSize is
                // computed, regardless of whether the last *message*
                // bubble has been realized. `scrollTo(lastMessageId)`
                // would race against LazyVStack's virtualized render
                // — the message is in the data but not yet on screen,
                // so the scroll is a no-op. The anchor pattern makes
                // the cross-session scroll deterministic.
                let lastId = messages.last?.id
                AppLogger.log("scrollRequest kind=\(kind), forceScroll=\(forceScroll ? 1 : 0), lastMsgId: \(lastId?.prefix(8) ?? "nil"), userHasScrolled: \(userHasScrolled)", category: .nativeChat)
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
                        proxy.scrollTo(bottomAnchorId, anchor: .bottom)
                    }
                case .historyLoaded:
                    // Multi-poll scroll: history-load bubbles render through
                    // UIViewRepresentable (MarkdownCardView) which measures
                    // its content height asynchronously on the UIKit thread.
                    // The first scrollTo races with the layout pass — the
                    // visible viewport is still showing the empty/short
                    // initial frame. The follow-up polls catch the bubble
                    // once MarkdownViewTextKit has actually measured in.
                    //
                    // `forceScroll` bypasses the `userHasScrolled` gate:
                    // set by the HistoryLoader when the session key
                    // changed since the last load. Without it, a user
                    // who was reading the previous session would be stuck
                    // on its anchor after switching — the new session's
                    // bubbles land at the bottom but the viewport never
                    // follows.
                    AppLogger.log("historyLoaded triggering multi-poll scroll to anchor, forceScroll=\(forceScroll ? 1 : 0), userHasScrolled: \(userHasScrolled)", category: .nativeChat)
                    // Poll cadence: short delays catch the initial
                    // layout, longer delays cover large histories and
                    // `MarkdownViewTextKit`'s async height measurement.
                    // forceScroll (cross-session switch) gets a longer
                    // tail: the previous session's view was anchored
                    // somewhere in the middle, and the new session's
                    // first render has to push everything down. We cap
                    // at 4s; beyond that, the user can scroll manually.
                    let delays: [Double] = forceScroll
                        ? [0.0, 0.1, 0.3, 0.6, 1.0, 1.5, 2.0, 3.0, 4.0]
                        : [0.0, 0.2, 0.5, 1.0, 2.0]
                    for delay in delays {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            if forceScroll || !userHasScrolled {
                                AppLogger.log("historyLoaded scroll poll delay=\(delay) force=\(forceScroll ? 1 : 0) userHasScrolled=\(userHasScrolled) -> scroll to anchor", category: .nativeChat)
                                proxy.scrollTo(bottomAnchorId, anchor: .bottom)
                            }
                        }
                    }
                case .manualRefresh:
                    // User pulled up to refresh. Bypasses the
                    // userHasScrolled gate — the user explicitly
                    // requested the scroll, so we land on the new
                    // message even if they had previously scrolled up.
                    // Single scroll (not multi-poll) because by the
                    // time the network returns, the layout is stable
                    // (we're not in the middle of a fresh history
                    // load with async height measurement).
                    AppLogger.log("manualRefresh scrolling to anchor", category: .nativeChat)
                    proxy.scrollTo(bottomAnchorId, anchor: .bottom)
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
                    // to the bottom anchor to recover. Gated on
                    // `!userHasScrolled` so a user reading above is not
                    // yanked back when the input resizes.
                    if !userHasScrolled {
                        DispatchQueue.main.async {
                            proxy.scrollTo(bottomAnchorId, anchor: .bottom)
                        }
                    }
                }
            }
            .onChange(of: isInputFocused) { _, focused in
                AppLogger.log("isInputFocused changed to \(focused)", category: .nativeChat)
                if !userHasScrolled {
                    DispatchQueue.main.async {
                        proxy.scrollTo(bottomAnchorId, anchor: .bottom)
                    }
                }
            }
        }
    }

    /// Stable id for the bottom anchor view that lives at the end of
    /// `messageList`. `ScrollViewReader.scrollTo(self.anchorId,
    /// anchor: .bottom)` always lands on the very last line of the
    /// scroll content, regardless of whether the last *message* is
    /// inside the LazyVStack's realized render window. The previous
    /// approach scrolled to `messages.last?.id`, which was a no-op
    /// when LazyVStack hadn't materialized the last bubble yet (e.g.,
    /// immediately after a session switch where the network history
    /// just landed and the long-tail content was still in the
    /// virtualized offscreen buffer).
    private let bottomAnchorId = "nativechat.bottomAnchor"

    /// Source of truth for the message list (refactor: message-cache-sot).
    /// Reads the per-session array from `viewModel.store`, converts to
    /// `ChatMessage` for the view layer, and merges the user's expand
    /// state from `CollapseStateCache`. The store is `@Observable`; the
    /// conversion + merge happen per body re-evaluation. For a 200-message
    /// session this is ~200 ChatMessage builds, which is well below the
    /// cost threshold for an `ObservableObject` cache to be worth it.
    private var messages: [ChatMessage] {
        guard let sessionKey = viewModel.selectedSession?.key else { return [] }
        let openclawMessages = viewModel.store.messages(for: sessionKey, since: nil)
        let chatMessages = openclawMessages.compactMap {
            ChatMessageConverter.toChatMessage(from: $0)
        }
        let expandedIds = CollapseStateCache.shared.expandedMessageIds
        return chatMessages.map { msg in
            var copy = msg
            copy.isUserExpanded = expandedIds.contains(msg.id)
            return copy
        }
    }

    private var messageList: some View {
        LazyVStack(spacing: 0) {
            ForEach(messages) { message in
                MessageBubbleView(
                    message: message,
                    onExpandChange: { expanded in
                        // Write through to `CollapseStateCache` so the
                        // `@ObservedObject` on `collapseCache` fires
                        // and the view re-evaluates `body`. The
                        // `messages` computed property merges the
                        // cache's `expandedMessageIds` into the
                        // bubble's `isUserExpanded` field, so a toggle
                        // shows up on the next render.
                        CollapseStateCache.shared.setExpanded(message.id, expanded)
                    }
                )
                .id(message.id)
            }
            // Zero-height bottom anchor. `.frame(height: 0)` plus
            // `.allowsHitTesting(false)` keeps it from contributing
            // to the visual layout (no extra padding) while still
            // being a valid `scrollTo` target — the anchor sits at
            // the very bottom of the LazyVStack's contentSize.
            Color.clear
                .frame(height: 0)
                .allowsHitTesting(false)
                .id(bottomAnchorId)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var refreshIndicator: some View {
        // Visible only while the user is actively pulling OR while a
        // network refresh is in flight. Floats over the bottom of the
        // ScrollView (via `.overlay(alignment: .bottom)` in
        // `messageScrollView`) so it never covers messages — the
        // underlying message list keeps its full height. The overlay
        // has `.allowsHitTesting(false)` so the spinner never blocks
        // touches or drag gestures.
        //
        // The `!isSending` guard is defense in depth: the
        // DragGesture's onChanged also short-circuits on `isSending`,
        // so `isPullingUp` never flips true mid-stream. The
        // `isManualRefreshing` branch could still show the spinner if
        // a refresh started exactly as the user sent a message; the
        // guard suppresses that edge case too.
        if !viewModel.isSending && (isPullingUp || viewModel.isManualRefreshing) {
            HStack(spacing: 8) {
                Spacer()
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
                    .scaleEffect(0.7)
                Spacer()
            }
            .frame(height: isPullingUp ? max(pullUpOffset, 24) : 28)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
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
