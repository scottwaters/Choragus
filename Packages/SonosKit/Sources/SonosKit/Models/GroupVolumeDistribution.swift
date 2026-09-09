/// GroupVolumeDistribution.swift — Spreads a master volume across a group.
///
/// The master slider does not set one value: it moves every speaker in the
/// group while preserving the relationship between them. Two modes:
///
/// - **Proportional** — each speaker keeps its ratio to the master. Members at
///   30 and 40 with a master of 35 become 60 and 80 when the master reaches 70.
///   Loud rooms stay loud relative to quiet ones.
/// - **Linear** — every speaker shifts by the same delta. The same members
///   become 65 and 75, closing the gap in proportion but keeping it absolute.
///
/// Both compute against an immutable drag-start snapshot rather than the
/// running values: clamping a member at 0 or 100 during a drag must not
/// poison the next tick, so dragging back down recovers the original spread.
import Foundation

public enum GroupVolumeDistribution {

    public enum Mode: Equatable {
        case proportional
        case linear
    }

    /// The state a drag started from. Volumes are per member id.
    public struct Snapshot: Equatable {
        public let master: Double
        public let volumes: [String: Double]

        public init(master: Double, volumes: [String: Double]) {
            self.master = master
            self.volumes = volumes
        }
    }

    /// Per-member targets for a master position, clamped to 0...100.
    ///
    /// - Parameters:
    ///   - master: where the master slider now sits.
    ///   - memberIDs: the group's members, in the order they should be written.
    ///   - snapshot: the immutable drag-start state.
    ///   - mode: proportional or linear.
    public static func targets(master: Double,
                               memberIDs: [String],
                               snapshot: Snapshot,
                               mode: Mode) -> [String: Int] {
        // The extremes are absolute: 0 silences everything and 100 drives
        // everything to maximum, whatever the spread was. The snapshot is left
        // untouched, so leaving the extreme restores the original spread.
        let absolute: Int?
        if master <= 0 { absolute = 0 }
        else if master >= 100 { absolute = 100 }
        else { absolute = nil }

        var result: [String: Int] = [:]
        for id in memberIDs {
            if let absolute {
                result[id] = absolute
                continue
            }
            let original = snapshot.volumes[id] ?? snapshot.master
            let raw: Double
            switch mode {
            case .proportional where snapshot.master > 0:
                raw = original * (master / snapshot.master)
            case .proportional:
                // The snapshot master was 0, so there is no ratio to keep.
                // Driving everyone to the new master is the only defined
                // answer; dividing by zero would give infinity or NaN.
                raw = master
            case .linear:
                raw = original + (master - snapshot.master)
            }
            result[id] = Int(max(0, min(100, raw)))
        }
        return result
    }

    /// The snapshot to adopt after the master has been held at zero long
    /// enough to level the group. Every member rises together from here
    /// instead of returning to its previous offset.
    public static func levelledSnapshot(memberIDs: [String]) -> Snapshot {
        Snapshot(master: 0,
                 // `uniquingKeysWith`, not `uniqueKeysWithValues`: the latter
                 // traps on a duplicate key, and a topology payload that lists
                 // a member twice must not crash the process.
                 volumes: Dictionary(memberIDs.map { ($0, 0.0) },
                                     uniquingKeysWith: { first, _ in first }))
    }
}
