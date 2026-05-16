/// AppleMusicProvider.swift — Abstraction over the source of Apple
/// Music catalog data (browse / search / artwork / metadata).
///
/// Why a protocol — Choragus needs to behave differently across three
/// build profiles, and the differences should be confined to one swap
/// point rather than scattered across views and services:
///
///   | Profile         | ENABLE_MUSICKIT | SHOW_LEGACY_APPLE_MUSIC | Result                                  |
///   |-----------------|-----------------|-------------------------|-----------------------------------------|
///   | OSS fork        | off             | on (default)            | Legacy SMAPI Apple Music only           |
///   | Dev iteration   | on              | on                      | Both UIs visible for side-by-side test  |
///   | Signed release  | on              | off                     | MusicKit Apple Music only; legacy hidden|
///
/// The flags are Swift compilation conditions injected via
/// `SWIFT_ACTIVE_COMPILATION_CONDITIONS` on the xcodebuild command
/// line (see `scripts/dev-build.sh` and `scripts/release.sh`). The
/// committed `project.pbxproj` carries no flags so a fork that runs
/// bare `xcodebuild -scheme Choragus` lands in the OSS-fork profile
/// with zero configuration.
///
/// **Playback** is unchanged across all three profiles — Apple Music
/// audio still reaches the speaker via Sonos's SMAPI URL scheme
/// (`x-sonosapi-hls-static:song:<id>`) because Apple's DRM forbids
/// extracting playable URLs from MusicKit for forwarding to a
/// third-party renderer. MusicKit's value here is browse / search /
/// metadata enrichment, not delivery.
import Foundation

/// Minimal Apple Music catalog item surfaces. Mirror the fields the UI
/// actually renders; nothing else. Provider implementations populate
/// these from whichever backend they wrap — MusicKit's `Song` /
/// `Album` types, or empty-result stubs on disabled providers.

public struct AppleMusicTrack: Identifiable, Equatable, Hashable, Sendable {
    /// Apple Music catalog ID. Identical to the numeric ID used in
    /// Sonos's `x-sonosapi-hls-static:song:<id>` SMAPI playback URI,
    /// so the existing SMAPI playback path can route MusicKit search
    /// results without a separate lookup.
    public var id: String
    public var title: String
    public var artist: String
    public var album: String
    public var artworkURL: URL?
    public var durationSec: Int?
    /// Apple Music album catalog ID. Populated where the source request
    /// gave us the album relationship — the playback DIDL needs this
    /// in `parentID="0004206calbum%3a<id>"` to satisfy Sonos's
    /// queue-advance validation (placeholders like "0" silently fail).
    public var albumID: String?
    public var releaseDate: Date?
    /// When the user added this track to their Apple Music library.
    /// Only populated for `librarySongs(...)` results.
    public var dateAdded: Date?

    public init(id: String, title: String, artist: String, album: String,
                artworkURL: URL? = nil, durationSec: Int? = nil,
                albumID: String? = nil, releaseDate: Date? = nil,
                dateAdded: Date? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkURL = artworkURL
        self.durationSec = durationSec
        self.albumID = albumID
        self.releaseDate = releaseDate
        self.dateAdded = dateAdded
    }
}

public struct AppleMusicAlbum: Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var artist: String
    public var artworkURL: URL?
    public var releaseDate: Date?
    /// When the user added this album to their Apple Music library.
    /// Only populated for `libraryAlbums(...)` results.
    public var dateAdded: Date?

    public init(id: String, title: String, artist: String,
                artworkURL: URL? = nil, releaseDate: Date? = nil,
                dateAdded: Date? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.artworkURL = artworkURL
        self.releaseDate = releaseDate
        self.dateAdded = dateAdded
    }
}

public struct AppleMusicArtist: Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var artworkURL: URL?

    public init(id: String, name: String, artworkURL: URL? = nil) {
        self.id = id
        self.name = name
        self.artworkURL = artworkURL
    }
}

