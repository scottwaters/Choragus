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
        uri.hasPrefix(sonosApiStream) || uri.hasPrefix(sonosApiRadio) || uri.hasPrefix(rinconMP3Radio)
    }
}

// MARK: - Known Service IDs

public enum ServiceID {
    public static let deezer = 2
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

    /// Fallback map for when the speaker's service list hasn't loaded
    public static let knownNames: [Int: String] = [
        deezer: "Deezer",
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
    public static let progressTimerInterval: TimeInterval = 0.5
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
}

// MARK: - UserDefaults Keys

public enum UDKey {
    public static let startupMode = "startupMode"
    public static let communicationMode = "communicationMode"
    public static let appearanceMode = "appearanceMode"
    public static let appLanguage = "appLanguage"
    public static let lastSelectedGroupID = "lastSelectedGroupID"
    public static let menuBarEnabled = "menuBarEnabled"
    public static let playHistoryEnabled = "playHistoryEnabled"
    public static let playHistoryEnabledSet = "playHistoryEnabledSet"
    public static let smapiEnabled = "smapiEnabled"
    public static let imageCacheMaxSizeMB = "imageCacheMaxSizeMB"
    public static let imageCacheMaxAgeDays = "imageCacheMaxAgeDays"
    public static let classicShuffleEnabled = "classicShuffleEnabled"
    public static let chartTheme = "chartTheme"
    public static let customPrimaryColor = "customPrimary"
    public static let customSecondaryColor = "customSecondary"
    public static let customAccentColor = "customAccent"
    public static let artOverridePrefix = "artOverride:"
}


// MARK: - Notifications

public extension Notification.Name {
    static let queueChanged = Notification.Name("sonosQueueChanged")
}

// MARK: - App Support Directory

public enum AppPaths {
    /// Returns the SonosController directory in Application Support, creating it if needed
    public static var appSupportDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = appSupport.appendingPathComponent("SonosController", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
