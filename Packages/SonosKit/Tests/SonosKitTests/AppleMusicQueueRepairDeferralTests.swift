import XCTest
@testable import SonosKit

/// The Apple Music row repair cannot swap the playing row or the one after
/// it. Those used to be dropped, leaving the row bare for good; now they are
/// deferred to a later pass once playback has moved on.
@MainActor
final class AppleMusicQueueRepairDeferralTests: XCTestCase {
    func testThePlayingRowAndTheNextAreDeferred() {
        XCTAssertTrue(SonosManager.repairShouldDefer(position: 1, playing: 1))
        XCTAssertTrue(SonosManager.repairShouldDefer(position: 2, playing: 1))
    }
    func testOtherRowsRepairNow() {
        XCTAssertFalse(SonosManager.repairShouldDefer(position: 3, playing: 1))
        XCTAssertFalse(SonosManager.repairShouldDefer(position: 1, playing: 2), "once playback has moved past, the old playing row is fair game")
    }
    func testWithNoKnownPlayingPositionNothingIsDeferred() {
        XCTAssertFalse(SonosManager.repairShouldDefer(position: 1, playing: -1))
    }
    func testRetryBudgetIsBounded() {
        XCTAssertGreaterThan(SonosManager.repairMaxPasses, 1)
        XCTAssertGreaterThanOrEqual(SonosManager.repairMaxPasses * Int(SonosManager.repairRetryDelay), 600,
                                    "must outlast a long playing track — a 4:11 song exhausted a 4-minute budget")
        XCTAssertLessThanOrEqual(SonosManager.repairMaxPasses * Int(SonosManager.repairRetryDelay), 1800,
                                 "still gives up within half an hour so a stuck queue cannot loop forever")
    }
}
