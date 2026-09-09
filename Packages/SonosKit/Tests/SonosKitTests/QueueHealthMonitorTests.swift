import XCTest
@testable import SonosKit

@MainActor
final class QueueHealthMonitorTests: XCTestCase {
    private func row(_ id: Int, _ uri: String?, _ title: String = "T") -> QueueHealthMonitor.Row {
        .init(id: id, uri: uri, title: title)
    }

    func testClassification() {
        let isMS: (String) -> Bool = { $0 == "192.168.0.9" }
        XCTAssertEqual(QueueHealthMonitor.kind(of: "x-file-cifs://nas/Music/a.flac", isMediaServerHost: isMS),
                       .cifs(host: "nas"))
        XCTAssertEqual(QueueHealthMonitor.kind(of: "http://192.168.0.9:50002/m/1.flac", isMediaServerHost: isMS),
                       .mediaServer(host: "192.168.0.9", port: 50002))
        XCTAssertEqual(QueueHealthMonitor.kind(of: "https://cdn.example.com/t.flac?token=x&Expires=99", isMediaServerHost: isMS),
                       .paidStreamingReadableExpiry)
        XCTAssertEqual(QueueHealthMonitor.kind(of: "https://cdn.example.com/t.flac?token=opaque", isMediaServerHost: isMS),
                       .paidStreamingOpaque)
        XCTAssertEqual(QueueHealthMonitor.kind(of: "x-sonos-http:song%3a1.mp4?sid=204", isMediaServerHost: isMS),
                       .notCheckable)
        XCTAssertEqual(QueueHealthMonitor.kind(of: "http://icecast.example.com/stream", isMediaServerHost: isMS),
                       .notCheckable)
    }

    /// Steady state: everything cached → a second pass makes zero probes.
    func testCooldownAndCacheStopRepeatProbes() async {
        nonisolated(unsafe) var probeCount = 0
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let monitor = QueueHealthMonitor(
            config: { var c = QueueHealthMonitor.Config(); c.debounce = 0; return c }(),
            probe: { _ in probeCount += 1; return 200 },
            hostAlive: { _, _ in true },
            now: { clock })
        let rows = [row(2, "https://cdn.example.com/a.flac?token=opaque")]
        var got: [Int: QueueHealthMonitor.Verdict]?

        monitor.noteTrackChanged(groupID: "g", rows: rows, currentTrack: 1,
                                 isMediaServerHost: { _ in false }) { got = $0 }
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(got, [:])   // healthy → no flags

        // Ten seconds later: cooldown blocks the probe tier entirely.
        clock = clock.addingTimeInterval(10)
        monitor.noteTrackChanged(groupID: "g", rows: rows, currentTrack: 1,
                                 isMediaServerHost: { _ in false }) { got = $0 }
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(probeCount, 1)
    }

    /// A dead NAS host verdicts every row it serves with one TCP touch.
    func testDeadHostShortCircuitsRows() async {
        nonisolated(unsafe) var touches = 0
        let monitor = QueueHealthMonitor(
            config: { var c = QueueHealthMonitor.Config(); c.debounce = 0; return c }(),
            probe: { _ in XCTFail("no HEAD should run"); return nil },
            hostAlive: { _, _ in touches += 1; return false },
            now: { Date(timeIntervalSince1970: 1_800_000_000) })
        let rows = [row(2, "x-file-cifs://nas/Music/a.flac"),
                    row(3, "x-file-cifs://nas/Music/b.flac")]
        var got: [Int: QueueHealthMonitor.Verdict]?
        monitor.noteTrackChanged(groupID: "g", rows: rows, currentTrack: 1,
                                 isMediaServerHost: { _ in false }) { got = $0 }
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(touches, 1)
        XCTAssertEqual(got, [2: .dead, 3: .dead])
    }

    /// Expired rows are flagged offline even while the cooldown blocks probes.
    func testExpiredFlagsIgnoreCooldown() async {
        let monitor = QueueHealthMonitor(
            config: { var c = QueueHealthMonitor.Config(); c.debounce = 0; return c }(),
            probe: { _ in 200 }, hostAlive: { _, _ in true },
            now: { Date(timeIntervalSince1970: 1_800_000_000) })
        let expired = "https://cdn.example.com/t.flac?token=x&Expires=1000000000"
        var got: [Int: QueueHealthMonitor.Verdict]?
        monitor.noteTrackChanged(groupID: "g", rows: [row(7, expired)], currentTrack: 20,
                                 isMediaServerHost: { _ in false }) { got = $0 }
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(got, [7: .expired])   // outside window, still flagged
    }

    /// Only rows in the window after the playhead are probed.
    func testWindowLimitsProbes() async {
        nonisolated(unsafe) var probed: [String] = []
        let monitor = QueueHealthMonitor(
            config: { var c = QueueHealthMonitor.Config(); c.debounce = 0; c.window = 2; return c }(),
            probe: { url in probed.append(url.absoluteString); return 200 },
            hostAlive: { _, _ in true },
            now: { Date(timeIntervalSince1970: 1_800_000_000) })
        let rows = (1...6).map { row($0, "https://cdn.example.com/\($0).flac?token=o\($0)") }
        monitor.noteTrackChanged(groupID: "g", rows: rows, currentTrack: 2,
                                 isMediaServerHost: { _ in false }) { _ in }
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(probed.count, 2)   // rows 3 and 4 only
    }
}
