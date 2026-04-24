/// ScrobbleService.swift — Protocol for "tracks played" sinks.
///
/// Abstracts over Last.fm, ListenBrainz, Libre.fm, Maloja — anything that
/// accepts a time-stamped artist/title/album tuple as a "listen". New
/// providers drop in as additional types conforming to this protocol;
/// `ScrobbleManager` enumerates all registered services and orchestrates
/// batch submission without knowing which one is which.
///
/// Each implementation owns its own connection/auth state (API keys,
/// session tokens, username). Auth flow is service-specific and happens
/// inside `connect()`.
import Foundation

/// Per-entry outcome of a scrobble batch submission.
public enum ScrobbleResult: Equatable {
    /// Service accepted the scrobble.
    case accepted(historyID: UUID)

    /// Service declined non-retryably — timestamp out of window, duplicate,
    /// malformed metadata, etc. Record so we don't resubmit.
    case ignored(historyID: UUID, reason: String)

    /// Transient failure (network, 5xx, rate limit). Safe to retry later
    /// subject to the repository's retry-count cap.
    case failed(historyID: UUID, error: String)

    public var historyID: UUID {
        switch self {
        case .accepted(let id): return id
        case .ignored(let id, _): return id
        case .failed(let id, _): return id
        }
    }
}

/// Generic "tracks played" sink. Implementations must be `@MainActor` —
/// they hold Published state for the Settings UI.
@MainActor
public protocol ScrobbleService: AnyObject {
    /// Short, stable identifier. Used as the `service` column in the
    /// `scrobble_log` table, and as a UserDefaults suffix. Lowercase, no
    /// spaces. Examples: "lastfm", "listenbrainz", "librefm", "maloja".
    var serviceID: String { get }

    /// User-facing name shown in Settings.
    var displayName: String { get }

    /// True when the service is fully set up and ready to accept scrobbles
    /// (credentials configured + auth token present + not expired).
    var isConnected: Bool { get }

    /// Username on the remote service, displayed in Settings once connected.
    var connectedUsername: String? { get }

    /// Runs the service-specific authentication flow. Throws on failure.
    /// Typically opens a browser for OAuth/token approval.
    func connect() async throws

    /// Clears stored session credentials. Keeps any service-specific config
    /// (like BYO API keys) in place so reconnect is one click.
    func disconnect()

    /// Submits a batch of history entries. Returns a per-entry `ScrobbleResult`
    /// so partial-success is possible — one bad timestamp shouldn't block the
    /// rest of the batch.
    ///
    /// Implementations should honour the service's batch-size cap internally
    /// (Last.fm: 50 tracks per call). Caller (ScrobbleManager) passes however
    /// many pass eligibility; implementation chunks as needed.
    func scrobble(_ entries: [PlayHistoryEntry]) async throws -> [ScrobbleResult]
}
