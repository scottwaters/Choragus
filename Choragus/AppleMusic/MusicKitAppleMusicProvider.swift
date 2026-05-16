/// MusicKitAppleMusicProvider.swift — MusicKit-backed implementation
/// of `AppleMusicProvider`. Compiled only when the build defines
/// `ENABLE_MUSICKIT` AND the SDK exposes the framework. Fork builds
/// skip this file entirely and resolve `AppleMusicProvider` to
/// `DisabledAppleMusicProvider` via the factory.
///
/// v1 wires authorisation + storefront detection only. Search,
/// library, and catalog enrichment land in follow-up iterations.
import Foundation
import SonosKit

#if ENABLE_MUSICKIT && canImport(MusicKit)
import MusicKit

/// Library item artwork URLs use a `musicKit://artwork/transient/...`
/// scheme that only Apple's `ArtworkImage` SwiftUI view can load. We
/// stash every Artwork value we see against the URL `Artwork.url(_:_:)`
/// returns, so the view layer can hand the raw `Artwork` to
/// `ArtworkImage`. Catalog items have https URLs and never need the
/// registry; the indirection is harmless for them.
public final class MusicKitArtworkRegistry: @unchecked Sendable {
    public static let shared = MusicKitArtworkRegistry()
    private let lock = NSLock()
    private var map: [URL: Artwork] = [:]

    public func register(_ artwork: Artwork, url: URL) {
        lock.lock(); defer { lock.unlock() }
        map[url] = artwork
    }

    public func artwork(for url: URL) -> Artwork? {
        lock.lock(); defer { lock.unlock() }
        return map[url]
    }
}

public final class MusicKitAppleMusicProvider: AppleMusicProvider, @unchecked Sendable {
    public init() {}

    // No runtime entitlement gate. MusicKit on macOS does NOT use
    // `com.apple.developer.musickit` — that key is iOS-only and is
    // explicitly rejected by App Store Connect upload validation when
    // present on a macOS binary. macOS gates authorisation via the
    // App ID's MusicKit Service binding + `NSAppleMusicUsageDescription`
    // in Info.plist. The TCC prompt is satisfied by the Info.plist key;
    // no signature-side capability needed.

    public var authorisation: AppleMusicAuthorisation {
        get async {
            mapStatus(MusicAuthorization.currentStatus)
        }
    }

    /// First request triggers the system permission prompt. Subsequent
    /// calls return the cached status without re-prompting.
    public func requestAuthorisation() async -> AppleMusicAuthorisation {
        let status = await MusicAuthorization.request()
        return mapStatus(status)
    }

    public var isOperational: Bool {
        get async {
            switch await authorisation {
            case .authorised: return true
            default: return false
            }
        }
    }

    public func currentStorefront() async -> String? {
        guard case .authorised = await authorisation else { return nil }
        do {
            let storefront = try await MusicDataRequest.currentCountryCode
            return storefront
        } catch {
            return nil
        }
    }

    public func search(query: String, limit: Int) async -> AppleMusicSearchResults {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, await isOperational else { return .empty }
        // Run primary search + suggestions-with-topResults in parallel.
        // Apple's plain catalog search misses prefix queries (typing
        // "yankov" returns 11 unrelated artists, no Yankovic); the
        // suggestions API with `includingTopResultsOfTypes` is what the
        // Apple Music app itself uses for type-ahead — it does proper
        // prefix matching and surfaces the canonical "top result".
        async let primary = catalogSearch(term: trimmed, limit: limit)
        async let topResults = catalogSuggestionTopResults(term: trimmed, limit: limit)
        let (broad, top) = await (primary, topResults)
        return Self.merge(topResults: top, primary: broad)
    }

    /// Top-result wins (prefix-matched, canonical), then primary fills
    /// in the rest. De-duped by id. Preserves the order in each list.
    private static func merge(topResults: AppleMusicSearchResults,
                              primary: AppleMusicSearchResults) -> AppleMusicSearchResults {
        func combine<T: Identifiable>(_ a: [T], _ b: [T]) -> [T] where T.ID: Hashable {
            var seen = Set<T.ID>()
            var out: [T] = []
            for item in a + b {
                if seen.insert(item.id).inserted { out.append(item) }
            }
            return out
        }
        return AppleMusicSearchResults(
            tracks: combine(topResults.tracks, primary.tracks),
            albums: combine(topResults.albums, primary.albums),
            artists: combine(topResults.artists, primary.artists),
            playlists: combine(topResults.playlists, primary.playlists)
        )
    }

