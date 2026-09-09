import XCTest
@testable import SonosKit

/// "Add All" walk order: an album must arrive in track order, not
/// alphabetical title order.
final class BrowseExpansionOrderTests: XCTestCase {

    private func item(_ title: String, container: Bool = false,
                      itemClass: BrowseItemClass = .musicTrack) -> BrowseItem {
        BrowseItem(id: title, title: title, itemClass: itemClass,
                   resourceURI: container ? nil : "x-file-cifs://nas/\(title).flac")
    }

    private func container(_ title: String, itemClass: BrowseItemClass = .container) -> BrowseItem {
        BrowseItem(id: title, title: title, itemClass: itemClass, resourceURI: nil)
    }

    func testContainersAreWalkedBeforeLooseTracks() {
        let children = [item("Zebra"), container("Albums"), item("Apple")]
        let order = BrowseExpansionOrder.walkOrder(children: children, preserveLeafOrder: false)
        XCTAssertEqual(order.map(\.title), ["Albums", "Apple", "Zebra"])
    }

    func testContainersSortAlphabeticallyRegardless() {
        let children = [container("Zulu"), container("Alpha")]
        let order = BrowseExpansionOrder.walkOrder(children: children, preserveLeafOrder: true)
        XCTAssertEqual(order.map(\.title), ["Alpha", "Zulu"])
    }

    /// An album's returned order is its track order.
    func testAlbumTrackOrderSurvives() {
        let tracks = [item("04 Fourth"), item("01 First"), item("02 Second")]
        let order = BrowseExpansionOrder.walkOrder(children: tracks, preserveLeafOrder: true)
        XCTAssertEqual(order.map(\.title), ["04 Fourth", "01 First", "02 Second"])
    }

    func testLooseTracksSortWhenOrderIsNotMeaningful() {
        let tracks = [item("Delta"), item("bravo"), item("Alpha")]
        let order = BrowseExpansionOrder.walkOrder(children: tracks, preserveLeafOrder: false)
        XCTAssertEqual(order.map(\.title), ["Alpha", "bravo", "Delta"])
    }

    func testAlbumsAndPlaylistsPreserveTheirOwnOrder() {
        XCTAssertTrue(BrowseExpansionOrder.preservesLeafOrder(container("X", itemClass: .musicAlbum)))
        XCTAssertTrue(BrowseExpansionOrder.preservesLeafOrder(container("X", itemClass: .playlist)))
    }

    func testFoldersAndArtistsDoNot() {
        XCTAssertFalse(BrowseExpansionOrder.preservesLeafOrder(container("X", itemClass: .container)))
    }

    // MARK: - Playlist files posing as containers

    func testPlaylistFilesAreSkipped() {
        for name in ["Party.m3u", "PARTY.M3U8", "mix.pls", "album.cue"] {
            XCTAssertTrue(BrowseExpansionOrder.isPlaylistFileContainer(container(name)), name)
        }
    }

    func testOrdinaryFoldersAreNotSkipped() {
        for name in ["Music", "m3u archive", "cue sheets"] {
            XCTAssertFalse(BrowseExpansionOrder.isPlaylistFileContainer(container(name)), name)
        }
    }

    // MARK: - Limits

    func testWalkStopsAtTheLeafCeiling() {
        XCTAssertTrue(BrowseExpansionOrder.shouldStop(collected: 500, maxLeaves: 500, cancelled: false))
        XCTAssertFalse(BrowseExpansionOrder.shouldStop(collected: 499, maxLeaves: 500, cancelled: false))
    }

    func testCancellationStopsTheWalkImmediately() {
        XCTAssertTrue(BrowseExpansionOrder.shouldStop(collected: 1, maxLeaves: 500, cancelled: true))
    }

    func testDepthCeilingIsSlackAgainstCyclicStructures() {
        // Artist → Album → Track is three; the ceiling is not a real limit.
        XCTAssertTrue(BrowseExpansionOrder.canDescend(to: 3))
        XCTAssertTrue(BrowseExpansionOrder.canDescend(to: 6))
        XCTAssertFalse(BrowseExpansionOrder.canDescend(to: 7))
    }

    func testEmptyChildrenProduceNoOrder() {
        XCTAssertTrue(BrowseExpansionOrder.walkOrder(children: [], preserveLeafOrder: false).isEmpty)
    }
}
