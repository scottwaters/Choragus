/// QueueHealthMonitor.swift — Automatic staleness detection for queue rows,
/// triggered by track changes, budgeted so steady state costs nothing.
///
/// Tiers, by cost:
///   1. Offline — expiry parsed from the URL. Free; recomputed every pass.
///   2. Host liveness — one TCP touch per distinct NAS/media-server host.
///      A dead host verdicts every row it serves without per-row probes.
///   3. HEAD probes — only rows where nothing cheaper can answer: paid
///      streaming URLs with opaque tokens, and media-server rows (whose
///      failure mode is a 404 after the server reindexed its object ids).
///
/// Budget rules, all enforced here:
/// verdicts cache on a signature-stripped key (a re-resolved URL is a new
/// key); ok lives 6 h, dead 30 min; one pass per group per 10 min; the
/// trigger is debounced and delayed so probes never share the wall-clock
/// instant with the art fetch and scroll animation a track change owns; only
/// the WINDOW rows after the playhead are considered; per-row results are
/// delivered as ONE batched dictionary, because ten sequential state writes
/// would re-render a 500-row list ten times.
import Foundation
import Network

@MainActor
public final class QueueHealthMonitor {

    public struct Config {
        public var window = 10
        public var okTTL: TimeInterval = 6 * 3600
        public var deadTTL: TimeInterval = 30 * 60
        public var cooldown: TimeInterval = 600
        public var debounce: TimeInterval = 5
        public var maxProbesPerPass = 10
        public init() {}
    }

    public typealias Verdict = QueueHealthScanner.Verdict

    private let config: Config
    private var cache: [String: (verdict: Verdict, at: Date)] = [:]
    private var lastPassByGroup: [String: Date] = [:]
    private var pendingPass: Task<Void, Never>?
    private let probe: @Sendable (URL) async -> Int?
    private let hostAlive: @Sendable (String, Int) async -> Bool
    private let now: () -> Date

    /// Probes injectable for tests; defaults do real networking.
    public init(config: Config = Config(),
                probe: (@Sendable (URL) async -> Int?)? = nil,
                hostAlive: (@Sendable (String, Int) async -> Bool)? = nil,
                now: @escaping () -> Date = { Date() }) {
        self.config = config
        self.probe = probe ?? { await QueueHealthScanner.httpProbe($0) }
        self.hostAlive = hostAlive ?? { await Self.tcpTouch(host: $0, port: $1) }
        self.now = now
    }

    // MARK: - Classification (pure, testable)

    enum RowKind: Equatable {
        case paidStreamingReadableExpiry
        case paidStreamingOpaque
        case mediaServer(host: String, port: Int)
        case cifs(host: String)
        case notCheckable
    }

    static func kind(of uri: String?, isMediaServerHost: (String) -> Bool) -> RowKind {
        guard let uri, !uri.isEmpty else { return .notCheckable }
        if uri.hasPrefix(URIPrefix.fileCifs) {
            let trimmed = uri.dropFirst(URIPrefix.fileCifs.count)
            let host = trimmed.split(separator: "/", omittingEmptySubsequences: true).first.map(String.init)
            return host.map { .cifs(host: $0) } ?? .notCheckable
        }
        guard StaleTrackURL.isDirectStream(uri) else { return .notCheckable }
        if StaleTrackURL.carriesRotatingCredential(uri) {
            return StaleTrackURL.expiry(in: uri) != nil
                ? .paidStreamingReadableExpiry : .paidStreamingOpaque
        }
        if let url = URL(string: uri), let host = url.host, isMediaServerHost(host) {
            return .mediaServer(host: host, port: url.port ?? 80)
        }
        return .notCheckable
    }

    /// Cache key that survives re-resolution rotation for paid streams and
    /// stays per-file for media servers.
    static func cacheKey(for uri: String) -> String {
        ResolvedPlaybackRegistry.key(forPlayURL: uri) ?? uri
    }

    // MARK: - Trigger

    public struct Row: Sendable {
        public let id: Int
        public let uri: String?
        public let title: String
        public init(id: Int, uri: String?, title: String) {
            self.id = id; self.uri = uri; self.title = title
        }
    }

    /// Call on every coordinator trackURI transition. Debounces internally;
    /// burst skipping collapses to one pass. `onVerdicts` receives ONE
    /// batched map covering every judged row, on the MainActor.
    public func noteTrackChanged(groupID: String,
                                 rows: [Row],
                                 currentTrack: Int,
                                 isMediaServerHost: @escaping @Sendable (String) -> Bool,
                                 onVerdicts: @escaping @MainActor ([Int: Verdict]) -> Void) {
        pendingPass?.cancel()
        let debounce = config.debounce
        pendingPass = Task { [weak self] in
            try? await Task.sleep(for: .seconds(debounce))
            guard !Task.isCancelled, let self else { return }
            await self.runPass(groupID: groupID, rows: rows, currentTrack: currentTrack,
                               isMediaServerHost: isMediaServerHost, onVerdicts: onVerdicts)
        }
    }

