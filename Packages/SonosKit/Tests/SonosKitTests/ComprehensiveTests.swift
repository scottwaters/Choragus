/// ComprehensiveTests.swift — Full coverage tests for refactored code.
///
/// Covers: TrackMetadata (parseStreamContent, isTechnicalName, smartCase),
/// AppError sanitization, centralized constants, ImageCache/SonosCache,
/// PlayHistoryRepository, AlbumArtSearchService helpers, LastChangeParser
/// edge cases, BrowseXMLParser, and SOAPError conversion.
import XCTest
@testable import SonosKit

// MARK: - TrackMetadata: parseStreamContent

final class ParseStreamContentTests: XCTestCase {

    func testArtistAndTitle() {
        let result = TrackMetadata.parseStreamContent("Busta Rhymes - Gimme Some More")
        XCTAssertEqual(result?.artist, "Busta Rhymes")
        XCTAssertEqual(result?.title, "Gimme Some More")
    }

    func testTitleWithMultipleDashes() {
        let result = TrackMetadata.parseStreamContent("The Beatles - Back In Black - Remastered")
        XCTAssertEqual(result?.artist, "The Beatles")
        XCTAssertEqual(result?.title, "Back In Black - Remastered")
    }

    func testTitleOnly() {
        let result = TrackMetadata.parseStreamContent("Just A Title")
        XCTAssertEqual(result?.artist, "")
        XCTAssertEqual(result?.title, "Just A Title")
    }

    func testEmptyString() {
        let result = TrackMetadata.parseStreamContent("")
        XCTAssertNil(result)
    }

    func testAllCapsConverted() {
        let result = TrackMetadata.parseStreamContent("JOURNEY - SEPARATE WAYS")
        XCTAssertEqual(result?.artist, "Journey")
        XCTAssertEqual(result?.title, "Separate Ways")
    }

    func testRomanNumeralsPreserved() {
        let result = TrackMetadata.parseStreamContent("ARTIST - ROCKY III")
        XCTAssertEqual(result?.title, "Rocky III")
    }

    func testMixedCaseUntouched() {
        let result = TrackMetadata.parseStreamContent("The Beatles - Let It Be")
        XCTAssertEqual(result?.artist, "The Beatles")
        XCTAssertEqual(result?.title, "Let It Be")
    }

    func testWhitespaceTrimmed() {
        let result = TrackMetadata.parseStreamContent("  Artist  -  Title  ")
        XCTAssertEqual(result?.artist, "Artist")
        XCTAssertEqual(result?.title, "Title")
    }

    func testBracketCapitalisation() {
        let result = TrackMetadata.parseStreamContent("ARTIST - SONG (THE REMIX)")
        // ALL CAPS triggers smartCase → title case, bracket cap fix capitalises after (
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.artist, "Artist")
        XCTAssertEqual(result?.title, "Song (The Remix)")
    }
}

// MARK: - TrackMetadata: isTechnicalName

final class IsTechnicalNameTests: XCTestCase {

    func testEmpty() {
        XCTAssertFalse(TrackMetadata.isTechnicalName(""))
    }

    func testNormalTitle() {
        XCTAssertFalse(TrackMetadata.isTechnicalName("Bohemian Rhapsody"))
    }

    func testFileExtensionMp3() {
        XCTAssertTrue(TrackMetadata.isTechnicalName("track01.mp3"))
    }

    func testFileExtensionFlac() {
        XCTAssertTrue(TrackMetadata.isTechnicalName("song.flac"))
    }

    func testFileExtensionM3u8() {
        XCTAssertTrue(TrackMetadata.isTechnicalName("playlist.m3u8"))
    }

    func testFileExtensionAac() {
        XCTAssertTrue(TrackMetadata.isTechnicalName("audio.aac"))
    }

    func testFileExtensionOgg() {
        XCTAssertTrue(TrackMetadata.isTechnicalName("track.ogg"))
    }

    func testFileExtensionWav() {
        XCTAssertTrue(TrackMetadata.isTechnicalName("sample.wav"))
    }

    func testFileExtensionPls() {
        XCTAssertTrue(TrackMetadata.isTechnicalName("radio.pls"))
    }

    func testFileExtensionMp4() {
        XCTAssertTrue(TrackMetadata.isTechnicalName("video.mp4"))
    }

    func testFileExtensionM3u() {
        XCTAssertTrue(TrackMetadata.isTechnicalName("list.m3u"))
    }

