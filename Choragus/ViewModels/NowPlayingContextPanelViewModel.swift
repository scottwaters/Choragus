/// NowPlayingContextPanelViewModel.swift — Owns the metadata
/// state machine for the Lyrics / About / History panel.
///
/// Pulls lyrics from `LyricsService`, artist + album info from
/// `MusicMetadataService`, and persists the per-track lyrics offset.
/// The View renders state and dispatches actions; all the async
/// orchestration (cache hit checks, lazy loads, debounced saves,
/// background pre-warming, refresh) lives here so the View stays
/// declarative.
import Foundation
import SonosKit

/// State of one async metadata fetch (lyrics or about).
enum ContextLoadState: Equatable {
    case idle, loading, loaded, missing
    case error(String)

    static func == (lhs: ContextLoadState, rhs: ContextLoadState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading),
             (.loaded, .loaded), (.missing, .missing):
            return true
        case let (.error(a), .error(b)):
            return a == b
        default:
            return false
        }
    }
}

@MainActor
@Observable
final class NowPlayingContextPanelViewModel {
    // MARK: - Lyrics state
    var lyrics: Lyrics?
    var lyricsState: ContextLoadState = .idle
    /// Per-track lyrics timing offset in seconds. Restored from cache
    /// on every track change (defaults to 0); persisted via the
    /// LyricsService whenever the user nudges. Positive = lyrics earlier.
    var lyricsOffset: Double = 0

    // MARK: - About state
    var artistInfo: ArtistInfo?
    var albumInfo: AlbumInfo?
    var aboutState: ContextLoadState = .idle

    // MARK: - Dependencies
    private let lyricsService: LyricsService
    private let metadataService: MusicMetadataService

    /// Holds the in-flight debounced offset save so a flurry of taps
    /// coalesces into a single write at the final value.
    private var offsetSaveTask: Task<Void, Never>?

    init(lyricsService: LyricsService, metadataService: MusicMetadataService) {
        self.lyricsService = lyricsService
        self.metadataService = metadataService
    }

    // MARK: - Lifecycle

    /// Reset all state for a new track and restore the persisted
    /// lyrics offset (if any). Call from the View's `.task(id:)`
    /// before triggering a load.
    func resetForNewTrack(_ metadata: TrackMetadata) {
        lyrics = nil
        lyricsState = .idle
        artistInfo = nil
        albumInfo = nil
        aboutState = .idle
        // Reset to 0 first so a rapid track skip doesn't briefly show
        // the previous track's offset before the persisted one lands.
        lyricsOffset = 0
        if let saved = lyricsService.loadOffset(
            artist: metadata.artist,
            title: metadata.title,
            album: metadata.album.isEmpty ? nil : metadata.album
        ) {
            lyricsOffset = saved
        }
    }

    /// Loads whichever tab is currently active, then pre-warms the
    /// other one in the background so tab switches are instant.
    func loadActiveTab(
        _ tab: NowPlayingContextPanelTab,
        metadata: TrackMetadata
    ) async {
        guard !metadata.title.isEmpty else { return }
        switch tab {
        case .lyrics: await loadLyrics(metadata)
        case .about:  await loadAbout(metadata)
        case .history: break
        }
        warmInactiveTabCaches(active: tab, metadata: metadata)
    }

    /// Drops the cached artist + album entries for this track and
    /// re-runs the About fetch. Wired to the right-click context menu
    /// so users can pull updated info without waiting for the 30-day
    /// cache TTL.
    func refreshAbout(_ metadata: TrackMetadata) async {
        guard !metadata.title.isEmpty else { return }
        if !metadata.artist.isEmpty {
            metadataService.invalidateArtist(name: metadata.artist)
        }
        if !metadata.album.isEmpty {
            metadataService.invalidateAlbum(artist: metadata.artist, album: metadata.album)
        }
        artistInfo = nil
        albumInfo = nil
        aboutState = .idle
        await loadAbout(metadata)
    }

    /// Debounced offset persistence. Cancels any in-flight save and
    /// schedules a new one for 500 ms in the future, so a tap-tap-tap
    /// of the +/- buttons coalesces into a single write at the final
    /// value. Captures the metadata at schedule time so a track change
    /// during the debounce window doesn't cross-contaminate the cache.
    func scheduleOffsetSave(_ value: Double, metadata: TrackMetadata) {
        offsetSaveTask?.cancel()
        let artist = metadata.artist
        let title = metadata.title
        let album = metadata.album.isEmpty ? nil : metadata.album
        // Don't save against a missing identifier — would write under an
        // empty key and cross-collide with whatever track is playing next.
        guard !title.isEmpty else { return }
        let service = lyricsService
        offsetSaveTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            service.saveOffset(artist: artist, title: title, album: album, seconds: value)
        }
    }

    // MARK: - Private loaders

    private func loadLyrics(_ metadata: TrackMetadata) async {
        if case .loaded = lyricsState { return }
        if case .loading = lyricsState { return }
        lyricsState = .loading
        let duration = metadata.duration > 0 ? Int(metadata.duration) : nil
        let result = await lyricsService.fetch(
            artist: metadata.artist,
            title: metadata.title,
            album: metadata.album.isEmpty ? nil : metadata.album,
            durationSeconds: duration
        )
        lyrics = result
        lyricsState = result == nil ? .missing : .loaded
    }

    private func loadAbout(_ metadata: TrackMetadata) async {
        if case .loaded = aboutState { return }
        if case .loading = aboutState { return }
        aboutState = .loading
        async let artistTask = metadataService.artistInfo(name: metadata.artist)
        async let albumTask: AlbumInfo? = metadata.album.isEmpty
            ? nil
            : metadataService.albumInfo(artist: metadata.artist, album: metadata.album)
        artistInfo = await artistTask
        albumInfo = await albumTask
        aboutState = .loaded
    }

    /// Fire-and-forget background fetches for the inactive tab(s) so
    /// the SQLite metadata cache is hot when the user switches tabs.
    /// Service-layer methods write to that cache, so subsequent
    /// `loadLyrics` / `loadAbout` calls return immediately on hit.
    private func warmInactiveTabCaches(
        active: NowPlayingContextPanelTab,
        metadata: TrackMetadata
    ) {
        guard !metadata.title.isEmpty else { return }
        let title = metadata.title
        let artist = metadata.artist
        let album = metadata.album
        let duration = metadata.duration > 0 ? Int(metadata.duration) : nil
        let lyricsRef = lyricsService
        let metadataRef = metadataService

        if active != .lyrics {
            Task {
                _ = await lyricsRef.fetch(
                    artist: artist, title: title,
                    album: album.isEmpty ? nil : album,
                    durationSeconds: duration
                )
            }
        }
        if active != .about {
            Task {
                _ = await metadataRef.artistInfo(name: artist)
                if !album.isEmpty {
                    _ = await metadataRef.albumInfo(artist: artist, album: album)
                }
            }
        }
    }
}

/// Tabs in the context panel — defined here (not nested inside the
/// View) so the ViewModel can take them as a parameter without
/// pulling in SwiftUI.
enum NowPlayingContextPanelTab: String, CaseIterable, Identifiable {
    case lyrics = "Lyrics"
    case about = "About"
    case history = "History"
    var id: String { rawValue }

    /// Localised label rendered in the segmented picker. The raw value
    /// is kept stable as a stringly-typed identifier so it can be
    /// persisted / logged without going through the L10n layer.
    var displayName: String {
        switch self {
        case .lyrics:  return L10n.tabLyrics
        case .about:   return L10n.tabAbout
        case .history: return L10n.tabHistory
        }
    }
}
