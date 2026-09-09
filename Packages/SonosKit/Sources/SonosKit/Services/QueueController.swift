/// QueueController.swift — Owns the speaker's live queue: reading it, mutating
/// it, and the background repair/fill bookkeeping behind long adds.
///
/// `clearQueue`, `playItemsReplacingQueue` and `playTrackFromQueue` stay with
/// transport: all three write `groupTrackMetadata`, `groupTransportStates`
/// and `awaitingPlayback`, so they are transport orchestration that happens
/// to involve a queue.
import Foundation

/// Taking an undo snapshot before a destructive queue operation. A one-method
/// protocol rather than a closure, so the dependency keeps its type.
@MainActor
public protocol QueueSnapshotting: AnyObject {
    func snapshotQueueForHistory(group: SonosGroup) async
}

/// Scheduling the follow-up that names Apple Music rows added bare.
@MainActor
public protocol QueueRowRepairing: AnyObject {
    func scheduleAppleMusicQueueRepair(group: SonosGroup, rows: [(position: Int, uri: String)])
}

@MainActor
@Observable
public final class QueueController: LiveQueueOperating {

    // MARK: - Collaborators

    @ObservationIgnored private let contentDirectory: QueueDirectoryOperating
    @ObservationIgnored private let enricher: TrackMetadataEnricher
    /// Set by the owner; weak so the controller never keeps it alive.
    @ObservationIgnored public weak var snapshotter: QueueSnapshotting?
    /// Apple Music rows that enqueued bare need a follow-up naming pass. That
    /// pass reads transport state, so it lives on the owner and is reached
    /// through a protocol rather than pulled in here.
    @ObservationIgnored public weak var rowRepairer: QueueRowRepairing?

    /// True while any add is in flight. The single source of truth for the
    /// "Adding to queue…" spinner — the façade forwards this rather than
    /// mirroring it into a second flag, so it cannot be left unwired.
    public var isAdding: Bool { addingToQueueDepth > 0 }

    /// Adds nest: a browse walk that expands several containers must not clear
    /// the spinner when an inner add finishes.
    public func beginAdding() {
        addingToQueueDepth += 1
    }

    public func endAdding() {
        addingToQueueDepth = max(0, addingToQueueDepth - 1)
    }

    public init(contentDirectory: QueueDirectoryOperating,
                enricher: TrackMetadataEnricher) {
        self.contentDirectory = contentDirectory
        self.enricher = enricher
    }

    /// Live track count during a large queue add. BrowseViewModel
    /// updates this as it walks a deep local-library hierarchy; the
    /// queue panel reads it to render "Adding N tracks…" instead of a
    /// blank spinner. Resets to 0 when no add is in flight.
    public var addingToQueueProgress: Int = 0

    /// Overlap-safe depth behind `isAddingToQueue`: with a single Bool the
    /// first of two concurrent adds to finish clears the flag while the
    /// second is still running. The published Bool stays as the UI-facing
    /// property; all writers go through `beginAddingToQueue` /
    /// `endAddingToQueue`.
    public internal(set) var addingToQueueDepth = 0

    /// Where a missing track length can be looked up. Sonos reports no
    /// duration for local-library rows, so play history — which records
    /// the length the speaker announced when the track last played —
    /// stands in.
    public var durationSource: (() -> QueueDurationSource?)?

    /// Rows without a duration get the learned one when there is one.
    public func fillingDurations(_ items: [QueueItem]) -> [QueueItem] {
        guard items.contains(where: { $0.duration.isEmpty }), let source = durationSource?() else { return items }
        return items.map { item in
            guard item.duration.isEmpty,
                  let seconds = source.learnedDuration(uri: item.uri, title: item.title, artist: item.artist, album: item.album)
            else { return item }
            var filled = item
            filled.duration = PlaybackTimeFormat.didlString(seconds)
            return filled
        }
    }

    /// See `QueueDirectoryOperating.queueRevision`.
    public func queueRevision(group: SonosGroup) async throws -> Int {
        guard let coordinator = group.coordinator else { return 0 }
        return try await contentDirectory.queueRevision(device: coordinator)
    }