public struct AppleMusicSearchResults: Equatable, Sendable {
    public var tracks: [AppleMusicTrack]
    public var albums: [AppleMusicAlbum]
    public var artists: [AppleMusicArtist]
    public var playlists: [AppleMusicPlaylist]

    public static let empty = AppleMusicSearchResults(tracks: [], albums: [], artists: [], playlists: [])

    public var isEmpty: Bool {
        tracks.isEmpty && albums.isEmpty && artists.isEmpty && playlists.isEmpty
    }

    public init(tracks: [AppleMusicTrack] = [],
                albums: [AppleMusicAlbum] = [],
                artists: [AppleMusicArtist] = [],
                playlists: [AppleMusicPlaylist] = []) {
        self.tracks = tracks
        self.albums = albums
        self.artists = artists
        self.playlists = playlists
    }
}

public struct AppleMusicPlaylist: Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var curatorName: String?
    public var artworkURL: URL?

    public init(id: String, name: String, curatorName: String? = nil, artworkURL: URL? = nil) {
        self.id = id
        self.name = name
        self.curatorName = curatorName
        self.artworkURL = artworkURL
    }
}

public struct AppleMusicGenre: Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct AppleMusicStation: Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var curatorName: String?
    public var artworkURL: URL?
    public var isLive: Bool

    public init(id: String, name: String, curatorName: String? = nil,
                artworkURL: URL? = nil, isLive: Bool = false) {
        self.id = id
        self.name = name
        self.curatorName = curatorName
        self.artworkURL = artworkURL
        self.isLive = isLive
    }
}

/// Aggregate "browse" surface returned by `topCharts` — the front-page
/// material shown to the user when they open the MusicKit view with no
/// active search query.
public struct AppleMusicBrowse: Equatable, Sendable {
    public var topSongs: [AppleMusicTrack]
    public var topAlbums: [AppleMusicAlbum]
    public var topPlaylists: [AppleMusicPlaylist]

    public static let empty = AppleMusicBrowse(topSongs: [], topAlbums: [], topPlaylists: [])

    public init(topSongs: [AppleMusicTrack] = [],
                topAlbums: [AppleMusicAlbum] = [],
                topPlaylists: [AppleMusicPlaylist] = []) {
        self.topSongs = topSongs
        self.topAlbums = topAlbums
        self.topPlaylists = topPlaylists
    }
}

/// Personalised recommendation — Apple's "For You" / "Listen Now"
/// row. Each recommendation has a label ("Recently Played", "Made for
/// You: <Genre>", "New Releases", etc.) and a mixed bag of items.
public struct AppleMusicRecommendation: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var albums: [AppleMusicAlbum]
    public var playlists: [AppleMusicPlaylist]
    public var stations: [AppleMusicStation]

    public init(id: String, title: String,
                albums: [AppleMusicAlbum] = [],
                playlists: [AppleMusicPlaylist] = [],
                stations: [AppleMusicStation] = []) {
        self.id = id
        self.title = title
        self.albums = albums
        self.playlists = playlists
        self.stations = stations
    }
}

/// User-library content slices — saved/added content for the signed-in
/// Apple Music account. Each list is a flat snapshot for the UI.
public struct AppleMusicLibrary: Equatable, Sendable {
    public var songs: [AppleMusicTrack]
    public var albums: [AppleMusicAlbum]
    public var artists: [AppleMusicArtist]
    public var playlists: [AppleMusicPlaylist]

    public static let empty = AppleMusicLibrary(songs: [], albums: [], artists: [], playlists: [])

    public init(songs: [AppleMusicTrack] = [],
                albums: [AppleMusicAlbum] = [],
                artists: [AppleMusicArtist] = [],
                playlists: [AppleMusicPlaylist] = []) {
        self.songs = songs
        self.albums = albums
        self.artists = artists
        self.playlists = playlists
    }
}