    private func catalogSearch(term: String, limit: Int) async -> AppleMusicSearchResults {
        do {
            var request = MusicCatalogSearchRequest(
                term: term,
                types: [Song.self, Album.self, Artist.self, Playlist.self]
            )
            request.limit = max(1, min(limit, 25))
            let response = try await request.response()
            return AppleMusicSearchResults(
                tracks: response.songs.map(Self.mapTrack),
                albums: response.albums.map(Self.mapAlbum),
                artists: response.artists.map(Self.mapArtist),
                playlists: response.playlists.map(Self.mapPlaylist)
            )
        } catch {
            sonosDiagLog(.warning, tag: "APPLE_MUSICKIT_SEARCH",
                         "catalogSearch error: \(error)",
                         context: ["term": term, "error": String(describing: error)])
            return .empty
        }
    }

    private func catalogSuggestionTopResults(term: String, limit: Int) async -> AppleMusicSearchResults {
        do {
            var req = MusicCatalogSearchSuggestionsRequest(
                term: term,
                includingTopResultsOfTypes: [Song.self, Album.self, Artist.self, Playlist.self]
            )
            req.limit = max(1, min(limit, 25))
            let response = try await req.response()
            var tracks: [AppleMusicTrack] = []
            var albums: [AppleMusicAlbum] = []
            var artists: [AppleMusicArtist] = []
            var playlists: [AppleMusicPlaylist] = []
            for top in response.topResults {
                switch top {
                case .song(let s):     tracks.append(Self.mapTrack(s))
                case .album(let a):    albums.append(Self.mapAlbum(a))
                case .artist(let a):   artists.append(Self.mapArtist(a))
                case .playlist(let p): playlists.append(Self.mapPlaylist(p))
                default: break
                }
            }
            return AppleMusicSearchResults(
                tracks: tracks, albums: albums,
                artists: artists, playlists: playlists
            )
        } catch {
            sonosDiagLog(.warning, tag: "APPLE_MUSICKIT_SEARCH",
                         "suggestion-topResults error: \(error)",
                         context: ["term": term, "error": String(describing: error)])
            return .empty
        }
    }

    public func topCharts(limit: Int) async -> AppleMusicBrowse {
        guard await isOperational else { return .empty }
        let capped = max(1, min(limit, 25))
        do {
            var request = MusicCatalogChartsRequest(
                kinds: [.mostPlayed],
                types: [Song.self, Album.self, Playlist.self]
            )
            request.limit = capped
            let response = try await request.response()
            let songs = response.songCharts.flatMap { $0.items }.prefix(capped).map(Self.mapTrack)
            let albums = response.albumCharts.flatMap { $0.items }.prefix(capped).map(Self.mapAlbum)
            let playlists = response.playlistCharts.flatMap { $0.items }.prefix(capped).map(Self.mapPlaylist)
            return AppleMusicBrowse(
                topSongs: Array(songs),
                topAlbums: Array(albums),
                topPlaylists: Array(playlists)
            )
        } catch {
            return .empty
        }
    }

    public func genres() async -> [AppleMusicGenre] {
        guard await isOperational else { return [] }
        do {
            let request = MusicCatalogResourceRequest<Genre>()
            let response = try await request.response()
            return response.items.map { AppleMusicGenre(id: $0.id.rawValue, name: $0.name) }
        } catch {
            return []
        }
    }

    public func charts(forGenreID genreID: String, limit: Int) async -> AppleMusicBrowse {
        guard await isOperational else { return .empty }
        let capped = max(1, min(limit, 25))
        // MusicCatalogChartsRequest's genre filter takes a `Genre` object,
        // not an ID — resolve the genre first, then issue the chart query.
        do {
            let genreRequest = MusicCatalogResourceRequest<Genre>(
                matching: \.id,
                equalTo: MusicItemID(genreID)
            )
            let genreResponse = try await genreRequest.response()
            guard let genre = genreResponse.items.first else { return .empty }
            var request = MusicCatalogChartsRequest(
                genre: genre,
                kinds: [.mostPlayed],
                types: [Song.self, Album.self, Playlist.self]
            )
            request.limit = capped
            let response = try await request.response()
            let songs = response.songCharts.flatMap { $0.items }.prefix(capped).map(Self.mapTrack)
            let albums = response.albumCharts.flatMap { $0.items }.prefix(capped).map(Self.mapAlbum)
            let playlists = response.playlistCharts.flatMap { $0.items }.prefix(capped).map(Self.mapPlaylist)
            return AppleMusicBrowse(
                topSongs: Array(songs),
                topAlbums: Array(albums),
                topPlaylists: Array(playlists)
            )
        } catch {
            return .empty
        }
    }

