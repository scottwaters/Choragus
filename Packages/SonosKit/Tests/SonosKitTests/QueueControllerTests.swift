import XCTest
@testable import SonosKit

/// `QueueController`. Every read runs through enrichment, so the controller
/// depends on exactly two collaborators; the tests pin that along with the
/// behaviour.
final class QueueControllerTests: XCTestCase {

    // MARK: - Fixtures

    private final class StubCD: QueueDirectoryOperating, @unchecked Sendable {
        var rows: [QueueItem] = []
        var browseError: Error?
        private(set) var removed: [String] = []
        private(set) var reorders: [(Int, Int, Int)] = []
        private(set) var browseCalls = 0

        func browseQueue(device: SonosDevice, start: Int, count: Int,
                         includeMetadata: Bool) async throws -> (items: [QueueItem], total: Int) {
            browseCalls += 1
            if let browseError { throw browseError }
            let page = Array(rows.dropFirst(start).prefix(count))
            return (items: page, total: rows.count)
        }

        func queueRevision(device: SonosDevice) async throws -> Int { 0 }
        func removeTrackFromQueue(device: SonosDevice, objectID: String) async throws {
            removed.append(objectID)
        }

        func reorderTracksInQueue(device: SonosDevice, startIndex: Int,
                                  numberOfTracks: Int, insertBefore: Int) async throws {
            reorders.append((startIndex, numberOfTracks, insertBefore))
        }

        @discardableResult
        func addURIToQueue(device: SonosDevice, uri: String, metadata: String,
                           desiredFirstTrackNumberEnqueued: Int, enqueueAsNext: Bool) async throws -> Int { 1 }

        @discardableResult
        func addMultipleURIsToQueue(device: SonosDevice, uris: [String], metadatas: [String],
                                    desiredFirstTrackNumberEnqueued: Int,
                                    enqueueAsNext: Bool) async throws -> (firstTrackNumber: Int, numAdded: Int) {
            (1, uris.count)
        }
    }

    private struct StubArt: AlbumArtSearchProtocol {
        func searchArtwork(artist: String, album: String) async -> String? { nil }
        func searchRadioTrackArt(artist: String, title: String) async -> String? { nil }
        func lookupArtworkByCatalogID(_ id: String) async -> String? { nil }
    }

    private struct StubError: Error {}

    private func row(_ id: Int, title: String = "", uri: String? = nil) -> QueueItem {
        QueueItem(id: id, title: title, artist: "", album: "", albumArtURI: nil,
                  duration: "0:03:00", uri: uri ?? "x-sonos-http:t\(id).flac")
    }

    private func group() -> SonosGroup {
        let d = SonosDevice(id: "A", ip: "10.0.0.1", port: 1400, roomName: "Kitchen",
                            householdID: "HH1", isCoordinator: true)
        return SonosGroup(id: "G1", coordinatorID: "A", members: [d], householdID: "HH1")
    }

    @MainActor
    private func make(_ cd: StubCD) -> (QueueController, TrackMetadataEnricher) {
        let e = TrackMetadataEnricher(albumArtSearch: StubArt())
        return (QueueController(contentDirectory: cd, enricher: e), e)
    }

    // MARK: - Reading

    @MainActor
    func testGetQueueReturnsRowsAndTotal() async throws {
        let cd = StubCD()
        cd.rows = [row(1, title: "One"), row(2, title: "Two")]
        let (q, _) = make(cd)

        let out = try await q.getQueue(group: group(), start: 0, count: 50)

        XCTAssertEqual(out.total, 2)
        XCTAssertEqual(out.items.map(\.title), ["One", "Two"])
    }

    /// Reads run through the enricher.
    @MainActor
    func testReadsAreEnriched() async throws {
        let cd = StubCD()
        let uri = "x-sonos-http:9f2c.mp3"
        cd.rows = [QueueItem(id: 1, title: "9f2c.mp3", artist: "", album: "",
                             albumArtURI: nil, duration: "0:03:00", uri: uri)]
        let (q, enricher) = make(cd)
        enricher.remember(.init(title: "Real Name", artist: "A", album: "B", artURL: nil),
                          forURI: uri)

        let out = try await q.getQueue(group: group(), start: 0, count: 50)

        XCTAssertEqual(out.items.first?.title, "Real Name",
                       "a filename title must be replaced from the metadata cache")
    }

