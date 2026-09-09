/// QueueViewModel.swift — Business logic for the Queue view.
import SwiftUI
import SonosKit

@MainActor
final class QueueViewModel: ObservableObject {
    var sonosManager: any QueueServices
    /// Queue mechanics come from the collaborator that owns them, not from
    /// the façade.
    let queue: any LiveQueueOperating
    /// Mutable so `QueueView` can push a new selected-speaker group into the
    /// view model when the user switches rooms in the sidebar.
    var group: SonosGroup

    @Published var queueItems: [QueueItem] = [] {
        didSet {
            // A speaker-confirmed position is only valid for the queue it
            // was confirmed against. After a reload, reorder or add, the
            // same URI can sit at a different position, so the memo that
            // suppresses the title fallback has to go with it.
            authoritativelyResolvedURI = nil
            // Summed once per load, not per header render — the header
            // re-evaluates on every transport tick.
            loadedPlaytime = QueuePlaytime(items: queueItems)
        }
    }
    /// Playtime of the loaded rows; the header adds the unloaded tail.
    @Published private(set) var loadedPlaytime = QueuePlaytime(items: [])
    @Published var currentTrack: Int = 0
    @Published var totalTracks: Int = 0
    @Published var isLoading = true
    @Published var saveMessage: String?
    @Published var playingTrack: Int? // Track currently being started (shows spinner)
    /// Selected rows by queue position. Pruned on every reload (positions
    /// shift) and cleared by the batch operations that consume it.
    @Published var selection: Set<Int> = []
    /// Anchor for shift-click range extension — the last plain click.
    private var selectionAnchor: Int?

    enum SelectionGesture {
        case replace   // plain click
        case toggle    // ⌘-click
        case extend    // ⇧-click: range from the anchor over the displayed rows
    }

    func select(_ id: Int, gesture: SelectionGesture) {
        switch gesture {
        case .replace:
            selection = [id]
            selectionAnchor = id
        case .toggle:
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            selectionAnchor = id
        case .extend:
            let ids = displayedItems.map(\.id)
            guard let anchor = selectionAnchor, let a = ids.firstIndex(of: anchor),
                  let b = ids.firstIndex(of: id) else {
                selection = [id]; selectionAnchor = id; return
            }
            selection.formUnion(ids[min(a, b)...max(a, b)])
        }
    }

    /// Rows a row-level action applies to: the selection when the row is
    /// part of it, otherwise that row alone (macOS convention).
    func actionTargets(for id: Int) -> Set<Int> {
        selection.contains(id) ? selection : [id]
    }

    /// Optimistic flag set immediately when user taps a queue track,
    /// before the next poll confirms isQueueSource from the speaker.
    private var userStartedQueuePlayback = false

    /// Last `isQueueSource` that came from a real CurrentURI observation.
    /// Event-sourced metadata carries the flag as a default, not a report
    /// (`didReportTransportSource`); trusting that default blanks the queue
    /// highlight at every track advance until the next settled write.
    private var lastReportedQueueSource = false

    /// True when the speaker is playing from the queue.
    var isPlayingFromQueue: Bool {
        if userStartedQueuePlayback { return true }
        guard let meta = sonosManager.groupTrackMetadata[group.coordinatorID] else { return false }
        if meta.didReportTransportSource {
            return meta.isQueueSource
        }
        return lastReportedQueueSource
    }

    /// URI whose position came from the speaker's own `trackNumber`. Title
    /// fallbacks must not re-resolve it: with duplicate titles they pick an
    /// earlier row and the current track oscillates.
    private var authoritativelyResolvedURI: String?

    init(sonosManager: any QueueServices, queue: any LiveQueueOperating, group: SonosGroup) {
        self.sonosManager = sonosManager
        self.queue = queue
        self.group = group
    }

