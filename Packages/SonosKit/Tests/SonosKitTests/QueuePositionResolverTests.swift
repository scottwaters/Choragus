import XCTest
@testable import SonosKit

/// Queue-position resolution: which row is playing when the speaker's report,
/// the title fallback and queue paging disagree.
final class QueuePositionResolverTests: XCTestCase {

    private func item(_ id: Int, _ title: String, _ artist: String = "A") -> QueueItem {
        QueueItem(id: id, title: title, artist: artist)
    }

    private var queue: [QueueItem] {
        [item(1, "One"), item(2, "Two"), item(3, "Three")]
    }

    // MARK: - The speaker's position wins

    func testSpeakerPositionIsAuthoritative() {
        let r = QueuePositionResolver.resolve(
            report: .init(trackNumber: 2, trackURI: "x", title: "One"),
            queue: queue, playingFromQueue: true, authoritativelyResolvedURI: nil)
        // Title says row 1, the speaker says row 2. The speaker wins.
        XCTAssertEqual(r, .position(2, basis: .trackNumber))
        XCTAssertTrue(QueuePositionResolver.confirmsAuthority(r))
    }

    func testNotPlayingFromQueueHoldsRegardlessOfReport() {
        let r = QueuePositionResolver.resolve(
            report: .init(trackNumber: 2, title: "Two"),
            queue: queue, playingFromQueue: false, authoritativelyResolvedURI: nil)
        XCTAssertEqual(r, .hold(.notPlayingFromQueue))
    }

    // MARK: - Duplicate titles

    /// Several rows share a title; a title fallback that returns the first
    /// every time oscillates against the speaker's position.
    func testAmbiguousTitleHoldsRatherThanGuessing() {
        let dupes = [item(1, "Theme"), item(2, "Theme"), item(3, "Other")]
        let r = QueuePositionResolver.resolve(
            report: .init(trackNumber: nil, title: "Theme"),
            queue: dupes, playingFromQueue: true, authoritativelyResolvedURI: nil)
        XCTAssertEqual(r, .hold(.ambiguousTitle(matches: 2)))
    }

    func testArtistDisambiguatesASharedTitle() {
        let dupes = [item(1, "Theme", "Composer A"), item(2, "Theme", "Composer B")]
        let r = QueuePositionResolver.resolve(
            report: .init(title: "Theme", artist: "Composer B"),
            queue: dupes, playingFromQueue: true, authoritativelyResolvedURI: nil)
        XCTAssertEqual(r, .position(2, basis: .titleAndArtist))
    }

    func testTitleOnlyMatchWhenArtistDisagrees() {
        // Sonos reports a differently formatted artist for the same track;
        // a unique title match is still the right row.
        let r = QueuePositionResolver.resolve(
            report: .init(title: "Two", artist: "A (Remastered)"),
            queue: queue, playingFromQueue: true, authoritativelyResolvedURI: nil)
        XCTAssertEqual(r, .position(2, basis: .titleOnly))
    }

    // MARK: - Authority is not re-litigated

    func testConfirmedURIIsNotSecondGuessedByTitle() {
        // The speaker has stopped reporting a position, and the title happens
        // to match a different row. Holding is correct.
        let r = QueuePositionResolver.resolve(
            report: .init(trackNumber: nil, trackURI: "uri-2", title: "One"),
            queue: queue, playingFromQueue: true, authoritativelyResolvedURI: "uri-2")
        XCTAssertEqual(r, .hold(.alreadyAuthoritative))
    }

    func testDifferentURIIsStillResolvedByTitle() {
        // No artist in the report, so the title+artist pass cannot match and
        // the unique title carries it.
        let r = QueuePositionResolver.resolve(
            report: .init(trackURI: "uri-3", title: "One"),
            queue: queue, playingFromQueue: true, authoritativelyResolvedURI: "uri-2")
        XCTAssertEqual(r, .position(1, basis: .titleOnly))
    }

    func testOnlySpeakerPositionConfirmsAuthority() {
        // A title match must not close the door on later correction.
        XCTAssertFalse(QueuePositionResolver.confirmsAuthority(.position(1, basis: .titleAndArtist)))
        XCTAssertFalse(QueuePositionResolver.confirmsAuthority(.position(1, basis: .titleOnly)))
        XCTAssertFalse(QueuePositionResolver.confirmsAuthority(.hold(.noSignal)))
    }

    // MARK: - Paging and mutation windows

    func testPositionBeyondTheLoadedQueueIsStillUsed() {
        // Queue paging has not reached row 120 yet, but the speaker is
        // playing it. Holding at the old row would freeze the highlight.
        let r = QueuePositionResolver.resolve(
            report: .init(trackNumber: 120, title: "Later"),
            queue: queue, playingFromQueue: true, authoritativelyResolvedURI: nil)
        XCTAssertEqual(r, .position(120, basis: .trackNumberBeyondQueue))
        XCTAssertFalse(QueuePositionResolver.confirmsAuthority(r))
    }

    func testEmptyQueueWithAPositionStillReportsIt() {
        let r = QueuePositionResolver.resolve(
            report: .init(trackNumber: 4, title: "Anything"),
            queue: [], playingFromQueue: true, authoritativelyResolvedURI: nil)
        XCTAssertEqual(r, .position(4, basis: .trackNumberBeyondQueue))
    }

    // MARK: - Degenerate reports

    func testNoUsableSignalHolds() {
        let r = QueuePositionResolver.resolve(
            report: .init(), queue: queue,
            playingFromQueue: true, authoritativelyResolvedURI: nil)
        XCTAssertEqual(r, .hold(.noSignal))
    }

    func testZeroTrackNumberIsNotAPosition() {
        // Sonos reports 0 before the first track settles; row 0 does not exist.
        let r = QueuePositionResolver.resolve(
            report: .init(trackNumber: 0, title: "Two"),
            queue: queue, playingFromQueue: true, authoritativelyResolvedURI: nil)
        XCTAssertEqual(r, .position(2, basis: .titleOnly))
    }

    func testEmptyTitleIsNotMatched() {
        let withBlank = [item(1, ""), item(2, "Two")]
        let r = QueuePositionResolver.resolve(
            report: .init(title: ""), queue: withBlank,
            playingFromQueue: true, authoritativelyResolvedURI: nil)
        XCTAssertEqual(r, .hold(.noSignal))
    }

    func testUnknownTitleHoldsRatherThanMovingToRowOne() {
        let r = QueuePositionResolver.resolve(
            report: .init(title: "Not in queue"),
            queue: queue, playingFromQueue: true, authoritativelyResolvedURI: nil)
        XCTAssertEqual(r, .hold(.noSignal))
    }
}