    /// The first page is cached for now-playing recovery; later pages are not,
    /// or a scroll would overwrite the head of the queue.
    @MainActor
    func testOnlyTheFirstPageSeedsTheRecoveryCache() async throws {
        let cd = StubCD()
        cd.rows = (1...5).map { row($0, title: "T\($0)") }
        let (q, enricher) = make(cd)

        _ = try await q.getQueue(group: group(), start: 2, count: 2)
        XCTAssertNil(enricher.lastQueueItems["A"])

        _ = try await q.getQueue(group: group(), start: 0, count: 2)
        XCTAssertNotNil(enricher.lastQueueItems["A"])
    }

    @MainActor
    func testGroupWithNoCoordinatorReadsNothing() async throws {
        let cd = StubCD()
        cd.rows = [row(1)]
        let (q, _) = make(cd)
        let orphan = SonosGroup(id: "G9", coordinatorID: "missing", members: [], householdID: "HH1")

        let out = try await q.getQueue(group: orphan, start: 0, count: 50)

        XCTAssertEqual(out.total, 0)
        XCTAssertEqual(cd.browseCalls, 0, "no coordinator means no round-trip")
    }

    @MainActor
    func testReadFullQueuePagesUntilTheTotalIsReached() async throws {
        let cd = StubCD()
        cd.rows = (1...1200).map { row($0) }
        let (q, _) = make(cd)
        let dev = group().coordinator!

        let all = try await q.readFullQueue(device: dev)

        XCTAssertEqual(all.count, 1200)
        XCTAssertGreaterThan(cd.browseCalls, 1, "1200 rows cannot arrive in one 500-row page")
    }

    // MARK: - Mutation

    @MainActor
    func testRemoveTargetsTheQueueObjectID() async throws {
        let cd = StubCD()
        let (q, _) = make(cd)

        try await q.removeFromQueue(group: group(), trackIndex: 7)

        XCTAssertEqual(cd.removed, ["Q:0/7"])
    }

    @MainActor
    func testMoveIsForwardedAsASingleTrackReorder() async throws {
        let cd = StubCD()
        let (q, _) = make(cd)

        try await q.moveTrackInQueue(group: group(), from: 3, to: 9)

        XCTAssertEqual(cd.reorders.count, 1)
        XCTAssertEqual(cd.reorders.first?.1, 1, "one track moves at a time")
    }

    @MainActor
    func testMutationsOnACoordinatorlessGroupAreNoOps() async throws {
        let cd = StubCD()
        let (q, _) = make(cd)
        let orphan = SonosGroup(id: "G9", coordinatorID: "missing", members: [], householdID: "HH1")

        try await q.removeFromQueue(group: orphan, trackIndex: 1)
        try await q.moveTrackInQueue(group: orphan, from: 1, to: 2)

        XCTAssertTrue(cd.removed.isEmpty)
        XCTAssertTrue(cd.reorders.isEmpty)
    }

    // MARK: - Add-progress bookkeeping

    /// The counter nests: a browse walk that adds several containers must not
    /// clear the spinner until the outermost add finishes. Asserts on the
    /// derived `isAdding` rather than a notification: a derived value has no
    /// wiring to omit.
    @MainActor
    func testAddingDepthNestsAndOnlyClearsAtTheOutermostEnd() {
        let cd = StubCD()
        let (q, _) = make(cd)

        q.beginAdding()
        q.beginAdding()
        XCTAssertTrue(q.isAdding)
        q.endAdding()
        XCTAssertTrue(q.isAdding, "an inner add finishing must not clear the flag")
        q.endAdding()

        XCTAssertFalse(q.isAdding)
    }

    /// The background fill brackets its own work inside the outer add;
    /// interleaved begin/end pairs must not strand the spinner on.
    @MainActor
    func testInterleavedOuterAndInnerAddsClearExactlyOnce() {
        let cd = StubCD()
        let (q, _) = make(cd)

        q.beginAdding()          // outer: a browse walk starts
        q.beginAdding()          // inner: background fill starts
        q.endAdding()            // outer finishes first
        XCTAssertTrue(q.isAdding, "the fill is still running")
        q.endAdding()            // fill finishes

        XCTAssertFalse(q.isAdding, "the spinner must not be stranded on")
    }

    @MainActor
    func testEndAddingNeverDrivesTheDepthNegative() {
        let cd = StubCD()
        let (q, _) = make(cd)

        q.endAdding()
        q.endAdding()
        q.beginAdding()

        XCTAssertTrue(q.isAdding, "an unbalanced end must not leave the counter below zero")
    }

    // MARK: - Failure

    @MainActor
    func testBrowseFailurePropagates() async {
        let cd = StubCD()
        cd.browseError = StubError()
        let (q, _) = make(cd)

        do {
            _ = try await q.getQueue(group: group(), start: 0, count: 50)
            XCTFail("a failed browse must not be reported as an empty queue")
        } catch {
            // expected
        }
    }
}
