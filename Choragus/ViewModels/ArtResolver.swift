/// ArtResolver.swift — Art display state for the now-playing view.
///
/// Single responsibility: decides which art URL to display based on current
/// state (radio track art, station art, metadata art, web search art).
/// Does NOT do: ad break detection (TrackMetadata.isAdBreak), DIDL parsing
/// (TrackMetadata.enrichFromDIDL), or search orchestration (NowPlayingViewModel).
///
/// `@Observable` so SwiftUI re-renders when async art-search results
/// land in `radioTrackArtURL`/`webArtURL`/`displayedArtURL`; a view bound
/// only to `NowPlayingViewModel` would show stale art across track changes.
import Foundation
import Observation
import AppKit
import SonosKit

@MainActor
@Observable
final class ArtResolver {
    // MARK: - Display State

    var displayedArtURL: URL?
    var radioTrackArtURL: URL?
    /// `title|artist` key the current `radioTrackArtURL` was resolved
    /// for. Compared against the *current* track's key in
    /// `artURLForDisplay` so a stale URL from the previous song doesn't
    /// keep displaying after the track has changed but before the next
    /// iTunes lookup completes (or fails). nil means the URL hasn't
    /// been associated with a specific track key yet.
    var radioTrackArtKey: String?
    var radioStationArtURL: URL?
    var webArtURL: URL?
    var forceWebArt = false
    /// Caches whether a `/getaa?` URL returned a real image, keyed by URL, so a
    /// local-no-art track isn't re-probed on every metadata poll.
    ///
    /// A hit is permanent. A miss expires after `getaaMissTTL`: "no image"
    /// is permanent for a local file with no embedded art, but a service
    /// track's proxy URL can start serving the cover once the speaker has it.
    @ObservationIgnored private var getaaProbeCache: [String: (hasImage: Bool, at: Date)] = [:]

    /// Miss TTL — long enough to avoid re-probing an artless local file on
    /// every metadata poll, short enough to pick up service art in-play.
    private static let getaaMissTTL: TimeInterval = 20

    /// Track keys whose pinned art came from a web (iTunes) search.
    ///
    /// Every other pin records something the track carries (speaker art,
    /// cached service cover, user choice). A web pin is a guess from
    /// `artist + album` and can be wrong, so `searchWebArtIfNeeded` keeps
    /// evaluating these tracks and hands the display back to the speaker
    /// as soon as it publishes real art.
    @ObservationIgnored private var webGuessArtKeys: Set<String> = []

    /// Radio track-art held over from the previous song so the display
    /// doesn't snap to the station logo during the brief window between
    /// "new song started" and "iTunes search returned art for it".
    /// Set when a real track changeover is detected on radio (see
    /// `handleTrackURIChanged`); cleared when the next track's art
    /// resolves or when `radioGraceDeadline` passes.
    var previousRadioTrackArtURL: URL?

    /// Wall-clock cutoff for honouring `previousRadioTrackArtURL`. Past
    /// this point the held art releases and the display falls back to
    /// the station logo. Sized so legitimate iTunes searches finish
    /// inside the window but a real station ID lands on the station
    /// logo within seconds rather than holding stale song art.
    var radioGraceDeadline: Date?

    /// Sleep task that nils `previousRadioTrackArtURL` and
    /// `radioGraceDeadline` once the deadline passes. Cancelled on
    /// every re-arm and on every `setRadioTrackArt` call so concurrent
    /// track flips don't compound.
    @ObservationIgnored
    private var radioGraceCleanupTask: Task<Void, Never>?

    /// Grace-window length, in seconds. Tuned so most iTunes radio-
    /// track searches finish inside it but a station-ID gap doesn't
    /// hold the prior song's art for an obviously-wrong duration.
    private static let radioGraceWindow: TimeInterval = 8.0

    // MARK: - Dedup Keys

    var lastArtSearchKey = ""

