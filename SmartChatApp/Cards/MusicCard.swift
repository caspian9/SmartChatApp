import SwiftUI

struct MusicCardContent: CardView {
    let toolCall: ToolCall
    @State private var isPlaying = false
    @State private var progress: Double = 0.0
    @State private var volume: Double = 0.7

    private var trackInfo: (title: String, artist: String)? {
        guard let data = toolCall.arguments.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let title = dict["title"] as? String ?? "Unknown Title"
        let artist = dict["artist"] as? String ?? "Unknown Artist"
        return (title, artist)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "music.note")
                    .foregroundColor(Color(hex: "10A37F"))
                if let info = trackInfo {
                    VStack(alignment: .leading) {
                        Text(info.title)
                            .font(.headline)
                            .foregroundColor(.white)
                        Text(info.artist)
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
                Spacer()
            }

            if isPlaying {
                HStack {
                    Text(formatTime(progress))
                        .font(.caption2)
                        .foregroundColor(.gray)

                    Slider(value: $progress, in: 0...1)
                        .tint(Color(hex: "10A37F"))

                    Text(formatTime(1.0))
                        .font(.caption2)
                        .foregroundColor(.gray)
                }

                HStack {
                    Image(systemName: "speaker.fill")
                        .foregroundColor(.gray)
                    Slider(value: $volume, in: 0...1)
                        .tint(Color(hex: "10A37F"))
                    Image(systemName: "speaker.wave.3.fill")
                        .foregroundColor(.gray)
                }

                HStack(spacing: 40) {
                    Button(action: {}) { Image(systemName: "backward.fill").font(.title2).foregroundColor(.white) }
                    Button(action: { isPlaying.toggle() }) { Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.largeTitle).foregroundColor(Color(hex: "10A37F")) }
                    Button(action: {}) { Image(systemName: "forward.fill").font(.title2).foregroundColor(.white) }
                }
                .frame(maxWidth: .infinity)
            } else {
                Button(action: { isPlaying = true }) {
                    Label("Play", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color(hex: "10A37F"))
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
            }
        }
        .padding()
        .background(Color(hex: "1E1E1E"))
        .cornerRadius(12)
    }

    private func formatTime(_ time: Double) -> String {
        let minutes = Int(time * 4)
        return "\(minutes / 60):\(String(format: "%02d", minutes % 60))"
    }
}
