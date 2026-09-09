import Foundation

public enum StaleDataError: Error, LocalizedError, Equatable {
    case deviceUnreachable(String) // room name
    case groupChanged(String) // group name
    case topologyStale
    /// Raised when the speaker rejects the URI/metadata sent to it (UPnP
    /// 714 "no such resource"). NOT a topology event: reporting it as
    /// `topologyStale` misreads a refused single-track URI as a broken
    /// group layout.
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
    /// situation instead of a rescan banner or a generic error.
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
    /// The speaker accepted an Amazon Music track into the queue and
    /// faulted UPnP 701 on Play. Observed on an Amazon Music Prime
    /// account for every track form: Prime plays albums,
    /// playlists and stations only; on-demand tracks need Unlimited.
    case serviceTierRefused

    public var errorDescription: String? {
        switch self {
        case .deviceUnreachable(let name):
            return L10n.errStaleDeviceUnreachable(name)
        case .groupChanged(let name):
            return L10n.errStaleGroupChanged(name)
        case .topologyStale:
            return L10n.errStaleTopology
        case .serviceRejected:
            return L10n.errStaleServiceRejected
        case .notPlayable:
            return L10n.errStaleNotPlayable
        case .serviceTierRefused:
            return L10n.errorAmazonTrackRefused
        case .serviceUnavailable:
            return L10n.errStaleServiceUnavailable
        case .nothingLoaded:
            return L10n.errStaleNothingLoaded
        case .tracksSkippingEarly:
            return L10n.errorTracksSkippingEarly
        case .libraryNotConfigured(let generation):
            let app = generation == .unknown
                ? L10n.errStaleLibraryAppThisSystem
                : L10n.errStaleLibraryAppNamed(generation.displayLabel)
            return L10n.errStaleLibraryNotConfigured(app)
        }
    }
}
