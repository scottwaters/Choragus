/// AsyncResultGuard.swift — Decides whether a finished async result still applies.
///
/// A late result (a browse page after the user moved folder, a biography
/// after the track changed) must not overwrite the current view. Two guards:
///
/// - **Generation** — a counter bumped whenever a new load starts. Work
///   captures the value at the start and discards its result if the counter
///   has moved. For when the *request* is what changed.
/// - **Identity** — a key describing what the result is for (a track URI, a
///   folder id). For when the same subject can be re-requested and the
///   answer is still valid; also prevents refetching what is already loaded.
import Foundation

/// Monotonic counter guarding "only the newest request may publish".
public struct GenerationGuard: Equatable {
    private var current = 0

    public init() {}

    /// Starts a new request and returns the token it must present later.
    /// Any token issued before this call is now stale.
    public mutating func begin() -> Int {
        current += 1
        return current
    }

    /// True when work holding this token may still publish its result.
    ///
    /// Token 0 is never valid: it is what an uninitialised capture holds, and
    /// a fresh guard's counter is also 0, so a plain equality check would let
    /// a variable that never received a token publish.
    public func isCurrent(_ token: Int) -> Bool { token > 0 && token == current }

    /// The token most recently issued. Exposed for diagnostics.
    public var latest: Int { current }
}

/// Guards "only a result for the thing now on screen may publish", and
/// suppresses refetching something already loaded or in flight.
public struct IdentityGuard<Key: Equatable>: Equatable {
    public enum State: Equatable {
        case idle
        case loading(Key)
        case loaded(Key)
    }

    public private(set) var state: State = .idle

    public init() {}

    /// Whether a fetch for `key` should start.
    ///
    /// Refuses when the same key is already loaded or already in flight;
    /// allows when the key differs, because the subject changed underneath a
    /// fetch that is no longer wanted.
    public func shouldFetch(_ key: Key) -> Bool {
        switch state {
        case .idle: return true
        case .loading(let inFlight): return inFlight != key
        case .loaded(let held): return held != key
        }
    }

    public mutating func beginFetch(_ key: Key) {
        state = .loading(key)
    }

    /// Accepts a finished fetch only if the subject has not changed since.
    /// Returns whether the result should be published.
    public mutating func finishFetch(_ key: Key) -> Bool {
        guard case .loading(let inFlight) = state, inFlight == key else { return false }
        state = .loaded(key)
        return true
    }

    /// Whether a result for `key` may be published without also recording it.
    public func accepts(_ key: Key) -> Bool {
        switch state {
        case .idle: return false
        case .loading(let inFlight): return inFlight == key
        case .loaded(let held): return held == key
        }
    }

    /// Clears everything — the subject changed and nothing on hand applies.
    public mutating func reset() {
        state = .idle
    }
}
