/// Split publishers for the high-churn playhead state.
///
/// These were `@Published` properties on `SonosManager` until the
/// karaoke-stutter investigation traced 70-85 ms main-thread stalls to
/// every 1 s position poll firing `SonosManager.objectWillChange` and
/// forcing every view observing the manager (karaoke window, club vis,
/// now-playing panel, etc.) to re-evaluate its body — even views that
/// don't care about position. The architectural fix is to split the
/// high-churn state out so the karaoke window only observes the
/// publisher whose changes actually matter to it.
///
/// - `PositionTracker` publishes for every position/duration update
///   (~1 Hz during playback). Views observe it only when they need
///   second-by-second time display (now-playing seek bar text).
/// - `AnchorTracker` publishes only when the playhead anchor rebases
///   (drift threshold exceeded, play/pause flipped, seek, track
///   change) — rare. The karaoke window observes only this one; its
///   `TimelineView(.animation)` projects forward from the anchor
///   per-frame without any SwiftUI re-evaluation between anchors.
import Foundation
import Combine

@MainActor
public final class PositionTracker: ObservableObject {
    @Published public var groupPositions: [String: TimeInterval] = [:]
    @Published public var groupDurations: [String: TimeInterval] = [:]

    public init() {}
}

@MainActor
public final class AnchorTracker: ObservableObject {
    @Published public var groupPositionAnchors: [String: PositionAnchor] = [:]

    public init() {}
}
