import SwiftUI

struct EntryCard: View {
    @Environment(\.theme) private var theme
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 48))
                    .foregroundColor(theme.primary)

                Text(title)
                    .font(.system(size: 14))
                    .foregroundColor(theme.textPrimary)
            }
            .frame(width: 150, height: 120)
            .background(theme.cardBackground)
            .cornerRadius(12)
        }
        .buttonStyle(PlainButtonStyle())
    }
}