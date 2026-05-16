/// ExtendedTests.swift — Comprehensive tests for critical logic paths.
import XCTest
@testable import SonosKit

// MARK: - TrackMetadata Extended Tests

final class TrackMetadataExtendedTests: XCTestCase {

    let device = SonosDevice(id: "RINCON_TEST", ip: "10.0.0.5", port: 1400)

    // MARK: - enrichFromDIDL

    func testEnrichFromDIDLPreservesExistingFields() {
        var meta = TrackMetadata(title: "Existing Title", artist: "Existing Artist", album: "Existing Album")
        let didl = "<DIDL-Lite><item><dc:title>New Title</dc:title><upnp:albumArtURI>/art.jpg</upnp:albumArtURI></item></DIDL-Lite>"
        meta.enrichFromDIDL(didl, device: device)
        XCTAssertEqual(meta.title, "Existing Title")
        XCTAssertEqual(meta.artist, "Existing Artist")
        XCTAssertEqual(meta.album, "Existing Album")
        XCTAssertEqual(meta.albumArtURI, "http://10.0.0.5:1400/art.jpg")
    }

    func testEnrichFromDIDLFillsEmptyFields() {
        var meta = TrackMetadata()
        let didl = "<DIDL-Lite><item><dc:title>Song</dc:title><dc:creator>Artist</dc:creator><upnp:album>Album</upnp:album></item></DIDL-Lite>"
        meta.enrichFromDIDL(didl, device: device)
        XCTAssertEqual(meta.title, "Song")
        XCTAssertEqual(meta.artist, "Artist")
        XCTAssertEqual(meta.album, "Album")
    }

    func testEnrichFromDIDLSkipsNotImplemented() {
        var meta = TrackMetadata(title: "Original")
        meta.enrichFromDIDL("NOT_IMPLEMENTED", device: device)
        XCTAssertEqual(meta.title, "Original")
    }

    func testEnrichFromDIDLSkipsEmpty() {
        var meta = TrackMetadata(title: "Original")
        meta.enrichFromDIDL("", device: device)
        XCTAssertEqual(meta.title, "Original")
    }

    func testEnrichFromDIDLHandlesXMLEscaped() {
        var meta = TrackMetadata()
        let escaped = "&lt;DIDL-Lite&gt;&lt;item&gt;&lt;dc:title&gt;Escaped&lt;/dc:title&gt;&lt;/item&gt;&lt;/DIDL-Lite&gt;"
        meta.enrichFromDIDL(escaped, device: device)
        XCTAssertEqual(meta.title, "Escaped")
    }

    // MARK: - isAdBreak

    func testIsAdBreakTitleEmpty() {
        let meta = TrackMetadata(title: "", stationName: "BBC Radio")
        XCTAssertTrue(meta.isAdBreak)
    }

    func testIsAdBreakTitleEqualsStation() {
        let meta = TrackMetadata(title: "BBC Radio", stationName: "BBC Radio")
        XCTAssertTrue(meta.isAdBreak)
    }

    func testIsAdBreakTitleEqualsStationWithArtist() {
        var meta = TrackMetadata(title: "BBC Radio", artist: "Some Artist", stationName: "BBC Radio")
        // Has artist — not an ad break even though title == station
        XCTAssertFalse(meta.isAdBreak)
    }

    func testIsAdBreakRealTrack() {
        let meta = TrackMetadata(title: "Song Name", artist: "Artist", stationName: "BBC Radio")
        XCTAssertFalse(meta.isAdBreak)
    }

    func testIsAdBreakNoStation() {
        let meta = TrackMetadata(title: "")
        XCTAssertFalse(meta.isAdBreak)
    }

    func testIsAdBreakRadioStreamNoStation() {
        var meta = TrackMetadata(title: "")
        meta.trackURI = "x-sonosapi-stream:s123"
        XCTAssertTrue(meta.isAdBreak)
    }

    // MARK: - isRadioStream

    func testIsRadioStreamTrue() {
        var meta = TrackMetadata()
        meta.trackURI = "x-sonosapi-stream:s123?sid=333"
        XCTAssertTrue(meta.isRadioStream)
    }

    func testIsRadioStreamHLS() {
        var meta = TrackMetadata()
        meta.trackURI = "x-sonosapi-hls:something"
        XCTAssertTrue(meta.isRadioStream)
    }

