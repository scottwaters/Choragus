import XCTest
@testable import SonosKit

/// Presets are persisted JSON written by earlier versions of the app. Both
/// `GroupPreset` and `PresetMember` hand-roll `init(from:)` specifically so a
/// preset saved before a field existed still decodes; a throw here does not
/// degrade a feature, it loses the user's saved groups.
final class GroupPresetCodingTests: XCTestCase {

    private func decodePreset(_ json: String) throws -> GroupPreset {
        try JSONDecoder().decode(GroupPreset.self, from: Data(json.utf8))
    }

    /// The v3-era JSON: no includesEQ, no homeTheaterEQ, no per-member eq.
    func testPresetSavedBeforeEQFieldsExistedStillDecodes() throws {
        let preset = try decodePreset("""
        {
          "id": "0EC8B0A6-2C6D-4E5F-9A3B-111122223333",
          "name": "Downstairs",
          "coordinatorDeviceID": "RINCON_1",
          "members": [{"deviceID": "RINCON_1", "volume": 25}]
        }
        """)
        XCTAssertEqual(preset.name, "Downstairs")
        XCTAssertFalse(preset.includesEQ, "a missing flag must default to off, not throw")
        XCTAssertNil(preset.homeTheaterEQ)
        XCTAssertEqual(preset.members.first?.volume, 25)
        XCTAssertNil(preset.members.first?.eq)
    }

    func testHomeTheaterPresetRoundTrips() throws {
        let original = GroupPreset(
            name: "Movie night", coordinatorDeviceID: "RINCON_ARC",
            members: [PresetMember(deviceID: "RINCON_ARC", volume: 40,
                                   eq: SpeakerEQ(bass: 3, treble: -2, loudness: false))],
            includesEQ: true,
            homeTheaterEQ: HomeTheaterEQ(nightMode: true, dialogLevel: true,
                                         subGain: -4, surroundLevel: 2, surroundMode: 0))

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GroupPreset.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.name, "Movie night")
        XCTAssertTrue(decoded.includesEQ)
        XCTAssertEqual(decoded.homeTheaterEQ?.nightMode, true)
        XCTAssertEqual(decoded.homeTheaterEQ?.subGain, -4)
        XCTAssertEqual(decoded.homeTheaterEQ?.surroundMode, 0)
        XCTAssertEqual(decoded.members.first?.eq?.bass, 3)
        XCTAssertEqual(decoded.members.first?.eq?.treble, -2)
    }

    func testMemberIdentityIsTheDeviceID() {
        let member = PresetMember(deviceID: "RINCON_9", volume: 10)
        XCTAssertEqual(member.id, "RINCON_9")
    }

    func testMissingRequiredFieldIsStillAnError() throws {
        // Optional fields tolerate absence; a preset with no coordinator is
        // not recoverable and must not decode into a broken preset.
        XCTAssertThrowsError(try decodePreset("""
        {"id": "0EC8B0A6-2C6D-4E5F-9A3B-111122223333", "name": "Broken", "members": []}
        """))
    }

    func testEmptyMemberListDecodes() throws {
        // A preset whose speakers have all left the household still loads, so
        // the user can see it and delete it rather than losing the list.
        let preset = try decodePreset("""
        {
          "id": "0EC8B0A6-2C6D-4E5F-9A3B-111122223333",
          "name": "Gone", "coordinatorDeviceID": "RINCON_X", "members": []
        }
        """)
        XCTAssertTrue(preset.members.isEmpty)
    }

    func testHomeTheaterDefaultsMatchASonosDefaultRoom() {
        // These defaults are written into every preset that predates the HT
        // fields, so they have to be the neutral position.
        let eq = HomeTheaterEQ()
        XCTAssertFalse(eq.nightMode)
        XCTAssertFalse(eq.dialogLevel)
        XCTAssertTrue(eq.subEnabled)
        XCTAssertEqual(eq.subGain, 0)
        XCTAssertTrue(eq.surroundEnabled)
        XCTAssertEqual(eq.surroundLevel, 0)
        XCTAssertEqual(eq.surroundMode, 1, "1 is Full, the Sonos default")
    }
}
