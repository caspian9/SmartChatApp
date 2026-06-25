import SwiftUI

struct ChatInputView: View {
    @Environment(\.theme) private var theme
    @Binding var inputText: String
    let isSending: Bool
    let isInputFocused: Bool
    let onSend: () -> Void
    let autocompleteCandidates: [SlashCommand]
    let onSelectCandidate: (SlashCommand) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Popup gates on BOTH: (a) input must contain a slash
            // command prefix (the candidates list is empty for plain
            // text — see `SlashCommandRouter.filter`) and (b) the
            // input must have keyboard focus, so the popup dismisses
            // when the user taps outside the input. Both conditions
            // are evaluated together so a candidate list leftover
            // from before focus loss disappears immediately.
            if isInputFocused && !autocompleteCandidates.isEmpty {
                SlashCommandAutocompleteView(
                    candidates: autocompleteCandidates,
                    onSelect: onSelectCandidate
                )
                .transition(.move(edge: .bottom))
            }
            HStack(spacing: 12) {
                ZStack(alignment: .leading) {
                    if inputText.isEmpty {
                        Text("Message...")
                            .foregroundColor(theme.textSecondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }
                    TextField("", text: $inputText, axis: .vertical)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .foregroundColor(theme.textPrimary)
                        .lineLimit(1...5)
                        .disabled(isSending)
                }
                .background(theme.inputBackground)
                .cornerRadius(20)

                if isSending {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .tint(theme.primary)
                } else {
                    Button(action: onSend) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 32))
                            .foregroundColor(theme.primary)
                    }
                    .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(theme.cardBackground)
        }
    }
}