    private func runPass(groupID: String,
                         rows: [Row],
                         currentTrack: Int,
                         isMediaServerHost: @Sendable (String) -> Bool,
                         onVerdicts: @MainActor ([Int: Verdict]) -> Void) async {
        var verdicts: [Int: Verdict] = [:]
        let currentTime = now()

        // Tier 1 — offline, whole queue, free. Cached probe verdicts are
        // re-applied here too: a pass that runs offline-only (cooldown) or a
        // row that has drifted out of the probe window must not erase what
        // an earlier probe established — the batched map replaces the UI
        // state wholesale, so every pass has to carry the full picture.
        for row in rows {
            guard let uri = row.uri else { continue }
            if StaleTrackURL.isDirectStream(uri), StaleTrackURL.isExpired(uri, now: currentTime) {
                verdicts[row.id] = .expired
                continue
            }
            let key = Self.cacheKey(for: uri)
            if let cached = cache[key], cached.verdict != .ok,
               !isStaleEntry(cached, at: currentTime) {
                verdicts[row.id] = cached.verdict
            }
        }

        // Probe tiers respect the per-group cooldown; offline verdicts do not.
        let probesAllowed: Bool
        if let last = lastPassByGroup[groupID], currentTime.timeIntervalSince(last) < config.cooldown {
            probesAllowed = false
        } else {
            probesAllowed = true
        }

        if probesAllowed {
            lastPassByGroup[groupID] = currentTime
            let windowRows = rows
                .filter { $0.id > currentTrack && $0.id <= currentTrack + config.window }

            // Tier 2 — host liveness, deduplicated.
            var hosts: [String: (host: String, port: Int)] = [:]
            for row in windowRows {
                switch Self.kind(of: row.uri, isMediaServerHost: isMediaServerHost) {
                case .cifs(let host): hosts["\(host):445"] = (host, 445)
                case .mediaServer(let host, let port): hosts["\(host):\(port)"] = (host, port)
                default: break
                }
            }
            var deadHosts = Set<String>()
            for (key, target) in hosts {
                if let cached = cache[key], !isStaleEntry(cached, at: currentTime) {
                    if cached.verdict == .dead { deadHosts.insert(target.host) }
                    continue
                }
                let alive = await hostAlive(target.host, target.port)
                cache[key] = (alive ? .ok : .dead, currentTime)
                if !alive { deadHosts.insert(target.host) }
            }
            for row in windowRows {
                switch Self.kind(of: row.uri, isMediaServerHost: isMediaServerHost) {
                case .cifs(let host) where deadHosts.contains(host):
                    verdicts[row.id] = .dead
                case .mediaServer(let host, _) where deadHosts.contains(host):
                    verdicts[row.id] = .dead
                default: break
                }
            }

            // Tier 3 — HEAD probes, capped.
            var budget = config.maxProbesPerPass
            for row in windowRows {
                guard budget > 0, verdicts[row.id] == nil, let uri = row.uri else { continue }
                let kind = Self.kind(of: uri, isMediaServerHost: isMediaServerHost)
                guard kind == .paidStreamingOpaque || {
                    if case .mediaServer = kind { return true }; return false
                }() else { continue }
                let key = Self.cacheKey(for: uri)
                if let cached = cache[key], !isStaleEntry(cached, at: currentTime) {
                    if cached.verdict != .ok { verdicts[row.id] = cached.verdict }
                    continue
                }
                guard let url = URL(string: uri) else { continue }
                budget -= 1
                let status = await probe(url)
                let verdict: Verdict = {
                    guard let status else { return .dead }
                    return (200...399).contains(status) ? .ok : .dead
                }()
                cache[key] = (verdict, currentTime)
                if verdict != .ok { verdicts[row.id] = verdict }
            }
            trimCache()
        }

        sonosDiagLog(.info, tag: "QUEUE", "Automatic health pass",
                     context: ["group": groupID,
                               "flagged": String(verdicts.count),
                               "probed": String(probesAllowed)])
        onVerdicts(verdicts)
    }

    private func isStaleEntry(_ entry: (verdict: Verdict, at: Date), at time: Date) -> Bool {
        let ttl = entry.verdict == .ok ? config.okTTL : config.deadTTL
        return time.timeIntervalSince(entry.at) > ttl
    }

    private func trimCache() {
        guard cache.count > 2000 else { return }
        // Oldest half goes; exact LRU is not worth the bookkeeping here.
        let cutoff = cache.values.map(\.at).sorted()[cache.count / 2]
        cache = cache.filter { $0.value.at >= cutoff }
    }

    /// One TCP connect with a short deadline. Cancels itself; never throws.
    static func tcpTouch(host: String, port: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
                continuation.resume(returning: false); return
            }
            let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            let lock = NSLock()
            var done = false
            let finish: (Bool) -> Void = { ok in
                lock.lock(); defer { lock.unlock() }
                guard !done else { return }
                done = true
                conn.cancel()
                continuation.resume(returning: ok)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled: finish(false)
                default: break
                }
            }
            conn.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { finish(false) }
        }
    }
}