    /// Updates current track number from transport metadata
    func updateCurrentTrack() {
        if let meta = sonosManager.groupTrackMetadata[group.coordinatorID],
           meta.didReportTransportSource {
            lastReportedQueueSource = meta.isQueueSource
        }
        // A click-to-play is a set-queue → seek → play sequence, and the
        // speaker reports track 1 between the first two steps. The
        // optimistic position set by playTrack stands until the operation
        // finishes, so the indicator does not flick to row 1 and back.
        guard playingTrack == nil else { return }
        let meta = sonosManager.groupTrackMetadata[group.coordinatorID]
        // Clear optimistic flag once speaker confirms queue playback
        if meta?.isQueueSource == true {
            userStartedQueuePlayback = false
        }

        // The rule lives in QueuePositionResolver so it can be tested
        // without a speaker, a view model, or a running app.
        let resolution = QueuePositionResolver.resolve(
            report: .init(trackNumber: meta?.trackNumber,
                          trackURI: meta?.trackURI,
                          title: meta?.title,
                          artist: meta?.artist),
            queue: queueItems,
            playingFromQueue: isPlayingFromQueue,
            authoritativelyResolvedURI: authoritativelyResolvedURI)

        switch resolution {
        case let .position(position, basis):
            if position != currentTrack {
                sonosDebugLog("[QUEUE] Position \(position) via \(basis)")
                currentTrack = position
            }
            if QueuePositionResolver.confirmsAuthority(resolution) {
                authoritativelyResolvedURI = meta?.trackURI
            }
        case let .hold(reason):
            if case .ambiguousTitle(let matches) = reason {
                sonosDebugLog("[QUEUE] Title fallback ambiguous for "
                              + "'\(meta?.title ?? "")' (\(matches) matches) — holding position")
            }
        }
    }

    /// Current-track-only re-sync from `getPositionInfo`, without the
    /// `Browse(Q:0)` paging or the loading spinner. Used after a trackURI
    /// change; the full `loadQueue` stays for queue mutations.
    func refreshCurrentTrack() async {
        // Same transient-seek guard as updateCurrentTrack.
        guard playingTrack == nil else { return }
        do {
            let posInfo = try await sonosManager.getPositionInfo(group: group)
            guard posInfo.trackNumber > 0 else { return }
            if currentTrack != posInfo.trackNumber {
                sonosDebugLog("[QUEUE] refreshCurrentTrack: \(currentTrack) → \(posInfo.trackNumber)")
                currentTrack = posInfo.trackNumber
            }
            // Speaker-confirmed either way — record it so the title
            // fallbacks leave this URI alone.
            if posInfo.trackNumber == currentTrack {
                authoritativelyResolvedURI = posInfo.trackURI
            }
        } catch {
            // Best-effort. The event-driven `currentTrack` stays put.
        }
    }

    /// Appends tracks the user just added, without hitting the speaker again.
    /// A real `loadQueue` later will reconcile. Skips items whose id already
    /// exists so a racing real reload doesn't produce duplicates.
    func optimisticallyAppend(_ items: [QueueItem]) {
        let existing = Set(queueItems.map(\.id))
        let fresh = items.filter { !existing.contains($0.id) }
        guard !fresh.isEmpty else { return }
        queueItems.append(contentsOf: fresh)
        totalTracks = max(totalTracks, queueItems.map(\.id).max() ?? totalTracks)
    }

    /// Load generation — captured at the start of each `loadQueue` and
    /// re-checked after the awaits so an older fetch that finishes late
    /// cannot overwrite a newer one's results.
    private var loadGeneration = 0

    func loadQueue() async {
        let priorTotal = totalTracks
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        defer { if generation == loadGeneration { isLoading = false } }
        // Verdicts are keyed by position; a reload invalidates them. The
        // monitor re-runs on its own triggers.
        healthVerdicts = [:]
        do {
            // Page-fetch the entire queue. Sonos's `Browse` accepts larger
            // RequestedCounts but starts truncating mid-page on S1
            // coordinators around 600+.
            let pageSize = 500
            var collected: [QueueItem] = []
            var totalSeen = 0
            var index = 0
            while true {
                let (page, total) = try await queue.getQueue(group: group, start: index, count: pageSize)
                totalSeen = total
                collected.append(contentsOf: page)
                if page.isEmpty { break }
                index += page.count
                if index >= total { break }
                // Hard ceiling at Sonos's documented queue maximum so a
                // runaway speaker-side total doesn't loop forever.
                if index >= 40_000 { break }
            }
            guard generation == loadGeneration else { return }
            queueItems = collected
            totalTracks = totalSeen
            selection.formIntersection(collected.map(\.id))
            let posInfo = try await sonosManager.getPositionInfo(group: group)
            guard generation == loadGeneration else { return }
            currentTrack = posInfo.trackNumber
            sonosDiagLog(.info, tag: "QUEUE",
                         "loadQueue done: \(collected.count) shown, total=\(totalSeen), prior=\(priorTotal)")

            // One-shot retry for the post-add commit race: a reload
            // triggered by `.queueChanged` can read the stale total before
            // the speaker finishes committing a container expansion.
            // 600 ms covers AddURIToQueue + x-rincon-playlist on S1.
            if totalSeen == priorTotal && pendingPostAddRetry {
                pendingPostAddRetry = false
                try? await Task.sleep(nanoseconds: 600_000_000)
                var retryCollected: [QueueItem] = []
                var retryTotal = 0
                var retryIndex = 0
                while true {
                    let (page, total) = try await queue.getQueue(group: group, start: retryIndex, count: pageSize)
                    retryTotal = total
                    retryCollected.append(contentsOf: page)
                    if page.isEmpty { break }
                    retryIndex += page.count
                    if retryIndex >= total { break }
                    if retryIndex >= 40_000 { break }
                }
                guard generation == loadGeneration else { return }
                if retryTotal != totalSeen {
                    queueItems = retryCollected
                    totalTracks = retryTotal
                    sonosDiagLog(.info, tag: "QUEUE",
                                 "loadQueue retry caught commit lag: total=\(retryTotal)")
                }
            }
        } catch {
            sonosDiagLog(.error, tag: "QUEUE",
                         "loadQueue threw: \(error.localizedDescription)")
            ErrorHandler.shared.handle(error, context: "QUEUE")
        }
    }

