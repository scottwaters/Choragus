/// SonosConstants.swift — Centralized constants for URI patterns, service IDs, and timing.
import Foundation
import SwiftUI

// MARK: - URI Prefixes

public enum URIPrefix {
    // Local library
    public static let fileCifs = "x-file-cifs://"
    public static let smb = "x-smb://"

    // Radio / streaming
    public static let sonosApiStream = "x-sonosapi-stream:"
    public static let sonosApiRadio = "x-sonosapi-radio:"
    public static let sonosApiHLS = "x-sonosapi-hls:"
    public static let sonosApiHLSStatic = "x-sonosapi-hls-static:"
    public static let rinconMP3Radio = "x-rincon-mp3radio:"
    public static let sonosHTTP = "x-sonos-http:"

    // Containers / queue / grouping
    public static let rinconContainer = "x-rincon-cpcontainer:"
    public static let rinconPlaylist = "x-rincon-playlist:"
    public static let rinconQueue = "x-rincon-queue:"
    public static let rincon = "x-rincon:"

    /// True if this URI is from a local network music library
    public static func isLocal(_ uri: String) -> Bool {
        uri.hasPrefix(fileCifs) || uri.hasPrefix(smb)
    }

    /// True if this URI is a radio/internet stream
    public static func isRadio(_ uri: String) -> Bool {
        uri.hasPrefix(sonosApiStream) || uri.hasPrefix(sonosApiRadio) || uri.hasPrefix(rinconMP3Radio) ||
        uri.hasPrefix(sonosApiHLS) || uri.hasPrefix(sonosApiHLSStatic)
    }
}

// MARK: - Known Service IDs

public enum ServiceID {
    public static let deezer = 2
    /// Pandora SMAPI sid per SoCo's public Music Service IDs wiki. Distinct
    /// from the RINCON service-type number `519` used for URI parsing in
    /// `RINCONService.knownNames` below — Sonos uses different IDs at the
    /// SMAPI catalog layer vs the URI layer for the same service.
    public static let pandora = 3
    public static let iHeartRadio = 6
    public static let spotify = 12
    public static let qobuz = 31
    public static let calmRadio = 144
    public static let soundCloud = 160
    public static let tidal = 174
    public static let amazonMusic = 201
    public static let appleMusic = 204
    public static let plex = 212
    public static let audible = 239
    public static let tuneIn = 254
    public static let youTubeMusic = 284
    public static let sonosRadio = 303
    public static let tuneInNew = 333
    /// SiriusXM — published Sonos SMAPI sid in the standard service
    /// catalogue. Like Amazon Music and YouTube Music, third-party
    /// AppLink auth fails: the SMAPI endpoint returns no authorization
    /// URL (Sonos's identity gate refuses non-Sonos clients).
    public static let siriusXM = 37

    /// Fallback map for when the speaker's service list hasn't loaded
    public static let knownNames: [Int: String] = [
        deezer: "Deezer",
        pandora: "Pandora",
        iHeartRadio: "iHeartRadio",
        spotify: "Spotify",
        qobuz: "Qobuz",
        calmRadio: "Calm Radio",
        soundCloud: "SoundCloud",
        tidal: "TIDAL",
        amazonMusic: "Amazon Music",
        appleMusic: "Apple Music",
        plex: "Plex",
        audible: "Audible",
        tuneIn: "TuneIn",
        youTubeMusic: "YouTube Music",
        sonosRadio: "Sonos Radio",
        tuneInNew: "TuneIn",
        siriusXM: "SiriusXM",
    ]
}

// MARK: - Service Name Constants

public enum ServiceName {
    public static let spotify = "Spotify"
    public static let appleMusic = "Apple Music"
    public static let amazonMusic = "Amazon Music"
    public static let deezer = "Deezer"
    public static let tidal = "TIDAL"
    public static let soundCloud = "SoundCloud"
    public static let youTubeMusic = "YouTube Music"
    public static let pandora = "Pandora"
    public static let calmRadio = "Calm Radio"
    public static let tuneIn = "TuneIn"
    public static let radio = "Radio"
    public static let musicLibrary = "Music Library"
    public static let localLibrary = "Local Library"
    public static let streaming = "Streaming"
    public static let unavailable = "Unavailable"
    public static let unknown = "Unknown"
    public static let sonosPlaylist = "Sonos Playlist"
    public static let sonosRadio = "Sonos Radio"
    public static let radioParadise = "Radio Paradise"
    public static let siriusXM = "SiriusXM"
    public static let local = "Local"
}

