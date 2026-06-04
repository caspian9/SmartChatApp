import SwiftUI
import OpenClawKit
import MarkdownDisplayView

// MARK: - Static (history) markdown view

struct MarkdownCardView: View {
    let content: String

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
                onLinkTap: { url in
                    UIApplication.shared.open(url)
                }
            )
            .frame(width: contentWidth, alignment: .topLeading)
        } else {
            Text(content)
                .font(.body)
                .frame(width: contentWidth, alignment: .topLeading)
        }
    }
}

@available(iOS 15.0, *)
struct MarkdownViewRepresentable: UIViewRepresentable {
    let markdown: String
    var onLinkTap: ((URL) -> Void)?

    func makeUIView(context: Context) -> MarkdownViewTextKit {
        let view = MarkdownViewTextKit()
        view.enableTypewriterEffect = false
        view.onLinkTap = onLinkTap
        view.markdown = markdown
        return view
    }

    func updateUIView(_ uiView: MarkdownViewTextKit, context: Context) {
        if uiView.markdown != markdown {
            uiView.markdown = markdown
        }
        uiView.onLinkTap = onLinkTap
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
