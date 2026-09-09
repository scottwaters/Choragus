import XCTest
@testable import SonosKit

/// Artwork precedence: previous-track art surviving a queue advance, a manual
/// override clobbered by radio auto-search, and Sonos's art proxy serving a
/// placeholder over a resolved iTunes result.
final class ArtDisplayDecisionTests: XCTestCase {

    private let pin = URL(string: "https://itunes.example/pinned.jpg")!
    private let station = URL(string: "https://radio.example/logo.png")!
    private let radioTrack = URL(string: "https://itunes.example/song.jpg")!
    private let previous = URL(string: "https://itunes.example/previous.jpg")!
    private let displayed = URL(string: "https://itunes.example/onscreen.jpg")!
    private let proxy = "http://192.168.1.10:1400/getaa?u=x&v=1"

    // MARK: - Absolutes

    func testIgnoredArtShowsNothing() {
        let url = ArtDisplayDecision.artURL(.init(
            isIgnored: true, isResolved: true, speakerArtURI: "https://a/b.jpg", pinnedURL: pin))
        XCTAssertNil(url)
    }

    /// An ad break must not show the previous song's cover — that reads as the
    /// song still playing.
    func testAdBreakShowsTheStationLogo() {
        let url = ArtDisplayDecision.artURL(.init(
            isAdBreak: true, stationName: "Radio X",
            pinnedURL: pin, stationArtURL: station, displayedArtURL: displayed))
        XCTAssertEqual(url, station)
    }

    // MARK: - Manual override

    /// Radio auto-search re-populates on every poll. Without this the user's
    /// chosen art is replaced seconds after they choose it.
    /// Set Artwork on a media-server track: the user's choice outranks
    /// the server's own cover.
    func testManualPinBeatsServerPublishedArt() {
        let published = URL(string: "http://nas:32469/art/1.jpg")!
        XCTAssertEqual(ArtDisplayDecision.artURL(.init(
            isResolved: true, pinnedURL: pin, serverPublishedArtURL: published)), pin)
        XCTAssertEqual(ArtDisplayDecision.artURL(.init(
            isResolved: false, pinnedURL: pin, serverPublishedArtURL: published)), pin)
    }

    func testServerPublishedArtWinsWithoutAPin() {
        let published = URL(string: "http://nas:32469/art/1.jpg")!
        let proxyPin = URL(string: "http://192.168.1.10:1400/getaa?u=x")!
        XCTAssertEqual(ArtDisplayDecision.artURL(.init(
            isResolved: true, speakerArtURI: "", serverPublishedArtURL: published)), published)
        XCTAssertEqual(ArtDisplayDecision.artURL(.init(
            isResolved: true, pinnedURL: proxyPin, serverPublishedArtURL: published)), published)
    }

    func testManualPinBeatsRadioAutoSearch() {
        let url = ArtDisplayDecision.artURL(.init(
            isResolved: true, stationName: "Radio X",
            pinnedURL: pin, radioTrackArtURL: radioTrack,
            radioTrackArtTitle: "Song", stationArtURL: station, title: "Song"))
        XCTAssertEqual(url, pin)
    }

    /// Sonos's proxy returns a generic placeholder for URLs it cannot fetch
    /// (Plex direct with a token, anything needing auth). A real pinned URL
    /// beats it even though the proxy URL is non-empty.
    func testPinBeatsTheArtProxyPlaceholder() {
        let url = ArtDisplayDecision.artURL(.init(
            isResolved: true, speakerArtURI: proxy, pinnedURL: pin))
        XCTAssertEqual(url, pin)
    }

    func testProxyArtIsKeptWhenThePinIsAlsoProxied() {
        let otherProxy = URL(string: "http://192.168.1.10:1400/getaa?u=y")!
        let url = ArtDisplayDecision.artURL(.init(
            isResolved: true, speakerArtURI: proxy, pinnedURL: otherProxy))
        XCTAssertEqual(url?.absoluteString, proxy)
    }

    // MARK: - Speaker art