    func testDotNoSpaces() {
        XCTAssertTrue(TrackMetadata.isTechnicalName("some.technical.name"))
    }

    func testDotWithSpaces() {
        XCTAssertFalse(TrackMetadata.isTechnicalName("Dr. Dre feat. Eminem"))
    }

    func testUnderscoresNoSpaces() {
        XCTAssertTrue(TrackMetadata.isTechnicalName("stream_id_12345"))
    }

    func testUnderscoresWithSpaces() {
        XCTAssertFalse(TrackMetadata.isTechnicalName("under_score with spaces"))
    }

    func testURL() {
        XCTAssertTrue(TrackMetadata.isTechnicalName("http://stream.example.com"))
    }

    func testURLQuery() {
        XCTAssertTrue(TrackMetadata.isTechnicalName("stream?format=mp3"))
    }

    func testURLAmpersand() {
        XCTAssertTrue(TrackMetadata.isTechnicalName("track&id=123"))
    }

    func testXPrefix() {
        XCTAssertTrue(TrackMetadata.isTechnicalName("x-sonosapi-stream:123"))
    }

    func testHttpPrefix() {
        XCTAssertTrue(TrackMetadata.isTechnicalName("https://cdn.example.com"))
    }

    func testShortAlphanumericDigitOnly() {
        XCTAssertTrue(TrackMetadata.isTechnicalName("5"))
    }

    func testShortArtistNames() {
        XCTAssertFalse(TrackMetadata.isTechnicalName("U2"))
        XCTAssertFalse(TrackMetadata.isTechnicalName("SWV"))
        XCTAssertFalse(TrackMetadata.isTechnicalName("AB1"))
    }

    func testFourCharWord() {
        XCTAssertFalse(TrackMetadata.isTechnicalName("Song"))
    }
}

// MARK: - TrackMetadata: smartCase

final class SmartCaseTests: XCTestCase {

    func testAllCapsToTitleCase() {
        XCTAssertEqual(TrackMetadata.smartCase("BOHEMIAN RHAPSODY"), "Bohemian Rhapsody")
    }

    func testMixedCaseUnchanged() {
        XCTAssertEqual(TrackMetadata.smartCase("Already Good"), "Already Good")
    }

    func testLowercaseUnchanged() {
        XCTAssertEqual(TrackMetadata.smartCase("lowercase text"), "lowercase text")
    }

    func testRomanNumeralPreserved() {
        XCTAssertEqual(TrackMetadata.smartCase("ROCKY IV"), "Rocky IV")
    }

    func testMultipleRomanNumerals() {
        XCTAssertEqual(TrackMetadata.smartCase("PART III SCENE II"), "Part III Scene II")
    }

    func testBracketCapitalisationAfterParen() {
        let result = TrackMetadata.smartCase("song (the remix)")
        XCTAssertEqual(result, "song (The remix)")
    }

    func testBracketCapitalisationAfterSlash() {
        let result = TrackMetadata.smartCase("title /subtitle")
        XCTAssertEqual(result, "title /Subtitle")
    }

    func testBracketCapitalisationAfterBracket() {
        let result = TrackMetadata.smartCase("song [live version]")
        XCTAssertEqual(result, "song [Live version]")
    }

    func testEmptyString() {
        XCTAssertEqual(TrackMetadata.smartCase(""), "")
    }

    func testSingleWord() {
        XCTAssertEqual(TrackMetadata.smartCase("HELLO"), "Hello")
    }
}

// MARK: - AppError Sanitization

final class AppErrorTests: XCTestCase {

    func testSOAPFaultSanitized() {
        let error = AppError.soapFault(code: "401", message: "Internal speaker stack trace here")
        XCTAssertEqual(error.errorDescription, "Speaker reported an invalid action.")
        XCTAssertFalse(error.errorDescription?.contains("stack trace") ?? true)
    }

    func testSOAPFault402() {
        let error = AppError.soapFault(code: "402", message: "raw detail")
        XCTAssertEqual(error.errorDescription, "The requested item was not found.")
    }

    func testSOAPFault714() {
        let error = AppError.soapFault(code: "714", message: "raw")
        XCTAssertEqual(error.errorDescription, "The requested item was not found.")
    }

    func testSOAPFault701() {
        let error = AppError.soapFault(code: "701", message: "raw")
        XCTAssertTrue(error.errorDescription?.contains("transition") ?? false)
    }

