import XCTest
@testable import SonosKit

/// Covers the pure scroll-wheel → volume-step mapping introduced in v3.6.
final class ScrollVolumeAccumulatorTests: XCTestCase {

    // MARK: - Sign convention

    func testScrollUpProducesPositiveStep() {
        var a = ScrollVolumeAccumulator()
        // macOS scrollingDeltaY for scroll-up is negative; accumulator
        // flips sign so that scroll-up → volume-up.
        XCTAssertEqual(a.consume(deltaY: -1.0), 1)
    }

    func testScrollDownProducesNegativeStep() {
        var a = ScrollVolumeAccumulator()
        XCTAssertEqual(a.consume(deltaY: 1.0), -1)
    }

    // MARK: - Threshold accumulation

    func testSubThresholdDeltaReturnsZero() {
        var a = ScrollVolumeAccumulator(stepThreshold: 1.0)
        XCTAssertEqual(a.consume(deltaY: -0.4), 0)
        XCTAssertEqual(a.accumulated, 0.4, accuracy: 0.001)
    }

    func testSubThresholdDeltasAccumulateUntilStepEmitted() {
        var a = ScrollVolumeAccumulator(stepThreshold: 1.0)
        XCTAssertEqual(a.consume(deltaY: -0.4), 0)
        XCTAssertEqual(a.consume(deltaY: -0.4), 0)
        XCTAssertEqual(a.consume(deltaY: -0.4), 1, "0.4+0.4+0.4 = 1.2 crosses the threshold once")
        XCTAssertEqual(a.accumulated, 0.2, accuracy: 0.001, "remainder after emitting 1 step")
    }

    // MARK: - Direction change

    func testReversingDirectionReducesAccumulator() {
        var a = ScrollVolumeAccumulator(stepThreshold: 1.0)
        _ = a.consume(deltaY: -0.6)    // accumulator = 0.6
        _ = a.consume(deltaY: 0.4)     // accumulator = 0.2
        XCTAssertEqual(a.accumulated, 0.2, accuracy: 0.001)
    }

    // MARK: - Flick-scroll cap

    func testLargeDeltaIsClampedToMaxStepPerEvent() {
        var a = ScrollVolumeAccumulator(maxStepPerEvent: 3)
        // Huge upward scroll would naively produce 50 steps; cap it at 3.
        XCTAssertEqual(a.consume(deltaY: -50.0), 3)
    }

    func testLargeNegativeDeltaIsClampedToMaxStepPerEvent() {
        var a = ScrollVolumeAccumulator(maxStepPerEvent: 3)
        XCTAssertEqual(a.consume(deltaY: 50.0), -3)
    }

    // MARK: - Reset

    func testResetClearsAccumulator() {
        var a = ScrollVolumeAccumulator()
        _ = a.consume(deltaY: -0.5)
        a.reset()
        XCTAssertEqual(a.accumulated, 0.0)
        XCTAssertEqual(a.consume(deltaY: -0.4), 0, "previous 0.5 should be gone")
    }

    // Note: stepThreshold beyond the default of 1.0 is not exercised by
    // production call sites (see `ScrollVolumeAccumulator.init`). The
    // accumulator emits `Int(accumulated.rounded(.towardZero))` steps once
    // the threshold is crossed, so a higher threshold only delays the first
    // emission — it doesn't scale the step size per unit of scroll. If a
    // future use case needs the latter, change the semantics explicitly.
}
