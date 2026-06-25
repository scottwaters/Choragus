import XCTest
@testable import SonosKit

// MARK: - XML Parser Tests

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

    /// Issue #63: a room named "Foo & Bar" arrives as `ZoneName="Foo &amp; Bar"`
    /// (valid XML — the SOAP layer already unescaped the outer encoding).
    /// A second unescape produced a bare `&`, the parser rejected the whole
    /// document, and every speaker in the household vanished.
    func testParseZoneGroupStateWithAmpersandInRoomName() {
        let xml = """
        <ZoneGroups>
          <ZoneGroup Coordinator="RINCON_0001" ID="group1">
            <ZoneGroupMember UUID="RINCON_0001" Location="http://192.168.1.10:1400/xml/device_description.xml" ZoneName="Bed &amp; Breakfast" />
            <ZoneGroupMember UUID="RINCON_0002" Location="http://192.168.1.11:1400/xml/device_description.xml" ZoneName="Kitchen" />
          </ZoneGroup>
        </ZoneGroups>
        """
        let groups = XMLResponseParser.parseZoneGroupState(xml)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].members.count, 2)
        XCTAssertEqual(groups[0].members[0].zoneName, "Bed & Breakfast")
        XCTAssertEqual(groups[0].members[1].zoneName, "Kitchen")
    }

    /// Defensive: genuinely-bare `&` from malformed firmware output must not
    /// zero the topology either.
    func testParseZoneGroupStateWithBareAmpersand() {
        let xml = """
        <ZoneGroups>
          <ZoneGroup Coordinator="RINCON_0001" ID="group1">
            <ZoneGroupMember UUID="RINCON_0001" Location="http://192.168.1.10:1400/xml/device_description.xml" ZoneName="Bed & Breakfast" />
          </ZoneGroup>
        </ZoneGroups>
        """
        let groups = XMLResponseParser.parseZoneGroupState(xml)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].members.first?.zoneName, "Bed & Breakfast")
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

    func testParseDIDLStreamContent() {
        let didl = """
        <DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/">
          <item>
            <dc:title>Station Name</dc:title>
            <r:streamContent>Artist Name - Track Title</r:streamContent>
            <upnp:albumArtURI>https://example.com/art.png</upnp:albumArtURI>
          </item>
        </DIDL-Lite>
        """

        let item = XMLResponseParser.parseDIDLMetadata(didl)
        XCTAssertNotNil(item)
        XCTAssertEqual(item?.title, "Station Name")
        XCTAssertEqual(item?.streamContent, "Artist Name - Track Title")
        XCTAssertEqual(item?.albumArtURI, "https://example.com/art.png")
    }

    func testXmlUnescape() {
        let escaped = "&lt;tag&gt;value&amp;more&lt;/tag&gt;"
        let result = XMLResponseParser.xmlUnescape(escaped)
        XCTAssertEqual(result, "<tag>value&more</tag>")
    }
}

// MARK: - Track Metadata Tests

final class TrackMetadataTests: XCTestCase {

    func testParseTimeString() {
        XCTAssertEqual(TrackMetadata.parseTimeString("0:03:45"), 225)
        XCTAssertEqual(TrackMetadata.parseTimeString("1:00:00"), 3600)
        XCTAssertEqual(TrackMetadata.parseTimeString("0:00:30"), 30)
    }

    func testServiceID() {
        var meta = TrackMetadata()
        meta.trackURI = "x-sonos-http:song%3a123.mp4?sid=204&flags=8232&sn=17"
        XCTAssertEqual(meta.serviceID, 204)
    }

    func testServiceIDMissing() {
        var meta = TrackMetadata()
        meta.trackURI = "x-file-cifs://nas/music/song.mp3"
        XCTAssertNil(meta.serviceID)
    }

    func testServiceIDNilURI() {
        let meta = TrackMetadata()
        XCTAssertNil(meta.serviceID)
    }
}

// MARK: - Transport State Tests

final class TransportStateTests: XCTestCase {

    func testTransportState() {
        XCTAssertEqual(TransportState(rawValue: "PLAYING"), .playing)
        XCTAssertEqual(TransportState(rawValue: "PAUSED_PLAYBACK"), .paused)
        XCTAssertTrue(TransportState.playing.isPlaying)
        XCTAssertFalse(TransportState.paused.isPlaying)
    }

