import XCTest
@testable import SonosKit

/// Queue export to CSV and extended M3U. The files are opened in spreadsheets
/// and other players, so escaping errors surface outside the app.
@MainActor
final class ExportTracksTests: XCTestCase {

    private func track(_ id: Int, title: String, artist: String = "Artist",
                       album: String = "Album", uri: String? = "x-file-cifs://nas/t.flac") -> QueueItem {
        QueueItem(id: id, title: title, artist: artist, album: album, uri: uri)
    }

    // MARK: - CSV

    func testCSVHasAHeaderAndOneRowPerTrack() {
        let csv = SonosManager.exportTracks(
            [track(1, title: "One"), track(2, title: "Two")], asCSV: true)
        let lines = csv.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "Title,Artist,Album,URI")
        XCTAssertEqual(lines.count, 3)
    }

    /// A quote inside a field must be doubled, per RFC 4180. Getting this
    /// wrong shifts every later column in the spreadsheet.
    func testQuotesInFieldsAreDoubled() {
        let csv = SonosManager.exportTracks(
            [track(1, title: "The \"Best\" Song")], asCSV: true)
        XCTAssertTrue(csv.contains("\"The \"\"Best\"\" Song\""), csv)
    }

    /// Every field is quoted so an embedded comma does not split columns.
    func testCommasInFieldsDoNotSplitColumns() {
        let csv = SonosManager.exportTracks(
            [track(1, title: "Sing, Sing, Sing", artist: "Goodman, Benny")], asCSV: true)
        let row = csv.components(separatedBy: "\n")[1]
        XCTAssertEqual(row, "\"Sing, Sing, Sing\",\"Goodman, Benny\",\"Album\",\"x-file-cifs://nas/t.flac\"")
    }

    func testMissingURIBecomesAnEmptyQuotedField() {
        let csv = SonosManager.exportTracks([track(1, title: "No URI", uri: nil)], asCSV: true)
        XCTAssertTrue(csv.hasSuffix(",\"\""), csv)
    }

    func testEmptyTrackListStillProducesAHeader() {
        XCTAssertEqual(SonosManager.exportTracks([], asCSV: true), "Title,Artist,Album,URI")
    }

    // MARK: - M3U

    func testM3UStartsWithTheExtendedHeader() {
        let m3u = SonosManager.exportTracks([track(1, title: "One")], asCSV: false)
        XCTAssertTrue(m3u.hasPrefix("#EXTM3U\n"), m3u)
    }

    func testM3UPairsAnInfoLineWithEachURI() {
        let m3u = SonosManager.exportTracks(
            [track(1, title: "One", artist: "A"), track(2, title: "Two", artist: "B")],
            asCSV: false)
        let lines = m3u.components(separatedBy: "\n")
        XCTAssertEqual(lines, ["#EXTM3U",
                               "#EXTINF:-1,A - One", "x-file-cifs://nas/t.flac",
                               "#EXTINF:-1,B - Two", "x-file-cifs://nas/t.flac"])
    }

    /// Duration is unknown at export time; -1 is the M3U convention for that
    /// and players treat it as "read the file to find out".
    func testUnknownDurationIsWrittenAsMinusOne() {
        let m3u = SonosManager.exportTracks([track(1, title: "One")], asCSV: false)
        XCTAssertTrue(m3u.contains("#EXTINF:-1,"), m3u)
    }

    func testEmptyTrackListStillProducesTheM3UHeader() {
        XCTAssertEqual(SonosManager.exportTracks([], asCSV: false), "#EXTM3U")
    }

    func testTracksWithoutAURIStillEmitTheirInfoLine() {
        // The row is preserved so the export matches the queue the user saw,
        // even though that entry will not play when re-imported.
        let m3u = SonosManager.exportTracks([track(1, title: "Gone", uri: nil)], asCSV: false)
        XCTAssertEqual(m3u.components(separatedBy: "\n"), ["#EXTM3U", "#EXTINF:-1,Artist - Gone", ""])
    }
}
