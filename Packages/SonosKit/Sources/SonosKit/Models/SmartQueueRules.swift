/// SmartQueueRules.swift — Turns play history into the three smart queues.
///
/// Most Played, Recently Played and Starred are the same history table read
/// three ways:
///
/// - **Room scoping** matches by token membership, not string equality. An
///   entry recorded while "Office + Float" were grouped belongs to a selection
///   of "Office", because that speaker did play it. Comparing the strings
///   would hide every grouped listen from a per-room filter.
/// - **Distinctness** is by title and artist, case-insensitively, not by URI.
///   The same song resolved from two services, or a service URL that rotated
///   its token, is one song to a listener.
/// - **Most Played** counts only the last 30 days, and ranks by play count
///   with the first-seen entry as the representative row.
import Foundation

public enum SmartQueueRules {

    public static let mostPlayedWindow: TimeInterval = 30 * 24 * 3600

    /// True when a history entry belongs to the selected room.
    ///
    /// `nil` or empty selects everything. Otherwise every token of the
    /// selection must appear in the entry's grouping, so "Office" matches an
    /// entry recorded as "Office + Float" but "Office + Kitchen" does not.
    public static func entryMatchesRoom(groupName: String, room: String?) -> Bool {
        guard let room, !room.isEmpty else { return true }
        let selected = room.components(separatedBy: " + ")
        let members = groupName.components(separatedBy: " + ")
        return selected.allSatisfy { members.contains($0) }
    }

    /// Identity used for de-duplication: one song, however it was sourced.
    public static func trackKey(title: String, artist: String) -> String {
        "\(title.lowercased())\u{1F}\(artist.lowercased())"
    }

    /// Ranks entries for Most Played: the last 30 days only, ordered by play
    /// count, each song represented by the first entry seen for it.
    ///
    /// - Parameter now: injected so the window is testable without waiting.
    public static func rankByPlayCount<Entry>(_ entries: [Entry],
                                              now: Date = Date(),
                                              timestamp: (Entry) -> Date,
                                              title: (Entry) -> String,
                                              artist: (Entry) -> String) -> [Entry] {
        let cutoff = now.addingTimeInterval(-mostPlayedWindow)
        var counts: [String: Int] = [:]
        var representative: [String: Entry] = [:]
        var firstSeen: [String: Int] = [:]
        var order: [String] = []
        for entry in entries where timestamp(entry) >= cutoff && !title(entry).isEmpty {
            let key = trackKey(title: title(entry), artist: artist(entry))
            counts[key, default: 0] += 1
            if representative[key] == nil {
                representative[key] = entry
                firstSeen[key] = order.count
                order.append(key)
            }
        }
        // Ties keep first-seen order rather than dictionary order, so the same
        // history always produces the same queue. The first-seen position is
        // looked up, not searched: an `order.firstIndex(of:)` inside the
        // comparator is quadratic (~700 ms per call on a 13k-row history).
        return order
            .sorted { lhs, rhs in
                let l = counts[lhs] ?? 0, r = counts[rhs] ?? 0
                if l != r { return l > r }
                return (firstSeen[lhs] ?? 0) < (firstSeen[rhs] ?? 0)
            }
            .compactMap { representative[$0] }
    }

    /// Keeps the first entry for each distinct song, up to `limit`, skipping
    /// entries with no playable URI or no title.
    public static func distinct<Entry>(_ entries: [Entry],
                                       limit: Int,
                                       uri: (Entry) -> String?,
                                       title: (Entry) -> String,
                                       artist: (Entry) -> String) -> [Entry] {
        var seen = Set<String>()
        var out: [Entry] = []
        for entry in entries {
            guard let uri = uri(entry), !uri.isEmpty, !title(entry).isEmpty else { continue }
            guard seen.insert(trackKey(title: title(entry), artist: artist(entry))).inserted else { continue }
            out.append(entry)
            if out.count >= limit { break }
        }
        return out
    }
}