/// Mixed-type recent history. Each item is the heaviest object the
/// caller is likely to render (album cover for albums, playlist cover
/// for playlists, single track row for songs).
public struct AppleMusicRecentlyPlayed: Equatable, Sendable {
    public var albums: [AppleMusicAlbum]
    public var playlists: [AppleMusicPlaylist]

    public static let empty = AppleMusicRecentlyPlayed(albums: [], playlists: [])

    public init(albums: [AppleMusicAlbum] = [],
                playlists: [AppleMusicPlaylist] = []) {
        self.albums = albums
        self.playlists = playlists
    }
}

/// Detailed metadata for a single song — used for enrichment of
/// currently-playing track info from other sources (Last.fm, iTunes
/// Search). `genreNames` mirrors Apple's catalog genre tags as plain
/// strings since downstream consumers (NowPlaying UI, ScrobbleManager)
/// already work with strings.
public struct AppleMusicSongDetails: Equatable, Sendable {
    public var id: String
    public var title: String
    public var artist: String
    public var album: String
    public var artworkURL: URL?
    public var genreNames: [String]
    public var releaseDate: Date?
    public var durationSec: Int?
    public var isrc: String?
    public var composerName: String?
    public var discNumber: Int?
    public var trackNumber: Int?
    /// Human-readable labels for audio variants the catalog offers
    /// (e.g. `Lossless`, `Hi-Res Lossless`, `Dolby Atmos`).
    public var audioVariants: [String]
    /// "Explicit" / "Clean" — empty when unrated.
    public var contentRating: String?
    public var appleMusicURL: URL?

    public init(id: String, title: String, artist: String, album: String,
                artworkURL: URL? = nil, genreNames: [String] = [],
                releaseDate: Date? = nil, durationSec: Int? = nil,
                isrc: String? = nil, composerName: String? = nil,
                discNumber: Int? = nil, trackNumber: Int? = nil,
                audioVariants: [String] = [], contentRating: String? = nil,
                appleMusicURL: URL? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkURL = artworkURL
        self.genreNames = genreNames
        self.releaseDate = releaseDate
        self.durationSec = durationSec
        self.isrc = isrc
        self.composerName = composerName
        self.discNumber = discNumber
        self.trackNumber = trackNumber
        self.audioVariants = audioVariants
        self.contentRating = contentRating
        self.appleMusicURL = appleMusicURL
    }
}

/// Artist-level enrichment — name, image, genre tags, editorial notes.
public struct AppleMusicArtistDetails: Equatable, Sendable {
    public var id: String
    public var name: String
    public var artworkURL: URL?
    public var genreNames: [String]
    /// Apple-curated bio. Two lengths: `short` is one or two sentences,
    /// `standard` is a paragraph. Both may be nil.
    public var editorialNotesShort: String?
    public var editorialNotesStandard: String?
    public var appleMusicURL: URL?

    public init(id: String, name: String, artworkURL: URL? = nil,
                genreNames: [String] = [],
                editorialNotesShort: String? = nil,
                editorialNotesStandard: String? = nil,
                appleMusicURL: URL? = nil) {
        self.id = id
        self.name = name
        self.artworkURL = artworkURL
        self.genreNames = genreNames
        self.editorialNotesShort = editorialNotesShort
        self.editorialNotesStandard = editorialNotesStandard
        self.appleMusicURL = appleMusicURL
    }
}

/// Album-level enrichment — the fuller version of `AppleMusicAlbum`
/// with all the descriptive catalog fields.
public struct AppleMusicAlbumDetails: Equatable, Sendable {
    public var id: String
    public var title: String
    public var artist: String
    public var artworkURL: URL?
    public var releaseDate: Date?
    public var editorialNotesShort: String?
    public var editorialNotesStandard: String?
    public var copyright: String?
    public var recordLabel: String?
    public var trackCount: Int?
    public var upc: String?
    public var audioVariants: [String]
    public var contentRating: String?
    public var isCompilation: Bool
    public var isSingle: Bool
    public var genreNames: [String]
    public var appleMusicURL: URL?

