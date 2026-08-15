import XCTest
@testable import SonosKit

/// Coverage for the #83 failure: a group whose reported coordinator is
/// not one of its visible members resolves to no coordinator at all,
/// leaving the group uncontrollable while its speakers keep emitting
/// UPnP events.
final class TopologyCoordinatorResolverTests: XCTestCase {

    func testReportedCoordinatorIsKeptWhenVisible() {
        let resolution = TopologyCoordinatorResolver.resolve(
            reported: "RINCON_0002",
            visibleMemberIDs: ["RINCON_0001", "RINCON_0002", "RINCON_0003"])
        XCTAssertEqual(resolution.coordinatorID, "RINCON_0002")
        XCTAssertFalse(resolution.substituted)
    }

    func testCoordinatorNotAmongVisibleMembersIsSubstituted() {
        // The reported coordinator is a bonded satellite — invisible, so
        // it never reaches `SonosGroup.members`.
        let resolution = TopologyCoordinatorResolver.resolve(
            reported: "RINCON_SUB",
            visibleMemberIDs: ["RINCON_0003", "RINCON_0001"])
        XCTAssertTrue(resolution.substituted)
        XCTAssertEqual(resolution.coordinatorID, "RINCON_0001",
                       "Substitution must pick the lowest id so the choice "
                       + "is stable across topology refreshes")
    }

    func testSubstitutionIsStableAcrossMemberOrdering() {
        let ids = ["RINCON_0003", "RINCON_0001", "RINCON_0002"]
        let first = TopologyCoordinatorResolver.resolve(reported: "RINCON_GONE",
                                                        visibleMemberIDs: ids)
        let second = TopologyCoordinatorResolver.resolve(reported: "RINCON_GONE",
                                                         visibleMemberIDs: ids.reversed())
        XCTAssertEqual(first, second)
    }

    func testAllBondedGroupKeepsReportedCoordinator() {
        // No visible members: nothing can be substituted, and inventing a
        // coordinator would be worse than leaving the reported value.
        let resolution = TopologyCoordinatorResolver.resolve(
            reported: "RINCON_0001", visibleMemberIDs: [])
        XCTAssertEqual(resolution.coordinatorID, "RINCON_0001")
        XCTAssertFalse(resolution.substituted)
    }
}

// MARK: - Substitution prefers a coordinator that really was one

extension TopologyCoordinatorResolverTests {

    func testPreviouslyKnownCoordinatorWinsOverLowestID() {
        // A transient malformed topology must not re-target transport
        // commands at a member that never coordinated.
        let resolution = TopologyCoordinatorResolver.resolve(
            reported: "RINCON_GONE",
            visibleMemberIDs: ["RINCON_0001", "RINCON_0002"],
            previouslyKnownCoordinator: "RINCON_0002")
        XCTAssertTrue(resolution.substituted)
        XCTAssertEqual(resolution.coordinatorID, "RINCON_0002")
    }

    func testPreviousCoordinatorIgnoredWhenNoLongerVisible() {
        let resolution = TopologyCoordinatorResolver.resolve(
            reported: "RINCON_GONE",
            visibleMemberIDs: ["RINCON_0003", "RINCON_0001"],
            previouslyKnownCoordinator: "RINCON_LEFT_THE_GROUP")
        XCTAssertEqual(resolution.coordinatorID, "RINCON_0001")
    }
}
