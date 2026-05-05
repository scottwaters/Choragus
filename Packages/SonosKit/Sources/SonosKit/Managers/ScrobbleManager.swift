/// ScrobbleManager.swift — Orchestrates scrobbling across services.
///
/// Responsibilities:
/// - Holds the list of registered `ScrobbleService` implementations.
/// - Applies user-configured filters (rooms, music services) to candidate
///   entries before submission.
/// - Applies Last.fm-style universal eligibility rules (duration ≥ 30 s,
///   timestamp within 14 days, non-empty artist + title).
/// - Runs the batch — asks each enabled service to scrobble what matches,
///   writes the per-entry results into `scrobble_log` via the repository.
/// - Optional 5-minute auto-scrobble timer (default off).
///
/// Does NOT know how any individual service authenticates or submits —
/// that's behind the `ScrobbleService` protocol.
import Foundation
import Combine

@MainActor
public final class ScrobbleManager: ObservableObject {
    private let repository: PlayHistoryRepository
    private let defaults: UserDefaults

    public let services: [any ScrobbleService]

    @Published public private(set) var isScrobbling: Bool = false
    @Published public private(set) var lastRunError: String?

    private var autoScrobbleTimer: Timer?

    /// Minimum track duration to be eligible. Last.fm explicitly requires ≥ 30 s.
    public static let minDurationSeconds: TimeInterval = 30
    /// Maximum scrobble age. Last.fm's documented acceptance window.
    public static let maxAgeSeconds: TimeInterval = 14 * 24 * 3600

    public init(repository: PlayHistoryRepository,
                services: [any ScrobbleService],
                defaults: UserDefaults = .standard) {
        self.repository = repository
        self.services = services
        self.defaults = defaults
        startAutoScrobbleTimerIfEnabled()
    }

    // MARK: - Public API

    /// Enumerates all enabled services and scrobbles everything eligible.
    /// Runs sequentially per service to avoid overloading Last.fm rate
    /// limits — parallelism not needed for human-scale history volumes.
    public func scrobblePending() async {
        guard !isScrobbling else { return }
        isScrobbling = true
        lastRunError = nil
        defer { isScrobbling = false }

        for service in services where isServiceEnabled(service) && service.isConnected {
            await runOne(service: service)
        }
    }

    /// Pending count for the given service — fast COUNT(*) query,
    /// ignores business-level filters (display-only approximation).
    public func pendingCount(for service: any ScrobbleService) -> Int {
        repository.pendingScrobbleCount(service: service.serviceID)
    }

    /// Stat tuple for a service's Settings row.
    public func stats(for service: any ScrobbleService) -> (sent: Int, ignored: Int, failed: Int) {
        repository.scrobbleStats(service: service.serviceID)
    }

    /// Recent non-sent rows for the Settings "why didn't these go?" disclosure.
    public func recentNonSent(
        for service: any ScrobbleService,
        limit: Int = 50
    ) -> [PlayHistoryRepository.ScrobbleDiagnosticRow] {
        repository.recentNonSentScrobbles(service: service.serviceID, limit: limit)
    }

    /// Clears all `ignoredByService` rows for a service so the entries are
    /// re-evaluated on the next run. Used when filter settings change and
    /// old filter-based rejections (from pre-substring-match behavior) are
    /// still in the log.
    @discardableResult
    public func resetIgnored(for service: any ScrobbleService) -> Int {
        let count = repository.resetIgnoredScrobbles(service: service.serviceID)
        objectWillChange.send()
        return count
    }

    /// Breakdown of what would happen if the user clicked "Scrobble Pending
    /// Now" right now. The background: filter-driven rejections (`.filteredOut`)
    /// are intentionally NOT written to `scrobble_log` so they stay pending
    /// and re-qualify when filters change — but that means the user has no
    /// way to see *why* their pending count won't shrink without us
    /// explicitly telling them. This structure provides that visibility.
    public struct PendingPreview {
        /// Total pending rows examined (capped at `candidateLimit`).
        public let examined: Int
        /// Would submit on the next run.
        public let eligible: Int
        /// Filtered out by the selected rooms.
        public let filteredByRoom: Int
        /// Filtered out by the selected music services.
        public let filteredByMusicService: Int
        /// Structurally ineligible (will become `ignored`, not stay pending).
        public let permanentlyIneligible: Int
        /// Up to a handful of real rows per bucket so the Settings UI can
        /// show concrete examples — typically one group_name or sourceURI
        /// is enough to spot the matching bug.
        public let sampleFilteredByRoom: [PlayHistoryEntry]
        public let sampleFilteredByMusicService: [PlayHistoryEntry]
    }