    public init(id: String, title: String, artist: String,
                artworkURL: URL? = nil, releaseDate: Date? = nil,
                editorialNotesShort: String? = nil,
                editorialNotesStandard: String? = nil,
                copyright: String? = nil, recordLabel: String? = nil,
                trackCount: Int? = nil, upc: String? = nil,
                audioVariants: [String] = [], contentRating: String? = nil,
                isCompilation: Bool = false, isSingle: Bool = false,
                genreNames: [String] = [], appleMusicURL: URL? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.artworkURL = artworkURL
        self.releaseDate = releaseDate
        self.editorialNotesShort = editorialNotesShort
        self.editorialNotesStandard = editorialNotesStandard
        self.copyright = copyright
        self.recordLabel = recordLabel
        self.trackCount = trackCount
        self.upc = upc
        self.audioVariants = audioVariants
        self.contentRating = contentRating
        self.isCompilation = isCompilation
        self.isSingle = isSingle
        self.genreNames = genreNames
        self.appleMusicURL = appleMusicURL
    }
}

/// Authorisation status surfaced by the provider. Fork builds return
/// `.notApplicable` because MusicKit is not on the build path; release
/// builds return live MusicKit values.
public enum AppleMusicAuthorisation: Equatable, Sendable {
    /// MusicKit support is not compiled into this build.
    case notApplicable
    /// Compiled in but the user has not been asked yet.
    case notDetermined
    /// User explicitly declined the system permission prompt.
    case denied
    /// User has no active Apple Music subscription on this device.
    case noSubscription
    /// Fully authorised — the provider can issue catalog requests.
    case authorised
}

/// Minimal catalog-side surface that views consume. Each method has a
/// non-throwing returns-empty-on-failure shape because the UI never
/// wants to crash on a network blip — surface "no results" instead.
public protocol AppleMusicProvider: AnyObject, Sendable {
    /// Current authorisation state. Read-only; the provider drives it.
    var authorisation: AppleMusicAuthorisation { get async }

    /// Triggers the system Apple Music permission prompt where
    /// applicable. No-op on profiles without MusicKit.
    func requestAuthorisation() async -> AppleMusicAuthorisation

    /// True when this provider can serve real Apple Music data right
    /// now. Used by the UI to decide whether to render MusicKit
    /// sections or fall through to the legacy SMAPI ones.
    var isOperational: Bool { get async }

    /// Two-letter ISO storefront for the signed-in account (e.g.
    /// `"us"`, `"au"`, `"de"`). Drives region-specific catalog
    /// queries. Returns nil on fork builds and when the user hasn't
    /// authorised.
    func currentStorefront() async -> String?

    /// Cross-type catalog search — tracks, albums, artists. `limit`
    /// applies to each section independently. Returns
    /// `AppleMusicSearchResults.empty` when the provider is not
    /// operational or the query is empty — never throws to the UI.
    func search(query: String, limit: Int) async -> AppleMusicSearchResults

    /// Top charts + featured playlists for the user's current
    /// storefront. Returns `AppleMusicBrowse.empty` when not operational.
    func topCharts(limit: Int) async -> AppleMusicBrowse

    /// Catalog genre list for the current storefront. Used to drive
    /// genre drill-down menus. Returns empty when not operational.
    func genres() async -> [AppleMusicGenre]

    /// Charts scoped to a specific genre ID (from `genres()`).
    func charts(forGenreID genreID: String, limit: Int) async -> AppleMusicBrowse

    /// Enrichment lookup — best-match song for a (title, artist) pair
    /// from the catalog. Used to backfill artwork, genre tags, release
    /// date, and ISRC into the now-playing UI from non-Apple sources
    /// (Sonos/SMAPI, line-in, TuneIn). Returns nil when not operational
    /// or no match found.
    func lookupSong(title: String, artist: String) async -> AppleMusicSongDetails?

    /// Enrichment lookup — best-match artist for a name string.
    func lookupArtist(name: String) async -> AppleMusicArtistDetails?

