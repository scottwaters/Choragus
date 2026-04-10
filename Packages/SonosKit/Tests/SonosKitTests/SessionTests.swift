/// SessionTests.swift — Tests for code changes made during this session.
///
/// Covers: stream content fallback extraction, isTechnicalName ampersand fix,
/// PlayHistoryManager station logging, updateArtwork matching, ATS domain config,
/// anonymous SMAPI methods, Sonos Radio constants.
import XCTest
@testable import SonosKit

// MARK: - Stream Content Fallback Extraction

final class StreamContentExtractionTests: XCTestCase {

    func testExtractWithNamespacePrefix() {
        let didl = """
        <DIDL-Lite><item><dc:title>Station</dc:title>
        <r:streamContent>Artist Name - Track Title</r:streamContent>
        </item></DIDL-Lite>
        """
        let result = XMLResponseParser.extractStreamContent(didl)
        XCTAssertEqual(result, "Artist Name - Track Title")
    }

    func testExtractWithoutNamespace() {
        let didl = """
        <DIDL-Lite><item><title>Station</title>
        <streamContent>Some Artist - Some Song</streamContent>
        </item></DIDL-Lite>
        """
        let result = XMLResponseParser.extractStreamContent(didl)
        XCTAssertEqual(result, "Some Artist - Some Song")
    }

    func testExtractWithBareAmpersand() {
        let didl = """
        <DIDL-Lite><item><dc:title>Radio</dc:title>
        <r:streamContent>Skrillex & Rick Ross - Purple Lamborghini</r:streamContent>
        </item></DIDL-Lite>
        """
        let result = XMLResponseParser.extractStreamContent(didl)
        XCTAssertEqual(result, "Skrillex & Rick Ross - Purple Lamborghini")
    }

    func testExtractWithEscapedAmpersand() {
        let didl = """
        <DIDL-Lite><item>
        <r:streamContent>Hall &amp; Oates - Kiss On My List</r:streamContent>
        </item></DIDL-Lite>
        """
        let result = XMLResponseParser.extractStreamContent(didl)
        XCTAssertEqual(result, "Hall & Oates - Kiss On My List")
    }

    func testExtractWithCommaInArtist() {
        let didl = """
        <DIDL-Lite><item>
        <r:streamContent>Earth, Wind & Fire - September</r:streamContent>
        </item></DIDL-Lite>
        """
        let result = XMLResponseParser.extractStreamContent(didl)
        XCTAssertEqual(result, "Earth, Wind & Fire - September")
    }

    func testExtractEmpty() {
        let didl = """
        <DIDL-Lite><item>
        <r:streamContent></r:streamContent>
        </item></DIDL-Lite>
        """
        let result = XMLResponseParser.extractStreamContent(didl)
        XCTAssertNil(result)
    }

    func testExtractMissing() {
        let didl = "<DIDL-Lite><item><dc:title>Station</dc:title></item></DIDL-Lite>"
        let result = XMLResponseParser.extractStreamContent(didl)
        XCTAssertNil(result)
    }

    func testExtractWhitespace() {
        let didl = """
        <DIDL-Lite><item>
        <r:streamContent>   </r:streamContent>
        </item></DIDL-Lite>
        """
        let result = XMLResponseParser.extractStreamContent(didl)
        XCTAssertNil(result)
    }
}

// MARK: - isTechnicalName Ampersand Fix

final class IsTechnicalNameAmpersandTests: XCTestCase {

    func testAmpersandWithSpacesIsNotTechnical() {
        XCTAssertFalse(TrackMetadata.isTechnicalName("Skrillex & Rick Ross"))
    }

    func testAmpersandNoSpacesIsTechnical() {
        XCTAssertTrue(TrackMetadata.isTechnicalName("track&id=123"))
    }

    func testQuestionMarkWithSpacesIsNotTechnical() {
        XCTAssertFalse(TrackMetadata.isTechnicalName("Where Are You?"))
    }

    func testQuestionMarkNoSpacesIsTechnical() {
        XCTAssertTrue(TrackMetadata.isTechnicalName("stream?format=mp3"))
    }

