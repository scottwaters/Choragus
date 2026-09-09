/// PlexPlaybackReporter.swift — Tells Plex what the speaker is playing.
///
/// Direct Plex playback hands the speaker a file URL, so the server never
/// sees a session: nothing shows as playing, play counts do not move, and
/// smart playlists that depend on them drift. Real Plex clients
/// report a `/:/timeline` every few seconds and scrobble at track end; this
/// does the same for tracks the app enqueued.
///
/// The play URL carries a part path, not the track's ratingKey, so the
/// browse layer registers `partKey → ratingKey` when it builds a playable
/// item; the registry persists so a queue that outlives the app still
/// reports.
import Foundation

@MainActor
public final class PlexPlaybackReporter {

    public static let shared = PlexPlaybackReporter()

    /// Live playhead anchor for a coordinator, injected so this type
    /// depends on a function rather than on `SonosManager`. The anchor's
    /// wall clock says whether it belongs to this track or is left over
    /// from the previous one.
    public var positionProvider: ((_ coordinatorID: String) -> PositionAnchor?)?

    private struct Session {
        let ratingKey: String
        let durationMs: Int
        let room: String
        let startedAt: Date
        var state: TransportState
        /// Furthest playhead reported for this track; the play-count
        /// test uses it, because at track end the shared anchor may
        /// already belong to the next track.
        var maxTimeMs = 0
        /// Play time accumulated across pauses, from wall clock — a
        /// second source for the threshold when the anchor lags.
        var playedWallMs = 0
        var resumedAt: Date?
    }

    private var sessions: [String: Session] = [:]          // by coordinator id
    /// Current Plex track per coordinator even when no session is open
    /// (e.g. stopped at launch), so a later Play can open one — the
    /// transport hook carries no track.
    private var currentTrack: [String: (ratingKey: String, durationMs: Int, room: String)] = [:]
    private var heartbeats: [String: Task<Void, Never>] = [:]
    /// Last send per coordinator; each new send awaits it so a fast
    /// skip cannot deliver "playing" before the prior "stopped".
    private var sendChain: [String: Task<Void, Never>] = [:]
    private static let heartbeat: Duration = .seconds(10)
    /// Fraction of the track that must have played for the end of a
    /// session to count as a play — Plex's own threshold for clients.
    private static let playedThreshold = 0.9
    /// Playhead at or below this, after the play gate was passed, means
    /// the same track started over (repeat-one, replay).
    private static let restartWindowMs = 3000

    // Registry: in memory, persisted after a short quiet period so a
    // playlist expansion registering thousands of tracks costs one write.
    private static let registryKey = "plex.direct.partRatingKeys"   // [partPath: "ratingKey\tdurationMs"]
    private static let registryCapacity = 4000
    private var registry: [String: String]?
    private var registryPersist: Task<Void, Never>?

    private let client: PlexDirectClient
    private let auth: PlexAuthManager

    init(client: PlexDirectClient = .shared, auth: PlexAuthManager = .shared) {
        self.client = client
        self.auth = auth
    }

    // MARK: Registry

    private func loadedRegistry() -> [String: String] {
        if let registry { return registry }
        let stored = (UserDefaults.standard.dictionary(forKey: Self.registryKey) as? [String: String]) ?? [:]
        registry = stored
        return stored
    }