// MARK: - SA_RINCON Mappings

public enum RINCONService {
    public static let knownNames: [Int: String] = [
        2311: "Spotify",
        3079: "TuneIn",
        519: "Pandora",
        36871: "Calm Radio",
        52231: "Apple Music",
        65031: "Amazon Music",
    ]
}

// MARK: - Service Badge Colors

public enum ServiceColor {
    public static func color(for service: String) -> Color {
        switch service {
        case ServiceName.musicLibrary, ServiceName.localLibrary, ServiceName.local: return .green.opacity(0.7)
        case ServiceName.radio: return .orange.opacity(0.7)
        case ServiceName.sonosRadio: return .orange.opacity(0.8)
        case ServiceName.tuneIn, "TuneIn (New)": return .orange.opacity(0.6)
        case ServiceName.calmRadio: return .teal.opacity(0.7)
        case ServiceName.sonosPlaylist: return .purple.opacity(0.7)
        case "TV", "Line-In": return .gray.opacity(0.7)
        case ServiceName.unavailable: return .red.opacity(0.5)
        default: return .blue.opacity(0.7)
        }
    }
}

// MARK: - Sonos Protocol

public enum SonosProtocol {
    public static let defaultPort = 1400
}

// MARK: - Timing Constants

public enum Timing {
    public static let defaultGracePeriod: TimeInterval = 5
    public static let playbackGracePeriod: TimeInterval = 10
    public static let soapRequestTimeout: TimeInterval = 10
    public static let soapResourceTimeout: TimeInterval = 15
    public static let artSearchTimeout: TimeInterval = 5
    public static let positionFreezeAfterSeek: TimeInterval = 3
    public static let progressTimerInterval: TimeInterval = 1.0
    public static let discoveryRescanInterval: TimeInterval = 30
    public static let artCacheDebounceSec: UInt64 = 2_000_000_000
    public static let subscriptionRenewalFraction: Double = 0.8
    public static let presetStepDelay: UInt64 = 500_000_000
    public static let reloadDebounce: UInt64 = 500_000_000
    public static let smapiAuthPollInterval: UInt64 = 5_000_000_000
    public static let errorAutoDismiss: UInt64 = 5_000_000_000
    public static let rescanDebounce: UInt64 = 2_000_000_000
    public static let toastDismiss: TimeInterval = 2
    public static let statusMessageDismiss: TimeInterval = 3
    public static let subscriptionRenewalCheck: TimeInterval = 60
    public static let reconciliationPolling: TimeInterval = 15
    public static let legacyPolling: TimeInterval = 5
    public static let metadataPolling: UInt64 = 5_000_000_000
    public static let musicServicesRetryDelay: TimeInterval = 3
    public static let groupRefreshDelay: TimeInterval = 1
    public static let searchDebounce: UInt64 = 300_000_000
    public static let marqueeAnimationPause: UInt64 = 500_000_000

    // MARK: Scrobbling (added v3.6)
    /// Auto-scrobble timer cadence (seconds). Runs the pending queue
    /// periodically without user action when the toggle is on.
    public static let autoScrobbleInterval: TimeInterval = 300
    /// Poll cadence while waiting for the user to approve Last.fm auth
    /// in their browser.
    public static let lastFMAuthPollInterval: UInt64 = 2_000_000_000
    /// How long we'll keep polling after opening the browser before
    /// giving up on `auth.getSession`.
    public static let lastFMAuthTimeout: TimeInterval = 90
    /// Debounce between scroll-wheel deltas and the SOAP volume commit —
    /// lets a rapid flick coalesce to one write instead of 10+.
    public static let scrollVolumeCommitDelay: UInt64 = 300_000_000
}