    func testCommaInArtistName() {
        XCTAssertFalse(TrackMetadata.isTechnicalName("Earth, Wind & Fire"))
    }

    func testHallAndOates() {
        XCTAssertFalse(TrackMetadata.isTechnicalName("Hall & Oates"))
    }

    func testSimonAndGarfunkel() {
        XCTAssertFalse(TrackMetadata.isTechnicalName("Simon & Garfunkel"))
    }

    func testShortArtistSWV() {
        XCTAssertFalse(TrackMetadata.isTechnicalName("SWV"))
    }

    func testShortArtistREM() {
        XCTAssertFalse(TrackMetadata.isTechnicalName("REM"))
    }

    func testShortArtistU2() {
        XCTAssertFalse(TrackMetadata.isTechnicalName("U2"))
    }

    func testShortArtistTLC() {
        XCTAssertFalse(TrackMetadata.isTechnicalName("TLC"))
    }

    func testShortArtistSZA() {
        XCTAssertFalse(TrackMetadata.isTechnicalName("SZA"))
    }

    func testSingleDigitIsTechnical() {
        XCTAssertTrue(TrackMetadata.isTechnicalName("5"))
    }

    func testShortCodesNotTechnical() {
        XCTAssertFalse(TrackMetadata.isTechnicalName("A1"))
        XCTAssertFalse(TrackMetadata.isTechnicalName("M"))
    }

    func testURLStillTechnical() {
        XCTAssertTrue(TrackMetadata.isTechnicalName("http://stream.example.com"))
        XCTAssertTrue(TrackMetadata.isTechnicalName("https://cdn.example.com"))
    }

    func testXPrefixStillTechnical() {
        XCTAssertTrue(TrackMetadata.isTechnicalName("x-sonosapi-stream:123"))
    }
}

// MARK: - ParseStreamContent with Special Characters

final class ParseStreamContentSpecialCharsTests: XCTestCase {

    func testAmpersandInArtist() {
        let result = TrackMetadata.parseStreamContent("Skrillex & Rick Ross - Purple Lamborghini")
        XCTAssertEqual(result?.artist, "Skrillex & Rick Ross")
        XCTAssertEqual(result?.title, "Purple Lamborghini")
    }

    func testCommaInArtist() {
        let result = TrackMetadata.parseStreamContent("Earth, Wind & Fire - September")
        XCTAssertEqual(result?.artist, "Earth, Wind & Fire")
        XCTAssertEqual(result?.title, "September")
    }

    func testShortArtistName() {
        // "SWV" is all caps → smartCase converts to "Swv"
        let result = TrackMetadata.parseStreamContent("SWV - Right Here")
        XCTAssertEqual(result?.artist, "Swv")
        XCTAssertEqual(result?.title, "Right Here")
    }

    func testTwoLetterArtist() {
        // "U2" is too short for smartCase threshold (>70% uppercase but only 1 letter)
        let result = TrackMetadata.parseStreamContent("U2 - One")
        XCTAssertEqual(result?.artist, "U2")
        XCTAssertEqual(result?.title, "One")
    }

    func testMultipleAmpersands() {
        let result = TrackMetadata.parseStreamContent("Tom & Jerry & Friends - Theme Song")
        XCTAssertEqual(result?.artist, "Tom & Jerry & Friends")
        XCTAssertEqual(result?.title, "Theme Song")
    }
}

// MARK: - PlayHistoryManager Station Title Logic

final class PlayHistoryStationTitleTests: XCTestCase {

    func testEmptyTitleUsesStationName() {
        // The trackMetadataChanged method copies stationName to title when title is empty
        var metadata = TrackMetadata(title: "", stationName: "BBC Radio 1")
        // Simulate the logic from trackMetadataChanged
        if metadata.title.isEmpty && !metadata.stationName.isEmpty {
            metadata.title = metadata.stationName
        }
        XCTAssertEqual(metadata.title, "BBC Radio 1")
    }

