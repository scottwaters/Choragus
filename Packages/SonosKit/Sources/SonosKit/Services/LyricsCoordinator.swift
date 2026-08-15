/// Single source of truth for lyrics state across the inline Now
/// Playing panel and the karaoke popout window. Holds the resolved
/// `Lyrics` value, memoised parsed-LRC lines, current load status,
/// and the user-tweaked timing offset — all keyed by `TrackMetadata.stableKey`.
///
/// Both surfaces become pure consumers: `loadIfNeeded` is idempotent
/// (first caller wins, subsequent callers no-op while a fetch is in
/// flight or already complete), and offset writes propagate through
/// `@Published` so a change in either window is visible to the other
/// within one SwiftUI re-render. Persistence is also coalesced — one
/// debounced disk write per track regardless of how many surfaces
/// tweak the offset.
import Combine
import Foundation
import SwiftUI

@MainActor
public final class LyricsCoordinator: ObservableObject {
    public enum Status: Equatable, Sendable {
        case idle, loading, loaded, missing
    }

    public struct Resolved: Equatable, Sendable {
        public let lyrics: Lyrics?
        public let status: Status
        public init(lyrics: Lyrics? = nil, status: Status = .idle) {
            self.lyrics = lyrics
            self.status = status
        }
    }

    @Published public private(set) var resolved: [String: Resolved] = [:]
    @Published public private(set) var offsets: [String: Double] = [:]

    private let lyricsService: LyricsService
    private var loadTasks: [String: Task<Void, Never>] = [:]
    private var saveTasks: [String: Task<Void, Never>] = [:]
    private var parseCache: [String: [(time: Double, line: String)]] = [:]

    public init(lyricsService: LyricsService) {
        self.lyricsService = lyricsService
    }

    // MARK: - Resolved lyrics

    public func resolved(for metadata: TrackMetadata) -> Resolved {
        resolved[metadata.stableKey] ?? Resolved()
    }

    /// Memoised parsed LRC lines for the track. Parses on first call;
    /// subsequent calls return the cached vector. Cleared when the
    /// underlying lyrics value changes.
    public func parsedLines(for metadata: TrackMetadata) -> [(time: Double, line: String)] {
        let key = metadata.stableKey
        if let cached = parseCache[key] { return cached }
        guard let synced = resolved[key]?.lyrics?.synced, !synced.isEmpty else { return [] }
        let parsed = Lyrics.parseSynced(synced)
        parseCache[key] = parsed
        return parsed
    }

    /// Idempotent fetch trigger. Either surface can call this on track
    /// change; first caller wins, subsequent callers no-op while a
    /// fetch is in flight or already complete. `LyricsService` handles
    /// its own SQLite cache, so a cold-start fetch is one disk read
    /// shared by every consumer.
    public func loadIfNeeded(for metadata: TrackMetadata) {
        let key = metadata.stableKey
        // Eagerly populate the offset from disk so body-time
        // `offset(for:)` reads can't mutate `@Published offsets` on a
        // cache miss — the resulting publisher tick was contributing
        // to per-frame re-renders during karaoke playback.
        if offsets[key] == nil {
            // Placeholder now, disk later: the previous synchronous
            // read ran dbQueue.sync SQLite on the MAIN actor — when
            // the shared play_history DB was contended (track-change
            // insert + metadata reads), main blocked up to ~850 ms
            // on every track change. The placeholder keeps body-time
            // `offset(for:)` reads pure; the real value lands
            // asynchronously and only overwrites an untouched
            // placeholder (a user scrub in the gap wins).
            offsets[key] = 0
            let service = lyricsService
            let artist = metadata.artist
            let title = metadata.title
            let album = metadata.album.isEmpty ? nil : metadata.album
            Task { [weak self] in
                let saved = await Task.detached(priority: .utility) {
                    service.loadOffset(artist: artist, title: title, album: album)
                }.value ?? 0
                guard let self, saved != 0, self.offsets[key] == 0 else { return }
                self.offsets[key] = saved
            }
        }
        // `.missing` is terminal: the service has already cached the
        // miss, so re-triggering on every call only burns a task per
        // render. `refresh(for:)` is the explicit retry path.
        if let existing = resolved[key],
           existing.status == .loading || existing.status == .loaded || existing.status == .missing {
            return
        }
        guard !metadata.title.isEmpty else {
            resolved[key] = Resolved(status: .idle)
            return
        }

        resolved[key] = Resolved(status: .loading)
        loadTasks[key]?.cancel()
        let service = lyricsService
        let artist = metadata.artist
        let title = metadata.title
        let album = metadata.album.isEmpty ? nil : metadata.album
        let durationSec = metadata.duration > 0 ? Int(metadata.duration) : nil
        let trackURI = metadata.trackURI

        loadTasks[key] = Task { [weak self] in
            let result = await service.fetch(
                artist: artist, title: title,
                album: album, durationSeconds: durationSec,
                trackURI: trackURI
            )
            if Task.isCancelled { return }
            guard let self else { return }
            self.parseCache.removeValue(forKey: key)
            self.resolved[key] = Resolved(
                lyrics: result,
                status: result == nil ? .missing : .loaded
            )
        }
    }

    /// Drops the cached lyric + parse for a single track and re-fetches.
    /// Wired to the panel's right-click "Refresh metadata" so users can
    /// pull updated content without waiting for the cache TTL.
    public func refresh(for metadata: TrackMetadata) {
        let key = metadata.stableKey
        loadTasks[key]?.cancel()
        resolved.removeValue(forKey: key)
        parseCache.removeValue(forKey: key)
        loadIfNeeded(for: metadata)
    }

    // MARK: - Offset

    public func offset(for metadata: TrackMetadata) -> Double {
        let key = metadata.stableKey
        if let cached = offsets[key] { return cached }
        let saved = lyricsService.loadOffset(
            artist: metadata.artist,
            title: metadata.title,
            album: metadata.album.isEmpty ? nil : metadata.album
        ) ?? 0
        offsets[key] = saved
        return saved
    }

    public func setOffset(_ value: Double, for metadata: TrackMetadata) {
        let key = metadata.stableKey
        guard offsets[key] != value else { return }
        offsets[key] = value
        scheduleOffsetSave(for: metadata, key: key, value: value)
    }

    public func offsetBinding(for metadata: TrackMetadata) -> Binding<Double> {
        Binding(
            get: { [weak self] in self?.offsets[metadata.stableKey] ?? 0 },
            set: { [weak self] new in self?.setOffset(new, for: metadata) }
        )
    }

    private func scheduleOffsetSave(for metadata: TrackMetadata, key: String, value: Double) {
        guard !metadata.title.isEmpty else { return }
        saveTasks[key]?.cancel()
        let service = lyricsService
        let artist = metadata.artist
        let title = metadata.title
        let album = metadata.album.isEmpty ? nil : metadata.album
        saveTasks[key] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return }
            service.saveOffset(artist: artist, title: title, album: album, seconds: value)
            self?.saveTasks[key] = nil
        }
    }
}
