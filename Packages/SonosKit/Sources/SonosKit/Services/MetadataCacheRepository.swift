/// MetadataCacheRepository.swift — Persistent cache for fetched
/// lyrics, artist info, album info, and any other web-derived
/// metadata.
///
/// Lives in the same SQLite file as play history so the user only
/// has one DB file to back up / clear / migrate. Schema is a single
/// generic key/payload/expiry table — kind-specific code in
/// `LyricsService` / `MusicMetadataService` decides what JSON shape
/// goes into `payload` and what TTL to apply.
///
/// Hits never re-fetch; misses fire one network call per (kind, key)
/// and write back. Permanent caching for things that don't change
/// (lyrics, artist names) is fine — manual refresh via context menu
/// is the planned escape hatch.
import Foundation
import SQLite3

public final class MetadataCacheRepository {
    private var db: OpaquePointer?
    private let dbQueue = DispatchQueue(label: "metadata-cache-repo", qos: .utility)

    /// Convenience for callers that don't want to construct keys
    /// manually. Lower-cases + trims so close-but-not-identical
    /// metadata strings hit the same cache entry.
    public enum Kind: String {
        case lyrics
        case artist
        case album
        case track
        /// Apple Music iTunes-by-track-ID lookup result. Keyed by the
        /// numeric track ID extracted from `x-sonos-http:song:<id>` /
        /// `x-sonosapi-hls-static:song:<id>` URIs. Stores artist + album
        /// so subsequent plays of the same favorite skip the network call.
        case appleMusicTrack
        /// Per-track lyrics timing offset chosen by the user via the
        /// `lyricsOffsetToolbar` in NowPlayingContextPanel. Keyed by
        /// `(artist, title, album)` so the same scrub sticks across
        /// relaunches and across switching to/from the track.
        case lyricsOffset
        public func key(_ parts: String...) -> String {
            let normalised = parts.map { part in
                part.lowercased()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "  ", with: " ")
            }.joined(separator: "|")
            return "\(rawValue):\(normalised)"
        }
    }

    public init(dbPath: String) {
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            sonosDebugLog("[META-CACHE] Could not open db at \(dbPath): \(String(cString: sqlite3_errmsg(db)))")
            return
        }
        let create = """
        CREATE TABLE IF NOT EXISTS metadata_cache (
            key TEXT PRIMARY KEY,
            payload TEXT NOT NULL,
            fetched_at INTEGER NOT NULL,
            expires_at INTEGER
        );
        """
        if sqlite3_exec(db, create, nil, nil, nil) != SQLITE_OK {
            sonosDebugLog("[META-CACHE] Schema create failed: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    deinit {
        if db != nil { sqlite3_close(db) }
    }

    // MARK: - Get / Set

    /// Returns the cached payload string if present and not expired,
    /// else nil. Decoding is the caller's responsibility (each kind
    /// owns its JSON shape).
    public func get(_ key: String) -> String? {
        dbQueue.sync {
            let now = Int(Date().timeIntervalSince1970)
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "SELECT payload, expires_at FROM metadata_cache WHERE key = ?"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            sqlite3_bind_text(stmt, 1, (key as NSString).utf8String, -1, nil)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            let payload = String(cString: sqlite3_column_text(stmt, 0))
            // expires_at NULL = never expire.
            if sqlite3_column_type(stmt, 1) != SQLITE_NULL {
                let expires = Int(sqlite3_column_int64(stmt, 1))
                if expires > 0 && now > expires { return nil }
            }
            return payload
        }
    }

    /// Stores `payload` under `key`. `ttlSeconds` of nil = permanent
    /// (lyrics never change). Use small TTLs (days/weeks) for
    /// dynamic Last.fm fields like listener counts.
    public func set(_ key: String, payload: String, ttlSeconds: Int? = nil) {
        dbQueue.async { [weak self] in
            guard let self, let db = self.db else { return }
            let now = Int(Date().timeIntervalSince1970)
            let expires: Int64 = ttlSeconds.map { Int64(now + $0) } ?? 0
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = """
            INSERT INTO metadata_cache (key, payload, fetched_at, expires_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET
                payload = excluded.payload,
                fetched_at = excluded.fetched_at,
                expires_at = excluded.expires_at;
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_text(stmt, 1, (key as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (payload as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(stmt, 3, Int64(now))
            if expires > 0 {
                sqlite3_bind_int64(stmt, 4, expires)
            } else {
                sqlite3_bind_null(stmt, 4)
            }
            sqlite3_step(stmt)
        }
    }

    /// Deletes a single cache entry. Used by the manual "refresh"
    /// context-menu action when the user wants to bust a stale entry.
    public func clear(_ key: String) {
        dbQueue.async { [weak self] in
            guard let self, let db = self.db else { return }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            sqlite3_prepare_v2(db, "DELETE FROM metadata_cache WHERE key = ?", -1, &stmt, nil)
            sqlite3_bind_text(stmt, 1, (key as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
    }

    /// Wipes the entire cache. Dev/debug button only.
    public func clearAll() {
        dbQueue.async { [weak self] in
            guard let self, let db = self.db else { return }
            sqlite3_exec(db, "DELETE FROM metadata_cache", nil, nil, nil)
        }
    }

    /// Approximate row count, for stats / debug surfaces.
    public func count() -> Int {
        dbQueue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM metadata_cache", -1, &stmt, nil) == SQLITE_OK else { return 0 }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int(stmt, 0))
        }
    }
}
