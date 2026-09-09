import XCTest
@testable import SonosKit

final class MediaServerReachabilityTests: XCTestCase {
    func testProxySuccessIsReachable() {
        XCTAssertEqual(MediaServerReachability.classify(status: 200, elapsed: 0.1), .reachable)
    }

    /// The measured signature of a VLAN the speaker cannot route to: the
    /// proxy's own connect timeout, surfaced as a slow 404.
    func testSlowFailureIsUnreachable() {
        XCTAssertEqual(MediaServerReachability.classify(status: 404, elapsed: 5.0), .unreachable)
    }

    /// A fast 404 could be a firewall reject or the proxy refusing the file;
    /// claiming "unreachable" from it would blame the network wrongly.
    func testFastFailureIsUnknown() {
        XCTAssertEqual(MediaServerReachability.classify(status: 404, elapsed: 0.05), .unknown)
    }

    /// No HTTP response at all means the speaker did not answer; reporting
    /// it as an unreachable server blames the wrong device.
    func testNoResponseMeansSpeakerOffline() {
        XCTAssertEqual(MediaServerReachability.classify(status: 0, elapsed: 12.0), .speakerOffline)
        XCTAssertEqual(MediaServerReachability.classify(status: 0, elapsed: 0.2), .speakerOffline)
    }
}
