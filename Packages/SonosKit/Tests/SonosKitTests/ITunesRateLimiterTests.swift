import XCTest
@testable import SonosKit

/// `ITunesRateLimiter` lanes: the background lane (artwork, browse, backfill)
/// stops short of the full per-minute budget so the `.nowPlaying` lane always
/// has slots left. Without the reservation a queue-wide artwork re-pin holds
/// the window for minutes and the playing track's catalogue lookup is refused
/// on every attempt, leaving a bare Apple Music row without a length.
final class ITunesRateLimiterTests: XCTestCase {

    private func drainBackground(_ limiter: ITunesRateLimiter) async -> Int {
        var granted = 0
        while case .proceed = await limiter.acquire(lane: .background) {
            granted += 1
            if granted > 100 { XCTFail("background lane never saturated"); break }
        }
        return granted
    }

    func testBackgroundLaneStopsBelowSoftLimit() async {
        let limiter = ITunesRateLimiter()
        let granted = await drainBackground(limiter)
        let snapshot = await limiter.snapshot()
        XCTAssertEqual(granted, snapshot.softLimit - 2)
        XCTAssertEqual(snapshot.requestsInWindow, granted)
    }

    func testNowPlayingLaneProceedsWhenBackgroundIsSaturated() async {
        let limiter = ITunesRateLimiter()
        _ = await drainBackground(limiter)

        guard case .denied(.selfThrottle, _) = await limiter.acquire(lane: .background) else {
            return XCTFail("background lane should be refused once its share is spent")
        }
        let first = await limiter.acquire(lane: .nowPlaying)
        let second = await limiter.acquire(lane: .nowPlaying)
        XCTAssertEqual(first, .proceed)
        XCTAssertEqual(second, .proceed)

        // The reserved slots are part of the same window: once they are spent
        // the now-playing lane waits like everyone else rather than exceeding
        // the soft limit Apple's 403 threshold is measured against.
        guard case .denied(.selfThrottle, _) = await limiter.acquire(lane: .nowPlaying) else {
            return XCTFail("now-playing lane must not exceed the soft limit")
        }
        let snapshot = await limiter.snapshot()
        XCTAssertEqual(snapshot.requestsInWindow, snapshot.softLimit)
    }

    func testNowPlayingLaneSpendCountsAgainstBackground() async {
        let limiter = ITunesRateLimiter()
        let reserved = await limiter.acquire(lane: .nowPlaying)
        XCTAssertEqual(reserved, .proceed)
        let granted = await drainBackground(limiter)
        let snapshot = await limiter.snapshot()
        // One shared window: a now-playing request takes a slot the
        // background lane would otherwise have had.
        XCTAssertEqual(granted, snapshot.softLimit - 2 - 1)
    }

    func testCooldownRefusesEveryLane() async {
        let limiter = ITunesRateLimiter()
        await limiter.record(failureStatus: 403)
        guard case .denied(.cooldown(let status), _) = await limiter.acquire(lane: .nowPlaying) else {
            return XCTFail("cooldown must refuse the now-playing lane too")
        }
        XCTAssertEqual(status, 403)
    }
}
