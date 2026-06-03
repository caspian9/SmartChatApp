import SwiftUI

struct ChatInputView: View {
    @Binding var inputText: String
    let isSending: Bool
    let onSend: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .leading) {
                if inputText.isEmpty {
                    Text("输入消息...")
                        .foregroundColor(.gray)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                TextEditor(text: $inputText)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .foregroundColor(.white)
                    .frame(minHeight: 36, maxHeight: 36)
                    .disabled(isSending)
            }
            .background(Color(hex: "2A2A2A"))
            .cornerRadius(20)

            if isSending {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
                    .tint(Color(hex: "10A37F"))
            } else {
                Button(action: onSend) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundColor(Color(hex: "10A37F"))
                }
                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(hex: "1E1E1E"))
    }
}