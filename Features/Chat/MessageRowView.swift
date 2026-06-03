import SwiftUI

struct MessageRowView: View {
    let message: Message
    @ObservedObject var cardRegistry = CardRegistry.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: message.role == .user ? "person.fill" : "brain")
                    .foregroundColor(message.role == .user ? Color(hex: "10A37F") : .purple)
                    .frame(width: 30, height: 30)
                    .background(
                        Circle()
                            .fill(message.role == .user ? Color(hex: "10A37F").opacity(0.2) : Color.purple.opacity(0.2))
                    )

                VStack(alignment: .leading, spacing: 8) {
                    if !message.content.isEmpty {
                        Text(message.content)
                            .font(.body)
                            .foregroundColor(.white)
                            .textSelection(.enabled)
                    }

                    if let toolCalls = message.toolCalls {
                        ForEach(toolCalls) { toolCall in
                            if cardRegistry.canHandle(toolCall) {
                                cardRegistry.createCard(for: toolCall)
                            } else {
                                UnknownCardView(toolCall: toolCall)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(message.role == .user ? Color(hex: "2E2E2E") : Color.clear)
        .cornerRadius(12)
    }
}