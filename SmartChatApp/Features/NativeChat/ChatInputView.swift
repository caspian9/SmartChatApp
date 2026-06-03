import SwiftUI

struct ChatInputView: View {
    @Binding var inputText: String
    let isSending: Bool
    let onSend: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            TextField("输入消息...", text: $inputText)
                .textFieldStyle(PlainTextFieldStyle())
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(hex: "2A2A2A"))
                .cornerRadius(20)
                .foregroundColor(.white)
                .disabled(isSending)

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