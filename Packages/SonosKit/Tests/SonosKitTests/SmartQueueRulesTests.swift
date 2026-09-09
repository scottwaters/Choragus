import XCTest
@testable import SonosKit

/// Smart queue construction from play history.
final class SmartQueueRulesTests: XCTestCase {

    private struct Entry {
        let title: String
        let artist: String
        let uri: String?
        let at: Date
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * 24 * 3600) }

    private func rank(_ entries: [Entry]) -> [Entry] {
        SmartQueueRules.rankByPlayCount(entries, now: now,
                                        timestamp: \.at, title: \.title, artist: \.artist)
    }

    private func distinct(_ entries: [Entry], limit: Int = 100) -> [Entry] {
        SmartQueueRules.distinct(entries, limit: limit,
                                 uri: \.uri, title: \.title, artist: \.artist)
    }

    // MARK: - Room scoping

    /// A song played while Office and Float were grouped was played in the
    /// Office. String equality would hide every grouped listen.
    func testRoomMatchesInsideAGrouping() {
        XCTAssertTrue(SmartQueueRules.entryMatchesRoom(groupName: "Office + Float", room: "Office"))
    }

    func testGroupSelectionRequiresEveryRoom() {
        XCTAssertTrue(SmartQueueRules.entryMatchesRoom(groupName: "Office + Float + Kitchen",
                                                       room: "Office + Kitchen"))
        XCTAssertFalse(SmartQueueRules.entryMatchesRoom(groupName: "Office + Float",
                                                        room: "Office + Kitchen"))
    }

    func testNoRoomSelectionMatchesEverything() {
        XCTAssertTrue(SmartQueueRules.entryMatchesRoom(groupName: "Office", room: nil))
        XCTAssertTrue(SmartQueueRules.entryMatchesRoom(groupName: "Office", room: ""))
    }

    func testUnrelatedRoomDoesNotMatch() {
        XCTAssertFalse(SmartQueueRules.entryMatchesRoom(groupName: "Kitchen", room: "Office"))
    }

    // MARK: - Distinctness

    /// The same song from two services is one song. Keying on URI would list
    /// it twice, and a rotated service token would list it twice again.
    func testSameSongFromDifferentSourcesAppearsOnce() {
        let entries = [
            Entry(title: "Song", artist: "Artist", uri: "x-sonos-http:a", at: now),
            Entry(title: "Song", artist: "Artist", uri: "https://cdn/b.flac?token=1", at: now),
        ]
        XCTAssertEqual(distinct(entries).count, 1)
    }

    func testDistinctnessIsCaseInsensitive() {
        let entries = [
            Entry(title: "Song", artist: "Artist", uri: "a", at: now),
            Entry(title: "SONG", artist: "ARTIST", uri: "b", at: now),
        ]
        XCTAssertEqual(distinct(entries).count, 1)
    }

    func testSameTitleByDifferentArtistsAreBothKept() {
        let entries = [
            Entry(title: "Theme", artist: "Composer A", uri: "a", at: now),
            Entry(title: "Theme", artist: "Composer B", uri: "b", at: now),
        ]
        XCTAssertEqual(distinct(entries).count, 2)
    }

    func testUnplayableAndUntitledEntriesAreSkipped() {
        let entries = [
            Entry(title: "No URI", artist: "A", uri: nil, at: now),
            Entry(title: "Empty URI", artist: "A", uri: "", at: now),
            Entry(title: "", artist: "A", uri: "a", at: now),
            Entry(title: "Good", artist: "A", uri: "b", at: now),
        ]
        XCTAssertEqual(distinct(entries).map(\.title), ["Good"])
    }

    func testLimitIsHonoured() {
        let entries = (1...10).map { Entry(title: "S\($0)", artist: "A", uri: "u\($0)", at: now) }
        XCTAssertEqual(distinct(entries, limit: 3).count, 3)
    }

    // MARK: - Most played

    func testRanksByPlayCount() {
        let entries = [
            Entry(title: "Twice", artist: "A", uri: "a", at: ago(1)),
            Entry(title: "Once", artist: "A", uri: "b", at: ago(1)),
            Entry(title: "Twice", artist: "A", uri: "a", at: ago(2)),
            Entry(title: "Thrice", artist: "A", uri: "c", at: ago(3)),
            Entry(title: "Thrice", artist: "A", uri: "c", at: ago(4)),
            Entry(title: "Thrice", artist: "A", uri: "c", at: ago(5)),
        ]
        XCTAssertEqual(rank(entries).map(\.title), ["Thrice", "Twice", "Once"])
    }

    func testPlaysOlderThanThirtyDaysAreExcluded() {
        let entries = [
            Entry(title: "Old favourite", artist: "A", uri: "a", at: ago(40)),
            Entry(title: "Old favourite", artist: "A", uri: "a", at: ago(35)),
            Entry(title: "Current", artist: "A", uri: "b", at: ago(2)),
        ]
        XCTAssertEqual(rank(entries).map(\.title), ["Current"])
    }

    func testTheWindowBoundaryIsInclusive() {
        let entries = [Entry(title: "Edge", artist: "A", uri: "a",
                             at: now.addingTimeInterval(-SmartQueueRules.mostPlayedWindow))]
        XCTAssertEqual(rank(entries).count, 1)
    }

    /// Equal counts must not depend on dictionary ordering, or the same
    /// history produces a different queue on each launch.
    func testTiesKeepFirstSeenOrder() {
        let entries = [
            Entry(title: "First", artist: "A", uri: "a", at: ago(1)),
            Entry(title: "Second", artist: "A", uri: "b", at: ago(2)),
            Entry(title: "Third", artist: "A", uri: "c", at: ago(3)),
        ]
        XCTAssertEqual(rank(entries).map(\.title), ["First", "Second", "Third"])
        XCTAssertEqual(rank(entries).map(\.title), ["First", "Second", "Third"])
    }

    func testUntitledEntriesAreNotCounted() {
        let entries = [
            Entry(title: "", artist: "A", uri: "a", at: ago(1)),
            Entry(title: "Real", artist: "A", uri: "b", at: ago(1)),
        ]
        XCTAssertEqual(rank(entries).map(\.title), ["Real"])
    }

    func testEmptyHistoryProducesNothing() {
        XCTAssertTrue(rank([]).isEmpty)
        XCTAssertTrue(distinct([]).isEmpty)
    }

    /// A 13k-row history with ~2k distinct songs ranked in well under a
    /// second. The comparator once searched the first-seen array per
    /// comparison and took ~700 ms at this size.
    func testRankByPlayCountScalesToLargeHistory() {
        var entries: [Entry] = []
        for i in 0..<13_000 {
            entries.append(Entry(title: "Song \(i % 2_000)", artist: "Artist \(i % 2_000 % 97)",
                                 uri: "x-file-cifs://a/\(i)", at: now.addingTimeInterval(-Double(i % 2_000_000))))
        }
        let start = Date()
        let ranked = rank(entries)
        XCTAssertEqual(ranked.count, 2_000)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }
}
