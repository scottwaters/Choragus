/// QueueScrollAnchor.swift — Decides which queue row to scroll to the top.
///
/// The queue panel follows the speaker: as tracks change, the row *before* the
/// playing one is pinned to the top, so the playing track sits second and the
/// user can see what just finished as well as what is next. At the head of the
/// queue there is no previous row, so the playing track takes the top itself.
///
/// Near the end of the queue there are not enough rows below to push the
/// anchor to the top and the list scrolls as far as it can, so this returns
/// the row to *request*, not the row that ends up on top.
///
/// `ScrollViewReader.scrollTo` is a silent no-op for rows the `LazyVStack`
/// has not materialised.
import Foundation

public enum QueueScrollAnchor {

    /// The row id to request, or nil when no scroll should happen.
    ///
    /// - Parameters:
    ///   - currentTrack: 1-based position of the playing row, 0 when nothing
    ///     in the queue is playing.
    ///   - queueCount: rows currently loaded.
    public static func target(currentTrack: Int, queueCount: Int) -> Int? {
        guard currentTrack > 0, queueCount > 0 else { return nil }
        // The first track has no predecessor to pin, so it anchors itself.
        return currentTrack > 1 ? currentTrack - 1 : currentTrack
    }

    /// Whether the initial scroll should run for this state.
    ///
    /// At launch `isQueueSource` can flip true *after* `currentTrack` and
    /// the rows are already set, and neither of those watchers fires again
    /// for that flip; without this the queue stays at the top mid-queue.
    public static func shouldPerformInitialScroll(hasScrolledAlready: Bool,
                                                  isPlayingFromQueue: Bool,
                                                  currentTrack: Int,
                                                  queueCount: Int) -> Bool {
        guard !hasScrolledAlready, isPlayingFromQueue else { return false }
        return target(currentTrack: currentTrack, queueCount: queueCount) != nil
    }
}
