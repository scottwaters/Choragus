import XCTest
@testable import SonosKit

/// `TopologyStore`: the self-view rejection that keeps a rebooting satellite
/// from wiping the household, per-household serialization, the refresh
/// throttle, and the channel-map equality gates that stop a refresh storm
/// flooding observers.
final class TopologyStoreTests: XCTestCase {

    // MARK: - Fixtures

    /// Records what it was asked for and returns whatever it was primed with.
    private final class StubFetcher: ZoneGroupStateFetching, @unchecked Sendable {
        var responses: [[ZoneGroupData]] = []
        var error: Error?
        private(set) var callCount = 0

        func getZoneGroupState(device: SonosDevice) async throws -> [ZoneGroupData] {
            callCount += 1
            if let error { throw error }
            guard !responses.isEmpty else { return [] }
            return responses.count == 1 ? responses[0] : responses.removeFirst()
        }
    }

    private struct StubError: Error {}

    private func member(_ uuid: String,
                        name: String,
                        invisible: Bool = false,
                        ht: String = "",
                        channelMap: String = "") -> ZoneMemberData {
        ZoneMemberData(uuid: uuid,
                       location: "http://10.0.0.1:1400/xml/device_description.xml",
                       zoneName: name,
                       ip: "10.0.0.1",
                       port: 1400,
                       isInvisible: invisible,
                       htSatChanMapSet: ht,
                       channelMapSet: channelMap)
    }

    private func device(_ id: String, household: String? = "HH1") -> SonosDevice {
        SonosDevice(id: id, ip: "10.0.0.1", port: 1400, roomName: "Source",
                    householdID: household)
    }

    @MainActor
    private func store(_ fetcher: StubFetcher,
                       minInterval: TimeInterval = 10,
                       tags: @escaping @MainActor (String) -> Void = { _ in }) -> TopologyStore {
        TopologyStore(zoneTopology: fetcher, refreshMinInterval: minInterval, publishTag: tags)
    }

    // MARK: - Merge

    @MainActor
    func testRefreshAppliesGroupsAndReportsChange() async {
        let f = StubFetcher()
        f.responses = [[ZoneGroupData(id: "G1", coordinatorUUID: "A",
                                      members: [member("A", name: "Kitchen")])]]
        let s = store(f)

        let result = await s.refresh(from: device("A"), force: false)

        XCTAssertEqual(result.outcome, .applied)
        XCTAssertTrue(result.changed)
        XCTAssertEqual(s.groups.count, 1)
        XCTAssertEqual(s.groups.first?.coordinatorID, "A")
        XCTAssertEqual(s.devices["A"]?.householdID, "HH1")
    }

    @MainActor
    func testSecondIdenticalRefreshReportsNoChange() async {
        let f = StubFetcher()
        f.responses = [[ZoneGroupData(id: "G1", coordinatorUUID: "A",
                                      members: [member("A", name: "Kitchen")])]]
        let s = store(f, minInterval: 0)

        _ = await s.refresh(from: device("A"), force: false)
        let second = await s.refresh(from: device("A"), force: false)

        XCTAssertEqual(second.outcome, .applied)
        XCTAssertFalse(second.changed, "an identical merge must not report a change")
    }

    @MainActor
    func testInvisibleMembersAreHiddenButStillRecordedAsDevices() async {
        let f = StubFetcher()
        f.responses = [[ZoneGroupData(id: "G1", coordinatorUUID: "A", members: [
            member("A", name: "Living Room"),
            member("SUB", name: "Living Room", invisible: true)
        ])]]
        let s = store(f)

        _ = await s.refresh(from: device("A"), force: false)

        XCTAssertEqual(s.groups.first?.members.map(\.id), ["A"],
                       "satellites must not appear as rooms")
        XCTAssertNotNil(s.devices["SUB"], "but they are still known devices")
    }

    // MARK: - Rejections

    @MainActor
    func testAllOrphanResponseIsRejectedAndKeepsPreviousTopology() async {
        let f = StubFetcher()
        f.responses = [
            [ZoneGroupData(id: "G1", coordinatorUUID: "A", members: [member("A", name: "Kitchen")])],
            [ZoneGroupData(id: "RINCON_X:orphan", coordinatorUUID: "X",
                           members: [member("X", name: "Satellite")])]
        ]
        let s = store(f, minInterval: 0)
        _ = await s.refresh(from: device("A"), force: false)
        XCTAssertEqual(s.groups.count, 1)

        let result = await s.refresh(from: device("A"), force: false)

        XCTAssertEqual(result.outcome, .rejectedSelfView)
        XCTAssertEqual(s.groups.count, 1, "a satellite self-view must not wipe the household")
        XCTAssertEqual(s.groups.first?.id, "G1")
    }

