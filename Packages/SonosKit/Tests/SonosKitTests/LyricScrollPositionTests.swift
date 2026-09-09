import XCTest
@testable import SonosKit

/// Synced-lyric interpolation. Failures are visible on screen within one
/// frame; a NaN offset renders a blank view rather than crashing.
final class LyricScrollPositionTests: XCTestCase {

    private let lines = [
        LyricScrollPosition.Line(time: 10, text: "First"),
        LyricScrollPosition.Line(time: 20, text: "Second"),
        LyricScrollPosition.Line(time: 30, text: "Third"),
    ]

    private func index(_ position: Double, _ lines: [LyricScrollPosition.Line]? = nil) -> Double {
        LyricScrollPosition.fractionalIndex(for: position, lines: lines ?? self.lines)
    }

    func testExactStampLandsOnTheLine() {
        XCTAssertEqual(index(10), 0, accuracy: 0.0001)
        XCTAssertEqual(index(20), 1, accuracy: 0.0001)
    }

    func testHalfwayBetweenStampsIsHalfway() {
        XCTAssertEqual(index(15), 0.5, accuracy: 0.0001)
        XCTAssertEqual(index(27.5), 1.75, accuracy: 0.0001)
    }

    /// Pre-roll is negative so the first line glides up from below, arriving
    /// exactly as its stamp does.
    func testPreRollIsNegative() {
        XCTAssertEqual(index(0), -1, accuracy: 0.0001)
        XCTAssertEqual(index(5), -0.5, accuracy: 0.0001)
        XCTAssertEqual(index(9.99), -0.001, accuracy: 0.001)
    }

    /// No next stamp to glide toward, so the last line holds.
    func testAfterTheLastStampHolds() {
        XCTAssertEqual(index(30), 2, accuracy: 0.0001)
        XCTAssertEqual(index(300), 2, accuracy: 0.0001)
    }

    // MARK: - Degenerate input

    func testNoLyricsIsZeroRatherThanACrash() {
        XCTAssertEqual(index(42, []), 0)
    }

    /// Two lines sharing a stamp give a zero span; dividing would yield
    /// infinity, and SwiftUI renders NaN offsets as nothing at all.
    func testDuplicateTimestampsDoNotDivideByZero() {
        let duplicated = [
            LyricScrollPosition.Line(time: 10, text: "A"),
            LyricScrollPosition.Line(time: 10, text: "B"),
            LyricScrollPosition.Line(time: 20, text: "C"),
        ]
        let result = index(10, duplicated)
        XCTAssertTrue(result.isFinite)
        XCTAssertEqual(result, 1, accuracy: 0.0001)
    }

    func testAFirstStampAtZeroHasNoPreRoll() {
        let fromZero = [
            LyricScrollPosition.Line(time: 0, text: "Immediate"),
            LyricScrollPosition.Line(time: 10, text: "Later"),
        ]
        XCTAssertEqual(index(0, fromZero), 0, accuracy: 0.0001)
        XCTAssertEqual(index(5, fromZero), 0.5, accuracy: 0.0001)
    }

    func testNegativePositionStaysBoundedDuringPreRoll() {
        // A seek to before the track start must not produce a wild offset.
        let result = index(-5)
        XCTAssertTrue(result.isFinite)
        XCTAssertLessThan(result, 0)
    }

    func testSingleLineHoldsThroughout() {
        let one = [LyricScrollPosition.Line(time: 10, text: "Only")]
        XCTAssertEqual(index(10, one), 0, accuracy: 0.0001)
        XCTAssertEqual(index(500, one), 0, accuracy: 0.0001)
    }

    /// Binary search must agree with a linear scan at every stamp, including
    /// the even/odd boundaries where a mid-point calculation can be off by one.
    func testBinarySearchAgreesWithALinearScanOnADenseFile() {
        let dense = (0..<200).map { LyricScrollPosition.Line(time: Double($0) * 2, text: "L\($0)") }
        for stamp in stride(from: 0.0, to: 398.0, by: 1.0) {
            let expected = Double(dense.lastIndex { $0.time <= stamp } ?? -1)
            let actual = index(stamp, dense)
            XCTAssertEqual(floor(actual), expected, accuracy: 0.0001, "at \(stamp)")
        }
    }
}
