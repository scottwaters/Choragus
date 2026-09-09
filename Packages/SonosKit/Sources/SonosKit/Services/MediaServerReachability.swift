/// MediaServerReachability.swift — Which speakers can fetch from a media
/// server.
///
/// Three failures present identically at the protocol layer — transport
/// STOPPED, status OK, no fault: a VLAN the speaker cannot route to, a server
/// bound to the wrong interface, and a firewall that permits one speaker but
/// not another. Nothing distinguishes them per speaker except making the
/// speaker itself fetch something.
///
/// The probe: the speaker's `/getaa?u=` proxy fetches an arbitrary URL and
/// returns 200 only when it retrieved the file AND extracted embedded art.
/// With a reference track known to carry embedded art, per-speaker semantics
/// are:
///   - 200            → the speaker reached the server.
///   - 404 after ~5 s → connect timeout inside the speaker; unreachable.
///   - fast 404       → ambiguous (firewall reject or proxy refusal).
/// No transport action is sent, so playback anywhere is never disturbed.
import Foundation

public enum MediaServerReachability {

    public enum State: String, Sendable {
        case reachable
        case unreachable
        /// The SPEAKER did not answer the probe — unplugged, asleep, or off
        /// the network. Says nothing about the server; reported separately
        /// because "Play:5 can't reach the server" while the Play:5 is
        /// unplugged blames the wrong thing.
        case speakerOffline
        case unknown
    }

    public struct SpeakerVerdict: Identifiable, Sendable {
        public let deviceID: String
        public let roomName: String
        public let state: State
        public var id: String { deviceID }
    }

    /// Elapsed time above which a 404 is read as a connect timeout rather
    /// than a refusal. Refusals answer in under 0.2 s, timeouts at five;
    /// the midpoint tolerates jitter on both sides.
    static let timeoutThreshold: TimeInterval = 2.5

    static func classify(status: Int, elapsed: TimeInterval) -> State {
        if status == 200 { return .reachable }
        // Status 0 means no HTTP response at all: the speaker itself did not
        // answer, so no verdict about the server is possible.
        if status == 0 { return .speakerOffline }
        return elapsed >= timeoutThreshold ? .unreachable : .unknown
    }

    /// A track on the server whose embedded art makes the probe conclusive:
    /// the first one that any single speaker returns 200 for. Walks the
    /// server's tree shallowly; a server with no tagged files yields nil and
    /// the caller reports `.unknown` rather than guessing.
    public static func referenceTrackURL(server: MediaServer,
                                         viaSpeaker speakerIP: String) async -> URL? {
        var queue = ["0"]
        var visited = 0
        var candidates: [String] = []
        while !queue.isEmpty, visited < 6, candidates.count < 12 {
            let objectID = queue.removeFirst()
            visited += 1
            guard let entries = try? await MediaServerService.browse(
                server: server, objectID: objectID, start: 0, count: 30) else { continue }
            for entry in entries {
                if entry.isContainer {
                    if queue.count < 12 { queue.append(entry.objectID) }
                } else if let uri = entry.resourceURI {
                    candidates.append(uri)
                }
            }
        }
        for uri in candidates.prefix(8) {
            let (status, elapsed) = await probe(speakerIP: speakerIP, trackURL: uri)
            if classify(status: status, elapsed: elapsed) == .reachable {
                return URL(string: uri)
            }
        }
        return nil
    }

    /// One speaker fetching one URL through its own art proxy.
    static func probe(speakerIP: String, trackURL: String) async -> (status: Int, elapsed: TimeInterval) {
        let encoded = trackURL.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? trackURL
        guard let url = URL(string: "http://\(speakerIP):1400/getaa?u=\(encoded)") else {
            return (0, 0)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        let started = Date()
        guard let (_, response) = try? await URLSession.shared.data(for: request) else {
            return (0, Date().timeIntervalSince(started))
        }
        return ((response as? HTTPURLResponse)?.statusCode ?? 0,
                Date().timeIntervalSince(started))
    }

    /// Every speaker probed in parallel against the reference track.
    /// `onProgress` reports completed-count for the "n of m" line.
    public struct Result: Sendable {
        public let verdicts: [SpeakerVerdict]
        /// host:port the probes fetched from — the MEDIA port, which
        /// is what a firewall rule has to name. The control port on the
        /// device description is usually a different one.
        public let probedTarget: String?
    }

    public static func verify(server: MediaServer,
                              devices: [(id: String, name: String, ip: String)],
                              onProgress: (@Sendable (Int, Int) -> Void)? = nil) async -> Result {
        // Any one speaker that can reach the server yields the reference;
        // the first device may be the one that cannot.
        var found: URL?
        for device in devices {
            found = await referenceTrackURL(server: server, viaSpeaker: device.ip)
            if found != nil { break }
        }
        guard let reference = found else {
            return Result(verdicts: devices.map {
                SpeakerVerdict(deviceID: $0.id, roomName: $0.name, state: .unknown)
            }, probedTarget: nil)
        }
        var verdicts: [SpeakerVerdict] = []
        var done = 0
        let total = devices.count
        await withTaskGroup(of: SpeakerVerdict.self) { group in
            for device in devices {
                group.addTask {
                    let (status, elapsed) = await probe(speakerIP: device.ip,
                                                        trackURL: reference.absoluteString)
                    return SpeakerVerdict(deviceID: device.id, roomName: device.name,
                                          state: classify(status: status, elapsed: elapsed))
                }
            }
            for await verdict in group {
                verdicts.append(verdict)
                done += 1
                onProgress?(done, total)
            }
        }
        let target = (reference.host ?? "") + ":" + String(reference.port ?? 80)
        return Result(verdicts: verdicts.sorted { $0.roomName < $1.roomName },
                      probedTarget: target)
    }
}
