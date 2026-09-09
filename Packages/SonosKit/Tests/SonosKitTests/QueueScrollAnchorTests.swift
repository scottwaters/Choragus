import XCTest
@testable import SonosKit

/// Queue auto-scroll: launch from mid-queue and the head-of-queue case.
final class QueueScrollAnchorTests: XCTestCase {

    func testAnchorsThePreviousRowSoThePlayingTrackSitsSecond() {
        XCTAssertEqual(QueueScrollAnchor.target(currentTrack: 5, queueCount: 20), 4)
    }

    func testFirstTrackAnchorsItself() {
        // No previous row exists; anchoring to 0 would scroll nowhere.
        XCTAssertEqual(QueueScrollAnchor.target(currentTrack: 1, queueCount: 20), 1)
    }

    func testSecondTrackAnchorsTheFirst() {
        XCTAssertEqual(QueueScrollAnchor.target(currentTrack: 2, queueCount: 20), 1)
    }

    func testNothingPlayingHasNoTarget() {
        XCTAssertNil(QueueScrollAnchor.target(currentTrack: 0, queueCount: 20))
    }

    func testEmptyQueueHasNoTarget() {
        XCTAssertNil(QueueScrollAnchor.target(currentTrack: 3, queueCount: 0))
    }

    /// Near the end the anchor cannot reach the top — there are too few rows
    /// below it. The request is still correct; the list scrolls as far as it
    /// can.
    func testLastTrackStillRequestsItsPredecessor() {
        XCTAssertEqual(QueueScrollAnchor.target(currentTrack: 20, queueCount: 20), 19)
    }

    /// The speaker can report a position past the loaded rows while paging is
    /// still in flight. Requesting it is a no-op rather than an error.
    func testPositionBeyondLoadedRowsStillProducesATarget() {
        XCTAssertEqual(QueueScrollAnchor.target(currentTrack: 120, queueCount: 100), 119)
    }

    // MARK: - Initial scroll

    func testInitialScrollRunsWhenPlaybackIsConfirmedAfterLoading() {
        // isQueueSource flips true after currentTrack and the rows are set;
        // no other watcher fires for that flip.
        XCTAssertTrue(QueueScrollAnchor.shouldPerformInitialScroll(
            hasScrolledAlready: false, isPlayingFromQueue: true,
            currentTrack: 7, queueCount: 30))
    }

    func testInitialScrollDoesNotRepeat() {
        XCTAssertFalse(QueueScrollAnchor.shouldPerformInitialScroll(
            hasScrolledAlready: true, isPlayingFromQueue: true,
            currentTrack: 7, queueCount: 30))
    }

    func testInitialScrollWaitsForQueuePlayback() {
        // Radio or line-in: no queue row is playing, so nothing to scroll to.
        XCTAssertFalse(QueueScrollAnchor.shouldPerformInitialScroll(
            hasScrolledAlready: false, isPlayingFromQueue: false,
            currentTrack: 7, queueCount: 30))
    }

    func testInitialScrollWaitsForRows() {
        XCTAssertFalse(QueueScrollAnchor.shouldPerformInitialScroll(
            hasScrolledAlready: false, isPlayingFromQueue: true,
            currentTrack: 7, queueCount: 0))
    }

    func testInitialScrollWaitsForAPosition() {
        XCTAssertFalse(QueueScrollAnchor.shouldPerformInitialScroll(
            hasScrolledAlready: false, isPlayingFromQueue: true,
            currentTrack: 0, queueCount: 30))
    }
}
