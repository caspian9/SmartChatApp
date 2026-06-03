import Foundation
import SwiftUI
import OpenClawKit

@MainActor
public final class CardRegistry: Observable {
    private var toolResultHandlers: [String: CardToolResult] = [:]

    public static let shared = CardRegistry()

    private init() {
        register(MusicToolResult())
        register(VideoToolResult())
        register(ButtonToolResult())
        register(ImageToolResult())
        register(MarkdownToolResult())
    }

    public func register(_ handler: CardToolResult) {
        toolResultHandlers[handler.toolName] = handler
    }

    public func canHandle(toolName: String) -> Bool {
        toolResultHandlers.keys.contains(toolName.lowercased())
    }

    public func createCard(for toolName: String, arguments: AnyCodable?) -> View? {
        guard let handler = toolResultHandlers[toolName.lowercased()] else { return nil }

        if let data = handler.parseResult(from: arguments) {
            return renderCard(type: handler.cardType, data: data)
        }
        return nil
    }

    @ViewBuilder
    private func renderCard(type: CardType, data: Any) -> some View {
        switch type {
        case .music:
            if let musicData = data as? MusicCardData {
                MusicCardView(data: musicData)
            }
        case .video:
            if let videoData = data as? VideoCardData {
                VideoCardView(data: videoData)
            }
        case .button:
            if let buttonData = data as? ButtonCardData {
                ButtonCardView(data: buttonData)
            }
        case .image:
            if let imageData = data as? ImageCardData {
                ImageCardView(data: imageData)
            }
        case .markdown:
            if let markdownData = data as? MarkdownCardData {
                MarkdownCardView(content: markdownData.content)
            }
        }
    }
}

public enum CardType: String {
    case music
    case video
    case button
    case image
    case markdown
}

public extension CardRegistry {
    static func containsMarkdown(content: String) -> Bool {
        let markdownPatterns = [
            "^#{1,6}\\s",           // Headers (# to ######)
            "\\*\\*[^*]+\\*\\*",    // Bold (**text**)
            "\\*[^*]+\\*",          // Italic (*text*)
            "```",                  // Code blocks
            "`[^`]+`",              // Inline code
            "\\[[^\\]]+\\]\\([^)]+\\)", // Links [text](url)
            "^[\\-\\*]\\s",         // List items (- or *)
            "^\\d+\\.\\s",          // Numbered lists
            ">\\s",                 // Blockquotes
            "\\|.*\\|.*\\|",        // Tables
        ]

        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmedContent.components(separatedBy: .newlines)

        for pattern in markdownPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { continue }
            for line in lines {
                let range = NSRange(line.startIndex..., in: line)
                if regex.firstMatch(in: line, options: [], range: range) != nil {
                    return true
                }
            }
        }
        return false
    }
}

public protocol CardToolResult {
    var cardType: CardType { get }
    var toolName: String { get }
    func parseResult(from arguments: AnyCodable?) -> Any?
}

public struct MusicToolResult: CardToolResult {
    public let cardType: CardType = .music
    public let toolName: String = "music_search"

    public init() {}

    public func parseResult(from arguments: AnyCodable?) -> Any? {
        guard let dict = arguments?.value as? [String: Any] else { return nil }

        let items = dict["items"] as? [[String: Any]] ?? [dict]
        return items.compactMap { item -> MusicCardData? in
            guard let id = item["id"] as? String,
                  let title = item["title"] as? String else { return nil }

            return MusicCardData(
                id: id,
                title: title,
                artist: item["artist"] as? String,
                albumArt: (item["albumArt"] as? String).flatMap { URL(string: $0) },
                durationMs: item["durationMs"] as? Int,
                previewUrl: (item["previewUrl"] as? String).flatMap { URL(string: $0) },
                externalUrl: (item["externalUrl"] as? String).flatMap { URL(string: $0) }
            )
        }
    }
}

public struct VideoToolResult: CardToolResult {
    public let cardType: CardType = .video
    public let toolName: String = "video_search"

    public init() {}

    public func parseResult(from arguments: AnyCodable?) -> Any? {
        guard let dict = arguments?.value as? [String: Any] else { return nil }

        let items = dict["items"] as? [[String: Any]] ?? [dict]
        return items.compactMap { item -> VideoCardData? in
            guard let id = item["id"] as? String,
                  let title = item["title"] as? String else { return nil }

            return VideoCardData(
                id: id,
                title: title,
                thumbnail: (item["thumbnail"] as? String).flatMap { URL(string: $0) },
                durationMs: item["durationMs"] as? Int,
                previewUrl: (item["previewUrl"] as? String).flatMap { URL(string: $0) }
            )
        }
    }
}

public struct ButtonToolResult: CardToolResult {
    public let cardType: CardType = .button
    public let toolName: String = "open_url"

    public init() {}

    public func parseResult(from arguments: AnyCodable?) -> Any? {
        guard let dict = arguments?.value as? [String: Any] else { return nil }

        guard let urlString = dict["url"] as? String,
              let url = URL(string: urlString) else { return nil }

        let title = dict["title"] as? String ?? "Open Link"
        let styleString = dict["style"] as? String ?? "primary"
        let style: ButtonCardData.ButtonStyle
        switch styleString {
        case "secondary": style = .secondary
        case "link": style = .link
        default: style = .primary
        }

        return ButtonCardData(
            id: UUID().uuidString,
            title: title,
            url: url,
            style: style
        )
    }
}

public struct ImageToolResult: CardToolResult {
    public let cardType: CardType = .image
    public let toolName: String = "image"

    public init() {}

    public func parseResult(from arguments: AnyCodable?) -> Any? {
        guard let dict = arguments?.value as? [String: Any] else { return nil }

        let imageUrl: URL?
        if let urlString = dict["url"] as? String {
            imageUrl = URL(string: urlString)
        } else if let urls = dict["urls"] as? [String], let first = urls.first {
            imageUrl = URL(string: first)
        } else {
            imageUrl = nil
        }

        guard let url = imageUrl else { return nil }

        return ImageCardData(
            id: UUID().uuidString,
            imageUrl: url,
            altText: dict["alt"] as? String,
            fullscreenUrl: (dict["fullscreenUrl"] as? String).flatMap { URL(string: $0) }
        )
    }
}