import XCTest
@testable import SonosKit

/// Seed addresses are typed by hand. The parser accepts the common forms and
/// refuses what cannot be probed; a silently ignored typo is indistinguishable
/// from a discovery failure.
final class SeedAddressDiscoveryTests: XCTestCase {

    private func normalise(_ input: String) -> (host: String, port: Int)? {
        SeedAddressDiscovery.normalise(input)
    }

    func testBareAddressGetsTheSonosPort() {
        let result = normalise("192.168.1.51")
        XCTAssertEqual(result?.host, "192.168.1.51")
        XCTAssertEqual(result?.port, SonosProtocol.defaultPort)
    }

    func testExplicitPortIsHonoured() {
        let result = normalise("192.168.1.51:1400")
        XCTAssertEqual(result?.host, "192.168.1.51")
        XCTAssertEqual(result?.port, 1400)
    }

    /// A pasted device-description URL is accepted as a seed.
    func testFullDescriptionURLIsAccepted() {
        let result = normalise("http://192.168.1.51:1400/xml/device_description.xml")
        XCTAssertEqual(result?.host, "192.168.1.51")
        XCTAssertEqual(result?.port, 1400)
    }

    func testSurroundingWhitespaceIsTrimmed() {
        XCTAssertEqual(normalise("  192.168.1.51  ")?.host, "192.168.1.51")
    }

    func testHostnamesAreAccepted() {
        // A user with local DNS or an /etc/hosts entry.
        let result = normalise("living-room.local")
        XCTAssertEqual(result?.host, "living-room.local")
        XCTAssertEqual(result?.port, SonosProtocol.defaultPort)
    }

    /// A bare IPv6 literal has several colons and none of them is a port.
    /// Splitting on the last one would mangle the address.
    func testIPv6LiteralIsNotMistakenForAPort() {
        let result = normalise("fd00::1234:5678")
        XCTAssertEqual(result?.host, "fd00::1234:5678")
        XCTAssertEqual(result?.port, SonosProtocol.defaultPort)
    }

    func testEmptyAndWhitespaceAreRejected() {
        XCTAssertNil(normalise(""))
        XCTAssertNil(normalise("   "))
    }

    func testAddressWithSpacesIsRejected() {
        XCTAssertNil(normalise("192.168.1.51 and 52"))
    }

    func testOutOfRangePortFallsBackRatherThanBeingDropped() {
        // "192.168.1.51:99999" is more likely a typo than a different host,
        // so the host is kept and the default port used.
        let result = normalise("192.168.1.51:99999")
        XCTAssertEqual(result?.host, "192.168.1.51:99999")
        XCTAssertEqual(result?.port, SonosProtocol.defaultPort)
    }

    func testTrailingPathWithoutSchemeIsStripped() {
        XCTAssertEqual(normalise("192.168.1.51/xml/device_description.xml")?.host, "192.168.1.51")
    }

    // MARK: - Scanning

    func testNoAddressesMeansNoProbes() {
        // An empty list must not schedule work; the transport is constructed
        // in every discovery mode.
        let discovery = SeedAddressDiscovery(addresses: { [] })
        var probed = false
        discovery.onProbeResult = { _, _ in probed = true }
        discovery.rescan()
        XCTAssertFalse(probed)
    }

    func testMalformedAddressesAreReportedRatherThanSilentlyDropped() {
        let discovery = SeedAddressDiscovery(addresses: { ["not a host"] })
        let reported = expectation(description: "probe result")
        discovery.onProbeResult = { address, result in
            XCTAssertEqual(address, "not a host")
            XCTAssertEqual(result, .malformedAddress)
            reported.fulfill()
        }
        discovery.rescan()
        wait(for: [reported], timeout: 5)
    }
}
