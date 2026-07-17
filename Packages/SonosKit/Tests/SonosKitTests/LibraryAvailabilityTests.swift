import XCTest
@testable import SonosKit

/// Per-household local-library availability — the pure share-matching and
/// generation-tag logic behind the (S1/S2) browse tags and the fail-fast
/// playback gate.
final class LibraryAvailabilityTests: XCTestCase {

    // Normalised (lower-cased) share roots, as stored in HouseholdCapabilities.
    private let shareX = "s://serverx/sharex"      // S1-only
    private let shareC = "s://serverc/sharec"      // on both S1 and S2

    // MARK: normalizedShareKey

    func testNormalizeLowercases() {
        XCTAssertEqual(SonosManager.normalizedShareKey("S://Server/Share"), "s://server/share")
    }

    // MARK: localLibraryPlayable(objectID:shareIDs:)

    func testShareRootExactMatchPlayable() {
        XCTAssertEqual(SonosManager.localLibraryPlayable(objectID: "S://ServerX/ShareX", shareIDs: [shareX]), true)
    }

    func testChildTrackUnderShareIsPlayable() {
        // A track deep inside a configured share matches its share root.
        let oid = "S://ServerX/ShareX/Music/Abba/Chiquitita.mp3"
        XCTAssertEqual(SonosManager.localLibraryPlayable(objectID: oid, shareIDs: [shareX]), true)
    }

    func testShareNotConfiguredIsNotPlayable() {
        // shareX track played against an S2 system that only has shareC.
        let oid = "S://ServerX/ShareX/Music/Abba/Chiquitita.mp3"
        XCTAssertEqual(SonosManager.localLibraryPlayable(objectID: oid, shareIDs: [shareC]), false)
    }

    func testPrefixIsBoundedToPathSeparator() {
        // "s://serverx/sharextra" must NOT match the "s://serverx/sharex" root.
        let oid = "S://ServerX/ShareXtra/file.mp3"
        XCTAssertEqual(SonosManager.localLibraryPlayable(objectID: oid, shareIDs: [shareX]), false)
    }

    func testAggregatedIndexNeedsAnyLibrary() {
        // A: items are the merged index — playable iff the system has any share.
        XCTAssertEqual(SonosManager.localLibraryPlayable(objectID: "A:ALBUMARTIST/Abba", shareIDs: [shareC]), true)
        XCTAssertEqual(SonosManager.localLibraryPlayable(objectID: "A:TRACKS", shareIDs: []), false)
    }

    func testNonLocalItemReturnsNil() {
        XCTAssertNil(SonosManager.localLibraryPlayable(objectID: "FV:2/118", shareIDs: [shareC]))
        XCTAssertNil(SonosManager.localLibraryPlayable(objectID: "x-sonos-spotify:track", shareIDs: [shareC]))
    }

    // MARK: availabilityTag(for:)

    func testTagSingleGeneration() {
        XCTAssertEqual(SonosManager.availabilityTag(for: [.s1]), "(S1)")
        XCTAssertEqual(SonosManager.availabilityTag(for: [.s2]), "(S2)")
    }

    func testTagBothGenerationsOrderedAndDeduped() {
        XCTAssertEqual(SonosManager.availabilityTag(for: [.s2, .s1, .s1]), "(S1/S2)")
    }

    func testTagDropsUnknownAndEmpty() {
        XCTAssertNil(SonosManager.availabilityTag(for: [.unknown]))
        XCTAssertNil(SonosManager.availabilityTag(for: []))
    }

    // MARK: reported scenario — S1={shareX, shareC}, S2={shareC}

    func testReportedMultiShareScenario() {
        let s1: Set<String> = [shareX, shareC]
        let s2: Set<String> = [shareC]
        let trackUnderX = "S://ServerX/ShareX/Music/track.mp3"
        let trackUnderC = "S://ServerC/ShareC/Music/track.mp3"

        // shareX track: plays on S1, blocked on S2.
        XCTAssertEqual(SonosManager.localLibraryPlayable(objectID: trackUnderX, shareIDs: s1), true)
        XCTAssertEqual(SonosManager.localLibraryPlayable(objectID: trackUnderX, shareIDs: s2), false)
        // shareC track: plays on both.
        XCTAssertEqual(SonosManager.localLibraryPlayable(objectID: trackUnderC, shareIDs: s1), true)
        XCTAssertEqual(SonosManager.localLibraryPlayable(objectID: trackUnderC, shareIDs: s2), true)

        // Row tags: shareX → (S1); shareC → (S1/S2).
        XCTAssertEqual(SonosManager.availabilityTag(for: [.s1]), "(S1)")
        XCTAssertEqual(SonosManager.availabilityTag(for: [.s1, .s2]), "(S1/S2)")
    }

    // MARK: error copy

    func testLibraryNotConfiguredMessageNamesGeneration() {
        XCTAssertTrue(StaleDataError.libraryNotConfigured(.s1).errorDescription?.contains("S1") ?? false)
        XCTAssertTrue(StaleDataError.libraryNotConfigured(.s2).errorDescription?.contains("S2") ?? false)
    }

    /// Issue #72: Play/Pause on an empty transport must name the situation,
    /// not claim a layout change or an unexpected error.
    func testNothingLoadedMessageNamesSituation() {
        XCTAssertEqual(StaleDataError.nothingLoaded.errorDescription,
                       "Nothing is loaded on this speaker. Choose something to play.")
    }
}
