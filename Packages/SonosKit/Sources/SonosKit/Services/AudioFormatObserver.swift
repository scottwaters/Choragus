/// AudioFormatObserver.swift — Records every distinct audio encoding
/// format the fleet reports. Two consumers:
///
/// 1. Diagnostics: the first sighting of a format per launch writes an
///    `AUDIO_FORMAT` line carrying the raw wire value — for HDMI input
///    that is the undocumented `HTAudioIn` integer, so bug bundles
///    contain exactly the evidence needed to extend `TVAudioFormat`'s
///    mapping (issue #80's table arrived as such a capture).
/// 2. A persisted observation table (JSON in app support) accumulating
///    each distinct format with the rooms it appeared in, first/last
///    seen timestamps, and a sighting count — the data source for
///    surfacing formats as playback tags.
///
/// Recording is fire-and-forget from the transport hot path: callers
/// hand over the raw value and the serial queue does dedup, logging,
/// and persistence off-thread.
import Foundation

public struct AudioFormatObservation: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        /// HDMI ARC / eARC / optical input format from
        /// `DeviceProperties.GetZoneInfo` → `HTAudioIn`.
        case htAudioIn
        /// Streaming-content format from the `r:streamInfo` DIDL
        /// extension (`bd:…,sr:…,c:…,l:…,d:…`).
        case streamInfo
        /// Per-track delivery format for normal audio: URI scheme,
        /// container extension, service id, and streamInfo when
        /// present. The evidence for tags like "FLAC", "Apple
        /// lossless 24/48", or a service's lossy tier.
        case track
    }

    /// Stable identity: `"ht:<int>"` or `"stream:<raw streamInfo>"`.
    public let key: String
    public let source: Source
    /// The wire value exactly as reported — decimal `HTAudioIn`
    /// integer, or the raw `r:streamInfo` string.
    public let rawValue: String
    /// The enum case the value mapped to when first recorded
    /// (`TVAudioFormat` / `AudioFormat` rawValue; `"unknown"` marks a
    /// value the mapping table doesn't cover yet).
    public let mapped: String
    /// Distinct rooms the format has been observed in, insertion order.
    public var rooms: [String]
    public var firstSeen: Date
    public var lastSeen: Date
    public var count: Int
}

public final class AudioFormatObserver: @unchecked Sendable {
    public static let shared = AudioFormatObserver()

    private let queue = DispatchQueue(label: "audio-format-observer", qos: .utility)
    private let fileURL: URL
    /// Keyed by `AudioFormatObservation.key`. Guarded by `queue`.
    private var observations: [String: AudioFormatObservation] = [:]
    private var loaded = false
    /// Keys already diag-logged this launch. Guarded by `queue`.
    private var loggedThisLaunch: Set<String> = []
    /// Sightings since the last file write. Guarded by `queue`.
    private var unsavedCount = 0

    /// Repeat sightings between file writes. New keys always write
    /// immediately; repeats only bump counts/timestamps, which are not
    /// worth a disk hit per transport poll.
    private static let saveEvery = 50

    init(fileURL: URL = AppPaths.appSupportDirectory
            .appendingPathComponent("audio_format_observations.json")) {
        self.fileURL = fileURL
    }

    // MARK: - Recording

    /// Records an HDMI / optical input format sighting. `raw` is the
    /// `HTAudioIn` integer as reported; unmapped values are recorded
    /// too — they are the interesting ones.
    public func recordHTAudioIn(_ raw: Int, mapped: TVAudioFormat,
                                room: String, model: String) {
        record(key: "ht:\(raw)", source: .htAudioIn,
               rawValue: String(raw), mapped: mapped.rawValue, room: room,
               logContext: [
                   "raw": String(raw),
                   "hex": String(format: "0x%X", raw),
                   "mapped": mapped.rawValue,
                   "room": room,
                   "model": model
               ])
    }

    /// Records a streaming-content format sighting. Callers skip
    /// empty / all-zero descriptors (`mapped == .unknown` there means
    /// "not decoded yet", not a new format).
    public func recordStreamInfo(_ info: String, mapped: AudioFormat, room: String) {
        record(key: "stream:\(info)", source: .streamInfo,
               rawValue: info, mapped: mapped.rawValue, room: room,
               logContext: [
                   "streamInfo": info,
                   "mapped": mapped.rawValue,
                   "room": room
               ])
    }

