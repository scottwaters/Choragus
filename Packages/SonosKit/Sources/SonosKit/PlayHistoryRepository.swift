/// PlayHistoryRepository.swift — SQLite data access for play history.
///
/// All database operations are encapsulated here. No business logic —
/// just typed inputs/outputs and SQL. Used by PlayHistoryManager.
import Foundation
import SQLite3

public struct DailySummary {
    public let date: Date
    public let playCount: Int
    public let totalDuration: Double
    public let uniqueArtists: Int
    public let uniqueAlbums: Int
    public let uniqueStations: Int
    public let uniqueRooms: Int
    public let topArtist: String
    public let topTrack: String
    public let starredCount: Int
}

/// Outcome of a scrobble submission for one (history entry, service) pair.
/// Mirrors the three states the `scrobble_log` table records:
/// - `sent`: accepted by the service.
/// - `ignoredByService`: service rejected but don't retry (bad timestamp, duplicate, etc.).
/// - `failedRetryable`: transient failure, try again later up to retry cap.
public enum ScrobbleLogState: Int {
    case sent = 0
    case ignoredByService = 1
    case failedRetryable = 2
}

/// Persisted row from `scrobble_log` — used mainly for stats display in the
/// Scrobbling settings tab and for retry policy decisions.
public struct ScrobbleLogEntry {
    public let historyID: String
    public let service: String
    public let sentAt: Date
    public let state: ScrobbleLogState
    public let error: String?
    public let retryCount: Int
}

@MainActor
public final class PlayHistoryRepository {
    private var db: OpaquePointer?
    private let dbPath: String

    static let maxEntries = CacheDefaults.playHistoryMaxEntries

    public init(dbPath: String) {
        self.dbPath = dbPath
        openDatabase()
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Setup

    private func openDatabase() {
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            sonosDebugLog("[HISTORY] Failed to open database: \(String(cString: sqlite3_errmsg(db)))")
            return
        }

        exec("PRAGMA journal_mode=WAL")

        exec("""
            CREATE TABLE IF NOT EXISTS history (
                id TEXT PRIMARY KEY,
                timestamp REAL NOT NULL,
                title TEXT NOT NULL DEFAULT '',
                artist TEXT NOT NULL DEFAULT '',
                album TEXT NOT NULL DEFAULT '',
                station_name TEXT NOT NULL DEFAULT '',
                source_uri TEXT,
                group_name TEXT NOT NULL DEFAULT '',
                duration REAL NOT NULL DEFAULT 0,
                album_art_uri TEXT
            )
        """)

        // Add starred column if it doesn't exist (migration for existing databases)
        exec("ALTER TABLE history ADD COLUMN starred INTEGER NOT NULL DEFAULT 0")

        exec("CREATE INDEX IF NOT EXISTS idx_history_timestamp ON history(timestamp)")
        exec("CREATE INDEX IF NOT EXISTS idx_history_artist ON history(artist)")
        exec("CREATE INDEX IF NOT EXISTS idx_history_group ON history(group_name)")
        exec("CREATE INDEX IF NOT EXISTS idx_history_title ON history(title)")

        // Daily summary rollup table
        exec("""
            CREATE TABLE IF NOT EXISTS daily_summary (
                date TEXT PRIMARY KEY,
                play_count INTEGER NOT NULL DEFAULT 0,
                total_duration REAL NOT NULL DEFAULT 0,
                unique_artists INTEGER NOT NULL DEFAULT 0,
                unique_albums INTEGER NOT NULL DEFAULT 0,
                unique_stations INTEGER NOT NULL DEFAULT 0,
                unique_rooms INTEGER NOT NULL DEFAULT 0,
                top_artist TEXT NOT NULL DEFAULT '',
                top_track TEXT NOT NULL DEFAULT '',
                starred_count INTEGER NOT NULL DEFAULT 0
            )
        """)

        // Scrobble log — one row per (history entry, scrobbling service) pair.
        // Composite PK means the same history entry can be independently
        // scrobbled to multiple services (Last.fm, ListenBrainz, etc.).
        // `service` is a short identifier ("lastfm", "listenbrainz").
        // `state` follows ScrobbleLogState: 0 sent, 1 ignored-by-service,
        // 2 failed-retryable. `ON DELETE CASCADE` — clearing play history
        // clears the log with it.
        exec("""
            CREATE TABLE IF NOT EXISTS scrobble_log (
                history_id   TEXT NOT NULL,
                service      TEXT NOT NULL,
                sent_at      INTEGER NOT NULL,
                state        INTEGER NOT NULL,
                error        TEXT,
                retry_count  INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (history_id, service),
                FOREIGN KEY (history_id) REFERENCES history(id) ON DELETE CASCADE
            )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_scrobble_service_state ON scrobble_log(service, state)")
    }

    // MARK: - CRUD

    func insert(_ entry: PlayHistoryEntry) {
        let sql = """
            INSERT OR IGNORE INTO history (id, timestamp, title, artist, album, station_name, source_uri, group_name, duration, album_art_uri)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (entry.id.uuidString as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 2, entry.timestamp.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 3, (entry.title as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 4, (entry.artist as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 5, (entry.album as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 6, (entry.stationName as NSString).utf8String, -1, nil)
        if let uri = entry.sourceURI {
            sqlite3_bind_text(stmt, 7, (uri as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 7)
        }
        sqlite3_bind_text(stmt, 8, (entry.groupName as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 9, entry.duration)
        if let art = entry.albumArtURI {
            sqlite3_bind_text(stmt, 10, (art as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 10)
        }

        if sqlite3_step(stmt) != SQLITE_DONE {
            sonosDebugLog("[HISTORY] Insert failed: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    func loadAll() -> [PlayHistoryEntry] {
        var entries: [PlayHistoryEntry] = []
        let sql = "SELECT id, timestamp, title, artist, album, station_name, source_uri, group_name, duration, album_art_uri, starred FROM history ORDER BY timestamp ASC"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return entries }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let entry = PlayHistoryEntry(
                id: UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0))) ?? UUID(),
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                title: String(cString: sqlite3_column_text(stmt, 2)),
                artist: String(cString: sqlite3_column_text(stmt, 3)),
                album: String(cString: sqlite3_column_text(stmt, 4)),
                stationName: String(cString: sqlite3_column_text(stmt, 5)),
                sourceURI: sqlite3_column_type(stmt, 6) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 6)) : nil,
                groupName: String(cString: sqlite3_column_text(stmt, 7)),
                duration: sqlite3_column_double(stmt, 8),
                albumArtURI: sqlite3_column_type(stmt, 9) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 9)) : nil,
                starred: sqlite3_column_int(stmt, 10) != 0
            )
            entries.append(entry)
        }
        return entries
    }

