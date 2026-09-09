/// NowPlayingContextPanelViewModel.swift — Owns the About + History
/// tab state for the Now Playing context panel. Lyrics state lives in
/// `LyricsCoordinator`, shared with the karaoke popout window.
import Foundation
import SonosKit

/// State of one async metadata fetch (about).
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
    // MARK: - About state
    var artistInfo: ArtistInfo?
    var albumInfo: AlbumInfo?
    var aboutState: ContextLoadState = .idle

    // MARK: - Dependencies
    private let lyricsCoordinator: LyricsCoordinator
    private let metadataService: MusicMetadataService

    init(lyricsCoordinator: LyricsCoordinator, metadataService: MusicMetadataService) {
        self.lyricsCoordinator = lyricsCoordinator
        self.metadataService = metadataService
    }

    // MARK: - Lifecycle

    /// Reset all per-track state for a new track. The coordinator owns
    /// the per-track lyrics + offset memoisation, so this only clears
    /// the About fetch state.
    func resetForNewTrack(_ metadata: TrackMetadata) {
        artistInfo = nil
        albumInfo = nil
        aboutState = .idle
        aboutGuard.reset()
    }

    /// Loads whichever tab is currently active, then pre-warms the
    /// other one in the background so tab switches are instant.
    func loadActiveTab(
        _ tab: NowPlayingContextPanelTab,
        metadata: TrackMetadata
    ) async {
        guard !metadata.title.isEmpty else { return }
        switch tab {
        case .lyrics:
            // Coordinator handles its own idempotent fetch.
            lyricsCoordinator.loadIfNeeded(for: metadata)
        case .about:   await loadAbout(metadata)
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

    /// Pixel-level gallery dedupe. Delegates to the service, which
    /// persists per-URL dHash records so the CPU-bound downsample runs
    /// once per image URL across sessions.
    func refinedGallery(_ urls: [URL]) async -> [URL] {
        await metadataService.refineGallery(urls)
    }

    // MARK: - Private loaders

    /// Track identity the current `aboutState` belongs to. Only a fetch
    /// for the track now showing may publish, the same track is not
    /// refetched, and a `.loaded` state for an old track must not block
    /// the new one.
    private var aboutGuard = IdentityGuard<String>()

    private func aboutIdentity(for metadata: TrackMetadata) -> String {
        "\(metadata.trackURI ?? "")|\(metadata.artist)|\(metadata.album)|\(metadata.title)"
    }

    private func loadAbout(_ metadata: TrackMetadata) async {
        let identity = aboutIdentity(for: metadata)
        guard aboutGuard.shouldFetch(identity) else { return }
        aboutGuard.beginFetch(identity)
        // Suno tracks: the "artist" is the Suno creator, which Last.fm /
        // Wikipedia don't know. Populate the About card from Suno's own creator
        // profile (avatar, bio) plus the track's style tags instead.
        if let uri = metadata.trackURI, let uuid = SunoCatalog.uuid(fromURI: uri) {
            aboutState = .loading
            let profile = await SunoResolver.artistProfile(forUUID: uuid)
            guard aboutGuard.finishFetch(identity) else { return }
            artistInfo = profile
            albumInfo = nil
            aboutState = .loaded
            return
        }
        // On radio the `artist` field frequently carries the station or
        // soundtrack name rather than the performing artist; sending it
        // to Wikipedia / MusicBrainz / Last.fm produces unrelated
        // articles. Render an empty About card instead.
        if metadata.isRadioStream || !metadata.stationName.isEmpty {
            let artistField = metadata.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            let stationField = metadata.stationName.trimmingCharacters(in: .whitespacesAndNewlines)
            let artistMatchesStation = !stationField.isEmpty &&
                artistField.caseInsensitiveCompare(stationField) == .orderedSame
            if artistField.isEmpty || artistMatchesStation {
                artistInfo = nil
                albumInfo = nil
                aboutState = .loaded
                return
            }
        }
        aboutState = .loading
        async let artistTask = metadataService.artistInfo(name: metadata.artist)
        async let albumTask: AlbumInfo? = metadata.album.isEmpty
            ? nil
            : metadataService.albumInfo(artist: metadata.artist, album: metadata.album)
        let fetchedArtist = await artistTask
        let fetchedAlbum = await albumTask
        // Apply only if this fetch is still for the current track.
        guard aboutGuard.finishFetch(identity) else { return }
        artistInfo = fetchedArtist
        albumInfo = fetchedAlbum
        aboutState = .loaded
    }

    /// Fire-and-forget background fetches for the inactive tab(s) so
    /// the cache is hot when the user switches tabs.
    private func warmInactiveTabCaches(
        active: NowPlayingContextPanelTab,
        metadata: TrackMetadata
    ) {
        guard !metadata.title.isEmpty else { return }
        let metadataRef = metadataService
        let coordinator = lyricsCoordinator
        let artist = metadata.artist
        let album = metadata.album

        if active != .lyrics {
            // Coordinator's loadIfNeeded is idempotent and cheap on hit.
            coordinator.loadIfNeeded(for: metadata)
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
