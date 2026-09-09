import XCTest
@testable import SonosKit

@MainActor
final class MCPBuildJobsTests: XCTestCase {
    /// A matching service that knows a fixed catalogue.
    private func catalogue(_ known: [String: String]) -> PlaylistResolveService {
        .localLibrary(search: { term in
            known.compactMap { title, artist -> BrowseItem? in
                guard term.lowercased().contains(title.lowercased()) else { return nil }
                return BrowseItem(id: "x-file:\(title)", title: title, artist: artist, album: "Album",
                                  itemClass: .musicTrack, resourceURI: "x-file-cifs://nas/\(title).flac")
            }
        })
    }

    private let specs = [SongSpec(title: "Alpha", artist: "Band"), SongSpec(title: "Beta", artist: "Band"),
                         SongSpec(title: "Gamma", artist: "Band")]

    func testHitsStreamOutInOrderAndFinishSeesThemAll() async {
        let jobs = MCPBuildJobs()
        var streamed: [String] = []
        var finished: [String] = []
        let job = try! jobs.start(name: "Test", specs: specs,
                             passes: [.init(label: "library", service: catalogue(["Alpha": "Band", "Gamma": "Band"]))],
                             onHit: { item, index in streamed.append("\(index):\(item.title)"); return index },
                             finish: { tracks in finished = tracks.map(\.title); return ("save", 42) })
        await jobs.wait(job, upTo: 10)
        XCTAssertEqual(job.state, .completed)
        XCTAssertEqual(streamed, ["1:Alpha", "2:Gamma"])
        XCTAssertEqual(finished, ["Alpha", "Gamma"])
        XCTAssertEqual(job.unmatched.map(\.title), ["Beta"])
        XCTAssertEqual(job.playlistID, 42)
        XCTAssertEqual(job.snapshot["status"] as? String, "completed")
        XCTAssertEqual(job.snapshot["done"] as? Int, 3)
    }

    func testFallbackPassOnlyRetriesMisses() async {
        let jobs = MCPBuildJobs()
        var secondPassTerms: [String] = []
        let fallback = PlaylistResolveService.localLibrary(search: { term in
            secondPassTerms.append(term)
            guard term.contains("Beta") else { return [] }
            return [BrowseItem(id: "s:beta", title: "Beta", artist: "Band", itemClass: .musicTrack, resourceURI: "x-sonos-http:beta")]
        })
        let job = try! jobs.start(name: "Test", specs: specs,
                             passes: [.init(label: "library", service: catalogue(["Alpha": "Band"])),
                                      .init(label: "Spotify", service: fallback)],
                             onHit: nil, finish: nil)
        await jobs.wait(job, upTo: 10)
        XCTAssertEqual(job.state, .completed)
        XCTAssertEqual(secondPassTerms.count, 2)
        XCTAssertEqual(job.matched.map(\.title), ["Alpha", "Beta"])
        XCTAssertEqual(job.unmatched.map(\.title), ["Gamma"])
        XCTAssertEqual(job.passLabels, ["library", "Spotify"])
    }

    func testFallbackMatchesKeepInputOrderWhileQueueIsArrivalOrder() async {
        let jobs = MCPBuildJobs()
        let list = [SongSpec(title: "One", artist: "B"), SongSpec(title: "Two", artist: "B"),
                    SongSpec(title: "Three", artist: "B"), SongSpec(title: "Four", artist: "B")]
        var queued: [String] = []
        let job = try! jobs.start(name: "Order", specs: list,
                                  passes: [.init(label: "library", service: catalogue(["One": "B", "Three": "B"])),
                                           .init(label: "Spotify", service: catalogue(["Two": "B", "Four": "B"]))],
                                  onHit: { item, _ in queued.append(item.title); return queued.count + 10 },
                                  finish: { tracks in XCTAssertEqual(tracks.map(\.title), ["One", "Two", "Three", "Four"]); return ("save", 1) })
        await jobs.wait(job, upTo: 10)
        XCTAssertEqual(job.state, .completed)
        XCTAssertEqual(job.matched.map(\.title), ["One", "Two", "Three", "Four"])
        XCTAssertEqual(queued, ["One", "Three", "Two", "Four"])
        XCTAssertEqual(job.queuedPositions, [11, 12, 13, 14])
    }

    func testRunningBuildsAreCapped() async {
        let jobs = MCPBuildJobs()
        let slow = PlaylistResolveService.localLibrary(search: { _ in try? await Task.sleep(for: .seconds(5)); return [] })
        for _ in 0..<MCPBuildJobs.maxRunning {
            XCTAssertNoThrow(try jobs.start(name: "s", specs: specs, passes: [.init(label: "library", service: slow)], onHit: nil, finish: nil))
        }
        XCTAssertThrowsError(try jobs.start(name: "s", specs: specs, passes: [.init(label: "library", service: slow)], onHit: nil, finish: nil))
        for job in jobs.running { _ = jobs.cancel(job.id) }
    }

    func testCancelStopsTheJob() async {
        let jobs = MCPBuildJobs()
        let slow = PlaylistResolveService.localLibrary(search: { _ in
            try? await Task.sleep(for: .seconds(5))
            return []
        })
        let job = try! jobs.start(name: "Slow", specs: specs, passes: [.init(label: "library", service: slow)], onHit: nil, finish: nil)
        XCTAssertTrue(jobs.cancel(job.id))
        XCTAssertFalse(jobs.cancel(job.id))
        XCTAssertEqual(job.state, .cancelled)
        XCTAssertNil(jobs.job("missing"))
    }

    func testHitErrorsAreCountedNotFatal() async {
        let jobs = MCPBuildJobs()
        struct QueueDown: Error {}
        let job = try! jobs.start(name: "Test", specs: specs,
                             passes: [.init(label: "library", service: catalogue(["Alpha": "Band", "Beta": "Band"]))],
                             onHit: { _, _ in throw QueueDown() },
                             finish: { _ in ("queue", nil) })
        await jobs.wait(job, upTo: 10)
        XCTAssertEqual(job.state, .completed)
        XCTAssertEqual(job.hitErrors, 2)
        XCTAssertEqual(job.delivered, "queue")
    }

    func testFinishFailureMarksTheJobFailed() async {
        let jobs = MCPBuildJobs()
        struct SaveFailed: Error {}
        let job = try! jobs.start(name: "Test", specs: specs,
                             passes: [.init(label: "library", service: catalogue(["Alpha": "Band"]))],
                             onHit: nil, finish: { _ in throw SaveFailed() })
        await jobs.wait(job, upTo: 10)
        XCTAssertEqual(job.state, .failed)
        XCTAssertNotNil(job.error)
    }
}
