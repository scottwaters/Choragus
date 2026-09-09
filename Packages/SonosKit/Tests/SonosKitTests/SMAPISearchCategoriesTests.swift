import XCTest
@testable import SonosKit

/// A service's search ids are its own. Amazon Music publishes
/// `catalog:*:search` ids and answers the generic `track` with an empty
/// result rather than a fault, so the agent server's hardcoded ids read
/// as "nothing found" for every query.
final class SMAPISearchCategoriesTests: XCTestCase {

    /// Amazon Music's published categories, in its own order.
    private let amazon: [(id: String, title: String)] = [
        ("catalog:albums:search", "Albums"),
        ("catalog:artists:search", "Artists"),
        ("catalog:tracks:search", "Tracks"),
        ("catalog:playlists:search", "Playlists"),
        ("podcast:episodes:search", "Podcast Episodes"),
        ("podcast:shows:search", "Podcast Shows"),
        ("catalog:universal:search", "All"),
    ]

    func testAmazonTracksResolveToItsOwnIdThenUniversalThenGeneric() {
        XCTAssertEqual(SMAPISearchCategories.searchIDs(for: .tracks, in: amazon),
                       ["catalog:tracks:search", "catalog:universal:search", "track"])
    }

    func testAmazonAlbumsAndArtistsResolveToTheirOwnIds() {
        XCTAssertEqual(SMAPISearchCategories.searchIDs(for: .albums, in: amazon).first, "catalog:albums:search")
        XCTAssertEqual(SMAPISearchCategories.searchIDs(for: .artists, in: amazon).first, "catalog:artists:search")
    }

    func testAServiceWithNoPublishedCategoriesGetsTheGenericIdOnly() {
        XCTAssertEqual(SMAPISearchCategories.searchIDs(for: .tracks, in: []), ["track"])
        XCTAssertEqual(SMAPISearchCategories.searchIDs(for: .albums, in: []), ["album"])
    }

    func testAServiceUsingTheGenericIdsDoesNotRepeatThem() {
        let tidal: [(id: String, title: String)] = [("track", "Tracks"), ("album", "Albums"), ("artist", "Artists")]
        XCTAssertEqual(SMAPISearchCategories.searchIDs(for: .tracks, in: tidal), ["track"])
    }

    func testACatchAllNamedAllIsMatchedWholeNotAsASubstring() {
        let cats: [(id: String, title: String)] = [("tracks", "Tracks"), ("smallprint", "Small print"), ("all", "Everything")]
        XCTAssertEqual(SMAPISearchCategories.searchIDs(for: .tracks, in: cats), ["tracks", "all", "track"])
    }

    func testPodcastCategoriesNeverPoseAsMusic() {
        let podcastsOnly: [(id: String, title: String)] = [("podcast:episodes:search", "Episodes"), ("podcast:shows:search", "Shows")]
        XCTAssertEqual(SMAPISearchCategories.searchIDs(for: .tracks, in: podcastsOnly), ["track"])
    }

    func testCacheRoundTripsThroughTheSharedKey() {
        let sid = 987_654
        defer { UserDefaults.standard.removeObject(forKey: SMAPISearchCategories.cacheKey(serviceID: sid)) }
        SMAPISearchCategories.store(amazon, serviceID: sid)
        let back = SMAPISearchCategories.cached(serviceID: sid)
        XCTAssertEqual(back.map(\.id), amazon.map(\.id))
        XCTAssertEqual(back.map(\.title), amazon.map(\.title))
        // The Browse window reads the same key, so the format is the one it wrote.
        XCTAssertEqual(SMAPISearchCategories.cacheKey(serviceID: sid), "smapiSearchCategories_987654")
    }

    func testStoringNothingLeavesTheCacheAlone() {
        let sid = 987_655
        defer { UserDefaults.standard.removeObject(forKey: SMAPISearchCategories.cacheKey(serviceID: sid)) }
        SMAPISearchCategories.store(amazon, serviceID: sid)
        SMAPISearchCategories.store([], serviceID: sid)
        XCTAssertEqual(SMAPISearchCategories.cached(serviceID: sid).count, amazon.count)
    }

    // MARK: - Observed-empty categories

    func testFanOutBelowThresholdChangesNothing() {
        let sid = 990_101
        defer { UserDefaults.standard.removeObject(forKey: SMAPISearchCategories.emptyKey(serviceID: sid)) }
        SMAPISearchCategories.recordFanOut(serviceID: sid, counts: ["catalog:tracks:search": 0, "catalog:albums:search": 2])
        XCTAssertTrue(SMAPISearchCategories.emptySearchIDs(serviceID: sid).isEmpty,
                      "a term that barely matched anywhere is no evidence against a category")
    }

    func testFanOutHidesEmptyCategoryWhenAnotherAnswered() {
        let sid = 990_102
        defer { UserDefaults.standard.removeObject(forKey: SMAPISearchCategories.emptyKey(serviceID: sid)) }
        SMAPISearchCategories.recordFanOut(serviceID: sid, counts: [
            "catalog:tracks:search": 0, "catalog:albums:search": 5, "catalog:artists:search": 3,
        ])
        XCTAssertEqual(SMAPISearchCategories.emptySearchIDs(serviceID: sid), ["catalog:tracks:search"])
    }

    func testFanOutRewritesSetSoAnAnsweringCategoryReturns() {
        let sid = 990_103
        defer { UserDefaults.standard.removeObject(forKey: SMAPISearchCategories.emptyKey(serviceID: sid)) }
        SMAPISearchCategories.recordFanOut(serviceID: sid, counts: ["catalog:tracks:search": 0, "catalog:albums:search": 9])
        XCTAssertEqual(SMAPISearchCategories.emptySearchIDs(serviceID: sid), ["catalog:tracks:search"])
        SMAPISearchCategories.recordFanOut(serviceID: sid, counts: ["catalog:tracks:search": 4, "catalog:albums:search": 9])
        XCTAssertTrue(SMAPISearchCategories.emptySearchIDs(serviceID: sid).isEmpty)
    }
}