// MARK: - UserDefaults Keys

public enum UDKey {
    public static let startupMode = "startupMode"
    public static let communicationMode = "communicationMode"
    public static let discoveryMode = "discoveryMode"
    public static let appearanceMode = "appearanceMode"
    /// Independent appearance preference for the karaoke popout
    /// window. Defaults to `.dark` because the karaoke window is an
    /// immersive media surface (often AirPlayed to a TV / viewed from
    /// across the room) and reads better with high contrast against a
    /// dark backdrop regardless of the rest of the app's theme.
    public static let karaokeAppearanceMode = "karaokeAppearanceMode"
    public static let appLanguage = "appLanguage"
    public static let lastSelectedGroupID = "lastSelectedGroupID"
    public static let menuBarEnabled = "menuBarEnabled"
    /// Opt-in for Sparkle's beta channel. When true, the
    /// `SparkleUpdaterDelegate` returns `["beta"]` from
    /// `allowedChannels(for:)`, exposing beta-tagged appcast items
    /// alongside production. Default off — beta channel is
    /// "may-break-things" by design.
    public static let sparkleBetaChannelEnabled = "sparkle.betaChannelEnabled"
    public static let playHistoryEnabled = "playHistoryEnabled"
    public static let playHistoryEnabledSet = "playHistoryEnabledSet"
    public static let smapiEnabled = "smapiEnabled"
    /// When true (default) AND direct Plex is authenticated, the Plex
    /// sidebar entry routes to PlexDirectBrowseView instead of the SMAPI
    /// relay. Toggle exposed in MusicServicesView when both auths exist.
    public static let plexPreferDirect = "plex.preferDirect"
    /// Mouse-wheel volume control over the Now Playing area.
    public static let scrollVolumeEnabled = "scrollVolumeEnabled"
    /// Middle-click mute toggle over the Now Playing area.
    public static let middleClickMuteEnabled = "middleClickMuteEnabled"
    public static let imageCacheMaxSizeMB = "imageCacheMaxSizeMB"
    public static let imageCacheMaxAgeDays = "imageCacheMaxAgeDays"
    public static let classicShuffleEnabled = "classicShuffleEnabled"
    public static let chartTheme = "chartTheme"
    public static let customPrimaryColor = "customPrimary"
    public static let customSecondaryColor = "customSecondary"
    public static let customAccentColor = "customAccent"
    public static let proportionalGroupVolume = "proportionalGroupVolume"
    public static let artOverridePrefix = "artOverride:"
    public static let tuneInSearchEnabled = "tuneInSearchEnabled"
    public static let calmRadioEnabled = "calmRadioEnabled"
    public static let appleMusicSearchEnabled = "appleMusicSearchEnabled"
    public static let sonosRadioEnabled = "sonosRadioEnabled"
    public static let ignoreTV = "ignoreTV"
    /// Collapses the Lyrics / About / History panel under Now Playing
    /// for users who prefer the cleaner now-playing-only layout.
    public static let contextPanelCollapsed = "contextPanelCollapsed"
    /// Hides the diagnostics (bug) toolbar icon for users who don't
    /// want it visible. Diagnostics still capture in the background.
    public static let hideDiagnosticsIcon = "hideDiagnosticsIcon"
    /// Persisted main-window panel toggles. Keep the same names users
    /// click to toggle them so the keys are readable in `defaults read`.
    public static let showBrowse = "showBrowse"
    public static let showQueue = "showQueue"
    /// User-set browse panel width (sentinel 0 = no override, use the
    /// allocator's computed default). `Double` because `@AppStorage`
    /// can't represent `Optional<CGFloat>` directly.
    public static let userBrowseWidth = "userBrowseWidth"
    /// Global lyrics timing offset in seconds. Applied on top of the
    /// per-track manual offset (the `±` toolbar in the lyrics panel).
    /// Default `-2.0` empirically — Sonos position polling typically
    /// runs ~1–2 s behind true playback head, and LRC databases (LRCLIB)
    /// are tuned for tracks-as-sung rather than as-streamed, so a
    /// negative baseline pulls lyrics into perceived sync without
    /// per-track tweaking.
    public static let lyricsGlobalOffset = "lyricsGlobalOffset"