    /// Per-track-URI canonical art decisions. Once a URL is resolved for a
    /// track it is pinned here and returned for every `artURLForDisplay`
    /// call until the track URI changes or the user acts (Search Artwork /
    /// Refresh / Ignore / Clear). Several art sources race across polls;
    /// the pin stops the cover flickering between them.
    ///
    /// Keyed by `trackMetadata.trackURI` (or title|artist if URI is
    /// missing). A nil value means "resolved to no art".
    private var pinnedArtByTrackURI: [String: URL?] = [:]

    /// Keys of `pinnedArtByTrackURI`.
    private var artResolvedTrackURIs: Set<String> {
        Set(pinnedArtByTrackURI.keys)
    }
    var lastTrackURI = ""
    var lastTrackTitle = ""
    var lastTrackArtist = ""
    var lastRadioTrackKey = ""
    var lastStationName = ""

    // MARK: - Dependencies

    private(set) weak var playHistoryManager: PlayHistoryManager?
    private let albumArtSearch: AlbumArtSearchProtocol

    init(playHistoryManager: PlayHistoryManager? = nil,
         albumArtSearch: AlbumArtSearchProtocol = AlbumArtSearchService.shared) {
        self.playHistoryManager = playHistoryManager
        self.albumArtSearch = albumArtSearch
    }

    // MARK: - Orchestration

    @MainActor
    protocol Dependencies: AnyObject {
        var groupTransportStates: [String: TransportState] { get }
        func cacheArtURL(_ url: String, forURI uri: String, title: String, itemID: String)
        /// Art already discovered for this track — most usefully the
        /// service's own cover URL, written when the track was browsed.
        /// The resolver consults it before falling back to a web guess.
        func lookupCachedArt(uri: String?, title: String) -> String?
    }

    func handleMetadataChanged(_ metadata: TrackMetadata,
                                group: SonosGroup,
                                dependencies: Dependencies) {
        let priorTrackURI = lastTrackURI
        handleTrackURIChanged(trackMetadata: metadata, group: group)
        updateDisplayedArt(trackMetadata: metadata, group: group)

        guard !metadata.isAdBreak else { return }

        if let artStr = metadata.albumArtURI, !artStr.isEmpty, let url = URL(string: artStr) {
            if displayedArtURL != url && !forceWebArt {
                displayedArtURL = url
            }
            if let pinned = pinnedURL(for: metadata), pinned != url, !forceWebArt,
               !artStr.contains("/getaa?") {
                invalidateArtResolution(for: metadata)
            }
        } else if !forceWebArt {
            // Transient empty-art on same URI — hold last-good; speaker
            // re-publishes can arrive empty briefly during `/getaa?`
            // proxy refreshes or topology rebuilds.
            let currentURI = metadata.trackURI ?? metadata.title
            guard currentURI != priorTrackURI else { return }
            if pinnedURL(for: metadata) != nil {
                invalidateArtResolution(for: metadata)
            }
            if displayedArtURL != nil {
                displayedArtURL = nil
            }
        }

        searchWebArtIfNeeded(metadata, group: group, dependencies: dependencies)
        updateDisplayedArt(trackMetadata: metadata, group: group)
        searchRadioTrackArt(metadata, group: group, dependencies: dependencies)
    }