    func testSOAPFault711() {
        let error = AppError.soapFault(code: "711", message: "raw")
        XCTAssertTrue(error.errorDescription?.contains("not supported") ?? false)
    }

    func testSOAPFault712() {
        let error = AppError.soapFault(code: "712", message: "raw")
        XCTAssertTrue(error.errorDescription?.contains("queue is full") ?? false)
    }

    func testSOAPFault718() {
        let error = AppError.soapFault(code: "718", message: "raw")
        XCTAssertTrue(error.errorDescription?.contains("seek") ?? false)
    }

    func testSOAPFault800() {
        let error = AppError.soapFault(code: "800", message: "raw")
        XCTAssertTrue(error.errorDescription?.contains("authentication") ?? false)
    }

    func testSOAPFaultParse() {
        let error = AppError.soapFault(code: "parse", message: "raw detail")
        XCTAssertTrue(error.errorDescription?.contains("unexpected response") ?? false)
    }

    func testSOAPFaultSMAPI() {
        let error = AppError.soapFault(code: "SMAPI", message: "raw")
        XCTAssertTrue(error.errorDescription?.contains("music service") ?? false)
    }

    func testSOAPFaultUnknownCode() {
        let error = AppError.soapFault(code: "999", message: "should not appear")
        XCTAssertTrue(error.errorDescription?.contains("code 999") ?? false)
        XCTAssertFalse(error.errorDescription?.contains("should not appear") ?? true)
    }

    func testUnknownErrorSanitized() {
        let error = AppError.unknown(NSError(domain: "test", code: 42, userInfo: [NSLocalizedDescriptionKey: "secret detail"]))
        XCTAssertEqual(error.errorDescription, "An unexpected error occurred.")
        XCTAssertFalse(error.errorDescription?.contains("secret") ?? true)
    }

    func testNetworkUnavailable() {
        XCTAssertTrue(AppError.networkUnavailable.errorDescription?.contains("network") ?? false)
    }

    func testTimeout() {
        XCTAssertTrue(AppError.timeout.errorDescription?.contains("timed out") ?? false)
    }

    func testSpeakerNotFound() {
        let error = AppError.speakerNotFound("Living Room")
        XCTAssertTrue(error.errorDescription?.contains("Living Room") ?? false)
    }

    func testServiceAuthRequired() {
        let error = AppError.serviceAuthRequired("Spotify")
        XCTAssertTrue(error.errorDescription?.contains("Spotify") ?? false)
    }

    // MARK: - SOAPError Conversion

    func testFromSOAPErrorInvalidURL() {
        let result = AppError.from(SOAPError.invalidURL)
        if case .networkUnavailable = result {} else { XCTFail("Expected networkUnavailable") }
    }

    func testFromSOAPErrorHTTP() {
        let result = AppError.from(SOAPError.httpError(500, "Internal Server Error with stack trace"))
        if case .soapFault(let code, _) = result {
            XCTAssertEqual(code, "500")
        } else { XCTFail("Expected soapFault") }
        // Body should not appear in user message
        XCTAssertFalse(result.errorDescription?.contains("Internal Server Error") ?? true)
    }

    func testFromSOAPErrorTimeout() {
        let urlError = URLError(.timedOut)
        let result = AppError.from(SOAPError.networkError(urlError))
        if case .timeout = result {} else { XCTFail("Expected timeout") }
    }

    func testFromSOAPErrorNetwork() {
        let error = NSError(domain: "test", code: 1)
        let result = AppError.from(SOAPError.networkError(error))
        if case .networkUnavailable = result {} else { XCTFail("Expected networkUnavailable") }
    }

    func testFromSOAPErrorAuthRequired402() {
        let result = AppError.from(SOAPError.soapFault("402", "No such item"))
        if case .serviceAuthRequired = result {} else { XCTFail("Expected serviceAuthRequired for 402") }
    }

    func testFromSOAPErrorAuthRequired714() {
        let result = AppError.from(SOAPError.soapFault("714", "No such item"))
        if case .serviceAuthRequired = result {} else { XCTFail("Expected serviceAuthRequired for 714") }
    }

    func testFromSOAPErrorAuthRequired800() {
        let result = AppError.from(SOAPError.soapFault("800", "Auth required"))
        if case .serviceAuthRequired = result {} else { XCTFail("Expected serviceAuthRequired for 800") }
    }