    func testIsRadioStreamFalse() {
        var meta = TrackMetadata()
        meta.trackURI = "x-sonos-http:track123"
        XCTAssertFalse(meta.isRadioStream)
    }

    func testIsRadioStreamNilURI() {
        let meta = TrackMetadata()
        XCTAssertFalse(meta.isRadioStream)
    }

    // MARK: - filterDeviceID

    func testFilterDeviceIDRemovesRINCON() {
        XCTAssertEqual(TrackMetadata.filterDeviceID("RINCON_000E58A1B2C401400"), "")
    }

    func testFilterDeviceIDKeepsNormal() {
        XCTAssertEqual(TrackMetadata.filterDeviceID("The Beatles"), "The Beatles")
    }

    func testFilterDeviceIDEmpty() {
        XCTAssertEqual(TrackMetadata.filterDeviceID(""), "")
    }

    // MARK: - parseTimeString edge cases

    func testParseTimeStringZero() {
        XCTAssertEqual(TrackMetadata.parseTimeString("0:00:00"), 0)
    }

    func testParseTimeStringMinutesOnly() {
        XCTAssertEqual(TrackMetadata.parseTimeString("3:45"), 225)
    }

    func testParseTimeStringEmptyString() {
        XCTAssertEqual(TrackMetadata.parseTimeString(""), 0)
    }

    func testParseTimeStringLargeHours() {
        XCTAssertEqual(TrackMetadata.parseTimeString("25:00:00"), 90000)
    }
}

// MARK: - URIPrefix Extended Tests

final class URIPrefixExtendedTests: XCTestCase {

    func testIsRadioHLSPrefix() {
        XCTAssertTrue(URIPrefix.isRadio("x-sonosapi-hls:stream123"))
    }

    func testIsRadioHLSStaticPrefix() {
        XCTAssertTrue(URIPrefix.isRadio("x-sonosapi-hls-static:stream123"))
    }

    func testIsRadioEmptyString() {
        XCTAssertFalse(URIPrefix.isRadio(""))
    }

    func testIsLocalEmptyString() {
        XCTAssertFalse(URIPrefix.isLocal(""))
    }

    func testIsLocalSMB() {
        XCTAssertTrue(URIPrefix.isLocal("x-smb://server/share/file.mp3"))
    }
}

// ArtResolver tests require app target — see TODO for app-level test target

// MARK: - Mock State Mutation Extended Tests

@MainActor
final class MockStateExtendedTests: XCTestCase {

    func testUpdateAwaitingPlayback() {
        let mock = MockSonosServices()
        mock.updateAwaitingPlayback("g1", awaiting: true)
        XCTAssertEqual(mock.awaitingPlayback["g1"], true)
        mock.updateAwaitingPlayback("g1", awaiting: false)
        XCTAssertEqual(mock.awaitingPlayback["g1"], false)
    }

    func testGracePeriodExpiry() {
        let mock = MockSonosServices()
        mock.setVolumeGrace(deviceID: "d1", duration: 0.01)
        XCTAssertTrue(mock.isVolumeGraceActive(deviceID: "d1"))
        // After grace expires
        Thread.sleep(forTimeInterval: 0.02)
        XCTAssertFalse(mock.isVolumeGraceActive(deviceID: "d1"))
    }

    func testTransportDidUpdateTrackMetadata() {
        let mock = MockSonosServices()
        let meta = TrackMetadata(title: "Song", artist: "Artist")
        mock.transportDidUpdateTrackMetadata("g1", metadata: meta, source: .poll)
        XCTAssertEqual(mock.groupTrackMetadata["g1"]?.title, "Song")
        XCTAssertEqual(mock.groupTrackMetadata["g1"]?.artist, "Artist")
    }

    func testDraggedBrowseItem() {
        let mock = MockSonosServices()
        XCTAssertNil(mock.draggedBrowseItem)
        let item = BrowseItem(id: "FV:2/1", title: "Test")
        mock.draggedBrowseItem = item
        XCTAssertEqual(mock.draggedBrowseItem?.title, "Test")
    }
}

// MARK: - PlayHistoryManager Logic Tests

@MainActor
final class PlayHistoryLogicTests: XCTestCase {

