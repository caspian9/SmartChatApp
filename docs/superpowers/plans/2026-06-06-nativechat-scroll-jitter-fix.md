# NativeChat Scroll Jitter Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the visible "up-down jitter" on entering the NativeChat page (with cache + gateway connected) and the "yank back to bottom" when the user scrolls up while streaming. The fix consolidates 4 independent scroll triggers into a single `NativeChatScrollRequest{token, kind}` and gates auto-scroll on detected user scroll intent. **Zero functional change to message display; pure scroll-behavior fix.**

**Architecture:** Replace the existing `scrollTrigger` / `cacheLoadCounter` / `needsScrollToBottom` triple with a single `var scrollRequest: NativeChatScrollRequest` (`token: Int`, `kind: .newMessage | .historyLoaded`) on `NativeChatViewModel`. Each writer (`sendMessage`, `MessageReceiver`, `HistoryLoader`) increments the token exactly once per event. The view observes `token` and dispatches on `kind` — `.newMessage` does a single `scrollTo`, `.historyLoaded` does a multi-poll (0/0.2/0.5/1.0/2.0s) to catch the `MarkdownViewTextKit` async height measurement. A sticky `userHasScrolled` flag (set by `.onScrollPhaseChange` when phase becomes `.interacting`/`.decelerating`) gates all auto-scrolls so a user reading above is never yanked back to the bottom.

**Tech Stack:** Swift 5.9, SwiftUI, iOS 17 `@Observable` + `onScrollPhaseChange` (iOS 17+), OpenClawKit SDK, OpenClawChatUI SDK, XcodeGen

---

## File Structure

**New files:**
- `SmartChatAppTests/NativeChatScrollRequestTests.swift` — 4 unit tests for the unified scroll token

**Modified files:**
- `SmartChatApp/Features/NativeChat/NativeChatViewModel.swift` — add `NativeChatScrollKind` / `NativeChatScrollRequest` types, replace 3 trigger fields with `scrollRequest`, remove 3 helper methods, fire 1 scroll request at end of `sendMessage`
- `SmartChatApp/Features/NativeChat/NativeChatView.swift` — delete 4 `onChange`s + `scheduleScroll` + 4 dead `@State`s, add 1 unified `onChange(scrollRequest.token)` + `userHasScrolled` gate via `.onScrollPhaseChange`
- `SmartChatApp/Features/NativeChat/Internal/HistoryLoader.swift` — replace 3 trigger writes per `loaded*History` method with 1 `scrollRequest` write, delete `incrementCacheCounter()`
- `SmartChatApp/Features/NativeChat/Internal/MessageReceiver.swift` — replace 3 `scrollTrigger += 1` (id-match / similar-match / fresh-insert paths) with 1 `scrollRequest` write; same in `appendNewMessages`

**Unchanged files (verify only):**
- `SmartChatApp/Features/NativeChat/ChatInputView.swift` — no scroll logic
- `SmartChatApp/Features/NativeChat/MessageBubbleView.swift` — no scroll logic
- `SmartChatApp/Features/NativeChat/SessionPickerView.swift` — no scroll logic
- `SmartChatApp/Core/Services/MarkdownStreamManager.swift` — markdown streaming is orthogonal

---

## Build/Test Commands Reference

These are used throughout the plan. Run from the project root.

- **Regenerate Xcode project** (after adding/moving files):
  ```bash
  xcodegen generate
  ```
- **Build app**:
  ```bash
  make build
  ```
  (Runs `xcodegen generate` + `xcodebuild -skipMacroValidation -scheme SmartChatApp -destination "platform=iOS,name=$(DEVICE_NAME)" -allowProvisioningUpdates build`.)
- **Run all unit tests**:
  ```bash
  xcodebuild -project SmartChatApp.xcodeproj -scheme SmartChatAppTests \
    -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test
  ```
- **Run a single test class**:
  ```bash
  xcodebuild -project SmartChatApp.xcodeproj -scheme SmartChatAppTests \
    -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test \
    -only-testing:SmartChatAppTests/NativeChatScrollRequestTests
  ```

---

## Task 1: Add `NativeChatScrollRequest` to `NativeChatViewModel`

