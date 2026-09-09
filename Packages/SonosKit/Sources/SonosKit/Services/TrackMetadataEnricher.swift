/// TrackMetadataEnricher.swift — Owns what the app knows about a track beyond
/// what the speaker reports: the play-time metadata cache, the local-album-art
/// store, and the self-heals that fill either in when a row arrives bare.
///
/// The queue's read path is enrichment and the transport delegate reads the
/// same caches; transport is a *consumer* of this state, not its owner. Every
/// write to `cachedTrackInfo` comes from a browse or enqueue path.
///
/// Dependencies are typed, not erased into closures. The one outward reach —
/// patching a now-playing row once a Suno title resolves — goes through
/// `NowPlayingTitlePatching`, a one-method protocol, rather than a
/// `[weak self]` closure over the façade.
import Foundation

/// Lets the enricher patch a now-playing row when a title resolves late,
/// without knowing what holds that row.
@MainActor
public protocol NowPlayingTitlePatching: AnyObject {
    func patchNowPlayingTitle(_ title: String, forSunoUUID uuid: String)
}

@MainActor
@Observable
public final class TrackMetadataEnricher: LocalAlbumArtResolving {

    // MARK: - Collaborators

    @ObservationIgnored private let albumArtSearch: AlbumArtSearchProtocol
    /// Hosts known to be media servers, used only to decide whether a queue
    /// row's art came from a server rather than the speaker's getaa proxy.
    @ObservationIgnored public weak var mediaServerHosts: MediaServerHostProviding?
    /// Set by the owner after construction; weak so the enricher never keeps
    /// the now-playing holder alive.
    @ObservationIgnored public weak var nowPlayingPatcher: NowPlayingTitlePatching?

    public init(albumArtSearch: AlbumArtSearchProtocol) {
        self.albumArtSearch = albumArtSearch
    }

    /// Drops every per-session cache.
    ///
    /// Unwired: clearing on transport-strategy restart would blank recovered
    /// titles and art for rows the speaker reports bare, which is the failure
    /// mode the caches exist to prevent. Wire only with that consequence in
    /// mind.
    public func reset() {
        cachedTrackInfo.removeAll()
        cachedTrackByPosition.removeAll()
        lastQueueItems.removeAll()
    }

    /// Records what a track turned out to be, keyed by URI. Called by the
    /// browse and enqueue paths, which are the only writers.
    public func remember(_ track: CachedTrack, forURI uri: String) {
        cachedTrackInfo[uri] = track
        if let decoded = uri.removingPercentEncoding, decoded != uri {
            cachedTrackInfo[decoded] = track
        }
    }

    /// Records the first page of a group's queue for now-playing recovery,
    /// enriching on the way in. Storage is `private(set)`: enrichment is the
    /// invariant, so a second writer cannot store unenriched rows and change
    /// which title, artist and art the recovery path returns.
    public func recordQueuePage(_ rawItems: [QueueItem], for coordinatorID: String) {
        guard !rawItems.isEmpty else { return }
        lastQueueItems[coordinatorID] = rawItems.map { enrichQueueItemFromCache($0) }
    }

    /// Forgets a group's cached page — used when its queue is cleared or
    /// replaced wholesale.
    public func forgetQueuePage(for coordinatorID: String) {
        lastQueueItems[coordinatorID] = nil
    }

    public func cachedTrack(forURI uri: String) -> CachedTrack? {
        cachedTrackInfo[uri] ?? uri.removingPercentEncoding.flatMap { cachedTrackInfo[$0] }
    }

    /// Cached track info — populated when adding Service Search items to queue.
    /// Used to recover title/artist when the speaker returns empty TrackMetaData.
    public struct CachedTrack {
        public let title: String
        public let artist: String
        public let album: String
        public let artURL: String?
        public init(title: String, artist: String, album: String, artURL: String?) {
            self.title = title; self.artist = artist; self.album = album; self.artURL = artURL
        }
    }

    @ObservationIgnored private var localAlbumArtFetches = Set<String>()