    /// Set by the `.queueChanged` observer when an add-style mutation
    /// was just signalled — `loadQueue` honours it once and clears.
    var pendingPostAddRetry: Bool = false

    /// Token for the most recent `playTrack` call. Concurrent taps share
    /// the optimistic state (`playingTrack`, `userStartedQueuePlayback`);
    /// only the newest call may clear or advance it — the first tap's
    /// completion must not wipe the second's spinner.
    private var playTrackGeneration = 0

    func playTrack(_ trackNumber: Int) async {
        playTrackGeneration += 1
        let generation = playTrackGeneration
        playingTrack = trackNumber
        userStartedQueuePlayback = true
        do {
            try await sonosManager.playTrackFromQueue(group: group, trackNumber: trackNumber)
            if generation == playTrackGeneration { currentTrack = trackNumber }
        } catch {
            if generation == playTrackGeneration { userStartedQueuePlayback = false }
            ErrorHandler.shared.handle(error, context: "QUEUE", userFacing: true)
        }
        if generation == playTrackGeneration { playingTrack = nil }
    }

    func removeTrack(_ trackIndex: Int) async {
        await removeTracks([trackIndex])
    }

    /// Highest position first, so earlier removals do not shift later
    /// ones; one reload at the end.
    func removeTracks(_ positions: Set<Int>) async {
        guard !positions.isEmpty else { return }
        // Positions above the removed rows shift down; the ids in the
        // selection would name different rows after the reload.
        selection = []
        do {
            for position in positions.sorted(by: >) {
                try await queue.removeFromQueue(group: group, trackIndex: position)
            }
        } catch {
            ErrorHandler.shared.handle(error, context: "QUEUE")
        }
        await loadQueue()
    }

    /// Moves `positions` as a block to sit before `insertBefore` (1-based;
    /// `count + 1` = end), preserving their relative order. Each move
    /// shifts the rows between source and target, so the source position
    /// is corrected per step: rows above the target are taken lowest first
    /// and each sits one lower than listed after the rows moved before it;
    /// rows at or below the target are taken lowest first and land one
    /// slot later each.
    func moveTracks(_ positions: Set<Int>, insertBefore: Int) async {
        guard !positions.isEmpty else { return }
        if positions.count == 1, positions.contains(insertBefore) { return }
        selection = []
        let sorted = positions.sorted()
        do {
            for (i, position) in sorted.filter({ $0 < insertBefore }).enumerated() {
                try await queue.moveTrackInQueue(group: group, from: position - i, to: insertBefore)
            }
            for (k, position) in sorted.filter({ $0 >= insertBefore }).enumerated() {
                try await queue.moveTrackInQueue(group: group, from: position, to: insertBefore + k)
            }
        } catch {
            ErrorHandler.shared.handle(error, context: "QUEUE")
        }
        await loadQueue()
    }

    /// Copies `positions` into a Choragus playlist: an existing one when
    /// `queueID` is given, otherwise a new one named `name`.
    func copyTracksToChoragus(_ positions: Set<Int>, queueID: Int64?, name: String) async {
        do {
            let tracks = try await sonosManager.liveQueueTracks(group: group, positions: positions)
            guard !tracks.isEmpty else { return }
            if let queueID {
                sonosManager.appendToChoragusPlaylist(queueID: queueID, tracks: tracks)
            } else {
                sonosManager.saveChoragusPlaylist(name: name, tracks: tracks)
            }
            showSaveMessage(L10n.playlistBuilderSaved(name, tracks.count))
        } catch {
            ErrorHandler.shared.handle(error, context: "QUEUE", userFacing: true)
        }
    }

    @Published var isClearing = false
    /// Batched verdicts from the automatic health monitor, by queue position.
    @Published var healthVerdicts: [Int: QueueHealthScanner.Verdict] = [:]
    let healthMonitor = QueueHealthMonitor()

