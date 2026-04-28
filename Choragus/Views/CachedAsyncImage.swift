/// CachedAsyncImage.swift — Image view backed by ImageCache (memory + disk).
///
/// Checks the two-tier cache first, then fetches from the network on miss.
/// Shows a music note placeholder while loading or on failure.
///
/// Image fetches use one of two URLSessions to avoid head-of-line
/// blocking. The single shared session was a problem when, say, a
/// Spotify queue of 50 tracks loaded all-at-once: art URLs all
/// originate from `i.scdn.co`, the per-host connection cap (6)
/// saturated, and the Now Playing art request had to wait its turn
/// behind 50 queue thumbs. Each session has its own connection pool,
/// so a queue render no longer starves Now Playing.
import SwiftUI
import SonosKit

enum ImageFetchPriority {
    /// Now Playing, menu bar, modal artwork — user is staring at this.
    case interactive
    /// Queue rows, browse lists — fine to wait if interactive is busy.
    case background
}

private enum ImageFetchSession {
    /// Dedicated to interactive surfaces. Small pool, but never blocks
    /// behind background loads.
    static let interactive: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 6
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()
    /// Browse / queue art. Independent pool.
    static let background: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 6
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    static func session(for priority: ImageFetchPriority) -> URLSession {
        priority == .interactive ? interactive : background
    }
}

struct CachedAsyncImage: View {
    let url: URL?
    var cornerRadius: CGFloat = 4
    var priority: ImageFetchPriority = .background

    @State private var image: NSImage?
    @State private var isLoading = false

    /// Check cache synchronously in body — avoids flicker on scroll recycling
    private var cachedImage: NSImage? {
        guard let url = url else { return nil }
        return ImageCache.shared.image(for: url)
    }

    var body: some View {
        Group {
            if let img = image ?? cachedImage {
                Image(nsImage: img)
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

    /// Center-crops an image to a square, keeping the shorter dimension and trimming the longer.
    private static func cropToSquare(_ source: NSImage) -> NSImage {
        let size = source.size
        guard size.width != size.height, size.width > 0, size.height > 0 else { return source }
        let side = min(size.width, size.height)
        let origin = CGPoint(x: (size.width - side) / 2, y: (size.height - side) / 2)
        let cropRect = CGRect(origin: origin, size: CGSize(width: side, height: side))
        guard let cgImage = source.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let cropped = cgImage.cropping(to: cropRect) else { return source }
        return NSImage(cgImage: cropped, size: CGSize(width: side, height: side))
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

        // Cache miss for the new URL — clear the previously-loaded image
        // immediately. Without this, a failed fetch (or one that returns
        // bytes that don't decode to NSImage, e.g. an empty body for a
        // file with no embedded art) leaves the previous track's image
        // on screen because `image` is only ever assigned on success.
        image = nil

        guard !isLoading else { return }
        isLoading = true

        Task {
            do {
                let session = ImageFetchSession.session(for: priority)
                let (data, _) = try await session.data(from: url)
                if let nsImage = NSImage(data: data) {
                    let squared = Self.cropToSquare(nsImage)
                    ImageCache.shared.store(squared, for: url)
                    await MainActor.run {
                        image = squared
                    }
                }
            } catch {
                // Silently fail — placeholder stays
            }
            await MainActor.run { isLoading = false }
        }
    }
}
