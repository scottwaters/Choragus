/// GroupDropDecision.swift — Decides what a sidebar drag-and-drop should do.
///
/// Dragging one room onto another groups them; dragging onto the strip below
/// the list splits a group apart. A drop can name a group that has since
/// disappeared, target itself, cross two households, or split a room that is
/// already standalone. Each is refused before a SOAP call goes out, because
/// the speaker answers an illegal join with a fault and the user sees nothing.
import Foundation

public enum GroupDropDecision {

    /// What a drop onto another group should do.
    public enum Join: Equatable {
        /// Join every member of the source group to this coordinator.
        case join(members: [String], toCoordinator: String, selecting: String)
        case refuse(JoinRefusal)
    }

    public enum JoinRefusal: Equatable {
        /// The dragged group is the drop target.
        case sameGroup
        /// The dragged group is no longer in the topology.
        case unknownSource
        /// The target has no coordinator to join to.
        case targetHasNoCoordinator
        /// Sonos cannot group across households, and the speaker would fault.
        case differentHousehold
    }

    /// What a drop onto the ungroup strip should do.
    public enum Split: Equatable {
        /// Detach these members, leaving the coordinator where it is.
        case ungroup(members: [String])
        case refuse(SplitRefusal)
    }

    public enum SplitRefusal: Equatable {
        case unknownSource
        /// A single-speaker group has nothing to split.
        case alreadyStandalone
    }

    /// Decides a room-onto-room drop.
    public static func join(sourceID: String,
                            target: SonosGroup,
                            groups: [SonosGroup]) -> Join {
        guard sourceID != target.id else { return .refuse(.sameGroup) }
        guard let source = groups.first(where: { $0.id == sourceID }) else {
            return .refuse(.unknownSource)
        }
        guard let coordinator = target.coordinator else {
            return .refuse(.targetHasNoCoordinator)
        }
        guard source.householdID == target.householdID else {
            return .refuse(.differentHousehold)
        }
        return .join(members: source.members.map(\.id),
                     toCoordinator: coordinator.id,
                     selecting: target.id)
    }

    /// Decides a room-onto-ungroup-strip drop. The coordinator stays put and
    /// keeps playing; the other members become standalone rooms.
    public static func split(sourceID: String, groups: [SonosGroup]) -> Split {
        guard let source = groups.first(where: { $0.id == sourceID }) else {
            return .refuse(.unknownSource)
        }
        guard source.members.count > 1 else { return .refuse(.alreadyStandalone) }
        return .ungroup(members: source.members
            .filter { $0.id != source.coordinatorID }
            .map(\.id))
    }
}