    public internal(set) var cachedTrackInfo: [String: CachedTrack] = [:]          // keyed by URI

    public internal(set) var cachedTrackByPosition: [String: [Int: CachedTrack]] = [:] // keyed by groupID -> queue position

    /// Last-fetched queue items per group — used for track info recovery
    public private(set) var lastQueueItems: [String: [QueueItem]] = [:]

    /// Replaces a queue row's filename/empty title (and missing artist/art)
    /// with the cached values captured at play time, keyed by the row's URI.
    /// Clips with a title fetch already started this session, so a
    /// queue full of unresolved Suno rows triggers at most one fetch each.
    private var sunoTitleFetches = Set<String>()

    /// Self-heal a Suno track's title when it isn't in the persistent store
    /// (e.g. a clip queued without going through the resolver). Fetches the
    /// `/song/<uuid>` page in the background — which persists the title — then
    /// patches any now-playing row and refreshes the queue.
    public func ensureSunoTitle(forUUID uuid: String) {
        guard SunoCatalog.title(forUUID: uuid) == nil,
              sunoTitleFetches.insert(uuid).inserted else { return }
        Task { [weak self] in
            _ = try? await SunoResolver.resolve("https://suno.com/song/\(uuid)")
            guard let self, let title = SunoCatalog.title(forUUID: uuid) else { return }
            self.nowPlayingPatcher?.patchNowPlayingTitle(title, forSunoUUID: uuid)
            self.postQueueChanged(optimisticItems: [])
        }
    }

    /// One iTunes `lookup?id=` per catalog song per session — self-heals
    /// Apple Music queue rows whose speaker-side metadata is bare (the
    /// descriptor-free fast enqueue stores none, and the session cache
    /// doesn't survive a relaunch). Same pattern as `ensureSunoTitle`.
    private var amQueueMetaFetches = Set<String>()

    /// Resolved iTunes art for local-library albums, keyed by album+artist.
    /// The speaker's `getaa` art proxy 404s for some NAS files (no embedded
    /// cover, or the speaker can't extract it), leaving queue rows blank even
    /// though Now Playing shows art — because Now Playing already resolves
    /// local art through this same iTunes path. One lookup per album paints
    /// every row of that album.
    public internal(set) var localAlbumArt: [String: String] = [:]

    private var localAlbumArtLoaded = false

    private let localAlbumArtURL = AppPaths.appSupportDirectory.appendingPathComponent("local_album_art.json")

    /// Loads the persisted album→art map once. Persisting the resolved iTunes
    /// URLs (not just the image bytes, which `ImageCache` already keeps) means
    /// a relaunch paints covers instantly instead of re-hitting iTunes for
    /// every album.
    public func loadLocalAlbumArtIfNeeded() {
        guard !localAlbumArtLoaded else { return }
        localAlbumArtLoaded = true
        if let data = try? Data(contentsOf: localAlbumArtURL),
           let map = try? JSONDecoder().decode([String: String].self, from: data) {
            localAlbumArt = map
        }
    }

    private func persistLocalAlbumArt() {
        guard let data = try? JSONEncoder().encode(localAlbumArt) else { return }
        try? data.write(to: localAlbumArtURL, options: .atomic)
    }

    static func localAlbumKey(artist: String, album: String) -> String {
        "\(album.lowercased())\u{1F}\(artist.lowercased())"
    }

    func ensureLocalQueueArt(artist: String, album: String) {
        guard !artist.isEmpty, !album.isEmpty else { return }
        Task { [weak self] in
            if (await self?.resolveLocalAlbumArt(artist: artist, album: album)) != nil {
                self?.postQueueChanged(optimisticItems: [])
            }
        }
    }