    func testSpeakerArtIsTheSourceOfTruthWhenResolved() {
        let speaker = "https://cdn.example/album.jpg"
        let url = ArtDisplayDecision.artURL(.init(
            isResolved: true, speakerArtURI: speaker, displayedArtURL: displayed))
        XCTAssertEqual(url?.absoluteString, speaker)
    }

    /// A /getaa? pin held while the speaker reports no art is the previous
    /// track's URL, captured before Sonos refreshed; the decision falls through
    /// to the station logo.
    func testProxyPinIsDiscardedWhenTheSpeakerReportsNoArt() {
        let proxyPin = URL(string: proxy)!
        let url = ArtDisplayDecision.artURL(.init(
            isResolved: true, speakerArtURI: nil,
            pinnedURL: proxyPin, stationArtURL: station))
        XCTAssertEqual(url, station)
    }

    func testNonProxyPinSurvivesWhenTheSpeakerReportsNoArt() {
        // A real iTunes result for a track the speaker has no art for.
        let url = ArtDisplayDecision.artURL(.init(
            isResolved: true, speakerArtURI: "", pinnedURL: pin, stationArtURL: station))
        XCTAssertEqual(url, pin)
    }

    // MARK: - Radio

    func testRadioTrackArtIsUsedWhenTheTitleMatches() {
        let url = ArtDisplayDecision.artURL(.init(
            stationName: "Radio X", radioTrackArtURL: radioTrack,
            radioTrackArtTitle: "Song|Artist", stationArtURL: station, title: "Song"))
        XCTAssertEqual(url, radioTrack)
    }

    /// Radio metadata arrives in stages: the title lands first and the artist
    /// can finalise afterwards. Comparing artist too would reject correct art.
    func testRadioArtSurvivesTheArtistFillingInLater() {
        XCTAssertTrue(ArtDisplayDecision.radioArtMatches(.init(
            radioTrackArtTitle: "Song|", title: "Song")))
    }

    func testRadioArtIsRejectedForADifferentSong() {
        let url = ArtDisplayDecision.artURL(.init(
            stationName: "Radio X", radioTrackArtURL: radioTrack,
            radioTrackArtTitle: "Old Song", stationArtURL: station,
            displayedArtURL: displayed, title: "New Song"))
        XCTAssertEqual(url, displayed)
    }

    func testRadioArtWithoutAStoredTitleIsTrusted() {
        XCTAssertTrue(ArtDisplayDecision.radioArtMatches(.init(
            radioTrackArtTitle: nil, title: "Anything")))
    }

    func testTitleComparisonIsCaseInsensitive() {
        XCTAssertTrue(ArtDisplayDecision.radioArtMatches(.init(
            radioTrackArtTitle: "SONG", title: "song")))
    }

    /// While the new song's search is in flight, holding the previous song's
    /// art beats flashing the station logo for a second.
    func testGraceWindowHoldsThePreviousSongsArt() {
        let url = ArtDisplayDecision.artURL(.init(
            stationName: "Radio X", stationArtURL: station,
            heldPreviousRadioArtURL: previous, radioGraceActive: true, title: "New Song"))
        XCTAssertEqual(url, previous)
    }

    func testExpiredGraceWindowReleasesTheHeldArt() {
        let url = ArtDisplayDecision.artURL(.init(
            stationName: "Radio X", stationArtURL: station,
            heldPreviousRadioArtURL: previous, radioGraceActive: false, title: "New Song"))
        XCTAssertEqual(url, station)
    }

    // MARK: - Fallbacks

    func testFallsBackToWhatIsOnScreen() {
        let url = ArtDisplayDecision.artURL(.init(displayedArtURL: displayed))
        XCTAssertEqual(url, displayed)
    }

    func testNothingAvailableShowsNothing() {
        XCTAssertNil(ArtDisplayDecision.artURL(.init()))
    }

    func testEmptyTitleCannotMatchStoredRadioArt() {
        XCTAssertFalse(ArtDisplayDecision.radioArtMatches(.init(
            radioTrackArtTitle: "Song", title: "")))
    }
}
