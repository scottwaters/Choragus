import XCTest
@testable import SonosKit

/// Bonded home-theatre zones. `hasSurrounds` gates the Surrounds tab; a
/// partial channel map hid it on real 5.1 systems (#78).
final class HomeTheaterZoneTests: XCTestCase {

    private func member(_ id: String, _ channel: SpeakerChannel) -> HomeTheaterMember {
        HomeTheaterMember(device: SonosDevice(id: id, ip: "192.168.1.20", roomName: "TV"),
                          channel: channel)
    }

    private func zone(_ channels: [SpeakerChannel], name: String = "TV") -> HomeTheaterZone {
        HomeTheaterZone(coordinatorID: "RINCON_BAR", name: name,
                        members: channels.enumerated().map { member("RINCON_\($0.offset)", $0.element) })
    }

    // MARK: - Composition

    func testFullSurroundZoneReportsBothSubAndSurrounds() {
        let z = zone([.soundbar, .sub, .rearLeft, .rearRight])
        XCTAssertTrue(z.hasSub)
        XCTAssertTrue(z.hasSurrounds)
        XCTAssertEqual(z.description, "TV (LS+RS+Sub)")
    }

    func testSoundbarAndSubOnly() {
        let z = zone([.soundbar, .sub])
        XCTAssertTrue(z.hasSub)
        XCTAssertFalse(z.hasSurrounds)
        XCTAssertEqual(z.description, "TV (Sub)")
    }

    /// A single rear speaker still counts as surrounds — a partial channel map
    /// naming only one rear must not hide the Surrounds tab (#78).
    func testOneRearSpeakerIsEnoughToCountAsSurrounds() {
        XCTAssertTrue(zone([.soundbar, .rearLeft]).hasSurrounds)
        XCTAssertTrue(zone([.soundbar, .rearRight]).hasSurrounds)
    }

    func testBareSoundbarDescribesItselfByName() {
        let z = zone([.soundbar])
        XCTAssertFalse(z.hasSub)
        XCTAssertFalse(z.hasSurrounds)
        XCTAssertEqual(z.description, "TV")
    }

    func testZoneIdentityIsTheCoordinator() {
        XCTAssertEqual(zone([.soundbar]).id, "RINCON_BAR")
    }

    // MARK: - Channel map parsing

    /// These raw values are Sonos's own ChannelMapSet tokens; a typo here
    /// silently drops a speaker from the zone.
    func testChannelsParseFromSonosTokens() {
        XCTAssertEqual(SpeakerChannel(rawValue: "LF,RF"), .soundbar)
        XCTAssertEqual(SpeakerChannel(rawValue: "SW"), .sub)
        XCTAssertEqual(SpeakerChannel(rawValue: "LR"), .rearLeft)
        XCTAssertEqual(SpeakerChannel(rawValue: "RR"), .rearRight)
        XCTAssertEqual(SpeakerChannel(rawValue: "LF,LF"), .leftPair)
        XCTAssertEqual(SpeakerChannel(rawValue: "RF,RF"), .rightPair)
    }

    func testUnknownTokenIsRejectedRatherThanGuessed() {
        XCTAssertNil(SpeakerChannel(rawValue: "XX"))
    }

    // MARK: - Display order

    func testHomeTheatreMembersSortFrontToBack() {
        let ordered = [SpeakerChannel.rearRight, .sub, .rearLeft, .soundbar]
            .sorted { $0.sortOrder < $1.sortOrder }
        XCTAssertEqual(ordered, [.soundbar, .sub, .rearLeft, .rearRight])
    }

    func testStereoPairSortsLeftBeforeRight() {
        let ordered = [SpeakerChannel.rightPair, .leftPair].sorted { $0.sortOrder < $1.sortOrder }
        XCTAssertEqual(ordered, [.leftPair, .rightPair])
    }

    func testEveryChannelHasADisplayName() {
        for channel in SpeakerChannel.allCases {
            XCTAssertFalse(channel.displayName.isEmpty, "\(channel)")
        }
    }
}
