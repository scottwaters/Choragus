/// Merges a bonded set's per-member `HTSatChanMapSet` views into the zone's
/// channel layout. Each satellite advertises only the soundbar and itself,
/// so reading one member's value loses the channels it cannot see (#78).
import Foundation

public enum HomeTheaterChannelMap {

    /// Returns device id → channel, ordered by channel then id so the result
    /// is stable across enumeration order. Unrecognised tokens are skipped:
    /// a wrong channel is worse than a missing one.
    public static func merge(memberMapSets: [String]) -> [(String, SpeakerChannel)] {
        var byDevice: [String: SpeakerChannel] = [:]
        for mapSet in memberMapSets where !mapSet.isEmpty {
            for pair in mapSet.components(separatedBy: ";") {
                let parts = pair.components(separatedBy: ":")
                guard parts.count == 2,
                      let channel = SpeakerChannel(rawValue: parts[1]) else { continue }
                byDevice[parts[0]] = channel
            }
        }
        return byDevice
            .map { ($0.key, $0.value) }
            .sorted { lhs, rhs in
                lhs.1.sortOrder == rhs.1.sortOrder ? lhs.0 < rhs.0
                                                   : lhs.1.sortOrder < rhs.1.sortOrder
            }
    }
}