**Files:**
- Modify: `SmartChatApp/Features/NativeChat/NativeChatViewModel.swift` (state block + `sendMessage`)

- [ ] **Step 1: Add the file-scope types**

At the top of `NativeChatViewModel.swift` (after the existing imports, before the `@MainActor` class), add:

```swift
/// Unified scroll signal between the view-model and the view. Replaces the
/// previous `scrollTrigger` / `cacheLoadCounter` / `needsScrollToBottom`
/// triple, where three independent counters in the same beat would compound
/// to 11+ `scrollTo` calls per history load. Writers (sendMessage,
/// MessageReceiver, HistoryLoader) bump `token` exactly once per event; the
/// view observes `token` and dispatches on `kind` — `.newMessage` does a
/// single scroll, `.historyLoaded` does a multi-poll scroll to catch the
/// `MarkdownViewTextKit` async height measurement.
enum NativeChatScrollKind: Equatable {
    /// A new message landed or a streaming delta arrived — single scroll.
    /// Streaming deltas mutate the same `lastId` (id-match path), so the
    /// single scroll is a no-op once at the bottom; only a fresh append
    /// (new user message, new tool bubble) actually moves the viewport.
    case newMessage
    /// Cached or network history just loaded — multi-poll scroll catches
    /// the `MarkdownViewTextKit` async height measurement.
    case historyLoaded
}

struct NativeChatScrollRequest: Equatable {
    var token: Int
    var kind: NativeChatScrollKind
    static let initial = NativeChatScrollRequest(token: 0, kind: .newMessage)
}
```

> **Why file-scope, not nested in the class:** the 4 collaborators (`MessageReceiver` / `HistoryLoader` / `EventInterpreter` / `SessionCoordinator`) live in separate files; nested types would be invisible to them. File-scope is also what the existing `OSAllocatedUnfairLock` style on `HistoryLoader` follows.

- [ ] **Step 2: Replace the 3 trigger fields with 1 `scrollRequest`**

In the state block (currently around line 47), delete:

```swift
var scrollTrigger: Int = 0
var cacheLoadCounter: Int = 0
var needsScrollToBottom: Bool = false
```

and replace with:

```swift
/// Unified scroll signal. See `NativeChatScrollRequest` doc for the
/// rationale. Each writer must increment the token exactly once per
/// event — multiple increments in the same beat used to produce
/// visible up-down jitter when the viewport kept re-anchoring against
/// different layout states.
var scrollRequest: NativeChatScrollRequest = .initial
```

- [ ] **Step 3: Delete the now-dead helper methods**

