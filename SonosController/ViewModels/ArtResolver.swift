/// ArtResolver.swift — Album art resolution for the now-playing view.
///
/// Handles art from multiple sources: metadata, /getaa, iTunes search,
/// radio track art, and user overrides. Extracted from NowPlayingViewModel
/// to keep that class focused on transport/volume/position.
import Foundation
import SonosKit

@MainActor
final class ArtResolver {
    // MARK: - State

    var displayedArtURL: URL?
    var radioTrackArtURL: URL?
    var radioStationArtURL: URL?
    var webArtURL: URL?
    var forceWebArt = false
    var lastArtSearchKey = ""
    var lastTrackURI = ""
    var lastRadioTrackKey = ""
    /// True when we're in an ad break — view reads this to decide what to show
    var inAdBreak = false

    // MARK: - Dependencies

    private weak var playHistoryManager: PlayHistoryManager?

    init(playHistoryManager: PlayHistoryManager? = nil) {
        self.playHistoryManager = playHistoryManager
    }

    // MARK: - Ad Break Detection

    /// True when a radio station is playing but track details are absent (ad break, buffer, etc.)
    func isRadioAdBreak(_ metadata: TrackMetadata) -> Bool {
        let hasStation = !metadata.stationName.isEmpty || isRadioStream(metadata)
        guard hasStation else { return false }
        // No title, or title matches station name with no artist/album = ad break
        if metadata.title.isEmpty { return true }
        if metadata.title == metadata.stationName && metadata.artist.isEmpty { return true }
        if metadata.artist.isEmpty && metadata.album.isEmpty && metadata.title == metadata.stationName { return true }
        return false
    }

    private func isRadioStream(_ metadata: TrackMetadata) -> Bool {
        metadata.trackURI.map(URIPrefix.isRadio) ?? false
    }

    // MARK: - Resolution

    func localFileArtURL(trackMetadata: TrackMetadata, group: SonosGroup) -> String? {
        guard let uri = trackMetadata.trackURI,
              URIPrefix.isLocal(uri),
              let coordinator = group.coordinator else { return nil }
        return AlbumArtSearchService.getaaURL(speakerIP: coordinator.ip, port: coordinator.port, trackURI: uri)
    }

    func resolveArtURL(trackMetadata: TrackMetadata, group: SonosGroup) -> URL? {
        let isLocalFile = trackMetadata.trackURI.map(URIPrefix.isLocal) ?? false
        let artURI = trackMetadata.albumArtURI ?? localFileArtURL(trackMetadata: trackMetadata, group: group)
        if forceWebArt {
            return webArtURL ?? artURI.flatMap { URL(string: $0) }
        } else if isLocalFile && webArtURL != nil {
            return webArtURL
        } else {
            return artURI.flatMap { URL(string: $0) } ?? webArtURL
        }
    }

    func updateDisplayedArt(trackMetadata: TrackMetadata, group: SonosGroup) {
        let onRadio = !trackMetadata.stationName.isEmpty || isRadioStream(trackMetadata)

        // Capture station art: use the first art we see when entering a radio stream,
        // but only if we don't already have one saved
        if onRadio && radioStationArtURL == nil {
            // Try the metadata art first (from DIDL), then any currently displayed art
            if let metaArt = trackMetadata.albumArtURI, !metaArt.isEmpty, let url = URL(string: metaArt) {
                radioStationArtURL = url
            } else if let art = displayedArtURL {
                radioStationArtURL = art
            }
        }

        // Ad break: set flag and don't update displayedArtURL
        if isRadioAdBreak(trackMetadata) {
            inAdBreak = true
            radioTrackArtURL = nil
            lastRadioTrackKey = ""
            return
        }

        // Not an ad break
        inAdBreak = false

        let resolved = resolveArtURL(trackMetadata: trackMetadata, group: group)
        if resolved != displayedArtURL {
            if resolved == nil && displayedArtURL != nil {
                if onRadio { return }
                let currentURI = trackMetadata.trackURI ?? ""
                if currentURI == lastTrackURI { return }
            }
            displayedArtURL = resolved
        }
    }

    // MARK: - Radio Track Art

    func searchRadioTrackArt(trackMetadata: TrackMetadata) {
        if isRadioAdBreak(trackMetadata) {
            radioTrackArtURL = nil
            lastRadioTrackKey = ""
            return
        }

        guard !trackMetadata.stationName.isEmpty,
              !trackMetadata.title.isEmpty,
              trackMetadata.title != trackMetadata.stationName else {
            if radioTrackArtURL != nil { radioTrackArtURL = nil }
            return
        }
        let key = "\(trackMetadata.title)|\(trackMetadata.artist)"
        guard key != lastRadioTrackKey else { return }
        lastRadioTrackKey = key
        if radioStationArtURL == nil, let stationArt = displayedArtURL ?? trackMetadata.albumArtURI.flatMap({ URL(string: $0) }) {
            radioStationArtURL = stationArt
        }
        let artist = TrackMetadata.filterDeviceID(trackMetadata.artist)
        let cleanTitle = AlbumArtSearchService.cleanTrackTitle(trackMetadata.title)
        let searchTitle = cleanTitle.isEmpty ? trackMetadata.title : cleanTitle
        Task {
            if let artURL = await AlbumArtSearchService.shared.searchRadioTrackArt(
                artist: artist, title: searchTitle
            ) {
                radioTrackArtURL = URL(string: artURL)
                playHistoryManager?.updateArtwork(
                    forTitle: trackMetadata.title, artist: trackMetadata.artist, artURL: artURL
                )
            } else {
                radioTrackArtURL = nil
            }
        }
    }

