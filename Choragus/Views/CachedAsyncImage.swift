/// CachedAsyncImage.swift — Image view backed by ImageCache (memory + disk).
///
/// Checks the two-tier cache first, then fetches from the network on miss.
/// Shows a music note placeholder while loading or on failure.
///
/// Image fetches use one of two URLSessions, each with its own connection
/// pool, so a burst of queue thumbnails from one host (per-host cap 6,
/// e.g. `i.scdn.co`) cannot delay the Now Playing art request.
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
    /// Overrides the automatic choice below. Automatic shows square art
    /// whole and crops non-square art to the frame, which keeps a grid of
    /// covers even. Force `.fill` for a backdrop that has to cover its
    /// window whatever the cover's shape, and `.fit` for a viewer whose
    /// job is to show the whole image.
    var contentMode: ContentMode?
    /// Ask the cache for a decoded thumbnail no larger than this on its
    /// longer side. Set it for cells drawn small (mosaic covers, list
    /// thumbnails) so relayout does not re-decode full-size JPEGs.
    var maxPixelSize: Int? = nil
    /// Which part of a filled image survives the crop. Centre suits
    /// artwork; `.top` suits photographs of people, whose faces sit in
    /// the upper third — a centred crop of a full-length press shot
    /// keeps the midriff and cuts the head off.
    var fillAlignment: Alignment = .center

    @State private var image: NSImage?
    /// URL of the fetch in flight. A fetch that finishes after the row
    /// has moved on to another URL compares against it and drops its
    /// result; `self.url` inside the task is the value captured at
    /// launch, so it cannot serve as that check.
    @State private var inFlightURL: URL?

    /// Memory tier only, checked in `body` so a recycled row shows its
    /// art on the first frame. Disk is never read here: a file read per
    /// row on the main thread stalls list selection. Disk and network
    /// hits arrive through `loadImage`.
    private var cachedImage: NSImage? {
        guard let url = url else { return nil }
        return ImageCache.shared.memoryImage(for: url, maxPixelSize: maxPixelSize)
    }

    var body: some View {
        Group {
            if let img = image ?? cachedImage {
                // Square art scales to FIT (whole image shown); non-square art
                // FILLS and is cropped to the frame. The Color.clear container
                // takes the proposed frame size and the clip is applied to it,
                // so an overflowing fill can't escape the frame and bleed over
                // neighbouring text.
                let s = img.size
                let isSquare = s.width > 0 && s.height > 0
                    && abs(s.width - s.height) / max(s.width, s.height) < 0.02
                let mode = contentMode ?? (isSquare ? .fit : .fill)
                Color.clear
                    .overlay(alignment: fillAlignment) {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: mode)
                    }
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
            inFlightURL = nil
            return
        }

        // Memory tier first.
        if let cached = ImageCache.shared.memoryImage(for: url, maxPixelSize: maxPixelSize) {
            image = cached
            inFlightURL = nil
            return
        }

        // Memory miss for the new URL — clear the loaded image now. `image`
        // is only assigned on success, so a failed or undecodable fetch
        // (e.g. an empty body for a file with no embedded art) would
        // otherwise leave the previous track's art on screen.
        image = nil

        guard inFlightURL != url else { return }
        // Art URIs arrive from catalogs and third-party media servers;
        // only web schemes are ever legitimate for artwork, so file:,
        // data:, ftp: and friends are refused before any fetch.
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            inFlightURL = nil
            return
        }
        inFlightURL = url

        Task {
            // Disk tier, off the main thread; then the network.
            if let disk = await ImageCache.shared.diskImage(for: url, maxPixelSize: maxPixelSize) {
                await MainActor.run {
                    guard inFlightURL == url else { return }
                    image = disk
                    inFlightURL = nil
                }
                return
            }
            do {
                let session = ImageFetchSession.session(for: priority)
                let (data, response) = try await session.data(from: url)
                if let nsImage = NSImage(data: data) {
                    // Stored as fetched. This path used to centre-crop to
                    // a square first, which is a no-op for album art but
                    // destroys an artist photo: press shots are tall
                    // portraits, the head sits in the top third, and the
                    // centre square is the midriff. It also meant nothing
                    // from the network ever reached the fit/fill branch
                    // above as non-square. Framing belongs to the view,
                    // which fits, fills and clips per frame and can be
                    // changed later; the cache keeps the original so the
                    // click-to-enlarge carousel has one to show. The
                    // other `store` callers already wrote what they
                    // fetched, so this makes every path agree.
                    ImageCache.shared.store(nsImage, for: url)
                    // The store's disk write is queued ahead of this
                    // read, so a thumbnail request decodes the file the
                    // store just wrote.
                    let shown = maxPixelSize == nil ? nsImage
                        : (await ImageCache.shared.diskImage(for: url, maxPixelSize: maxPixelSize) ?? nsImage)
                    await MainActor.run {
                        if inFlightURL == url { image = shown }
                    }
                } else {
                    // Fetched, but not decodable as an image: a 404 body, an
                    // HTML error page, or a format NSImage cannot read.
                    sonosDiagLog(.warning, tag: "ART", "Image fetched but not decodable",
                                 context: ["url": url.absoluteString,
                                           "status": String((response as? HTTPURLResponse)?.statusCode ?? -1),
                                           "bytes": String(data.count),
                                           "type": (response as? HTTPURLResponse)?
                                               .value(forHTTPHeaderField: "Content-Type") ?? "?"])
                }
            } catch {
                // Logged: ATS refusals, timeouts and refused connections
                // are otherwise indistinguishable from "no art".
                sonosDiagLog(.warning, tag: "ART", "Image fetch failed",
                             context: ["url": url.absoluteString,
                                       "error": error.localizedDescription])
            }
            await MainActor.run {
                if inFlightURL == url { inFlightURL = nil }
            }
        }
    }
}