    func testIsActive() {
        XCTAssertTrue(TransportState.playing.isActive)
        XCTAssertTrue(TransportState.transitioning.isActive)
        XCTAssertFalse(TransportState.stopped.isActive)
        XCTAssertFalse(TransportState.paused.isActive)
    }
}

// MARK: - Play Mode Tests

final class PlayModeTests: XCTestCase {

    func testShuffle() {
        XCTAssertTrue(PlayMode.shuffle.isShuffled)
        XCTAssertTrue(PlayMode.shuffleNoRepeat.isShuffled)
        XCTAssertFalse(PlayMode.normal.isShuffled)
        XCTAssertFalse(PlayMode.repeatAll.isShuffled)
    }

    func testRepeat() {
        XCTAssertEqual(PlayMode.normal.repeatMode, .off)
        XCTAssertEqual(PlayMode.repeatAll.repeatMode, .all)
        XCTAssertEqual(PlayMode.repeatOne.repeatMode, .one)
    }

    func testToggleShuffle() {
        XCTAssertEqual(PlayMode.normal.togglingShuffle(), .shuffleNoRepeat)
        XCTAssertEqual(PlayMode.shuffleNoRepeat.togglingShuffle(), .normal)
        XCTAssertEqual(PlayMode.repeatAll.togglingShuffle(), .shuffle)
    }

    func testCycleRepeat() {
        XCTAssertEqual(PlayMode.normal.cyclingRepeat(), .repeatAll)
        XCTAssertEqual(PlayMode.repeatAll.cyclingRepeat(), .repeatOne)
        XCTAssertEqual(PlayMode.repeatOne.cyclingRepeat(), .normal)
    }
}

// MARK: - BrowseItem Tests

final class BrowseItemTests: XCTestCase {

    func testRequiresService() {
        let item = BrowseItem(id: "FV:2/1", title: "Sonos Radio")
        XCTAssertTrue(item.requiresService)
    }

    func testPlayableWithURI() {
        let item = BrowseItem(id: "FV:2/1", title: "Song", resourceURI: "x-sonos-http:song.mp4?sid=204")
        XCTAssertTrue(item.isPlayable)
        XCTAssertFalse(item.requiresService)
    }

    func testContainerIsPlayable() {
        let item = BrowseItem(id: "A:ALBUM/Test", title: "Test Album", itemClass: .musicAlbum)
        XCTAssertTrue(item.isPlayable)
        XCTAssertTrue(item.isContainer)
    }

    func testBrowseItemClass() {
        XCTAssertEqual(BrowseItemClass.from(upnpClass: "object.item.audioItem.musicTrack"), .musicTrack)
        XCTAssertEqual(BrowseItemClass.from(upnpClass: "object.container.album.musicAlbum"), .musicAlbum)
        XCTAssertEqual(BrowseItemClass.from(upnpClass: "object.item.audioItem.audioBroadcast"), .radioStation)
        XCTAssertEqual(BrowseItemClass.from(upnpClass: "object.container"), .container)
    }
}

// MARK: - Localization Tests

final class LocalizationTests: XCTestCase {

    func testEnglishDefaults() {
        UserDefaults.standard.set("en", forKey: "appLanguage")
        XCTAssertEqual(L10n.settings, "Settings")
        XCTAssertEqual(L10n.play, "Play")
        XCTAssertEqual(L10n.rooms, "Rooms")
        XCTAssertEqual(L10n.queue, "Queue")
    }

    func testGermanTranslation() {
        UserDefaults.standard.set("de", forKey: "appLanguage")
        XCTAssertEqual(L10n.settings, "Einstellungen")
        XCTAssertEqual(L10n.rooms, "Räume")
        // Reset
        UserDefaults.standard.set("en", forKey: "appLanguage")
    }

    func testJapaneseTranslation() {
        UserDefaults.standard.set("ja", forKey: "appLanguage")
        XCTAssertEqual(L10n.settings, "設定")
        // Reset
        UserDefaults.standard.set("en", forKey: "appLanguage")
    }