    // MARK: - Web Art Search

    func searchWebArtIfNeeded(trackMetadata: TrackMetadata, displayArtist: String, group: SonosGroup) {
        if isRadioAdBreak(trackMetadata) { return }

        let currentURI = trackMetadata.trackURI ?? trackMetadata.title
        if currentURI != lastTrackURI && !currentURI.isEmpty {
            lastTrackURI = currentURI
            if !forceWebArt {
                webArtURL = nil
                lastArtSearchKey = ""
            }
            displayedArtURL = trackMetadata.albumArtURI.flatMap { URL(string: $0) }
            if trackMetadata.stationName.isEmpty {
                radioTrackArtURL = nil
                radioStationArtURL = nil
                lastRadioTrackKey = ""
            }
            loadPersistedArtOverride(trackMetadata: trackMetadata, group: group)
        }

        let hasArt = trackMetadata.albumArtURI != nil && !(trackMetadata.albumArtURI?.isEmpty ?? true)
        let isLocalFile = trackMetadata.trackURI.map(URIPrefix.isLocal) ?? false
        if hasArt && !isLocalFile {
            if !forceWebArt { if webArtURL != nil { webArtURL = nil } }
            return
        }
        forceWebArt = false

        let searchTerm: String
        if isLocalFile && !trackMetadata.album.isEmpty {
            searchTerm = trackMetadata.album
        } else if !trackMetadata.stationName.isEmpty {
            searchTerm = trackMetadata.stationName
        } else if !trackMetadata.album.isEmpty {
            searchTerm = trackMetadata.album
        } else if !trackMetadata.title.isEmpty {
            searchTerm = trackMetadata.title
        } else {
            searchTerm = ""
        }
        let artist = displayArtist
        let key = "\(searchTerm)|\(artist)"
        guard !searchTerm.isEmpty else { return }
        guard key != lastArtSearchKey else { return }
        lastArtSearchKey = key
        webArtURL = nil
        sonosDebugLog("[ART-SEARCH] Searching iTunes for artist='\(artist)' album='\(searchTerm)'")
        Task {
            if let artURL = await AlbumArtSearchService.shared.searchArtwork(
                artist: artist, album: searchTerm
            ) {
                sonosDebugLog("[ART-SEARCH] Found: \(artURL.prefix(80))")
                webArtURL = URL(string: artURL)
                playHistoryManager?.updateArtwork(
                    forTitle: trackMetadata.title, artist: trackMetadata.artist, artURL: artURL
                )
            } else {
                sonosDebugLog("[ART-SEARCH] No result from iTunes")
                webArtURL = nil
            }
            updateDisplayedArt(trackMetadata: trackMetadata, group: group)
        }
    }

    func forceITunesArtSearch(trackMetadata: TrackMetadata, displayArtist: String, group: SonosGroup) {
        let artist = displayArtist
        let searchTerm = !trackMetadata.title.isEmpty ? trackMetadata.title :
                         !trackMetadata.stationName.isEmpty ? trackMetadata.stationName : ""
        guard !searchTerm.isEmpty else { return }
        lastArtSearchKey = ""
        forceWebArt = false
        Task {
            if let artURL = await AlbumArtSearchService.shared.searchArtwork(
                artist: artist, album: searchTerm
            ) {
                webArtURL = URL(string: artURL)
                forceWebArt = true
                let key = "\(UDKey.artOverridePrefix)\(searchTerm.lowercased())"
                UserDefaults.standard.set(artURL, forKey: key)
                updateDisplayedArt(trackMetadata: trackMetadata, group: group)
            }
        }
    }

    func loadPersistedArtOverride(trackMetadata: TrackMetadata, group: SonosGroup) {
        let searchTerm = !trackMetadata.title.isEmpty ? trackMetadata.title :
                         !trackMetadata.stationName.isEmpty ? trackMetadata.stationName : ""
        guard !searchTerm.isEmpty else { return }
        let key = "\(UDKey.artOverridePrefix)\(searchTerm.lowercased())"
        if let saved = UserDefaults.standard.string(forKey: key) {
            webArtURL = URL(string: saved)
            forceWebArt = true
            updateDisplayedArt(trackMetadata: trackMetadata, group: group)
        }
    }

    /// Resets all art state (e.g., when switching groups)
    func reset() {
        displayedArtURL = nil
        radioTrackArtURL = nil
        radioStationArtURL = nil
        webArtURL = nil
        forceWebArt = false
        lastArtSearchKey = ""
        lastTrackURI = ""
        lastRadioTrackKey = ""
        inAdBreak = false
    }
}
