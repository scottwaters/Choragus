import XCTest
@testable import SonosKit

final class SonosSystemVersionTests: XCTestCase {

    // MARK: - fromSwGen

    func testSwGen_1_mapsToS1() {
        XCTAssertEqual(SonosSystemVersion.fromSwGen("1"), .s1)
    }

    func testSwGen_2_mapsToS2() {
        XCTAssertEqual(SonosSystemVersion.fromSwGen("2"), .s2)
    }

    func testSwGen_whitespaceTolerated() {
        XCTAssertEqual(SonosSystemVersion.fromSwGen(" 2 "), .s2)
        XCTAssertEqual(SonosSystemVersion.fromSwGen("\t1\n"), .s1)
    }

    func testSwGen_emptyOrUnknownReturnsUnknown() {
        XCTAssertEqual(SonosSystemVersion.fromSwGen(""), .unknown)
        XCTAssertEqual(SonosSystemVersion.fromSwGen("3"), .unknown)
        XCTAssertEqual(SonosSystemVersion.fromSwGen("foo"), .unknown)
    }

    // MARK: - fromSoftwareVersion

    func testSoftwareVersion_s1Major() {
        XCTAssertEqual(SonosSystemVersion.fromSoftwareVersion("11.2.8-12200"), .s1)
        XCTAssertEqual(SonosSystemVersion.fromSoftwareVersion("7.4.1"), .s1)
        XCTAssertEqual(SonosSystemVersion.fromSoftwareVersion("11"), .s1)
    }

    func testSoftwareVersion_s2Major() {
        XCTAssertEqual(SonosSystemVersion.fromSoftwareVersion("12.0.0"), .s2)
        XCTAssertEqual(SonosSystemVersion.fromSoftwareVersion("72.1-34290"), .s2)
        XCTAssertEqual(SonosSystemVersion.fromSoftwareVersion("12"), .s2)
    }

    func testSoftwareVersion_empty() {
        XCTAssertEqual(SonosSystemVersion.fromSoftwareVersion(""), .unknown)
    }

    func testSoftwareVersion_nonNumericLeadingIsStripped() {
        // Classifier is forgiving — leading non-digits are skipped to find the
        // first numeric run. "v11.2.8" → "11" → S1. This matches real-world
        // practice where some Sonos-adjacent tooling prepends "v" to tags.
        XCTAssertEqual(SonosSystemVersion.fromSoftwareVersion("v11.2.8"), .s1)
        XCTAssertEqual(SonosSystemVersion.fromSoftwareVersion("v12.0.0"), .s2)
    }

    // MARK: - classify (combined)

    func testClassify_prefersSwGenOverVersion() {
        // Even if softwareVersion would suggest S2, swGen=1 wins
        XCTAssertEqual(
            SonosSystemVersion.classify(swGen: "1", softwareVersion: "72.1-34290"),
            .s1
        )
        // And the inverse — swGen=2 wins over S1-shaped softwareVersion
        XCTAssertEqual(
            SonosSystemVersion.classify(swGen: "2", softwareVersion: "11.2.8"),
            .s2
        )
    }

    func testClassify_fallsBackToSoftwareVersionWhenSwGenMissing() {
        XCTAssertEqual(
            SonosSystemVersion.classify(swGen: "", softwareVersion: "11.2.8-12200"),
            .s1
        )
        XCTAssertEqual(
            SonosSystemVersion.classify(swGen: "", softwareVersion: "12.0.0"),
            .s2
        )
    }

    func testClassify_unknownWhenBothMissing() {
        XCTAssertEqual(
            SonosSystemVersion.classify(swGen: "", softwareVersion: ""),
            .unknown
        )
    }

    // MARK: - SonosDevice + SonosGroup integration

    func testSonosDevice_systemVersion_usesSwGen() {
        let device = SonosDevice(id: "R1", ip: "10.0.0.1", softwareVersion: "11.0", swGen: "2")
        XCTAssertEqual(device.systemVersion, .s2, "swGen must override softwareVersion heuristic")
    }

    func testSonosDevice_systemVersion_fallsBackToSoftwareVersion() {
        let device = SonosDevice(id: "R1", ip: "10.0.0.1", softwareVersion: "11.2.8", swGen: "")
        XCTAssertEqual(device.systemVersion, .s1)
    }

    func testSonosGroup_systemVersion_fromCoordinator() {
        let coord = SonosDevice(id: "R1", ip: "10.0.0.1", swGen: "2", isCoordinator: true)
        let member = SonosDevice(id: "R2", ip: "10.0.0.2") // no version info
        let group = SonosGroup(id: "g1", coordinatorID: "R1", members: [coord, member], householdID: "H1")
        XCTAssertEqual(group.systemVersion, .s2)
    }

    func testSonosGroup_systemVersion_fallsBackToMembersWhenCoordinatorUnknown() {
        let coord = SonosDevice(id: "R1", ip: "10.0.0.1", isCoordinator: true) // no version
        let member = SonosDevice(id: "R2", ip: "10.0.0.2", swGen: "1")
        let group = SonosGroup(id: "g1", coordinatorID: "R1", members: [coord, member], householdID: "H1")
        XCTAssertEqual(group.systemVersion, .s1)
    }

    func testSonosGroup_systemVersion_unknownWhenNoSignal() {
        let coord = SonosDevice(id: "R1", ip: "10.0.0.1", isCoordinator: true)
        let group = SonosGroup(id: "g1", coordinatorID: "R1", members: [coord], householdID: "H1")
        XCTAssertEqual(group.systemVersion, .unknown)
    }

    // MARK: - Display label

    func testDisplayLabel() {
        XCTAssertEqual(SonosSystemVersion.s1.displayLabel, "S1")
        XCTAssertEqual(SonosSystemVersion.s2.displayLabel, "S2")
        XCTAssertEqual(SonosSystemVersion.unknown.displayLabel, "Unknown")
    }
}
