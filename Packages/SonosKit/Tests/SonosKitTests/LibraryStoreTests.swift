import XCTest
@testable import SonosKit

/// `LibraryStore`: the S1/S2 capability picture built from share matching —
/// which systems index a library, what the browse sections say about it, and
/// that sections owned by other features arrive through injection rather than
/// by the store knowing about them. The pure share-matching rules are covered
/// by `LibraryAvailabilityTests`.
final class LibraryStoreTests: XCTestCase {

    // MARK: - Fixtures

    private final class StubCD: ContentDirectoryBrowsing, @unchecked Sendable {
        /// objectID → (items, total)
        var responses: [String: ([BrowseItem], Int)] = [:]
        var browseError: Error?
        private(set) var reindexed: [String] = []

        func browse(device: SonosDevice, objectID: String,
                    start: Int, count: Int) async throws -> (items: [BrowseItem], total: Int) {
            if let browseError { throw browseError }
            let hit = responses[objectID] ?? ([], 0)
            return (items: hit.0, total: hit.1)
        }

        func refreshShareIndex(device: SonosDevice) async throws {
            reindexed.append(device.id)
        }
    }

    private struct NoTopology: ZoneGroupStateFetching {
        func getZoneGroupState(device: SonosDevice) async throws -> [ZoneGroupData] { [] }
    }

    private func device(_ id: String, household: String) -> SonosDevice {
        SonosDevice(id: id, ip: "10.0.0.1", port: 1400, roomName: "Room \(id)",
                    householdID: household, isCoordinator: true)
    }

    private func group(_ id: String, coordinator: SonosDevice) -> SonosGroup {
        SonosGroup(id: id, coordinatorID: coordinator.id,
                   members: [coordinator], householdID: coordinator.householdID)
    }

    @MainActor
    private func make(_ cd: StubCD,
                      groups: [SonosGroup] = [],
                      extra: [BrowseSection] = [])
    -> (LibraryStore, TopologyStore) {
        let topology = TopologyStore(zoneTopology: NoTopology())
        var devices: [String: SonosDevice] = [:]
        for g in groups { for m in g.members { devices[m.id] = m } }
        topology.applyCached(groups: groups, devices: devices)
        let lib = LibraryStore(contentDirectory: cd, topology: topology)
        if !extra.isEmpty {
            let c = StubContributor(sections: extra)
            retained.append(c)
            lib.sectionContributor = c
        }
        return (lib, topology)
    }

    /// Held weakly by the store, so a test must keep it alive.
    private var retained: [AnyObject] = []

    final class StubContributor: BrowseSectionContributing {
        let sections: [BrowseSection]
        init(sections: [BrowseSection]) { self.sections = sections }
        func contributedBrowseSections() -> [BrowseSection] { sections }
    }

    private func caps(_ household: String,
                      _ generation: SonosSystemVersion,
                      shares: Set<String>) -> HouseholdCapabilities {
        HouseholdCapabilities(householdID: household, generation: generation, shareIDs: shares)
    }

    // MARK: - Capability picture

    @MainActor
    func testSingleHouseholdIsNotMultiSystem() {
        let (lib, _) = make(StubCD())
        lib.seedCapabilities(["HH1": caps("HH1", .s2, shares: ["s:music"])])

        XCTAssertFalse(lib.hasMultipleSystems)
        XCTAssertEqual(lib.localLibraryGenerations, [.s2])
    }

    @MainActor
    func testTwoHouseholdsReportBothGenerations() {
        let (lib, _) = make(StubCD())
        lib.seedCapabilities([
            "HH1": caps("HH1", .s1, shares: ["s:music"]),
            "HH2": caps("HH2", .s2, shares: ["s:music"])
        ])

        XCTAssertTrue(lib.hasMultipleSystems)
        XCTAssertEqual(Set(lib.localLibraryGenerations), Set([.s1, .s2]))
    }

    /// A system with no shares has no local library, so it must not be listed
    /// as a generation that carries one.
    @MainActor
    func testSystemWithoutSharesIsNotAlibraryGeneration() {
        let (lib, _) = make(StubCD())
        lib.seedCapabilities([
            "HH1": caps("HH1", .s1, shares: []),
            "HH2": caps("HH2", .s2, shares: ["s:music"])
        ])

        XCTAssertEqual(lib.localLibraryGenerations, [.s2])
    }

    // MARK: - Availability notes

    @MainActor
    func testNoNoteInASingleSystemHousehold() {
        let (lib, _) = make(StubCD())
        lib.seedCapabilities(["HH1": caps("HH1", .s2, shares: ["s://nas/music"])])

        XCTAssertNil(lib.availabilityNote(forShareObjectID: "S://nas/music"),
                     "a household with one system needs no S1/S2 tag")
    }