    // MARK: - Scrobbling (added v3.6)
    /// Per-service enable toggle. Pattern: `scrobbling.<serviceID>.enabled`.
    /// Example: `scrobbling.lastfm.enabled`.
    public static func scrobblingEnabled(for serviceID: String) -> String {
        "scrobbling.\(serviceID).enabled"
    }
    /// Comma-separated list of rooms (group-name substrings) the user wants
    /// to scrobble. Empty = scrobble all rooms.
    public static let scrobblingEnabledRooms = "scrobbling.enabledRooms"
    /// Comma-separated list of music-service sources to scrobble (e.g.
    /// "Sonos Radio,TuneIn,Local Library"). Empty = scrobble all.
    public static let scrobblingEnabledMusicServices = "scrobbling.enabledMusicServices"
    /// Auto-scrobble timer (5-min cadence) on/off. Default off.
    public static let scrobblingAutoScrobble = "scrobbling.autoScrobble"
    public static let realtimeStats = "realtimeStats"
    public static let rollupInterval = "rollupInterval"
    /// User-overridable cap on play-history row count. Sentinel `0`
    /// means unlimited (no pruning). Default for unset accounts is
    /// effectively unlimited via `UserDefaults.integer`'s zero
    /// fallback — users who were silently capped at the old 50k
    /// `CacheDefaults.playHistoryMaxEntries` ceiling now keep
    /// everything they have unless they explicitly opt back into a
    /// smaller cap from Settings → Music → Play History.
    public static let playHistoryMaxEntries = "playHistoryMaxEntries"

    // MARK: - Visualisations (Club Vis)
    /// Genre-match strictness for the Club Vis tile pool. Stored as a
    /// raw String matching `VisGenreMatchMode.rawValue` ("partial" |
    /// "full"). Default behaves as "partial" via the rawValue init's
    /// fallback so an unset key behaves the same as the default.
    public static let visGenreMatchMode = "vis.genreMatchMode"
    /// Percentage (0–100) of the Club Vis tile pool reserved for
    /// genre-agnostic random sprinkle. Default 5. Independent of queue
    /// / genre rule precedence — the sprinkle always fires.
    public static let visRandomSprinklePercent = "vis.randomSprinklePercent"
    /// When true (default), the Back of the Club bottom-right About
    /// panel renders the artist's bio + tags. Toggle off for users
    /// who want a cleaner art-only wall.
    public static let visShowAboutPanel = "vis.showAboutPanel"
    /// History source for the Vis wall. Stored as a raw String
    /// matching `VisHistorySource.rawValue` ("group" | "all").
    /// "group" (default) restricts the history pool to plays in the
    /// currently-selected group; "all" pools across every group.
    public static let visHistorySource = "vis.historySource"
}

/// Stored as a raw String UserDefault under `UDKey.visHistorySource`.
/// `group` (default) — wall only draws history art from plays that
/// occurred on the speakers in the currently-selected group. `all` —
/// draws across every entry in `playHistoryManager.entries`.
public enum VisHistorySource: String, CaseIterable {
    case group
    case all

    /// `.group` matches plays whose `groupName` contains ANY room
    /// currently in the active group — not the exact group-name
    /// string. So a 3-room group pulls history from all 3 rooms
    /// across every constellation they've ever played in.
    public static var defaultMode: VisHistorySource { .group }

    public static var current: VisHistorySource {
        let raw = UserDefaults.standard.string(forKey: UDKey.visHistorySource) ?? ""
        return VisHistorySource(rawValue: raw) ?? .defaultMode
    }
}

/// Stored as a raw String UserDefault under `UDKey.visGenreMatchMode`.
/// `partial` (default) does case-insensitive substring match across
/// comma-split genre tokens; `full` requires equality on the full
/// stored genre string.
public enum VisGenreMatchMode: String, CaseIterable {
    case partial
    case full