    func testSourceServiceNameSidExtraction() {
        // Create a manager to test sourceServiceName
        let manager = PlayHistoryManager()
        let entry = PlayHistoryEntry(
            title: "Song", artist: "Artist",
            sourceURI: "x-sonos-http:track?sid=12&flags=8224&sn=3"
        )
        let name = manager.sourceServiceName(for: entry)
        XCTAssertEqual(name, "Spotify") // sid=12 = Spotify
    }

    func testSourceServiceNameLocalFile() {
        let manager = PlayHistoryManager()
        let entry = PlayHistoryEntry(
            title: "Song", artist: "Artist",
            sourceURI: "x-file-cifs://server/share/song.mp3"
        )
        let name = manager.sourceServiceName(for: entry)
        XCTAssertEqual(name, "Music Library")
    }

    func testSourceServiceNameRadioStream() {
        let manager = PlayHistoryManager()
        let entry = PlayHistoryEntry(
            title: "Song", artist: "Artist",
            sourceURI: "x-sonosapi-stream:s123"
        )
        let name = manager.sourceServiceName(for: entry)
        XCTAssertEqual(name, "Radio")
    }

    func testSourceServiceNameNoURI() {
        let manager = PlayHistoryManager()
        let entry = PlayHistoryEntry(title: "Song", artist: "Artist")
        let name = manager.sourceServiceName(for: entry)
        XCTAssertEqual(name, "Local")
    }

    func testListeningStreakNonNegative() {
        let manager = PlayHistoryManager()
        XCTAssertGreaterThanOrEqual(manager.listeningStreak, 0)
    }

    func testCurrentStreakNonNegative() {
        let manager = PlayHistoryManager()
        XCTAssertGreaterThanOrEqual(manager.currentStreak, 0)
    }

    func testAveragePlaysPerDayNonNegative() {
        let manager = PlayHistoryManager()
        XCTAssertGreaterThanOrEqual(manager.averagePlaysPerDay, 0)
    }
}

// MARK: - SonosDevice Tests

final class SonosDeviceExtendedTests: XCTestCase {

    func testMakeAbsoluteURLRelativePath() {
        let device = SonosDevice(id: "R1", ip: "192.168.1.10", port: 1400)
        XCTAssertEqual(device.makeAbsoluteURL("/getaa?s=1"), "http://192.168.1.10:1400/getaa?s=1")
    }

    func testMakeAbsoluteURLAbsoluteUnchanged() {
        let device = SonosDevice(id: "R1", ip: "192.168.1.10", port: 1400)
        XCTAssertEqual(device.makeAbsoluteURL("https://cdn.example.com/art.jpg"), "https://cdn.example.com/art.jpg")
    }

    func testMakeAbsoluteURLEmpty() {
        let device = SonosDevice(id: "R1", ip: "192.168.1.10", port: 1400)
        XCTAssertEqual(device.makeAbsoluteURL(""), "")
    }

    func testBaseURL() {
        let device = SonosDevice(id: "R1", ip: "10.0.0.5", port: 1400)
        XCTAssertEqual(device.baseURL.absoluteString, "http://10.0.0.5:1400")
    }

    func testGroupCoordinator() {
        let coord = SonosDevice(id: "R1", ip: "10.0.0.1", isCoordinator: true)
        let member = SonosDevice(id: "R2", ip: "10.0.0.2")
        let group = SonosGroup(id: "g1", coordinatorID: "R1", members: [coord, member])
        XCTAssertEqual(group.coordinator?.id, "R1")
        XCTAssertEqual(group.members.count, 2)
    }

    func testGroupName() {
        let coord = SonosDevice(id: "R1", ip: "10.0.0.1", roomName: "Living Room", isCoordinator: true)
        let member = SonosDevice(id: "R2", ip: "10.0.0.2", roomName: "Kitchen")
        let group = SonosGroup(id: "g1", coordinatorID: "R1", members: [coord, member])
        XCTAssertEqual(group.name, "Living Room + Kitchen")
    }

    func testGroupNameSingleSpeaker() {
        let coord = SonosDevice(id: "R1", ip: "10.0.0.1", roomName: "Office", isCoordinator: true)
        let group = SonosGroup(id: "g1", coordinatorID: "R1", members: [coord])
        XCTAssertEqual(group.name, "Office")
    }
}
