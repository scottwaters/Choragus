import XCTest
@testable import SonosKit

/// Master-slider distribution. Computing against the running values instead
/// of the drag-start snapshot flattens a group permanently the first time a
/// member hits 0.
final class GroupVolumeDistributionTests: XCTestCase {

    private let members = ["A", "B"]
    private let spread = GroupVolumeDistribution.Snapshot(
        master: 35, volumes: ["A": 30, "B": 40])

    // MARK: - Proportional

    func testProportionalKeepsEachMembersRatio() {
        let t = GroupVolumeDistribution.targets(
            master: 70, memberIDs: members, snapshot: spread, mode: .proportional)
        XCTAssertEqual(t, ["A": 60, "B": 80])
    }

    func testProportionalHalvingHalvesEveryone() {
        let t = GroupVolumeDistribution.targets(
            master: 17.5, memberIDs: members, snapshot: spread, mode: .proportional)
        XCTAssertEqual(t, ["A": 15, "B": 20])
    }

    /// No ratio exists from a snapshot master of zero. Dividing would give
    /// infinity, and Int(infinity) traps at runtime.
    func testProportionalFromZeroMasterDrivesEveryoneToTheNewMaster() {
        let flat = GroupVolumeDistribution.Snapshot(master: 0, volumes: ["A": 0, "B": 0])
        let t = GroupVolumeDistribution.targets(
            master: 40, memberIDs: members, snapshot: flat, mode: .proportional)
        XCTAssertEqual(t, ["A": 40, "B": 40])
    }

    // MARK: - Linear

    func testLinearShiftsEveryoneByTheSameDelta() {
        let t = GroupVolumeDistribution.targets(
            master: 70, memberIDs: members, snapshot: spread, mode: .linear)
        XCTAssertEqual(t, ["A": 65, "B": 75])
    }

    func testLinearDownwardsPreservesTheGap() {
        let t = GroupVolumeDistribution.targets(
            master: 25, memberIDs: members, snapshot: spread, mode: .linear)
        XCTAssertEqual(t, ["A": 20, "B": 30])
    }

    // MARK: - Extremes

    func testMasterAtZeroSilencesEveryone() {
        for mode in [GroupVolumeDistribution.Mode.proportional, .linear] {
            let t = GroupVolumeDistribution.targets(
                master: 0, memberIDs: members, snapshot: spread, mode: mode)
            XCTAssertEqual(t, ["A": 0, "B": 0], "\(mode)")
        }
    }

    func testMasterAtMaximumDrivesEveryoneToMaximum() {
        for mode in [GroupVolumeDistribution.Mode.proportional, .linear] {
            let t = GroupVolumeDistribution.targets(
                master: 100, memberIDs: members, snapshot: spread, mode: mode)
            XCTAssertEqual(t, ["A": 100, "B": 100], "\(mode)")
        }
    }

    // MARK: - Clamping must not be cumulative

    /// A member clamped at 0 mid-drag must recover its offset when the master
    /// comes back up. This only holds because the maths runs against the
    /// snapshot; against running values the group would stay flattened.
    func testClampingAtZeroRecoversTheSpread() {
        let low = GroupVolumeDistribution.targets(
            master: 4, memberIDs: members, snapshot: spread, mode: .linear)
        XCTAssertEqual(low, ["A": 0, "B": 9])   // A clamped

        let back = GroupVolumeDistribution.targets(
            master: 35, memberIDs: members, snapshot: spread, mode: .linear)
        XCTAssertEqual(back, ["A": 30, "B": 40])
    }

    func testClampingAtMaximumRecoversTheSpread() {
        let loud = GroupVolumeDistribution.Snapshot(master: 90, volumes: ["A": 85, "B": 95])
        let high = GroupVolumeDistribution.targets(
            master: 99, memberIDs: members, snapshot: loud, mode: .linear)
        XCTAssertEqual(high, ["A": 94, "B": 100])  // B clamped

        let back = GroupVolumeDistribution.targets(
            master: 90, memberIDs: members, snapshot: loud, mode: .linear)
        XCTAssertEqual(back, ["A": 85, "B": 95])
    }

    // MARK: - Edges

    func testMemberMissingFromTheSnapshotFallsBackToTheMaster() {
        // A speaker that joined mid-drag has no snapshot entry.
        let t = GroupVolumeDistribution.targets(
            master: 70, memberIDs: ["A", "B", "NEW"], snapshot: spread, mode: .linear)
        XCTAssertEqual(t["NEW"], 70)
    }

    func testEmptyGroupProducesNoTargets() {
        let t = GroupVolumeDistribution.targets(
            master: 50, memberIDs: [], snapshot: spread, mode: .linear)
        XCTAssertTrue(t.isEmpty)
    }

    func testLevelledSnapshotZeroesEveryMember() {
        // Snapshot taken at zero: every member rises together from here.
        let s = GroupVolumeDistribution.levelledSnapshot(memberIDs: members)
        XCTAssertEqual(s.master, 0)
        XCTAssertEqual(s.volumes, ["A": 0, "B": 0])

        let t = GroupVolumeDistribution.targets(
            master: 50, memberIDs: members, snapshot: s, mode: .linear)
        XCTAssertEqual(t, ["A": 50, "B": 50])
    }
}