    public static var defaultMode: VisGenreMatchMode { .partial }

    public static var current: VisGenreMatchMode {
        let raw = UserDefaults.standard.string(forKey: UDKey.visGenreMatchMode) ?? ""
        return VisGenreMatchMode(rawValue: raw) ?? .defaultMode
    }
}


// MARK: - Browse Object IDs

public enum BrowseID {
    public static let favorites = "FV:2"
    public static let playlists = "SQ:"
    public static let libraryRoot = "A:"
    public static let albumArtist = "A:ALBUMARTIST"
    public static let album = "A:ALBUM"
    public static let tracks = "A:TRACKS"
    public static let shares = "S:"
    public static let smapiRoot = "root"
}

// MARK: - SMAPI BrowseItem objectID prefixes

/// Prefix stamped onto `BrowseItem.objectID` values for SMAPI-sourced
/// items and on navigation destinations (`BrowseDestination.objectID`).
/// The lowercase form is written by `ServiceSearchProvider.smapiItemToBrowseItem`;
/// the uppercase form is produced by UI navigation paths. Both need to be
/// stripped before passing an id back to SMAPI via `getMetadata`.
public enum SMAPIPrefix {
    public static let lower = "smapi:"
    public static let upper = "SMAPI:"
    public static func strip(_ objectID: String, serviceID: Int) -> String {
        objectID
            .replacingOccurrences(of: "\(lower)\(serviceID):", with: "")
            .replacingOccurrences(of: "\(upper)\(serviceID):", with: "")
    }
}

// MARK: - Pagination Defaults

public enum PageSize {
    public static let browse = 100
    public static let queue = 100
    public static let search = 50
    public static let searchArtist = 20
    public static let searchAlbum = 20
    public static let searchTrack = 30
    public static let smapiAuth = 200
}

// MARK: - Cache Defaults

public enum CacheDefaults {
    public static let imageDiskMaxSizeMB = 500
    public static let imageDiskMaxAgeDays = 30
    public static let imageMemoryCountLimit = 200
    public static let imageMemoryBytesLimit = 50 * 1024 * 1024
    public static let imageEvictionFrequency = 50
    public static let playHistoryMaxEntries = 50_000
}

// MARK: - UI Layout Constants

public enum UILayout {
    public static let nowPlayingArtSize: CGFloat = 180
    public static let horizontalPadding: CGFloat = 24
    public static let defaultSpacing: CGFloat = 12
    public static let volumeLabelWidth: CGFloat = 28
    public static let speakerNameMinWidth: CGFloat = 60
    public static let presetWindowWidth: CGFloat = 680
    public static let presetWindowHeight: CGFloat = 580
}

// MARK: - Schema Compatibility

public enum SchemaCompat {
    public static let hashSeed = "78cb4c93-13ae-454f-be17-4c7681d34d95"
}

@inline(never)
public func _resolveCompatibilityRevision() -> UInt32 {
    return 0x6708fb89
}

// MARK: - Notifications

public extension Notification.Name {
    static let queueChanged = Notification.Name("sonosQueueChanged")
}

/// Keys used on `.queueChanged` notifications.
public enum QueueChangeKey {
    /// An array of `QueueItem` the view can append directly without
    /// re-fetching the whole queue from the coordinator. If absent,
    /// subscribers should do a full reload instead. Present on single- or
    /// multi-track adds where we know the resulting track numbers; absent
    /// on container adds (server-side expansion) or when the SOAP response
    /// didn't include a usable track number.
    public static let optimisticItems = "optimisticItems"
}

// MARK: - App Support Directory

public enum AppPaths {
    /// Returns the Choragus directory in Application Support, creating it if needed.
    /// (Pre-rename builds used a `SonosController` directory at the same parent.
    /// In the sandboxed build the new bundle ID gets a fresh container, so cross-
    /// directory access doesn't apply — the old directory is in the old bundle's
    /// container and isn't visible to the renamed app.)
    public static var appSupportDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = appSupport.appendingPathComponent("Choragus", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