    func testFallbackToEnglish() {
        UserDefaults.standard.set("xx", forKey: "appLanguage")
        XCTAssertEqual(L10n.settings, "Settings")
        // Reset
        UserDefaults.standard.set("en", forKey: "appLanguage")
    }

    func testAllLanguagesHaveSettings() {
        for lang in AppLanguage.allCases {
            UserDefaults.standard.set(lang.rawValue, forKey: "appLanguage")
            XCTAssertFalse(L10n.settings.isEmpty, "Missing 'settings' for \(lang.rawValue)")
        }
        UserDefaults.standard.set("en", forKey: "appLanguage")
    }
}

// MARK: - AppLanguage Tests

final class AppLanguageTests: XCTestCase {

    func testAllCases() {
        XCTAssertEqual(AppLanguage.allCases.count, 13)
    }

    func testDisplayNames() {
        XCTAssertEqual(AppLanguage.english.displayName, "English")
        XCTAssertEqual(AppLanguage.german.displayName, "Deutsch")
        XCTAssertEqual(AppLanguage.japanese.displayName, "日本語")
    }

    func testRawValues() {
        XCTAssertEqual(AppLanguage.english.rawValue, "en")
        XCTAssertEqual(AppLanguage.german.rawValue, "de")
        XCTAssertEqual(AppLanguage.chineseSimplified.rawValue, "zh-Hans")
    }
}

// MARK: - StoredColor Tests

final class StoredColorTests: XCTestCase {

    func testSystem() {
        let color = StoredColor.system
        XCTAssertTrue(color.isSystem)
        XCTAssertLessThan(color.red, 0)
    }

    func testCustom() {
        let color = StoredColor(red: 1.0, green: 0.5, blue: 0.0)
        XCTAssertFalse(color.isSystem)
        XCTAssertEqual(color.red, 1.0)
        XCTAssertEqual(color.green, 0.5)
    }

    func testSaveLoad() {
        let key = "testColor"
        let color = StoredColor(red: 0.2, green: 0.4, blue: 0.6)
        color.save(to: key)
        let loaded = StoredColor.load(from: key)
        XCTAssertEqual(loaded.red, 0.2, accuracy: 0.001)
        XCTAssertEqual(loaded.green, 0.4, accuracy: 0.001)
        XCTAssertEqual(loaded.blue, 0.6, accuracy: 0.001)
        UserDefaults.standard.removeObject(forKey: key)
    }
}

// MARK: - LastChangeParser Tests

final class LastChangeParserTests: XCTestCase {

    func testParseAVTransportEvent() {
        let xml = """
        <e:propertyset xmlns:e="urn:schemas-upnp-org:event-1-0">
          <e:property>
            <LastChange>&lt;Event xmlns=&quot;urn:schemas-upnp-org:metadata-1-0/AVT/&quot;&gt;
              &lt;InstanceID val=&quot;0&quot;&gt;
                &lt;TransportState val=&quot;PLAYING&quot;/&gt;
                &lt;CurrentPlayMode val=&quot;SHUFFLE&quot;/&gt;
              &lt;/InstanceID&gt;
            &lt;/Event&gt;</LastChange>
          </e:property>
        </e:propertyset>
        """

        let event = LastChangeParser.parseAVTransportEvent(xml)
        XCTAssertEqual(event.transportState, .playing)
        XCTAssertEqual(event.currentPlayMode, .shuffle)
    }

    func testParseRenderingControlEvent() {
        let xml = """
        <e:propertyset xmlns:e="urn:schemas-upnp-org:event-1-0">
          <e:property>
            <LastChange>&lt;Event xmlns=&quot;urn:schemas-upnp-org:metadata-1-0/RCS/&quot;&gt;
              &lt;InstanceID val=&quot;0&quot;&gt;
                &lt;Volume channel=&quot;Master&quot; val=&quot;42&quot;/&gt;
                &lt;Mute channel=&quot;Master&quot; val=&quot;0&quot;/&gt;
              &lt;/InstanceID&gt;
            &lt;/Event&gt;</LastChange>
          </e:property>
        </e:propertyset>
        """

        let event = LastChangeParser.parseRenderingControlEvent(xml)
        XCTAssertEqual(event.volume, 42)
        XCTAssertEqual(event.mute, false)
    }
}

