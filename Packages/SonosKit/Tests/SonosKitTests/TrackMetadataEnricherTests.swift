import XCTest
@testable import SonosKit

/// `TrackMetadataEnricher` precedence: what the speaker reported wins unless it
/// is empty or a technical filename, and cached values fill gaps rather than
/// overwrite good data. Getting that backwards shows up as queue rows that flip
/// between the real title and a UUID.
///
/// The network self-heals (`ensureAppleMusicQueueMetadata`, `ensureLocalQueueArt`)
/// are not triggered — fixtures avoid the branches that fire them, so this
/// suite makes no network calls.
final class TrackMetadataEnricherTests: XCTestCase {

    private struct StubArt: AlbumArtSearchProtocol {
        func searchArtwork(artist: String, album: String) async -> String? { nil }
        func searchRadioTrackArt(artist: String, title: String) async -> String? { nil }
        func lookupArtworkByCatalogID(_ id: String) async -> String? { nil }
    }

    @MainActor
    private func make() -> TrackMetadataEnricher {
        TrackMetadataEnricher(albumArtSearch: StubArt())
    }

    private func row(_ id: Int, title: String = "", artist: String = "",
                     album: String = "", art: String? = nil,
                     uri: String? = "x-file-cifs://nas/music/song.flac") -> QueueItem {
        QueueItem(id: id, title: title, artist: artist, album: album,
                  albumArtURI: art, duration: "0:03:00", uri: uri)
    }

    private func track(_ title: String, artist: String = "A", album: String = "B",
                       art: String? = "http://art") -> TrackMetadataEnricher.CachedTrack {
        .init(title: title, artist: artist, album: album, artURL: art)
    }

    // MARK: - Cache

    @MainActor
    func testRememberThenLookup() {
        let e = make()
        e.remember(track("Real Title"), forURI: "x-sonos-http:abc.flac")

        XCTAssertEqual(e.cachedTrack(forURI: "x-sonos-http:abc.flac")?.title, "Real Title")
    }

    /// Speakers report the same track with and without percent-encoding, so a
    /// lookup must find the entry either way.
    @MainActor
    func testLookupMatchesAcrossPercentEncoding() {
        let e = make()
        e.remember(track("Real Title"), forURI: "x-file-cifs://nas/My%20Music/a.flac")

        XCTAssertNotNil(e.cachedTrack(forURI: "x-file-cifs://nas/My Music/a.flac"))
    }

    @MainActor
    func testResetDropsEverySessionCache() {
        let e = make()
        e.remember(track("T"), forURI: "uri")
        e.recordQueuePage([row(1)], for: "G1")
        e.cachedTrackByPosition["G1"] = [1: track("T")]

        e.reset()

        XCTAssertNil(e.cachedTrack(forURI: "uri"))
        XCTAssertTrue(e.lastQueueItems.isEmpty)
        XCTAssertTrue(e.cachedTrackByPosition.isEmpty)
    }

    // MARK: - Enrichment precedence

    /// A speaker that returns a filename for a direct-URL track must be
    /// overridden; the real name is in the play-time cache.
    @MainActor
    func testTechnicalTitleIsReplacedFromCache() {
        let e = make()
        let uri = "x-file-cifs://nas/music/9f2c1e.mp3"
        e.remember(track("Actual Song"), forURI: uri)

        let out = e.enrichQueueItemFromCache(row(1, title: "9f2c1e.mp3", uri: uri))

        XCTAssertEqual(out.title, "Actual Song")
    }

    @MainActor
    func testEmptyTitleIsFilledFromCache() {
        let e = make()
        let uri = "x-file-cifs://nas/music/x.flac"
        e.remember(track("Actual Song"), forURI: uri)

        XCTAssertEqual(e.enrichQueueItemFromCache(row(1, uri: uri)).title, "Actual Song")
    }

    /// The speaker is authoritative when it gave a real title. A cache entry
    /// from an earlier resolution must not overwrite it.
    @MainActor
    func testGoodSpeakerTitleSurvivesEnrichment() {
        let e = make()
        let uri = "x-file-cifs://nas/music/x.flac"
        e.remember(track("Stale Cached Name"), forURI: uri)

        let out = e.enrichQueueItemFromCache(row(1, title: "What The Speaker Said", uri: uri))

        XCTAssertEqual(out.title, "What The Speaker Said")
    }

