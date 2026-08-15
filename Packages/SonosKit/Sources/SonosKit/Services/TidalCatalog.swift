/// TidalCatalog.swift — Persistent art/title/artist recovery for TIDAL tracks.
///
/// A TIDAL track is played via a resolved direct CDN URL (`getMediaURI` →
/// `https://…audio.tidal.com/mediatracks/<blob>/0.flac?token=…`) with empty
/// DIDL, so the speaker reports no album art and no usable title. Unlike Suno
/// there is no id in the play URL that maps back to cover art, so the art /
/// title / artist that TIDAL supplies at browse time are remembered
/// (UserDefaults) keyed by the stable `mediatracks/<blob>` segment of the play
/// URL. The `?token=…` query rotates per resolution, so it is deliberately
/// excluded from the key; the blob is constant per track and survives an app
/// restart — unlike the in-memory track cache.
import Foundation

public enum TidalCatalog {
    private static let metaKey = "tidalTrackMeta"   // [blob: "art\ttitle\tartist"]
    /// Compiled once — `key(fromURI:)` is called per history entry in
    /// hot paths (Club Vis pool build); per-call compilation showed up
    /// in main-thread stall profiles.
    private static let blobRegex = try? NSRegularExpression(pattern: "mediatracks/([^/?]+)")
    /// Serializes the read-modify-write in `remember` — UserDefaults
    /// guarantees atomicity per call, not across a read + write pair,
    /// so unlocked concurrent remembers could lose entries.
    private static let storeLock = NSLock()

    /// The stable per-track key embedded in a resolved TIDAL CDN URL, or nil
    /// when `uri` isn't a TIDAL media URL.
    public static func key(fromURI uri: String) -> String? {
        guard uri.contains("audio.tidal.com") || uri.contains("tidal.com/mediatracks") else { return nil }
        guard let re = blobRegex else { return nil }
        let range = NSRange(uri.startIndex..., in: uri)
        guard let m = re.firstMatch(in: uri, range: range),
              let r = Range(m.range(at: 1), in: uri) else { return nil }
        return String(uri[r])
    }

    /// Persist the browse-time art / title / artist for a resolved play URL so
    /// the four playback surfaces can recover them after the DIDL is stripped.
    public static func remember(playURL: String, art: String?, title: String, artist: String) {
        guard let blob = key(fromURI: playURL) else { return }
        let a = (art ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let ar = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        // Nothing worth remembering — avoid clobbering a good prior entry.
        guard !a.isEmpty || !t.isEmpty || !ar.isEmpty else { return }
        storeLock.lock()
        defer { storeLock.unlock() }
        var store = (UserDefaults.standard.dictionary(forKey: metaKey) as? [String: String]) ?? [:]
        // Tab-join is safe: art is a URL, title/artist can't contain a tab.
        let packed = "\(a)\t\(t)\t\(ar)"
        guard store[blob] != packed else { return }
        store[blob] = packed
        UserDefaults.standard.set(store, forKey: metaKey)
    }

    private static func fields(forURI uri: String) -> (art: String, title: String, artist: String)? {
        guard let blob = key(fromURI: uri),
              let packed = (UserDefaults.standard.dictionary(forKey: metaKey) as? [String: String])?[blob]
        else { return nil }
        let parts = packed.components(separatedBy: "\t")
        return (parts.first ?? "",
                parts.count > 1 ? parts[1] : "",
                parts.count > 2 ? parts[2] : "")
    }

    public static func art(forURI uri: String) -> String? {
        let v = fields(forURI: uri)?.art
        return (v?.isEmpty == false) ? v : nil
    }

    /// One-shot blob→art snapshot for bulk walks. `art(forURI:)`
    /// copies the whole UserDefaults dictionary per call; a
    /// per-history-entry walk (Club Vis pool build) made thousands of
    /// copies and contended the process-global preferences lock the
    /// main thread's @AppStorage reads also take. Callers take one
    /// snapshot and pair it with `key(fromURI:)`.
    public static func artByBlobSnapshot() -> [String: String] {
        guard let store = UserDefaults.standard.dictionary(forKey: metaKey) as? [String: String] else {
            return [:]
        }
        var out: [String: String] = [:]
        out.reserveCapacity(store.count)
        for (blob, packed) in store {
            let art = packed.components(separatedBy: "\t").first ?? ""
            if !art.isEmpty { out[blob] = art }
        }
        return out
    }

    public static func title(forURI uri: String) -> String? {
        let v = fields(forURI: uri)?.title
        return (v?.isEmpty == false) ? v : nil
    }

    public static func artist(forURI uri: String) -> String? {
        let v = fields(forURI: uri)?.artist
        return (v?.isEmpty == false) ? v : nil
    }
}