    func searchWebArtIfNeeded(_ metadata: TrackMetadata,
                               group: SonosGroup,
                               dependencies: Dependencies) {
        if forceWebArt { return }
        // Repeated iTunes searches return different top hits and visibly
        // flip the cover. A web-guess pin is the exception: it must give
        // way once the track publishes real art (see `webGuessArtKeys`).
        // `shouldSearch` still dedups the lookup itself.
        if isArtResolved(for: metadata),
           !webGuessArtKeys.contains(artResolutionKey(trackMetadata: metadata)) { return }

        // Apple Music URIs need no fast path here: `SonosManager.
        // enrichAppleMusicArtistIfNeeded` writes the authoritative art URL
        // into `groupTrackMetadata`, picked up via `albumArtURI`.

        let hasArt = metadata.albumArtURI != nil && !(metadata.albumArtURI?.isEmpty ?? true)
        let isLocalFile = metadata.trackURI.map(URIPrefix.isLocal) ?? false
        let hasLocalOnlyArt = hasArt && (metadata.albumArtURI?.contains("/getaa?") ?? false)
        // Radio's `albumArtURI` is the station logo, not track-specific
        // art — leave it unpinned so `searchRadioTrackArt` can resolve
        // the song cover async.
        let onRadio = !metadata.stationName.isEmpty || metadata.isRadioStream
        if hasArt && !hasLocalOnlyArt {
            clearWebArt()
            if !onRadio,
               let artStr = metadata.albumArtURI, let url = URL(string: artStr) {
                markArtResolved(for: metadata, url: url)
            }
            return
        }
        // Local-file /getaa? proxy: keep it only if it returns an image.
        // Sonos serves an empty (0-byte) body when the file has no embedded
        // art — fall through to a web lookup in that case.
        if hasLocalOnlyArt {
            guard let artStr = metadata.albumArtURI, let url = URL(string: artStr) else { return }
            let applyProbe: (Bool) -> Void = { [weak self] hasImage in
                guard let self else { return }
                if hasImage {
                    // Invalidate the search key so a web search still in
                    // flight for this track is dropped by its completion
                    // guard and can't overwrite the speaker's own cover.
                    self.clearWebArt()
                    self.lastArtSearchKey = ""
                    if !onRadio { self.markArtResolved(for: metadata, url: url) }
                } else {
                    self.performWebArtSearch(metadata, group: group, dependencies: dependencies,
                                             isLocalFile: isLocalFile, hasGetaaFallback: true)
                }
            }
            if let cached = getaaProbeCache[artStr],
               cached.hasImage || Date().timeIntervalSince(cached.at) < Self.getaaMissTTL {
                applyProbe(cached.hasImage)
                return
            }
            Task { [weak self] in
                let hasImage = await Self.getaaReturnsImage(url)
                guard let self else { return }
                // Bound the probe cache — it keys on art URL and would otherwise
                // grow for the whole session. A flush only re-probes a few URLs.
                if self.getaaProbeCache.count >= 1000 {
                    self.getaaProbeCache.removeAll(keepingCapacity: true)
                }
                self.getaaProbeCache[artStr] = (hasImage, Date())
                if !hasImage { sonosDebugLog("[ART] getaa empty for \(metadata.title) — web lookup") }
                applyProbe(hasImage)
            }
            return
        }
        performWebArtSearch(metadata, group: group, dependencies: dependencies,
                            isLocalFile: isLocalFile, hasGetaaFallback: false)
    }