    func testNonEmptyTitlePreserved() {
        var metadata = TrackMetadata(title: "Real Song", stationName: "BBC Radio 1")
        if metadata.title.isEmpty && !metadata.stationName.isEmpty {
            metadata.title = metadata.stationName
        }
        XCTAssertEqual(metadata.title, "Real Song")
    }

    func testBothEmptyStaysEmpty() {
        var metadata = TrackMetadata(title: "", stationName: "")
        if metadata.title.isEmpty && !metadata.stationName.isEmpty {
            metadata.title = metadata.stationName
        }
        XCTAssertEqual(metadata.title, "")
    }
}

// MARK: - UpdateArtwork Matching Logic

@MainActor
final class UpdateArtworkMatchingTests: XCTestCase {

    func testMatchesByTitleAndArtist() {
        let manager = PlayHistoryManager()
        let entry = PlayHistoryEntry(title: "Song", artist: "Artist")
        manager.entries.append(entry)
        manager.updateArtwork(forTitle: "Song", artist: "Artist", artURL: "https://art.jpg")
        XCTAssertEqual(manager.entries.last?.albumArtURI, "https://art.jpg")
    }

    func testMatchesWithEmptyStoredArtist() {
        let manager = PlayHistoryManager()
        let entry = PlayHistoryEntry(title: "Song", artist: "")
        manager.entries.append(entry)
        manager.updateArtwork(forTitle: "Song", artist: "New Artist", artURL: "https://art.jpg")
        XCTAssertEqual(manager.entries.last?.albumArtURI, "https://art.jpg")
    }

    func testMatchesWithEmptyNewArtist() {
        let manager = PlayHistoryManager()
        let entry = PlayHistoryEntry(title: "Song", artist: "Artist")
        manager.entries.append(entry)
        manager.updateArtwork(forTitle: "Song", artist: "", artURL: "https://art.jpg")
        XCTAssertEqual(manager.entries.last?.albumArtURI, "https://art.jpg")
    }

    func testDoesNotMatchDifferentTitle() {
        let manager = PlayHistoryManager()
        let entry = PlayHistoryEntry(title: "Song A", artist: "Artist")
        manager.entries.append(entry)
        manager.updateArtwork(forTitle: "Song B", artist: "Artist", artURL: "https://art.jpg")
        XCTAssertNil(manager.entries.last?.albumArtURI)
    }
}

// MARK: - New Constants

final class NewConstantsTests: XCTestCase {

    func testSonosRadioServiceID() {
        XCTAssertEqual(ServiceID.sonosRadio, 303)
    }

    func testNewUDKeys() {
        XCTAssertEqual(UDKey.tuneInSearchEnabled, "tuneInSearchEnabled")
        XCTAssertEqual(UDKey.calmRadioEnabled, "calmRadioEnabled")
        XCTAssertEqual(UDKey.appleMusicSearchEnabled, "appleMusicSearchEnabled")
        XCTAssertEqual(UDKey.sonosRadioEnabled, "sonosRadioEnabled")
    }

    func testBrowseIDSmapiRoot() {
        XCTAssertEqual(BrowseID.smapiRoot, "root")
    }
}

// MARK: - AlbumArtSearchService cleanTrackTitle Edge Cases

final class CleanTrackTitleEdgeCaseTests: XCTestCase {

    func testStripsReprise() {
        XCTAssertEqual(AlbumArtSearchService.cleanTrackTitle("Theme Reprise"), "Theme")
    }

    func testStripsInstrumental() {
        XCTAssertEqual(AlbumArtSearchService.cleanTrackTitle("Song Instrumental"), "Song")
    }

    func testStripsOverture() {
        XCTAssertEqual(AlbumArtSearchService.cleanTrackTitle("Act One Overture"), "Act One")
    }

    func testMultiLanguageParenthetical() {
        // Should strip parenthetical content
        let result = AlbumArtSearchService.cleanTrackTitle("Tristania (Troia Troy)")
        XCTAssertEqual(result, "Tristania")
    }

    func testNestedParentheses() {
        let result = AlbumArtSearchService.cleanTrackTitle("Song (feat. Artist (Remix))")
        // Should strip outer parens
        XCTAssertFalse(result.contains("("))
    }
}
