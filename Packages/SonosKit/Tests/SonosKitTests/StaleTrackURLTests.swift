import XCTest
@testable import SonosKit

final class StaleTrackURLTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Expiry parsing

    func testReadsEpochSecondsExpiry() {
        let uri = "https://lgf.audio.tidal.com/mediatracks/abc/0.flac?token=xyz&Expires=1799999000"
        XCTAssertEqual(StaleTrackURL.expiry(in: uri),
                       Date(timeIntervalSince1970: 1_799_999_000))
        XCTAssertTrue(StaleTrackURL.isExpired(uri, now: now))
    }

    func testReadsEpochMillisecondsExpiry() {
        // Same instant expressed in milliseconds must not be read as the
        // year 59000 — that would make an expired URL look valid forever.
        let uri = "https://cdn.example.com/track.flac?exp=1799999000000"
        XCTAssertEqual(StaleTrackURL.expiry(in: uri),
                       Date(timeIntervalSince1970: 1_799_999_000))
        XCTAssertTrue(StaleTrackURL.isExpired(uri, now: now))
    }

    func testFutureExpiryIsNotStale() {
        let uri = "https://cdn.example.com/track.flac?token=t&Expires=1800009999"
        XCTAssertFalse(StaleTrackURL.isExpired(uri, now: now))
        XCTAssertFalse(StaleTrackURL.isStale(uri, playbackFailed: false, now: now))
    }

    func testExpiryWithinToleranceIsNotYetExpired() {
        // Clock skew against the signing service must not discard a URL that
        // would still have played.
        let uri = "https://cdn.example.com/track.flac?Expires=1799999990"
        XCTAssertFalse(StaleTrackURL.isExpired(uri, now: now, tolerance: 30))
        XCTAssertTrue(StaleTrackURL.isExpired(uri, now: now, tolerance: 5))
    }

    func testAmazonStyleLifetimeCombinesWithSignedDate() {
        let uri = "https://s3.example.com/t.mp3?X-Amz-Date=20260101T000000Z&X-Amz-Expires=3600"
        let expected = ISO8601DateFormatter().date(from: "2026-01-01T01:00:00Z")
        XCTAssertEqual(StaleTrackURL.expiry(in: uri), expected)
    }

    func testAmazonLifetimeWithoutSignedDateIsUnreadable() {
        let uri = "https://s3.example.com/t.mp3?X-Amz-Expires=3600"
        XCTAssertNil(StaleTrackURL.expiry(in: uri))
    }

    func testMalformedQueryDoesNotDiscardTheWholeURL() {
        // An unencoded character makes URLComponents return nil; losing the
        // URL entirely would read as "no expiry", i.e. never stale.
        let uri = "https://cdn.example.com/a track.flac?Expires=1799999000&title=a|b"
        XCTAssertTrue(StaleTrackURL.isExpired(uri, now: now))
    }

    /// TIDAL's CDN puts the expiry at the head of the token value —
    /// `token=<epoch>~<hmac>` — with no Expires parameter at all. Such a row
    /// is unplayable and must be flagged.
    func testAkamaiStyleTokenExpiry() {
        let uri = "https://lgf.audio.tidal.com/mediatracks/abc/0.flac?token=1787287532~MzUxNzZl"
        XCTAssertEqual(StaleTrackURL.expiry(in: uri),
                       Date(timeIntervalSince1970: 1_787_287_532))
        XCTAssertTrue(StaleTrackURL.isExpired(uri, now: now))
    }

    func testHdntsEmbeddedExpiry() {
        let uri = "https://cdn.example.com/t.m3u8?hdnts=st=1787280000~exp=1787287532~acl=/*~hmac=ab"
        XCTAssertEqual(StaleTrackURL.expiry(in: uri),
                       Date(timeIntervalSince1970: 1_787_287_532))
    }

    /// A token that does not lead with an epoch must stay unreadable, not
    /// become a fabricated expiry.
    func testOpaqueTokenStillUnreadable() {
        let uri = "https://cdn.example.com/t.flac?token=MzUxNzZl~1787287532"
        XCTAssertNil(StaleTrackURL.expiry(in: uri))
    }

    // MARK: - Credentials and staleness

    func testUnsignedURLIsNeverStale() {
        let uri = "https://cdn.example.com/open/track.flac"
        XCTAssertNil(StaleTrackURL.expiry(in: uri))
        XCTAssertFalse(StaleTrackURL.carriesRotatingCredential(uri))
        XCTAssertFalse(StaleTrackURL.isStale(uri, playbackFailed: true))
    }

    func testSignedURLWithNoReadableExpiryIsStaleOnlyAfterFailure() {
        let uri = "https://lgf.audio.tidal.com/mediatracks/abc/0.flac?token=opaque"
        XCTAssertNil(StaleTrackURL.expiry(in: uri))
        XCTAssertTrue(StaleTrackURL.carriesRotatingCredential(uri))
        XCTAssertFalse(StaleTrackURL.isStale(uri, playbackFailed: false))
        XCTAssertTrue(StaleTrackURL.isStale(uri, playbackFailed: true))
    }

    func testServiceURIsAreOutOfScope() {
        // Sonos resolves these itself at play time, so they cannot go stale.
        for uri in ["x-sonosapi-hls-static:song%3a123?sid=204",
                    "x-rincon-queue:RINCON_1234#0",
                    "x-file-cifs://nas/music/track.flac"] {
            XCTAssertFalse(StaleTrackURL.isDirectStream(uri), uri)
            XCTAssertFalse(StaleTrackURL.isStale(uri, playbackFailed: true), uri)
        }
    }
}