    /// Classifies up to `candidateLimit` oldest pending rows against the
    /// current filters without submitting anything. Cheap: it's an in-memory
    /// classify loop with no network.
    public func previewPending(
        for service: any ScrobbleService,
        candidateLimit: Int = 500,
        sampleLimit: Int = 5
    ) -> PendingPreview {
        let sid = service.serviceID
        let rooms = loadSet(UDKey.scrobblingEnabledRooms)
        let musicServices = loadSet(UDKey.scrobblingEnabledMusicServices)
        let now = Date()

        let candidates = repository.unscrobbledEntries(service: sid, maxRetries: 3, limit: candidateLimit)

        var eligible = 0
        var filteredByRoom = 0
        var filteredByMusicService = 0
        var permanent = 0
        var sampleRoom: [PlayHistoryEntry] = []
        var sampleService: [PlayHistoryEntry] = []

        for entry in candidates {
            switch Self.classify(entry, enabledRooms: rooms,
                                 enabledMusicServices: musicServices, now: now) {
            case .eligible:
                eligible += 1
            case .permanentlyIneligible:
                permanent += 1
            case .filteredOut(let reason):
                if reason.contains("room") {
                    filteredByRoom += 1
                    if sampleRoom.count < sampleLimit { sampleRoom.append(entry) }
                } else {
                    filteredByMusicService += 1
                    if sampleService.count < sampleLimit { sampleService.append(entry) }
                }
            }
        }

        return PendingPreview(
            examined: candidates.count,
            eligible: eligible,
            filteredByRoom: filteredByRoom,
            filteredByMusicService: filteredByMusicService,
            permanentlyIneligible: permanent,
            sampleFilteredByRoom: sampleRoom,
            sampleFilteredByMusicService: sampleService
        )
    }

    // MARK: - Enable state (UserDefaults)

    public func isServiceEnabled(_ service: any ScrobbleService) -> Bool {
        defaults.bool(forKey: UDKey.scrobblingEnabled(for: service.serviceID))
    }

    public func setServiceEnabled(_ service: any ScrobbleService, _ enabled: Bool) {
        defaults.set(enabled, forKey: UDKey.scrobblingEnabled(for: service.serviceID))
        objectWillChange.send()
    }

    public var autoScrobbleEnabled: Bool {
        get { defaults.bool(forKey: UDKey.scrobblingAutoScrobble) }
        set {
            defaults.set(newValue, forKey: UDKey.scrobblingAutoScrobble)
            if newValue { startAutoScrobbleTimerIfEnabled() } else { stopAutoScrobbleTimer() }
            objectWillChange.send()
        }
    }

    // MARK: - Eligibility filter (pure, testable)

    /// Result of evaluating a history entry against the full eligibility
    /// ruleset. Separates permanent (never-going-to-scrobble) rejections
    /// from filter-driven (user-editable) skips so the caller can decide
    /// whether to persist the decision to `scrobble_log`.
    public enum EligibilityVerdict: Equatable {
        case eligible
        /// Reason is structural — missing fields, duration, age. Persist
        /// as `ignoredByService` so we stop re-evaluating the row.
        case permanentlyIneligible(reason: String)
        /// Reason is a user-editable filter (room, music service). Do NOT
        /// persist — the row must re-qualify when the filter changes.
        case filteredOut(reason: String)
    }

