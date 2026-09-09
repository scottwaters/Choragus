import XCTest
@testable import SonosKit

final class QueueHealthScannerTests: XCTestCase {
    /// An expired signature is decidable from the URL alone — no probe may
    /// run for it, because the CDN sometimes still answers 200 briefly.
    func testExpiredSignatureNeedsNoProbe() {
        let uri = "https://cdn.example.com/t.flac?token=x&Expires=1000000000"
        XCTAssertEqual(QueueHealthScanner.offlineVerdict(uri: uri, title: "Song"), .expired)
    }

    func testSpeakerResolvedURIsAreNotJudged() {
        XCTAssertEqual(QueueHealthScanner.offlineVerdict(
            uri: "x-sonos-http:song%3a1.mp4?sid=204", title: "Eat It"), .ok)
        XCTAssertEqual(QueueHealthScanner.offlineVerdict(
            uri: "x-file-cifs://nas/t.flac", title: "Song"), .ok)
    }

    /// A direct URL with a filename title: the probe succeeds — the file
    /// exists — so the verdict has to come from the metadata, not the fetch.
    func testFilenameTitleFlagsMissingMetadata() async {
        let rows = [(id: 8, uri: "http://192.168.0.9:50002/m/1.flac", title: "85940.flac")]
        let results = await QueueHealthScanner.scan(rows: rows, probe: { _ in 200 })
        XCTAssertEqual(results, [.init(id: 8, verdict: .missingMetadata)])
    }

    func testDeadHostAndErrorStatusAreDead() async {
        let rows = [(id: 1, uri: "https://gone.example.com/a.mp3", title: "A"),
                    (id: 2, uri: "https://cdn.example.com/b.mp3", title: "B")]
        let results = await QueueHealthScanner.scan(rows: rows, probe: { url in
            url.host == "gone.example.com" ? nil : 404
        })
        XCTAssertEqual(results, [.init(id: 1, verdict: .dead),
                                 .init(id: 2, verdict: .dead)])
    }

    func testHealthyDirectStreamIsOK() async {
        let rows = [(id: 1, uri: "https://cdn.example.com/b.mp3", title: "B")]
        let results = await QueueHealthScanner.scan(rows: rows, probe: { _ in 206 })
        XCTAssertEqual(results, [.init(id: 1, verdict: .ok)])
    }
}