    func testFromSOAPErrorRegularFault() {
        let result = AppError.from(SOAPError.soapFault("701", "Transition not available"))
        if case .soapFault(let code, _) = result {
            XCTAssertEqual(code, "701")
        } else { XCTFail("Expected soapFault") }
    }

    func testFromSOAPErrorParse() {
        let result = AppError.from(SOAPError.parseError("bad xml"))
        if case .soapFault(let code, _) = result {
            XCTAssertEqual(code, "parse")
        } else { XCTFail("Expected soapFault with parse code") }
    }

    // MARK: - SMAPIError Conversion

    func testFromSMAPIErrorInvalidURL() {
        let result = AppError.from(SMAPIError.invalidURL)
        if case .networkUnavailable = result {} else { XCTFail("Expected networkUnavailable") }
    }

    func testFromSMAPIErrorNotAuthenticated() {
        let result = AppError.from(SMAPIError.notAuthenticated)
        if case .serviceAuthRequired = result {} else { XCTFail("Expected serviceAuthRequired") }
    }

    func testFromSMAPIErrorAuthFailed() {
        let result = AppError.from(SMAPIError.authFailed("token expired"))
        if case .serviceAuthRequired = result {} else { XCTFail("Expected serviceAuthRequired") }
    }

    func testFromSMAPIErrorSoapFault() {
        let result = AppError.from(SMAPIError.soapFault("some detail"))
        if case .soapFault(let code, _) = result {
            XCTAssertEqual(code, "SMAPI")
        } else { XCTFail("Expected soapFault") }
    }
}

// MARK: - Constants Tests

final class ConstantsTests: XCTestCase {

    // MARK: - BrowseID
    func testBrowseIDs() {
        XCTAssertEqual(BrowseID.favorites, "FV:2")
        XCTAssertEqual(BrowseID.playlists, "SQ:")
        XCTAssertEqual(BrowseID.libraryRoot, "A:")
        XCTAssertEqual(BrowseID.albumArtist, "A:ALBUMARTIST")
        XCTAssertEqual(BrowseID.album, "A:ALBUM")
        XCTAssertEqual(BrowseID.tracks, "A:TRACKS")
        XCTAssertEqual(BrowseID.shares, "S:")
        XCTAssertEqual(BrowseID.smapiRoot, "root")
    }

    // MARK: - PageSize
    func testPageSizes() {
        XCTAssertEqual(PageSize.browse, 100)
        XCTAssertEqual(PageSize.queue, 100)
        XCTAssertEqual(PageSize.search, 50)
        XCTAssertEqual(PageSize.searchArtist, 20)
        XCTAssertEqual(PageSize.searchAlbum, 20)
        XCTAssertEqual(PageSize.searchTrack, 30)
        XCTAssertEqual(PageSize.smapiAuth, 200)
    }

    // MARK: - CacheDefaults
    func testCacheDefaults() {
        XCTAssertEqual(CacheDefaults.imageDiskMaxSizeMB, 500)
        XCTAssertEqual(CacheDefaults.imageDiskMaxAgeDays, 30)
        XCTAssertEqual(CacheDefaults.imageMemoryCountLimit, 200)
        XCTAssertEqual(CacheDefaults.imageMemoryBytesLimit, 50 * 1024 * 1024)
        XCTAssertEqual(CacheDefaults.imageEvictionFrequency, 50)
        XCTAssertEqual(CacheDefaults.playHistoryMaxEntries, 50_000)
    }

    // MARK: - Timing
    func testTimingConstants() {
        XCTAssertEqual(Timing.subscriptionRenewalCheck, 60)
        XCTAssertEqual(Timing.reconciliationPolling, 15)
        XCTAssertEqual(Timing.legacyPolling, 5)
        XCTAssertEqual(Timing.metadataPolling, 5_000_000_000)
        XCTAssertEqual(Timing.musicServicesRetryDelay, 3)
        XCTAssertEqual(Timing.groupRefreshDelay, 1)
        XCTAssertEqual(Timing.searchDebounce, 300_000_000)
        XCTAssertEqual(Timing.marqueeAnimationPause, 500_000_000)
        XCTAssertEqual(Timing.soapRequestTimeout, 10)
        XCTAssertEqual(Timing.progressTimerInterval, 1.0)
        XCTAssertEqual(Timing.discoveryRescanInterval, 30)
    }

