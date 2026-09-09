import XCTest
@testable import SonosKit

/// Guards deciding whether a finished network result still applies. Failure
/// under a race: a stale folder listing or the previous track's biography
/// painted over the current one.
final class GenerationGuardTests: XCTestCase {

    func testTheOnlyOutstandingRequestMayPublish() {
        var guardState = GenerationGuard()
        let token = guardState.begin()
        XCTAssertTrue(guardState.isCurrent(token))
    }

    /// Folder A opened, then folder B before A returns: A's late result must
    /// not paint over B.
    func testAnOlderRequestIsRefusedAfterANewerOneStarts() {
        var guardState = GenerationGuard()
        let first = guardState.begin()
        let second = guardState.begin()
        XCTAssertFalse(guardState.isCurrent(first))
        XCTAssertTrue(guardState.isCurrent(second))
    }

    func testEachRequestGetsADistinctToken() {
        var guardState = GenerationGuard()
        let tokens = (0..<5).map { _ in guardState.begin() }
        XCTAssertEqual(Set(tokens).count, 5, "a reused token would let a stale result publish")
    }

    func testTokensAreMonotonicSoLatenessIsOrdered() {
        var guardState = GenerationGuard()
        let first = guardState.begin()
        let second = guardState.begin()
        XCTAssertLessThan(first, second)
        XCTAssertEqual(guardState.latest, second)
    }

    /// Zero is what an uninitialised capture holds, and a fresh guard's counter
    /// is also zero — a plain equality check would let a variable that never
    /// received a token publish its result.
    func testAnUnissuedTokenIsNeverCurrent() {
        var guardState = GenerationGuard()
        XCTAssertFalse(guardState.isCurrent(0))
        XCTAssertFalse(guardState.isCurrent(99))
        _ = guardState.begin()
        XCTAssertFalse(guardState.isCurrent(0), "still refused once requests are under way")
    }

    /// A page-load captures the generation at page start and appends only if
    /// it still holds. Three pages in flight, a reset between: none of the
    /// three may append.
    func testResetInvalidatesEveryOutstandingPage() {
        var guardState = GenerationGuard()
        let pages = (0..<3).map { _ in guardState.begin() }
        _ = guardState.begin()   // loadItems() resets the list
        for page in pages {
            XCTAssertFalse(guardState.isCurrent(page))
        }
    }
}

final class IdentityGuardTests: XCTestCase {

    private typealias Guard = IdentityGuard<String>

    func testFirstFetchIsAllowed() {
        let guardState = Guard()
        XCTAssertTrue(guardState.shouldFetch("track-a"))
    }

    func testTheSameSubjectIsNotRefetchedWhileInFlight() {
        var guardState = Guard()
        guardState.beginFetch("track-a")
        XCTAssertFalse(guardState.shouldFetch("track-a"))
    }

    func testTheSameSubjectIsNotRefetchedOnceLoaded() {
        var guardState = Guard()
        guardState.beginFetch("track-a")
        _ = guardState.finishFetch("track-a")
        XCTAssertFalse(guardState.shouldFetch("track-a"))
    }

    /// A loaded state for an OLD subject must not block the new one — that is
    /// how a panel gets stuck showing the previous track.
    func testADifferentSubjectIsAlwaysFetchable() {
        var guardState = Guard()
        guardState.beginFetch("track-a")
        _ = guardState.finishFetch("track-a")
        XCTAssertTrue(guardState.shouldFetch("track-b"))
    }

    func testALateResultForAPreviousSubjectIsRefused() {
        var guardState = Guard()
        guardState.beginFetch("track-a")
        guardState.beginFetch("track-b")          // track changed mid-fetch
        XCTAssertFalse(guardState.finishFetch("track-a"))
        XCTAssertTrue(guardState.finishFetch("track-b"))
    }

    func testFinishingWithoutStartingIsRefused() {
        var guardState = Guard()
        XCTAssertFalse(guardState.finishFetch("track-a"))
    }

    func testFinishingTwiceIsRefusedTheSecondTime() {
        // A retry that lands after the first result must not re-publish.
        var guardState = Guard()
        guardState.beginFetch("track-a")
        XCTAssertTrue(guardState.finishFetch("track-a"))
        XCTAssertFalse(guardState.finishFetch("track-a"))
    }

    func testAcceptsMatchesTheHeldSubjectWithoutRecording() {
        var guardState = Guard()
        guardState.beginFetch("track-a")
        XCTAssertTrue(guardState.accepts("track-a"))
        XCTAssertFalse(guardState.accepts("track-b"))
        XCTAssertEqual(guardState.state, .loading("track-a"), "accepts must not mutate state")
    }

    func testResetClearsEverything() {
        var guardState = Guard()
        guardState.beginFetch("track-a")
        _ = guardState.finishFetch("track-a")
        guardState.reset()
        XCTAssertEqual(guardState.state, .idle)
        XCTAssertTrue(guardState.shouldFetch("track-a"), "after a reset the subject is fetchable again")
    }

    func testIdleAcceptsNothing() {
        XCTAssertFalse(Guard().accepts("track-a"))
    }
}