    /// Runs the web (iTunes) art lookup for a track with no usable supplied art,
    /// writing the result through every surface so they stay consistent:
    /// `webArtURL` (Now Playing + Club Vis hero via `artURLForDisplay`), the
    /// play-history entry (`updateArtwork`), and the URI art cache
    /// (`cacheArtURL` — Karaoke and the Club Vis wall both read it).
    /// `hasGetaaFallback` true means an empty getaa is still displayed, so a
    /// no-result search shouldn't clear it.
    private func performWebArtSearch(_ metadata: TrackMetadata, group: SonosGroup,
                                     dependencies: Dependencies,
                                     isLocalFile: Bool, hasGetaaFallback: Bool) {
        clearWebArt()
        // A cover URL cached from browsing the service is authoritative in
        // a way an iTunes title match is not. Matters most for services
        // whose speaker-side art is a `/getaa?` proxy (Amazon Music).
        if let cached = dependencies.lookupCachedArt(uri: metadata.trackURI, title: metadata.title),
           !cached.isEmpty, !cached.contains("/getaa?"), let url = URL(string: cached) {
            setWebArtResult(url)
            markArtResolved(for: metadata, url: url)
            updateDisplayedArt(trackMetadata: metadata, group: group)
            return
        }
        let searchTerm: String
        if isLocalFile && !metadata.album.isEmpty {
            searchTerm = metadata.album
        } else if !metadata.stationName.isEmpty {
            searchTerm = metadata.stationName
        } else if !metadata.album.isEmpty {
            searchTerm = metadata.album
        } else if !metadata.title.isEmpty {
            searchTerm = metadata.title
        } else {
            return
        }
        let artist = TrackMetadata.filterDeviceID(metadata.artist)
        let key = "\(searchTerm)|\(artist)"
        guard shouldSearch(key: key) else { return }
        setSearchKey(key)
        setWebArtResult(nil)
        var cleanedSearchTerm = searchTerm
            .replacingOccurrences(of: "\\s*\\([^)]*\\)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s*\\[[^\\]]*\\]", with: "", options: .regularExpression)
        if let p = cleanedSearchTerm.firstIndex(of: "(") { cleanedSearchTerm = String(cleanedSearchTerm[..<p]) }
        if let b = cleanedSearchTerm.firstIndex(of: "[") { cleanedSearchTerm = String(cleanedSearchTerm[..<b]) }
        cleanedSearchTerm = cleanedSearchTerm.trimmingCharacters(in: .whitespaces)
        let effectiveSearch = cleanedSearchTerm.isEmpty ? searchTerm : cleanedSearchTerm

        Task { [weak self, weak dependencies] in
            guard let self else { return }
            var foundArt = await self.albumArtSearch.searchArtwork(
                artist: artist, album: effectiveSearch
            )
            if foundArt == nil, !artist.isEmpty {
                foundArt = await self.albumArtSearch.searchArtwork(
                    artist: artist, album: ""
                )
            }
            // Apply only when this search is still for the current track —
            // mirrors the radio path's staleness key. A slow lookup for a
            // previous track must not overwrite (or clear) the art the
            // current track's search resolved.
            guard self.lastArtSearchKey == key else { return }
            if let artURL = foundArt, let url = URL(string: artURL) {
                self.playHistoryManager?.updateArtwork(
                    forTitle: metadata.title, artist: metadata.artist, artURL: artURL
                )
                dependencies?.cacheArtURL(artURL, forURI: metadata.trackURI ?? "", title: metadata.title, itemID: "")
                self.setWebArtResult(url)
                self.markArtResolved(for: metadata, url: url)
                // A search result is a guess, whether it filled in for a
                // track with no art at all or for one whose `/getaa?`
                // proxy came up empty — see `webGuessArtKeys`.
                self.webGuessArtKeys.insert(self.artResolutionKey(trackMetadata: metadata))
                self.updateDisplayedArt(trackMetadata: metadata, group: group)
            } else if !hasGetaaFallback {
                self.setWebArtResult(nil)
            }
        }
    }

    /// Tight-timeout session for probing whether a `/getaa?` art URL returns a
    /// real image (vs Sonos's empty body for a local file with no embedded art).
    private static let artProbeSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 4
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    /// True only when the URL returns a decodable image. Sonos serves an empty
    /// body for a local file with no embedded art (decodes to nil) — the signal
    /// to fall back to a web lookup. `nonisolated` so it runs off the main actor.
    nonisolated static func getaaReturnsImage(_ url: URL) async -> Bool {
        guard let (data, resp) = try? await artProbeSession.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              !data.isEmpty else { return false }
        return NSImage(data: data) != nil
    }

