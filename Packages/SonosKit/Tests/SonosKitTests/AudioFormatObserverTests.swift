import XCTest
@testable import SonosKit

/// Covers the `HTAudioIn` → `TVAudioFormat` mapping table and the
/// observation store that records distinct formats for diagnostics
/// and future playback tags.
final class AudioFormatObserverTests: XCTestCase {

    // MARK: - Mapping table

    func testHTAudioInMapping() {
        // Locally-captured values plus the issue #80 table.
        let expected: [(Int, TVAudioFormat)] = [
            (0, .noSignal),
            (33554434, .stereoPCM),
            (84934658, .multichannelPCM51),
            (118489090, .multichannelPCM71),
            (84934713, .dolbyDigital51),
            (118489146, .dolbyDigitalPlus71),
            (63, .dolbyAtmos),
            (61, .dolbyAtmosTrueHD71),
            (84934721, .dtsSurround51),
        ]
        for (raw, format) in expected {
            XCTAssertEqual(TVAudioFormat.from(htAudioIn: raw), format,
                           "raw \(raw)")
        }
        XCTAssertEqual(TVAudioFormat.from(htAudioIn: 12345), .unknown)
    }

    // MARK: - Observation store

    private func makeObserver() -> (AudioFormatObserver, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("afo-test-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return (AudioFormatObserver(fileURL: url), url)
    }

    func testRepeatSightingsCollapseToOneObservation() {
        let (observer, _) = makeObserver()
        observer.recordHTAudioIn(63, mapped: .dolbyAtmos,
                                 room: "Lounge", model: "Sonos Arc")
        observer.recordHTAudioIn(63, mapped: .dolbyAtmos,
                                 room: "Lounge", model: "Sonos Arc")
        observer.recordHTAudioIn(63, mapped: .dolbyAtmos,
                                 room: "Den", model: "Sonos Beam")
        let snapshot = observer.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot[0].key, "ht:63")
        XCTAssertEqual(snapshot[0].count, 3)
        XCTAssertEqual(snapshot[0].rooms, ["Lounge", "Den"])
        XCTAssertEqual(snapshot[0].mapped, "dolbyAtmos")
    }

