/// QueueHealthScanner.swift — Which queue rows will not play, without
/// playing them.
///
/// A queue rots in ways the speaker never reports: signed CDN URLs expire,
/// a media server goes away, a row is enqueued with no metadata. All three
/// are detectable up front — expiry from the URL itself, liveness with one
/// HEAD request, and missing metadata from the title. Speaker-resolved
/// service URIs (`x-sonos-http:`, `x-file-cifs:`) are deliberately reported
/// as fine: the speaker re-resolves those at play time and the Mac has no
/// equivalent vantage point, so claiming otherwise would be a guess.
import Foundation

public enum QueueHealthScanner {

    public enum Verdict: Equatable, Sendable {
        /// Nothing wrong, or nothing checkable — no badge either way.
        case ok
        /// The URL states an expiry and it has passed.
        case expired
        /// The host answered and refused, or never answered.
        case dead
        /// The row plays but carries no usable metadata (filename title).
        case missingMetadata
    }

    public struct RowResult: Sendable, Equatable {
        public let id: Int
        public let verdict: Verdict
    }

    /// What can be judged without any network traffic.
    /// Returns nil when only a probe can decide.
    static func offlineVerdict(uri: String?, title: String) -> Verdict? {
        guard let uri, !uri.isEmpty else { return .ok }
        if StaleTrackURL.isDirectStream(uri) {
            if StaleTrackURL.isExpired(uri) { return .expired }
            return nil   // probe decides
        }
        // Speaker-resolved URI: playable as far as this scan can know, but a
        // filename-for-title row was enqueued without metadata and is worth
        // flagging on any scheme.
        return TrackMetadata.isTechnicalName(title) ? .missingMetadata : .ok
    }

    /// Scans every row. `probe` returns the HTTP status for a URL, nil when
    /// the host never answered; injected so the logic is testable without a
    /// network. Probes run concurrently; verdict order matches input order.
    public static func scan(rows: [(id: Int, uri: String?, title: String)],
                            probe: @escaping @Sendable (URL) async -> Int?,
                            onProgress: (@Sendable (Int, Int) -> Void)? = nil) async -> [RowResult] {
        var results: [Int: Verdict] = [:]
        var pending: [(Int, URL, String)] = []
        for row in rows {
            if let verdict = offlineVerdict(uri: row.uri, title: row.title) {
                results[row.id] = verdict
            } else if let uri = row.uri, let url = URL(string: uri) {
                pending.append((row.id, url, row.title))
            } else {
                results[row.id] = .ok
            }
        }
        let total = pending.count
        var done = 0
        await withTaskGroup(of: (Int, Verdict).self) { group in
            for (id, url, title) in pending {
                group.addTask {
                    guard let status = await probe(url) else { return (id, .dead) }
                    if (200...399).contains(status) {
                        return (id, TrackMetadata.isTechnicalName(title) ? .missingMetadata : .ok)
                    }
                    return (id, .dead)
                }
            }
            for await (id, verdict) in group {
                results[id] = verdict
                done += 1
                onProgress?(done, total)
            }
        }
        return rows.map { RowResult(id: $0.id, verdict: results[$0.id] ?? .ok) }
    }

    /// Default probe: HEAD, falling back to a one-byte ranged GET for hosts
    /// that reject HEAD (some CDNs 403 it while GET works).
    public static func httpProbe(_ url: URL) async -> Int? {
        var head = URLRequest(url: url)
        head.httpMethod = "HEAD"
        head.timeoutInterval = 6
        if let (_, response) = try? await URLSession.shared.data(for: head),
           let status = (response as? HTTPURLResponse)?.statusCode {
            if status == 403 || status == 405 {
                var get = URLRequest(url: url)
                get.setValue("bytes=0-0", forHTTPHeaderField: "Range")
                get.timeoutInterval = 6
                if let (_, r2) = try? await URLSession.shared.data(for: get),
                   let s2 = (r2 as? HTTPURLResponse)?.statusCode {
                    return s2
                }
            }
            return status
        }
        return nil
    }
}
