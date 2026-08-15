import XCTest
@testable import SonosKit

/// Covers the per-URI format-evidence memory that heals the
/// bogus-publish flip-back (track returns as a "new" track with
/// `.unknown` and no streamInfo rebroadcast coming).
final class AudioFormatMemoryTests: XCTestCase {

    func testRecallAfterFlipBack() {
        var memory = AudioFormatMemory()
        memory.remember(group: "g1", uri: "x-sonosapi-hls-static:song%3a1?sid=204",
                        format: .atmos, streamInfo: "bd:16,sr:48000,c:11,l:0,d:1")
        // Interloper track publishes in between.
        memory.remember(group: "g1", uri: "x-sonos-http:song%3a2.unknown?sid=204",
                        format: .stereo, streamInfo: "")
        let recalled = memory.recall(group: "g1",
                                     uri: "x-sonosapi-hls-static:song%3a1?sid=204")
        XCTAssertEqual(recalled?.format, .atmos)
        XCTAssertEqual(recalled?.streamInfo, "bd:16,sr:48000,c:11,l:0,d:1")
    }

    func testUnknownIsNeverRemembered() {
        var memory = AudioFormatMemory()
        memory.remember(group: "g1", uri: "uri1", format: .lossless,
                        streamInfo: "bd:24,sr:96000,c:2,l:1,d:0")
        // A later unknown publish for the same URI must not clobber
        // the real evidence.
        memory.remember(group: "g1", uri: "uri1", format: .unknown, streamInfo: "")
        XCTAssertEqual(memory.recall(group: "g1", uri: "uri1")?.format, .lossless)
    }

    func testGroupsAreIsolated() {
        var memory = AudioFormatMemory()
        memory.remember(group: "g1", uri: "uri1", format: .atmos, streamInfo: "si")
        XCTAssertNil(memory.recall(group: "g2", uri: "uri1"))
    }

    func testCapEvictsOldestPerGroup() {
        var memory = AudioFormatMemory()
        for i in 0..<12 {
            memory.remember(group: "g1", uri: "uri\(i)", format: .stereo,
                            streamInfo: "")
        }
        XCTAssertNil(memory.recall(group: "g1", uri: "uri0"))
        XCTAssertNotNil(memory.recall(group: "g1", uri: "uri11"))
    }

    func testReRememberMovesURIToFreshest() {
        var memory = AudioFormatMemory()
        memory.remember(group: "g1", uri: "keep", format: .lossless, streamInfo: "si")
        for i in 0..<7 {
            memory.remember(group: "g1", uri: "uri\(i)", format: .stereo,
                            streamInfo: "")
        }
        // Re-remembering "keep" moves it to the fresh end, so the next
        // insert evicts an older URI instead.
        memory.remember(group: "g1", uri: "keep", format: .lossless, streamInfo: "si")
        memory.remember(group: "g1", uri: "new", format: .stereo, streamInfo: "")
        XCTAssertNotNil(memory.recall(group: "g1", uri: "keep"))
        XCTAssertNil(memory.recall(group: "g1", uri: "uri0"))
    }
}
