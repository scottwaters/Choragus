import XCTest
@testable import SonosKit

/// `VolumeController`: the echo absorption that stops the app's own SOAP
/// writes bouncing back as user changes, the equality gates that keep a
/// refresh storm from flooding observers, and the fixed-line-out handling for
/// Connect/Port/Amp (#50).
///
/// The debounced verifier fan-outs are wall-clock timed (500 ms) and are not
/// exercised here; the live-speaker path covers them.
final class VolumeControllerTests: XCTestCase {

    // MARK: - Fixtures

    private final class StubRC: RenderingControlling, @unchecked Sendable {
        var volumes: [String: Int] = [:]
        var mutes: [String: Bool] = [:]
        var outputFixed: Set<String> = []
        var setVolumeError: Error?
        private(set) var setVolumeCalls: [(String, Int)] = []
        private(set) var setMuteCalls: [(String, Bool)] = []

        func getVolume(device: SonosDevice) async throws -> Int { volumes[device.id] ?? 0 }
        func getMute(device: SonosDevice) async throws -> Bool { mutes[device.id] ?? false }
        func getOutputFixed(device: SonosDevice) async -> Bool { outputFixed.contains(device.id) }

        func setVolume(device: SonosDevice, volume: Int) async throws {
            if let setVolumeError { throw setVolumeError }
            setVolumeCalls.append((device.id, volume))
            volumes[device.id] = volume
        }

        func setMute(device: SonosDevice, muted: Bool) async throws {
            setMuteCalls.append((device.id, muted))
            mutes[device.id] = muted
        }
    }

    private func device(_ id: String, model: String = "Sonos One") -> SonosDevice {
        SonosDevice(id: id, ip: "10.0.0.1", port: 1400, roomName: "Room \(id)",
                    modelName: model, householdID: "HH1")
    }

    @MainActor
    private func make(_ rc: StubRC,
                      groups: [SonosGroup] = [],
                      devices: [String: SonosDevice] = [:],
                      tags: @escaping @MainActor (String) -> Void = { _ in },
                      context: StubContext? = nil)
    -> (VolumeController, TopologyStore) {
        let topology = TopologyStore(zoneTopology: NoTopology())
        topology.applyCached(groups: groups, devices: devices)
        let vc = VolumeController(renderingControl: rc, topology: topology, publishTag: tags)
        vc.nowPlayingContext = context
        if let context { retained.append(context) }
        return (vc, topology)
    }

    /// The controller holds its context provider weakly, so tests must keep
    /// one alive for the duration.
    private var retained: [AnyObject] = []

    final class StubContext: NowPlayingContextProviding {
        var asked: [String] = []
        let result: (trackURI: String, state: String)?
        init(result: (trackURI: String, state: String)?) { self.result = result }
        func nowPlayingContext(forCoordinator coordinatorID: String) -> (trackURI: String, state: String)? {
            asked.append(coordinatorID)
            return result
        }
    }

    private struct NoTopology: ZoneGroupStateFetching {
        func getZoneGroupState(device: SonosDevice) async throws -> [ZoneGroupData] { [] }
    }

    // MARK: - Observed values

    @MainActor
    func testObservedVolumeIsApplied() {
        let rc = StubRC()
        let (vc, _) = make(rc, devices: ["A": device("A")])

        vc.applyObservedVolume("A", volume: 42)

        XCTAssertEqual(vc.deviceVolumes["A"], 42)
    }

    /// `scanGroup` calls this for every member of every group after every
    /// topology refresh, and the value is typically unchanged. Without the
    /// equality gate, ten speakers refreshing flood observers.
    @MainActor
    func testUnchangedVolumeDoesNotPublish() {
        let rc = StubRC()
        var tags: [String] = []
        let (vc, _) = make(rc, devices: ["A": device("A")], tags: { tags.append($0) })

        vc.applyObservedVolume("A", volume: 42)
        XCTAssertEqual(tags.filter { $0 == "vol" }.count, 1)

        vc.applyObservedVolume("A", volume: 42)
        XCTAssertEqual(tags.filter { $0 == "vol" }.count, 1,
                       "an identical value must not publish again")
    }