    /// Applies universal eligibility rules + user source/room filters to a
    /// candidate entry. Exposed for tests. The verdict distinguishes
    /// permanent rejections from filter-driven skips (see `EligibilityVerdict`).
    public static func classify(
        _ entry: PlayHistoryEntry,
        enabledRooms: Set<String>,
        enabledMusicServices: Set<String>,
        now: Date = Date()
    ) -> EligibilityVerdict {
        // ── Permanent checks (structural — cannot change) ──────────────
        if entry.artist.trimmingCharacters(in: .whitespaces).isEmpty {
            return .permanentlyIneligible(reason: "no artist")
        }
        if entry.title.trimmingCharacters(in: .whitespaces).isEmpty {
            return .permanentlyIneligible(reason: "no title")
        }
        // Last.fm rejects tracks shorter than 30 s. A duration of 0 means
        // "unknown" (typical for radio streams, which Sonos reports as a
        // continuous source) — accept those and omit the duration field
        // in the scrobble payload so Last.fm applies its own rules.
        if entry.duration > 0 && entry.duration < minDurationSeconds {
            return .permanentlyIneligible(reason: "duration < \(Int(minDurationSeconds))s")
        }
        if now.timeIntervalSince(entry.timestamp) > maxAgeSeconds {
            return .permanentlyIneligible(reason: "too old (> 14 d)")
        }

        // ── User-editable filters ──────────────────────────────────────
        // Room filter (empty set = all rooms). Substring-match against
        // `groupName` so a selected room matches both single playback
        // ("Office") and grouped playback ("Office + Kitchen",
        // "Whole House", "Office Group", etc.) — Sonos group-name
        // conventions vary by configuration.
        if !enabledRooms.isEmpty {
            let haystack = entry.groupName.lowercased()
            let matches = enabledRooms.contains { room in
                let needle = room.lowercased()
                return !needle.isEmpty && haystack.contains(needle)
            }
            if !matches { return .filteredOut(reason: "room not selected") }
        }

        // Music-service filter (empty set = all services). Empty sourceURI
        // bypasses (local / unknown source).
        if !enabledMusicServices.isEmpty {
            if let src = entry.sourceURI?.lowercased(), !src.isEmpty {
                let matches = enabledMusicServices.contains { name in
                    Self.sourceURI(src, matchesService: name)
                }
                if !matches { return .filteredOut(reason: "music service not selected") }
            }
        }

        return .eligible
    }

    /// Maps a music-service display name (as shown in the Settings
    /// checklist) to the URI fingerprints that identify that service in
    /// Sonos's `sourceURI`. The human-readable name rarely appears
    /// verbatim — e.g., Apple Music tracks carry `sid=204`, not
    /// "apple music" — so a simple keyword match under-matches massively
    /// (real-world bug: 136 Apple Music tracks reported as "service not
    /// selected" even with Apple Music ticked).
    ///
    /// Patterns are lowercased substrings; the first match wins. Unknown
    /// services fall through to a plain-keyword check against the name
    /// itself, which still works for Spotify / SoundCloud / TuneIn etc.
    /// whose name does appear in their URIs.
    // SIDs confirmed by live ListAvailableServices call against a Sonos One
    // on this household. Lowercased because matching is done against a
    // lowercased sourceURI. Keywords are kept as fallbacks in case a URI
    // happens to include the service name (SoundCloud does; TuneIn doesn't
    // always).
    static let knownServiceURIPatterns: [String: [String]] = [
        "apple music": ["sid=204"],
        "amazon music": ["sid=201"],
        "spotify": ["sid=12", "spotify"],
        "tunein": ["sid=254", "tunein"],
        "sonos radio": ["sid=303", "x-sonosapi-radio:", "sonosradio"],
        "calm radio": ["sid=144", "calmradio"],
        "soundcloud": ["sid=160", "soundcloud"],
        "youtube music": ["sid=284"],
        "local library": ["x-file-cifs:", "x-sonos-http:library"],
    ]

    static func sourceURI(_ uriLowercased: String, matchesService name: String) -> Bool {
        let lower = name.lowercased()
        if let patterns = knownServiceURIPatterns[lower] {
            return patterns.contains { uriLowercased.contains($0) }
        }
        return uriLowercased.contains(lower)
    }

