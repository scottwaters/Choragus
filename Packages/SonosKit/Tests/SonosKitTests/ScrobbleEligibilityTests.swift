import XCTest
@testable import SonosKit

/// Covers `ScrobbleManager.isEligible`, which is the gate between the local
/// history table and outbound scrobble submissions. Regressions here cause
/// one of two bad outcomes: (a) eligible listens silently dropped, or
/// (b) junk (stations, short previews, ancient rows) getting pushed to
/// Last.fm as real plays.
@MainActor
final class ScrobbleEligibilityTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeEntry(
        title: String = "Song",
        artist: String = "Artist",
        duration: TimeInterval = 180,
        groupName: String = "Office",
        sourceURI: String? = nil,
        ageSeconds: TimeInterval = 60
    ) -> PlayHistoryEntry {
        PlayHistoryEntry(
            timestamp: now.addingTimeInterval(-ageSeconds),
            title: title,
            artist: artist,
            sourceURI: sourceURI,
            groupName: groupName,
            duration: duration
        )
    }

    private func isEligible(
        _ entry: PlayHistoryEntry,
        rooms: Set<String> = [],
        services: Set<String> = []
    ) -> Bool {
        ScrobbleManager.isEligible(entry, enabledRooms: rooms, enabledMusicServices: services, now: now)
    }

    // MARK: - Universal rules

    func testBasicTrackIsEligible() {
        XCTAssertTrue(isEligible(makeEntry()))
    }

    func testMissingArtistIsIneligible() {
        XCTAssertFalse(isEligible(makeEntry(artist: "")))
    }

    func testMissingTitleIsIneligible() {
        XCTAssertFalse(isEligible(makeEntry(title: "")))
    }

    func testWhitespaceOnlyArtistIsIneligible() {
        XCTAssertFalse(isEligible(makeEntry(artist: "   ")))
    }

    func testShortTrackIsIneligible() {
        // Last.fm explicitly rejects < 30 s — but only when we actually
        // know the duration. Radio streams (duration == 0) are handled
        // separately; see `testZeroDurationIsEligibleAsUnknown`.
        XCTAssertFalse(isEligible(makeEntry(duration: 29)))
        XCTAssertFalse(isEligible(makeEntry(duration: 1)))
    }

    func testThirtySecondTrackIsEligible() {
        // Boundary: exactly 30 s must pass.
        XCTAssertTrue(isEligible(makeEntry(duration: 30)))
    }

    func testZeroDurationIsEligibleAsUnknown() {
        // Sonos reports continuous radio streams with no duration. Those
        // rows have real artist + title but duration == 0, and rejecting
        // them as "< 30 s" permanently blocks every radio scrobble.
        XCTAssertTrue(isEligible(makeEntry(duration: 0)))
    }

    func testAncientTrackIsIneligible() {
        // 14-day window — 15 days old must fail.
        let fifteenDays: TimeInterval = 15 * 24 * 3600
        XCTAssertFalse(isEligible(makeEntry(ageSeconds: fifteenDays)))
    }

    func testFourteenDayTrackIsEligible() {
        // Exactly at the boundary: 14 days = 14 * 86400.
        let fourteenDays: TimeInterval = 14 * 24 * 3600
        XCTAssertTrue(isEligible(makeEntry(ageSeconds: fourteenDays)))
    }

    // MARK: - Room filter

    func testEmptyRoomSetMatchesAnyRoom() {
        XCTAssertTrue(isEligible(makeEntry(groupName: "Basement"), rooms: []))
    }

    func testRoomFilterMatchesSingleRoom() {
        let e = makeEntry(groupName: "Office")
        XCTAssertTrue(isEligible(e, rooms: ["Office"]))
        XCTAssertFalse(isEligible(e, rooms: ["Kitchen"]))
    }

    func testRoomFilterMatchesGroupedNameVariants() {
        // Sonos group-name conventions vary: "+"-separated, coordinator-only,
        // custom group names. Substring match covers all of them so the user
        // doesn't have to anticipate the exact format Sonos picked.
        XCTAssertTrue(isEligible(
            makeEntry(groupName: "Office + Kitchen + Bedroom"),
            rooms: ["Kitchen"]
        ))
        XCTAssertTrue(isEligible(
            makeEntry(groupName: "Office, Kitchen"),
            rooms: ["Kitchen"]
        ))
        XCTAssertTrue(isEligible(
            makeEntry(groupName: "Office Group"),
            rooms: ["Office"]
        ))
        XCTAssertFalse(isEligible(
            makeEntry(groupName: "Office + Kitchen"),
            rooms: ["Basement"]
        ))
    }

    func testRoomFilterIsCaseInsensitive() {
        let e = makeEntry(groupName: "OFFICE + Kitchen")
        XCTAssertTrue(isEligible(e, rooms: ["office"]))
        XCTAssertTrue(isEligible(e, rooms: ["Office"]))
    }

    // MARK: - Classify verdict

    func testFilterIneligibilityIsNotPermanent() {
        // Room/service filters are user-editable, so failures must come back
        // as `.filteredOut` (not `.permanentlyIneligible`) so the caller
        // knows not to persist the decision.
        let e = makeEntry(groupName: "Basement")
        let verdict = ScrobbleManager.classify(
            e, enabledRooms: ["Office"], enabledMusicServices: [], now: now
        )
        XCTAssertEqual(verdict, .filteredOut(reason: "room not selected"))
    }

    func testStructuralIneligibilityIsPermanent() {
        let e = makeEntry(duration: 10)
        let verdict = ScrobbleManager.classify(
            e, enabledRooms: [], enabledMusicServices: [], now: now
        )
        XCTAssertEqual(verdict, .permanentlyIneligible(reason: "duration < 30s"))
    }

    // MARK: - Music service filter

    func testEmptyServiceSetMatchesAnyService() {
        XCTAssertTrue(isEligible(
            makeEntry(sourceURI: "x-sonosapi-stream:spotify:foo"),
            services: []
        ))
    }

    func testServiceFilterMatchesBySubstring() {
        let e = makeEntry(sourceURI: "x-sonos-http:track:spotify:12345.mp4")
        XCTAssertTrue(isEligible(e, services: ["Spotify"]))
        XCTAssertFalse(isEligible(e, services: ["TuneIn"]))
    }

    func testAppleMusicMatchesBySID() {
        // Real-world bug: Apple Music URIs never contain "apple music" —
        // they're tagged with `sid=204`. The filter must recognize the SID
        // or all Apple Music listens get silently service-blocked.
        let e = makeEntry(sourceURI: "x-sonos-http:song%3a1591055545.mp4?sid=204&flags=8232&sn=17")
        XCTAssertTrue(isEligible(e, services: ["Apple Music"]))
        XCTAssertFalse(isEligible(e, services: ["Spotify"]))
    }

    func testAppleMusicHLSVariantMatches() {
        // Apple Music also serves some tracks as HLS streams — the scheme
        // differs but the sid parameter is still 204.
        let e = makeEntry(sourceURI: "x-sonosapi-hls-static:song%3a1608226536?sid=204&flags=8232&sn=17")
        XCTAssertTrue(isEligible(e, services: ["Apple Music"]))
    }

    func testServiceSIDsFromLiveSonosHousehold() {
        // These SIDs were confirmed by a live `ListAvailableServices` call
        // against a Sonos One (household firmware 94.1). Earlier guesses
        // (TuneIn=65031, SoundCloud=151) silently broke filtering for
        // those services — these assertions pin the real values.
        XCTAssertTrue(isEligible(
            makeEntry(sourceURI: "x-sonosapi-stream:s12345?sid=254&flags=32"),
            services: ["TuneIn"]
        ))
        XCTAssertTrue(isEligible(
            makeEntry(sourceURI: "x-sonos-http:track%3a123.mp4?sid=160&flags=8232"),
            services: ["SoundCloud"]
        ))
        XCTAssertTrue(isEligible(
            makeEntry(sourceURI: "x-sonos-http:song%3a99?sid=201"),
            services: ["Amazon Music"]
        ))
        XCTAssertTrue(isEligible(
            makeEntry(sourceURI: "x-sonosapi-stream:xyz?sid=144"),
            services: ["Calm Radio"]
        ))
        XCTAssertTrue(isEligible(
            makeEntry(sourceURI: "x-sonosapi-hls:radio?sid=303"),
            services: ["Sonos Radio"]
        ))
    }

    func testUnknownServiceFallsBackToKeywordMatch() {
        // Services not in the SID map (new/niche additions) still get a
        // best-effort keyword match so adding a service name to the UI
        // doesn't require a code change to wire up matching.
        let e = makeEntry(sourceURI: "x-sonosapi-stream:myservice:station123")
        XCTAssertTrue(isEligible(e, services: ["MyService"]))
    }

    func testServiceFilterIsCaseInsensitive() {
        let e = makeEntry(sourceURI: "X-SONOSAPI-STREAM:SPOTIFY:FOO")
        XCTAssertTrue(isEligible(e, services: ["spotify"]))
    }

    func testEmptySourceURIBypassesServiceFilter() {
        // Local library / unknown source has no URI; treat as "match" so
        // users aren't forced to enumerate every possibility.
        XCTAssertTrue(isEligible(
            makeEntry(sourceURI: nil),
            services: ["Spotify"]
        ))
        XCTAssertTrue(isEligible(
            makeEntry(sourceURI: ""),
            services: ["Spotify"]
        ))
    }

    func testMultipleEnabledServicesAreOrMatched() {
        let e = makeEntry(sourceURI: "x-sonosapi-stream:tunein:s123")
        XCTAssertTrue(isEligible(e, services: ["Spotify", "TuneIn"]))
    }
}