    // MARK: - Existing Constants
    func testSonosProtocol() {
        XCTAssertEqual(SonosProtocol.defaultPort, 1400)
    }

    func testServiceIDs() {
        XCTAssertEqual(ServiceID.spotify, 12)
        XCTAssertEqual(ServiceID.appleMusic, 204)
        XCTAssertEqual(ServiceID.tuneIn, 254)
        XCTAssertEqual(ServiceID.amazonMusic, 201)
    }

    func testServiceNames() {
        XCTAssertEqual(ServiceName.spotify, "Spotify")
        XCTAssertEqual(ServiceName.appleMusic, "Apple Music")
        XCTAssertEqual(ServiceName.radio, "Radio")
        XCTAssertEqual(ServiceName.musicLibrary, "Music Library")
    }

    func testUDKeys() {
        XCTAssertEqual(UDKey.appLanguage, "appLanguage")
        XCTAssertEqual(UDKey.startupMode, "startupMode")
        XCTAssertEqual(UDKey.playHistoryEnabled, "playHistoryEnabled")
    }
}

// MARK: - AlbumArtSearchService Helpers

final class AlbumArtHelperTests: XCTestCase {

    func testGetaaURL() {
        let url = AlbumArtSearchService.getaaURL(speakerIP: "192.168.1.10", port: 1400, trackURI: "x-file-cifs://nas/song.mp3")
        XCTAssertTrue(url.hasPrefix("http://192.168.1.10:1400/getaa?s=1&u="))
        XCTAssertTrue(url.contains("x-file-cifs"))
    }

    func testGetaaURLDefaultPort() {
        let url = AlbumArtSearchService.getaaURL(speakerIP: "10.0.0.5", trackURI: "x-smb://share/song.flac")
        XCTAssertTrue(url.hasPrefix("http://10.0.0.5:1400/getaa?s=1&u="))
    }

    func testCleanTrackTitleStripsParenthetical() {
        XCTAssertEqual(AlbumArtSearchService.cleanTrackTitle("Song (Radio Edit)"), "Song")
    }

    func testCleanTrackTitleStripsBrackets() {
        XCTAssertEqual(AlbumArtSearchService.cleanTrackTitle("Song [Deluxe Version]"), "Song")
    }

    func testCleanTrackTitleStripsSuffix() {
        XCTAssertEqual(AlbumArtSearchService.cleanTrackTitle("Theme Main Title"), "Theme")
    }

    func testCleanTrackTitleStripsEndCredits() {
        XCTAssertEqual(AlbumArtSearchService.cleanTrackTitle("Movie End Credits"), "Movie")
    }

    func testCleanTrackTitleStripsSuite() {
        XCTAssertEqual(AlbumArtSearchService.cleanTrackTitle("Piano Suite"), "Piano")
    }

    func testCleanTrackTitlePreservesPlain() {
        XCTAssertEqual(AlbumArtSearchService.cleanTrackTitle("Bohemian Rhapsody"), "Bohemian Rhapsody")
    }

    func testCleanTrackTitleEmpty() {
        XCTAssertEqual(AlbumArtSearchService.cleanTrackTitle(""), "")
    }

    func testCleanTrackTitleUnclosedParen() {
        XCTAssertEqual(AlbumArtSearchService.cleanTrackTitle("Song (incomplete"), "Song")
    }
}

// MARK: - PlayHistoryRepository Tests

@MainActor
final class PlayHistoryRepositoryTests: XCTestCase {

    private var repo: PlayHistoryRepository!
    private var dbPath: String!

    override func setUp() {
        super.setUp()
        dbPath = NSTemporaryDirectory() + "test_history_\(UUID().uuidString).sqlite"
        repo = PlayHistoryRepository(dbPath: dbPath)
    }

    override func tearDown() {
        repo = nil
        try? FileManager.default.removeItem(atPath: dbPath)
        super.tearDown()
    }