    /// Fed by the view's trackURI observer. The monitor debounces, budgets
    /// and caches internally; this supplies the rows and the media-server
    /// host check.
    func noteTrackChangedForHealth() {
        let rows = queueItems.map { QueueHealthMonitor.Row(id: $0.id, uri: $0.uri, title: $0.title) }
        guard !rows.isEmpty else { return }
        let manager = sonosManager
        let coordinatorID = group.coordinatorID
        repairBareAppleMusicRowsIfNeeded()
        healthMonitor.noteTrackChanged(
            groupID: coordinatorID,
            rows: rows,
            currentTrack: currentTrack,
            isMediaServerHost: { host in
                MediaServerService.ContentHosts.serverID(servingHost: host) != nil
            },
            onVerdicts: { [weak self] verdicts in
                // A pass that started for a previous coordinator reports
                // positions in a queue this view no longer shows.
                guard let self, self.group.coordinatorID == coordinatorID else { return }
                if self.healthVerdicts != verdicts { self.healthVerdicts = verdicts }
                self.repairExpiredIfDue(verdicts: verdicts)
            })
        _ = manager
    }

    /// An Apple Music row the speaker wrote bare — no title, no length —
    /// is normally named by the follow-up that runs after a bulk add. That
    /// follow-up lives in memory: rows it had to defer (next to playback)
    /// are lost on relaunch, and a queue loaded before a fix shipped was
    /// never examined at all. Each track change re-checks the queue, so a
    /// bare row is picked up whenever playback moves, including the first
    /// look after launch. The repair verifies each row itself and defers
    /// what sits next to playback, so a repeat call is harmless; only an
    /// in-flight repair for this coordinator is not doubled.
    private func repairBareAppleMusicRowsIfNeeded() {
        guard let repairing = sonosManager as? SonosManager else { return }
        guard !repairing.queue.queueRepairActiveGroups.contains(group.coordinatorID) else { return }
        let bare = queueItems.compactMap { item -> (position: Int, uri: String)? in
            guard let uri = item.uri, URIPrefix.appleMusicSongID(from: uri) != nil,
                  item.title.isEmpty || TrackMetadata.isTechnicalName(item.title) else { return nil }
            return (item.id, uri)
        }
        guard !bare.isEmpty else { return }
        repairing.scheduleAppleMusicQueueRepair(group: group, rows: bare)
    }

    /// One repair attempt per cooldown window. Un-repairable rows (no
    /// recorded origin) would otherwise trigger a resolver round-trip on
    /// every pass forever.
    private var lastExpiredRepairAttempt: Date?

    private func repairExpiredIfDue(verdicts: [Int: QueueHealthScanner.Verdict]) {
        guard verdicts.values.contains(.expired) else { return }
        if let last = lastExpiredRepairAttempt, Date().timeIntervalSince(last) < 600 { return }
        lastExpiredRepairAttempt = Date()
        guard let repairing = sonosManager as? SonosManager else { return }
        let groupID = group.id
        Task { [weak self] in
            let repaired = await repairing.repairExpiredQueueEntries(groupID: groupID)
            if repaired {
                await self?.loadQueue()
                self?.healthVerdicts = self?.healthVerdicts.filter { $0.value != .expired } ?? [:]
            }
        }
    }

    func clearQueue() async {
        isClearing = true
        defer { isClearing = false }
        do {
            try await sonosManager.clearQueue(group: group)
            queueItems = []
            totalTracks = 0
        } catch {
            ErrorHandler.shared.handle(error, context: "QUEUE")
        }
    }

    @Published var isShuffling = false

    /// Shuffles the queue order randomly on the speaker
    func shuffleQueue() async {
        guard queueItems.count > 1 else { return }
        isShuffling = true

        // Fisher-Yates shuffle: move each track to a random position
        for i in stride(from: queueItems.count, through: 2, by: -1) {
            let randomPos = Int.random(in: 1...i)
            if randomPos != i {
                do {
                    try await queue.moveTrackInQueue(group: group, from: i, to: randomPos)
                } catch {
                    ErrorHandler.shared.handle(error, context: "QUEUE")
                    break
                }
            }
        }

        // Reload queue with new order
        do {
            let (items, total) = try await queue.getQueue(group: group, start: 0, count: 100)
            queueItems = items
            totalTracks = total
        } catch {
            sonosDebugLog("[QUEUE] Reload after shuffle failed: \(error)")
        }

        isShuffling = false
    }

