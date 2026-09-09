import XCTest
@testable import SonosKit

final class ResolvedPlaybackRegistryTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ResolvedPlaybackRegistry.removeAll()
    }

    override func tearDown() {
        ResolvedPlaybackRegistry.removeAll()
        super.tearDown()
    }

    /// The same track resolved twice carries a different signature and
    /// expiry, and must still map to one entry.
    func testKeyIgnoresRotatingCredentials() {
        let first = "https://lgf.audio.tidal.com/mediatracks/blob123/0.flac?token=aaa&Expires=1799999000"
        let second = "https://lgf.audio.tidal.com/mediatracks/blob123/0.flac?token=bbb&Expires=1800009999"
        XCTAssertEqual(ResolvedPlaybackRegistry.key(forPlayURL: first),
                       ResolvedPlaybackRegistry.key(forPlayURL: second))
    }

    func testKeyKeepsNonRotatingParameters() {
        let a = "https://cdn.example.com/t.flac?quality=lossless&token=x"
        let b = "https://cdn.example.com/t.flac?quality=low&token=x"
        XCTAssertNotEqual(ResolvedPlaybackRegistry.key(forPlayURL: a),
                          ResolvedPlaybackRegistry.key(forPlayURL: b))
    }

    func testKeyIsOrderIndependent() {
        let a = "https://cdn.example.com/t.flac?bitrate=1411&region=au"
        let b = "https://cdn.example.com/t.flac?region=au&bitrate=1411"
        XCTAssertEqual(ResolvedPlaybackRegistry.key(forPlayURL: a),
                       ResolvedPlaybackRegistry.key(forPlayURL: b))
    }

    func testOnlyDirectStreamsAreKeyed() {
        XCTAssertNil(ResolvedPlaybackRegistry.key(forPlayURL: "x-sonos-http:song%3a1.mp4?sid=204"))
        XCTAssertNil(ResolvedPlaybackRegistry.key(forPlayURL: "x-file-cifs://nas/t.flac"))
    }

    func testRoundTripRecoversServiceOrigin() {
        let resolved = "https://lgf.audio.tidal.com/mediatracks/blob999/0.flac?token=aaa&Expires=1799999000"
        ResolvedPlaybackRegistry.remember(playURL: resolved, sid: ServiceID.tidal, itemID: "track:5566")
        let origin = ResolvedPlaybackRegistry.origin(ofPlayURL: resolved)
        XCTAssertEqual(origin?.sid, ServiceID.tidal)
        XCTAssertEqual(origin?.itemID, "track:5566")
    }

    /// An expired URL is what the queue holds when repair runs, and it must
    /// resolve back to the same origin as the URL that was recorded.
    func testExpiredURLStillFindsItsOrigin() {
        let fresh = "https://lgf.audio.tidal.com/mediatracks/blob777/0.flac?token=new&Expires=1900000000"
        let expired = "https://lgf.audio.tidal.com/mediatracks/blob777/0.flac?token=old&Expires=1700000000"
        ResolvedPlaybackRegistry.remember(playURL: fresh, sid: ServiceID.tidal, itemID: "track:1")
        XCTAssertEqual(ResolvedPlaybackRegistry.origin(ofPlayURL: expired)?.itemID, "track:1")
    }

    func testUnknownURLHasNoOrigin() {
        XCTAssertNil(ResolvedPlaybackRegistry.origin(ofPlayURL: "https://cdn.example.com/never-seen.flac"))
    }

    func testEmptyItemIDIsNotRecorded() {
        let resolved = "https://cdn.example.com/t.flac?token=a"
        ResolvedPlaybackRegistry.remember(playURL: resolved, sid: 174, itemID: "")
        XCTAssertNil(ResolvedPlaybackRegistry.origin(ofPlayURL: resolved))
    }
}