    @MainActor
    func testEmptyResponseIsRejected() async {
        let f = StubFetcher()
        f.responses = [[]]
        let s = store(f)

        let result = await s.refresh(from: device("A"), force: false)

        XCTAssertEqual(result.outcome, .rejectedSelfView)
        XCTAssertTrue(s.groups.isEmpty)
    }

    @MainActor
    func testHouseholdlessSourceIsRejectedBeforeMerging() async {
        let f = StubFetcher()
        f.responses = [[ZoneGroupData(id: "G1", coordinatorUUID: "A",
                                      members: [member("A", name: "Kitchen")])]]
        let s = store(f)

        let result = await s.refresh(from: device("A", household: nil), force: false)

        XCTAssertEqual(result.outcome, .noHousehold,
                       "merging nil-tagged groups would wipe S1/S2 partitioning")
        XCTAssertTrue(s.groups.isEmpty)
    }

    @MainActor
    func testFetchFailureLeavesTopologyIntact() async {
        let f = StubFetcher()
        f.responses = [[ZoneGroupData(id: "G1", coordinatorUUID: "A",
                                      members: [member("A", name: "Kitchen")])]]
        let s = store(f, minInterval: 0)
        _ = await s.refresh(from: device("A"), force: false)

        f.error = StubError()
        let result = await s.refresh(from: device("A"), force: false)

        XCTAssertEqual(result.outcome, .failed)
        XCTAssertEqual(s.groups.count, 1)
    }

    // MARK: - Throttle

    @MainActor
    func testRefreshWithinMinIntervalIsThrottled() async {
        let f = StubFetcher()
        f.responses = [[ZoneGroupData(id: "G1", coordinatorUUID: "A",
                                      members: [member("A", name: "Kitchen")])]]
        let s = store(f, minInterval: 60)

        _ = await s.refresh(from: device("A"), force: false)
        let second = await s.refresh(from: device("A"), force: false)

        XCTAssertEqual(second.outcome, .throttled)
        XCTAssertEqual(f.callCount, 1, "the throttle must prevent the second SOAP call")
    }

    @MainActor
    func testForcedRefreshBypassesTheThrottle() async {
        let f = StubFetcher()
        f.responses = [[ZoneGroupData(id: "G1", coordinatorUUID: "A",
                                      members: [member("A", name: "Kitchen")])]]
        let s = store(f, minInterval: 60)

        _ = await s.refresh(from: device("A"), force: false)
        let forced = await s.refresh(from: device("A"), force: true)

        XCTAssertEqual(forced.outcome, .applied)
        XCTAssertEqual(f.callCount, 2)
    }

    @MainActor
    func testThrottleIsPerHousehold() async {
        let f = StubFetcher()
        f.responses = [[ZoneGroupData(id: "G1", coordinatorUUID: "A",
                                      members: [member("A", name: "Kitchen")])]]
        let s = store(f, minInterval: 60)

        f.responses = [
            [ZoneGroupData(id: "RINCON_A:1", coordinatorUUID: "A", members: [member("A", name: "Kitchen")])],
            [ZoneGroupData(id: "RINCON_B:1", coordinatorUUID: "B", members: [member("B", name: "Study")])]
        ]
        _ = await s.refresh(from: device("A", household: "S1"), force: false)
        let other = await s.refresh(from: device("B", household: "S2"), force: false)

        XCTAssertNotEqual(other.outcome, .throttled,
                          "S1 and S2 refresh independently")
    }

    // MARK: - Event topology

    @MainActor
    func testApplyEventTopologyReplacesGroups() {
        let f = StubFetcher()
        let s = store(f)

        let changed = s.applyEventTopology([
            ZoneGroupData(id: "G1", coordinatorUUID: "A", members: [member("A", name: "Kitchen")])
        ])

        XCTAssertTrue(changed)
        XCTAssertEqual(s.groups.map(\.id), ["G1"])
        XCTAssertNotNil(s.devices["A"])
    }

    @MainActor
    func testApplyEventTopologyReportsNoChangeWhenIdentical() {
        let f = StubFetcher()
        let s = store(f)
        let payload = [ZoneGroupData(id: "G1", coordinatorUUID: "A",
                                     members: [member("A", name: "Kitchen")])]

        _ = s.applyEventTopology(payload)
        XCTAssertFalse(s.applyEventTopology(payload))
    }

    // MARK: - Coordinator repair (#83)

    @MainActor
    func testCoordinatorNotAmongVisibleMembersIsSubstituted() async {
        let f = StubFetcher()
        // Coordinator "GHOST" is not among the members the speaker listed.
        f.responses = [[ZoneGroupData(id: "G1", coordinatorUUID: "GHOST",
                                      members: [member("A", name: "Kitchen")])]]
        let s = store(f)

        _ = await s.refresh(from: device("A"), force: false)

        XCTAssertEqual(s.groups.first?.coordinatorID, "A",
                       "a group whose coordinator names no visible member is repaired, not left inert")
    }

    // MARK: - Channel maps