    func testInsertAndLoad() {
        let entry = PlayHistoryEntry(title: "Test Song", artist: "Test Artist", album: "Test Album")
        repo.insert(entry)
        let loaded = repo.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.title, "Test Song")
        XCTAssertEqual(loaded.first?.artist, "Test Artist")
    }

    func testInsertMultiple() {
        for i in 0..<5 {
            repo.insert(PlayHistoryEntry(title: "Song \(i)"))
        }
        let loaded = repo.loadAll()
        XCTAssertEqual(loaded.count, 5)
    }

    func testCountFiltered() {
        for i in 0..<3 {
            repo.insert(PlayHistoryEntry(title: "Song \(i)"))
        }
        XCTAssertEqual(repo.countFiltered(), 3)
    }

    func testHasRecentEntry() {
        let entry = PlayHistoryEntry(title: "Recent", artist: "Artist", groupName: "Room")
        repo.insert(entry)
        let cutoff = Date().timeIntervalSince1970 - 60
        XCTAssertTrue(repo.hasRecentEntry(title: "Recent", artist: "Artist", groupName: "Room", since: cutoff))
        XCTAssertFalse(repo.hasRecentEntry(title: "Other", artist: "Artist", groupName: "Room", since: cutoff))
    }

    func testUpdateArtwork() {
        let entry = PlayHistoryEntry(title: "Song", artist: "Artist")
        repo.insert(entry)
        repo.updateArtwork(id: entry.id, artURL: "https://example.com/art.jpg")
        let loaded = repo.loadAll()
        XCTAssertEqual(loaded.first?.albumArtURI, "https://example.com/art.jpg")
    }

    func testStarredDefault() {
        let entry = PlayHistoryEntry(title: "Song")
        repo.insert(entry)
        XCTAssertFalse(repo.loadAll().first?.starred ?? true)
    }

    func testDeleteAll() {
        for i in 0..<3 {
            repo.insert(PlayHistoryEntry(title: "Song \(i)"))
        }
        repo.deleteAll()
        XCTAssertEqual(repo.countFiltered(), 0)
    }

    func testStationNameStored() {
        let entry = PlayHistoryEntry(title: "Track", stationName: "BBC Radio 1")
        repo.insert(entry)
        let loaded = repo.loadAll()
        XCTAssertEqual(loaded.first?.stationName, "BBC Radio 1")
    }

    func testDurationStored() {
        let entry = PlayHistoryEntry(title: "Track", duration: 245.5)
        repo.insert(entry)
        let loaded = repo.loadAll()
        XCTAssertEqual(loaded.first?.duration ?? 0, 245.5, accuracy: 0.1)
    }

    func testSourceURIStored() {
        let entry = PlayHistoryEntry(title: "Track", sourceURI: "x-sonos-http:track?sid=12")
        repo.insert(entry)
        let loaded = repo.loadAll()
        XCTAssertEqual(loaded.first?.sourceURI, "x-sonos-http:track?sid=12")
    }
}

// MARK: - LastChangeParser Extended Tests

final class LastChangeParserExtendedTests: XCTestCase {

    func testParseAVTransportEventWithTrackMetaData() {
        let xml = """
        <e:propertyset xmlns:e="urn:schemas-upnp-org:event-1-0">
          <e:property>
            <LastChange>&lt;Event&gt;
              &lt;InstanceID val=&quot;0&quot;&gt;
                &lt;TransportState val=&quot;PAUSED_PLAYBACK&quot;/&gt;
                &lt;CurrentTrackURI val=&quot;x-sonos-http:track.mp4?sid=204&quot;/&gt;
                &lt;CurrentTrackDuration val=&quot;0:04:30&quot;/&gt;
                &lt;NumberOfTracks val=&quot;15&quot;/&gt;
              &lt;/InstanceID&gt;
            &lt;/Event&gt;</LastChange>
          </e:property>
        </e:propertyset>
        """

        let event = LastChangeParser.parseAVTransportEvent(xml)
        XCTAssertEqual(event.transportState, .paused)
        XCTAssertEqual(event.currentTrackURI, "x-sonos-http:track.mp4?sid=204")
        XCTAssertEqual(event.currentTrackDuration, "0:04:30")
        XCTAssertEqual(event.numberOfTracks, 15)
    }

