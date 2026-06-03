import SwiftUI

public struct ButtonCardView: View {
    let data: ButtonCardData
    @Environment(\.openURL) private var openURL

    public init(data: ButtonCardData) {
        self.data = data
    }

    public var body: some View {
        Button(action: openLink) {
            HStack {
                Image(systemName: iconName)
                    .font(.title3)

                Text(data.title)
                    .font(.subheadline.weight(.medium))

                Spacer()

                if data.style == .link {
                    Image(systemName: "arrow.up.right")
                        .font(.caption)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .foregroundStyle(foregroundColor)
            .background(backgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var iconName: String {
        switch data.url.scheme {
        case "https", "http":
            return "link"
        case "mailto":
            return "envelope"
        case "tel":
            return "phone"
        default:
            return "arrow.up.right.square"
        }
    }

    private var foregroundColor: Color {
        switch data.style {
        case .primary:
            return .white
        case .secondary:
            return .primary
        case .link:
            return Color(hex: "10A37F")
        }
    }

    private var backgroundColor: Color {
        switch data.style {
        case .primary:
            return Color(hex: "10A37F")
        case .secondary:
            return Color.white.opacity(0.1)
        case .link:
            return Color.clear
        }
    }

    private func openLink() {
        openURL(data.url)
    }
}