// MARK: - EventSubscription Tests

final class EventSubscriptionTests: XCTestCase {

    func testExpiry() {
        let sub = EventSubscription(
            sid: "uuid:test",
            deviceID: "RINCON_001",
            deviceIP: "192.168.1.10",
            devicePort: 1400,
            servicePath: "/MediaRenderer/AVTransport/Control",
            timeout: 1800,
            subscribedAt: Date()
        )
        XCTAssertFalse(sub.isExpired)
        XCTAssertTrue(sub.expiresAt > Date())
        XCTAssertTrue(sub.renewAt < sub.expiresAt)
    }

    func testExpiredSubscription() {
        let sub = EventSubscription(
            sid: "uuid:test",
            deviceID: "RINCON_001",
            deviceIP: "192.168.1.10",
            devicePort: 1400,
            servicePath: "/MediaRenderer/AVTransport/Control",
            timeout: 0,
            subscribedAt: Date().addingTimeInterval(-10)
        )
        XCTAssertTrue(sub.isExpired)
    }
}

@MainActor
final class QueueHistoryStoreTests: XCTestCase {
    private func makeStore() -> QueueHistoryStore {
        let defaults = UserDefaults(suiteName: "QueueHistoryTests-\(UUID().uuidString)")!
        return QueueHistoryStore(defaults: defaults)
    }

    private func snap(_ id: String, _ count: Int = 1) -> QueueSnapshot {
        QueueSnapshot(objectID: id, savedAt: Date(timeIntervalSince1970: TimeInterval(count)),
                      trackCount: count, summary: "\(count) tracks")
    }

    func testRegisterNewestFirst() {
        let store = makeStore()
        _ = store.register(snap("SQ:1"), for: "C1")
        _ = store.register(snap("SQ:2"), for: "C1")
        XCTAssertEqual(store.snapshots(for: "C1").map(\.objectID), ["SQ:2", "SQ:1"])
    }

    func testRetentionPrunesOldestAndReportsOverflow() {
        let store = makeStore()
        var overflow: [String] = []
        for i in 1...(QueueHistoryStore.maxDepth + 2) {
            overflow = store.register(snap("SQ:\(i)"), for: "C1")
        }
        XCTAssertEqual(store.snapshots(for: "C1").count, QueueHistoryStore.maxDepth)
        // The final register pushed SQ:7, evicting the oldest (SQ:1 then SQ:2).
        XCTAssertEqual(overflow, ["SQ:2"])
        XCTAssertEqual(store.snapshots(for: "C1").first?.objectID, "SQ:7")
        XCTAssertFalse(store.snapshots(for: "C1").contains { $0.objectID == "SQ:1" })
    }

    func testPerCoordinatorIsolation() {
        let store = makeStore()
        _ = store.register(snap("SQ:1"), for: "C1")
        _ = store.register(snap("SQ:2"), for: "C2")
        XCTAssertEqual(store.snapshots(for: "C1").map(\.objectID), ["SQ:1"])
        XCTAssertEqual(store.snapshots(for: "C2").map(\.objectID), ["SQ:2"])
    }

    func testReregisterDeduplicates() {
        let store = makeStore()
        _ = store.register(snap("SQ:1"), for: "C1")
        _ = store.register(snap("SQ:2"), for: "C1")
        _ = store.register(snap("SQ:1"), for: "C1")
        XCTAssertEqual(store.snapshots(for: "C1").map(\.objectID), ["SQ:1", "SQ:2"])
    }

    func testRemove() {
        let store = makeStore()
        _ = store.register(snap("SQ:1"), for: "C1")
        store.remove(objectID: "SQ:1", for: "C1")
        XCTAssertTrue(store.snapshots(for: "C1").isEmpty)
    }

    func testPersistenceRoundTrip() {
        let suite = "QueueHistoryTests-persist-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = QueueHistoryStore(defaults: defaults)
        _ = store.register(snap("SQ:9", 42), for: "C1")
        let reloaded = QueueHistoryStore(defaults: defaults)
        XCTAssertEqual(reloaded.snapshots(for: "C1").first?.objectID, "SQ:9")
        XCTAssertEqual(reloaded.snapshots(for: "C1").first?.trackCount, 42)
    }

