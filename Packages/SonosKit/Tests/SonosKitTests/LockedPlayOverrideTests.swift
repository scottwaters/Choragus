import XCTest
@testable import SonosKit

/// Headsets emit a play command when a call ends; the locked-screen guard
/// absorbs that burst. Repeated deliberate presses override the guard.
final class LockedPlayOverrideTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ offset: TimeInterval) -> Date { start.addingTimeInterval(offset) }

    func testThreeDeliberatePressesGrantOnce() {
        var override = LockedPlayOverride()
        XCTAssertFalse(override.registerRefusedPress(at: at(0)))
        XCTAssertFalse(override.registerRefusedPress(at: at(1)))
        XCTAssertTrue(override.registerRefusedPress(at: at(2)))
    }

    func testGrantClearsTheTally() {
        // A trailing duplicate must not ride in on the grant just given.
        var override = LockedPlayOverride()
        _ = override.registerRefusedPress(at: at(0))
        _ = override.registerRefusedPress(at: at(1))
        XCTAssertTrue(override.registerRefusedPress(at: at(2)))
        XCTAssertFalse(override.registerRefusedPress(at: at(2.5)))
        XCTAssertEqual(override.pendingPresses, 1)
    }

    /// A headset emitting several play events milliseconds apart is one device
    /// burst, not a person.
    func testDeviceEventBurstNeverGrants() {
        var override = LockedPlayOverride()
        var granted = false
        for step in stride(from: 0.0, through: 1.0, by: 0.05) {
            granted = override.registerRefusedPress(at: at(step)) || granted
        }
        XCTAssertFalse(granted, "a sustained device burst must never grant")
        XCTAssertEqual(override.pendingPresses, 1)
    }

    func testPressesOutsideTheWindowDoNotAccumulate() {
        var override = LockedPlayOverride()
        XCTAssertFalse(override.registerRefusedPress(at: at(0)))
        XCTAssertFalse(override.registerRefusedPress(at: at(6)))   // first expired
        XCTAssertFalse(override.registerRefusedPress(at: at(12)))  // second expired
    }

    func testWindowSlidesRatherThanResetting() {
        // Presses at 0, 3 and 5.5: the first has expired by 5.5, so two
        // remain and no grant is given until a third lands inside the window.
        var override = LockedPlayOverride()
        XCTAssertFalse(override.registerRefusedPress(at: at(0)))
        XCTAssertFalse(override.registerRefusedPress(at: at(3)))
        XCTAssertFalse(override.registerRefusedPress(at: at(5.5)))
        XCTAssertTrue(override.registerRefusedPress(at: at(6)))
    }

    /// Just past the minimum gap counts. The boundary itself is not asserted:
    /// these are Double intervals, and at(0.6) - at(0.3) lands a hair under
    /// 0.3 in binary floating point.
    func testJustPastTheMinimumGapCounts() {
        var override = LockedPlayOverride()
        XCTAssertFalse(override.registerRefusedPress(at: at(0)))
        XCTAssertFalse(override.registerRefusedPress(at: at(0.31)))
        XCTAssertTrue(override.registerRefusedPress(at: at(0.62)))
    }

    func testResetClearsPendingPresses() {
        // Lock, unlock, and the media-keys toggle all reset, so a burst
        // cannot span two sessions.
        var override = LockedPlayOverride()
        _ = override.registerRefusedPress(at: at(0))
        _ = override.registerRefusedPress(at: at(1))
        override.reset()
        XCTAssertEqual(override.pendingPresses, 0)
        XCTAssertFalse(override.registerRefusedPress(at: at(2)))
    }

    func testConfigurationIsHonoured() {
        var override = LockedPlayOverride(requiredPresses: 2, window: 1, minimumGap: 0.1)
        XCTAssertFalse(override.registerRefusedPress(at: at(0)))
        XCTAssertTrue(override.registerRefusedPress(at: at(0.5)))
    }
}
