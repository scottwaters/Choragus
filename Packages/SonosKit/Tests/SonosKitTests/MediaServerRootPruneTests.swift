import XCTest
@testable import SonosKit

final class MediaServerRootPruneTests: XCTestCase {
    private func item(_ rawClass: String, container: Bool = false) -> BrowseItem {
        var i = BrowseItem(id: "x", title: "t",
                           itemClass: container ? .container : .unknown,
                           resourceURI: container ? nil : "http://s/a")
        i.rawUPnPClass = rawClass
        return i
    }

    func testEmptySubtreeIsDropped() {
        XCTAssertFalse(MediaServerService.subtreeLooksAudio([]))
    }

    func testAudioChildrenKeepTheSubtree() {
        XCTAssertTrue(MediaServerService.subtreeLooksAudio(
            [item("object.item.audioItem.musicTrack")]))
        XCTAssertTrue(MediaServerService.subtreeLooksAudio(
            [item("object.container.album.musicAlbum", container: true)]))
    }

    /// minidlna-style Pictures folder: image items only, no audio anywhere.
    func testVisualOnlySubtreeIsDropped() {
        XCTAssertFalse(MediaServerService.subtreeLooksAudio(
            [item("object.item.imageItem.photo"), item("object.item.videoItem.movie")]))
        XCTAssertFalse(MediaServerService.subtreeLooksAudio(
            [item("object.container.album.photoAlbum", container: true)]))
    }

    /// Generic storage folders are undecidable one level down; hiding real
    /// music costs more than showing a stray section, so they stay.
    func testGenericFoldersFailOpen() {
        XCTAssertTrue(MediaServerService.subtreeLooksAudio(
            [item("object.container.storageFolder", container: true)]))
        XCTAssertTrue(MediaServerService.subtreeLooksAudio(
            [item("object.container.storageFolder", container: true),
             item("object.item.imageItem.photo")]))
    }
}
