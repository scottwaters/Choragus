import Network
import XCTest
@testable import SonosKit

/// The listener accepts unauthenticated NOTIFY posts from anything that can
/// reach its port, and the payload feeds topology and transport state. These
/// cover the address check that bounds who may deliver one.
final class EventListenerPeerTests: XCTestCase {

    private func endpoint(_ host: String, _ port: UInt16 = 1400) -> NWEndpoint {
        .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
    }

    private func peerAddress(_ host: String) -> String? {
        let connection = NWConnection(to: endpoint(host), using: .tcp)
        defer { connection.cancel() }
        return EventListener.peerAddress(of: connection)
    }

    func testExtractsIPv4PeerAddress() {
        XCTAssertEqual(peerAddress("192.168.50.51"), "192.168.50.51")
    }

    /// A speaker discovered over IPv4 can arrive as an IPv4-mapped IPv6 peer.
    /// Comparing the mapped form against the discovered address would refuse
    /// a legitimate speaker, so the mapping is unwrapped first.
    func testUnwrapsIPv4MappedIPv6Peer() {
        XCTAssertEqual(peerAddress("::ffff:192.168.50.51"), "192.168.50.51")
    }

    func testKeepsRealIPv6PeerIntact() {
        let address = peerAddress("fe80::1")
        XCTAssertNotNil(address)
        XCTAssertFalse(address?.contains(".") ?? true)
    }

    func testAllowedPeersStartEmptySoStartupEventsAreNotLost() {
        // Between start() and the first device list there is nothing to
        // compare against. Refusing everything there would drop events from a
        // speaker still holding a subscription from the previous session.
        let listener = EventListener()
        let expectation = expectation(description: "stats read")
        listener.refusedPeerStats { refused, sample in
            XCTAssertEqual(refused, 0)
            XCTAssertNil(sample)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }

    func testAllowedPeersAreAppliedOnTheListenerQueue() {
        let listener = EventListener()
        listener.setAllowedPeers(["192.168.50.51", "192.168.50.52"])
        let expectation = expectation(description: "applied")
        // The read is queued behind the write, so observing zero refusals
        // here also proves the setter did not drop the update.
        listener.refusedPeerStats { refused, _ in
            XCTAssertEqual(refused, 0)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }
}
