/// PlayHistoryRepository.swift — SQLite data access for play history.
///
/// All database operations are encapsulated here. No business logic —
/// just typed inputs/outputs and SQL. Used by PlayHistoryManager.
import Foundation
import SQLite3

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

    // MARK: - Internal

    private func exec(_ sql: String) {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            sonosDebugLog("[HISTORY] SQL error: \(String(cString: sqlite3_errmsg(db))) for: \(sql)")
        }
    }
}
