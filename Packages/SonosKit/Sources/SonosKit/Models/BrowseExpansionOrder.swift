/// BrowseExpansionOrder.swift — Rules for walking a browse container.
///
/// "Add All" on an artist, folder or playlist walks the hierarchy depth-first
/// and collects playable leaves. Two rules decide the result:
///
/// - **Walk order.** Containers are visited before loose tracks at the same
///   level, and both sort alphabetically, so the queue arrives in an order the
///   user can predict from the screen.
/// - **Except inside an album or playlist**, where the order the speaker
///   returned *is* the track order. Sorting those alphabetically would
///   shuffle albums into title order.
///
/// A container whose title ends in a playlist-file extension is skipped: Sonos
/// presents `.m3u` and friends as browsable containers, and descending into
/// one duplicates tracks already collected from the folder beside it.
import Foundation

public enum BrowseExpansionOrder {

    /// Depth ceiling for the recursive walk. Local-library hierarchies run to
    /// three levels (Artist → Album → Track); this is slack against a
    /// pathological or cyclic structure rather than a real limit.
    public static let maxDepth = 6

    /// Extensions Sonos exposes as containers but which hold tracks already
    /// reachable from the folder beside them.
    private static let playlistFileExtensions = [".m3u", ".m3u8", ".pls", ".cue"]

    /// True when this container's own order is meaningful and must survive.
    public static func preservesLeafOrder(_ item: BrowseItem) -> Bool {
        item.itemClass == .musicAlbum || item.itemClass == .playlist
    }

    /// True when descending into this container would duplicate tracks.
    public static func isPlaylistFileContainer(_ item: BrowseItem) -> Bool {
        let lowered = item.title.lowercased()
        return playlistFileExtensions.contains { lowered.hasSuffix($0) }
    }

    /// Children in the order they should be walked: containers first, then
    /// leaves, each alphabetical unless the parent's own order must survive.
    public static func walkOrder(children: [BrowseItem],
                                 preserveLeafOrder: Bool) -> [BrowseItem] {
        let byTitle: (BrowseItem, BrowseItem) -> Bool = {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        let containers = children.filter(\.isContainer).sorted(by: byTitle)
        var leaves = children.filter { !$0.isContainer }
        if !preserveLeafOrder { leaves.sort(by: byTitle) }
        return containers + leaves
    }

    /// Whether the walk should stop before visiting this child.
    public static func shouldStop(collected: Int, maxLeaves: Int, cancelled: Bool) -> Bool {
        cancelled || collected >= maxLeaves
    }

    /// Whether the walk may descend past this depth.
    public static func canDescend(to depth: Int) -> Bool { depth <= maxDepth }
}
