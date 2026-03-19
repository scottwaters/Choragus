/// CachedAsyncImage.swift — Image view backed by ImageCache (memory + disk).
///
/// Checks the two-tier cache first, then fetches from the network on miss.
/// Shows a music note placeholder while loading or on failure.
import SwiftUI
import SonosKit

struct CachedAsyncImage: View {
    let url: URL?
    var cornerRadius: CGFloat = 4

    @State private var image: NSImage?
    @State private var isLoading = false

    var body: some View {
        Group {
            if let image = image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            } else {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .onAppear { loadImage() }
        .onChange(of: url) { loadImage() }
    }

    private func loadImage() {
        guard let url = url else {
            image = nil
            return
        }

        // Check cache first
        if let cached = ImageCache.shared.image(for: url) {
            image = cached
            return
        }

        guard !isLoading else { return }
        isLoading = true

        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let nsImage = NSImage(data: data) {
                    ImageCache.shared.store(nsImage, for: url)
                    await MainActor.run {
                        image = nsImage
                    }
                }
            } catch {
                // Silently fail — placeholder stays
            }
            await MainActor.run { isLoading = false }
        }
    }
}