    /// Remembers which track a part path plays, called when a Plex track
    /// becomes a playable item. Query strings (tokens) are dropped.
    public func register(partKey: String, ratingKey: String, durationMs: Int?) {
        let path = Self.partPath(partKey)
        guard !path.isEmpty, !ratingKey.isEmpty else { return }
        var store = loadedRegistry()
        let packed = "\(ratingKey)\t\(durationMs ?? 0)"
        guard store[path] != packed else { return }
        store[path] = packed
        if store.count > Self.registryCapacity {
            // Evict from the keys other than the one just written, so
            // the count lands exactly on the cap.
            for surplus in store.keys.filter({ $0 != path }).prefix(store.count - Self.registryCapacity) {
                store.removeValue(forKey: surplus)
            }
        }
        registry = store
        registryPersist?.cancel()
        registryPersist = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, let registry = self.registry else { return }
            UserDefaults.standard.set(registry, forKey: Self.registryKey)
        }
    }

    static func partPath(_ keyOrURL: String) -> String {
        let noQuery = keyOrURL.split(separator: "?", maxSplits: 1).first.map(String.init) ?? keyOrURL
        if let range = noQuery.range(of: "/library/parts/") {
            return String(noQuery[range.lowerBound...])
        }
        return noQuery.hasPrefix("/library/parts/") ? noQuery : ""
    }

    private func lookup(trackURI: String) -> (ratingKey: String, durationMs: Int)? {
        let path = Self.partPath(trackURI)
        guard !path.isEmpty, let packed = loadedRegistry()[path] else { return nil }
        let parts = packed.components(separatedBy: "\t")
        guard let ratingKey = parts.first, !ratingKey.isEmpty else { return nil }
        return (ratingKey, parts.count > 1 ? Int(parts[1]) ?? 0 : 0)
    }

    // MARK: Hooks

    /// The coordinator's current track changed. A Plex track opens a
    /// session (closing any previous one); anything else closes it. A
    /// stopped coordinator opens nothing — there is no playback to show.
    public func trackChanged(coordinatorID: String, trackURI: String?, room: String, state: TransportState) {
        let next = trackURI.flatMap(lookup(trackURI:))
        if let trackURI, trackURI.contains("/library/parts/") {
            sonosDebugLog("[PLEX] trackChanged room=\(room) state=\(state.rawValue) rk=\(next?.ratingKey ?? "unregistered") part=\(Self.partPath(trackURI))")
        }
        currentTrack[coordinatorID] = next.map { ($0.ratingKey, $0.durationMs, room) }
        if let current = sessions[coordinatorID] {
            // The same track re-announced after the play gate is a
            // replay: the session ends (and counts) and a new one opens.
            if let next, next.ratingKey == current.ratingKey, !Self.passedPlayGate(current) { return }
            end(coordinatorID: coordinatorID, session: current)
        }
        guard next != nil, state == .playing || state == .paused || state == .transitioning else { return }
        open(coordinatorID: coordinatorID, state: state)
    }

    private func open(coordinatorID: String, state: TransportState) {
        guard let track = currentTrack[coordinatorID] else { return }
        var session = Session(ratingKey: track.ratingKey, durationMs: track.durationMs,
                              room: track.room, startedAt: Date(), state: state)
        if state == .playing { session.resumedAt = session.startedAt }
        sessions[coordinatorID] = session
        sonosDebugLog("[PLEX] session start rk=\(track.ratingKey) room=\(track.room) duration=\(track.durationMs)ms state=\(state.rawValue)")
        report(coordinatorID: coordinatorID)
        startHeartbeat(coordinatorID: coordinatorID)
    }

    /// Play / pause / stop for a coordinator with an open session. Stop
    /// keeps the session (silent, no heartbeat) so Play on the same
    /// track resumes reporting; a track change is what ends it.
    public func transportChanged(coordinatorID: String, state: TransportState,
                                 trackURI: String? = nil, room: String = "") {
        guard var session = sessions[coordinatorID] else {
            // Play on a Plex track that was already current (stopped at
            // launch, or known before the metadata hook ran): no
            // metadata change will come, so open here from the track
            // the transport hook carries.
            guard state == .playing else { return }
            if currentTrack[coordinatorID] == nil, let trackURI, let found = lookup(trackURI: trackURI) {
                currentTrack[coordinatorID] = (found.ratingKey, found.durationMs, room)
            }
            open(coordinatorID: coordinatorID, state: state)
            return
        }
        guard session.state != state else { return }
        let now = Date()
        switch state {
        case .playing:
            session.state = .playing
            session.resumedAt = now
            sessions[coordinatorID] = session
            report(coordinatorID: coordinatorID)
            startHeartbeat(coordinatorID: coordinatorID)
        case .paused, .stopped, .noMedia:
            if let resumedAt = session.resumedAt {
                session.playedWallMs += Int(now.timeIntervalSince(resumedAt) * 1000)
                session.resumedAt = nil
            }
            session.state = state
            sessions[coordinatorID] = session
            report(coordinatorID: coordinatorID)
            if state != .paused { stopHeartbeat(coordinatorID: coordinatorID) }
        case .transitioning:
            break
        }
    }

    // MARK: Reporting

    private func startHeartbeat(coordinatorID: String) {
        heartbeats[coordinatorID]?.cancel()
        heartbeats[coordinatorID] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.heartbeat)
                guard !Task.isCancelled, let self, self.sessions[coordinatorID] != nil else { return }
                self.report(coordinatorID: coordinatorID)
            }
        }
    }

    private func stopHeartbeat(coordinatorID: String) {
        heartbeats[coordinatorID]?.cancel()
        heartbeats[coordinatorID] = nil
    }

    private func end(coordinatorID: String, session: Session) {
        stopHeartbeat(coordinatorID: coordinatorID)
        sessions[coordinatorID] = nil
        var final = session
        if let resumedAt = final.resumedAt {
            final.playedWallMs += Int(Date().timeIntervalSince(resumedAt) * 1000)
            final.resumedAt = nil
        }
        let timeMs = currentTimeMs(coordinatorID: coordinatorID, session: final)
        final.maxTimeMs = max(final.maxTimeMs, timeMs)
        if session.state != .stopped && session.state != .noMedia {
            send(coordinatorID: coordinatorID, session: final, state: "stopped", timeMs: timeMs)
        }
        let progressMs = max(final.maxTimeMs, min(final.playedWallMs, final.durationMs))
        let played = final.durationMs > 0
            && Double(progressMs) >= Double(final.durationMs) * Self.playedThreshold
        sonosDebugLog("[PLEX] session end rk=\(final.ratingKey) room=\(final.room) progress=\(progressMs)/\(final.durationMs)ms played=\(played)")
        if played { scrobble(coordinatorID: coordinatorID, session: final) }
    }

    private static func passedPlayGate(_ session: Session) -> Bool {
        session.durationMs > 0
            && Double(session.maxTimeMs) >= Double(session.durationMs) * playedThreshold
    }

    private func report(coordinatorID: String) {
        guard var session = sessions[coordinatorID] else { return }
        let timeMs = currentTimeMs(coordinatorID: coordinatorID, session: session)
        // A playhead back near zero after the gate was passed is the same
        // track starting over; the wall-clock fallback only grows, so
        // this fires from the anchor alone.
        if Self.passedPlayGate(session), timeMs <= Self.restartWindowMs {
            end(coordinatorID: coordinatorID, session: session)
            open(coordinatorID: coordinatorID, state: session.state)
            return
        }
        session.maxTimeMs = max(session.maxTimeMs, timeMs)
        sessions[coordinatorID] = session
        let state: String
        switch session.state {
        case .playing: state = "playing"
        case .paused: state = "paused"
        case .transitioning: state = "buffering"
        case .stopped, .noMedia: state = "stopped"
        }
        send(coordinatorID: coordinatorID, session: session, state: state, timeMs: timeMs)
    }

    /// The playhead to report. An anchor set before this session began
    /// is the previous track's frozen position — a fresh track that
    /// starts from stopped can carry it for a few seconds — so the
    /// wall clock since the session started is used until a newer
    /// anchor lands.
    private func currentTimeMs(coordinatorID: String, session: Session) -> Int {
        let now = Date()
        let seconds: TimeInterval
        if let anchor = positionProvider?(coordinatorID), anchor.wallClock >= session.startedAt {
            seconds = anchor.projected(at: now)
        } else {
            let running = session.resumedAt.map { now.timeIntervalSince($0) } ?? 0
            seconds = Double(session.playedWallMs) / 1000 + running
        }
        let ms = Int(max(0, seconds) * 1000)
        return session.durationMs > 0 ? min(ms, session.durationMs) : ms
    }

    private func send(coordinatorID: String, session: Session, state: String, timeMs: Int) {
        guard auth.isAuthenticated else { return }
        let previous = sendChain[coordinatorID]
        sendChain[coordinatorID] = Task { [client, auth] in
            await previous?.value
            do {
                try await auth.withRetry { base, token in
                    try await client.timeline(baseURI: base, authToken: token,
                                              ratingKey: session.ratingKey, state: state,
                                              timeMs: timeMs, durationMs: session.durationMs,
                                              deviceName: session.room)
                }
            } catch {
                sonosDebugLog("[PLEX] timeline \(state) rk=\(session.ratingKey) failed: \(String(describing: error).prefix(200))")
            }
        }
    }

    /// Counts the play on the server, queued behind the final timeline.
    private func scrobble(coordinatorID: String, session: Session) {
        guard auth.isAuthenticated else { return }
        let previous = sendChain[coordinatorID]
        sendChain[coordinatorID] = Task { [client, auth] in
            await previous?.value
            do {
                try await auth.withRetry { base, token in
                    try await client.scrobble(baseURI: base, authToken: token, ratingKey: session.ratingKey)
                }
            } catch {
                sonosDebugLog("[PLEX] scrobble rk=\(session.ratingKey) failed: \(String(describing: error).prefix(200))")
            }
        }
    }
}
