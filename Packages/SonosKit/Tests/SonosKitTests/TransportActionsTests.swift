/// TransportActionsTests.swift — parsing the speaker's own skip verdict.
///
/// The action lists asserted here were read off a live S1 household:
/// an Amazon Music station grants `Next` but not
/// `Previous`, group members report nothing at all.
import XCTest
@testable import SonosKit

final class TransportActionsTests: XCTestCase {

    // MARK: - Parsing

    func testAmazonStationGrantsNextButNotPrevious() {
        let actions = TransportActions.parse("Set, Stop, Pause, Play, Next")
        XCTAssertEqual(actions?.canSkipNext, true)
        XCTAssertEqual(actions?.canSkipPrevious, false)
    }

    func testQueuePlaybackGrantsBothSkips() {
        let actions = TransportActions.parse("Set, Stop, Pause, Play, Seek, Next, Previous")
        XCTAssertEqual(actions?.canSkipNext, true)
        XCTAssertEqual(actions?.canSkipPrevious, true)
        XCTAssertEqual(actions?.contains(.seek), true)
    }

    func testUnskippableStreamGrantsNeither() {
        let actions = TransportActions.parse("Set, Stop, Pause, Play")
        XCTAssertEqual(actions?.canSkipNext, false)
        XCTAssertEqual(actions?.canSkipPrevious, false)
    }

    /// Group members answer with an empty list — that's "ask the
    /// coordinator", not "nothing is allowed", so it must stay nil and
    /// let the caller's fallback decide.
    func testEmptyListIsUnknownRatherThanDenial() {
        XCTAssertNil(TransportActions.parse(""))
        XCTAssertNil(TransportActions.parse("  ,  "))
    }

    func testUnknownActionNamesAreIgnored() {
        let actions = TransportActions.parse("Play, X_DLNA_TeleportSpeaker, Next")
        XCTAssertEqual(actions, [.play, .next])
    }

    // MARK: - Event wiring

    func testLastChangeEventCarriesTransportActions() {
        let body = """
        <?xml version="1.0"?><e:propertyset xmlns:e="urn:schemas-upnp-org:event-1-0">\
        <e:property><LastChange>&lt;Event&gt;&lt;InstanceID val=&quot;0&quot;&gt;\
        &lt;TransportState val=&quot;PLAYING&quot;/&gt;\
        &lt;CurrentTransportActions val=&quot;Set, Stop, Pause, Play, Next&quot;/&gt;\
        &lt;/InstanceID&gt;&lt;/Event&gt;</LastChange></e:property></e:propertyset>
        """
        let event = LastChangeParser.parseAVTransportEvent(body)
        XCTAssertEqual(event.transportState, .playing)
        XCTAssertEqual(event.currentTransportActions?.canSkipNext, true)
        XCTAssertEqual(event.currentTransportActions?.canSkipPrevious, false)
    }
}
