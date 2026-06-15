import SwiftUI
import OpenClawKit
import MarkdownDisplayView

// MARK: - Static (history) markdown view

struct MarkdownCardView: View {
    let content: String
    /// Backing height state. See `MarkdownViewRepresentable.makeUIView`
    /// for the "only grow" stabilization rationale.
    @State private var height: CGFloat = 0
    /// Cached `onLinkTap` closure. The previous implementation created
    /// a new closure on every parent body re-evaluation
    /// (`{ url in UIApplication.shared.open(url) }`), which caused
    /// `updateUIView` to reassign `view.onLinkTap = onLinkTap` on
    /// every re-eval. `MarkdownViewTextKit` treats the `onLinkTap`
    /// setter as a signal that some piece of its input changed and
    /// invalidates its internal TextKit layout, triggering a fresh
    /// `onHeightChange` re-measurement — which propagated as a
    /// cascade of small per-bubble height fluctuations across the
    /// entire visible LazyVStack after `lifecycle=end` (or any other
    /// state change that re-evaluates the parent). The user-visible
    /// symptom was "the entire history drifts up and down together": each bubble's
    /// height drifted by a few pixels, the LazyVStack's total
    /// content size wobbled in lockstep, and `.defaultScrollAnchor(.bottom)`
    /// pulled the viewport to follow the wobble. Hoisting the
    /// closure into a `@State` cell means the same instance is
    /// passed to the representable on every re-eval, and `updateUIView`
    /// can no-op the assignment.
    @State private var openURL: (URL) -> Void = { url in
        UIApplication.shared.open(url)
    }

    /// Match the width that `StreamingMarkdownCardView` uses, so the view-tree
    /// swap at the end of streaming doesn't shift the bubble horizontally.
    /// Without an explicit width, the static bubble's width is determined by
    /// `MarkdownViewTextKit`'s intrinsic content size, which is usually narrower
    /// than the streaming bubble's full-width frame — producing a visible
    /// layout jump when `isAssistantStreaming` flips to false.
    /// The 16*2 is the HStack padding around the bubble; the 12*2 is the
    /// bubble's own horizontal padding.
    static let bubbleChromeWidth: CGFloat = 16 * 2 + 12 * 2

    var body: some View {
        let contentWidth = UIScreen.main.bounds.width - Self.bubbleChromeWidth
        if #available(iOS 15.0, *) {
            MarkdownViewRepresentable(
                markdown: content,
                height: $height,
                onLinkTap: openURL
            )
            .frame(width: contentWidth, height: max(height, 1), alignment: .topLeading)
        } else {
            Text(content)
                .font(.body)
                .frame(width: contentWidth, height: max(height, 1), alignment: .topLeading)
        }
    }
}

@available(iOS 15.0, *)
struct MarkdownViewRepresentable: UIViewRepresentable {
    let markdown: String
    @Binding var height: CGFloat
    var onLinkTap: ((URL) -> Void)?

    func makeUIView(context: Context) -> MarkdownViewTextKit {
        let view = MarkdownViewTextKit()
        view.enableTypewriterEffect = false
        view.onLinkTap = onLinkTap
        // "Only grow" height stabilization. The 0.5pt-tolerance
        // variant (used by the streaming view) lets the binding both
        // grow and shrink, which is fine during streaming where the
        // height is monotonically increasing as text accumulates.
        // For the post-`lifecycle=end` static view, the text is
        // final and shouldn't need to shrink; allowing shrinkage
        // re-anchors the viewport to a moving bottom edge every
        // time `MarkdownViewTextKit` re-measures by a sub-point
        // (which it does as TextKit's font/line metrics settle
        // post-render). Restricting the binding to grow-only
        // (i.e. `newHeight > current`) decouples the viewport
        // position from any post-render shrinkage: the content
        // size never decreases, so the anchor stops chasing it.
        // The first measurement (likely the smallest, before
        // TextKit finishes settling) might briefly under-show the
        // bubble; subsequent larger measurements grow the frame
        // to fit, and from then on the size is stable.
        view.onHeightChange = { [weak view] newHeight in
            guard view != nil, newHeight > 0 else { return }
            DispatchQueue.main.async {
                if newHeight > self.height {
                    self.height = newHeight
                }
            }
        }
        view.markdown = markdown
        return view
    }

