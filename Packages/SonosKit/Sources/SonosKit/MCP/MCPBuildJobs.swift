/// MCPBuildJobs.swift — Background playlist builds for the MCP server.
///
/// Matching a song list takes seconds per song on hosted services, far
/// longer than a tool call may block. `build_playlist` therefore starts
/// a job and returns its id; `build_status` reads progress. The job
/// runs one or more matching passes (a fallback service re-tries the
/// misses of the pass before it), hands every hit to `onHit` as it lands
/// so a queue can fill while matching continues, and calls `finish` with
/// the full result once. This type knows nothing about Sonos — the tool
/// layer supplies both closures.
import Foundation

@MainActor
final class MCPBuildJobs {
    struct Pass {
        let label: String
        let service: PlaylistResolveService
    }

    /// Named as the MCP Tasks extension names them, so a later move to
    /// that transport changes no field values.
    enum State: String {
        case working, completed, cancelled, failed
    }

    /// How often a client should read `build_status` while working.
    static let pollIntervalMilliseconds = 1000

    /// Called per match with the track and its 1-based match number;
    /// returns the queue position it landed at, when it was queued.
    typealias Hit = @MainActor (QueueItem, _ index: Int) async throws -> Int?
    /// At most this many builds run at once; each paces the network.
    static let maxRunning = 2

    enum StartError: Error { case tooManyRunning }
    typealias Finish = @MainActor ([QueueItem]) async throws -> (delivered: String, playlistID: Int64?)

    final class Job {
        let id = UUID().uuidString
        let name: String
        let total: Int
        let passLabels: [String]
        let startedAt = Date()
        fileprivate(set) var currentPass: String
        fileprivate(set) var done = 0
        /// Matches in input order, however many passes found them.
        fileprivate(set) var matched: [QueueItem] = []
        /// Input index of each match, parallel to `matched`.
        fileprivate var matchedIndices: [Int] = []
        /// Queue positions the hits landed at, in the order they were added.
        fileprivate(set) var queuedPositions: [Int] = []
        fileprivate(set) var unmatched: [SongSpec] = []
        fileprivate(set) var state: State = .working
        fileprivate(set) var delivered: String?
        fileprivate(set) var playlistID: Int64?
        fileprivate(set) var hitErrors = 0
        fileprivate(set) var error: String?
        fileprivate var task: Task<Void, Never>?

        fileprivate var specIDs: [String] = []
        fileprivate var usedSlots: Set<Int> = []

        init(name: String, total: Int, passLabels: [String]) {
            self.name = name
            self.total = total
            self.passLabels = passLabels
            self.currentPass = passLabels.first ?? ""
        }

        /// The first unused input position carrying this spec.
        fileprivate func inputIndex(of spec: SongSpec) -> Int {
            for (index, id) in specIDs.enumerated() where id == spec.id && !usedSlots.contains(index) {
                usedSlots.insert(index)
                return index
            }
            return specIDs.count
        }

        var snapshot: [String: Any] {
            [
                "job_id": id,
                "name": name,
                "status": state.rawValue,
                "poll_interval_ms": MCPBuildJobs.pollIntervalMilliseconds,
                "services": passLabels,
                "current_service": currentPass,
                "total": total,
                "done": done,
                "matched": matched.map { ["title": $0.title, "artist": $0.artist, "album": $0.album] },
                "unmatched": unmatched.map { ["title": $0.title, "artist": $0.artist] },
                "queued_positions": queuedPositions,
                "delivered": delivered ?? NSNull(),
                "playlist_id": playlistID ?? NSNull(),
                "queue_errors": hitErrors,
                "error": error ?? NSNull(),
                "elapsed_seconds": Int(Date().timeIntervalSince(startedAt)),
            ]
        }
    }

    /// Finished jobs kept for status reads; oldest go first.
    static let keepLimit = 20

    private var jobs: [String: Job] = [:]
    private var order: [String] = []

    var running: [Job] { allJobs.filter { $0.state == .working } }
    /// Every job still held, newest first.
    var allJobs: [Job] { order.reversed().compactMap { jobs[$0] } }

    func job(_ id: String) -> Job? { jobs[id] }

    @discardableResult
    func start(name: String, specs: [SongSpec], passes: [Pass], onHit: Hit?, finish: Finish?) throws -> Job {
        precondition(!passes.isEmpty, "A build needs at least one matching pass")
        guard running.count < Self.maxRunning else { throw StartError.tooManyRunning }
        let job = Job(name: name, total: specs.count, passLabels: passes.map(\.label))
        job.specIDs = specs.map(\.id)
        jobs[job.id] = job
        order.append(job.id)
        evict()
        job.task = Task { [weak self] in
            await self?.run(job, specs: specs, passes: passes, onHit: onHit, finish: finish)
        }
        return job
    }

    /// True when the job was running and is now cancelled.
    func cancel(_ id: String) -> Bool {
        guard let job = jobs[id], job.state == .working else { return false }
        job.task?.cancel()
        job.state = .cancelled
        return true
    }

    /// Returns when the job leaves `running` or `seconds` elapse.
    func wait(_ job: Job, upTo seconds: Int) async {
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        while job.state == .working, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    // MARK: - Running

    private func run(_ job: Job, specs: [SongSpec], passes: [Pass], onHit: Hit?, finish: Finish?) async {
        var pending = specs
        // Re-matching only the misses on later passes; the counter
        // therefore covers every spec exactly once per pass it reaches.
        for (passIndex, pass) in passes.enumerated() {
            guard !pending.isEmpty, job.state == .working else { break }
            job.currentPass = pass.label
            if passIndex > 0 { job.done = job.total - pending.count }
            let result = await PlaylistResolver.resolve(pending, via: pass.service, pacing: pass.service.defaultPacing) { _, _, spec, item in
                await self.record(item, spec: spec, in: job, onHit: onHit)
            }
            pending = result.misses
        }
        guard job.state == .working else { return }
        job.unmatched = pending
        job.done = job.total
        if let finish, !job.matched.isEmpty {
            do {
                let outcome = try await finish(job.matched)
                job.delivered = outcome.delivered
                job.playlistID = outcome.playlistID
            } catch {
                job.error = error.localizedDescription
                job.state = .failed
                return
            }
        }
        job.state = .completed
    }

    private func record(_ item: QueueItem?, spec: SongSpec, in job: Job, onHit: Hit?) async {
        guard job.state == .working else { return }
        job.done += 1
        guard let item else { return }
        // Insert at the input position: matches from a later pass slot
        // in among the first pass's, so the saved list keeps the order
        // the songs were given in. The queue, filled as hits land, is
        // arrival order — that is what streaming means.
        let slot = job.inputIndex(of: spec)
        let insertAt = job.matchedIndices.firstIndex(where: { $0 > slot }) ?? job.matched.count
        let renumbered = QueueItem(id: job.matched.count + 1, title: item.title, artist: item.artist, album: item.album,
                                   albumArtURI: item.albumArtURI, duration: item.duration, uri: item.uri,
                                   metadata: item.metadata, originSid: item.originSid, originItemID: item.originItemID)
        job.matched.insert(renumbered, at: insertAt)
        job.matchedIndices.insert(slot, at: insertAt)
        guard let onHit else { return }
        do {
            if let position = try await onHit(renumbered, job.queuedPositions.count + 1) { job.queuedPositions.append(position) }
        } catch {
            job.hitErrors += 1
        }
    }

    private func evict() {
        while order.count > Self.keepLimit,
              let victim = order.first(where: { jobs[$0]?.state != .working }) {
            order.removeAll { $0 == victim }
            jobs.removeValue(forKey: victim)
        }
    }
}