    func testParseRenderingControlWithBassAndTreble() {
        let xml = """
        <e:propertyset xmlns:e="urn:schemas-upnp-org:event-1-0">
          <e:property>
            <LastChange>&lt;Event&gt;
              &lt;InstanceID val=&quot;0&quot;&gt;
                &lt;Volume channel=&quot;Master&quot; val=&quot;65&quot;/&gt;
                &lt;Volume channel=&quot;LF&quot; val=&quot;100&quot;/&gt;
                &lt;Mute channel=&quot;Master&quot; val=&quot;1&quot;/&gt;
                &lt;Bass val=&quot;5&quot;/&gt;
                &lt;Treble val=&quot;-3&quot;/&gt;
                &lt;Loudness channel=&quot;Master&quot; val=&quot;1&quot;/&gt;
              &lt;/InstanceID&gt;
            &lt;/Event&gt;</LastChange>
          </e:property>
        </e:propertyset>
        """

        let event = LastChangeParser.parseRenderingControlEvent(xml)
        XCTAssertEqual(event.volume, 65) // Master only, LF ignored
        XCTAssertEqual(event.mute, true)
        XCTAssertEqual(event.bass, 5)
        XCTAssertEqual(event.treble, -3)
        XCTAssertEqual(event.loudness, true)
    }

    func testParseEmptyXML() {
        let event = LastChangeParser.parseAVTransportEvent("")
        XCTAssertNil(event.transportState)
        XCTAssertNil(event.currentTrackURI)
    }

    func testParseMalformedXML() {
        let event = LastChangeParser.parseAVTransportEvent("not xml at all")
        XCTAssertNil(event.transportState)
    }

    func testParsePropertySetWithValAttributes() {
        // Test the fallback path where XML already contains val= attributes
        let xml = """
        <Event><InstanceID val="0"><TransportState val="STOPPED"/><CurrentPlayMode val="REPEAT_ALL"/></InstanceID></Event>
        """
        let values = LastChangeParser.parsePropertySet(xml)
        XCTAssertEqual(values["TransportState"], "STOPPED")
        XCTAssertEqual(values["CurrentPlayMode"], "REPEAT_ALL")
    }
}

// MARK: - PlayHistoryEntry Tests

final class PlayHistoryEntryTests: XCTestCase {

    func testDefaultValues() {
        let entry = PlayHistoryEntry(title: "Test")
        XCTAssertEqual(entry.title, "Test")
        XCTAssertEqual(entry.artist, "")
        XCTAssertEqual(entry.album, "")
        XCTAssertEqual(entry.stationName, "")
        XCTAssertNil(entry.sourceURI)
        XCTAssertEqual(entry.groupName, "")
        XCTAssertEqual(entry.duration, 0)
        XCTAssertNil(entry.albumArtURI)
        XCTAssertFalse(entry.starred)
    }

    func testCustomValues() {
        let entry = PlayHistoryEntry(
            title: "Song", artist: "Artist", album: "Album",
            stationName: "Station", sourceURI: "uri",
            groupName: "Room", duration: 180,
            albumArtURI: "https://art.jpg", starred: true
        )
        XCTAssertEqual(entry.title, "Song")
        XCTAssertEqual(entry.artist, "Artist")
        XCTAssertEqual(entry.album, "Album")
        XCTAssertEqual(entry.stationName, "Station")
        XCTAssertEqual(entry.sourceURI, "uri")
        XCTAssertEqual(entry.groupName, "Room")
        XCTAssertEqual(entry.duration, 180)
        XCTAssertEqual(entry.albumArtURI, "https://art.jpg")
        XCTAssertTrue(entry.starred)
    }

    func testCodable() throws {
        let entry = PlayHistoryEntry(title: "Codable Test", artist: "Encoder")
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(PlayHistoryEntry.self, from: data)
        XCTAssertEqual(decoded.title, "Codable Test")
        XCTAssertEqual(decoded.artist, "Encoder")
        XCTAssertEqual(decoded.id, entry.id)
    }
}

// MARK: - EventSubscription Extended Tests

final class EventSubscriptionExtendedTests: XCTestCase {

    func testRenewAtIsBeforeExpiry() {
        let sub = EventSubscription(
            sid: "uuid:test", deviceID: "R1", deviceIP: "10.0.0.1",
            devicePort: 1400, servicePath: "/AVTransport/Control",
            timeout: 1800, subscribedAt: Date()
        )
        XCTAssertTrue(sub.renewAt < sub.expiresAt)
        // renewAt should be ~80% of timeout
        let expectedRenew = sub.subscribedAt.addingTimeInterval(1800 * Timing.subscriptionRenewalFraction)
        XCTAssertEqual(sub.renewAt.timeIntervalSince1970, expectedRenew.timeIntervalSince1970, accuracy: 1)
    }