    /// Regression: restoring the OLDEST snapshot with a full ring must not
    /// let the pre-restore snapshot evict (and destroy) the restore target.
    /// SonosManager touches the target to the head first; this verifies the
    /// store-level contract that a touched entry can't land in overflow.
    func testTouchedSnapshotSurvivesEviction() {
        let store = makeStore()
        for i in 1...QueueHistoryStore.maxDepth {
            _ = store.register(snap("SQ:\(i)"), for: "C1")
        }
        // SQ:1 is the oldest (tail). Touch it, then register a new snapshot.
        _ = store.register(snap("SQ:1"), for: "C1")
        let overflow = store.register(snap("SQ:99"), for: "C1")
        XCTAssertFalse(overflow.contains("SQ:1"))
        XCTAssertTrue(store.snapshots(for: "C1").contains { $0.objectID == "SQ:1" })
        XCTAssertEqual(overflow, ["SQ:2"]) // true oldest after the touch
    }

    func testHistoryTitleDetection() {
        XCTAssertTrue(QueueHistoryStore.isHistoryTitle(QueueHistoryStore.snapshotTitle(at: Date())))
        XCTAssertFalse(QueueHistoryStore.isHistoryTitle("My Playlist"))
    }
}

@MainActor
final class SavedQueueRepositoryTests: XCTestCase {
    private func makeRepo() -> SavedQueueRepository {
        let path = NSTemporaryDirectory() + "savedq-\(UUID().uuidString).sqlite"
        return SavedQueueRepository(dbPath: path)
    }

    private func track(_ pos: Int, _ title: String, uri: String? = nil, metadata: String? = nil) -> QueueItem {
        QueueItem(id: pos, title: title, artist: "Artist", album: "Album",
                  albumArtURI: nil, duration: "0:03:00", uri: uri ?? "x-test://\(pos)",
                  metadata: metadata)
    }

    func testMetadataRoundTrip() {
        let repo = makeRepo()
        let didl = "<DIDL-Lite><item id=\"x\"><dc:title>T</dc:title></item></DIDL-Lite>"
        let id = repo.save(name: "AM", tracks: [track(1, "T", metadata: didl)])!
        XCTAssertEqual(repo.tracks(for: id).first?.metadata, didl)
    }

    func testSaveListTracksRoundTrip() {
        let repo = makeRepo()
        let id = repo.save(name: "Road Trip", tracks: [track(1, "One"), track(2, "Two")])
        XCTAssertNotNil(id)
        let list = repo.list()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.name, "Road Trip")
        XCTAssertEqual(list.first?.trackCount, 2)
        let tracks = repo.tracks(for: id!)
        XCTAssertEqual(tracks.map(\.title), ["One", "Two"])
        XCTAssertEqual(tracks.map(\.uri), ["x-test://1", "x-test://2"])
    }

    func testSaveEmptyReturnsNil() {
        XCTAssertNil(makeRepo().save(name: "Empty", tracks: []))
    }

    func testRename() {
        let repo = makeRepo()
        let id = repo.save(name: "Old", tracks: [track(1, "T")])!
        repo.rename(id: id, to: "New")
        XCTAssertEqual(repo.list().first?.name, "New")
    }

    func testDeleteCascadesTracks() {
        let repo = makeRepo()
        let id = repo.save(name: "Gone", tracks: [track(1, "T")])!
        repo.delete(id: id)
        XCTAssertTrue(repo.list().isEmpty)
        XCTAssertTrue(repo.tracks(for: id).isEmpty)
    }

    func testTitlesWithQuotesAndUnicode() {
        let repo = makeRepo()
        let id = repo.save(name: "K\u{00FC}che's \"Mix\"", tracks: [track(1, "Bj\u{00F6}rk — J\u{00F3}ga")])!
        XCTAssertEqual(repo.list().first?.name, "K\u{00FC}che's \"Mix\"")
        XCTAssertEqual(repo.tracks(for: id).first?.title, "Bj\u{00F6}rk — J\u{00F3}ga")
    }
}
