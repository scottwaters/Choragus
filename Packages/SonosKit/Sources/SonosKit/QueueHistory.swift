/// QueueHistory.swift — Per-coordinator ring buffer of queue snapshots.
///
/// A snapshot is a Sonos server-side saved queue (`SaveQueue` → `SQ:N`)
/// captured immediately BEFORE a destructive queue mutation (replace-all,
/// clear, bulk remove). Restoring one re-enqueues that saved queue, so an
/// accidental "play this now" that wiped a 50-track queue is recoverable.
///
/// This type holds only state + retention policy + persistence. It performs
/// NO networking — the SOAP `SaveQueue` / `DestroyObject` / enqueue calls
/// live in `SonosManager`, which owns the speaker connection. Keeping the
/// two apart leaves this unit pure and unit-testable (SRP), and means the
/// retention math can be exercised without a live household.
import Foundation

/// One recoverable queue state. `objectID` is the Sonos saved-queue handle
/// (`SQ:N`); the tracks themselves live on the speaker, not here.
public struct QueueSnapshot: Codable, Equatable, Identifiable {
    public let objectID: String
    public let savedAt: Date
    public let trackCount: Int
    /// Human label for the history list, e.g. "47 tracks · The Bends".
    public let summary: String

    public var id: String { objectID }

    public init(objectID: String, savedAt: Date, trackCount: Int, summary: String) {
        self.objectID = objectID
        self.savedAt = savedAt
        self.trackCount = trackCount
        self.summary = summary
    }
}

/// Ring-buffer store of snapshots keyed by group-coordinator ID, persisted
/// to `UserDefaults` so the history list survives an app restart (the saved
/// queues it points at already persist on the speaker).
@MainActor
public final class QueueHistoryStore: ObservableObject {
    /// Title prefix for the speaker-side saved queue. The prefix is how
    /// every UI list that enumerates saved queues / playlists filters
    /// these internal snapshots back out — see `isHistoryTitle`.
    public static let titlePrefix = "__cghist__"

    /// Retention depth per coordinator. Older snapshots beyond this are
    /// pruned (and their speaker-side saved queue destroyed).
    public static let maxDepth = 5

    @Published public private(set) var snapshotsByCoordinator: [String: [QueueSnapshot]] = [:]

    private let defaults: UserDefaults
    private let storageKey = "choragus.queueHistory.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    /// True when a saved-queue title is an internal history snapshot, not a
    /// user playlist. Used to exclude snapshots from browse / playlist UI.
    public static func isHistoryTitle(_ title: String) -> Bool {
        title.hasPrefix(titlePrefix)
    }

    /// The speaker-side title to use when saving a snapshot. Encodes the
    /// epoch so concurrent saves across coordinators never collide.
    public static func snapshotTitle(at date: Date) -> String {
        "\(titlePrefix)\(Int(date.timeIntervalSince1970))"
    }

    public func snapshots(for coordinatorID: String) -> [QueueSnapshot] {
        snapshotsByCoordinator[coordinatorID] ?? []
    }

    /// Registers a freshly-created snapshot at the head of the ring buffer.
    /// Returns the objectIDs that fell off the end and must be destroyed
    /// speaker-side by the caller. Newest-first ordering.
    @discardableResult
    public func register(_ snapshot: QueueSnapshot, for coordinatorID: String) -> [String] {
        var list = snapshotsByCoordinator[coordinatorID] ?? []
        list.removeAll { $0.objectID == snapshot.objectID }
        list.insert(snapshot, at: 0)
        let overflow = list.count > Self.maxDepth ? Array(list[Self.maxDepth...]) : []
        if !overflow.isEmpty { list.removeLast(list.count - Self.maxDepth) }
        snapshotsByCoordinator[coordinatorID] = list
        persist()
        return overflow.map(\.objectID)
    }

    /// Drops a snapshot from the index after its speaker-side queue is
    /// consumed or destroyed.
    public func remove(objectID: String, for coordinatorID: String) {
        guard var list = snapshotsByCoordinator[coordinatorID] else { return }
        list.removeAll { $0.objectID == objectID }
        snapshotsByCoordinator[coordinatorID] = list
        persist()
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