    /// Resolves the song cover for radio (where `albumArtURI` is the
    /// station logo, not the track), into `radioTrackArtURL`.
    func searchRadioTrackArt(_ metadata: TrackMetadata,
                              group: SonosGroup,
                              dependencies: Dependencies) {
        let transportState = dependencies.groupTransportStates[group.coordinatorID] ?? .stopped
        guard transportState.isActive else { return }

        if metadata.stationName.isEmpty || metadata.isAdBreak {
            clearRadioTrackArt()
            return
        }
        // Holds last-good across transient title blips on the same
        // station instead of flicking back to the logo.
        if metadata.title.isEmpty || metadata.title == metadata.stationName {
            return
        }
        // Amazon Music stations play real catalogue tracks
        // (`x-sonosapi-hls-static:catalog:track:asin:…`) whose DIDL
        // already carries the song's own cover. An iTunes guess would
        // only compete with (and sometimes mismatch) the real art, so
        // let the metadata art through untouched.
        if URIPrefix.isHLSStaticTrack(metadata.trackURI ?? ""),
           let art = metadata.albumArtURI, !art.isEmpty,
           !art.contains("/getaa?") {
            clearRadioTrackArt()
            return
        }
        let key = "\(metadata.title)|\(metadata.artist)"
        guard shouldSearchRadioTrack(key: key) else { return }
        setRadioTrackKey(key)
        if radioStationArtURL == nil, let stationArt = displayedArtURL ?? metadata.albumArtURI.flatMap({ URL(string: $0) }) {
            radioStationArtURL = stationArt
        }
        var artist = TrackMetadata.filterDeviceID(metadata.artist)
        // Stations sometimes use the station/soundtrack name as the
        // artist field (e.g. "Movie Ticket Radio" → "Animal House");
        // dropping that on match yields better iTunes results.
        if !metadata.stationName.isEmpty,
           artist.caseInsensitiveCompare(metadata.stationName) == .orderedSame {
            artist = ""
        }
        let searchTitle = metadata.title
        Task { [weak self, weak dependencies] in
            guard let self else { return }
            if let artURL = await self.albumArtSearch.searchRadioTrackArt(
                artist: artist, title: searchTitle
            ) {
                sonosDebugLog("[ART/RADIO] resolved \(searchTitle) – \(artist) → \(artURL.prefix(80))")
                self.setRadioTrackArt(URL(string: artURL), forKey: key)
                self.playHistoryManager?.updateArtwork(
                    forTitle: metadata.title, artist: metadata.artist, artURL: artURL
                )
                dependencies?.cacheArtURL(artURL, forURI: metadata.trackURI ?? "", title: metadata.title, itemID: "")
            } else {
                sonosDebugLog("[ART/RADIO] no result for \(searchTitle) – \(artist)")
                self.setRadioTrackArt(nil, forKey: key)
            }
        }
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

        // Station change = non-empty `currentStation` that differs from
        // `lastStationName`, or radio left entirely (`onRadio` false).
        // Sonos metadata polls occasionally drop `stationName` for a
        // frame; a transient empty value must not clear `radioTrackArtURL`
        // or the track art flicks back to the station logo.
        let realStationChange: Bool
        if !currentStation.isEmpty {
            realStationChange = currentStation != lastStationName
        } else {
            realStationChange = !lastStationName.isEmpty && !onRadio
        }
        if realStationChange {
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
        // Auto-pin the first non-`/getaa?` art for this track. For
        // direct-stream playback (Plex direct, custom HTTP) the first frame
        // carries the upstream URL from the DIDL; later speaker polls
        // rewrite it to a `/getaa?` proxy that returns placeholder art when
        // the upstream isn't fetchable speaker-side.
        if !isArtResolved(for: trackMetadata),
           !onRadio,
           let url = resolved,
           !url.absoluteString.contains("/getaa?") {
            markArtResolved(for: trackMetadata, url: url)
        }
    }

    /// The art URL the view should show — accounts for ad breaks and ignore state.
    ///
    /// Canonical return value: once a track URI is pinned in
    /// `pinnedArtByTrackURI`, this always returns that URL for that
    /// track regardless of other state changes. User actions
    /// (invalidateArtResolution) are the only way the answer changes.
    func artURLForDisplay(trackMetadata: TrackMetadata) -> URL? {
        // Precedence lives in ArtDisplayDecision, testable without a speaker
        // or a clock; this method only gathers the candidates.
        ArtDisplayDecision.artURL(.init(
            isIgnored: isArtIgnored,
            isAdBreak: trackMetadata.isAdBreak,
            isResolved: isArtResolved(for: trackMetadata),
            stationName: trackMetadata.stationName,
            speakerArtURI: trackMetadata.albumArtURI,
            pinnedURL: pinnedURL(for: trackMetadata),
            serverPublishedArtURL: serverPublishedArtURL(for: trackMetadata),
            radioTrackArtURL: radioTrackArtURL,
            radioTrackArtTitle: radioTrackArtKey,
            stationArtURL: radioStationArtURL,
            heldPreviousRadioArtURL: previousRadioTrackArtURL,
            radioGraceActive: radioGraceDeadline.map { Date() < $0 } ?? false,
            displayedArtURL: displayedArtURL,
            title: trackMetadata.title))
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
        // Radio HLS streams keep the same trackURI across songs, so a
        // title change on a stable radio URI also counts as a track change
        // (otherwise the grace window below never arms).
        let onRadio = !trackMetadata.stationName.isEmpty || trackMetadata.isRadioStream
        let titleChangedOnSameRadioURI =
            onRadio &&
            currentURI == lastTrackURI &&
            !trackMetadata.title.isEmpty &&
            trackMetadata.title != lastTrackTitle
        guard (currentURI != lastTrackURI || titleChangedOnSameRadioURI),
              !currentURI.isEmpty
        else { return }
        let previousTitle = lastTrackTitle
        let previousArtist = lastTrackArtist
        let previouslyResolvedRadioArt = radioTrackArtURL
        lastTrackURI = currentURI
        lastTrackTitle = trackMetadata.title
        lastTrackArtist = trackMetadata.artist
        // Same song but URI rotated (common with radio HLS streams) — keep radio art
        let sameSong = !trackMetadata.title.isEmpty &&
                       trackMetadata.title == previousTitle &&
                       trackMetadata.artist == previousArtist
        if sameSong { return }
        // New track — reset all overrides
        isArtIgnored = false
        forceWebArt = false
        webArtURL = nil
        // radioTrackArtURL is not cleared here: on radio that reverts to
        // station art until searchRadioTrackArt returns (visible flicker).
        // searchRadioTrackArt replaces or clears it when the result lands.
        lastArtSearchKey = ""
        displayedArtURL = trackMetadata.albumArtURI.flatMap { URL(string: $0) }
        // Restore any persisted override for this specific track
        loadPersistedArtOverride(trackMetadata: trackMetadata, group: group)

        // Radio grace window: hold the previous song's art until the
        // iTunes search returns. Skipped when the new "track" is a station
        // ID (empty title, or title equals station name) — the station
        // logo is the right answer immediately.
        let isStationID = trackMetadata.title.isEmpty ||
            (!trackMetadata.stationName.isEmpty &&
             trackMetadata.title.caseInsensitiveCompare(trackMetadata.stationName) == .orderedSame)
        if onRadio, !isStationID, let prior = previouslyResolvedRadioArt {
            armRadioGraceWindow(holding: prior)
        } else {
            cancelRadioGraceWindow()
        }
    }

    /// Captures `prior` as the held-over art and arms the deadline. A
    /// background task fires after `radioGraceWindow` seconds to release
    /// the hold, so views observing `previousRadioTrackArtURL` /
    /// `radioGraceDeadline` get an automatic re-render and fall back to
    /// the station logo when the search fails to land in time.
    private func armRadioGraceWindow(holding prior: URL) {
        previousRadioTrackArtURL = prior
        let deadline = Date().addingTimeInterval(Self.radioGraceWindow)
        radioGraceDeadline = deadline
        radioGraceCleanupTask?.cancel()
        radioGraceCleanupTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.radioGraceWindow * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            // If a newer arm has bumped the deadline forward, defer to it.
            if let current = self.radioGraceDeadline, current > Date() { return }
            self.previousRadioTrackArtURL = nil
            self.radioGraceDeadline = nil
        }
    }