    public func getQueue(group: SonosGroup, start: Int = 0, count: Int = PageSize.queue) async throws -> (items: [QueueItem], total: Int) {
        guard let coordinator = group.coordinator else { return ([], 0) }
        let result = try await contentDirectory.browseQueue(device: coordinator, start: start, count: count, includeMetadata: false)
        // Recover real titles for rows where the speaker returned a filename
        // (e.g. Suno `<uuid>.mp3`) — the song name is in the play-time cache.
        let items = fillingDurations(result.items.map { enricher.enrichQueueItemFromCache($0) })
        // Cache queue items for track info recovery (Apple Music tracks may have empty GetPositionInfo)
        if start == 0 {
            enricher.recordQueuePage(result.items, for: group.coordinatorID)
        }
        return (items, result.total)
    }

    /// Serial background repair chain per coordinator.
    public internal(set) var queueRepairTasks: [String: Task<Void, Never>] = [:]

    /// Background queue fill per coordinator. A replace-queue action
    /// cancels the previous coordinator's fill — otherwise Play All on
    /// album B while album A's fill is mid-flight interleaves both
    /// albums' remaining chunks into the new queue.
    public internal(set) var queueFillTasks: [String: Task<Void, Never>] = [:]

    /// Count of repairs in flight per coordinator — Q:0 GENA events are
    /// suppressed while non-zero so the swap churn doesn't blink the queue
    /// panel; one reload fires when the last chained repair finishes.
    public internal(set) var queueRepairDepth: [String: Int] = [:]

    public var queueRepairActiveGroups: Set<String> {
        Set(queueRepairDepth.filter { $0.value > 0 }.map(\.key))
    }

    public func removeFromQueue(group: SonosGroup, trackIndex: Int) async throws {
        guard let coordinator = group.coordinator else { return }
        try await contentDirectory.removeTrackFromQueue(device: coordinator, objectID: "Q:0/\(trackIndex)")
    }

    /// Pages the entire live queue WITH per-track DIDL. The metadata is what
    /// lets an Apple Music / SMAPI track re-enqueue later without faulting
    /// UPnP 800.
    func readFullQueue(device: SonosDevice) async throws -> [QueueItem] {
        var collected: [QueueItem] = []
        var index = 0
        while true {
            let (page, total) = try await contentDirectory.browseQueue(device: device, start: index, count: 500, includeMetadata: true)
            collected.append(contentsOf: fillingDurations(page.map { enricher.enrichQueueItemFromCache($0) }))
            if page.isEmpty || collected.count >= total || index >= 40_000 { break }
            index += page.count
        }
        return collected
    }

    /// Removes duplicate tracks (same resource URI) from the queue, keeping
    /// the first occurrence. Snapshots the queue first so it's undoable.
    /// Returns the number of rows removed.
    public func dedupeQueue(group: SonosGroup) async throws -> Int {
        guard let coordinator = group.coordinator else { return 0 }
        // A background queue repair (Apple Music name-swap walker) mutates
        // rows while it runs — positions computed here would be stale by
        // removal time. Skip rather than remove the wrong rows.
        if queueRepairDepth[coordinator.id, default: 0] > 0 {
            sonosDiagLog(.info, tag: "QUEUE",
                         "dedupeQueue skipped — queue repair in flight",
                         context: ["coordinator": coordinator.id])
            return 0
        }
        var collected: [QueueItem] = []
        var index = 0
        while true {
            let (page, total) = try await getQueue(group: group, start: index, count: 500)
            collected.append(contentsOf: page)
            if page.isEmpty || collected.count >= total || index >= 40_000 { break }
            index += page.count
        }
        var seen = Set<String>()
        var duplicates: [(position: Int, uri: String)] = []
        for item in collected {
            guard let uri = item.uri, !uri.isEmpty else { continue }
            if seen.contains(uri) {
                duplicates.append((position: item.id, uri: uri))
            } else {
                seen.insert(uri)
            }
        }
        guard !duplicates.isEmpty else { return 0 }
        await snapshotter?.snapshotQueueForHistory(group: group)
        // Remove bottom-up so earlier removals don't shift later positions.
        // Positions were computed across paged awaits — re-verify each
        // row's URI with a single-row browse immediately before removing
        // so a queue mutated since the scan can't lose the wrong track.
        var removed = 0
        for (position, uri) in duplicates.sorted(by: { $0.position > $1.position }) {
            guard let row = try? await contentDirectory.browseQueue(
                    device: coordinator, start: position - 1, count: 1, includeMetadata: false).items.first,
                  row.uri == uri else {
                sonosDiagLog(.info, tag: "QUEUE",
                             "dedupeQueue skipped shifted row",
                             context: ["position": String(position)])
                continue
            }
            try await contentDirectory.removeTrackFromQueue(device: coordinator, objectID: "Q:0/\(position)")
            removed += 1
        }
        enricher.postQueueChanged(optimisticItems: [])
        return removed
    }