    /// Convenience wrapper preserved for callers/tests that only care
    /// about the binary decision.
    public static func isEligible(
        _ entry: PlayHistoryEntry,
        enabledRooms: Set<String>,
        enabledMusicServices: Set<String>,
        now: Date = Date()
    ) -> Bool {
        if case .eligible = classify(entry, enabledRooms: enabledRooms,
                                     enabledMusicServices: enabledMusicServices, now: now) {
            return true
        }
        return false
    }

    // MARK: - Internals

    private func runOne(service: any ScrobbleService) async {
        let sid = service.serviceID
        let rooms = loadSet(UDKey.scrobblingEnabledRooms)
        let musicServices = loadSet(UDKey.scrobblingEnabledMusicServices)

        let candidates = repository.unscrobbledEntries(service: sid, maxRetries: 3, limit: 500)
        let now = Date()
        var eligible: [PlayHistoryEntry] = []
        var permanentlyIneligible: [(PlayHistoryEntry, String)] = []
        for entry in candidates {
            switch Self.classify(entry, enabledRooms: rooms, enabledMusicServices: musicServices, now: now) {
            case .eligible:
                eligible.append(entry)
            case .permanentlyIneligible(let reason):
                permanentlyIneligible.append((entry, reason))
            case .filteredOut:
                // Skip without recording — filter settings are user-editable,
                // so the row must be re-evaluated on the next run if filters
                // change. Recording as ignoredByService would lock it in.
                break
            }
        }

        // Structural failures (< 30 s, missing artist, > 14 d) will never
        // become eligible no matter what the user does, so we persist them
        // as ignored to avoid re-considering 3,000+ rows every run.
        for (entry, reason) in permanentlyIneligible {
            repository.recordScrobbleResult(
                historyID: entry.id, service: sid,
                state: .ignoredByService, error: reason
            )
        }

        guard !eligible.isEmpty else {
            sonosDebugLog("[SCROBBLE] \(sid): no eligible entries to scrobble")
            return
        }

        sonosDebugLog("[SCROBBLE] \(sid): submitting \(eligible.count) entries")
        do {
            let results = try await service.scrobble(eligible)
            for r in results {
                switch r {
                case .accepted(let id):
                    repository.recordScrobbleResult(historyID: id, service: sid, state: .sent)
                case .ignored(let id, let reason):
                    repository.recordScrobbleResult(historyID: id, service: sid,
                                                    state: .ignoredByService, error: reason)
                case .failed(let id, let err):
                    repository.recordScrobbleResult(historyID: id, service: sid,
                                                    state: .failedRetryable, error: err)
                }
            }
            sonosDebugLog("[SCROBBLE] \(sid): completed \(results.count) results")
        } catch {
            sonosDiagLog(.error, tag: "SCROBBLE",
                         "Submission threw: \(error.localizedDescription)",
                         context: ["service": sid])
            lastRunError = error.localizedDescription
        }
    }

    private func loadSet(_ key: String) -> Set<String> {
        let raw = defaults.string(forKey: key) ?? ""
        return Set(raw.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
    }

    public func saveRoomSet(_ rooms: Set<String>) {
        defaults.set(rooms.sorted().joined(separator: ","), forKey: UDKey.scrobblingEnabledRooms)
        objectWillChange.send()
    }

    public var enabledRooms: Set<String> { loadSet(UDKey.scrobblingEnabledRooms) }

    public func saveMusicServiceSet(_ services: Set<String>) {
        defaults.set(services.sorted().joined(separator: ","),
                     forKey: UDKey.scrobblingEnabledMusicServices)
        objectWillChange.send()
    }

    public var enabledMusicServices: Set<String> { loadSet(UDKey.scrobblingEnabledMusicServices) }

    // MARK: - Auto-scrobble timer

    private func startAutoScrobbleTimerIfEnabled() {
        stopAutoScrobbleTimer()
        guard autoScrobbleEnabled else { return }
        autoScrobbleTimer = Timer.scheduledTimer(
            withTimeInterval: Timing.autoScrobbleInterval, repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.scrobblePending() }
        }
    }

    private func stopAutoScrobbleTimer() {
        autoScrobbleTimer?.invalidate()
        autoScrobbleTimer = nil
    }
}