    /// Awaitable cache-or-search for a local album's iTunes art, persisted to
    /// disk so each album resolves once across launches. A cache hit returns
    /// regardless of limiter state; a miss only hits iTunes when the limiter
    /// has budget (browsing a large library must not pile on during a
    /// cooldown), and a failed lookup stays retryable. Shared by the
    /// live-queue resolver, the Queue Library, and local-library browse art.
    public func resolveLocalAlbumArt(artist: String, album: String) async -> String? {
        guard !artist.isEmpty, !album.isEmpty else { return nil }
        loadLocalAlbumArtIfNeeded()
        let key = Self.localAlbumKey(artist: artist, album: album)
        if let cached = localAlbumArt[key] { return cached }
        // Don't attempt while iTunes is cooling down — defer so the row
        // retries once budget returns instead of staying blank.
        guard await ITunesRateLimiter.shared.snapshot().isAvailable else { return nil }
        // Dedupe concurrent lookups for the same album.
        guard localAlbumArtFetches.insert(key).inserted else { return localAlbumArt[key] }
        let art = await albumArtSearch.searchArtwork(artist: artist, album: album)
        if let art, !art.isEmpty {
            localAlbumArt[key] = art
            persistLocalAlbumArt()
            return art
        }
        // Allow a later retry (e.g. after a transient cooldown clears).
        localAlbumArtFetches.remove(key)
        return nil
    }

    /// Whether a stored/parsed art URL won't render in this household — the
    /// speaker's getaa proxy 404s for some local NAS files.
    public static func isUnreliableLocalArt(uri: String?, art: String?) -> Bool {
        (uri.map(URIPrefix.isLocal) == true) && (art == nil || art!.isEmpty || art!.contains("/getaa"))
    }

    /// Resolves local-library art for an arbitrary track list (Queue Library
    /// detail / smart-queue tracks) so their rows render iTunes art instead
    /// of dead getaa URLs.
    public func resolveLocalArt(in tracks: [QueueItem]) async -> [QueueItem] {
        var out: [QueueItem] = []
        for var t in tracks {
            if Self.isUnreliableLocalArt(uri: t.uri, art: t.albumArtURI),
               let art = await resolveLocalAlbumArt(artist: t.artist, album: t.album) {
                t.albumArtURI = art
            }
            out.append(t)
        }
        return out
    }

    public func ensureAppleMusicQueueMetadata(songID: String, uri: String) {
        guard amQueueMetaFetches.insert(songID).inserted else { return }
        Task { [weak self] in
            guard let url = URL(string: "https://itunes.apple.com/lookup?id=\(songID)") else { return }
            guard let (data, _) = await ITunesRateLimiter.shared.perform(
                url: url, session: URLSession.shared, maxWait: 8
            ), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let first = (json["results"] as? [[String: Any]])?.first,
               let title = first["trackName"] as? String, !title.isEmpty,
               let self else { return }
            let art = (first["artworkUrl100"] as? String)?
                .replacingOccurrences(of: "100x100", with: "600x600")
            let cached = CachedTrack(title: title,
                                     artist: first["artistName"] as? String ?? "",
                                     album: first["collectionName"] as? String ?? "",
                                     artURL: art)
            self.cachedTrackInfo[uri] = cached
            if let d = uri.removingPercentEncoding, d != uri { self.cachedTrackInfo[d] = cached }
            self.postQueueChanged(optimisticItems: [])
        }
    }

