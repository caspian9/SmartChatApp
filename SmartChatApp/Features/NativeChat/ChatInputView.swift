import SwiftUI

struct ChatInputView: View {
    @Binding var inputText: String
    let isSending: Bool
    let onSend: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .topLeading) {
                if inputText.isEmpty {
                    Text("输入消息...")
                        .foregroundColor(.gray)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                }
                TextField("", text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                    .foregroundColor(.white)
                    .lineLimit(1...3)
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