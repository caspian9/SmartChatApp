import SwiftUI

public struct MusicCardView: View {
    let data: MusicCardData
    @State private var isPlaying = false
    @State private var progress: Double = 0

    public init(data: MusicCardData) {
        self.data = data
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                AsyncImage(url: data.albumArt) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .failure:
                        imagePlaceholder
                    case .empty:
                        imagePlaceholder
                            .overlay(ProgressView())
                    @unknown default:
                        imagePlaceholder
                    }
                }
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 4) {
                    Text(data.title)
                        .font(.headline)
                        .lineLimit(1)

                    if let artist = data.artist {
                        Text(artist)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if let duration = data.formattedDuration {
                        Text(duration)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                Button(action: togglePlayback) {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title)
                        .foregroundStyle(.primary)
                }
            }

            if isPlaying {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
            }

            HStack(spacing: 16) {
                Button(action: skipBackward) {
                    Image(systemName: "backward.fill")
                        .foregroundStyle(.secondary)
                }

                Button(action: togglePlayback) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .foregroundStyle(.primary)
                }

                Button(action: skipForward) {
                    Image(systemName: "forward.fill")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let url = data.externalUrl {
                    Button(action: { openUrl(url) }) {
                        Image(systemName: "safari")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .font(.title3)
        }
        .padding()
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var imagePlaceholder: some View {
        Rectangle()
            .fill(Color.gray.opacity(0.3))
            .overlay(
                Image(systemName: "music.note")
                    .foregroundStyle(.secondary)
            )
    }

    private func togglePlayback() {
        isPlaying.toggle()
        if isPlaying {
            startProgressTimer()
        }
    }

    private func skipBackward() {
        progress = max(0, progress - 0.1)
    }

    private func skipForward() {
        progress = min(1, progress + 0.1)
    }

    private func startProgressTimer() {
        // Simulated progress for preview
        if isPlaying {
            withAnimation(.linear(duration: 1)) {
                progress = min(1, progress + 0.01)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if self.isPlaying {
                    self.startProgressTimer()
                }
            }
        }
    }

    private func openUrl(_ url: URL) {
        // Would open external player
    }
}
