import XCTest
@testable import SonosKit

final class PlaybackTimeFormatTests: XCTestCase {

    func testMinutesAndSeconds() {
        XCTAssertEqual(PlaybackTimeFormat.string(0), "0:00")
        XCTAssertEqual(PlaybackTimeFormat.string(9), "0:09")
        XCTAssertEqual(PlaybackTimeFormat.string(70), "1:10")
        XCTAssertEqual(PlaybackTimeFormat.string(599), "9:59")
    }

    /// Without the carry an Audible chapter or a long DJ set reads as "78:00"
    /// in the history list and "1:18:00" on the transport.
    func testHoursAreCarriedRatherThanRunningTheMinutesUp() {
        XCTAssertEqual(PlaybackTimeFormat.string(3600), "1:00:00")
        XCTAssertEqual(PlaybackTimeFormat.string(4680), "1:18:00")
        XCTAssertEqual(PlaybackTimeFormat.string(3661), "1:01:01")
    }

    func testLongAudiobooks() {
        XCTAssertEqual(PlaybackTimeFormat.string(36_000), "10:00:00")
    }

    func testSecondsAreTruncatedNotRounded() {
        // Matching the scrubber: a readout that rounds up shows a second the
        // playhead has not reached.
        XCTAssertEqual(PlaybackTimeFormat.string(59.9), "0:59")
    }

    func testNegativeAndNonFiniteInputsAreClamped() {
        // A seek can briefly report a negative offset; a NaN would otherwise
        // render as garbage next to the scrubber.
        XCTAssertEqual(PlaybackTimeFormat.string(-5), "0:00")
        XCTAssertEqual(PlaybackTimeFormat.string(.nan), "0:00")
        XCTAssertEqual(PlaybackTimeFormat.string(.infinity), "0:00")
    }

    func testIntegerConvenienceMatches() {
        XCTAssertEqual(PlaybackTimeFormat.string(seconds: 4680),
                       PlaybackTimeFormat.string(4680))
    }

    // MARK: Parsing

    func testParsesTheSpeakerDurationForms() {
        XCTAssertEqual(PlaybackTimeFormat.seconds(from: "0:03:45"), 225)
        XCTAssertEqual(PlaybackTimeFormat.seconds(from: "3:45"), 225)
        XCTAssertEqual(PlaybackTimeFormat.seconds(from: "1:18:00"), 4680)
        XCTAssertEqual(PlaybackTimeFormat.seconds(from: "0:03:45.120")!, 225.12, accuracy: 0.001)
        XCTAssertEqual(PlaybackTimeFormat.seconds(from: "90"), 90)
    }

    func testUnparseableDurationsAreNilNotZero() {
        XCTAssertNil(PlaybackTimeFormat.seconds(from: ""))
        XCTAssertNil(PlaybackTimeFormat.seconds(from: "NOT_IMPLEMENTED"))
        XCTAssertNil(PlaybackTimeFormat.seconds(from: "1:2:3:4"))
        XCTAssertNil(PlaybackTimeFormat.seconds(from: "-1:00"))
        XCTAssertNil(PlaybackTimeFormat.seconds(from: "1.5:00"))
    }

    func testRoundTrip() {
        for seconds in [0.0, 9, 70, 599, 3600, 4680, 36_000] {
            XCTAssertEqual(PlaybackTimeFormat.seconds(from: PlaybackTimeFormat.string(seconds)), seconds)
        }
    }
}

final class QueuePlaytimeTests: XCTestCase {

    private func item(_ id: Int, _ duration: String) -> QueueItem {
        QueueItem(id: id, title: "t", duration: duration)
    }

    func testSumsKnownDurations() {
        let p = QueuePlaytime(items: [item(1, "0:03:00"), item(2, "0:02:30")])
        XCTAssertEqual(p.knownSeconds, 330)
        XCTAssertFalse(p.isPartial)
        XCTAssertEqual(p.label, "5:30")
    }

    func testMissingDurationsMarkTheEstimatePartial() {
        let p = QueuePlaytime(items: [item(1, "0:03:00"), item(2, "")])
        XCTAssertEqual(p.unknownCount, 1)
        XCTAssertTrue(p.isPartial)
        XCTAssertEqual(p.label, "~3:00")
    }

    func testUnloadedTailMarksTheEstimatePartial() {
        let p = QueuePlaytime(items: [item(1, "0:03:00")], totalCount: 40)
        XCTAssertEqual(p.unloadedCount, 39)
        XCTAssertEqual(p.label, "~3:00")
    }

    func testNothingKnownIsEmpty() {
        XCTAssertTrue(QueuePlaytime(items: [item(1, "")]).isEmpty)
        XCTAssertTrue(QueuePlaytime(items: []).isEmpty)
    }

    // MARK: remaining

    func testRemainingCountsRestOfCurrentTrackAndEverythingAfter() {
        let items = [item(1, "0:03:00"), item(2, "0:04:00"), item(3, "0:05:00")]
        let p = QueuePlaytime.remaining(items: items, currentTrack: 2, elapsed: 60)
        XCTAssertEqual(p.knownSeconds, 180 + 300)
        XCTAssertFalse(p.isPartial)
        XCTAssertEqual(p.label, "8:00")
    }

    func testRemainingIgnoresRowsBeforeCurrentAndClampsElapsed() {
        let items = [item(1, "0:03:00"), item(2, "0:04:00")]
        XCTAssertEqual(QueuePlaytime.remaining(items: items, currentTrack: 2, elapsed: 999).knownSeconds, 0)
        XCTAssertEqual(QueuePlaytime.remaining(items: items, currentTrack: 2, elapsed: -5).knownSeconds, 240)
    }

    func testRemainingMarksUnknownAndUnloadedRowsPartial() {
        let items = [item(1, "0:03:00"), item(2, ""), item(3, "0:01:00")]
        let p = QueuePlaytime.remaining(items: items, currentTrack: 1, elapsed: 0, totalCount: 10)
        XCTAssertEqual(p.unknownCount, 1)
        XCTAssertEqual(p.unloadedCount, 7)
        XCTAssertEqual(p.label, "~4:00")
    }
}
