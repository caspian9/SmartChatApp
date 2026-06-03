import SwiftUI

struct ThinkingCardView: View {
    let content: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "brain")
                .font(.caption)
                .foregroundColor(.purple)

            Text(formattedContent)
                .font(.caption)
                .foregroundColor(.secondary)
                .italic()
        }
        .padding(8)
        .background(Color.purple.opacity(0.1))
        .cornerRadius(8)
    }

    private var formattedContent: String {
        content.replacingOccurrences(of: "\\n", with: "\n")
    }
}