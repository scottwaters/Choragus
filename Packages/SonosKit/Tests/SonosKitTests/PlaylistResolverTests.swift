import XCTest
@testable import SonosKit

final class PlaylistResolverTests: XCTestCase {

    private func item(title: String, artist: String) -> BrowseItem {
        BrowseItem(id: "\(title)|\(artist)", title: title, artist: artist, album: "",
                   albumArtURI: nil, itemClass: .musicTrack, resourceURI: "x-file:\(title)",
                   resourceMetadata: "")
    }

    // MARK: - Artist matching

    func testArticleAloneDoesNotMatchAnotherArtist() {
        let spec = SongSpec(title: "My Sharona", artist: "The Knack")
        XCTAssertNil(PlaylistResolver.pickBest([item(title: "My Sharona", artist: "The Beatles")], for: spec))
    }

    func testMultiArtistSpecMatchesOnAContentWord() {
        let spec = SongSpec(title: "Smooth", artist: "Santana feat. Rob Thomas")
        let hit = item(title: "Smooth", artist: "Santana")
        XCTAssertEqual(PlaylistResolver.pickBest([item(title: "Smooth", artist: "Feat Collective"), hit], for: spec)?.id,
                       hit.id)
    }

    func testStopWordsAloneNeverMatch() {
        let spec = SongSpec(title: "Song", artist: "The And With")
        XCTAssertNil(PlaylistResolver.pickBest([item(title: "Song", artist: "Anderson Withers")], for: spec))
    }

    // MARK: - Retry cooldown

    func testRetryCooldownFollowsTheService() {
        XCTAssertEqual(PlaylistResolveService.appleMusic(sn: 1).defaultRetryCooldown, .seconds(60))
        XCTAssertEqual(PlaylistResolveService.localLibrary(search: { _ in [] }).defaultRetryCooldown, .zero)
        XCTAssertEqual(PlaylistResolveService.mediaServer(search: { _ in [] }).defaultRetryCooldown, .zero)
    }

    /// A LAN searcher returning nothing is final: no retry, no cooldown,
    /// and no pacing sleep after the last spec.
    func testLocalLibraryMissesDoNotStall() async {
        let calls = Counter()
        let service = PlaylistResolveService.localLibrary(search: { _ in
            await calls.increment()
            return []
        })
        let specs = [SongSpec(title: "A", artist: "B"), SongSpec(title: "C", artist: "D")]
        let started = Date()
        let result = await PlaylistResolver.resolve(specs, via: service, pacing: .seconds(1))
        XCTAssertEqual(result.misses.count, 2)
        XCTAssertEqual(result.resolved.count, 0)
        let count = await calls.value
        XCTAssertEqual(count, 2)
        // One pacing sleep between the two specs, none after the last.
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.9)
    }

    private actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }
}