    /// Filtered query — pushes filtering to SQLite instead of in-memory.
    /// Handles date range, room, search text. Source filtering done in-memory
    /// since it requires URI pattern matching not suited to SQL.
    func loadFiltered(since: Date? = nil, until: Date? = nil,
                      room: String? = nil, searchText: String? = nil,
                      sortNewestFirst: Bool = true, limit: Int = 50_000) -> [PlayHistoryEntry] {
        var clauses: [String] = []
        var binds: [(Int, Any)] = []
        var bindIndex = 1

        if let since {
            clauses.append("timestamp >= ?")
            binds.append((bindIndex, since.timeIntervalSince1970))
            bindIndex += 1
        }
        if let until {
            clauses.append("timestamp < ?")
            binds.append((bindIndex, until.timeIntervalSince1970))
            bindIndex += 1
        }
        if let room, !room.isEmpty {
            clauses.append("group_name = ?")
            binds.append((bindIndex, room))
            bindIndex += 1
        }
        if let searchText, !searchText.isEmpty {
            clauses.append("(title LIKE ? OR artist LIKE ? OR album LIKE ? OR station_name LIKE ? OR group_name LIKE ?)")
            let pattern = "%\(searchText)%"
            for _ in 0..<5 {
                binds.append((bindIndex, pattern))
                bindIndex += 1
            }
        }

        let whereClause = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        let order = sortNewestFirst ? "DESC" : "ASC"
        let sql = "SELECT id, timestamp, title, artist, album, station_name, source_uri, group_name, duration, album_art_uri, starred FROM history \(whereClause) ORDER BY timestamp \(order) LIMIT \(limit)"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        for (idx, value) in binds {
            if let d = value as? Double {
                sqlite3_bind_double(stmt, Int32(idx), d)
            } else if let s = value as? String {
                sqlite3_bind_text(stmt, Int32(idx), (s as NSString).utf8String, -1, nil)
            }
        }

        var entries: [PlayHistoryEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let entry = PlayHistoryEntry(
                id: UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0))) ?? UUID(),
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                title: String(cString: sqlite3_column_text(stmt, 2)),
                artist: String(cString: sqlite3_column_text(stmt, 3)),
                album: String(cString: sqlite3_column_text(stmt, 4)),
                stationName: String(cString: sqlite3_column_text(stmt, 5)),
                sourceURI: sqlite3_column_type(stmt, 6) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 6)) : nil,
                groupName: String(cString: sqlite3_column_text(stmt, 7)),
                duration: sqlite3_column_double(stmt, 8),
                albumArtURI: sqlite3_column_type(stmt, 9) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 9)) : nil,
                starred: sqlite3_column_int(stmt, 10) != 0
            )
            entries.append(entry)
        }
        return entries
    }

    /// Count entries matching filters (for display without loading all data)
    func countFiltered(since: Date? = nil, until: Date? = nil,
                       room: String? = nil, searchText: String? = nil) -> Int {
        var clauses: [String] = []
        var binds: [(Int, Any)] = []
        var bindIndex = 1

        if let since {
            clauses.append("timestamp >= ?")
            binds.append((bindIndex, since.timeIntervalSince1970))
            bindIndex += 1
        }
        if let until {
            clauses.append("timestamp < ?")
            binds.append((bindIndex, until.timeIntervalSince1970))
            bindIndex += 1
        }
        if let room, !room.isEmpty {
            clauses.append("group_name = ?")
            binds.append((bindIndex, room))
            bindIndex += 1
        }
        if let searchText, !searchText.isEmpty {
            clauses.append("(title LIKE ? OR artist LIKE ? OR album LIKE ? OR station_name LIKE ? OR group_name LIKE ?)")
            let pattern = "%\(searchText)%"
            for _ in 0..<5 {
                binds.append((bindIndex, pattern))
                bindIndex += 1
            }
        }

        let whereClause = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        let sql = "SELECT COUNT(*) FROM history \(whereClause)"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }

        for (idx, value) in binds {
            if let d = value as? Double {
                sqlite3_bind_double(stmt, Int32(idx), d)
            } else if let s = value as? String {
                sqlite3_bind_text(stmt, Int32(idx), (s as NSString).utf8String, -1, nil)
            }
        }

        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    func setStarred(id: UUID, starred: Bool) {
        let sql = "UPDATE history SET starred = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, starred ? 1 : 0)
        sqlite3_bind_text(stmt, 2, (id.uuidString as NSString).utf8String, -1, nil)
        sqlite3_step(stmt)
    }

    func delete(ids: [UUID]) {
        let sql = "DELETE FROM history WHERE id = ?"
        for id in ids {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            sqlite3_bind_text(stmt, 1, (id.uuidString as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    func deleteAll() {
        exec("DELETE FROM history")
    }

    func deleteByIDs(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        // Batch delete in chunks to avoid SQL parameter limits
        let chunkSize = 500
        for chunk in stride(from: 0, to: ids.count, by: chunkSize) {
            let batch = Array(ids[chunk..<min(chunk + chunkSize, ids.count)])
            let placeholders = batch.map { _ in "?" }.joined(separator: ",")
            let sql = "DELETE FROM history WHERE id IN (\(placeholders))"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(stmt) }
            for (i, id) in batch.enumerated() {
                sqlite3_bind_text(stmt, Int32(i + 1), (id.uuidString as NSString).utf8String, -1, nil)
            }
            sqlite3_step(stmt)
        }
    }

    func updateArtwork(id: UUID, artURL: String) {
        let sql = "UPDATE history SET album_art_uri = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (artURL as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (id.uuidString as NSString).utf8String, -1, nil)
        if sqlite3_step(stmt) != SQLITE_DONE {
            sonosDebugLog("[HISTORY] Update art failed: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    func hasRecentEntry(title: String, artist: String, groupName: String, since: TimeInterval) -> Bool {
        let sql = "SELECT COUNT(*) FROM history WHERE title = ? AND artist = ? AND group_name = ? AND timestamp > ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (title as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (artist as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (groupName as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 4, since)
        return sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_int(stmt, 0) > 0
    }

    // MARK: - Migration

    func insertBatch(_ entries: [PlayHistoryEntry]) {
        exec("BEGIN TRANSACTION")
        for entry in entries {
            insert(entry)
        }
        exec("COMMIT")
    }

    // MARK: - Daily Summary Rollup

    /// Rebuilds daily_summary for all dates, or a specific date
    func rebuildDailySummary(for date: String? = nil) {
        if let date {
            exec("DELETE FROM daily_summary WHERE date = '\(date)'")
            rebuildSummaryForDate(date)
        } else {
            exec("DELETE FROM daily_summary")
            // Get all distinct dates
            let sql = "SELECT DISTINCT date(timestamp, 'unixepoch', 'localtime') as d FROM history ORDER BY d"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            var dates: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cStr = sqlite3_column_text(stmt, 0) {
                    dates.append(String(cString: cStr))
                }
            }
            for d in dates {
                rebuildSummaryForDate(d)
            }
        }
    }

    private func rebuildSummaryForDate(_ date: String) {
        let sql = """
        INSERT OR REPLACE INTO daily_summary (date, play_count, total_duration, unique_artists, unique_albums, unique_stations, unique_rooms, top_artist, top_track, starred_count)
        SELECT
            date(timestamp, 'unixepoch', 'localtime') as d,
            COUNT(*) as play_count,
            COALESCE(SUM(duration), 0) as total_duration,
            COUNT(DISTINCT CASE WHEN artist != '' THEN artist END) as unique_artists,
            COUNT(DISTINCT CASE WHEN album != '' THEN album END) as unique_albums,
            COUNT(DISTINCT CASE WHEN station_name != '' THEN station_name END) as unique_stations,
            COUNT(DISTINCT CASE WHEN group_name != '' THEN group_name END) as unique_rooms,
            COALESCE((SELECT artist FROM history WHERE date(timestamp, 'unixepoch', 'localtime') = ? AND artist != '' GROUP BY artist ORDER BY COUNT(*) DESC LIMIT 1), '') as top_artist,
            COALESCE((SELECT title FROM history WHERE date(timestamp, 'unixepoch', 'localtime') = ? AND title != '' GROUP BY title ORDER BY COUNT(*) DESC LIMIT 1), '') as top_track,
            COALESCE(SUM(starred), 0) as starred_count
        FROM history
        WHERE date(timestamp, 'unixepoch', 'localtime') = ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (date as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (date as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (date as NSString).utf8String, -1, nil)
        sqlite3_step(stmt)
    }

    /// Returns daily summary data for dashboard charts
    func loadDailySummary(since: Date? = nil) -> [DailySummary] {
        var sql = "SELECT date, play_count, total_duration, unique_artists, unique_albums, unique_stations, unique_rooms, top_artist, top_track, starred_count FROM daily_summary"
        if let since {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            sql += " WHERE date >= '\(formatter.string(from: since))'"
        }
        sql += " ORDER BY date"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        var results: [DailySummary] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let dateStr = sqlite3_column_text(stmt, 0) else { continue }
            let date = formatter.date(from: String(cString: dateStr)) ?? Date()
            results.append(DailySummary(
                date: date,
                playCount: Int(sqlite3_column_int(stmt, 1)),
                totalDuration: sqlite3_column_double(stmt, 2),
                uniqueArtists: Int(sqlite3_column_int(stmt, 3)),
                uniqueAlbums: Int(sqlite3_column_int(stmt, 4)),
                uniqueStations: Int(sqlite3_column_int(stmt, 5)),
                uniqueRooms: Int(sqlite3_column_int(stmt, 6)),
                topArtist: sqlite3_column_text(stmt, 7).map { String(cString: $0) } ?? "",
                topTrack: sqlite3_column_text(stmt, 8).map { String(cString: $0) } ?? "",
                starredCount: Int(sqlite3_column_int(stmt, 9))
            ))
        }
        return results
    }

    /// Summary totals from the rollup table
    func summaryTotals() -> (plays: Int, duration: Double, artists: Int, albums: Int, stations: Int, rooms: Int, starred: Int) {
        let sql = "SELECT COALESCE(SUM(play_count),0), COALESCE(SUM(total_duration),0), COUNT(*), COALESCE(SUM(starred_count),0) FROM daily_summary"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return (0, 0, 0, 0, 0, 0, 0)
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return (0, 0, 0, 0, 0, 0, 0) }
        return (
            plays: Int(sqlite3_column_int(stmt, 0)),
            duration: sqlite3_column_double(stmt, 1),
            artists: 0, albums: 0, stations: 0, rooms: 0, // These need distinct counts across days
            starred: Int(sqlite3_column_int(stmt, 3))
        )
    }

    // MARK: - Scrobble Log

    /// Returns history entries that are candidates for scrobbling to `service`:
    /// never sent OR previously failed with retries remaining. Caller applies
    /// business-level eligibility on top (duration, age window, artist/title
    /// presence, source/room filters).
    ///
    /// Ordered by timestamp ascending so older entries are scrobbled first —
    /// important when there are more pending than one batch can hold.
    public func unscrobbledEntries(
        service: String,
        maxRetries: Int = 3,
        limit: Int = 500
    ) -> [PlayHistoryEntry] {
        let sql = """
            SELECT h.id, h.timestamp, h.title, h.artist, h.album, h.station_name,
                   h.source_uri, h.group_name, h.duration, h.album_art_uri, h.starred
            FROM history h
            LEFT JOIN scrobble_log s
              ON s.history_id = h.id AND s.service = ?
            WHERE s.history_id IS NULL
               OR (s.state = \(ScrobbleLogState.failedRetryable.rawValue) AND s.retry_count < ?)
            ORDER BY h.timestamp ASC
            LIMIT ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (service as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 2, Int32(maxRetries))
        sqlite3_bind_int(stmt, 3, Int32(limit))

        var entries: [PlayHistoryEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let entry = PlayHistoryEntry(
                id: UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0))) ?? UUID(),
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                title: String(cString: sqlite3_column_text(stmt, 2)),
                artist: String(cString: sqlite3_column_text(stmt, 3)),
                album: String(cString: sqlite3_column_text(stmt, 4)),
                stationName: String(cString: sqlite3_column_text(stmt, 5)),
                sourceURI: sqlite3_column_type(stmt, 6) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 6)) : nil,
                groupName: String(cString: sqlite3_column_text(stmt, 7)),
                duration: sqlite3_column_double(stmt, 8),
                albumArtURI: sqlite3_column_type(stmt, 9) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 9)) : nil,
                starred: sqlite3_column_int(stmt, 10) != 0
            )
            entries.append(entry)
        }
        return entries
    }

    /// Records the outcome of a scrobble submission. Uses UPSERT semantics —
    /// later state replaces earlier state for the same (history_id, service).
    /// `retry_count` increments automatically when re-recording a failure.
    public func recordScrobbleResult(
        historyID: UUID,
        service: String,
        state: ScrobbleLogState,
        error: String? = nil
    ) {
        let sql = """
            INSERT INTO scrobble_log (history_id, service, sent_at, state, error, retry_count)
            VALUES (?, ?, ?, ?, ?, 0)
            ON CONFLICT(history_id, service) DO UPDATE SET
                sent_at = excluded.sent_at,
                state = excluded.state,
                error = excluded.error,
                retry_count = CASE
                    WHEN excluded.state = \(ScrobbleLogState.failedRetryable.rawValue)
                    THEN scrobble_log.retry_count + 1
                    ELSE scrobble_log.retry_count
                END
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sonosDebugLog("[SCROBBLE] Prepare recordScrobbleResult failed: \(String(cString: sqlite3_errmsg(db)))")
            return
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (historyID.uuidString as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (service as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(stmt, 3, Int64(Date().timeIntervalSince1970))
        sqlite3_bind_int(stmt, 4, Int32(state.rawValue))
        if let error {
            sqlite3_bind_text(stmt, 5, (error as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 5)
        }

        if sqlite3_step(stmt) != SQLITE_DONE {
            sonosDebugLog("[SCROBBLE] Record failed: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    /// Pending (unscrobbled eligible) count for a service — for UI display.
    /// Cheaper than fetching the entries; uses same join predicate.
    public func pendingScrobbleCount(service: String, maxRetries: Int = 3) -> Int {
        let sql = """
            SELECT COUNT(*) FROM history h
            LEFT JOIN scrobble_log s
              ON s.history_id = h.id AND s.service = ?
            WHERE s.history_id IS NULL
               OR (s.state = \(ScrobbleLogState.failedRetryable.rawValue) AND s.retry_count < ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (service as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 2, Int32(maxRetries))
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    /// Counts by state for a service — for UI display.
    public func scrobbleStats(service: String) -> (sent: Int, ignored: Int, failed: Int) {
        let sql = """
            SELECT state, COUNT(*) FROM scrobble_log
            WHERE service = ?
            GROUP BY state
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return (0, 0, 0) }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (service as NSString).utf8String, -1, nil)

        var sent = 0, ignored = 0, failed = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            let state = Int(sqlite3_column_int(stmt, 0))
            let count = Int(sqlite3_column_int(stmt, 1))
            switch ScrobbleLogState(rawValue: state) {
            case .sent: sent = count
            case .ignoredByService: ignored = count
            case .failedRetryable: failed = count
            case nil: break
            }
        }
        return (sent, ignored, failed)
    }

    /// Deletes `scrobble_log` rows for a service in the `ignoredByService`
    /// state — called when the user changes their room/service filters and
    /// wants previously filter-excluded rows to be re-evaluated. Returns
    /// the number of rows cleared so the UI can confirm how many will be
    /// reconsidered on the next run. `sent` rows are preserved (never
    /// re-scrobble a successful submission).
    @discardableResult
    public func resetIgnoredScrobbles(service: String) -> Int {
        let sql = """
            DELETE FROM scrobble_log
            WHERE service = ? AND state = \(ScrobbleLogState.ignoredByService.rawValue)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (service as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return 0 }
        return Int(sqlite3_changes(db))
    }

    /// One row of a recent non-sent scrobble for the Settings diagnostic list.
    /// Joins `scrobble_log` back to `history` so the UI can render why a
    /// specific track was dropped (instead of a bare count).
    public struct ScrobbleDiagnosticRow: Identifiable {
        public let id: UUID
        public let timestamp: Date
        public let title: String
        public let artist: String
        public let state: ScrobbleLogState
        public let reason: String?
    }

    /// Returns the most recent scrobble_log rows that are NOT in the `sent`
    /// state — the ones the user wants to see when they ask "why didn't my
    /// tracks go?". Ordered newest first so the likeliest recent culprit is
    /// at the top.
    public func recentNonSentScrobbles(
        service: String,
        limit: Int = 50
    ) -> [ScrobbleDiagnosticRow] {
        let sql = """
            SELECT s.history_id, h.timestamp, h.title, h.artist, s.state, s.error
            FROM scrobble_log s
            JOIN history h ON h.id = s.history_id
            WHERE s.service = ?
              AND s.state != \(ScrobbleLogState.sent.rawValue)
            ORDER BY s.sent_at DESC
            LIMIT ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (service as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 2, Int32(limit))

        var rows: [ScrobbleDiagnosticRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0))) ?? UUID()
            let ts = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
            let title = String(cString: sqlite3_column_text(stmt, 2))
            let artist = String(cString: sqlite3_column_text(stmt, 3))
            let rawState = Int(sqlite3_column_int(stmt, 4))
            let state = ScrobbleLogState(rawValue: rawState) ?? .ignoredByService
            let reason: String? = sqlite3_column_type(stmt, 5) != SQLITE_NULL
                ? String(cString: sqlite3_column_text(stmt, 5)) : nil
            rows.append(ScrobbleDiagnosticRow(
                id: id, timestamp: ts, title: title, artist: artist,
                state: state, reason: reason
            ))
        }
        return rows
    }

    /// Returns the set of distinct `group_name` values seen in history — used
    /// to populate the room-selection UI in Scrobbling settings.
    public func distinctGroupNames() -> [String] {
        let sql = "SELECT DISTINCT group_name FROM history WHERE group_name != '' ORDER BY group_name"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var names: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                names.append(String(cString: cStr))
            }
        }
        return names
    }

    // MARK: - Internal

    private func exec(_ sql: String) {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            sonosDebugLog("[HISTORY] SQL error: \(String(cString: sqlite3_errmsg(db))) for: \(sql)")
        }
    }
}
