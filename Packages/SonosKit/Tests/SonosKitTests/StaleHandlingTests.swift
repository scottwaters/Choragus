/// StaleHandlingTests.swift — Pin the SOAP-fault → StaleDataError
/// mapping so the misleading "Speaker layout has changed" copy
/// doesn't reappear for SMAPI service-track rejections (issue #42),
/// and so 701 / s:Client continue to trigger the rescan path.
///
/// Also covers `isSMAPIServiceTrackURI` so the URI scheme allowlist
/// can't drift away from the queue-routing site silently.
import XCTest
@testable import SonosKit

final class StaleHandlingTests: XCTestCase {

    // MARK: - SOAP fault classification

    func testNetworkErrorMapsToDeviceUnreachable() {
        let underlying = NSError(domain: "test", code: -1, userInfo: nil)
        let mapped = SonosManager.classifySOAPFault(.networkError(underlying), roomName: "Kitchen")
        guard case .deviceUnreachable(let name) = mapped else {
            return XCTFail("expected .deviceUnreachable, got \(String(describing: mapped))")
        }
        XCTAssertEqual(name, "Kitchen")
    }

    func test714MapsToServiceRejected() {
        let mapped = SonosManager.classifySOAPFault(
            .soapFault("714", "UPnPError"),
            roomName: "Living Room"
        )
        XCTAssertEqual(mapped, .serviceRejected,
                       "SOAP 714 ('no such resource') must surface as service rejection — the dominant trigger is SMAPI single-track URIs the speaker refuses, not topology drift (issue #42).")
    }

    func test701MapsToTopologyStale() {
        let mapped = SonosManager.classifySOAPFault(
            .soapFault("701", "invalid object"),
            roomName: "Office"
        )
        XCTAssertEqual(mapped, .topologyStale)
    }

    func testClientSideFaultMapsToTopologyStale() {
        let mapped = SonosManager.classifySOAPFault(
            .soapFault("s:Client", ""),
            roomName: "Office"
        )
        XCTAssertEqual(mapped, .topologyStale)
    }

    func testUnknownFaultCodeReturnsNil() {
        // 402, 501, etc. — pass through as raw SOAPError.
        XCTAssertNil(SonosManager.classifySOAPFault(
            .soapFault("402", "Invalid Action"),
            roomName: "Kitchen"
        ))
        XCTAssertNil(SonosManager.classifySOAPFault(
            .soapFault("501", "Action Failed"),
            roomName: "Kitchen"
        ))
    }

    // MARK: - StaleDataError copy

    /// The user-facing copy on `.serviceRejected` must not suggest a
    /// workaround and must not claim a specific cause — both rules
    /// the user pushed back on during the issue #42 fix.
    func testServiceRejectedCopyIsNeutral() {
        let msg = StaleDataError.serviceRejected.errorDescription ?? ""
        XCTAssertFalse(msg.lowercased().contains("try "),
                       "Workaround phrasing leaked into error copy.")
        XCTAssertFalse(msg.lowercased().contains("instead"),
                       "Workaround phrasing leaked into error copy.")
        XCTAssertFalse(msg.lowercased().contains("known"),
                       "Cause-claiming phrasing leaked into error copy.")
        XCTAssertTrue(msg.lowercased().contains("bug report"),
                      "Error copy should direct user to file a bug report.")
    }

    // MARK: - SMAPI service-track URI detection

    func testSMAPISchemesAreDetected() {
        XCTAssertTrue(SonosManager.isSMAPIServiceTrackURI(
            "x-sonos-spotify:spotify%3atrack%3a36vmaZyO0iAE6FZ7287fg2?sid=12&flags=8224&sn=20"
        ), "Spotify tracks must route via queue (issue #42).")

        XCTAssertTrue(SonosManager.isSMAPIServiceTrackURI(
            "x-sonos-http:tracks%3a485169719?sid=310&flags=8224&sn=*"
        ), "HTTP-backed SMAPI tracks (Calm Radio sid=310) must route via queue.")

        XCTAssertTrue(SonosManager.isSMAPIServiceTrackURI(
            "x-sonos-hls:something?sid=42"
        ), "HLS-backed SMAPI tracks must route via queue.")
    }

    func testNonSMAPISchemesArePassThrough() {
        // TuneIn music stations — direct play works, must NOT route via queue.
        XCTAssertFalse(SonosManager.isSMAPIServiceTrackURI(
            "x-sonosapi-stream:s12345?sid=254"
        ))
        // Raw radio HTTP — direct play works.
        XCTAssertFalse(SonosManager.isSMAPIServiceTrackURI(
            "x-rincon-mp3radio://stream.example.com/foo"
        ))
        XCTAssertFalse(SonosManager.isSMAPIServiceTrackURI(
            "https://podcast.example.com/episode.mp3"
        ))
        // Already-queue URIs — never re-route.
        XCTAssertFalse(SonosManager.isSMAPIServiceTrackURI(
            "x-rincon-queue:RINCON_xxxx#0"
        ))
        XCTAssertFalse(SonosManager.isSMAPIServiceTrackURI(
            "x-rincon-cpcontainer:1006206cspotify%3aalbum%3a..."
        ))
        // Line-in.
        XCTAssertFalse(SonosManager.isSMAPIServiceTrackURI(
            "x-rincon-stream:RINCON_xxxx"
        ))
        // Empty.
        XCTAssertFalse(SonosManager.isSMAPIServiceTrackURI(""))
    }

    /// Spotify's SMAPI `getMediaURI` rewrites the original
    /// `x-sonos-spotify:` URI to `x-spotify://…` which Sonos ALSO
    /// rejects — and the rewrite happens inside
    /// `.smapiResolveThenEmpty` before the queue gate. The fix in
    /// B1242 moved the gate before the strategy switch so it sees the
    /// original URI. This pins that `x-spotify://` is NOT in the
    /// detection set (so if someone later re-introduces the
    /// post-switch check, it'll still correctly miss the resolved
    /// URI rather than silently accept it and add a wrong code path).
    func testResolvedXSpotifySchemeIsNotInDetectionSet() {
        XCTAssertFalse(SonosManager.isSMAPIServiceTrackURI(
            "x-spotify://spotify:track:5AdD7XsNMCok2QXX8WB4ct"
        ), "Detection should only match the ORIGINAL Sonos service URIs, not the SMAPI resolver's rewrites — see the pre-strategy-switch gate in playBrowseItem.")
    }
}
