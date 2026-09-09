import XCTest
@testable import SonosKit

/// Services whose SMAPI hands back a plain HTTPS stream carry no `sid=` and no
/// Sonos URI scheme, so the host is the only thing identifying them. When it is
/// not recognised the Now Playing service row is absent — the track
/// shows a format badge with nothing underneath — and play history records the
/// listen as generic streaming.
final class DirectStreamServiceNameTests: XCTestCase {

    func testRadioParadiseIsIdentifiedByHost() {
        XCTAssertEqual(
            ServiceName.resolve(uri: "https://stream.radioparadise.com/flac-320"),
            ServiceName.radioParadise)
    }

    func testRadioParadiseSubdomainsAndPathsAllMatch() {
        for uri in ["https://api.radioparadise.com/sonos/stream/0",
                    "http://stream-uk1.radioparadise.com/mellow-flac",
                    "https://img.radioparadise.com/covers/l/8746.jpg"] {
            XCTAssertEqual(ServiceName.resolve(uri: uri), ServiceName.radioParadise, uri)
        }
    }

    func testSomaFMIsIdentifiedByHost() {
        XCTAssertEqual(
            ServiceName.resolve(uri: "https://ice6.somafm.com/groovesalad-256-mp3"),
            "SomaFM Radio")
    }

    /// A sid, where one exists, still wins — it names the specific service and
    /// the host check is only the fallback.
    func testAServiceIDStillTakesPrecedence() {
        XCTAssertEqual(
            ServiceName.resolve(uri: "x-sonosapi-hls-static:song%3a123?sid=204"),
            ServiceName.appleMusic)
    }

    func testUnrelatedHostsAreNotClaimed() {
        XCTAssertEqual(ServiceName.resolve(uri: "https://cdn.example.com/track.flac"),
                       ServiceName.streaming)
    }

    func testLocalLibraryIsUnaffected() {
        XCTAssertEqual(ServiceName.resolve(uri: "x-file-cifs://nas/Music/t.flac"),
                       ServiceName.musicLibrary)
    }
}