    /// Releases any held-over radio art immediately. Called when fresh
    /// track art lands (`setRadioTrackArt`) or a definitive non-result
    /// returns from the search.
    private func cancelRadioGraceWindow() {
        radioGraceCleanupTask?.cancel()
        radioGraceCleanupTask = nil
        previousRadioTrackArtURL = nil
        radioGraceDeadline = nil
    }

    // MARK: - Persistence

    /// Sentinel value stored to indicate artwork should be ignored (show generic icon)
    static let ignoreArtMarker = "IGNORE"

    /// Whether artwork is currently being ignored for this track
    var isArtIgnored = false

    func loadPersistedArtOverride(trackMetadata: TrackMetadata, group: SonosGroup) {
        let searchTerm = artOverrideKey(trackMetadata: trackMetadata)
        guard !searchTerm.isEmpty else { return }
        let key = "\(UDKey.artOverridePrefix)\(searchTerm.lowercased())"
        if let saved = UserDefaults.standard.string(forKey: key) {
            if saved == Self.ignoreArtMarker {
                isArtIgnored = true
                webArtURL = nil
                forceWebArt = false
                displayedArtURL = nil
            } else {
                isArtIgnored = false
                webArtURL = URL(string: saved)
                forceWebArt = true
                updateDisplayedArt(trackMetadata: trackMetadata, group: group)
            }
        }
    }