    public func enrichQueueItemFromCache(_ item: QueueItem) -> QueueItem {
        var copy = item

        // Suno code path — keyed on the suno.ai host + clip UUID in the row's
        // URI. Cover is derived from the UUID; title comes from the persistent
        // store. Both survive restarts (the speaker returns a blank getaa art
        // proxy + the filename as title for these direct-URL tracks).
        if let uri = item.uri, let uuid = SunoCatalog.uuid(fromURI: uri) {
            copy.albumArtURI = SunoCatalog.coverURL(forUUID: uuid)
            if let t = SunoCatalog.title(forUUID: uuid) {
                copy.title = t
            } else if copy.title.isEmpty || TrackMetadata.isTechnicalName(copy.title) {
                ensureSunoTitle(forUUID: uuid)
            }
            return copy
        }

        // TIDAL code path — resolved CDN URL with no embedded cover id; art /
        // title / artist come from the persistent catalog (see TidalCatalog).
        if let uri = item.uri, TidalCatalog.key(fromURI: uri) != nil {
            if let art = TidalCatalog.art(forURI: uri) { copy.albumArtURI = art }
            if copy.title.isEmpty || TrackMetadata.isTechnicalName(copy.title),
               let t = TidalCatalog.title(forURI: uri) { copy.title = t }
            if copy.artist.isEmpty, let a = TidalCatalog.artist(forURI: uri) { copy.artist = a }
            return copy
        }

        // Local-library art: the speaker's getaa proxy 404s for some NAS
        // files, so prefer iTunes-resolved album art (the same source Now
        // Playing uses for these tracks) and kick off a lookup on miss.
        // Media-server rows join this path: their speaker proxy 404s whenever
        // the file has no embedded art, and the server itself may publish no
        // cover. Server-published art (substituted at parse time) stays
        // authoritative; only proxy-or-nothing rows fall through to iTunes.
        // Checked against the persisted content-host store, not the live
        // `mediaServerHosts` list: queue rows load before discovery has answered,
        // and rows classified in that window would stay placeholder until a
        // later queue refresh.
        let rowHost = item.uri.flatMap { URL(string: $0)?.host }
        let isMediaServerRow = rowHost.map { host in
            (mediaServerHosts?.knownMediaServerHosts().contains(host) ?? false)
                || MediaServerService.ContentHosts.serverID(servingHost: host) != nil
        } ?? false
        let hasServerArt = isMediaServerRow
            && (copy.albumArtURI.map { !$0.isEmpty && !$0.contains("/getaa?") } ?? false)
        if let uri = item.uri, URIPrefix.isLocal(uri) || (isMediaServerRow && !hasServerArt),
           !copy.artist.isEmpty, !copy.album.isEmpty {
            loadLocalAlbumArtIfNeeded()
            let key = Self.localAlbumKey(artist: copy.artist, album: copy.album)
            if let resolved = localAlbumArt[key] {
                copy.albumArtURI = resolved
            } else {
                ensureLocalQueueArt(artist: copy.artist, album: copy.album)
            }
        }

        guard let uri = item.uri,
              let cached = cachedTrackInfo[uri]
                ?? (uri.removingPercentEncoding.flatMap { cachedTrackInfo[$0] })
        else {
            // Bare Apple Music row with no session cache (post-relaunch):
            // self-heal from iTunes by the URI's authoritative catalog ID,
            // then refresh the queue.
            if let uri = item.uri,
               item.title.isEmpty || TrackMetadata.isTechnicalName(item.title),
               let songID = URIPrefix.appleMusicSongID(from: uri) {
                ensureAppleMusicQueueMetadata(songID: songID, uri: uri)
            }
            // Return `copy`, not `item`: local-library rows have no session
            // cache entry, so they reach this branch, and `copy` carries the
            // iTunes-resolved album art assigned above.
            return copy
        }
        // Title only when the speaker gave a filename/empty; artwork whenever
        // missing (direct-URL tracks often report a title but no art).
        if (copy.title.isEmpty || TrackMetadata.isTechnicalName(copy.title)), !cached.title.isEmpty {
            copy.title = cached.title
        }
        if copy.artist.isEmpty { copy.artist = cached.artist }
        if copy.album.isEmpty { copy.album = cached.album }
        if (copy.albumArtURI == nil || copy.albumArtURI?.isEmpty == true), let art = cached.artURL {
            copy.albumArtURI = art
        }
        return copy
    }

    /// Posts a `.queueChanged` notification. When `optimisticItems` is
    /// non-empty, subscribers (QueueView) append the items directly and skip
    /// the full `Browse(Q:0)` round-trip. When empty, subscribers do a full
    /// reload. Use the plural form for both single- and multi-track adds.
    public func postQueueChanged(optimisticItems: [QueueItem]) {
        if optimisticItems.isEmpty {
            NotificationCenter.default.post(name: .queueChanged, object: nil)
        } else {
            NotificationCenter.default.post(
                name: .queueChanged,
                object: nil,
                userInfo: [QueueChangeKey.optimisticItems: optimisticItems]
            )
        }
    }
}
