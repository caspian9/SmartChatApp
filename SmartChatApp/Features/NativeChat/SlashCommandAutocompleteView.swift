import SwiftUI

struct SlashCommandAutocompleteView: View {
    let candidates: [SlashCommand]
    let onSelect: (SlashCommand) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(candidates) { cmd in
                    Button {
                        onSelect(cmd)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(cmd.id)
                                    .font(.system(size: 13,
                                                  weight: .semibold))
                                if cmd.source == .server {
                                    Text("server")
                                        .font(.system(size: 9))
                                        .foregroundColor(
                                            theme.textSecondary)
                                }
                            }
                            Text(cmd.description)
                                .font(.system(size: 10))
                                .foregroundColor(theme.textSecondary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(theme.cardBackground)
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 56)
    }
}
