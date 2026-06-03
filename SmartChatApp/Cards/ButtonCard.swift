import SwiftUI

struct ButtonCardContent: View {
    let toolCall: ToolCall
    let actionTitle: String

    private var buttonInfo: (title: String, description: String, url: String)? {
        guard let data = toolCall.arguments.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let title = dict["title"] as? String ?? actionTitle
        let description = dict["description"] as? String ?? ""
        let url = dict["url"] as? String ?? ""
        return (title, description, url)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let info = buttonInfo {
                VStack(alignment: .leading, spacing: 4) {
                    Text(info.title)
                        .font(.headline)
                        .foregroundColor(.white)

                    Text(info.description)
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }

            Button(action: {
                if let urlString = buttonInfo?.url, let url = URL(string: urlString) {
                    UIApplication.shared.open(url)
                }
            }) {
                Text(actionTitle)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color(hex: "10A37F"))
                    .foregroundColor(.white)
                    .cornerRadius(8)
                    .font(.headline)
            }
        }
        .padding()
        .background(Color(hex: "1E1E1E"))
        .cornerRadius(12)
    }
}