    @MainActor
    func testUnchangedMuteDoesNotPublish() {
        let rc = StubRC()
        var tags: [String] = []
        let (vc, _) = make(rc, devices: ["A": device("A")], tags: { tags.append($0) })

        vc.applyObservedMute("A", muted: true)
        vc.applyObservedMute("A", muted: true)

        XCTAssertEqual(tags.filter { $0 == "mute" }.count, 1)
    }

    // MARK: - Echo absorption

    /// The app's own write must not come back as a user change. The speaker
    /// echoes every SetVolume as an RC NOTIFY.
    @MainActor
    func testOurOwnWriteIsAbsorbedAsAnEcho() async throws {
        let rc = StubRC()
        let dev = device("A")
        let (vc, _) = make(rc, devices: ["A": dev])
        vc.applyObservedVolume("A", volume: 10)

        try await vc.setVolume(device: dev, volume: 55)
        // The echo of the app's write arrives.
        vc.applyObservedVolume("A", volume: 55)

        XCTAssertEqual(vc.deviceVolumes["A"], 10,
                       "the echo is consumed, so the dict keeps its pre-write value until a real event")
    }

    /// A time-window grace would drop every event for its duration,
    /// swallowing genuine Sonos-app changes; the echo queue absorbs one value.
    @MainActor
    func testExternalChangeDuringPendingWriteFlowsThrough() async throws {
        let rc = StubRC()
        let dev = device("A")
        let (vc, _) = make(rc, devices: ["A": dev])

        try await vc.setVolume(device: dev, volume: 55)
        // A different value — someone moved the slider in the Sonos app.
        vc.applyObservedVolume("A", volume: 20)

        XCTAssertEqual(vc.deviceVolumes["A"], 20,
                       "an event that matches no pending write is a real change")
    }

    @MainActor
    func testEchoIsConsumedOnlyOnce() async throws {
        let rc = StubRC()
        let dev = device("A")
        let (vc, _) = make(rc, devices: ["A": dev])

        try await vc.setVolume(device: dev, volume: 55)
        vc.applyObservedVolume("A", volume: 55)   // absorbed
        vc.applyObservedVolume("A", volume: 55)   // nothing left to absorb

        XCTAssertEqual(vc.deviceVolumes["A"], 55,
                       "a second identical event is a real one and applies")
    }

    @MainActor
    func testMuteEchoIsAbsorbed() async throws {
        let rc = StubRC()
        let dev = device("A")
        let (vc, _) = make(rc, devices: ["A": dev])
        vc.applyObservedMute("A", muted: false)

        try await vc.setMute(device: dev, muted: true)
        vc.applyObservedMute("A", muted: true)

        XCTAssertEqual(vc.deviceMutes["A"], false)
    }

    // MARK: - Fixed line-out (#50)

    @MainActor
    func testSetVolumeIsSkippedForAKnownFixedLineOut() async throws {
        let rc = StubRC()
        let dev = device("A", model: "Sonos Connect")
        rc.outputFixed = ["A"]
        let (vc, _) = make(rc, devices: ["A": dev])
        await vc.refreshFixedOutputStatus()

        try await vc.setVolume(device: dev, volume: 30)

        XCTAssertTrue(vc.isOutputFixed("A"))
        XCTAssertTrue(rc.setVolumeCalls.isEmpty,
                      "a fixed line-out rejects SetVolume with 501; do not spam it")
    }

    /// A fixed line-out sometimes reports its lock late, as a 501 on the write
    /// itself. That must be remembered, not surfaced as a user-facing error.
    @MainActor
    func testLateFiveOhOneMarksTheDeviceFixedAndDoesNotThrow() async throws {
        let rc = StubRC()
        let dev = device("A", model: "Sonos Port")
        rc.setVolumeError = SOAPError.soapFault("501", "Action Failed")
        let (vc, _) = make(rc, devices: ["A": dev])

        try await vc.setVolume(device: dev, volume: 30)

        XCTAssertTrue(vc.isOutputFixed("A"))
    }

