/// AudioFormatMemory.swift — Per-group memory of recent tracks'
/// format evidence, keyed by track URI.
///
/// The speaker broadcasts `r:streamInfo` only at track transitions.
/// When a transient bogus publish interrupts a track (#47-class
/// HLS-static leak: a different song id with `flags=0` flashes in and
/// straight back out), the flip-back registers as a track change, the
/// sticky carry-over is skipped, and the returning track is left at
/// `.unknown` with no rebroadcast coming — the format pills vanish
/// mid-track. Restoring remembered evidence by URI heals any
/// flip-back, whatever caused it.
import Foundation

struct AudioFormatMemory {
    /// Remembered evidence per group, most recent last. Bounded so a
    /// long radio session can't grow it unbounded.
    private var entries: [String: [(uri: String, format: AudioFormat, streamInfo: String)]] = [:]

    /// Distinct URIs remembered per group. Generous enough for a
    /// flip-back plus a few interleaved publishes; small enough to be
    /// irrelevant memory-wise.
    private static let perGroupCap = 8

    /// Records format evidence for a URI. Known formats only —
    /// remembering `.unknown` would overwrite real evidence.
    mutating func remember(group: String, uri: String,
                           format: AudioFormat, streamInfo: String) {
        guard format != .unknown, !uri.isEmpty else { return }
        var list = entries[group] ?? []
        list.removeAll { $0.uri == uri }
        list.append((uri, format, streamInfo))
        if list.count > Self.perGroupCap {
            list.removeFirst(list.count - Self.perGroupCap)
        }
        entries[group] = list
    }

    /// Evidence previously recorded for this URI, if any.
    func recall(group: String, uri: String) -> (format: AudioFormat, streamInfo: String)? {
        entries[group]?.last { $0.uri == uri }
            .map { ($0.format, $0.streamInfo) }
    }
}
