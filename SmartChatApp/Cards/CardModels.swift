import Foundation

public struct MusicCardData {
    public let id: String
    public let title: String
    public let artist: String?
    public let albumArt: URL?
    public let durationMs: Int?
    public let previewUrl: URL?
    public let externalUrl: URL?

    public init(
        id: String,
        title: String,
        artist: String? = nil,
        albumArt: URL? = nil,
        durationMs: Int? = nil,
        previewUrl: URL? = nil,
        externalUrl: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.albumArt = albumArt
        self.durationMs = durationMs
        self.previewUrl = previewUrl
        self.externalUrl = externalUrl
    }

    public var formattedDuration: String? {
        guard let ms = durationMs else { return nil }
        let seconds = ms / 1000
        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }
}

public struct VideoCardData {
    public let id: String
    public let title: String
    public let thumbnail: URL?
    public let durationMs: Int?
    public let previewUrl: URL?

    public init(
        id: String,
        title: String,
        thumbnail: URL? = nil,
        durationMs: Int? = nil,
        previewUrl: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.thumbnail = thumbnail
        self.durationMs = durationMs
        self.previewUrl = previewUrl
    }

    public var formattedDuration: String? {
        guard let ms = durationMs else { return nil }
        let seconds = ms / 1000
        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }
}

public struct ButtonCardData {
    public let id: String
    public let title: String
    public let url: URL
    public let style: ButtonStyle

    public init(id: String, title: String, url: URL, style: ButtonStyle = .primary) {
        self.id = id
        self.title = title
        self.url = url
        self.style = style
    }

    public enum ButtonStyle {
        case primary
        case secondary
        case link
    }
}

public struct ImageCardData {
    public let id: String
    public let imageUrl: URL
    public let altText: String?
    public let fullscreenUrl: URL?

    public init(
        id: String,
        imageUrl: URL,
        altText: String? = nil,
        fullscreenUrl: URL? = nil
    ) {
        self.id = id
        self.imageUrl = imageUrl
        self.altText = altText
        self.fullscreenUrl = fullscreenUrl
    }
}