    func updateUIView(_ uiView: MarkdownViewTextKit, context: Context) {
        if uiView.markdown != markdown {
            uiView.markdown = markdown
        }
        // `onLinkTap` is intentionally NOT reassigned here. The
        // parent (`MarkdownCardView`) hoists its `openURL` into
        // `@State` so the same closure instance is passed on every
        // body re-eval. Reassigning it on every re-eval used to
        // trigger `MarkdownViewTextKit`'s invalidate path, which
        // re-laid out the TextKit text and fired a fresh
        // `onHeightChange` per visible bubble — the root cause of
        // the "entire history drifts up and down together" jitter. The closure
        // was set once in `makeUIView` and persists for the
        // view's lifetime, which is what we want.
    }
}

// MARK: - Streaming markdown view (uses MarkdownStreamManager)

@available(iOS 15.0, *)
struct StreamingMarkdownCardView: View {
    let messageId: String
    let content: String
    @State private var height: CGFloat = 0

    var body: some View {
        StreamingMarkdownRepresentable(messageId: messageId, height: $height)
            // Give the view an explicit width so it can compute a non-zero height.
            // MarkdownViewTextKit's intrinsicContentSize is 0 when content is empty,
            // which traps it at 0x0 inside SwiftUI's layout. Width matches
            // `MarkdownCardView.bubbleChromeWidth` so the streaming → static
            // view swap doesn't shift the bubble.
            .frame(width: UIScreen.main.bounds.width - MarkdownCardView.bubbleChromeWidth,
                   height: max(height, 1),
                   alignment: .topLeading)
    }
}

@available(iOS 15.0, *)
struct StreamingMarkdownRepresentable: UIViewRepresentable {
    let messageId: String
    @Binding var height: CGFloat

    func makeUIView(context: Context) -> MarkdownViewTextKit {
        let holder = MarkdownStreamManager.shared.holder(for: messageId)
        holder.begin()
        // The view doesn't notify SwiftUI when its height changes via appendStreamData;
        // wire onHeightChange to push the new height into the SwiftUI @Binding.
        holder.view.onHeightChange = { [weak holder] newHeight in
            guard holder != nil, newHeight > 0 else { return }
            // onHeightChange is already invoked on the main thread.
            if abs(self.height - newHeight) > 0.5 {
                self.height = newHeight
            }
        }
        return holder.view
    }

    func updateUIView(_ uiView: MarkdownViewTextKit, context: Context) {
        // Content is managed via the streaming API; do not reassign markdown here.
    }

    static func dismantleUIView(_ uiView: MarkdownViewTextKit, coordinator: ()) {
        // Holder stays alive in the manager; will be released by the view model
        // when the message is removed from state.messages.
    }
}

// MARK: - Card registry helpers (unchanged)

public struct MarkdownCardData: Equatable {
    public let id: String
    public let content: String

    public init(id: String = UUID().uuidString, content: String) {
        self.id = id
        self.content = content
    }

    public static func == (lhs: MarkdownCardData, rhs: MarkdownCardData) -> Bool {
        lhs.id == rhs.id && lhs.content == rhs.content
    }
}

public struct MarkdownToolResult: CardToolResult {
    public let cardType: CardType = .markdown
    public let toolName: String = "markdown"

    public init() {}

    public func parseResult(from arguments: AnyCodable?) -> Any? {
        guard let dict = arguments?.value as? [String: Any],
              let content = dict["content"] as? String else { return nil }
        return MarkdownCardData(content: content)
    }
}
