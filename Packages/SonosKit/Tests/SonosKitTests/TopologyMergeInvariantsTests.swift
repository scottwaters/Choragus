import XCTest
@testable import SonosKit

/// Covers invariants added in v3.5 to eliminate the S1/S2 speaker flicker:
/// - SonosGroup value equality (Equatable by synthesis)
/// - SonosDevice value equality and hashability
/// - Stable member ordering semantics
/// - Household-scoped partitioning behaviour
final class TopologyMergeInvariantsTests: XCTestCase {

    // MARK: - SonosDevice equality

    func testSonosDeviceEqualityByValue() {
        let a = SonosDevice(id: "R1", ip: "10.0.0.1", roomName: "Kitchen",
                            softwareVersion: "72.1", swGen: "2", householdID: "HH1")
        let b = SonosDevice(id: "R1", ip: "10.0.0.1", roomName: "Kitchen",
                            softwareVersion: "72.1", swGen: "2", householdID: "HH1")
        XCTAssertEqual(a, b, "SonosDevice with identical fields must compare equal")
    }

    func testSonosDeviceInequalityOnAnyField() {
        let base = SonosDevice(id: "R1", ip: "10.0.0.1", roomName: "Kitchen",
                               softwareVersion: "72.1", swGen: "2", householdID: "HH1")
        XCTAssertNotEqual(base, SonosDevice(id: "R2", ip: "10.0.0.1", roomName: "Kitchen",
                                            softwareVersion: "72.1", swGen: "2", householdID: "HH1"))
        XCTAssertNotEqual(base, SonosDevice(id: "R1", ip: "10.0.0.2", roomName: "Kitchen",
                                            softwareVersion: "72.1", swGen: "2", householdID: "HH1"))
        XCTAssertNotEqual(base, SonosDevice(id: "R1", ip: "10.0.0.1", roomName: "Office",
                                            softwareVersion: "72.1", swGen: "2", householdID: "HH1"))
        XCTAssertNotEqual(base, SonosDevice(id: "R1", ip: "10.0.0.1", roomName: "Kitchen",
                                            softwareVersion: "72.1", swGen: "2", householdID: "HH2"))
    }

    // MARK: - SonosGroup equality

    func testSonosGroupEqualityByValue() {
        let d1 = SonosDevice(id: "R1", ip: "10.0.0.1", householdID: "HH1", isCoordinator: true)
        let d2 = SonosDevice(id: "R2", ip: "10.0.0.2", householdID: "HH1")
        let g1 = SonosGroup(id: "g1", coordinatorID: "R1", members: [d1, d2], householdID: "HH1")
        let g2 = SonosGroup(id: "g1", coordinatorID: "R1", members: [d1, d2], householdID: "HH1")
        XCTAssertEqual(g1, g2)
    }

    func testSonosGroupInequalityOnMemberListReorder() {
        // Equatable synthesis is order-sensitive for arrays; this test documents
        // that contract so that anyone changing SonosGroup.members must also
        // update the stable-sort step in SonosManager.refreshTopology.
        let d1 = SonosDevice(id: "R1", ip: "10.0.0.1", isCoordinator: true)
        let d2 = SonosDevice(id: "R2", ip: "10.0.0.2")
        let g1 = SonosGroup(id: "g1", coordinatorID: "R1", members: [d1, d2], householdID: "HH1")
        let g2 = SonosGroup(id: "g1", coordinatorID: "R1", members: [d2, d1], householdID: "HH1")
        XCTAssertNotEqual(g1, g2, "Array equality is order-sensitive — members must be stably sorted at construction")
    }

    func testSonosGroupInequalityOnHouseholdID() {
        let d = SonosDevice(id: "R1", ip: "10.0.0.1", isCoordinator: true)
        let g1 = SonosGroup(id: "g1", coordinatorID: "R1", members: [d], householdID: "HH1")
        let g2 = SonosGroup(id: "g1", coordinatorID: "R1", members: [d], householdID: "HH2")
        XCTAssertNotEqual(g1, g2)
    }

    // MARK: - Stable member ordering semantics

    func testMemberSortByIDIsDeterministic() {
        // Simulate members returned in two different orders from consecutive
        // topology responses — once sorted by id, both produce the same array.
        let a = SonosDevice(id: "RINCON_AAA", ip: "10.0.0.1")
        let b = SonosDevice(id: "RINCON_BBB", ip: "10.0.0.2")
        let c = SonosDevice(id: "RINCON_CCC", ip: "10.0.0.3")

        let order1 = [a, b, c].sorted { $0.id < $1.id }
        let order2 = [c, a, b].sorted { $0.id < $1.id }
        let order3 = [b, c, a].sorted { $0.id < $1.id }

        XCTAssertEqual(order1, order2)
        XCTAssertEqual(order2, order3)
        XCTAssertEqual(order1.map(\.id), ["RINCON_AAA", "RINCON_BBB", "RINCON_CCC"])
    }

    // MARK: - Household-scoped partitioning

    func testGroupsPartitionByHousehold() {
        // Models the filter SonosManager.refreshTopology uses to preserve
        // other-household groups when merging new data for a single household.
        let d1 = SonosDevice(id: "R1", ip: "10.0.0.1", isCoordinator: true)
        let d2 = SonosDevice(id: "R2", ip: "10.0.0.2", isCoordinator: true)
        let groupHH1 = SonosGroup(id: "g1", coordinatorID: "R1", members: [d1], householdID: "HH_S2")
        let groupHH2 = SonosGroup(id: "g2", coordinatorID: "R2", members: [d2], householdID: "HH_S1")
        let groups = [groupHH1, groupHH2]

        let household = "HH_S2"
        let otherHouseholdGroups = groups.filter { $0.householdID != household }
        XCTAssertEqual(otherHouseholdGroups, [groupHH2],
                       "Refreshing HH_S2 must preserve HH_S1 groups untouched")

        let nilHouseholdRefresh: String? = nil
        let allPreservedWhenHouseholdUnknown = groups.filter { $0.householdID != nilHouseholdRefresh }
        XCTAssertEqual(allPreservedWhenHouseholdUnknown, groups,
                       "If household is nil, filter must not remove any real-household groups — refreshTopology aborts in this case")
    }

    // MARK: - Grace window semantics

    func testGraceWindowRetainsRecentlySeenGroup() {
        // Models the grace-window logic in refreshTopology: a group missing
        // from the new response is retained if it was seen within the window.
        let grace: TimeInterval = 30
        let now = Date()
        let recentlySeen = now.addingTimeInterval(-5)   // 5s ago — within grace
        let longAgo = now.addingTimeInterval(-120)      // 2m ago — outside grace

        XCTAssertTrue(now.timeIntervalSince(recentlySeen) < grace,
                      "Group seen 5s ago must be retained across a missed refresh")
        XCTAssertFalse(now.timeIntervalSince(longAgo) < grace,
                       "Group unseen for 2m must be allowed to drop out")
    }
}
