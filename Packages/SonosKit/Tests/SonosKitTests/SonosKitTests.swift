import XCTest
@testable import SonosKit

final class XMLResponseParserTests: XCTestCase {

    func testParseZoneGroupState() {
        let xml = """
        <ZoneGroups>
          <ZoneGroup Coordinator="RINCON_0001" ID="group1">
            <ZoneGroupMember UUID="RINCON_0001" Location="http://192.168.1.10:1400/xml/device_description.xml" ZoneName="Living Room" />
            <ZoneGroupMember UUID="RINCON_0002" Location="http://192.168.1.11:1400/xml/device_description.xml" ZoneName="Kitchen" />
          </ZoneGroup>
          <ZoneGroup Coordinator="RINCON_0003" ID="group2">
            <ZoneGroupMember UUID="RINCON_0003" Location="http://192.168.1.12:1400/xml/device_description.xml" ZoneName="Bedroom" />
          </ZoneGroup>
        </ZoneGroups>
        """

        let groups = XMLResponseParser.parseZoneGroupState(xml)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].coordinatorUUID, "RINCON_0001")
        XCTAssertEqual(groups[0].members.count, 2)
        XCTAssertEqual(groups[0].members[0].zoneName, "Living Room")
        XCTAssertEqual(groups[0].members[0].ip, "192.168.1.10")
        XCTAssertEqual(groups[1].members.count, 1)
        XCTAssertEqual(groups[1].members[0].zoneName, "Bedroom")
    }

    func testParseDIDLMetadata() {
        let didl = """
        <DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/">
          <item>
            <dc:title>Test Song</dc:title>
            <dc:creator>Test Artist</dc:creator>
            <upnp:album>Test Album</upnp:album>
            <upnp:albumArtURI>/getaa?s=1&amp;u=x-sonos-spotify%3aspotify</upnp:albumArtURI>
          </item>
        </DIDL-Lite>
        """

        let item = XMLResponseParser.parseDIDLMetadata(didl)
        XCTAssertNotNil(item)
        XCTAssertEqual(item?.title, "Test Song")
        XCTAssertEqual(item?.creator, "Test Artist")
        XCTAssertEqual(item?.album, "Test Album")
    }

    func testParseTimeString() {
        XCTAssertEqual(TrackMetadata.parseTimeString("0:03:45"), 225)
        XCTAssertEqual(TrackMetadata.parseTimeString("1:00:00"), 3600)
        XCTAssertEqual(TrackMetadata.parseTimeString("0:00:30"), 30)
    }

    func testTransportState() {
        XCTAssertEqual(TransportState(rawValue: "PLAYING"), .playing)
        XCTAssertEqual(TransportState(rawValue: "PAUSED_PLAYBACK"), .paused)
        XCTAssertTrue(TransportState.playing.isPlaying)
        XCTAssertFalse(TransportState.paused.isPlaying)
    }
}