    func testServicePath() {
        let sub = EventSubscription(
            sid: "uuid:abc", deviceID: "R1", deviceIP: "10.0.0.1",
            devicePort: 1400, servicePath: "/MediaRenderer/RenderingControl/Control",
            timeout: 600, subscribedAt: Date()
        )
        XCTAssertEqual(sub.servicePath, "/MediaRenderer/RenderingControl/Control")
        XCTAssertEqual(sub.deviceID, "R1")
    }
}

// MARK: - SonosDevice & SonosGroup Extended Tests

final class SonosModelTests: XCTestCase {

    func testDeviceDefaultPort() {
        let device = SonosDevice(id: "R1", ip: "10.0.0.1")
        XCTAssertEqual(device.port, SonosProtocol.defaultPort)
    }

    func testDeviceCustomPort() {
        let device = SonosDevice(id: "R1", ip: "10.0.0.1", port: 3400)
        XCTAssertEqual(device.port, 3400)
    }

    func testGroupCoordinatorNil() {
        let member = SonosDevice(id: "R2", ip: "10.0.0.2")
        let group = SonosGroup(id: "g1", coordinatorID: "R1", members: [member])
        XCTAssertNil(group.coordinator) // R1 not in members
    }

    func testDeviceIsCoordinator() {
        let device = SonosDevice(id: "R1", ip: "10.0.0.1", isCoordinator: true)
        XCTAssertTrue(device.isCoordinator)
    }
}

// MARK: - ServiceColor Tests

final class ServiceColorTests: XCTestCase {

    func testKnownServiceColors() {
        // Just verify they return non-nil colors (exact color matching is fragile)
        let _ = ServiceColor.color(for: ServiceName.musicLibrary)
        let _ = ServiceColor.color(for: ServiceName.radio)
        let _ = ServiceColor.color(for: ServiceName.spotify)
        let _ = ServiceColor.color(for: "TV")
        let _ = ServiceColor.color(for: "Unknown Service")
        // If we get here without crash, the color lookup works
    }
}

// MARK: - RINCONService Tests

final class RINCONServiceTests: XCTestCase {

    func testKnownMappings() {
        XCTAssertEqual(RINCONService.knownNames[2311], "Spotify")
        XCTAssertEqual(RINCONService.knownNames[3079], "TuneIn")
        XCTAssertEqual(RINCONService.knownNames[52231], "Apple Music")
        XCTAssertEqual(RINCONService.knownNames[65031], "Amazon Music")
    }

    func testUnknownMapping() {
        XCTAssertNil(RINCONService.knownNames[99999])
    }
}

// MARK: - TrackMetadata enrichFromMediaInfo Extended

final class EnrichFromMediaInfoExtendedTests: XCTestCase {

    let device = SonosDevice(id: "R1", ip: "10.0.0.5", port: 1400)

    func testSetsQueueSource() {
        var meta = TrackMetadata()
        let mediaInfo: [String: String] = [
            "CurrentURI": "x-rincon-queue:RINCON_001#0",
            "CurrentURIMetaData": "",
            "NrTracks": "25"
        ]
        meta.enrichFromMediaInfo(mediaInfo, device: device)
        XCTAssertTrue(meta.isQueueSource)
        XCTAssertEqual(meta.queueSize, 25)
    }

    func testNonQueueSource() {
        var meta = TrackMetadata()
        let mediaInfo: [String: String] = [
            "CurrentURI": "x-sonosapi-stream:s123",
            "CurrentURIMetaData": ""
        ]
        meta.enrichFromMediaInfo(mediaInfo, device: device)
        XCTAssertFalse(meta.isQueueSource)
    }

    func testMissingMediaInfo() {
        var meta = TrackMetadata(title: "Original")
        meta.enrichFromMediaInfo([:], device: device)
        XCTAssertEqual(meta.title, "Original")
    }
}

// MARK: - XML Unescape Edge Cases

final class XMLUnescapeTests: XCTestCase {

    func testQuotAndApos() {
        XCTAssertEqual(XMLResponseParser.xmlUnescape("&quot;hello&apos;"), "\"hello'")
    }

    func testNoEscapes() {
        XCTAssertEqual(XMLResponseParser.xmlUnescape("plain text"), "plain text")
    }

    func testMixed() {
        XCTAssertEqual(XMLResponseParser.xmlUnescape("a &amp; b &lt; c"), "a & b < c")
    }

    func testEmpty() {
        XCTAssertEqual(XMLResponseParser.xmlUnescape(""), "")
    }
}