    /// Background batched enqueue used after `playItemsReplacingQueue`
    /// has the first track playing. Sets `isAddingToQueue` so QueueView
    /// shows its spinner; never posts the green status banner.
    ///
    /// Mirrors `addBrowseItemsToQueue`'s resilience: tries the bulk
    /// `AddMultipleURIsToQueue` first, falls back to per-track
    /// `AddURIToQueue` calls if the batch throws OR comes back with
    /// `numAdded == 0`. The speaker commonly rejects the first chunk
    /// while the queue is mid-transition immediately after `play()`;
    /// without the fallback every subsequent track is lost and Play All
    /// on an album plays only the first track.
    public func fillQueueInBackground(_ items: [BrowseItem], in group: SonosGroup) async {
        guard let coordinator = group.coordinator, !items.isEmpty else { return }
        beginAdding()
        defer {
            endAdding()
            enricher.postQueueChanged(optimisticItems: [])
        }

        // Brief settle window. The bulk-add SOAP request landing
        // microseconds after `play()` sometimes faults because the
        // speaker is still wiring up the new playback context. 300 ms
        // is below any user-perceptible delay (the first track is
        // already playing) but enough for the transport state to settle.
        try? await Task.sleep(nanoseconds: 300_000_000)

        var uris: [String] = []
        var metas: [String] = []
        var sources: [BrowseItem] = []
        for item in items {
            // Skip only items with no usable URI. SMAPI containers
            // (`x-rincon-cpcontainer:` album/playlist URIs from
            // Spotify, Apple Music, Plex etc.) DO have a URI and Sonos
            // expands them server-side inside AddMultipleURIsToQueue
            // / AddURIToQueue — same as the singular
            // `addBrowseItemToQueue` path. Filtering on
            // `!item.isContainer` here makes Play All on an artist's
            // album list play only the first album.
            guard let uri = item.resourceURI, !uri.isEmpty else { continue }
            uris.append(uri)
            var meta = item.resourceMetadata ?? ""
            meta = DIDLNormalize.metadata(meta)
            metas.append(meta)
            sources.append(item)
            if !item.title.isEmpty {
                let cached = TrackMetadataEnricher.CachedTrack(title: item.title,
                                         artist: item.artist,
                                         album: item.album,
                                         artURL: item.albumArtURI)
                enricher.cachedTrackInfo[uri] = cached
                if let decoded = uri.removingPercentEncoding, decoded != uri {
                    enricher.cachedTrackInfo[decoded] = cached
                }
            }
        }
        guard !uris.isEmpty else { return }

        let chunkSize = 16
        var repairRows: [(position: Int, uri: String)] = []
        var failedTitles: [String] = []
        for chunkStart in stride(from: 0, to: uris.count, by: chunkSize) {
            // A newer replace-queue action cancels this fill; continuing
            // would append this (stale) selection's chunks into the new
            // queue.
            if Task.isCancelled { return }
            let end = min(chunkStart + chunkSize, uris.count)
            let uriChunk = Array(uris[chunkStart..<end])
            let metaChunk = Array(metas[chunkStart..<end])
            let sourceChunk = Array(sources[chunkStart..<end])

            // Items the bulk call did not land — the whole chunk on a
            // fault, or the tail beyond `numAdded` on a partial add.
            var pending: [BrowseItem] = []
            do {
                let result = try await contentDirectory.addMultipleURIsToQueue(
                    device: coordinator,
                    uris: uriChunk,
                    metadatas: metaChunk,
                    desiredFirstTrackNumberEnqueued: 0,
                    enqueueAsNext: false
                )
                sonosDebugLog("[QUEUE] Background fill chunk \(chunkStart)-\(end-1): firstTrack=\(result.firstTrackNumber) numAdded=\(result.numAdded)")
                if result.firstTrackNumber > 0 {
                    for (offset, u) in uriChunk.prefix(result.numAdded).enumerated() {
                        repairRows.append((position: result.firstTrackNumber + offset, uri: u))
                    }
                }
                if result.numAdded < sourceChunk.count {
                    pending = Array(sourceChunk.dropFirst(max(result.numAdded, 0)))
                }
            } catch {
                sonosDebugLog("[QUEUE] Background fill chunk \(chunkStart)-\(end-1) bulk failed: \(error). Falling back.")
                pending = sourceChunk
            }

            if !pending.isEmpty {
                // Per-track fallback, as in `addBrowseItemsToQueue`:
                // single-track adds recover the cases where the bulk
                // variant rejects mid-transition. Each failed add gets
                // one delayed retry — the fault mode is a transient
                // rejection immediately after stop/clear/play, which
                // clears within a second.
                var perTrackAdded = 0
                for (i, item) in pending.enumerated() {
                    guard let uri = item.resourceURI, !uri.isEmpty else { continue }
                    var meta = item.resourceMetadata ?? ""
                    meta = DIDLNormalize.metadata(meta)
                    var added = false
                    for attempt in 1...2 {
                        do {
                            let pos = try await contentDirectory.addURIToQueue(
                                device: coordinator, uri: uri, metadata: meta,
                                desiredFirstTrackNumberEnqueued: 0,
                                enqueueAsNext: false
                            )
                            if pos > 0 { perTrackAdded += 1 }
                            added = true
                            break
                        } catch {
                            sonosDebugLog("[QUEUE] Background per-track add attempt \(attempt) failed for '\(item.title)' (chunk \(chunkStart)+\(i)): \(error)")
                            // One bad track does not stop the rest of
                            // the chunk. (The user-initiated
                            // `addBrowseItemsToQueue` breaks on first
                            // error to avoid hammering a misbehaving
                            // speaker.)
                            if attempt == 1 {
                                try? await Task.sleep(nanoseconds: 1_000_000_000)
                            }
                        }
                    }
                    if !added { failedTitles.append(item.title) }
                }
                sonosDebugLog("[QUEUE] Background per-track fallback chunk \(chunkStart)-\(end-1): \(perTrackAdded)/\(pending.count)")
            }

            // Refresh the queue panel after each chunk so large
            // playlists fill in visibly instead of jumping from
            // 1 track → N tracks at the very end.
            enricher.postQueueChanged(optimisticItems: [])
        }
        rowRepairer?.scheduleAppleMusicQueueRepair(group: group, rows: repairRows)
        if !failedTitles.isEmpty {
            sonosDebugLog("[QUEUE] Background fill dropped \(failedTitles.count) track(s): \(failedTitles.joined(separator: ", "))")
            ErrorHandler.shared.warning(L10n.queueTracksNotAdded(failedTitles.count), context: "QUEUE")
        }
    }

    public func moveTrackInQueue(group: SonosGroup, from: Int, to: Int) async throws {
        guard let coordinator = group.coordinator else { return }
        try await contentDirectory.reorderTracksInQueue(device: coordinator, startIndex: from, numberOfTracks: 1, insertBefore: to)
    }

}