    @MainActor
    func testMissingArtIsFilledButPresentArtIsKept() {
        let e = make()
        let uri = "x-sonos-http:track.flac"
        e.remember(track("T", art: "http://cached-art"), forURI: uri)

        let filled = e.enrichQueueItemFromCache(row(1, title: "T", uri: uri))
        XCTAssertEqual(filled.albumArtURI, "http://cached-art")

        let kept = e.enrichQueueItemFromCache(
            row(2, title: "T", art: "http://row-art", uri: uri))
        XCTAssertEqual(kept.albumArtURI, "http://row-art",
                       "artwork the row already carries wins over the cache")
    }

    @MainActor
    func testEmptyArtistAndAlbumAreFilledFromCache() {
        let e = make()
        let uri = "x-sonos-http:track.flac"
        e.remember(track("T", artist: "The Artist", album: "The Album"), forURI: uri)

        let out = e.enrichQueueItemFromCache(row(1, title: "T", uri: uri))

        XCTAssertEqual(out.artist, "The Artist")
        XCTAssertEqual(out.album, "The Album")
    }

    /// A row with no cache entry and nothing to self-heal from comes back
    /// unchanged rather than blanked, keeping art resolved earlier in the same
    /// pass.
    @MainActor
    func testRowWithNoCacheEntryIsReturnedIntact() {
        let e = make()
        let out = e.enrichQueueItemFromCache(
            row(1, title: "Known", artist: "A", album: "B",
                art: "http://existing", uri: "x-sonos-http:unknown.flac"))

        XCTAssertEqual(out.title, "Known")
        XCTAssertEqual(out.albumArtURI, "http://existing")
    }

    @MainActor
    func testItemWithNoURIIsUntouched() {
        let e = make()
        let out = e.enrichQueueItemFromCache(row(1, title: "Line In", uri: nil))

        XCTAssertEqual(out.title, "Line In")
    }

    // MARK: - Local album art

    @MainActor
    func testLocalAlbumKeyIsStableAcrossCase() {
        XCTAssertEqual(TrackMetadataEnricher.localAlbumKey(artist: "AC/DC", album: "Back In Black"),
                       TrackMetadataEnricher.localAlbumKey(artist: "ac/dc", album: "back in black"))
    }

    /// The getaa proxy URL a speaker returns for a local-library row is known
    /// to 404, which is why those rows resolve through iTunes instead.
    @MainActor
    func testGetaaArtOnALocalRowIsTreatedAsUnreliable() {
        XCTAssertTrue(TrackMetadataEnricher.isUnreliableLocalArt(
            uri: "x-file-cifs://nas/music/a.flac",
            art: "http://10.0.0.1:1400/getaa?u=x-file-cifs%3a%2f%2fnas"))
    }

    @MainActor
    func testRealArtOnALocalRowIsTrusted() {
        XCTAssertFalse(TrackMetadataEnricher.isUnreliableLocalArt(
            uri: "x-file-cifs://nas/music/a.flac",
            art: "https://is1-ssl.mzstatic.com/image/thumb/600x600.jpg"))
    }

    // MARK: - Queue page recording

    /// Rows are enriched on the way in. The transport delegate reads this
    /// dictionary to recover a bare now-playing row, so it must hold enriched
    /// rows only.
    @MainActor
    func testRecordedQueuePagesAreEnrichedOnTheWayIn() {
        let e = make()
        let uri = "x-sonos-http:9f2c.mp3"
        e.remember(track("Actual Song"), forURI: uri)

        e.recordQueuePage([row(1, title: "9f2c.mp3", uri: uri)], for: "G1")

        XCTAssertEqual(e.lastQueueItems["G1"]?.first?.title, "Actual Song",
                       "storage must not be reachable with unenriched rows")
    }

    @MainActor
    func testForgetQueuePageClearsOnlyThatGroup() {
        let e = make()
        e.recordQueuePage([row(1, title: "A")], for: "G1")
        e.recordQueuePage([row(1, title: "B")], for: "G2")

        e.forgetQueuePage(for: "G1")

        XCTAssertNil(e.lastQueueItems["G1"])
        XCTAssertNotNil(e.lastQueueItems["G2"])
    }

    @MainActor
    func testRecordingAnEmptyPageIsIgnored() {
        let e = make()
        e.recordQueuePage([row(1, title: "A")], for: "G1")

        e.recordQueuePage([], for: "G1")

        XCTAssertNotNil(e.lastQueueItems["G1"],
                        "an empty read must not wipe a good page")
    }
}