    @MainActor
    func testNonFiveOhOneErrorStillPropagates() async {
        let rc = StubRC()
        let dev = device("A")
        rc.setVolumeError = SOAPError.soapFault("500", "Boom")
        let (vc, _) = make(rc, devices: ["A": dev])

        do {
            try await vc.setVolume(device: dev, volume: 30)
            XCTFail("a genuine fault must not be swallowed")
        } catch {
            // expected
        }
    }

    // MARK: - Grace

    @MainActor
    func testVolumeGraceWindowReportsActiveThenLapses() {
        let rc = StubRC()
        let (vc, _) = make(rc)

        XCTAssertFalse(vc.isVolumeGraceActive(deviceID: "A"))
        vc.setVolumeGrace(deviceID: "A", duration: 5)
        XCTAssertTrue(vc.isVolumeGraceActive(deviceID: "A"))

        vc.setVolumeGrace(deviceID: "A", duration: -1)
        XCTAssertFalse(vc.isVolumeGraceActive(deviceID: "A"),
                       "an elapsed deadline is not an active grace")
    }

    // MARK: - Reset and optimistic writes

    @MainActor
    func testResetClearsBothDictionaries() {
        let rc = StubRC()
        let (vc, _) = make(rc, devices: ["A": device("A")])
        vc.applyObservedVolume("A", volume: 30)
        vc.applyObservedMute("A", muted: true)

        vc.reset()

        XCTAssertTrue(vc.deviceVolumes.isEmpty)
        XCTAssertTrue(vc.deviceMutes.isEmpty)
    }

    @MainActor
    func testOptimisticVolumeShowsBeforeTheWriteLands() {
        let rc = StubRC()
        let (vc, _) = make(rc, devices: ["A": device("A")])

        vc.setOptimisticVolume(deviceID: "A", volume: 77)

        XCTAssertEqual(vc.deviceVolumes["A"], 77)
    }

    // MARK: - Topology is a sibling, not a back-reference

    /// The controller answers coordinator questions through the injected
    /// store; topology is a sibling dependency, not a back-reference.
    @MainActor
    func testCoordinatorIdentityComesFromTheTopologyStore() {
        let rc = StubRC()
        let coord = device("A")
        let member = device("B")
        let group = SonosGroup(id: "G1", coordinatorID: "A",
                               members: [coord, member], householdID: "HH1")
        let (_, topology) = make(rc, groups: [group],
                                 devices: ["A": coord, "B": member])

        XCTAssertTrue(topology.isCoordinator(deviceID: "A"))
        XCTAssertFalse(topology.isCoordinator(deviceID: "B"))
    }

    // MARK: - Portable diagnostic

    /// The transport context closure exists solely for the portable-speaker
    /// volume=0 diagnostic. With the `{ _ in nil }` default the path logs "?"
    /// for both fields, so the closure must be consulted.
    @MainActor
    func testPortableVolumeZeroConsultsTheInjectedTransportContext() {
        let rc = StubRC()
        let portable = SonosDevice(id: "A", ip: "10.0.0.1", port: 1400,
                                   roomName: "Kitchen", modelName: "Sonos Roam",
                                   householdID: "HH1")
        let g = SonosGroup(id: "G1", coordinatorID: "A", members: [portable], householdID: "HH1")
        let ctx = StubContext(result: (trackURI: "x-sonos-http:track.flac", state: "PLAYING"))
        let (vc, _) = make(rc, groups: [g], devices: ["A": portable], context: ctx)

        // The diagnostic lives on the poll/scan path, not the event path.
        vc.updateDeviceVolume("A", volume: 0)

        XCTAssertEqual(ctx.asked, ["A"],
                       "the volume=0 diagnostic must ask for the group's transport context")
    }
}
