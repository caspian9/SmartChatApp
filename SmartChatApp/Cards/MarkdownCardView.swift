import SwiftUI
import OpenClawKit
import MarkdownDisplayView

struct MarkdownCardView: View {
    let content: String

    var body: some View {
        if #available(iOS 15.0, *) {
            MarkdownViewRepresentable(
                markdown: content,
                onLinkTap: { url in
                    UIApplication.shared.open(url)
                }
            )
        } else {
            Text(content)
                .font(.body)
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
        return view
    }

    func updateUIView(_ uiView: MarkdownViewTextKit, context: Context) {
        if uiView.markdown != markdown {
            uiView.markdown = markdown
        }
        uiView.onLinkTap = onLinkTap
    }
}

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