import XCTest
@testable import SonosKit

/// Media-server discovery and browse. The description fixtures follow the
/// Synology Media Server layout, including the VLAN address mismatch that
/// made a server browse perfectly and play nothing.
final class MediaServerServiceTests: XCTestCase {

    private func description(host: String, includeContentDirectory: Bool = true) -> String {
        let cd = includeContentDirectory ? """
        <service>
          <serviceType>urn:schemas-upnp-org:service:ContentDirectory:1</serviceType>
          <controlURL>/ContentDirectory/control</controlURL>
        </service>
        """ : ""
        return """
        <root><device>
          <UDN>uuid:0011aabb-2233-4455-6677-8899aabbccdd</UDN>
          <friendlyName>nas-media</friendlyName>
          <modelName>DS-MS</modelName>
          <serviceList>
            <service>
              <serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType>
              <controlURL>/ConnectionManager/control</controlURL>
            </service>
            \(cd)
          </serviceList>
        </device></root>
        """
    }

    // MARK: - Building a server

    func testReadsIdentityAndControlPath() throws {
        let server = try XCTUnwrap(MediaServerService.makeServer(
            descriptionXML: description(host: "192.168.50.200"),
            locationURL: URL(string: "http://192.168.50.200:50001/desc/device.xml")!,
            answeringHost: "192.168.50.200"))
        XCTAssertEqual(server.name, "nas-media")
        XCTAssertEqual(server.modelName, "DS-MS")
        XCTAssertEqual(server.controlPath, "/ContentDirectory/control")
        XCTAssertEqual(server.baseURL.absoluteString, "http://192.168.50.200:50001/")
        XCTAssertNil(server.advertisedHostMismatch)
    }

    /// Taking the first controlURL in the document returns ConnectionManager's,
    /// which faults on every Browse.
    func testPicksContentDirectoryNotTheFirstService() {
        let path = MediaServerService.contentDirectoryControlPath(in: description(host: "h"))
        XCTAssertEqual(path, "/ContentDirectory/control")
    }

    /// The server answers from 192.168.50.200 while advertising 10.10.10.200,
    /// a VLAN the speakers cannot route to: browsing works, nothing plays.
    func testRecordsAdvertisedHostMismatch() throws {
        let server = try XCTUnwrap(MediaServerService.makeServer(
            descriptionXML: description(host: "10.10.10.200"),
            locationURL: URL(string: "http://10.10.10.200:50001/desc/device.xml")!,
            answeringHost: "192.168.50.200"))
        XCTAssertEqual(server.advertisedHostMismatch, "192.168.50.200")
        XCTAssertEqual(server.baseURL.host, "10.10.10.200",
                       "URLs must stay on the advertised host — that is what the server serves")
    }

    func testDeviceWithoutContentDirectoryIsRejected() {
        // Hue bridges and HDHomeRun tuners answer MediaServer:1 searches too.
        XCTAssertNil(MediaServerService.makeServer(
            descriptionXML: description(host: "h", includeContentDirectory: false),
            locationURL: URL(string: "http://192.168.50.11:80/description.xml")!,
            answeringHost: "192.168.50.11"))
    }

    func testFallsBackToHostWhenIdentityIsMissing() throws {
        let bare = """
        <root><device><serviceList><service>
          <serviceType>urn:schemas-upnp-org:service:ContentDirectory:1</serviceType>
          <controlURL>/cd/control</controlURL>
        </service></serviceList></device></root>
        """
        let server = try XCTUnwrap(MediaServerService.makeServer(
            descriptionXML: bare,
            locationURL: URL(string: "http://10.0.0.5:8200/desc.xml")!,
            answeringHost: "10.0.0.5"))
        XCTAssertEqual(server.name, "10.0.0.5")
        XCTAssertEqual(server.id, "10.0.0.5:8200")
    }

    func testDefaultPortWhenTheLocationOmitsOne() throws {
        let server = try XCTUnwrap(MediaServerService.makeServer(
            descriptionXML: description(host: "nas.local"),
            locationURL: URL(string: "http://nas.local/desc.xml")!,
            answeringHost: nil))
        XCTAssertEqual(server.baseURL.absoluteString, "http://nas.local:80/")
    }

    // MARK: - Item mapping

    /// Real DIDL from the Synology server: audio and artwork both on :50002.
    func testTracksAreMappedForDirectHTTPPlayback() {
        let didl = """
        <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" \
        xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">
          <item id="23$@84972" parentID="23" restricted="1">
            <dc:title>Ricky</dc:title>
            <upnp:class>object.item.audioItem.musicTrack</upnp:class>
            <upnp:albumArtURI>http://192.168.50.200:50002/transcoder/jpegtnscaler.cgi/ebdart/84972.jpg</upnp:albumArtURI>
            <res protocolInfo="http-get:*:audio/flac:*">http://192.168.50.200:50002/m/NDLNA/84972.flac</res>
          </item>
        </DIDL-Lite>
        """
        let items = BrowseXMLParser.parse(didl, deviceIP: "192.168.50.200", devicePort: 50001)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.title, "Ricky")
        XCTAssertEqual(items.first?.resourceURI, "http://192.168.50.200:50002/m/NDLNA/84972.flac")
    }
}
