import XCTest
@testable import SonosKit

/// Coverage for #78 — the Surrounds tab was hidden on systems that have
/// surrounds. The strings below are the four `HTSatChanMapSet` values a
/// live Arc + Sub + two surrounds zone publishes, one per bonded member.
final class HomeTheaterChannelMapTests: XCTestCase {

    private let soundbar = "RINCON_BAR:LF,RF;RINCON_SUB:SW;RINCON_LS:LR;RINCON_RS:RR"
    private let subView = "RINCON_BAR:LF,RF;RINCON_SUB:SW"
    private let leftView = "RINCON_BAR:LF,RF;RINCON_LS:LR"
    private let rightView = "RINCON_BAR:LF,RF;RINCON_RS:RR"

    func testMergeRecoversFullZoneFromPartialViews() {
        // Deliberately excludes the soundbar's complete view: the union of
        // the satellites' partial views must still describe the zone.
        let merged = HomeTheaterChannelMap.merge(
            memberMapSets: [subView, leftView, rightView])
        let channels = Set(merged.map(\.1))
        XCTAssertTrue(channels.contains(.sub))
        XCTAssertTrue(channels.contains(.rearLeft))
        XCTAssertTrue(channels.contains(.rearRight))
        XCTAssertTrue(channels.contains(.soundbar))
        XCTAssertEqual(merged.count, 4)
    }

    func testResultIsIndependentOfMemberOrdering() {
        // The pre-fix parser took the first non-empty entry, so the answer
        // depended on which member the topology happened to list first.
        let a = HomeTheaterChannelMap.merge(
            memberMapSets: [subView, soundbar, leftView, rightView])
        let b = HomeTheaterChannelMap.merge(
            memberMapSets: [rightView, leftView, soundbar, subView])
        XCTAssertEqual(a.map(\.0), b.map(\.0))
        XCTAssertEqual(a.map(\.1), b.map(\.1))
    }

    func testSubOnlyZoneReportsNoSurrounds() {
        // A genuine soundbar+sub zone must not gain phantom surrounds.
        let merged = HomeTheaterChannelMap.merge(memberMapSets: [subView, subView])
        let channels = Set(merged.map(\.1))
        XCTAssertEqual(channels, [.soundbar, .sub])
    }

    func testUnknownChannelTokensAreSkipped() {
        let merged = HomeTheaterChannelMap.merge(
            memberMapSets: ["RINCON_BAR:LF,RF;RINCON_X:WAT;RINCON_SUB:SW"])
        XCTAssertEqual(merged.count, 2)
        XCTAssertFalse(merged.contains { $0.0 == "RINCON_X" })
    }

    func testEmptyInputYieldsEmptyMap() {
        XCTAssertTrue(HomeTheaterChannelMap.merge(memberMapSets: ["", ""]).isEmpty)
    }

    func testLaterViewsDoNotDowngradeKnownChannels() {
        // Every view agrees about the soundbar; the merge must not let a
        // repeated entry change an already-resolved device's channel.
        let merged = HomeTheaterChannelMap.merge(
            memberMapSets: [soundbar, subView, leftView, rightView])
        let bar = merged.first { $0.0 == "RINCON_BAR" }
        XCTAssertEqual(bar?.1, .soundbar)
        XCTAssertEqual(merged.count, 4)
    }
}