    /// Enrichment lookup — best-match album for an (artist, title) pair.
    /// Used by `AlbumArtSearchService` to source album artwork from
    /// Apple Music in preference to iTunes Search when the user is
    /// authenticated.
    func lookupAlbum(artist: String, title: String) async -> AppleMusicAlbum?

    /// Resolves a library-scoped track id (`i.<uuid>` / `l.<uuid>`) to
    /// the catalog id Sonos's SMAPI service can play. Returns nil when
    /// the track has no catalog equivalent (typically user uploads).
    /// Caller passes the current track metadata so the resolver can
    /// fall back to a title-+-artist catalog search.
    func resolveCatalogID(forLibraryTrack track: AppleMusicTrack) async -> String?

    /// Looks up the album catalog id for a given song catalog id.
    /// Returns nil when the song has no resolvable album (rare —
    /// usually single-release tracks fold into a single-song album).
    /// Used by the playback helper to populate `parentID` in the
    /// queue DIDL — Sonos's Apple Music SMAPI rejects placeholder
    /// `0004206calbum%3a0` parents with a silent no-play.
    func lookupAlbumID(forSongCatalogID catalogID: String) async -> String?

    /// Rich album enrichment — pulls editorial notes, record label,
    /// audio variants, copyright, etc. for the About-panel display.
    func lookupAlbumDetails(artist: String, title: String) async -> AppleMusicAlbumDetails?

    // MARK: - User library (signed-in account's saved content)

    func librarySongs(limit: Int) async -> [AppleMusicTrack]
    func libraryAlbums(limit: Int) async -> [AppleMusicAlbum]
    func libraryArtists(limit: Int) async -> [AppleMusicArtist]
    func libraryPlaylists(limit: Int) async -> [AppleMusicPlaylist]

    // MARK: - Personalised / recent

    /// User's recently played albums + playlists.
    func recentlyPlayed(limit: Int) async -> AppleMusicRecentlyPlayed

    /// Apple's "Listen Now" recommendations for the signed-in account.
    func recommendations() async -> [AppleMusicRecommendation]

    // MARK: - Drilldowns

    /// Tracks on an album. Used by the album detail view.
    func albumTracks(albumID: String) async -> [AppleMusicTrack]

    /// Tracks on a playlist. Used by the playlist detail view.
    func playlistTracks(playlistID: String) async -> [AppleMusicTrack]

    /// Albums attributed to an artist (full albums, not singles).
    func artistAlbums(artistID: String) async -> [AppleMusicAlbum]

    /// Artist's top songs in the catalog.
    func artistTopSongs(artistID: String, limit: Int) async -> [AppleMusicTrack]

    /// Catalog radio-station search. Returns Apple Music stations
    /// matching the query — useful for genre / mood / artist station
    /// lookups when no curated browse hub is available.
    func searchStations(query: String, limit: Int) async -> [AppleMusicStation]

    /// User-personalised stations — saved or algorithmically generated
    /// for the signed-in account (e.g. "Personal Mix", "Discovery
    /// Station", "Heavy Rotation Mix"). Sourced from the user's library.
    func userStations(limit: Int) async -> [AppleMusicStation]

    /// Top albums filtered to those available in Dolby Atmos / Spatial
    /// Audio. Approximation — MusicKit doesn't expose Apple's curated
    /// "Now in Spatial Audio" list, so we filter the top-charts feed
    /// by `audioVariants`.
    func spatialAudioAlbums(limit: Int) async -> [AppleMusicAlbum]
}

