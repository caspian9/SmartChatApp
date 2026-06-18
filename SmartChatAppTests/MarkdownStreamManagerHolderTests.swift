import XCTest
@testable import SmartChatApp

/// Regression: `MarkdownStreamManager.holder(for:)` was auto-resetting
/// existing holders on every access. `StreamingMarkdownRepresentable`'s
/// `makeUIView` calls `holder(for:)` whenever SwiftUI recreates the
/// streaming UIView (any re-render that produces a new view instance),
/// and the auto-reset wiped the holder's `lastReceivedText`. The
/// next `appendCumulative` then computed its suffix against an empty
/// `lastReceivedText` and re-fed the FULL cumulative text to the
/// TextKit view — the same content appended on top of itself,
/// producing the user-reported "same assistant response rendered 4x"
/// duplicate.
///
/// The fix removes the auto-reset; `reset()` remains as a no-arg
/// method that callers invoke explicitly when re-entering (e.g. on
/// session switch via `releaseAll()`). This test locks in the
/// "second access does NOT reset" contract.
@MainActor
final class MarkdownStreamManagerHolderTests: XCTestCase {
    private let messageId = "r-hold-1"

    override func setUp() async throws {
        MarkdownStreamManager.shared.releaseAll()
    }

    override func tearDown() async throws {
        MarkdownStreamManager.shared.releaseAll()
    }

    func test_holderFor_existingHolder_doesNotResetStreamingState() async throws {
        // First access — create + begin. Mirrors what
        // `StreamingMarkdownRepresentable.makeUIView` does on the
        // first time the streaming view appears.
        let h1 = MarkdownStreamManager.shared.holder(for: messageId)
        h1.begin()
        // First chunk: cumulative is fresh, lastReceived was empty, so
        // the whole string is the suffix.
        let s1 = h1.appendCumulative("Hello, world")
        XCTAssertEqual(s1, "Hello, world",
            "First appendCumulative should emit the full cumulative text as the suffix")
        // Second access — this is what SwiftUI does when it recreates
        // the streaming UIView (parent re-render, view-tree change,
        // etc.). `StreamingMarkdownRepresentable.makeUIView` calls
        // `holder(for:)` then `begin()` — so the second access here
        // mirrors that flow. Pre-fix, `holder(for:)` auto-reset the
        // existing holder (clearing lastReceivedText), then begin()
        // re-armed it; the next appendCumulative then computed a
        // full-text suffix against an empty lastReceivedText and
        // re-fed the entire cumulative to the TextKit view — the
        // user-reported "same assistant response rendered 4x"
        // duplication.
        let h2 = MarkdownStreamManager.shared.holder(for: messageId)
        XCTAssertTrue(h1 === h2,
            "holder(for:) must return the same instance on repeated access")
        h2.begin()
        // The critical assertion: the second appendCumulative with
        // the SAME cumulative text must compute an empty suffix,
        // because lastReceivedText was preserved. Pre-fix this
        // returned "Hello, world" (the full text was re-appended to
        // the view) — duplicating the bubble content.
        let s2 = h2.appendCumulative("Hello, world")
        XCTAssertEqual(s2, "",
            "Repeated holder(for:)+begin() must not reset lastReceivedText — pre-fix the holder reset and the next appendCumulative re-fed the full cumulative text, causing visible duplication")
    }

    func test_holderFor_existingHolder_doesNotResetAfterEnd() async throws {
        // After `end()`, the streaming is over. The holder is still
        // in the manager (release happens later in the lifecycle
        // cleanup). A subsequent `holder(for:)` re-access should not
        // reset `lastReceivedText` — the streaming state is final
        // and should be preserved (e.g. for `currentText()` to keep
        // returning the last text, or for re-render safety). Pre-fix
        // the auto-reset would re-enable appendCumulative by
        // clearing `isEnded = false` via `begin()` from
        // `StreamingMarkdownRepresentable.makeUIView` after a
        // subsequent makeUIView.
        let h1 = MarkdownStreamManager.shared.holder(for: messageId)
        h1.begin()
        h1.appendCumulative("Final text")
        h1.end()
        // Re-access after end.
        let h2 = MarkdownStreamManager.shared.holder(for: messageId)
        XCTAssertTrue(h1 === h2)
        // `currentText` should still report the final text — the
        // reset path would clear `lastReceivedText` and break this.
        XCTAssertEqual(h2.currentText(), "Final text",
            "Re-access after end must not wipe the final streaming state")
    }

    func test_reset_clearsStreamingState() async throws {
        // Sanity check: the explicit `reset()` API still works. This
        // is the contract callers (e.g. `MarkdownStreamManager.release`,
        // session-switch paths) rely on. Removing the auto-reset
        // must NOT remove the ability to reset on demand.
        let h = MarkdownStreamManager.shared.holder(for: messageId)
        h.begin()
        h.appendCumulative("Some text")
        h.reset()
        // After reset, hasBegun=false; appendCumulative is a no-op
        // (the guard `guard hasBegun, !isEnded else { return "" }`
        // short-circuits). The caller must `begin()` to re-arm.
        XCTAssertEqual(h.appendCumulative("Fresh text"), "",
            "After reset() and before begin(), appendCumulative must be a no-op (guard blocks on hasBegun=false)")
        // Now re-arm and verify the streaming state is truly fresh:
        // first appendCumulative after begin() sees an empty
        // lastReceivedText, so the whole cumulative is the suffix.
        h.begin()
        XCTAssertEqual(h.appendCumulative("Fresh text"), "Fresh text",
            "After reset+begin, lastReceivedText must be empty so the next appendCumulative emits the full text as suffix")
        // And once we've appended it, a second call with the same
        // text computes an empty suffix — the streaming state
        // tracker has been properly re-primed.
        XCTAssertEqual(h.appendCumulative("Fresh text"), "",
            "After reset+begin+firstAppend, a second same-text appendCumulative should compute an empty suffix (lastReceivedText is now 'Fresh text')")
    }
}
