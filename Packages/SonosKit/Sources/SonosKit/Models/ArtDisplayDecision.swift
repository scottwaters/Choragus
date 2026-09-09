/// ArtDisplayDecision.swift — Chooses which artwork URL to display.
///
/// Candidates: the speaker's own `albumArtURI`, a user's manual override, an
/// iTunes result for a radio song, a station logo, and the art still on
/// screen from the previous track. Precedence:
///
///  1. Art the user ignored shows nothing at all.
///  2. An ad break shows the station logo, never the previous song's art.
///  3. A media server's own art for the track, unless the user pinned a
///     non-proxy URL over it.
///  4. Once a track's art is *resolved*, that answer is stable:
///     a. a user's manual pin beats radio auto-search, which re-populates on
///        every poll and would otherwise clobber the choice;
///     b. an iTunes result whose title matches the playing song;
///     c. a pin that is not a `/getaa?` proxy URL, when the speaker's own art
///        *is* one — the proxy serves a placeholder for URLs it cannot fetch;
///     d. the speaker's `albumArtURI`;
///     e. a non-`/getaa?` pin when the speaker reports no art at all — a
///        `/getaa?` pin here is usually the previous track's URL, leaked into
///        metadata during a queue advance before Sonos refreshed;
///     f. the station logo.
///  5. Unresolved, an iTunes result for the current song still wins.
///  6. During the grace window after a radio song changes, the previous
///     song's art is held rather than flashing the station logo while the
///     search is in flight.
///  7. Otherwise whatever is on screen, falling back to the station logo.
import Foundation

public enum ArtDisplayDecision {

    /// Every art candidate available at the moment of the decision.
    public struct Inputs {
        public let isIgnored: Bool
        public let isAdBreak: Bool
        public let isResolved: Bool
        public let stationName: String
        public let speakerArtURI: String?
        public let pinnedURL: URL?
        /// Art the media server itself published for this track at browse
        /// time. Authoritative when present: the track came from that server,
        /// so the server's own cover is the correct one by definition.
        public let serverPublishedArtURL: URL?
        public let radioTrackArtURL: URL?
        /// Title the radio art was resolved for, nil when it was set without
        /// one. Compared on title alone: radio metadata arrives in stages and
        /// an artist that fills in later must not invalidate correct art.
        public let radioTrackArtTitle: String?
        public let stationArtURL: URL?
        public let heldPreviousRadioArtURL: URL?
        public let radioGraceActive: Bool
        public let displayedArtURL: URL?
        public let title: String

        public init(isIgnored: Bool = false,
                    isAdBreak: Bool = false,
                    isResolved: Bool = false,
                    stationName: String = "",
                    speakerArtURI: String? = nil,
                    pinnedURL: URL? = nil,
                    serverPublishedArtURL: URL? = nil,
                    radioTrackArtURL: URL? = nil,
                    radioTrackArtTitle: String? = nil,
                    stationArtURL: URL? = nil,
                    heldPreviousRadioArtURL: URL? = nil,
                    radioGraceActive: Bool = false,
                    displayedArtURL: URL? = nil,
                    title: String = "") {
            self.isIgnored = isIgnored
            self.isAdBreak = isAdBreak
            self.isResolved = isResolved
            self.stationName = stationName
            self.speakerArtURI = speakerArtURI
            self.pinnedURL = pinnedURL
            self.serverPublishedArtURL = serverPublishedArtURL
            self.radioTrackArtURL = radioTrackArtURL
            self.radioTrackArtTitle = radioTrackArtTitle
            self.stationArtURL = stationArtURL
            self.heldPreviousRadioArtURL = heldPreviousRadioArtURL
            self.radioGraceActive = radioGraceActive
            self.displayedArtURL = displayedArtURL
            self.title = title
        }
    }

    /// Sonos proxies third-party art through this path and serves a generic
    /// placeholder when it cannot fetch the upstream URL.
    private static let proxyMarker = "/getaa?"

    public static func artURL(_ inputs: Inputs) -> URL? {
        if inputs.isIgnored { return nil }
        if inputs.isAdBreak { return inputs.stationArtURL }

        // Media-server art outranks every automatic candidate, before the
        // resolved split: Sonos reports no art for these tracks and its
        // /getaa? proxy 404s on the server's URL, so the paths below show
        // nothing. A manual pin is the user's choice and still wins.
        if let published = inputs.serverPublishedArtURL {
            if let pin = inputs.pinnedURL, !pin.absoluteString.contains(proxyMarker) { return pin }
            return published
        }

        let onRadio = !inputs.stationName.isEmpty
        let speakerArt = inputs.speakerArtURI ?? ""
        let speakerArtIsProxy = speakerArt.contains(proxyMarker)

        if inputs.isResolved {
            if onRadio, let pin = inputs.pinnedURL { return pin }
            if onRadio, let trackArt = inputs.radioTrackArtURL, radioArtMatches(inputs) {
                return trackArt
            }
            if speakerArtIsProxy, let pin = inputs.pinnedURL,
               !pin.absoluteString.contains(proxyMarker) {
                return pin
            }
            if !speakerArt.isEmpty, let url = URL(string: speakerArt) { return url }
            if let pin = inputs.pinnedURL, !pin.absoluteString.contains(proxyMarker) {
                return pin
            }
            return inputs.stationArtURL
        }

        if onRadio, let trackArt = inputs.radioTrackArtURL, radioArtMatches(inputs) {
            return trackArt
        }
        if onRadio, inputs.radioGraceActive, let held = inputs.heldPreviousRadioArtURL {
            return held
        }
        return inputs.displayedArtURL ?? inputs.stationArtURL
    }

    /// Whether the radio art on hand was resolved for the song now playing.
    /// Title-only, case-insensitive: an `artist|title` comparison rejects
    /// correct art when the artist field finalises after the search returned.
    /// No stored title means the URL was set without one, and is trusted.
    public static func radioArtMatches(_ inputs: Inputs) -> Bool {
        guard let stored = inputs.radioTrackArtTitle else { return true }
        let storedTitle = stored.split(separator: "|", maxSplits: 1,
                                       omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard !storedTitle.isEmpty, !inputs.title.isEmpty else { return false }
        return storedTitle.caseInsensitiveCompare(inputs.title) == .orderedSame
    }
}
