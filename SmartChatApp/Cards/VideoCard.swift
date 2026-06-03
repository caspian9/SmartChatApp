import SwiftUI

struct VideoCardContent: CardView {
    let toolCall: ToolCall
    @State private var isPlaying = false

    private var videoInfo: (title: String, duration: String)? {
        guard let data = toolCall.arguments.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let title = dict["title"] as? String ?? "Video"
        let duration = dict["duration"] as? String ?? ""
        return (title, duration)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "video.fill")
                    .foregroundColor(Color(hex: "10A37F"))
                if let info = videoInfo {
                    VStack(alignment: .leading) {
                        Text(info.title)
                            .font(.headline)
                            .foregroundColor(.white)
                        Text(info.duration)
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
                Spacer()
            }

            ZStack {
                Rectangle()
                    .fill(Color.black)
                    .aspectRatio(16/9, contentMode: .fit)
                    .cornerRadius(8)

                Button(action: { isPlaying = true }) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 50))
                        .foregroundColor(.white)
                }
            }

            HStack(spacing: 16) {
                Button(action: { isPlaying = true }) {
                    Label("Play", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color(hex: "10A37F"))
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }

                Button(action: {}) {
                    Label("Open in App", systemImage: "arrow.up.right.square")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color(hex: "2E2E2E"))
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
            }
        }
        .padding()
        .background(Color(hex: "1E1E1E"))
        .cornerRadius(12)
    }
}