    /// Persists an ignore marker so this track always shows the generic icon
    func ignoreArtwork(trackMetadata: TrackMetadata) {
        let searchTerm = artOverrideKey(trackMetadata: trackMetadata)
        guard !searchTerm.isEmpty else { return }
        let key = "\(UDKey.artOverridePrefix)\(searchTerm.lowercased())"
        UserDefaults.standard.set(Self.ignoreArtMarker, forKey: key)
        isArtIgnored = true
        webArtURL = nil
        forceWebArt = false
        displayedArtURL = nil
        // Explicit user decision — the resolution is fixed now.
        markArtResolved(for: trackMetadata)
    }

    /// Persists a manually chosen art URL and pre-caches the image
    func setManualArtwork(_ artURL: String, trackMetadata: TrackMetadata, group: SonosGroup) {
        let searchTerm = artOverrideKey(trackMetadata: trackMetadata)
        guard !searchTerm.isEmpty else { return }
        let key = "\(UDKey.artOverridePrefix)\(searchTerm.lowercased())"
        UserDefaults.standard.set(artURL, forKey: key)
        isArtIgnored = false
        let chosenURL = URL(string: artURL)
        webArtURL = chosenURL
        forceWebArt = true
        // Clear stale state before pinning, and pass the chosen URL
        // explicitly so the pin matches the user's choice regardless of
        // transient state.
        radioTrackArtURL = nil
        displayedArtURL = chosenURL
        markArtResolved(for: trackMetadata, url: chosenURL)
        updateDisplayedArt(trackMetadata: trackMetadata, group: group)

        // Pre-cache the image so it's available immediately on future plays
        if let url = URL(string: artURL) {
            Task {
                if ImageCache.shared.image(for: url) == nil {
                    if let (data, _) = try? await URLSession.shared.data(from: url),
                       let image = NSImage(data: data) {
                        ImageCache.shared.store(image, for: url)
                    }
                }
            }
        }

        // Update play history artwork for this track
        playHistoryManager?.updateArtwork(
            forTitle: trackMetadata.title, artist: trackMetadata.artist, artURL: artURL)
    }

    /// Consistent key for art override persistence
    func artOverrideKey(trackMetadata: TrackMetadata) -> String {
        !trackMetadata.title.isEmpty ? trackMetadata.title :
        !trackMetadata.stationName.isEmpty ? trackMetadata.stationName : ""
    }

    /// Key used to track a single "resolved" art decision per track.
    /// Falls back to title|artist when trackURI isn't populated (e.g.,
    /// very-early metadata with only DIDL-parsed title/artist).
    func artResolutionKey(trackMetadata: TrackMetadata) -> String {
        if let uri = trackMetadata.trackURI, !uri.isEmpty { return uri }
        return "\(trackMetadata.title)|\(trackMetadata.artist)"
    }

    /// True if the track's art has already been resolved this session and
    /// automatic searches should be skipped.
    func isArtResolved(for trackMetadata: TrackMetadata) -> Bool {
        resolutionKeys(for: trackMetadata).contains { pinnedArtByTrackURI[$0] != nil }
    }

    /// Both keys a pin for this track may live under. A web search launched
    /// from early metadata (no trackURI yet) pins under `title|artist`; the
    /// display lookup arrives later with the URI populated and must still
    /// find that pin.
    private func resolutionKeys(for trackMetadata: TrackMetadata) -> [String] {
        let primary = artResolutionKey(trackMetadata: trackMetadata)
        let titleKey = "\(trackMetadata.title)|\(trackMetadata.artist)"
        return primary == titleKey ? [primary] : [primary, titleKey]
    }

