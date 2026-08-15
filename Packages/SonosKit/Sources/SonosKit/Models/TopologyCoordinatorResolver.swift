/// Picks the coordinator a group is controlled through when the topology's
/// own answer names a device that is not a visible member (#83). Such a
/// group otherwise resolves to no coordinator: no transport command, no
/// state, while its speakers keep emitting events.
import Foundation

public enum TopologyCoordinatorResolver {

    public struct Resolution: Equatable {
        public let coordinatorID: String
        /// True when `coordinatorID` is a substitute. Callers log these.
        public let substituted: Bool
    }

    /// Prefers the coordinator the group was last controlled through, then
    /// the lowest visible id — stable across refreshes, so a transient bad
    /// topology cannot re-target transport commands on every event.
    public static func resolve(reported: String,
                               visibleMemberIDs: [String],
                               previouslyKnownCoordinator: String? = nil) -> Resolution {
        if visibleMemberIDs.contains(reported) {
            return Resolution(coordinatorID: reported, substituted: false)
        }
        if let previous = previouslyKnownCoordinator,
           visibleMemberIDs.contains(previous) {
            return Resolution(coordinatorID: previous, substituted: true)
        }
        // All-bonded group: nothing to substitute.
        guard let fallback = visibleMemberIDs.min() else {
            return Resolution(coordinatorID: reported, substituted: false)
        }
        return Resolution(coordinatorID: fallback, substituted: true)
    }
}