    /// Records a normal-audio track's delivery format. The key is
    /// assembled only from observed evidence — URI scheme, container
    /// extension, `sid` service id, raw streamInfo — never from
    /// assumed service bitrates. Home-theater URIs are skipped; those
    /// arrive through `recordHTAudioIn` with the real input format.
    public func recordTrack(uri: String, streamInfo: String,
                            audioFormat: AudioFormat, room: String) {
        guard !uri.isEmpty,
              !uri.hasPrefix("x-sonos-htastream:"),
              !uri.hasPrefix("x-rincon-stream:") else { return }
        let scheme = String(uri.prefix(while: { $0 != ":" })).lowercased()
        guard !scheme.isEmpty else { return }
        var parts = ["scheme:\(scheme)"]
        var context = ["scheme": scheme]
        if let ext = Self.audioExtension(of: uri) {
            parts.append("ext:\(ext)")
            context["ext"] = ext
        }
        if let sid = Self.queryValue("sid", in: uri) {
            parts.append("sid:\(sid)")
            context["sid"] = sid
        }
        if !streamInfo.isEmpty {
            parts.append("si:\(streamInfo)")
            context["streamInfo"] = streamInfo
        }
        parts.append("fmt:\(audioFormat.rawValue)")
        context["mapped"] = audioFormat.rawValue
        context["room"] = room
        let raw = parts.joined(separator: "|")
        record(key: "track:\(raw)", source: .track,
               rawValue: raw, mapped: audioFormat.rawValue, room: room,
               logContext: context)
    }

    /// Current observation table, most-recently-seen first. Data
    /// source for a playback-tag UI.
    public func snapshot() -> [AudioFormatObservation] {
        queue.sync {
            loadIfNeeded()
            return observations.values.sorted { $0.lastSeen > $1.lastSeen }
        }
    }

    // MARK: - URI evidence extraction

    /// Audio container extension from the URI path (query stripped),
    /// whitelisted so junk path segments don't masquerade as codecs.
    /// Public: also feeds the Now Playing stream-details pill.
    public static func audioExtension(of uri: String) -> String? {
        let known: Set<String> = ["mp3", "flac", "m4a", "mp4", "aac",
                                  "ogg", "opus", "wav", "aiff", "aif",
                                  "alac", "wma"]
        let path = uri.split(separator: "?", maxSplits: 1,
                             omittingEmptySubsequences: false)[0]
        guard let lastComponent = path.split(separator: "/").last,
              let dot = lastComponent.lastIndex(of: ".") else { return nil }
        let ext = lastComponent[lastComponent.index(after: dot)...].lowercased()
        return known.contains(ext) ? ext : nil
    }

    /// Value of a query parameter (`sid` identifies the music
    /// service in Sonos URIs). Nil when absent.
    static func queryValue(_ name: String, in uri: String) -> String? {
        let split = uri.split(separator: "?", maxSplits: 1,
                              omittingEmptySubsequences: false)
        guard split.count == 2 else { return nil }
        for pair in split[1].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1,
                                omittingEmptySubsequences: false)
            if kv.count == 2, kv[0] == name {
                return String(kv[1])
            }
        }
        return nil
    }

    // MARK: - Private

    private func record(key: String, source: AudioFormatObservation.Source,
                        rawValue: String, mapped: String, room: String,
                        logContext: [String: String]) {
        let now = Date()
        queue.async { [self] in
            loadIfNeeded()
            var isNewKey = false
            if var existing = observations[key] {
                existing.lastSeen = now
                existing.count += 1
                if !room.isEmpty && !existing.rooms.contains(room) {
                    existing.rooms.append(room)
                }
                observations[key] = existing
            } else {
                isNewKey = true
                observations[key] = AudioFormatObservation(
                    key: key, source: source, rawValue: rawValue,
                    mapped: mapped, rooms: room.isEmpty ? [] : [room],
                    firstSeen: now, lastSeen: now, count: 1)
            }
            if !loggedThisLaunch.contains(key) {
                loggedThisLaunch.insert(key)
                let message: String
                switch source {
                case .htAudioIn:  message = "Observed HDMI input format"
                case .streamInfo: message = "Observed stream format"
                case .track:      message = "Observed track delivery format"
                }
                sonosDiagLog(.info, tag: "AUDIO_FORMAT", message,
                             context: logContext)
            }
            unsavedCount += 1
            if isNewKey || unsavedCount >= Self.saveEvery {
                save()
            }
        }
    }

    /// Runs on `queue`.
    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode([AudioFormatObservation].self,
                                                     from: data) else { return }
        for observation in stored {
            observations[observation.key] = observation
        }
    }

    /// Runs on `queue`.
    private func save() {
        unsavedCount = 0
        let list = observations.values.sorted { $0.firstSeen < $1.firstSeen }
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
