/// ArtResolver.swift — Art display state for the now-playing view.
///
/// Single responsibility: decides which art URL to display based on current
/// state (radio track art, station art, metadata art, web search art).
/// Does NOT do: ad break detection (TrackMetadata.isAdBreak), DIDL parsing
/// (TrackMetadata.enrichFromDIDL), or search orchestration (NowPlayingViewModel).
import Foundation
import SonosKit

@MainActor
final class ArtResolver {
    // MARK: - Display State

    var displayedArtURL: URL?
    var radioTrackArtURL: URL?
    var radioStationArtURL: URL?
    var webArtURL: URL?
    var forceWebArt = false

    // MARK: - Dedup Keys

    var lastArtSearchKey = ""
    var lastTrackURI = ""
    var lastRadioTrackKey = ""
    var lastStationName = ""

    // MARK: - Dependencies

    private(set) weak var playHistoryManager: PlayHistoryManager?

    init(playHistoryManager: PlayHistoryManager? = nil) {
        self.playHistoryManager = playHistoryManager
    }

    // MARK: - Display Resolution

    /// Returns the URL that should be displayed as album art right now.
    /// Priority: forced web art > radio track art > metadata art > web search art > station art.
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

    /// Updates displayedArtURL from current state. Handles station changes.
    func updateDisplayedArt(trackMetadata: TrackMetadata, group: SonosGroup) {
        let currentStation = trackMetadata.stationName
        let onRadio = !currentStation.isEmpty || trackMetadata.isRadioStream

        // Station changed — clear stale radio art
        if currentStation != lastStationName {
            let wasRadio = !lastStationName.isEmpty
            lastStationName = currentStation
            radioStationArtURL = nil
            radioTrackArtURL = nil
            lastRadioTrackKey = ""
            if wasRadio || onRadio {
                displayedArtURL = nil
                webArtURL = nil
            }
        }

        // Capture station art — try metadata art first, then current displayed art
        if onRadio && radioStationArtURL == nil {
            if let metaArt = trackMetadata.albumArtURI, !metaArt.isEmpty, let url = URL(string: metaArt) {
                radioStationArtURL = url
            } else if let displayed = displayedArtURL {
                radioStationArtURL = displayed
            }
        }

        // During ad breaks, show station art — don't update displayedArtURL
        if trackMetadata.isAdBreak {
            radioTrackArtURL = nil
            lastRadioTrackKey = ""
            return
        }

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

    /// The art URL the view should show — accounts for ad breaks.
    func artURLForDisplay(trackMetadata: TrackMetadata) -> URL? {
        if trackMetadata.isAdBreak {
            return radioStationArtURL
        }
        if let trackArt = radioTrackArtURL, !trackMetadata.stationName.isEmpty {
            return trackArt
        }
        return displayedArtURL ?? radioStationArtURL
    }

    /// Whether to show the station badge overlay.
    func shouldShowStationBadge(trackMetadata: TrackMetadata) -> Bool {
        guard let _ = radioTrackArtURL,
              let stationArt = radioStationArtURL,
              !trackMetadata.isAdBreak else { return false }
        return stationArt != radioTrackArtURL && stationArt != displayedArtURL
    }

    // MARK: - Track Change Handling

    func handleTrackURIChanged(trackMetadata: TrackMetadata, group: SonosGroup) {
        let currentURI = trackMetadata.trackURI ?? trackMetadata.title
        guard currentURI != lastTrackURI, !currentURI.isEmpty else { return }
        lastTrackURI = currentURI
        if !forceWebArt {
            webArtURL = nil
            lastArtSearchKey = ""
        }
        displayedArtURL = trackMetadata.albumArtURI.flatMap { URL(string: $0) }
        loadPersistedArtOverride(trackMetadata: trackMetadata, group: group)
    }

    // MARK: - Persistence

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

    // MARK: - State Mutation (encapsulated — ViewModel calls these, not direct property access)

    func clearWebArt() {
        webArtURL = nil
        forceWebArt = false
    }

    func setWebArtResult(_ url: URL?) {
        webArtURL = url
    }

    func setRadioTrackArt(_ url: URL?) {
        radioTrackArtURL = url
    }

    func clearRadioTrackArt() {
        radioTrackArtURL = nil
        lastRadioTrackKey = ""
    }

    func setSearchKey(_ key: String) {
        lastArtSearchKey = key
    }

    func shouldSearch(key: String) -> Bool {
        key != lastArtSearchKey
    }

    func shouldSearchRadioTrack(key: String) -> Bool {
        key != lastRadioTrackKey
    }

    func setRadioTrackKey(_ key: String) {
        lastRadioTrackKey = key
    }

    func reset() {
        displayedArtURL = nil
        radioTrackArtURL = nil
        radioStationArtURL = nil
        webArtURL = nil
        forceWebArt = false
        lastArtSearchKey = ""
        lastTrackURI = ""
        lastRadioTrackKey = ""
        lastStationName = ""
    }

    // MARK: - Helpers

    private func localFileArtURL(trackMetadata: TrackMetadata, group: SonosGroup) -> String? {
        guard let uri = trackMetadata.trackURI,
              URIPrefix.isLocal(uri),
              let coordinator = group.coordinator else { return nil }
        return AlbumArtSearchService.getaaURL(speakerIP: coordinator.ip, port: coordinator.port, trackURI: uri)
    }
}