    public func lookupSong(title: String, artist: String) async -> AppleMusicSongDetails? {
        guard await isOperational else { return nil }
        let term = "\(title) \(artist)".trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return nil }
        do {
            var request = MusicCatalogSearchRequest(term: term, types: [Song.self])
            request.limit = 10
            let response = try await request.response()
            // Best match: case-insensitive title + artist substring match,
            // else fall back to first result.
            let lowerTitle = title.lowercased()
            let lowerArtist = artist.lowercased()
            let match = response.songs.first { song in
                song.title.lowercased().contains(lowerTitle) &&
                song.artistName.lowercased().contains(lowerArtist)
            } ?? response.songs.first
            guard let song = match else { return nil }
            // Fetch detailed song to populate genre tags + release date.
            var detailRequest = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: song.id)
            detailRequest.properties = [.genres]
            let detailResponse = try? await detailRequest.response()
            let detailed = detailResponse?.items.first ?? song
            return AppleMusicSongDetails(
                id: detailed.id.rawValue,
                title: detailed.title,
                artist: detailed.artistName,
                album: detailed.albumTitle ?? "",
                artworkURL: Self.registerArtwork(detailed.artwork, width: 1200, height: 1200),
                genreNames: detailed.genreNames,
                releaseDate: detailed.releaseDate,
                durationSec: detailed.duration.map { Int($0) },
                isrc: detailed.isrc,
                composerName: detailed.composerName,
                discNumber: detailed.discNumber,
                trackNumber: detailed.trackNumber,
                audioVariants: Self.audioVariantLabels(detailed.audioVariants),
                contentRating: Self.contentRatingLabel(detailed.contentRating),
                appleMusicURL: detailed.url
            )
        } catch {
            return nil
        }
    }

    public func lookupAlbumDetails(artist: String, title: String) async -> AppleMusicAlbumDetails? {
        guard await isOperational else { return nil }
        let term = "\(title) \(artist)".trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return nil }
        do {
            var search = MusicCatalogSearchRequest(term: term, types: [Album.self])
            search.limit = 10
            let response = try await search.response()
            let lowerTitle = title.lowercased()
            let lowerArtist = artist.lowercased()
            let match = response.albums.first { album in
                album.title.lowercased().contains(lowerTitle) &&
                album.artistName.lowercased().contains(lowerArtist)
            } ?? response.albums.first
            guard let album = match else { return nil }
            // Pull editorial notes + genres in a second request — they
            // aren't included in default search responses.
            var detailRequest = MusicCatalogResourceRequest<Album>(matching: \.id, equalTo: album.id)
            detailRequest.properties = [.genres]
            let detailResponse = try? await detailRequest.response()
            let detailed = detailResponse?.items.first ?? album
            return AppleMusicAlbumDetails(
                id: detailed.id.rawValue,
                title: detailed.title,
                artist: detailed.artistName,
                artworkURL: Self.registerArtwork(detailed.artwork, width: 1200, height: 1200),
                releaseDate: detailed.releaseDate,
                editorialNotesShort: detailed.editorialNotes?.short,
                editorialNotesStandard: detailed.editorialNotes?.standard,
                copyright: detailed.copyright,
                recordLabel: detailed.recordLabelName,
                trackCount: detailed.trackCount,
                upc: detailed.upc,
                audioVariants: Self.audioVariantLabels(detailed.audioVariants),
                contentRating: Self.contentRatingLabel(detailed.contentRating),
                isCompilation: detailed.isCompilation ?? false,
                isSingle: detailed.isSingle ?? false,
                genreNames: detailed.genreNames,
                appleMusicURL: detailed.url
            )
        } catch {
            return nil
        }
    }

    private static func audioVariantLabels(_ variants: [MusicKit.AudioVariant]?) -> [String] {
        let list: [MusicKit.AudioVariant] = variants ?? []
        return list.map { (v: MusicKit.AudioVariant) -> String in
            switch v {
            case .dolbyAtmos: return "Dolby Atmos"
            case .dolbyAudio: return "Dolby Audio"
            case .lossless: return "Lossless"
            case .lossyStereo: return "Stereo"
            @unknown default: return String(describing: v).capitalized
            }
        }
    }

    private static func contentRatingLabel(_ rating: ContentRating?) -> String? {
        guard let rating else { return nil }
        switch rating {
        case .clean: return "Clean"
        case .explicit: return "Explicit"
        @unknown default: return nil
        }
    }

    public func lookupAlbumID(forSongCatalogID catalogID: String) async -> String? {
        guard await isOperational else { return nil }
        guard let mid = Optional(MusicItemID(catalogID)) else { return nil }
        do {
            var req = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: mid)
            req.properties = [.albums]
            let resp = try await req.response()
            return resp.items.first?.albums?.first?.id.rawValue
        } catch {
            return nil
        }
    }

    public func resolveCatalogID(forLibraryTrack track: AppleMusicTrack) async -> String? {
        // Short-circuit only when the id is already a catalog-structure
        // numeric. Hash-style library ids (large positives, negatives)
        // and letter-prefixed ids all fall through to the catalog
        // title+artist search. Without this, we'd return the original
        // library id and Sonos would fault with SOAP 800.
        if Self.idLane(track.id) == "catalog" { return track.id }
        guard await isOperational else { return nil }
        // Best-effort catalog match by (title, artist). The catalog
        // search ignores album mismatches because library copies often
        // sit on compilations / remasters with different album titles
        // than the canonical catalog entry.
        let term = "\(track.title) \(track.artist)".trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return nil }
        do {
            var request = MusicCatalogSearchRequest(term: term, types: [Song.self])
            request.limit = 5
            let response = try await request.response()
            let lowerTitle = track.title.lowercased()
            let lowerArtist = track.artist.lowercased()
            let match = response.songs.first { song in
                song.title.lowercased() == lowerTitle &&
                song.artistName.lowercased() == lowerArtist
            } ?? response.songs.first { song in
                song.title.lowercased().contains(lowerTitle) &&
                song.artistName.lowercased().contains(lowerArtist)
            } ?? response.songs.first
            let resolved = match?.id.rawValue
            // Guard against the catalog returning yet another non-
            // catalog-structure id (rare but possible when Apple returns
            // a result whose id outside the expected window — playing
            // it would re-trigger the same SOAP 800).
            if let resolved, Self.idLane(resolved) != "catalog" { return nil }
            return resolved
        } catch {
            return nil
        }
    }

    public func lookupAlbum(artist: String, title: String) async -> AppleMusicAlbum? {
        guard await isOperational else { return nil }
        let term = "\(title) \(artist)".trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return nil }
        do {
            var request = MusicCatalogSearchRequest(term: term, types: [Album.self])
            request.limit = 10
            let response = try await request.response()
            let lowerTitle = title.lowercased()
            let lowerArtist = artist.lowercased()
            let match = response.albums.first { album in
                album.title.lowercased().contains(lowerTitle) &&
                album.artistName.lowercased().contains(lowerArtist)
            } ?? response.albums.first
            guard let album = match else { return nil }
            return Self.mapAlbum(album)
        } catch {
            return nil
        }
    }

    public func lookupArtist(name: String) async -> AppleMusicArtistDetails? {
        guard await isOperational else { return nil }
        let term = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return nil }
        do {
            var request = MusicCatalogSearchRequest(term: term, types: [Artist.self])
            request.limit = 10
            let response = try await request.response()
            let lowerName = name.lowercased()
            let match = response.artists.first { $0.name.lowercased() == lowerName }
                ?? response.artists.first
            guard let artist = match else { return nil }
            var detailRequest = MusicCatalogResourceRequest<Artist>(matching: \.id, equalTo: artist.id)
            detailRequest.properties = [.genres]
            let detailResponse = try? await detailRequest.response()
            let detailed = detailResponse?.items.first ?? artist
            return AppleMusicArtistDetails(
                id: detailed.id.rawValue,
                name: detailed.name,
                artworkURL: Self.registerArtwork(detailed.artwork, width: 1200, height: 1200),
                genreNames: detailed.genres?.map(\.name) ?? [],
                editorialNotesShort: detailed.editorialNotes?.short,
                editorialNotesStandard: detailed.editorialNotes?.standard,
                appleMusicURL: detailed.url
            )
        } catch {
            return nil
        }
    }

    // MARK: - Stations + Spatial Audio

    public func searchStations(query: String, limit: Int) async -> [AppleMusicStation] {
        guard await isOperational else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        do {
            var req = MusicCatalogSearchRequest(term: trimmed, types: [Station.self])
            req.limit = max(1, min(limit, 25))
            let response = try await req.response()
            let result = response.stations.map(Self.mapStation)
            sonosDiagLog(.info, tag: "APPLE_MUSICKIT",
                         "searchStations: \(trimmed) → \(result.count) stations",
                         context: ["query": trimmed, "count": String(result.count)])
            return result
        } catch {
            sonosDiagLog(.warning, tag: "APPLE_MUSICKIT",
                         "searchStations failed: \(error)",
                         context: ["query": trimmed, "error": String(describing: error)])
            return []
        }
    }

    public func userStations(limit: Int) async -> [AppleMusicStation] {
        guard await isOperational else { return [] }
        // `Station` doesn't conform to `MusicLibraryRequestable`, so we
        // can't do a direct library query. The personalised mixes
        // ("Personal Mix", "Discovery Station", "Heavy Rotation Mix")
        // surface inside the recently-played container — same source
        // Apple Music itself uses on its home screen.
        do {
            var req = MusicRecentlyPlayedContainerRequest()
            req.limit = max(1, min(limit, 25))
            let response = try await req.response()
            var stations: [AppleMusicStation] = []
            for item in response.items {
                if case .station(let s) = item {
                    stations.append(Self.mapStation(s))
                }
            }
            sonosDiagLog(.info, tag: "APPLE_MUSICKIT",
                         "userStations → \(stations.count) stations",
                         context: ["count": String(stations.count)])
            return stations
        } catch {
            sonosDiagLog(.warning, tag: "APPLE_MUSICKIT",
                         "userStations failed: \(error)",
                         context: ["error": String(describing: error)])
            return []
        }
    }

    public func spatialAudioAlbums(limit: Int) async -> [AppleMusicAlbum] {
        guard await isOperational else { return [] }
        let capped = max(1, min(limit, 25))
        // No dedicated Apple endpoint for "Spatial Audio" via MusicKit;
        // approximate by fetching the most-played album chart and
        // filtering for entries Apple flagged as Dolby Atmos.
        do {
            var req = MusicCatalogChartsRequest(
                kinds: [.mostPlayed],
                types: [Album.self]
            )
            req.limit = capped
            let response = try await req.response()
            let all = response.albumCharts.flatMap { $0.items }
            let atmos = all.filter { album in
                (album.audioVariants ?? []).contains(where: { variant in
                    if case .dolbyAtmos = variant { return true }
                    return false
                })
            }
            return atmos.map(Self.mapAlbum)
        } catch { return [] }
    }

    // MARK: - Type mappers

    /// Registers `artwork` against the URL it would render to and
    /// returns that URL. Use the returned URL on `AppleMusic*` types so
    /// `AppleMusicArtworkSquare` can fetch the raw `Artwork` back and
    /// render via Apple's `ArtworkImage` — necessary for library items
    /// whose URLs use the `musicKit://artwork/transient/...` scheme
    /// that `URLSession` can't load.
    private static func registerArtwork(_ artwork: Artwork?, width: Int = 600, height: Int = 600) -> URL? {
        guard let artwork, let url = artwork.url(width: width, height: height) else { return nil }
        MusicKitArtworkRegistry.shared.register(artwork, url: url)
        return url
    }

    private static func mapStation(_ s: Station) -> AppleMusicStation {
        AppleMusicStation(
            id: s.id.rawValue,
            name: s.name,
            curatorName: s.stationProviderName,
            artworkURL: Self.registerArtwork(s.artwork),
            isLive: s.isLive
        )
    }


    private static func mapTrack(_ song: Song) -> AppleMusicTrack {
        AppleMusicTrack(
            id: song.id.rawValue,
            title: song.title,
            artist: song.artistName,
            album: song.albumTitle ?? "",
            artworkURL: Self.registerArtwork(song.artwork),
            durationSec: song.duration.map { Int($0) },
            releaseDate: song.releaseDate
        )
    }

    /// Library-flavoured Song mapper. Library Song.id is a library-scoped
    /// identifier (`i.<uuid>`) that Sonos's Apple Music SMAPI service
    /// rejects. The playback helper does a title+artist catalog resolve
    /// at play time; here we just carry whatever id Apple gave us.
    private static func mapLibrarySong(_ song: Song) -> AppleMusicTrack {
        AppleMusicTrack(
            id: song.id.rawValue,
            title: song.title,
            artist: song.artistName,
            album: song.albumTitle ?? "",
            artworkURL: Self.registerArtwork(song.artwork),
            durationSec: song.duration.map { Int($0) },
            releaseDate: song.releaseDate,
            dateAdded: song.libraryAddedDate
        )
    }

    /// True when a library Song has minimum playable metadata. `url`
    /// isn't populated by `MusicLibraryRequest` even for tracks that
    /// ARE in the public catalog (verified empirically 2026-05-15), so
    /// we can't use it as a "is in catalog" signal. Best we can do:
    /// require `playParameters` + non-empty title + non-empty artist.
    /// Orphan history entries / partial-sync stubs have blank metadata
    /// and get filtered here; the catalog resolve at play time then
    /// decides whether Sonos can actually stream the rest.
    private static func isPlayableLibrarySong(_ song: Song) -> Bool {
        guard song.playParameters != nil else { return false }
        if song.title.isEmpty { return false }
        if song.artistName.isEmpty { return false }
        return true
    }

    private static func mapAlbum(_ album: Album) -> AppleMusicAlbum {
        AppleMusicAlbum(
            id: album.id.rawValue,
            title: album.title,
            artist: album.artistName,
            artworkURL: Self.registerArtwork(album.artwork),
            releaseDate: album.releaseDate
        )
    }

    /// Library-flavoured Album mapper — see `mapLibrarySong`.
    private static func mapLibraryAlbum(_ album: Album) -> AppleMusicAlbum {
        AppleMusicAlbum(
            id: album.id.rawValue,
            title: album.title,
            artist: album.artistName,
            artworkURL: Self.registerArtwork(album.artwork),
            releaseDate: album.releaseDate,
            dateAdded: album.libraryAddedDate
        )
    }

    private static func mapArtist(_ artist: Artist) -> AppleMusicArtist {
        AppleMusicArtist(
            id: artist.id.rawValue,
            name: artist.name,
            artworkURL: Self.registerArtwork(artist.artwork)
        )
    }

    private static func mapPlaylist(_ playlist: Playlist) -> AppleMusicPlaylist {
        AppleMusicPlaylist(
            id: playlist.id.rawValue,
            name: playlist.name,
            curatorName: playlist.curatorName,
            artworkURL: Self.registerArtwork(playlist.artwork)
        )
    }

    // MARK: - User library

    // Library fetches paginate internally — `MusicLibraryRequest`'s per-call
    // `limit` is capped at 100 by Apple, so a user library larger than 100
    // would silently truncate without this loop. Bumping the outer `limit`
    // expands the visible window.

    public func librarySongs(limit: Int) async -> [AppleMusicTrack] {
        guard await isOperational else { return [] }
        return await paginateLibrary(limit: limit) { offset, pageSize in
            var request = MusicLibraryRequest<Song>()
            request.limit = pageSize
            request.offset = offset
            let response = try await request.response()
            // Strip user-uploads / DRM-locked items — see
            // `isPlayableLibrarySong`. Sonos can't play these and
            // showing them would surface "tracks" that silently no-op.
            return response.items
                .filter(Self.isPlayableLibrarySong)
                .map(Self.mapLibrarySong)
        }
    }

    public func libraryAlbums(limit: Int) async -> [AppleMusicAlbum] {
        guard await isOperational else { return [] }
        return await paginateLibrary(limit: limit) { offset, pageSize in
            var request = MusicLibraryRequest<Album>()
            request.limit = pageSize
            request.offset = offset
            let response = try await request.response()
            return response.items.filter { Self.isPlayableLibraryAlbum($0) }.map(Self.mapLibraryAlbum)
        }
    }

    /// Album-level analog of `isPlayableLibrarySong`. `url` / `upc`
    /// aren't populated by `MusicLibraryRequest`, so we filter on the
    /// content-presence signals that ARE reliable: non-empty title +
    /// artist + at least one track.
    private static func isPlayableLibraryAlbum(_ album: Album) -> Bool {
        guard album.playParameters != nil else { return false }
        if album.title.isEmpty { return false }
        if album.artistName.isEmpty { return false }
        if album.trackCount <= 0 { return false }
        return true
    }

    public func libraryArtists(limit: Int) async -> [AppleMusicArtist] {
        guard await isOperational else { return [] }
        return await paginateLibrary(limit: limit) { offset, pageSize in
            var request = MusicLibraryRequest<Artist>()
            request.limit = pageSize
            request.offset = offset
            let response = try await request.response()
            return response.items.map(Self.mapArtist)
        }
    }

    public func libraryPlaylists(limit: Int) async -> [AppleMusicPlaylist] {
        guard await isOperational else { return [] }
        return await paginateLibrary(limit: limit) { offset, pageSize in
            var request = MusicLibraryRequest<Playlist>()
            request.limit = pageSize
            request.offset = offset
            let response = try await request.response()
            return response.items.map(Self.mapPlaylist)
        }
    }

    /// Drives an offset-based page loop against MusicLibraryRequest.
    /// Walks pages of up to 100 items each until either the target
    /// `limit` is reached or the source runs out of items.
    private func paginateLibrary<T>(limit: Int, page: (Int, Int) async throws -> [T]) async -> [T] {
        var collected: [T] = []
        let pageSize = 100
        var offset = 0
        let cap = max(1, min(limit, 5000))
        while collected.count < cap {
            let remaining = cap - collected.count
            let thisPage = min(pageSize, remaining)
            do {
                let items = try await page(offset, thisPage)
                if items.isEmpty { break }
                collected.append(contentsOf: items)
                if items.count < thisPage { break }
                offset += items.count
            } catch {
                break
            }
        }
        return collected
    }

    // MARK: - Recently played / recommendations

    public func recentlyPlayed(limit: Int) async -> AppleMusicRecentlyPlayed {
        guard await isOperational else { return .empty }
        do {
            var request = MusicRecentlyPlayedContainerRequest()
            request.limit = max(1, min(limit, 25))
            let response = try await request.response()
            var albums: [AppleMusicAlbum] = []
            var playlists: [AppleMusicPlaylist] = []
            for item in response.items {
                switch item {
                case .album(let a): albums.append(Self.mapAlbum(a))
                case .playlist(let p): playlists.append(Self.mapPlaylist(p))
                case .station: continue // Sonos owns radio
                @unknown default: continue
                }
            }
            return AppleMusicRecentlyPlayed(albums: albums, playlists: playlists)
        } catch { return .empty }
    }

    public func recommendations() async -> [AppleMusicRecommendation] {
        guard await isOperational else { return [] }
        do {
            let request = MusicPersonalRecommendationsRequest()
            let response = try await request.response()
            return response.recommendations.map { rec in
                var albums: [AppleMusicAlbum] = []
                var playlists: [AppleMusicPlaylist] = []
                var stations: [AppleMusicStation] = []
                for album in rec.albums { albums.append(Self.mapAlbum(album)) }
                for playlist in rec.playlists { playlists.append(Self.mapPlaylist(playlist)) }
                for station in rec.stations { stations.append(Self.mapStation(station)) }
                return AppleMusicRecommendation(
                    id: rec.id.rawValue,
                    title: rec.title ?? "Recommended",
                    albums: albums,
                    playlists: playlists,
                    stations: stations
                )
            }
        } catch { return [] }
    }

    // MARK: - Drilldowns

    public func albumTracks(albumID: String) async -> [AppleMusicTrack] {
        guard await isOperational else { return [] }
        let lane = Self.idLane(albumID)
        let result: [AppleMusicTrack]
        if lane == "catalog" {
            result = await catalogAlbumTracks(albumID: albumID)
        } else {
            result = await libraryAlbumTracks(albumID: albumID)
        }
        sonosDiagLog(.info, tag: "APPLE_MUSICKIT",
                     "albumTracks: \(albumID) → \(result.count) tracks",
                     context: ["albumID": albumID, "lane": lane, "count": String(result.count)])
        return result
    }

    /// Catalog Apple Music ids are positive integers — most are 9-10
    /// digits but some (legacy artists like The Beatles `136975`) sit
    /// well below 1e8. Library items come in two structures:
    /// letter-prefixed (`l.xxxx`, `p.xxxx`, `r.xxxx`, `i.xxxx`) AND
    /// hash-style 64-bit integers (negative, or 13+ digit positives
    /// that wrap around Int64). Lane = library when the id is
    /// non-numeric, negative, or a hash-style giant; otherwise catalog.
    private static func idLane(_ id: String) -> String {
        guard let value = Int64(id) else { return "library" }
        if value <= 0 { return "library" }
        if value > 1_000_000_000_000 { return "library" }
        return "catalog"
    }

    private func catalogAlbumTracks(albumID: String) async -> [AppleMusicTrack] {
        do {
            var request = MusicCatalogResourceRequest<Album>(matching: \.id, equalTo: MusicItemID(albumID))
            request.properties = [.tracks]
            let response = try await request.response()
            guard let album = response.items.first, let tracks = album.tracks else { return [] }
            return tracks.map { track in
                AppleMusicTrack(
                    id: track.id.rawValue,
                    title: track.title,
                    artist: track.artistName,
                    album: album.title,
                    artworkURL: Self.registerArtwork(track.artwork ?? album.artwork),
                    durationSec: track.duration.map { Int($0) },
                    releaseDate: track.releaseDate
                )
            }
        } catch { return [] }
    }

    private func libraryAlbumTracks(albumID: String) async -> [AppleMusicTrack] {
        do {
            var request = MusicLibraryRequest<Album>()
            request.filter(matching: \.id, equalTo: MusicItemID(albumID))
            let response = try await request.response()
            guard let album = response.items.first else { return [] }
            let loaded = try await album.with([.tracks])
            guard let tracks = loaded.tracks else { return [] }
            // Track-list filter mirrors `librarySongs`.
            return tracks.compactMap { track -> AppleMusicTrack? in
                guard track.playParameters != nil else { return nil }
                guard !track.title.isEmpty else { return nil }
                guard !track.artistName.isEmpty else { return nil }
                return AppleMusicTrack(
                    id: track.id.rawValue,
                    title: track.title,
                    artist: track.artistName,
                    album: loaded.title,
                    artworkURL: Self.registerArtwork(track.artwork ?? loaded.artwork),
                    durationSec: track.duration.map { Int($0) },
                    releaseDate: track.releaseDate
                )
            }
        } catch { return [] }
    }

    public func playlistTracks(playlistID: String) async -> [AppleMusicTrack] {
        guard await isOperational else { return [] }
        let lane: String
        if playlistID.hasPrefix("p.") {
            lane = "library"
        } else if playlistID.hasPrefix("pl.") {
            lane = "catalog"
        } else {
            lane = Self.idLane(playlistID)
        }
        let result: [AppleMusicTrack]
        if lane == "library" {
            result = await libraryPlaylistTracks(playlistID: playlistID)
        } else {
            result = await catalogPlaylistTracks(playlistID: playlistID)
        }
        sonosDiagLog(.info, tag: "APPLE_MUSICKIT",
                     "playlistTracks: \(playlistID) → \(result.count) tracks",
                     context: ["playlistID": playlistID, "lane": lane, "count": String(result.count)])
        return result
    }

    private func catalogPlaylistTracks(playlistID: String) async -> [AppleMusicTrack] {
        do {
            var request = MusicCatalogResourceRequest<Playlist>(matching: \.id, equalTo: MusicItemID(playlistID))
            request.properties = [.tracks]
            let response = try await request.response()
            guard let playlist = response.items.first, let tracks = playlist.tracks else { return [] }
            return tracks.map { track in
                AppleMusicTrack(
                    id: track.id.rawValue,
                    title: track.title,
                    artist: track.artistName,
                    album: track.albumTitle ?? "",
                    artworkURL: Self.registerArtwork(track.artwork),
                    durationSec: track.duration.map { Int($0) },
                    releaseDate: track.releaseDate
                )
            }
        } catch { return [] }
    }

    private func libraryPlaylistTracks(playlistID: String) async -> [AppleMusicTrack] {
        do {
            var request = MusicLibraryRequest<Playlist>()
            request.filter(matching: \.id, equalTo: MusicItemID(playlistID))
            let response = try await request.response()
            guard let playlist = response.items.first else { return [] }
            let loaded = try await playlist.with([.tracks])
            guard let tracks = loaded.tracks else { return [] }
            return tracks.map { track in
                AppleMusicTrack(
                    id: track.id.rawValue,
                    title: track.title,
                    artist: track.artistName,
                    album: track.albumTitle ?? "",
                    artworkURL: Self.registerArtwork(track.artwork),
                    durationSec: track.duration.map { Int($0) },
                    releaseDate: track.releaseDate
                )
            }
        } catch { return [] }
    }

    public func artistAlbums(artistID: String) async -> [AppleMusicAlbum] {
        guard await isOperational else { return [] }
        let lane = Self.idLane(artistID)
        let result: [AppleMusicAlbum]
        if lane == "catalog" {
            result = await catalogArtistAlbums(artistID: artistID)
        } else {
            result = await libraryArtistAlbums(artistID: artistID)
        }
        sonosDiagLog(.info, tag: "APPLE_MUSICKIT",
                     "artistAlbums: \(artistID) → \(result.count) albums",
                     context: ["artistID": artistID, "lane": lane, "count": String(result.count)])
        return result
    }

    private func catalogArtistAlbums(artistID: String) async -> [AppleMusicAlbum] {
        do {
            var request = MusicCatalogResourceRequest<Artist>(matching: \.id, equalTo: MusicItemID(artistID))
            request.properties = [.albums]
            let response = try await request.response()
            guard let artist = response.items.first, let albums = artist.albums else { return [] }
            return albums.map(Self.mapAlbum)
        } catch { return [] }
    }

    private func libraryArtistAlbums(artistID: String) async -> [AppleMusicAlbum] {
        do {
            // Find the library Artist, expand `.albums` relationship.
            var req = MusicLibraryRequest<Artist>()
            req.filter(matching: \.id, equalTo: MusicItemID(artistID))
            let response = try await req.response()
            guard let artist = response.items.first else { return [] }
            let loaded = try await artist.with([.albums])
            guard let albums = loaded.albums else { return [] }
            return albums.map(Self.mapLibraryAlbum)
        } catch { return [] }
    }

    public func artistTopSongs(artistID: String, limit: Int) async -> [AppleMusicTrack] {
        guard await isOperational else { return [] }
        let lane = Self.idLane(artistID)
        let result: [AppleMusicTrack]
        if lane == "catalog" {
            result = await catalogArtistTopSongs(artistID: artistID, limit: limit)
        } else {
            result = await libraryArtistSongs(artistID: artistID)
        }
        sonosDiagLog(.info, tag: "APPLE_MUSICKIT",
                     "artistTopSongs: \(artistID) → \(result.count) tracks",
                     context: ["artistID": artistID, "lane": lane, "count": String(result.count)])
        return result
    }

    private func catalogArtistTopSongs(artistID: String, limit: Int) async -> [AppleMusicTrack] {
        do {
            var request = MusicCatalogResourceRequest<Artist>(matching: \.id, equalTo: MusicItemID(artistID))
            request.properties = [.topSongs]
            let response = try await request.response()
            guard let artist = response.items.first, let songs = artist.topSongs else { return [] }
            return songs.prefix(max(1, min(limit, 50))).map(Self.mapTrack)
        } catch { return [] }
    }

    private func libraryArtistSongs(artistID: String) async -> [AppleMusicTrack] {
        // Library `Artist` doesn't expose a direct `.tracks` or
        // `.songs` relationship. Resolve the artist name first,
        // then page library songs by `artistName`. Strip
        // non-Apple-Music-playable items (user uploads etc.).
        let artistName: String
        do {
            var artistReq = MusicLibraryRequest<Artist>()
            artistReq.filter(matching: \.id, equalTo: MusicItemID(artistID))
            let artistResponse = try await artistReq.response()
            guard let artist = artistResponse.items.first else { return [] }
            artistName = artist.name
        } catch { return [] }
        return await paginateLibrary(limit: 5000) { offset, pageSize in
            var songReq = MusicLibraryRequest<Song>()
            songReq.filter(matching: \.artistName, equalTo: artistName)
            songReq.limit = pageSize
            songReq.offset = offset
            let songResponse = try await songReq.response()
            return songResponse.items
                .filter(Self.isPlayableLibrarySong)
                .map(Self.mapLibrarySong)
        }
    }

    private func mapStatus(_ status: MusicAuthorization.Status) -> AppleMusicAuthorisation {
        switch status {
        case .notDetermined: return .notDetermined
        case .denied:        return .denied
        case .restricted:    return .denied
        case .authorized:    return .authorised
        @unknown default:    return .notDetermined
        }
    }
}

#endif
