import XCTest
@testable import SonosKit

final class BrowseSortOptionTests: XCTestCase {
    private func item(_ title: String, artist: String = "", date: Date? = nil) -> BrowseItem {
        BrowseItem(id: title, title: title, artist: artist, releaseDate: date)
    }

    func testArtistAndYearOrdersOnlyWhenSomeRowHasThem() {
        let bare = [item("b"), item("a")]
        XCTAssertEqual(BrowseSortOption.available(for: bare), [.relevance, .titleAscending, .titleDescending])
        let withArtist = [item("b"), item("a", artist: "Beck")]
        XCTAssertEqual(BrowseSortOption.available(for: withArtist),
                       [.relevance, .titleAscending, .titleDescending, .artistAscending, .artistDescending])
        let dated = [item("b"), item("a", date: Date(timeIntervalSince1970: 0))]
        XCTAssertEqual(Array(BrowseSortOption.available(for: dated).suffix(2)), [.newest, .oldest])
    }

    func testRelevanceKeepsSourceOrder() {
        let rows = [item("b"), item("a"), item("c")]
        XCTAssertEqual(BrowseSortOption.relevance.apply(rows).map(\.title), ["b", "a", "c"])
    }

    func testTitleOrdersAreCaseInsensitiveAndStable() {
        let rows = [item("beta"), item("Alpha"), item("alpha"), item("Gamma")]
        XCTAssertEqual(BrowseSortOption.titleAscending.apply(rows).map(\.title), ["Alpha", "alpha", "beta", "Gamma"])
        XCTAssertEqual(BrowseSortOption.titleDescending.apply(rows).map(\.title), ["Gamma", "beta", "Alpha", "alpha"])
    }

    func testArtistOrderBreaksTiesOnTitle() {
        let rows = [item("z", artist: "Beck"), item("a", artist: "Beck"), item("m", artist: "Air")]
        XCTAssertEqual(BrowseSortOption.artistAscending.apply(rows).map(\.title), ["m", "a", "z"])
        XCTAssertEqual(BrowseSortOption.artistDescending.apply(rows).map(\.title), ["a", "z", "m"])
    }

    func testYearOrdersPutUndatedRowsLast() {
        let d1 = Date(timeIntervalSince1970: 1_000), d2 = Date(timeIntervalSince1970: 2_000)
        let rows = [item("none"), item("old", date: d1), item("new", date: d2)]
        XCTAssertEqual(BrowseSortOption.newest.apply(rows).map(\.title), ["new", "old", "none"])
        XCTAssertEqual(BrowseSortOption.oldest.apply(rows).map(\.title), ["old", "new", "none"])
    }
}
