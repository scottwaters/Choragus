import XCTest
@testable import SonosKit

/// A saved-queue row the speaker described without `<r:resMD>` used to be
/// re-enqueued as a bare URI. The track played, but the speaker resolved
/// no metadata for the row, so the restored queue showed no title, artist
/// or album — and the next snapshot of that queue inherited the loss.
@MainActor
final class SavedQueueEnvelopeTests: XCTestCase {

    private func item(title: String, uri: String?, metadata: String?) -> BrowseItem {
        BrowseItem(id: "LOCALQ:219/1", title: title, artist: "Sam Cooke",
                   album: "The Best of Sam Cooke", albumArtURI: nil,
                   itemClass: .musicTrack, resourceURI: uri, resourceMetadata: metadata)
    }

    func testARowSavedWithoutAnEnvelopeIsDescribedBeforeEnqueue() {
        let described = SonosManager.describingRowsSavedWithoutMetadata(
            item(title: "Bring It On Home to Me",
                 uri: "x-sonos-spotify:spotify%3atrack%3a5EoYc?sid=12&flags=8232&sn=20",
                 metadata: nil))
        let envelope = try! XCTUnwrap(described.resourceMetadata)
        XCTAssertTrue(envelope.contains("<dc:title>Bring It On Home to Me</dc:title>"))
        XCTAssertTrue(envelope.contains("<dc:creator>Sam Cooke</dc:creator>"))
        XCTAssertTrue(envelope.contains("<upnp:album>The Best of Sam Cooke</upnp:album>"))
        // A service track needs the item id the service expects and its
        // cdudn; a generic envelope carrying <res> is discarded whole.
        XCTAssertTrue(envelope.contains("spotify%3atrack%3a5EoYc"))
        XCTAssertTrue(envelope.contains("desc id=\"cdudn\""))
        XCTAssertFalse(envelope.contains("<res "))
    }

    func testALocalLibraryRowGetsTheHouseholdDescriptor() {
        let described = SonosManager.describingRowsSavedWithoutMetadata(
            item(title: "Ruby Tuesday", uri: "x-file-cifs://nas/Music/ruby.mp3", metadata: nil))
        let envelope = try! XCTUnwrap(described.resourceMetadata)
        XCTAssertTrue(envelope.contains("RINCON_AssociatedZPUDN"))
    }

    func testAStoredEnvelopeIsLeftUntouched() {
        let described = SonosManager.describingRowsSavedWithoutMetadata(
            item(title: "Ruby Tuesday", uri: "x-sonos-spotify:abc?sid=12",
                 metadata: "<DIDL-Lite>stored</DIDL-Lite>"))
        XCTAssertEqual(described.resourceMetadata, "<DIDL-Lite>stored</DIDL-Lite>")
    }

    func testARowWithNoTitleIsLeftAlone() {
        let described = SonosManager.describingRowsSavedWithoutMetadata(
            item(title: "", uri: "x-sonos-spotify:abc?sid=12", metadata: nil))
        XCTAssertNil(described.resourceMetadata)
    }

    func testARowWithNoURIIsLeftAlone() {
        let described = SonosManager.describingRowsSavedWithoutMetadata(
            item(title: "Ruby Tuesday", uri: nil, metadata: nil))
        XCTAssertNil(described.resourceMetadata)
    }

    func testTitleTextIsEscapedIntoTheEnvelope() {
        let described = SonosManager.describingRowsSavedWithoutMetadata(
            item(title: "Simon & Garfunkel <live>",
                 uri: "x-file-cifs://nas/Music/a.mp3", metadata: nil))
        let envelope = try! XCTUnwrap(described.resourceMetadata)
        XCTAssertTrue(envelope.contains("Simon &amp; Garfunkel &lt;live&gt;"))
    }
}