    func testUnmappedValueIsRecorded() {
        let (observer, _) = makeObserver()
        observer.recordHTAudioIn(99999, mapped: .unknown,
                                 room: "Lounge", model: "Sonos Arc")
        let snapshot = observer.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot[0].rawValue, "99999")
        XCTAssertEqual(snapshot[0].mapped, "unknown")
    }

    func testStreamAndHTKeysStayDistinct() {
        let (observer, _) = makeObserver()
        observer.recordHTAudioIn(63, mapped: .dolbyAtmos,
                                 room: "Lounge", model: "Sonos Arc")
        observer.recordStreamInfo("bd:24,sr:48000,c:8,l:1,d:1",
                                  mapped: .atmos, room: "Lounge")
        let keys = Set(observer.snapshot().map(\.key))
        XCTAssertEqual(keys, ["ht:63", "stream:bd:24,sr:48000,c:8,l:1,d:1"])
    }

    // MARK: - Track (normal audio) feed

    func testAudioExtensionExtraction() {
        XCTAssertEqual(AudioFormatObserver.audioExtension(
            of: "x-file-cifs://nas/music/Album/01%20Song.flac"), "flac")
        XCTAssertEqual(AudioFormatObserver.audioExtension(
            of: "x-sonos-http:song:123.mp4?sid=204&flags=8224"), "mp4")
        // Query stripped before extension parse.
        XCTAssertEqual(AudioFormatObserver.audioExtension(
            of: "http://host/stream.mp3?token=a.b.c"), "mp3")
        // Unknown extension rejected.
        XCTAssertNil(AudioFormatObserver.audioExtension(
            of: "http://host/playlist.m3u8"))
        XCTAssertNil(AudioFormatObserver.audioExtension(
            of: "x-sonosapi-stream:s12345"))
    }

    func testQueryValueExtraction() {
        XCTAssertEqual(AudioFormatObserver.queryValue(
            "sid", in: "x-sonos-http:song:1.mp4?sid=204&flags=8224&sn=3"), "204")
        XCTAssertNil(AudioFormatObserver.queryValue(
            "sid", in: "x-file-cifs://nas/music/song.flac"))
    }

    func testTrackFeedRecordsEvidenceKey() {
        let (observer, _) = makeObserver()
        observer.recordTrack(
            uri: "x-sonos-http:song:1.mp4?sid=204&flags=8224",
            streamInfo: "bd:24,sr:48000,c:2,l:1,d:0",
            audioFormat: .lossless, room: "Office")
        let snapshot = observer.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot[0].key,
                       "track:scheme:x-sonos-http|ext:mp4|sid:204|si:bd:24,sr:48000,c:2,l:1,d:0|fmt:lossless")
        XCTAssertEqual(snapshot[0].mapped, "lossless")
    }

    func testTrackFeedSkipsHomeTheaterSources() {
        let (observer, _) = makeObserver()
        observer.recordTrack(
            uri: "x-sonos-htastream:RINCON_1234:spdif",
            streamInfo: "", audioFormat: .unknown, room: "Lounge")
        observer.recordTrack(
            uri: "x-rincon-stream:RINCON_1234",
            streamInfo: "", audioFormat: .unknown, room: "Lounge")
        XCTAssertTrue(observer.snapshot().isEmpty)
    }

    func testTrackFeedSeparatesQualityTiers() {
        // Same service, same container — different streamInfo tiers
        // stay distinct observations (the "lossless vs hi-res" split).
        let (observer, _) = makeObserver()
        observer.recordTrack(
            uri: "x-sonos-http:song:1.mp4?sid=204",
            streamInfo: "bd:16,sr:44100,c:2,l:1,d:0",
            audioFormat: .lossless, room: "Office")
        observer.recordTrack(
            uri: "x-sonos-http:song:2.mp4?sid=204",
            streamInfo: "bd:24,sr:96000,c:2,l:1,d:0",
            audioFormat: .lossless, room: "Office")
        XCTAssertEqual(observer.snapshot().count, 2)
    }

    // MARK: - Now Playing stream-details pill

    func testQualityLabelFromStreamInfo() {
        XCTAssertEqual(TrackMetadata.qualityLabel(
            fromStreamInfo: "bd:16,sr:44100,c:2,l:1,d:0"), "16-bit/44.1 kHz")
        XCTAssertEqual(TrackMetadata.qualityLabel(
            fromStreamInfo: "bd:24,sr:96000,c:2,l:1,d:0"), "24-bit/96 kHz")
        XCTAssertEqual(TrackMetadata.qualityLabel(
            fromStreamInfo: "bd:24,sr:48000,c:6,l:0,d:1"), "24-bit/48 kHz · 5.1")
        // All-zero (not yet decoded) and absent yield nil.
        XCTAssertNil(TrackMetadata.qualityLabel(
            fromStreamInfo: "bd:0,sr:0,c:0,l:0,d:0"))
        XCTAssertNil(TrackMetadata.qualityLabel(fromStreamInfo: ""))
    }

    func testStreamDetailsLabelComposition() {
        var metadata = TrackMetadata(title: "Song")
        metadata.trackURI = "x-file-cifs://nas/music/song.flac"
        metadata.audioFormat = .lossless
        metadata.streamInfoRaw = "bd:24,sr:96000,c:2,l:1,d:0"
        XCTAssertEqual(metadata.streamDetailsLabel,
                       "FLAC · Lossless · 24-bit/96 kHz")
        // Extension only — no streamInfo, lossy.
        metadata = TrackMetadata(title: "Song")
        metadata.trackURI = "http://host/stream.mp3?token=x"
        XCTAssertEqual(metadata.streamDetailsLabel, "MP3")
        // No evidence at all — no pill.
        metadata = TrackMetadata(title: "Song")
        metadata.trackURI = "x-sonosapi-stream:s12345?sid=254"
        XCTAssertNil(metadata.streamDetailsLabel)
        // Home-theater source — TV pill owns it.
        metadata = TrackMetadata(title: "TV")
        metadata.trackURI = "x-sonos-htastream:RINCON_1:spdif"
        metadata.streamInfoRaw = "bd:24,sr:48000,c:6,l:0,d:1"
        XCTAssertNil(metadata.streamDetailsLabel)
        // Atmos stream: quality shows, "Lossless" word does not (the
        // separate Atmos badge names the format).
        metadata = TrackMetadata(title: "Song")
        metadata.trackURI = "x-sonos-http:song:1.mp4?sid=204"
        metadata.audioFormat = .atmos
        metadata.streamInfoRaw = "bd:16,sr:48000,c:11,l:0,d:1"
        XCTAssertEqual(metadata.streamDetailsLabel, "MP4 · 16-bit/48 kHz")
    }

    func testObservationsPersistAcrossInstances() {
        let (observer, url) = makeObserver()
        observer.recordHTAudioIn(61, mapped: .dolbyAtmosTrueHD71,
                                 room: "Lounge", model: "Sonos Arc")
        // snapshot() syncs the serial queue, so the new-key save has
        // completed by the time it returns.
        XCTAssertEqual(observer.snapshot().count, 1)
        let reloaded = AudioFormatObserver(fileURL: url)
        let snapshot = reloaded.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot[0].key, "ht:61")
        XCTAssertEqual(snapshot[0].mapped, "dolbyAtmosTrueHD71")
    }
}
