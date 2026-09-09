import XCTest
@testable import SonosKit

final class IPAddressTests: XCTestCase {
    func testRecognisesPrivateIPv4Ranges() {
        for host in ["10.0.4.21", "192.168.50.200", "172.16.0.1", "172.31.255.254",
                     "127.0.0.1", "169.254.1.1", "100.64.0.1"] {
            XCTAssertTrue(IPAddress.isPrivate(host), host)
        }
    }

    func testPublicAddressesAreNotPrivate() {
        // 172.32 and 172.15 sit either side of the private block; treating
        // the whole 172.0.0.0/8 as private would misclassify both.
        for host in ["8.8.8.8", "172.32.0.1", "172.15.0.1", "100.128.0.1", "1.1.1.1"] {
            XCTAssertFalse(IPAddress.isPrivate(host), host)
        }
    }

    func testLocalNamesAreLocal() {
        XCTAssertTrue(IPAddress.isPrivate("nas.local"))
        XCTAssertTrue(IPAddress.isPrivate("localhost"))
    }

    /// A CDN hostname must not be classified as local, or its art URL would
    /// stop being upgraded to HTTPS.
    func testHostnamesAreNotAssumedLocal() {
        XCTAssertFalse(IPAddress.isPrivate("i.scdn.co"))
        XCTAssertFalse(IPAddress.isPrivate(""))
    }

    func testIPv6LocalForms() {
        XCTAssertTrue(IPAddress.isPrivate("[fe80::1]"))
        XCTAssertTrue(IPAddress.isPrivate("fd00::1"))
        XCTAssertFalse(IPAddress.isPrivate("2606:4700::1111"))
    }
}
