/// QueueHistory.swift — Per-coordinator ring buffer of queue snapshots.
///
/// A snapshot is a hidden Choragus-side saved queue (a `SavedQueueRepository`
/// row flagged `is_snapshot`) captured immediately BEFORE a destructive queue
/// mutation (replace-all, clear, bulk remove). Restoring one re-enqueues its
/// stored tracks, so an accidental "play this now" that wiped a 50-track
/// queue is recoverable. Snapshots never touch the speaker: earlier versions
/// stored them as Sonos server-side saved queues, which surfaced as
/// `__cghist__*` playlists in every other controller (the official app
/// doesn't know the prefix) — see `purgeLegacySpeakerSnapshots`.
///
/// This type holds only state + retention policy + persistence of the index.
/// The queue reads, track storage, and restore enqueue live in
/// `SonosManager` / `SavedQueueRepository`. Keeping them apart leaves this
/// unit pure and unit-testable (SRP), and means the retention math can be
/// exercised without a live household or a database.
import Foundation

/// One recoverable queue state. `localID` is the `SavedQueueRepository` row
/// holding the tracks; nothing is stored speaker-side.
public struct QueueSnapshot: Codable, Equatable, Identifiable {
    public let localID: Int64
    public let savedAt: Date
    public let trackCount: Int
    /// Human label for the history list, e.g. "47 tracks · The Bends".
    public let summary: String

    public var id: Int64 { localID }

    public init(localID: Int64, savedAt: Date, trackCount: Int, summary: String) {
        self.localID = localID
        self.savedAt = savedAt
        self.trackCount = trackCount
        self.summary = summary
    }
}

/// Ring-buffer index of snapshots keyed by group-coordinator ID, persisted
/// to `UserDefaults` so the history list survives an app restart (the track
/// rows live in the saved-queue database).
@MainActor
public final class QueueHistoryStore: ObservableObject {
    /// Name prefix for snapshot rows — and for the legacy speaker-side saved
    /// queues that versions ≤4.12 created, which `isHistoryTitle` still
    /// filters out of browse/playlist UI until the one-time purge removes them.
    public static let titlePrefix = "__cghist__"

    /// Retention depth per coordinator. Older snapshots beyond this are
    /// pruned (and their database rows deleted).
    public static let maxDepth = 5

    @Published public private(set) var snapshotsByCoordinator: [String: [QueueSnapshot]] = [:]

    private let defaults: UserDefaults
    /// v2: snapshots moved from speaker-side saved queues (`objectID`) to
    /// local database rows (`localID`). The v1 blob is discarded, not
    /// migrated — its speaker-side queues are destroyed by the legacy purge.
    private let storageKey = "choragus.queueHistory.v2"
    private let legacyStorageKey = "choragus.queueHistory.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.removeObject(forKey: legacyStorageKey)
        load()
    }

    /// True when a saved-queue title is an internal history snapshot, not a
    /// user playlist. Used to exclude snapshots from browse / playlist UI
    /// and to identify legacy speaker-side snapshots for the purge.
    public static func isHistoryTitle(_ title: String) -> Bool {
        title.hasPrefix(titlePrefix)
    }

    /// The row name to use when saving a snapshot. Encodes the epoch so
    /// concurrent saves across coordinators never collide.
    public static func snapshotTitle(at date: Date) -> String {
        "\(titlePrefix)\(Int(date.timeIntervalSince1970))"
    }

    public func snapshots(for coordinatorID: String) -> [QueueSnapshot] {
        snapshotsByCoordinator[coordinatorID] ?? []
    }

    /// Registers a freshly-created snapshot at the head of the ring buffer.
    /// Returns the row IDs that fell off the end and must be deleted from
    /// the database by the caller. Newest-first ordering.
    @discardableResult
    public func register(_ snapshot: QueueSnapshot, for coordinatorID: String) -> [Int64] {
        var list = snapshotsByCoordinator[coordinatorID] ?? []
        list.removeAll { $0.localID == snapshot.localID }
        list.insert(snapshot, at: 0)
        let overflow = list.count > Self.maxDepth ? Array(list[Self.maxDepth...]) : []
        if !overflow.isEmpty { list.removeLast(list.count - Self.maxDepth) }
        snapshotsByCoordinator[coordinatorID] = list
        persist()
        return overflow.map(\.localID)
    }

    /// Drops a snapshot from the index after its database row is deleted.
    public func remove(localID: Int64, for coordinatorID: String) {
        guard var list = snapshotsByCoordinator[coordinatorID] else { return }
        list.removeAll { $0.localID == localID }
        snapshotsByCoordinator[coordinatorID] = list
        persist()
    }

    /// Every row ID the index currently tracks, across all coordinators.
    /// The purge uses this to garbage-collect orphaned snapshot rows.
    public func allTrackedLocalIDs() -> Set<Int64> {
        Set(snapshotsByCoordinator.values.flatMap { $0.map(\.localID) })
    }

    // MARK: - Persistence

    private func load() {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: [QueueSnapshot]].self, from: data)
        else { return }
        snapshotsByCoordinator = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(snapshotsByCoordinator) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
