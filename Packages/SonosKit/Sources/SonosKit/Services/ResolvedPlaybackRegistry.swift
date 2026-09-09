/// ResolvedPlaybackRegistry.swift — Remembers what a resolved play URL was.
///
/// A controller-authenticated service track is enqueued as the pre-signed CDN
/// URL returned by `getMediaURI`, with empty DIDL. That discards the only
/// thing that could produce a *fresh* URL later: the service id and the
/// service's own item id. When the signature expires, the queue entry is
/// unrepairable.
///
/// This registry keeps that mapping, keyed by the part of the play URL that
/// stays constant across resolutions. The signature and expiry rotate every
/// time the same track is resolved, so they are excluded from the key; what
/// remains identifies the track on the CDN.
///
/// Persisted, because the queue outlives the app session that filled it.
/// Bounded, because a long-lived library would otherwise grow without limit.
import Foundation

public enum ResolvedPlaybackRegistry {
    private static let storeKey = "resolvedPlaybackOrigins"  // [key: "sid\titemID"]
    /// Trim target. A queue holds at most a few hundred tracks and a saved
    /// queue library a few thousand; beyond this the oldest entries are the
    /// least likely to be replayed.
    private static let capacity = 4000
    /// Serializes read-modify-write. `UserDefaults` is atomic per call, not
    /// across a read and a write, so concurrent resolutions could lose
    /// entries — the same hazard `TidalCatalog.remember` guards against.
    private static let storeLock = NSLock()

    /// Query parameters that change on every resolution of the same track.
    /// Excluded from the key so a re-resolved URL maps to the same entry.
    private static let rotatingParameters: Set<String> = [
        "token", "sig", "signature", "hdnts", "Expires", "expires", "exp",
        "oauth2_expiry", "Policy", "Key-Pair-Id",
        "X-Amz-Signature", "X-Amz-Date", "X-Amz-Expires", "X-Amz-Credential",
        "X-Amz-Security-Token", "X-Amz-SignedHeaders", "X-Amz-Algorithm",
    ]

    /// The stable identity of a resolved play URL: scheme, host, path, and any
    /// query parameter that does not rotate. Returns nil for anything that
    /// isn't a direct stream, since only those are resolved this way.
    public static func key(forPlayURL url: String) -> String? {
        guard StaleTrackURL.isDirectStream(url) else { return nil }
        guard let mark = url.firstIndex(of: "?") else { return url }
        let base = String(url[..<mark])
        let query = url[url.index(after: mark)...]
        let kept = query
            .split(separator: "&", omittingEmptySubsequences: true)
            .filter { pair in
                let name = pair.firstIndex(of: "=").map { String(pair[..<$0]) } ?? String(pair)
                return !rotatingParameters.contains(name)
            }
            .sorted()
        return kept.isEmpty ? base : base + "?" + kept.joined(separator: "&")
    }

    /// Record which service item produced this play URL.
    public static func remember(playURL: String, sid: Int, itemID: String) {
        guard let key = key(forPlayURL: playURL), !itemID.isEmpty else { return }
        let packed = "\(sid)\t\(itemID)"
        storeLock.lock()
        defer { storeLock.unlock() }
        var store = (UserDefaults.standard.dictionary(forKey: storeKey) as? [String: String]) ?? [:]
        guard store[key] != packed else { return }
        store[key] = packed
        if store.count > capacity {
            // No insertion order is kept, so trim an arbitrary slice rather
            // than pretend to evict the oldest. Losing an entry costs one
            // manual re-add; unbounded growth costs every launch.
            for surplus in store.keys.prefix(store.count - capacity) where surplus != key {
                store.removeValue(forKey: surplus)
            }
        }
        UserDefaults.standard.set(store, forKey: storeKey)
    }

    /// The service item this play URL came from, when it is known.
    public static func origin(ofPlayURL playURL: String) -> (sid: Int, itemID: String)? {
        guard let key = key(forPlayURL: playURL),
              let packed = (UserDefaults.standard.dictionary(forKey: storeKey) as? [String: String])?[key]
        else { return nil }
        let parts = packed.components(separatedBy: "\t")
        guard parts.count >= 2, let sid = Int(parts[0]), !parts[1].isEmpty else { return nil }
        return (sid, parts[1])
    }

    /// Drops every entry. Exposed for the cache-clearing control in Settings.
    public static func removeAll() {
        storeLock.lock()
        defer { storeLock.unlock() }
        UserDefaults.standard.removeObject(forKey: storeKey)
    }
}
