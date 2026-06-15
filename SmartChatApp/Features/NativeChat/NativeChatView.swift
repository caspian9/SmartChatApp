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
    /// The id of the view that should be pinned to the viewport's
    /// bottom edge via `.scrollPosition(id: $pinnedBottomId, anchor:
    /// .bottom)`. Set by the `onChange(of: messages.last?.id)`
    /// handler when the user has not scrolled up (or when the
    /// `scrollRequest.forceScroll` flag is set, which is the cross-
    /// session / entry-time force-scroll signal from
    /// `HistoryLoader`). The Build 7527 multi-poll + `proxy.scrollTo`
    /// approach flickered: every `scrollTo` fire was a separate
    /// viewport jump, and the multi-poll (5 ticks at 0/50/150/400/
    /// 800 ms) re-fired 5 jumps per session-enter. `.scrollPosition`
    /// is the SwiftUI-native replacement — it tracks the binding
    /// internally and only animates the scroll when the binding
    /// value changes, with at most ONE scroll per change. So a
    /// cross-session `messages.last?.id` transition produces ONE
    /// scroll animation, not five flickering jumps. The default
    /// SwiftUI transaction animation (≈ 0.25 s ease-in-out) is
    /// gentler than the abrupt `scrollTo` jumps and reads as a
    /// smooth "land at the bottom" rather than a "flash".
    @State private var pinnedBottomId: String?
    /// How far the user has pulled up beyond the bottom, in points.
    /// 0 when not pulling, up to `pullUpMaxOffset` when at the limit.
    /// Drives the `refreshIndicator`'s height for visual feedback.
    @State private var pullUpOffset: CGFloat = 0
    /// True once `pullUpOffset` exceeds the activation threshold. Used
    /// to distinguish "user is touching the screen" from "user is
    /// actually performing the pull gesture". Reset on release.
    @State private var isPullingUp: Bool = false
    /// Throttle for the cross-session re-anchor triggered by
    /// `onScrollGeometryChange` when isAtBottom flips true→false
    /// (LazyVStack cells measuring async, dragging the viewport off
    /// the bottom while content grows). Without a throttle, each
    /// geometry change bumps `scrollRequest.token`, which fires a
    /// fresh `scrollTo` and *itself* triggers another geometry
    /// change — a tight feedback loop during the 50-150ms
    /// measurement window. Debounced to once per 80ms, the loop
    /// is bounded and the user sees at most a few re-anchors, not
    /// a per-frame stampede.
    ///
    /// Build 7488: removed. The previous onScrollGeometryChange
    /// re-anchor is gone, replaced by UITableView's content-size-
    /// based scroll. The @State is no longer needed.

    /// Minimum pull distance before the refresh indicator appears.
    /// 30pt — large enough that scroll momentum overshoot or the
    /// system rubber-band from a non-pull gesture doesn't commit the
    /// refresh. The previous 8pt threshold was the user-reported
    /// "small distance triggers" bug.
    private let pullUpActivationThreshold: CGFloat = 30
    /// Minimum pull distance at release to actually trigger the
    /// network refresh. 100pt — raised from 80pt after the user
    /// reported the previous threshold committed a refresh on
    /// gestures that felt exploratory (e.g. scrolling past the
    /// bottom looking for a typing cursor). The new value requires
    /// a deliberate pull, not a small overshoot.
    private let pullUpTriggerThreshold: CGFloat = 100
    /// Maximum pull distance — beyond this the offset clamps. 140pt
    /// gives the indicator room to grow visibly past the trigger
    /// point (100pt) so the user sees the spinner "snap" before
    /// release. Without the 40pt headroom the clamp kicks in at
    /// the trigger and the indicator stops moving.
    private let pullUpMaxOffset: CGFloat = 140

    /// ScrollViewReader target id. The previous Build 7526 version
    /// used a 1pt `Color.clear` sibling at the bottom of the
    /// `LazyVStack` and targeted it with `scrollTo(bottomAnchorId,
    /// anchor: .bottom)`. That turned out to be the user-reported
    /// Build 7568 cut-session symptom's root cause: `scrollTo(_, anchor:
    /// .bottom)` aligns the *anchor view's* bottom edge with the
    /// scrollView's bottom edge. The 1pt anchor was a separate view
    /// BELOW the last message, so its bottom edge sat ~1pt + the
    /// last message's `padding(.vertical, 4)` (~5pt) below the
    /// actual last-message visual bottom — the user saw the
    /// viewport "below the last message" and had to scroll up a
    /// little to find the messages.
    ///
    /// Build 7527+ drops the `Color.clear` anchor entirely. We
    /// give each `MessageBubbleView` an explicit `.id(msg.id)` and
    /// `scrollTo(messages.last!.id, anchor: .bottom)` aligns the
    /// last message's actual bottom edge with the viewport's
    /// bottom edge — the viewport lands on the message, not
    /// 1 pt below it. Each `MessageBubbleView`'s own
    /// `.padding(.vertical, 4)` makes the visual bottom edge
    /// (where the background ends) sit 4 pt above the layout
    /// bottom, but that's the same 4 pt on every message in the
    /// list, so the viewport always lands on the "bottom row" of
    /// the chat, which is what the user means by "in the
    /// bottom".

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
        // Build 7526: back to SwiftUI-native `ScrollView { LazyVStack }`
        // + `ScrollViewReader`. The `MessageTableView`
        // (UIViewRepresentable wrapping a UITableView) path was
        // removed because its `UITableViewCell` + `UIHostingController`
        // + `MarkdownViewTextKit` triple-stacking produced an
        // unresolvable layout race: even with the Build 7525
        // collapse-to-`Text+lineLimit` fix, the cell's hosting view
        // `intrinsicContentSize` was the SwiftUI view's full natural
        // height, which `UITableView` Auto Layout took at face value
        // and used to compute `scrollToRow` offsets — the 5-30 pt
        // chrome estimation error compounded across N cells into
        // hundreds of points of "last-message-bottom not at the
        // bottom" / "overlapping messages" drift.
        //
        // The LazyVStack path lets SwiftUI own the full layout —
        // each `MessageBubbleView` reports its own intrinsic size
        // (no estimated-row-height shortcut), and the `ScrollView`'s
        // content size is the sum of the actual rendered bubble
        // heights. `scrollTo(bottomAnchorId, .bottom)` always lands
        // on the real last cell.
        //
        // Performance: `MarkdownStreamManager.shared.holder(for:)`
        // (see `MarkdownCardView.swift`) already reuses the
        // underlying `MarkdownViewTextKit` across re-renders of the
        // same message id, so scrolling a large markdown bubble
        // into the viewport doesn't re-create its TextKit stack —
        // just updates the `markdown` string. The previous Build
        // 7384 scroll-lag (50 markdown cells × 5-10 ms = 250-500 ms
        // per scroll) was measured before the holder-reuse path
        // existed; with the holder, the LazyVStack path is in the
        // same ballpark as `MessageTableView` for visible-cell cost
        // (the only "extra" cost is `LazyVStack`'s prefetch window,
        // which materialises ~5 cells above the viewport).
        //
        // The `onScrollPhaseChange` + `onScrollGeometryChange` (iOS
        // 17+) modifiers that the Build 7488 comment claimed were
        // "gone — the MessageTableView's Coordinator provides
        // them" are back: they track `userHasScrolled` and
        // `isAtBottom` respectively, which the pull-up gesture
        // below gates on.
        messageList
            // Custom pull-UP refresh at the bottom of the table.
            // The system `.refreshable` is pull-DOWN, which is wrong
            // here — the chat list scrolls from top (oldest) to
            // bottom (latest), and the user "refreshes" by pulling
            // the bottom up. The indicator floats *over* the last
            // row (`.overlay(alignment: .bottom)` +
            // `.allowsHitTesting(false)`) so the message list keeps
            // its full height.
            //
            // Thresholds raised from the previous attempt
            // (8/40/80) to (30/100/140) to fix the "small distance
            // triggers" user-reported bug — the user has to
            // *intend* a refresh, and the table view's natural
            // rubber-band overshoot no longer races the gesture.
            // The 40pt headroom between trigger (100) and max
            // (140) lets the indicator visibly grow past the
            // trigger so the user feels the gesture commit.
            .overlay(alignment: .bottom) {
                refreshIndicator
                    .allowsHitTesting(false)
            }
            .onTapGesture { isInputFocused = false }
            .simultaneousGesture(
                DragGesture(minimumDistance: pullUpActivationThreshold)
                    .onChanged { value in
                        // Disable the entire pull-up gesture while a
                        // message is in flight — the refresh's
                        // `replaceForSession` would wipe the
                        // in-progress streaming entry.
                        guard !viewModel.isSending else { return }
                        // Only upward swipes (negative translation).
                        guard value.translation.height < 0 else { return }
                        // Gate the *initial* pull on `isAtBottom`
                        // (prevents the gesture from fighting with
                        // normal upward scroll through history).
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
                        guard !viewModel.isSending else { return }
                        guard isPullingUp, pullUpOffset >= pullUpTriggerThreshold else { return }
                        viewModel.refreshFromServer()
                    }
            )
            .onChange(of: viewModel.isSending) { _, isSending in
                // If the user started a pull-up while !isSending and
                // then a send kicks off mid-drag, cancel the
                // in-flight gesture so the eventual onEnded can't
                // commit a refresh that would race with the
                // streaming events. Snap the indicator back so the
                // user sees the gesture was cancelled rather than
                // hung.
                if isSending {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        pullUpOffset = 0
                        isPullingUp = false
                    }
                }
            }
    }


    /// Source of truth for the message list (refactor: message-cache-sot).
    /// Reads the per-session array from `viewModel.store`, converts to
    /// `ChatMessage` for the view layer, and merges the user's expand
    /// state from `CollapseStateCache`. The store is `@Observable`; the
    /// conversion + merge happen per body re-evaluation. For a 200-message
    /// session this is ~200 ChatMessage builds, which is well below the
    /// cost threshold for an `ObservableObject` cache to be worth it.
    private var messages: [ChatMessage] {
        guard let sessionKey = viewModel.selectedSession?.key else { return [] }
        // Use the viewModel's cached conversion. The conversion is
        // memoized inside the VM keyed on the source's id-list, so
        // re-evaluations of `body` triggered by `expandedMessageIds`,
        // `scrollRequest`, or other unrelated observable changes
        // don't re-run the (potentially expensive) full
        // `ChatMessageConverter.toChatMessage` pass for a 200+
        // message session.
        let chatMessages = viewModel.chatMessages(for: sessionKey)
        let expandedIds = CollapseStateCache.shared.expandedMessageIds
        // Skip the per-message merge when no bubbles are manually
        // expanded. For a 200-message session this avoids 200
        // struct copies + 200 Set lookups per body evaluation.
        // The body re-evaluates on every `expandedMessageIds`
        // mutation and on every `scrollRequest` token change
        // (per streaming delta), so the savings compound.
        if expandedIds.isEmpty {
            return chatMessages
        }
        return chatMessages.map { msg in
            var copy = msg
            copy.isUserExpanded = expandedIds.contains(msg.id) ? true : nil
            return copy
        }
    }

    private var messageList: some View {
        // Build 7526: pure SwiftUI `ScrollViewReader` + `ScrollView`
        // + `LazyVStack` + `MessageBubbleView`. No
        // `UIViewRepresentable` in the message-list path, no
        // `UITableView` + `UIHostingController` double-stacking.
        // See `messageScrollView`'s docstring for the full
        // architecture rationale (replaces Build 7488's
        // `MessageTableView`, which had a `UITableView` /
        // `UIHostingController` / `MarkdownViewTextKit` triple-
        // stack race that produced the user-reported overlap / empty-
        // gap / wrong-bottom bugs).
        //
        // Three `onChange` handlers drive `scrollTo(bottomAnchorId,
        // .bottom)`:
        //
        //   1. **`scrollRequest.token` change** — the unified scroll
        //      signal (`historyLoaded` / `newMessage` / `streaming
        //      delta` / `sendMessage completion`). Gated on
        //      `forceScroll` (set by `HistoryLoader` for cross-
        //      session transitions and entry-time history loads)
        //      or `!userHasScrolled` (so a user who scrolled up to
        //      read history isn't yanked back).
        //   2. **`messages.count` 0→>0 transition** — entry-time
        //      rescue. iOS 17's `.defaultScrollAnchor(_:)` modifier
        //      fires once on first appear; if the message list is
        //      empty at that point (cache hydrate hasn't run yet),
        //      it commits to "empty content bottom" = the top of
        //      the visible viewport. When the cache populates
        //      `messages` 0→99 a few ms later, the modifier's
        //      value changes from `nil` to `.bottom`, but in
        //      practice the commit has already happened and the
        //      viewport stays at the top. Catching the 0→>0
        //      transition here gives an explicit, deterministic
        //      re-anchor trigger.
        //   3. (Implicit: `viewModel.selectedSession?.key` change
        //      is signalled by `scrollRequest.token` with
        //      `forceScroll=true`, set by `HistoryLoader` on cross-
        //      session load — the existing `NativeChatScrollRequest`
        //      shape already models this signal explicitly, no
        //      second `onChange` needed.)
        //
        // Tracking:
        //   - `userHasScrolled`: `onScrollPhaseChange` flips it true
        //     on `.interacting` / `.decelerating`. Sticky for the
        //     view's lifetime.
        //   - `isAtBottom`: `onScrollGeometryChange` computes
        //     `contentSize - contentOffset - containerSize` and
        //     thresholds at 1 pt. Gates the pull-up refresh
        //     gesture (only active at the bottom).
        ScrollViewReader { proxy in
            ScrollView {
                // Build 7535: revert `VStack` → `LazyVStack`. The
                // Build 7534 `VStack` change made the first-render
                // visibly laggy on the 114-message session (all
                // 114 `MessageBubbleView`s materialised up-front,
                // each running a `MarkdownStreamManager` holder +
                // `MarkdownViewTextKit` first-measure pass, which
                // stacked to several seconds of main-thread work
                // before the view tree was even ready for
                // `.scrollPosition` to read). `LazyVStack` only
                // renders cells in the prefetch window, so the
                // first frame is fast — at the cost of the last
                // cell sometimes not being in the rendered view
                // tree on first appear. We accept that trade
                // (revert Build 7534); the user's request "don't
                // go through the scroll method" rules out the
                // multi-step animation that was the workaround.
                LazyVStack(spacing: 0) {
                    ForEach(messages) { msg in
                        MessageBubbleView(
                            message: msg,
                            onExpandChange: { expanded in
                                CollapseStateCache.shared.setExpanded(msg.id, expanded)
                            }
                        )
                        // Explicit `.id(msg.id)` so `.scrollPosition(
                        // id: $pinnedBottomId, anchor: .bottom)`
                        // reliably finds the last-message view in
                        // the LazyVStack. `ForEach` already uses
                        // `Identifiable.id` implicitly, but
                        // declaring it explicitly here also
                        // disambiguates the target from any nested
                        // `id` modifiers in the bubble sub-tree
                        // (e.g. `MarkdownCardView`'s width frame),
                        // which can otherwise confuse ScrollView's
                        // internal id index when the last message's
                        // view tree contains an inner `.id()` of
                        // its own.
                        .id(msg.id)
                    }
                }
            }
            // Force ScrollView rebuild on cross-session transition.
            // The previous `MessageTableView.Coordinator.resetForNewSession`
            // method is no longer reachable (the Coordinator is
            // gone), so we use SwiftUI's structural identity to
            // achieve the same effect: when `selectedSession?.key`
            // changes, the `ScrollView` is destroyed and rebuilt
            // from scratch — `@State` (userHasScrolled, isAtBottom,
            // pinnedBottomId, pullUpOffset, isPullingUp) resets to
            // its initial values, and the
            // `onChange(of: messages.last?.id)` handler below
            // re-fires to pin the new session's last message to
            // the viewport bottom.
            .id(viewModel.selectedSession?.key ?? "no-session")
            // Build 7528 scroll-pinning. `.scrollPosition(id:
            // $pinnedBottomId, anchor: .bottom)` is the
            // SwiftUI-native replacement for the
            // `proxy.scrollTo(_, anchor: .bottom)` path. The
            // binding is updated by the `onChange(of: messages.
            // last?.id)` handler below; SwiftUI internally
            // tracks the binding and animates the scroll to keep
            // the named view pinned at the viewport's bottom
            // edge. This replaces three sources of Build 7568 /
            // 7576 user-reported flicker:
            //
            //   1. `.defaultScrollAnchor(messages.isEmpty ?
            //      nil : .bottom)` was committing an anchor at
            //      first appear; when `messages` went from `[]`
            //      to `[N]` a frame later, the anchor value
            //      transitioned, causing a second commit and
            //      viewport jump.
            //   2. `.task { multi-poll }` was firing 5 separate
            //      `proxy.scrollTo` calls per session-enter, at
            //      [0, 50, 150, 400, 800] ms — each fire was a
            //      viewport jump, and the cells materialising
            //      between polls changed the target's measured
            //      y, so the five jumps landed on five different
            //      y-values. Read at 60 fps that's 5 viewport
            //      transitions in <1 s = visible "flicker".
            //   3. `onChange(of: messages.count) { 0→>0 }` and
            //      `onChange(of: scrollRequest.token)` were both
            //      firing on the same session-enter, each calling
            //      `proxy.scrollTo` again — double-jump.
            //
            // With `.scrollPosition`, all three collapse into one
            // binding update → one scroll animation, no
            // double-jump, no multi-jump.
            .scrollPosition(id: $pinnedBottomId, anchor: .bottom)
            .task(id: viewModel.selectedSession?.key ?? "no-session") {
                // The user-reported Build 7584 symptom — "session
                // switch doesn't flicker but isn't at the bottom" /
                // "first entry shows the top" — reduced to a single
                // root cause: when
                // `pinnedBottomId` is set on the first render, the
                // `LazyVStack` cells haven't finished their first
                // layout pass yet. `MarkdownCardView` /
                // `StreamingMarkdownCardView` report their actual
                // height asynchronously (the `MarkdownViewTextKit`
                // callback fires after the view appears, triggering
                // a frame change). When `.scrollPosition` receives a
                // `pinnedBottomId` whose view's frame is still
                // 0-or-estimated, it scrolls to the wrong y, and
                // the subsequent frame change cancels the scroll
                // rather than re-anchoring. The end result is the
                // viewport sitting where the cells were estimated to
                // end up — which, for a 30-cell session whose cells
                // haven't materialised, is roughly the top of the
                // list (Build 7584's "first entry shows the top")
                // or somewhere below the last cell (Build 7584's
                // "session switch not at the bottom").
                //
                // The fix is to delay the `pinnedBottomId` write
                // until AFTER the cells have had a chance to
                // materialise and the markdown views have reported
                // their first onHeightChange. The 50 ms sleep is
                // empirical: it's enough to outlast the typical
                // SwiftUI first-layout-pass (which is in the 10-30
                // ms range) plus the typical
                // `MarkdownViewTextKit.onHeightChange` callback
                // (which fires on the main thread after TextKit's
                // first glyph run is laid out, 20-40 ms). The
                // `while messages.isEmpty` poll covers the slower
                // case where the HistoryLoader is still fetching
                // from the network.
                //
                // `.task(id:)` is the right primitive: when
                // `selectedSession?.key` changes, the old task is
                // cancelled and a new one starts — the same
                // behaviour we'd otherwise have to wire up by hand
                // with a session-key `.id()` rebuild of the
                // ScrollView (which `.id(...)` already does above,
                // but the two are belt-and-braces — the task
                // re-fires even if the structural rebuild is
                // skipped by SwiftUI's diffing).
                //
                // Build 7535: revert Build 7534's multi-step
                // `withAnimation` to a single direct set. The
                // user reported the multi-step animation as
                // "very laggy" and explicitly asked for "no
                // animation" and "don't go through the scroll
                // method". A plain binding assignment
                // without `withAnimation` is the "direct position"
                // they asked for: `.scrollPosition` lands the
                // cell's bottom at the viewport's bottom in a
                // single frame, no interpolated animation, no
                // visible viewport travel.
                //
                // The 50 ms wait is kept (not the 250 ms from
                // Build 7533) because there's no animation
                // budget to stretch here — the binding writes
                // synchronously and the scroll happens in the
                // next layout pass. If the last cell is in the
                // rendered view tree by then (the common case
                // for a 30-cell or shorter session), the scroll
                // lands on the card's bottom. For the 114-cell
                // session the user is testing, the last cell
                // sits outside `LazyVStack`'s prefetch window
                // and the binding update is silently dropped —
                // the same Build 7532 behaviour, which is the
                // current best-effort we can do without giving
                // up `LazyVStack`'s first-render speed.
                var polls = 0
                while messages.isEmpty && polls < 50 {
                    try? await Task.sleep(nanoseconds: 20_000_000) // 20ms
                    polls += 1
                }
                if messages.isEmpty {
                    AppLogger.log("task pin: messages still empty after 1s, giving up", category: .nativeChat)
                    return
                }
                try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
                if let lastId = messages.last?.id {
                    let request = viewModel.scrollRequest
                    AppLogger.log(
                        "task pin → \(lastId) (forceScroll=\(request.forceScroll), userHasScrolled=\(userHasScrolled), count=\(messages.count))",
                        category: .nativeChat)
                    pinnedBottomId = lastId
                }
            }
            .onChange(of: messages.last?.id) { _, newId in
                // Streaming-delta / in-app history refresh case.
                // The `.task(id: sessionKey)` above handles
                // entry-time and cross-session scroll; this
                // handler covers the case where `messages.last`
                // changes WITHOUT a session-key change — i.e.
                // a new message arrives via streaming, or the
                // user pull-up-refreshes and `HistoryLoader`
                // appends new server messages. The gate is the
                // same as the previous
                // `onChange(scrollRequest.token)` path: respect
                // the user's reading position
                // (`!userHasScrolled`) unless the writer set
                // `forceScroll=true` (currently no in-app writer
                // does this for streaming, so streaming deltas
                // gate on `!userHasScrolled` only).
                //
                // Build 7531: target is now the outer
                // `MessageBubbleView`'s `.id(msg.id)` directly
                // (no more `"bubble-\(id)"` sub-id on the inner
                // `bubbleContent`). With `MessageMetaView`
                // extracted into the card (see
                // `MessageBubbleView.swift`), the cell's layout
                // bottom now equals the card's visual bottom, so
                // pinning to `msg.id` lands the viewport exactly
                // on the card instead of 50 pt below it.
                let request = viewModel.scrollRequest
                guard request.forceScroll || !userHasScrolled else {
                    return
                }
                guard let newId else { return }
                AppLogger.log(
                    "onChange pin → \(newId) (forceScroll=\(request.forceScroll), userHasScrolled=\(userHasScrolled))",
                    category: .nativeChat)
                pinnedBottomId = newId
            }
            .onScrollPhaseChange { _, newPhase in
                // `userHasScrolled` tracking. The previous
                // `MessageTableView.onUserInteraction` callback is
                // replaced by this iOS 17 modifier. Once the user
                // touches the scroll, the flag sticks for the
                // view's lifetime (it resets implicitly on
                // `NativeChatView` re-mount — i.e. next time the
                // user enters NativeChat).
                if newPhase == .interacting || newPhase == .decelerating {
                    if !userHasScrolled {
                        userHasScrolled = true
                    }
                }
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                // `isAtBottom` tracking. Replaces the
                // `MessageTableView.Coordinator.scrollViewDidScroll`
                // callback. 1 pt epsilon matches the previous
                // implementation's threshold — tight on purpose
                // so a user reading the last visible message
                // doesn't have the pull-up gesture commit
                // prematurely.
                let distanceFromBottom = geometry.contentSize.height
                    - geometry.contentOffset.y
                    - geometry.containerSize.height
                return distanceFromBottom < 1
            } action: { _, newIsAtBottom in
                if isAtBottom != newIsAtBottom {
                    isAtBottom = newIsAtBottom
                }
            }
        }
    }

    @ViewBuilder
    private var refreshIndicator: some View {
        // Custom pull-UP indicator. Shown when the user is actively
        // pulling (height tracks `pullUpOffset`) OR when a network
        // refresh is in flight (height 28pt). Floats over the bottom
        // of the ScrollView (via `.overlay(alignment: .bottom)` in
        // `messageScrollView`) so it never covers messages — the
        // underlying message list keeps its full height. The overlay
        // has `.allowsHitTesting(false)` so the spinner never blocks
        // touches or drag gestures.
        //
        // The `!isSending` guard is defense in depth: the
        // DragGesture's onChanged also short-circuits on `isSending`,
        // so `isPullingUp` never flips true mid-stream.
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