    @MainActor
    func testShareOnOneSystemOnlyIsTagged() {
        let (lib, _) = make(StubCD())
        lib.seedCapabilities([
            "HH1": caps("HH1", .s1, shares: ["s://nas/music"]),
            "HH2": caps("HH2", .s2, shares: [])
        ])

        let note = lib.availabilityNote(forShareObjectID: "S://nas/music")

        XCTAssertNotNil(note, "a share only one system indexes must say which")
    }

    /// `shareIDs` are stored normalised — `refreshHouseholdCapabilities`
    /// inserts through `normalizedShareKey` — so a query in any case matches
    /// the same folder path on whichever systems have it configured. The
    /// resulting (S1/S2) tag means the folder is set up on both systems as two
    /// independently-indexed shares, not that they share one index.
    @MainActor
    func testShareQueryMatchesRegardlessOfCase() {
        let (lib, _) = make(StubCD())
        let key = LibraryStore.normalizedShareKey("S://NAS/Music")
        lib.seedCapabilities([
            "HH1": caps("HH1", .s1, shares: [key]),
            "HH2": caps("HH2", .s2, shares: [key])
        ])

        XCTAssertEqual(lib.availabilityNote(forShareObjectID: "S://nas/MUSIC"), "(S1/S2)",
                       "the folder is configured on both systems, so the tag names both")
    }

    // MARK: - Refresh

    @MainActor
    func testRefreshRecordsAShareBearingSystem() async {
        let cd = StubCD()
        let coord = device("A", household: "HH1")
        cd.responses["S:"] = ([BrowseItem(id: "S://nas/music", title: "music")], 1)
        let (lib, _) = make(cd, groups: [group("G1", coordinator: coord)])

        await lib.refreshHouseholdCapabilities()

        XCTAssertEqual(lib.householdCapabilities["HH1"]?.hasLocalLibrary, true)
    }

    @MainActor
    func testRefreshWithNoSharesRecordsAnEmptyLibrary() async {
        let cd = StubCD()
        let coord = device("A", household: "HH1")
        cd.responses["S:"] = ([], 0)
        let (lib, _) = make(cd, groups: [group("G1", coordinator: coord)])

        await lib.refreshHouseholdCapabilities()

        XCTAssertEqual(lib.householdCapabilities["HH1"]?.hasLocalLibrary, false)
    }

    // MARK: - Sections

    /// The store must not know that media servers exist. Sections owned by
    /// other features arrive through the injected closure.
    @MainActor
    func testInjectedSectionsAreAppendedAfterTheSpeakersOwn() async {
        let cd = StubCD()
        let coord = device("A", household: "HH1")
        let extra = BrowseSection(id: "mediaserver-1", title: "NAS",
                                  objectID: "MS:1/0", icon: "externaldrive.badge.wifi")
        let (lib, _) = make(cd, groups: [group("G1", coordinator: coord)], extra: [extra])

        await lib.loadBrowseSections()

        XCTAssertEqual(lib.browseSections.last?.id, "mediaserver-1",
                       "contributed sections sit alongside, and after, the speaker's own")
    }

    @MainActor
    func testCachedSectionsSeedTheStore() {
        let (lib, _) = make(StubCD())
        let cached = [BrowseSection(id: "s1", title: "Cached", objectID: "A:", icon: "music.note")]

        lib.applyCachedSections(cached)

        XCTAssertEqual(lib.browseSections.map(\.id), ["s1"])
    }

    // MARK: - Reindex

    @MainActor
    func testUpdateMusicLibraryAsksEachSystemToReindex() async {
        let cd = StubCD()
        let a = device("A", household: "HH1")
        let b = device("B", household: "HH2")
        cd.responses["S:"] = ([BrowseItem(id: "S://nas/music", title: "music")], 1)
        let (lib, _) = make(cd, groups: [group("G1", coordinator: a), group("G2", coordinator: b)])

        let result = await lib.updateMusicLibrary()

        XCTAssertEqual(result.triggered, 2, "one reindex per distinct system")
        XCTAssertEqual(Set(cd.reindexed), Set(["A", "B"]))
    }

    @MainActor
    func testSystemWithNoSharesIsNotAskedToReindex() async {
        let cd = StubCD()
        let a = device("A", household: "HH1")
        cd.responses["S:"] = ([], 0)
        let (lib, _) = make(cd, groups: [group("G1", coordinator: a)])

        let result = await lib.updateMusicLibrary()

        XCTAssertEqual(result.librariesFound, 0)
        XCTAssertTrue(cd.reindexed.isEmpty,
                      "a system with no shares has nothing to reindex")
    }
}
