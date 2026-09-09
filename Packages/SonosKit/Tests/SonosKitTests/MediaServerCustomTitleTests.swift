import XCTest
@testable import SonosKit

/// A media server can be shown under a name of the user's choosing. The
/// title is applied where the manager publishes its list, so every
/// consumer sees one name, and the advertised name survives on the struct
/// for reverting and for matching.
final class MediaServerCustomTitleTests: XCTestCase {

    private func server(_ id: String, name: String) -> MediaServer {
        MediaServer(id: id, name: name, modelName: "Model", baseURL: URL(string: "http://10.0.0.9:50001")!,
                    controlPath: "/ctl")
    }

    private let ids = ["uuid:test-a", "uuid:test-b"]

    override func tearDown() {
        for id in ids { MediaServerService.CustomTitles.forget(id: id) }
        super.tearDown()
    }

    func testRenamedKeepsTheAdvertisedName() {
        let renamed = server("uuid:test-a", name: "DiskStation").renamed(to: "Study NAS")
        XCTAssertEqual(renamed.name, "Study NAS")
        XCTAssertEqual(renamed.advertisedName, "DiskStation")
        XCTAssertTrue(renamed.isRenamed)
    }

    func testABlankTitleRevertsToTheAdvertisedName() {
        let back = server("uuid:test-a", name: "DiskStation").renamed(to: "Study NAS").renamed(to: "   ")
        XCTAssertEqual(back.name, "DiskStation")
        XCTAssertFalse(back.isRenamed)
    }

    func testStoreRoundTripsAndBlankRemoves() {
        MediaServerService.CustomTitles.set("  Study NAS  ", for: "uuid:test-a")
        XCTAssertEqual(MediaServerService.CustomTitles.title(for: "uuid:test-a"), "Study NAS")
        MediaServerService.CustomTitles.set("", for: "uuid:test-a")
        XCTAssertNil(MediaServerService.CustomTitles.title(for: "uuid:test-a"))
    }

    func testTitlesAreCappedInLength() {
        MediaServerService.CustomTitles.set(String(repeating: "x", count: 200), for: "uuid:test-a")
        XCTAssertEqual(MediaServerService.CustomTitles.title(for: "uuid:test-a")?.count,
                       MediaServerService.CustomTitles.maxLength)
    }

    func testApplyingRenamesOnlyTheServersWithATitle() {
        MediaServerService.CustomTitles.set("Study NAS", for: "uuid:test-a")
        let published = MediaServerService.CustomTitles.applying(to: [
            server("uuid:test-a", name: "DiskStation"),
            server("uuid:test-b", name: "MinimServer"),
        ])
        XCTAssertEqual(published.map(\.name), ["Study NAS", "MinimServer"])
        XCTAssertEqual(published.map(\.advertisedName), ["DiskStation", "MinimServer"])
    }

    func testApplyingWithNoTitlesReturnsTheListUntouched() {
        let list = [server("uuid:test-a", name: "DiskStation")]
        XCTAssertEqual(MediaServerService.CustomTitles.applying(to: list), list)
    }
}
