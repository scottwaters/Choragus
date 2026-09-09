/// QueuePlaytime.swift — Estimated running time of a list of queue rows.
///
/// Durations arrive as strings off the speaker and are stored that way, and
/// not every row carries one (Sonos playlists browsed as items, radio
/// streams, rows saved before the column existed). The estimate sums what
/// is known and says how much was not, so the readout can be marked as
/// partial instead of silently under-reporting.
import Foundation

public struct QueuePlaytime: Equatable {
    /// Sum of the rows whose duration parsed.
    public let knownSeconds: TimeInterval
    /// Rows whose duration was missing or unparseable.
    public let unknownCount: Int
    /// Rows the estimate did not see at all (queue pages not yet loaded).
    public let unloadedCount: Int

    public init(knownSeconds: TimeInterval, unknownCount: Int, unloadedCount: Int = 0) {
        self.knownSeconds = knownSeconds
        self.unknownCount = unknownCount
        self.unloadedCount = unloadedCount
    }

    /// Nothing parsed — there is no figure worth showing.
    public var isEmpty: Bool { knownSeconds <= 0 }

    /// Some rows were not counted, so the figure is a lower bound.
    public var isPartial: Bool { unknownCount > 0 || unloadedCount > 0 }

    /// `h:mm:ss` / `m:ss`, prefixed with `~` when partial.
    public var label: String {
        (isPartial ? "~" : "") + PlaybackTimeFormat.string(knownSeconds)
    }

    /// - Parameter totalCount: the full row count when `items` is only the
    ///   loaded prefix of a longer queue; defaults to `items.count`.
    public init(items: [QueueItem], totalCount: Int? = nil) {
        var known: TimeInterval = 0
        var unknown = 0
        for item in items {
            if let seconds = PlaybackTimeFormat.seconds(from: item.duration) {
                known += seconds
            } else {
                unknown += 1
            }
        }
        self.init(knownSeconds: known, unknownCount: unknown,
                  unloadedCount: max(0, (totalCount ?? items.count) - items.count))
    }

    /// Playtime still to come: what is left of the current track plus
    /// every row after it. Rows before the current one are not counted.
    /// Unloaded pages all lie past the loaded prefix, so they count as
    /// unloaded here too. A current track outside the loaded rows
    /// yields the whole loaded playtime.
    public static func remaining(items: [QueueItem], currentTrack: Int, elapsed: TimeInterval,
                                 totalCount: Int? = nil) -> QueuePlaytime {
        var known: TimeInterval = 0
        var unknown = 0
        for item in items where item.id >= currentTrack {
            if let seconds = PlaybackTimeFormat.seconds(from: item.duration) {
                known += item.id == currentTrack ? max(0, seconds - max(0, elapsed)) : seconds
            } else {
                unknown += 1
            }
        }
        return QueuePlaytime(knownSeconds: known, unknownCount: unknown,
                             unloadedCount: max(0, (totalCount ?? items.count) - items.count))
    }
}
