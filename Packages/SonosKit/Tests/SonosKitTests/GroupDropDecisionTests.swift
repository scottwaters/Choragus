import XCTest
@testable import SonosKit

/// Sidebar drag-and-drop grouping (#82). Each refusal corresponds to a SOAP
/// fault that would otherwise surface as no visible change.
final class GroupDropDecisionTests: XCTestCase {

    private func device(_ id: String, _ room: String) -> SonosDevice {
        SonosDevice(id: id, ip: "192.168.1.10", roomName: room)
    }

    private func group(_ id: String, members: [String], household: String? = "HH1") -> SonosGroup {
        SonosGroup(id: id, coordinatorID: members[0],
                   members: members.map { device($0, "Room \($0)") },
                   householdID: household)
    }

    private var kitchen: SonosGroup { group("G1", members: ["A"]) }
    private var office: SonosGroup { group("G2", members: ["B", "C"]) }

    // MARK: - Joining

    func testJoinsEveryMemberOfTheDraggedGroup() {
        // Dragging a grouped pair onto another room must bring both speakers,
        // not just the coordinator.
        let decision = GroupDropDecision.join(sourceID: "G2", target: kitchen,
                                              groups: [kitchen, office])
        XCTAssertEqual(decision, .join(members: ["B", "C"],
                                       toCoordinator: "A", selecting: "G1"))
    }

    func testDropOntoItselfIsRefused() {
        let decision = GroupDropDecision.join(sourceID: "G1", target: kitchen,
                                              groups: [kitchen, office])
        XCTAssertEqual(decision, .refuse(.sameGroup))
    }

    /// Sonos cannot group across households; the speaker answers the join with
    /// a fault, so the drop is refused before any call goes out.
    func testCrossHouseholdDropIsRefused() {
        let other = group("G3", members: ["D"], household: "HH2")
        let decision = GroupDropDecision.join(sourceID: "G3", target: kitchen,
                                              groups: [kitchen, other])
        XCTAssertEqual(decision, .refuse(.differentHousehold))
    }

    func testUnknownHouseholdsAreNotTreatedAsMatching() {
        // Two groups with no household reported are not evidence of one
        // system. nil == nil would silently permit an illegal join.
        let a = group("G4", members: ["E"], household: nil)
        let b = group("G5", members: ["F"], household: nil)
        let decision = GroupDropDecision.join(sourceID: "G4", target: b, groups: [a, b])
        XCTAssertEqual(decision, .join(members: ["E"], toCoordinator: "F", selecting: "G5"))
    }

    func testVanishedSourceIsRefused() {
        // Topology changed between the drag starting and the drop landing.
        let decision = GroupDropDecision.join(sourceID: "GONE", target: kitchen,
                                              groups: [kitchen, office])
        XCTAssertEqual(decision, .refuse(.unknownSource))
    }

    func testTargetWithoutACoordinatorIsRefused() {
        let headless = SonosGroup(id: "G6", coordinatorID: "MISSING",
                                  members: [], householdID: "HH1")
        let decision = GroupDropDecision.join(sourceID: "G1", target: headless,
                                              groups: [kitchen, headless])
        XCTAssertEqual(decision, .refuse(.targetHasNoCoordinator))
    }

    // MARK: - Splitting

    func testSplitDetachesEveryoneButTheCoordinator() {
        // The coordinator keeps playing; the others become standalone.
        let decision = GroupDropDecision.split(sourceID: "G2", groups: [kitchen, office])
        XCTAssertEqual(decision, .ungroup(members: ["C"]))
    }

    func testSplittingAStandaloneRoomIsRefused() {
        let decision = GroupDropDecision.split(sourceID: "G1", groups: [kitchen, office])
        XCTAssertEqual(decision, .refuse(.alreadyStandalone))
    }

    func testSplittingAVanishedGroupIsRefused() {
        let decision = GroupDropDecision.split(sourceID: "GONE", groups: [kitchen])
        XCTAssertEqual(decision, .refuse(.unknownSource))
    }

    func testSplitOfAThreeSpeakerGroupDetachesTwo() {
        let trio = group("G7", members: ["X", "Y", "Z"])
        let decision = GroupDropDecision.split(sourceID: "G7", groups: [trio])
        XCTAssertEqual(decision, .ungroup(members: ["Y", "Z"]))
    }
}