/// Default implementation used by every build profile that does NOT
/// have MusicKit compiled in (OSS forks). Returns the not-applicable
/// authorisation state and refuses catalog requests, so the UI falls
/// through to the legacy SMAPI Apple Music browse path.
public final class DisabledAppleMusicProvider: AppleMusicProvider, @unchecked Sendable {
    public init() {}
    public var authorisation: AppleMusicAuthorisation { get async { .notApplicable } }
    public func requestAuthorisation() async -> AppleMusicAuthorisation { .notApplicable }
    public var isOperational: Bool { get async { false } }
    public func currentStorefront() async -> String? { nil }
    public func search(query: String, limit: Int) async -> AppleMusicSearchResults { .empty }
    public func topCharts(limit: Int) async -> AppleMusicBrowse { .empty }
    public func genres() async -> [AppleMusicGenre] { [] }
    public func charts(forGenreID genreID: String, limit: Int) async -> AppleMusicBrowse { .empty }
    public func lookupSong(title: String, artist: String) async -> AppleMusicSongDetails? { nil }
    public func lookupArtist(name: String) async -> AppleMusicArtistDetails? { nil }
    public func lookupAlbum(artist: String, title: String) async -> AppleMusicAlbum? { nil }
    public func resolveCatalogID(forLibraryTrack track: AppleMusicTrack) async -> String? { nil }
    public func lookupAlbumID(forSongCatalogID catalogID: String) async -> String? { nil }
    public func lookupAlbumDetails(artist: String, title: String) async -> AppleMusicAlbumDetails? { nil }
    public func librarySongs(limit: Int) async -> [AppleMusicTrack] { [] }
    public func libraryAlbums(limit: Int) async -> [AppleMusicAlbum] { [] }
    public func libraryArtists(limit: Int) async -> [AppleMusicArtist] { [] }
    public func libraryPlaylists(limit: Int) async -> [AppleMusicPlaylist] { [] }
    public func recentlyPlayed(limit: Int) async -> AppleMusicRecentlyPlayed { .empty }
    public func recommendations() async -> [AppleMusicRecommendation] { [] }
    public func albumTracks(albumID: String) async -> [AppleMusicTrack] { [] }
    public func playlistTracks(playlistID: String) async -> [AppleMusicTrack] { [] }
    public func artistAlbums(artistID: String) async -> [AppleMusicAlbum] { [] }
    public func artistTopSongs(artistID: String, limit: Int) async -> [AppleMusicTrack] { [] }
    public func searchStations(query: String, limit: Int) async -> [AppleMusicStation] { [] }
    public func userStations(limit: Int) async -> [AppleMusicStation] { [] }
    public func spatialAudioAlbums(limit: Int) async -> [AppleMusicAlbum] { [] }
}

/// Live provider selection. Always returns a usable instance — a
/// `DisabledAppleMusicProvider` on profiles without MusicKit, the
/// native MusicKit-backed provider on profiles with `ENABLE_MUSICKIT`.
public enum AppleMusicProviderFactory {
    public static func makeCurrent() -> AppleMusicProvider {
        #if ENABLE_MUSICKIT && canImport(MusicKit)
        return MusicKitAppleMusicProvider()
        #else
        return DisabledAppleMusicProvider()
        #endif
    }

    /// True when the running build can ever render the new MusicKit-
    /// backed Apple Music UI. Views use this to decide whether to
    /// hide the legacy SMAPI sections in addition to showing the
    /// MusicKit ones. Independent of runtime auth — a build that
    /// shipped with MusicKit support stays UI-eligible even when the
    /// user has declined the permission prompt (the UI then shows an
    /// authorisation CTA in place of the sections).
    public static var hasMusicKitSupport: Bool {
        #if ENABLE_MUSICKIT && canImport(MusicKit)
        return true
        #else
        return false
        #endif
    }

    /// True when the legacy SMAPI-based Apple Music browse / search
    /// surfaces should remain visible. On by default for fork and dev
    /// builds; turned off in the signed release where the MusicKit UI
    /// is the only Apple Music surface.
    public static var showLegacyAppleMusic: Bool {
        #if SHOW_LEGACY_APPLE_MUSIC
        return true
        #else
        // Legacy stays on whenever MusicKit isn't compiled — without
        // it there is no replacement UI and hiding the SMAPI path
        // would leave the user with no Apple Music at all.
        return !hasMusicKitSupport
        #endif
    }
}