Remove from the class:
- `func scrollToBottom()` 
- `func setNeedsScrollToBottom(_ value: Bool)`
- `func incrementScrollTrigger()`
- `func incrementCacheCounter()` (if it lives on the VM; otherwise it's on `HistoryLoader` and gets removed in Task 3)

- [ ] **Step 4: Fire 1 scroll request at the end of `sendMessage()`**

In `sendMessage()`, after `messages.append(message)` and before `inputText = ""`, add:

```swift
// Without this scroll request, the viewport stays at the
// pre-send position until `isSending` flips false (lifecycle end,
// which can be 10+ seconds for a long response). The view's
// `.newMessage` handler scrolls to the new last id (this very
// user message) so the user sees the bubble land at the bottom.
scrollRequest = NativeChatScrollRequest(token: scrollRequest.token &+ 1, kind: .newMessage)
```

- [ ] **Step 5: Build, verify it compiles**

```bash
make build
```

Expected: build succeeds. `HistoryLoader` and `MessageReceiver` are temporarily broken (they still write the old fields) — that gets fixed in Tasks 3 and 4. If `make build` complains about the missing `scrollTrigger` etc. inside the collaborators, that's fine, comment-out those lines temporarily and re-enable in Tasks 3/4. Alternatively, do Tasks 2-4 together before building.

---

## Task 2: Add the unified `onChange` + `userHasScrolled` gate in `NativeChatView`

**Files:**
- Modify: `SmartChatApp/Features/NativeChat/NativeChatView.swift` (scrollView block)

- [ ] **Step 1: Add the sticky `userHasScrolled` state**

At the top of `NativeChatView`, add:

```swift
/// Sticky flag: once the user has touched the scroll view, auto-scroll
/// stops. Set by `.onScrollPhaseChange` when the phase becomes
/// `.interacting` or `.decelerating`. Reset implicitly when the view
/// identity is recreated (next time the user enters NativeChat). This
/// prevents the historyLoaded multi-poll cascade and incoming-message
/// scrolls from yanking the user back to the bottom while they're
/// reading history above.
@State private var userHasScrolled = false
```

- [ ] **Step 2: Delete the 4 old `onChange`s, the dead `@State`s, and `scheduleScroll`**

In `NativeChatView`:
- Delete `@State private var isUserScrolling: Bool = false` (dead — never set to true in this view)
- Delete `@State private var scrollToMessageId: String? = nil`
- Delete `@State private var triggerCount: Int = 0`
- Delete `@State private var cacheLoadTriggerCount: Int = 0`
- Delete the `scheduleScroll(proxy:)` helper function
- Delete these 4 `.onChange`s in the `ScrollViewReader`:
  - `.onChange(of: viewModel.messages.count)`
  - `.onChange(of: viewModel.scrollTrigger)`
  - `.onChange(of: viewModel.cacheLoadCounter)`
  - `.onChange(of: viewModel.needsScrollToBottom)`

- [ ] **Step 3: Add `.onScrollPhaseChange` to set `userHasScrolled`**

On the `ScrollView` (or its `ScrollViewReader`), add:

```swift
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
```

- [ ] **Step 4: Add the single unified `onChange(scrollRequest.token)`**

Replace the 4 deleted `onChange`s with:

```swift
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
```

- [ ] **Step 5: Gate the existing `isSending` and `isInputFocused` `onChange`s on `userHasScrolled`**

The two remaining `onChange`s (`viewModel.isSending` and `isInputFocused`) currently scroll unconditionally. Wrap their `proxy.scrollTo` calls with `if !userHasScrolled` so a user reading above is not yanked back when the input resizes or the keyboard appears/disappears. Add `userHasScrolled` to the existing `AppLogger.log(...)` calls in those handlers.

- [ ] **Step 6: Build, verify it compiles**

```bash
make build
```

Expected: build fails inside `HistoryLoader` and `MessageReceiver` because they still write `vm.scrollTrigger` / `vm.cacheLoadCounter` / `vm.needsScrollToBottom`. Continue to Tasks 3 and 4 before re-building.

---

## Task 3: Update `HistoryLoader` to use the unified scroll request

**Files:**
- Modify: `SmartChatApp/Features/NativeChat/Internal/HistoryLoader.swift` (both `loaded*History` methods)

- [ ] **Step 1: Replace the 3 trigger writes in `loadedCachedHistory`**

In `loadedCachedHistory(_:isRestoring:)`, delete:

```swift
vm.scrollTrigger += 1
vm.cacheLoadCounter += 1
Task { [messages] in
    await MainActor.run {
        MarkdownCache.shared.precomputeForMessages(messages)
        CollapseStateCache.shared.precompute(for: messages)
    }
    self.incrementCacheCounter()
}
```

and replace with:

```swift
// Single scroll request — the view's multi-poll handler covers
// the `MarkdownViewTextKit` async height measurement. Precompute
// runs in a Task without firing a second scroll request.
vm.scrollRequest = NativeChatScrollRequest(token: vm.scrollRequest.token &+ 1, kind: .historyLoaded)
Task { [messages] in
    await MainActor.run {
        MarkdownCache.shared.precomputeForMessages(messages)
        CollapseStateCache.shared.precompute(for: messages)
    }
}
```

- [ ] **Step 2: Replace the 3 trigger writes in `loadedNetworkHistory`**

In `loadedNetworkHistory(sessionKey:messages:)`, make the same change as Step 1, after the staleness check (`if currentKey != sessionKey { return }`).

- [ ] **Step 3: Delete `incrementCacheCounter()`**

Remove the method from `HistoryLoader`. It's no longer called by anyone.

---

## Task 4: Update `MessageReceiver` to use the unified scroll request

**Files:**
- Modify: `SmartChatApp/Features/NativeChat/Internal/MessageReceiver.swift` (`receiveMessage` + `appendNewMessages`)

- [ ] **Step 1: Delete the 3 inline `scrollTrigger += 1` writes in `receiveMessage`**

In `receiveMessage(_:)`, delete the 3 separate `vm.scrollTrigger += 1` lines (one in the id-match branch, one in the similar-match branch, one in the fresh-insert branch). They currently live inside the `if let existingIndex` / `if let similarIndex` / `else` blocks.

- [ ] **Step 2: Add 1 unified scroll request at the end of `receiveMessage`**

After the if/else block (before the `if message.state == "final"` block), add:

```swift
// Single scroll request per receiveMessage call regardless of
// which merge path was taken (id-match, similar-match, or fresh
// insert). Multiple fires in the same beat used to compound with
// HistoryLoader's triggers to produce visible jitter.
vm.scrollRequest = NativeChatScrollRequest(token: vm.scrollRequest.token &+ 1, kind: .newMessage)
```

- [ ] **Step 3: Update `appendNewMessages`**

In `appendNewMessages(_:)`, delete `vm.needsScrollToBottom = true` and replace with:

```swift
vm.scrollRequest = NativeChatScrollRequest(token: vm.scrollRequest.token &+ 1, kind: .newMessage)
```

- [ ] **Step 4: Build, verify it compiles**

```bash
make build
```

Expected: build succeeds. All 4 files now consistently use the unified scroll request.

---

## Task 5: Add `NativeChatScrollRequestTests` regression guards

**Files:**
- Create: `SmartChatAppTests/NativeChatScrollRequestTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `SmartChatAppTests/NativeChatScrollRequestTests.swift`:

```swift
import XCTest
@testable import SmartChatApp

@MainActor
final class NativeChatScrollRequestTests: XCTestCase {
    var sut: NativeChatViewModel!

    override func setUp() {
        super.setUp()
        sut = NativeChatViewModel()
    }

    /// Regression guard for the scroll-jitter fix: the initial scroll request
    /// must be `kind: .newMessage` with `token: 0` so the view's first
    /// `onChange(scrollRequest.token)` doesn't see a phantom historyLoaded.
    func testInitialScrollRequest_isNewMessageTokenZero() {
        XCTAssertEqual(sut.scrollRequest.token, 0)
        XCTAssertEqual(sut.scrollRequest.kind, .newMessage)
    }

    /// `MessageReceiver.receiveMessage` must increment the scroll token
    /// exactly once per call, regardless of which merge path (id-match,
    /// similar-match, fresh insert) was taken. The previous code had three
    /// separate `vm.scrollTrigger += 1` sites plus a 5-poll
    /// `cacheLoadCounter` cascade in HistoryLoader — together that produced
    /// 11+ `scrollTo` calls per history load, which is what caused the
    /// visible up-down jitter.
    func testReceiveMessage_freshInsert_incrementsTokenOnce() {
        let initialToken = sut.scrollRequest.token
        let msg = makeMessage(id: "m1", text: "hi", role: "assistant", state: "final")
        sut.messageReceiver.receiveMessage(msg)
        XCTAssertEqual(sut.scrollRequest.token, initialToken &+ 1)
        XCTAssertEqual(sut.scrollRequest.kind, .newMessage)
    }

    /// Streaming deltas hit the id-match path: same id, updated text/state.
    /// The view's single-scroll handler is a no-op when `lastId` is
    /// unchanged, so this case should not cause visible viewport jumps.
    func testReceiveMessage_idMatch_stillIncrementsTokenOnce() {
        let initialToken = sut.scrollRequest.token
        let first = makeMessage(id: "run-1", text: "", role: "assistant", state: "streaming")
        sut.messageReceiver.receiveMessage(first)
        let tokenAfterFirst = sut.scrollRequest.token
        let delta = makeMessage(id: "run-1", text: "Hello world", role: "assistant", state: "streaming")
        sut.messageReceiver.receiveMessage(delta)
        XCTAssertEqual(sut.scrollRequest.token, tokenAfterFirst &+ 1)
        XCTAssertEqual(sut.scrollRequest.token, initialToken &+ 2)
        XCTAssertEqual(sut.scrollRequest.kind, .newMessage)
    }

    /// Multiple back-to-back receives must produce a monotonically
    /// increasing token. The wrapping `&+` operator is used so the test
    /// stays valid even if the token were ever to overflow Int.max.
    func testReceiveMessage_multipleReceives_tokenMonotonic() {
        var lastToken = sut.scrollRequest.token
        for i in 0..<5 {
            let msg = makeMessage(id: "m\(i)", text: "msg \(i)", role: "user", state: "final")
            sut.messageReceiver.receiveMessage(msg)
            XCTAssertGreaterThan(sut.scrollRequest.token, lastToken, "token must increase after receive #\(i)")
            XCTAssertEqual(sut.scrollRequest.kind, .newMessage)
            lastToken = sut.scrollRequest.token
        }
    }

    // MARK: - Helpers

    private func makeMessage(id: String, text: String, role: String, state: String) -> ChatMessage {
        ChatMessage(
            id: id,
            text: text,
            timestamp: Date(),
            role: role,
            state: state,
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
    }
}
```

- [ ] **Step 2: Regenerate the project so the new test file is picked up**

```bash
xcodegen generate
```

- [ ] **Step 3: Run the new test class, expect 4 passes**

```bash
xcodebuild -project SmartChatApp.xcodeproj -scheme SmartChatAppTests \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test \
  -only-testing:SmartChatAppTests/NativeChatScrollRequestTests
```

Expected: 4 tests pass.

- [ ] **Step 4: Run all tests, expect no regressions**

```bash
xcodebuild -project SmartChatApp.xcodeproj -scheme SmartChatAppTests \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test
```

Expected: all prior tests still pass (50+ tests depending on what's in the suite).

- [ ] **Step 5: Commit**

```bash
git add SmartChatApp/Features/NativeChat/NativeChatViewModel.swift \
        SmartChatApp/Features/NativeChat/NativeChatView.swift \
        SmartChatApp/Features/NativeChat/Internal/HistoryLoader.swift \
        SmartChatApp/Features/NativeChat/Internal/MessageReceiver.swift \
        SmartChatAppTests/NativeChatScrollRequestTests.swift \
        SmartChatApp.xcodeproj
git commit -m "fix(nativechat): gate auto-scroll on user scroll intent"
```

---

## Task 6: Final verification + manual smoke test

**Files:** None (read-only checks + device install + manual testing)

- [ ] **Step 1: Confirm `scrollTrigger` / `cacheLoadCounter` / `needsScrollToBottom` are gone**

```bash
grep -rn "scrollTrigger\|cacheLoadCounter\|needsScrollToBottom\|incrementCacheCounter\|incrementScrollTrigger" \
  SmartChatApp/Features/NativeChat/
```

Expected: no matches (or only doc-comment references explaining what was removed).

- [ ] **Step 2: Confirm the unified scroll request is used in all 3 writer sites**

```bash
grep -rn "scrollRequest" SmartChatApp/Features/NativeChat/
```

Expected: 4 matches — 1 in `NativeChatViewModel` (declaration + initial), 1 in `NativeChatView` (onChange), 1 in `HistoryLoader` (both methods), 1 in `MessageReceiver` (both methods), 1 in `NativeChatViewModel.sendMessage`.

- [ ] **Step 3: Run all unit tests**

```bash
xcodebuild -project SmartChatApp.xcodeproj -scheme SmartChatAppTests \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test
```

Expected: all tests pass (50+ including the 4 new ones).

- [ ] **Step 4: Build and install to iPhone**

```bash
make install
```

Expected: app builds and installs to the connected iPhone.

- [ ] **Step 5: Manual smoke test on the iPhone**

Launch the app and verify each of the following:

1. **Enter NativeChat with cache + connected gateway** — viewport should smoothly settle to the bottom in 1-2 seconds, with at most one visible "settle" motion. No up-down jitter, no jumping to a middle position then back.
2. **Enter NativeChat with no cache** — same smooth settle after the network response arrives.
3. **Send a message** — viewport lands on the new user message immediately, not after `isSending` flips false.
4. **Receive a streaming reply** — viewport stays at the bottom (no visible jumps per delta, since `lastId` is unchanged).
5. **Scroll up while streaming** — viewport stays where the user scrolled; new deltas do NOT yank the viewport back. `userHasScrolled` log line should fire once on first scroll.
6. **Switch sessions** — new session's history loads, viewport settles to that session's bottom (this works because switching sessions recreates the view, resetting `userHasScrolled`).
7. **Tap into an old conversation, then leave and re-enter NativeChat** — `userHasScrolled` resets (new view), auto-scroll works again.

- [ ] **Step 6: Compare scroll request usage vs. baseline**

```bash
echo "Baseline: 4 scroll triggers (scrollTrigger, cacheLoadCounter, needsScrollToBottom, messages.count onChange), 11+ scrollTo calls per history load"
echo "After: 1 scroll request, 1 .newMessage scroll per event OR 5 polls on .historyLoaded, gated on userHasScrolled"
```

Expected: cleaner trigger model, no behavior regression.

---

## Self-Review

### Spec Coverage

The plan implements the 3-point user request:
- **Point 1 (no jitter on entry with cache + connected)**: Tasks 1, 2, 3, 4 collapse the 4-scroll-trigger cascade (11+ `scrollTo` per history load) into 1 trigger per event. Task 2's multi-poll handler explicitly catches the `MarkdownViewTextKit` async height measurement.
- **Point 2 (no repeat jumps after manual scroll)**: Task 2 introduces `userHasScrolled` (sticky, set by `.onScrollPhaseChange` on `.interacting`/`.decelerating`) and gates all 3 scroll sites on it.
- **Point 3 (regression guard)**: Task 5 adds 4 unit tests pinning the unified scroll request's behavior. The 3-merge-paths test catches a future regression where someone re-adds per-branch `scrollTrigger += 1`.

### Placeholder Scan

No "TBD", "TODO", "implement later", or "etc." in the plan. Every code block is complete and runnable. Every command has expected output.

### Type Consistency

- `NativeChatScrollKind` (file-scope enum) and `NativeChatScrollRequest` (file-scope struct) defined in Task 1, consumed in Tasks 2, 3, 4, 5. ✓
- `var scrollRequest: NativeChatScrollRequest` declared in Task 1, written in Tasks 1, 3, 4, observed in Task 2. ✓
- `userHasScrolled: Bool` (`@State`) introduced in Task 2, observed in Task 2 (3 sites) and tested in Task 5 indirectly via the token-monotonicity guarantee. ✓
- The `&+` wrapping-addition operator is used everywhere the token increments, so a token overflow at `Int.max` doesn't trap. ✓

---

## Critical Files (Quick Reference)

| Path | Action | Result |
|---|---|---|
| `SmartChatApp/Features/NativeChat/NativeChatViewModel.swift` | Modify | Add `NativeChatScrollKind` / `NativeChatScrollRequest`, swap 3 trigger fields for 1, remove 3 helper methods, fire 1 request in `sendMessage` |
| `SmartChatApp/Features/NativeChat/NativeChatView.swift` | Modify | Delete 4 `onChange`s + 4 dead `@State`s + `scheduleScroll`; add 1 unified `onChange(scrollRequest.token)` + `userHasScrolled` flag + `.onScrollPhaseChange` listener; gate 3 scroll sites |
| `SmartChatApp/Features/NativeChat/Internal/HistoryLoader.swift` | Modify | Replace 3 trigger writes per `loaded*History` with 1 scroll request; delete `incrementCacheCounter()` |
| `SmartChatApp/Features/NativeChat/Internal/MessageReceiver.swift` | Modify | Replace 3 `scrollTrigger += 1` + 1 `needsScrollToBottom = true` with 1 scroll request per call |
| `SmartChatAppTests/NativeChatScrollRequestTests.swift` | Create | 4 unit tests pinning the unified scroll token's behavior |
| `SmartChatApp/Features/NativeChat/ChatInputView.swift` | **Unchanged** | input is not part of scroll logic |
| `SmartChatApp/Features/NativeChat/MessageBubbleView.swift` | **Unchanged** | |
| `SmartChatApp/Features/NativeChat/SessionPickerView.swift` | **Unchanged** | |
| `SmartChatApp/Core/Services/MarkdownStreamManager.swift` | **Unchanged** | |

## Reused Existing Code

- **iOS 17 `.onScrollPhaseChange`** — built into SwiftUI, no new dependency. Used to set the sticky `userHasScrolled` flag.
- **`ScrollViewReader.scrollTo(_:anchor:)`** — existing iOS 17 API; no change to call site pattern, only the gating predicate.
- **`AppLogger.log(...)` with `.nativeChat` category** — the existing app-wide log facade; the new handlers add log lines for traceability (`scrollRequest kind=...`, `historyLoaded triggering multi-poll`, `userHasScrolled set to true`).
- **`OSAllocatedUnfairLock<String?>`** — pre-existing pattern in `HistoryLoader.loadHistory()` (reentrancy guard, unchanged).

## Out of Scope (Future Work)

- **`loadedCachedHistory` staleness check** — same pattern as the `loadedNetworkHistory` staleness check at HistoryLoader:154-158. Not related to scroll jitter; leave for a separate PR.
- **`loadHistoryLock` short-circuit on re-entry** — current code lets concurrent `loadHistory` calls for the same session key each spawn a task (the lock only logs "already in progress"). Could short-circuit the second call, but again, not related to scroll jitter.
- **"网络断开时顶部信息缺失" + "重新联网后 cache 不显示"** — the user's other two reported issues. Per their explicit instruction, this plan only fixes scroll jitter. The other two are tracked for the next round.
- **Pagination** (`loadMoreHistory` is currently a no-op) — placeholder, not in scope.
- **Replacing the `MarkdownViewTextKit` async height measurement with a sync measurement** — would let us drop the multi-poll cascade entirely, but it's an SDK-side change.

## Why This Fix Was Needed (Background)

`NativeChatView` was listening to 4 independent scroll triggers:

1. `.onChange(of: viewModel.messages.count)` — fired on every array mutation, including streaming text updates and precompute-driven `messages` re-assignments from `loadedNetworkHistory`.
2. `.onChange(of: viewModel.scrollTrigger)` — fired 3× per `receiveMessage` (id-match, similar-match, fresh-insert branches) and 1× per `loaded*History` method.
3. `.onChange(of: viewModel.cacheLoadCounter)` — fired 3× per `loaded*History` method (once direct + once in a `Task` via `incrementCacheCounter`); its handler did a 5-poll cascade (0/0.2/0.5/1.0/2.0s) to catch the `MarkdownViewTextKit` async height measurement.
4. `.onChange(of: viewModel.needsScrollToBottom)` — fired from `appendNewMessages`.

Net effect: a single `loadedCachedHistory` call triggered **1 (scrollTrigger) + 1 (cacheLoadCounter direct) + 1 (cacheLoadCounter via Task) + 1 (messages.count, since `vm.messages = messages` mutates count) = 4 separate `onChange` fires**, and the `cacheLoadCounter` handler alone did **5 `scrollTo` polls**. Total per history load: ~11+ `scrollTo` calls, each capturing a different layout state. The viewport kept re-anchoring against fresh layouts, producing the visible up-down jitter. The `MarkdownViewTextKit` async height measurement (which kicks in after the first frame) was the root cause: each `scrollTo` raced with a still-incomplete layout, so the viewport kept snapping to wrong positions as the bubble's true height arrived.

The fix consolidates the model side (1 signal per event) and uses a kind-tagged handler on the view side (1 scroll for new messages, 5 polls for history). Plus, the user-scroll-intent gate (`userHasScrolled`) stops the cascade from yanking the user back to the bottom while they're reading above.

---

## Verification (End-to-End)

After all 6 tasks:

1. `grep -rn "scrollTrigger\|cacheLoadCounter\|needsScrollToBottom" SmartChatApp/` — no matches.
2. `xcodebuild test` — all tests pass (50+ including the 4 new).
3. `make install` — installs to iPhone.
4. Manual smoke (Task 6 step 5) — all 7 user flows show no jitter, no yank-back.