    @MainActor
    func testHomeTheatreChannelMapProducesAZone() async {
        let f = StubFetcher()
        f.responses = [[ZoneGroupData(id: "G1", coordinatorUUID: "BAR", members: [
            member("BAR", name: "Living Room", ht: "BAR:LF,RF;SUB:SW"),
            member("SUB", name: "Living Room", invisible: true, ht: "BAR:LF,RF;SUB:SW")
        ])]]
        let s = store(f)

        _ = await s.refresh(from: device("BAR"), force: false)

        XCTAssertNotNil(s.htSatChannelMaps["BAR"])
        XCTAssertEqual(s.homeTheaterZones.count, 1)
        XCTAssertEqual(s.homeTheaterZones.first?.coordinatorID, "BAR")
    }

    @MainActor
    func testStereoPairMapIsKeyedOnTheVisiblePrimary() async {
        let f = StubFetcher()
        f.responses = [[ZoneGroupData(id: "G1", coordinatorUUID: "L", members: [
            member("L", name: "Office", channelMap: "L:LF,LF;R:RF,RF")
        ])]]
        let s = store(f)

        _ = await s.refresh(from: device("L"), force: false)

        XCTAssertEqual(s.stereoChannelMaps["L"]?.count, 2)
        XCTAssertTrue(s.htSatChannelMaps.isEmpty,
                      "a stereo pair is not a home-theatre zone")
    }

    /// An unchanged map must not publish; without the equality gate a refresh
    /// storm floods observers 10–20 ×/s.
    @MainActor
    func testUnchangedChannelMapsDoNotPublish() async {
        let f = StubFetcher()
        f.responses = [[ZoneGroupData(id: "G1", coordinatorUUID: "BAR", members: [
            member("BAR", name: "Living Room", ht: "BAR:LF,RF;SUB:SW")
        ])]]
        var tags: [String] = []
        let s = store(f, minInterval: 0, tags: { tags.append($0) })

        _ = await s.refresh(from: device("BAR"), force: false)
        XCTAssertEqual(tags.filter { $0 == "htChannel" }.count, 1)

        _ = await s.refresh(from: device("BAR"), force: false)
        XCTAssertEqual(tags.filter { $0 == "htChannel" }.count, 1,
                       "an identical channel map must not publish a second time")
    }

    /// A payload carrying no bonded-channel attributes at all must not be
    /// read as "un-bonded", or every home-theatre zone flickers out of
    /// existence between refreshes.
    @MainActor
    func testPayloadWithoutChannelAttributesKeepsExistingMap() async {
        let f = StubFetcher()
        f.responses = [
            [ZoneGroupData(id: "G1", coordinatorUUID: "BAR",
                           members: [member("BAR", name: "Living Room", ht: "BAR:LF,RF;SUB:SW")])],
            [ZoneGroupData(id: "G1", coordinatorUUID: "BAR",
                           members: [member("BAR", name: "Living Room")])]
        ]
        let s = store(f, minInterval: 0)

        _ = await s.refresh(from: device("BAR"), force: false)
        _ = await s.refresh(from: device("BAR"), force: false)

        XCTAssertNotNil(s.htSatChannelMaps["BAR"],
                        "absent attributes mean 'not reported', not 'un-bonded'")
    }

    // MARK: - Seeding

    @MainActor
    func testApplyCachedSeedsBothCollections() {
        let f = StubFetcher()
        let s = store(f)
        let dev = device("A")
        let group = SonosGroup(id: "G1", coordinatorID: "A", members: [dev], householdID: "HH1")

        s.applyCached(groups: [group], devices: ["A": dev])

        XCTAssertEqual(s.groups.map(\.id), ["G1"])
        XCTAssertEqual(s.devices.count, 1)
    }

    @MainActor
    func testUpsertDeviceOverwritesTopologyStub() {
        let f = StubFetcher()
        let s = store(f)
        s.applyCached(groups: [], devices: ["A": device("A")])

        var full = device("A")
        full.modelName = "Sonos One"
        s.upsertDevice(full)

        XCTAssertEqual(s.devices["A"]?.modelName, "Sonos One")
    }

    /// A speaker reporting the same group id twice in one response must
    /// produce a log line, not a trap: `Dictionary(uniqueKeysWithValues:)`
    /// in the merge diagnostics traps on duplicate keys.
    @MainActor
    func testDuplicateGroupIDsDoNotTrap() async {
        let f = StubFetcher()
        f.responses = [[
            ZoneGroupData(id: "G1", coordinatorUUID: "A", members: [member("A", name: "Kitchen")]),
            ZoneGroupData(id: "G1", coordinatorUUID: "B", members: [member("B", name: "Study")])
        ]]
        let s = store(f, minInterval: 0)

        _ = await s.refresh(from: device("A"), force: false)
        // Second pass is what builds the old-vs-new diff over duplicate keys.
        let result = await s.refresh(from: device("A"), force: false)

        XCTAssertEqual(result.outcome, .applied)
    }
}
