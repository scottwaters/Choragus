import Foundation

public enum StaleDataError: Error, LocalizedError, Equatable {
    case deviceUnreachable(String) // room name
    case groupChanged(String) // group name
    case topologyStale
    /// Raised when the speaker rejects the URI/metadata we sent (UPnP
    /// 714 "no such resource"). NOT a topology event — bundling it
    /// with `topologyStale` previously led users to think their group
    /// layout was broken when in reality the speaker simply refused
    /// the single-track URI we built (issue #42). The real fix is to
    /// route those plays through the queue path; this case exists so
    /// the user sees an actionable message in the meantime.
    case serviceRejected
    /// Raised on a direct play when the speaker can't resolve the track's
    /// source — its music service or library share isn't set up on that
    /// speaker's system (common when an S2-library track is pushed to an S1
    /// household, or a service is linked on one system but not the other).
    /// Surfaces UPnP 701 as a meaningful message instead of a topology error.
    case serviceUnavailable
    /// Play/Pause sent to a transport with no source loaded (fresh boot,
    /// cleared queue, no stream). The speaker faults UPnP 701 — the same code
    /// stale topology produces — so this case exists to report the actual
    /// situation instead of a rescan banner or a generic error (issue #72).
    case nothingLoaded

    /// Tracks skipped within seconds of starting, repeatedly. Sonos reports
    /// no fault for this: a media URL that no longer resolves simply plays
    /// nothing and the speaker advances. Common for queue entries holding a
    /// service's pre-signed URL after its token has expired.
    case tracksSkippingEarly
    /// Raised *before* the play SOAP is sent (fail-fast pre-flight) when the
    /// selected speaker's system has no music library — or no copy of the
    /// specific share — that the chosen local-library item lives on. Prevents
    /// the UPnP 701 / "speaker layout changed" path entirely and tells the user
    /// which Sonos app (S1/S2) to add the folders in. The associated value is
    /// the selected system's generation. See per-household availability design.
    case libraryNotConfigured(SonosSystemVersion)
    /// Raised before any SOAP is sent when a "track" carries a
    /// container id (playlist/album/artist) — a service error
    /// placeholder or malformed row that AddURIToQueue would reject
    /// with UPnP 800 (#77: Spotify's "Unable to access playlist"
    /// error row carried a playlist URI through the leaf path).
    case notPlayable

    public var errorDescription: String? {
        switch self {
        case .deviceUnreachable(let name):
            return "\(name) is not responding. Your network layout may have changed — refreshing now."
        case .groupChanged(let name):
            return "\(name) group has changed. Refreshing speaker list."
        case .topologyStale:
            return "Speaker layout has changed since last cached. Refreshing now."
        case .serviceRejected:
            return "Speaker rejected request. Please raise bug report."
        case .notPlayable:
            return "Service returned an unplayable item. Please raise bug report."
        case .serviceUnavailable:
            return "This track's music service or library isn't available on this speaker's system."
        case .nothingLoaded:
            return "Nothing is loaded on this speaker. Choose something to play."
        case .tracksSkippingEarly:
            return L10n.errorTracksSkippingEarly
        case .libraryNotConfigured(let generation):
            let app = generation == .unknown
                ? "the Sonos app for this system"
                : "the Sonos \(generation.displayLabel) app"
            return "This music isn't set up on the selected system. Add your music folders in \(app), then try again."
        }
    }
}
