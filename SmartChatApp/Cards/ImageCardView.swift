import SwiftUI

public struct ImageCardView: View {
    let data: ImageCardData
    @State private var showFullscreen = false

    public init(data: ImageCardData) {
        self.data = data
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AsyncImage(url: data.imageUrl) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .onTapGesture {
                            showFullscreen = true
                        }
                case .failure:
                    imagePlaceholder
                case .empty:
                    imagePlaceholder
                        .overlay(ProgressView())
                @unknown default:
                    imagePlaceholder
                }
            }
            .frame(maxHeight: 300)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            if let altText = data.altText {
                Text(altText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .fullScreenCover(isPresented: $showFullscreen) {
            FullscreenImageView(data: data, isPresented: $showFullscreen)
        }
    }

    private var imagePlaceholder: some View {
        Rectangle()
            .fill(Color.gray.opacity(0.3))
            .frame(height: 200)
            .overlay(
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            )
    }
}

private struct FullscreenImageView: View {
    let data: ImageCardData
    @Binding var isPresented: Bool
    @State private var scale: CGFloat = 1.0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            AsyncImage(url: data.fullscreenUrl ?? data.imageUrl) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(scale)
                        .gesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    scale = value
                                }
                                .onEnded { _ in
                                    withAnimation {
                                        scale = max(1.0, min(scale, 3.0))
                                    }
                                }
                        )
                        .onTapGesture(count: 2) {
                            withAnimation {
                                scale = scale > 1.0 ? 1.0 : 2.0
                            }
                        }
                case .failure:
                    Image(systemName: "photo")
                        .font(.largeTitle)
                        .foregroundStyle(.white)
                case .empty:
                    ProgressView()
                @unknown default:
                    EmptyView()
                }
            }

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
            }
        }
    }
}
