import XCTest
@testable import SonosKit

@MainActor
final class QueueDurationFillTests: XCTestCase {
    private final class StubCD: QueueDirectoryOperating, @unchecked Sendable {
        func browseQueue(device: SonosDevice, start: Int, count: Int, includeMetadata: Bool) async throws -> (items: [QueueItem], total: Int) { ([], 0) }
        func queueRevision(device: SonosDevice) async throws -> Int { 0 }
        func removeTrackFromQueue(device: SonosDevice, objectID: String) async throws {}
        func reorderTracksInQueue(device: SonosDevice, startIndex: Int, numberOfTracks: Int, insertBefore: Int) async throws {}
        @discardableResult
        func addURIToQueue(device: SonosDevice, uri: String, metadata: String, desiredFirstTrackNumberEnqueued: Int, enqueueAsNext: Bool) async throws -> Int { 1 }
        @discardableResult
        func addMultipleURIsToQueue(device: SonosDevice, uris: [String], metadatas: [String], desiredFirstTrackNumberEnqueued: Int, enqueueAsNext: Bool) async throws -> (firstTrackNumber: Int, numAdded: Int) { (1, uris.count) }
    }
    private struct StubArt: AlbumArtSearchProtocol {
        func searchArtwork(artist: String, album: String) async -> String? { nil }
        func searchRadioTrackArt(artist: String, title: String) async -> String? { nil }
        func lookupArtworkByCatalogID(_ id: String) async -> String? { nil }
    }
    private func makeQueue() -> QueueController {
        QueueController(contentDirectory: StubCD(), enricher: TrackMetadataEnricher(albumArtSearch: StubArt()))
    }

    private final class Source: QueueDurationSource {
        var byURI: [String: TimeInterval] = [:]
        var byTrack: [String: TimeInterval] = [:]
        func learnedDuration(uri: String?, title: String, artist: String, album: String) -> TimeInterval? {
            if let uri, let d = byURI[uri] { return d }
            return byTrack["\(title)|\(artist)"]
        }
    }

    func testDidlStringMatchesSpeakerForm() {
        XCTAssertEqual(PlaybackTimeFormat.didlString(200), "0:03:20")
        XCTAssertEqual(PlaybackTimeFormat.didlString(3661.4), "1:01:01")
        XCTAssertEqual(PlaybackTimeFormat.didlString(0), "0:00:00")
    }

    func testOnlyBlankDurationsAreFilled() {
        let queue = makeQueue()
        let source = Source()
        source.byURI["x-file-cifs://nas/a.flac"] = 200
        source.byTrack["Beta|Band"] = 61
        queue.durationSource = { source }
        let rows = [
            QueueItem(id: 1, title: "Alpha", artist: "Band", duration: "", uri: "x-file-cifs://nas/a.flac"),
            QueueItem(id: 2, title: "Beta", artist: "Band", duration: "", uri: "x-file-cifs://nas/b.flac"),
            QueueItem(id: 3, title: "Gamma", artist: "Band", duration: "0:04:00", uri: "x-sonos-spotify:x"),
            QueueItem(id: 4, title: "Delta", artist: "Band", duration: "", uri: "x-file-cifs://nas/d.flac"),
        ]
        let filled = queue.fillingDurations(rows)
        XCTAssertEqual(filled.map(\.duration), ["0:03:20", "0:01:01", "0:04:00", ""])
    }

    func testNoSourceLeavesRowsAlone() {
        let queue = makeQueue()
        let rows = [QueueItem(id: 1, title: "Alpha", artist: "Band", duration: "", uri: "x")]
        XCTAssertEqual(queue.fillingDurations(rows).first?.duration, "")
    }
}