    /// Pin the current art decision for this track. Called after any
    /// art-source hop lands a real URL (iTunes search, manual override,
    /// metadata URL, persistent cache hit).
    func markArtResolved(for trackMetadata: TrackMetadata, url: URL? = nil) {
        let key = artResolutionKey(trackMetadata: trackMetadata)
        guard !key.isEmpty else { return }
        sonosDebugLog("[ART/PIN] mark key=\(key.prefix(60)) url=\(url?.absoluteString.prefix(80) ?? "<derive>")")
        // Storing the URL (not just the fact of resolution) keeps
        // `artURLForDisplay` stable across transient state changes.
        let resolved = url ?? displayedArtURL ?? webArtURL
        pinnedArtByTrackURI[key] = resolved
        // Any fresh decision supersedes a provisional one. The web-art
        // fallback re-marks the key right after this call; every other
        // caller (manual override, metadata art, cache hit) is final.
        webGuessArtKeys.remove(key)
    }

    /// Clear the "already resolved" flag for this track so the next
    /// metadata change will re-run the search. Only called from explicit
    /// user actions (Search Artwork, Refresh, Ignore, Clear).
    func invalidateArtResolution(for trackMetadata: TrackMetadata) {
        for key in resolutionKeys(for: trackMetadata) {
            sonosDebugLog("[ART/PIN] invalidate key=\(key.prefix(60))")
            pinnedArtByTrackURI.removeValue(forKey: key)
            webGuessArtKeys.remove(key)
        }
    }

    /// Pinned URL for this track if one was resolved, else nil. Used by
    /// `artURLForDisplay` to short-circuit the resolver chain once the
    /// canonical answer is known.
    func pinnedURL(for trackMetadata: TrackMetadata) -> URL? {
        for key in resolutionKeys(for: trackMetadata) {
            if let pinned = pinnedArtByTrackURI[key] ?? nil { return pinned }
        }
        return nil
    }

    /// Art the originating media server published for this track, if it came
    /// from one. Kept separate from `pinnedURL`: a pin is a per-session
    /// resolver decision, this is source data. Conflating them makes
    /// `isArtResolved` disagree with `pinnedURL` on every metadata poll.
    func serverPublishedArtURL(for trackMetadata: TrackMetadata) -> URL? {
        guard let uri = trackMetadata.trackURI, !uri.isEmpty else { return nil }
        return MediaServerService.PublishedArt.art(forPlayURL: uri)
    }

    func forceITunesArtSearch(trackMetadata: TrackMetadata, displayArtist: String, group: SonosGroup) {
        let artist = displayArtist
        let searchTerm = artOverrideKey(trackMetadata: trackMetadata)
        guard !searchTerm.isEmpty else { return }
        lastArtSearchKey = ""
        invalidateArtResolution(for: trackMetadata)
        forceWebArt = false
        isArtIgnored = false
        Task {
            if let artURL = await albumArtSearch.searchArtwork(
                artist: artist, album: searchTerm
            ) {
                setManualArtwork(artURL, trackMetadata: trackMetadata, group: group)
            } else {
                // No iTunes match: show the placeholder rather than the
                // previous track's URL.
                displayedArtURL = nil
                webArtURL = nil
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
        // Keyless setter clears the gating key so display doesn't reject
        // the URL. Prefer `setRadioTrackArt(_:forKey:)`.
        radioTrackArtKey = nil
        cancelRadioGraceWindow()
    }

    /// Records the URL together with the `title|artist` key it was
    /// resolved for. The display layer compares this against the current
    /// track's key and refuses to surface a stale URL from a previous
    /// song while the new search is still in flight.
    func setRadioTrackArt(_ url: URL?, forKey key: String) {
        radioTrackArtURL = url
        radioTrackArtKey = url == nil ? nil : key
        // Search resolved (success or definitive nil) — release held art.
        cancelRadioGraceWindow()
    }

    func clearRadioTrackArt() {
        radioTrackArtURL = nil
        radioTrackArtKey = nil
        lastRadioTrackKey = ""
        cancelRadioGraceWindow()
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
        radioTrackArtKey = nil
        radioStationArtURL = nil
        webArtURL = nil
        forceWebArt = false
        isArtIgnored = false
        lastArtSearchKey = ""
        lastTrackURI = ""
        lastTrackTitle = ""
        lastTrackArtist = ""
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