    func saveAsPlaylist(name: String) async {
        do {
            _ = try await sonosManager.saveQueueAsPlaylist(group: group, title: name)
            showSaveMessage(L10n.savedAsFormat(name))
        } catch {
            ErrorHandler.shared.handle(error, context: "QUEUE", userFacing: true)
        }
    }

    /// Single owner of the transient save-status capsule. The generation
    /// token stops an older auto-clear timer wiping a newer message.
    private var saveMessageGeneration = 0
    func showSaveMessage(_ message: String) {
        saveMessage = message
        saveMessageGeneration += 1
        let gen = saveMessageGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.saveMessageGeneration == gen else { return }
            self.saveMessage = nil
        }
    }

    func addBrowseItem(_ item: BrowseItem, atPosition: Int = 0) async {
        do {
            try await sonosManager.addBrowseItemToQueue(item, in: group, playNext: false, atPosition: atPosition)
            await loadQueue()
        } catch {
            ErrorHandler.shared.handle(error, context: "QUEUE")
        }
    }


    // MARK: - Queue History

    /// Recoverable snapshots for the current group, newest first.
    var queueSnapshots: [QueueSnapshot] {
        sonosManager.queueSnapshots(group: group)
    }

    func restoreSnapshot(_ snapshot: QueueSnapshot) async {
        do {
            try await sonosManager.restoreQueueSnapshot(group: group, localID: snapshot.localID)
            // No loadQueue() here. The replace path is audio-first: the
            // first track lands now, the rest fill in the background, and
            // each step posts `.queueChanged` for the panel observer. An
            // immediate reload reads the partial 1-track queue and races
            // to last-writer, leaving the panel stuck on one track.
            showSaveMessage(L10n.restoredSnapshotFormat(snapshot.summary))
        } catch {
            ErrorHandler.shared.handle(error, context: "QUEUE", userFacing: true)
        }
    }

    // MARK: - Choragus-side saved queues

    /// Local saved-queue index. Refreshed on demand (cheap SQLite read);
    /// @Published so the menu re-renders after save / rename / delete.
    @Published var localSavedQueues: [LocalSavedQueue] = []

    func refreshLocalSavedQueues() {
        localSavedQueues = sonosManager.localSavedQueues()
    }

    /// Folder-nested form of `localSavedQueues` for the load menu.
    var savedQueueTree: SavedQueueTree {
        SavedQueueTree(folders: sonosManager.savedQueueFolders(), queues: localSavedQueues)
    }

    /// Loads a history snapshot of any room into this group. Replace is
    /// the undo-aware restore; append adds the rows after the queue.
    func loadSnapshot(_ snapshot: QueueSnapshot, append: Bool) async {
        guard append else { await restoreSnapshot(snapshot); return }
        isLoading = true
        defer { isLoading = false }
        do {
            try await sonosManager.loadLocalSavedQueue(id: snapshot.localID, group: group, append: true)
            await loadQueue()
        } catch {
            ErrorHandler.shared.handle(error, context: "QUEUE", userFacing: true)
        }
    }

    func saveToChoragus(name: String) async {
        do {
            let count = try await sonosManager.saveQueueToChoragus(group: group, name: name)
            refreshLocalSavedQueues()
            showSaveMessage(L10n.savedTracksToChoragusFormat(count, name))
        } catch {
            ErrorHandler.shared.handle(error, context: "QUEUE", userFacing: true)
        }
    }

    func loadLocalSavedQueue(_ saved: LocalSavedQueue, append: Bool) async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await sonosManager.loadLocalSavedQueue(id: saved.id, group: group, append: append)
            await loadQueue()
        } catch {
            ErrorHandler.shared.handle(error, context: "QUEUE", userFacing: true)
        }
    }

    func deleteLocalSavedQueue(_ saved: LocalSavedQueue) {
        sonosManager.deleteLocalSavedQueue(id: saved.id)
        refreshLocalSavedQueues()
    }

    // MARK: - Queue tools

    /// Display-only filter over the loaded queue rows.
    @Published var filterText: String = ""

    var displayedItems: [QueueItem] {
        let needle = filterText.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return queueItems }
        return queueItems.filter {
            $0.title.localizedCaseInsensitiveContains(needle)
                || $0.artist.localizedCaseInsensitiveContains(needle)
                || $0.album.localizedCaseInsensitiveContains(needle)
        }
    }

    func removeDuplicates() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let removed = try await queue.dedupeQueue(group: group)
            await loadQueue()
            showSaveMessage(removed == 0 ? L10n.noDuplicatesFound : L10n.removedDuplicatesFormat(removed))
        } catch {
            ErrorHandler.shared.handle(error, context: "QUEUE", userFacing: true)
        }
    }
}
