import SwiftUI
import AVKit

public struct VideoCardView: View {
    let data: VideoCardData
    @State private var isPlaying = false
    @State private var showFullscreen = false

    public init(data: VideoCardData) {
        self.data = data
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                AsyncImage(url: data.thumbnail) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .failure:
                        thumbnailPlaceholder
                    case .empty:
                        thumbnailPlaceholder
                            .overlay(ProgressView())
                    @unknown default:
                        thumbnailPlaceholder
                    }
                }
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                Button(action: togglePlayback) {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.white)
                        .shadow(radius: 4)
                }
            }

            HStack {
                Text(data.title)
                    .font(.headline)
                    .lineLimit(2)

                Spacer()

                if let duration = data.formattedDuration {
                    Text(duration)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.1))
                        .clipShape(Capsule())
                }
            }

            HStack {
                Button(action: togglePlayback) {
                    Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)

                Button(action: { showFullscreen = true }) {
                    Label("Fullscreen", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)

                Spacer()

                if let url = data.previewUrl {
                    Button(action: { openUrl(url) }) {
                        Image(systemName: "safari")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding()
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .fullScreenCover(isPresented: $showFullscreen) {
            VideoPlayerView(data: data, isPresented: $showFullscreen)
        }
    }

    private var thumbnailPlaceholder: some View {
        Rectangle()
            .fill(Color.gray.opacity(0.3))
            .overlay(
                Image(systemName: "video.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            )
    }

    private func togglePlayback() {
        isPlaying.toggle()
    }

    private func openUrl(_ url: URL) {
        // Would open external player
    }
}

private struct VideoPlayerView: View {
    let data: VideoCardData
    @Binding var isPresented: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack {
                HStack {
                    Spacer()
                    Button(action: { isPresented = false }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundStyle(.white)
                    }
                    .padding()
                }

                Spacer()

                if let url = data.previewUrl {
                    VideoPlayer(player: AVPlayer(url: url))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Image(systemName: "video.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.white)
                }

                Spacer()
            }
        }
    }
}
