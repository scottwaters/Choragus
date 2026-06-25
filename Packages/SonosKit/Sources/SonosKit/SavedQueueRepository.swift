/// SavedQueueRepository.swift — SQLite data access for Choragus-side saved
/// queues.
///
/// A Choragus-side save is independent of the Sonos household: it survives
/// speaker resets, doesn't count against the household's saved-queue
/// budget, and never appears in other controllers. The stored fields are
/// the parsed queue rows (title / artist / album / art / uri / duration);
/// restore rebuilds `BrowseItem`s from them and reuses the normal enqueue
/// machinery, which reconstructs service DIDL and prefills the track-info
/// cache — the same fidelity as any browse-originated add.
///
/// All database operations are encapsulated here. No business logic —
/// just typed inputs/outputs and SQL. Mirrors `PlayHistoryRepository`.
import Foundation
import SQLite3

/// A folder grouping Choragus-side saved queues.
public struct SavedQueueFolder: Identifiable, Equatable {
    public let id: Int64
    public let name: String
    /// Parent folder for nesting; nil = top level.
    public let parentID: Int64?
    public init(id: Int64, name: String, parentID: Int64? = nil) {
        self.id = id; self.name = name; self.parentID = parentID
    }
}

/// One Choragus-side saved queue (header row; tracks load separately).
public struct LocalSavedQueue: Identifiable, Equatable {
    public let id: Int64
    public let name: String
    public let createdAt: Date
    public let trackCount: Int
    /// Folders this queue belongs to. A queue can be a member of several
    /// folders at once (many-to-many); empty == top level.
    public let folderIDs: [Int64]

    public init(id: Int64, name: String, createdAt: Date, trackCount: Int, folderIDs: [Int64] = []) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.trackCount = trackCount
        self.folderIDs = folderIDs
    }
}

@MainActor
public final class SavedQueueRepository {

    /// SQLite must COPY the bound buffer: `(s as NSString).utf8String` is
    /// autorelease-pool-scoped, so the no-copy `nil` destructor promised a
    /// lifetime the buffer does not have (dangling-pointer UB). Mirrors
    /// PlayHistoryRepository.
    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private var db: OpaquePointer?

    public init(dbPath: String) {
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            sonosDiagLog(.error, tag: "SAVEDQ",
                         "Failed to open database: \(String(cString: sqlite3_errmsg(db)))",
                         context: ["dbPath": dbPath])
            return
        }
        exec("PRAGMA journal_mode=WAL")
        // OFF by default in SQLite, per-connection. Without it the tracks
        // table's ON DELETE CASCADE is inert and deletions orphan rows.
        exec("PRAGMA foreign_keys=ON")
        exec("""
            CREATE TABLE IF NOT EXISTS saved_queue_folders (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                created_at REAL NOT NULL
            )
            """)
        exec("""
            CREATE TABLE IF NOT EXISTS saved_queues (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                created_at REAL NOT NULL,
                folder_id INTEGER REFERENCES saved_queue_folders(id) ON DELETE SET NULL
            )
            """)
        // Defensive migration for stores created before folders (B1320).
        addColumnIfMissing(table: "saved_queues", column: "folder_id",
                           definition: "folder_id INTEGER REFERENCES saved_queue_folders(id) ON DELETE SET NULL")
        // Sub-folders: nest folders via parent_id. CASCADE so deleting a parent
        // removes its subtree; the queues inside those subfolders fall back to
        // top level via the saved_queues SET NULL above.
        addColumnIfMissing(table: "saved_queue_folders", column: "parent_id",
                           definition: "parent_id INTEGER REFERENCES saved_queue_folders(id) ON DELETE CASCADE")
        // Many-to-many folder membership: a queue can live in several folders.
        // The legacy single `folder_id` column is migrated in below and then
        // ignored (kept to avoid a table rebuild).
        exec("""
            CREATE TABLE IF NOT EXISTS saved_queue_folder_members (
                queue_id INTEGER NOT NULL REFERENCES saved_queues(id) ON DELETE CASCADE,
                folder_id INTEGER NOT NULL REFERENCES saved_queue_folders(id) ON DELETE CASCADE,
                PRIMARY KEY (queue_id, folder_id)
            )
            """)
        // One-time, idempotent: seed memberships from the old folder_id.
        exec("""
            INSERT OR IGNORE INTO saved_queue_folder_members (queue_id, folder_id)
            SELECT id, folder_id FROM saved_queues WHERE folder_id IS NOT NULL
            """)
        exec("""
            CREATE TABLE IF NOT EXISTS saved_queue_tracks (
                queue_id INTEGER NOT NULL REFERENCES saved_queues(id) ON DELETE CASCADE,
                position INTEGER NOT NULL,
                title TEXT NOT NULL DEFAULT '',
                artist TEXT NOT NULL DEFAULT '',
                album TEXT NOT NULL DEFAULT '',
                art_url TEXT,
                uri TEXT,
                duration TEXT NOT NULL DEFAULT '',
                metadata TEXT,
                PRIMARY KEY (queue_id, position)
            )
            """)
        // Defensive migration for queues saved by a build that predated the
        // metadata column (B1307).
        addColumnIfMissing(table: "saved_queue_tracks", column: "metadata", definition: "metadata TEXT")
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Writes

    /// Stores a queue under `name`. Returns the new queue's row ID, or nil
    /// on failure. Tracks keep their 1-based queue positions.
    public func save(name: String, tracks: [QueueItem]) -> Int64? {
        guard !tracks.isEmpty else { return nil }
        exec("BEGIN")
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "INSERT INTO saved_queues (name, created_at) VALUES (?, ?)",
                                 -1, &stmt, nil) == SQLITE_OK else { exec("ROLLBACK"); return nil }
        sqlite3_bind_text(stmt, 1, name, -1, Self.SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_DONE else { exec("ROLLBACK"); return nil }
        let queueID = sqlite3_last_insert_rowid(db)

        var trackStmt: OpaquePointer?
        defer { sqlite3_finalize(trackStmt) }
        guard sqlite3_prepare_v2(db, """
            INSERT INTO saved_queue_tracks
                (queue_id, position, title, artist, album, art_url, uri, duration, metadata)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, -1, &trackStmt, nil) == SQLITE_OK else { exec("ROLLBACK"); return nil }
        for track in tracks {
            sqlite3_reset(trackStmt)
            sqlite3_bind_int64(trackStmt, 1, queueID)
            sqlite3_bind_int(trackStmt, 2, Int32(track.id))
            sqlite3_bind_text(trackStmt, 3, track.title, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(trackStmt, 4, track.artist, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(trackStmt, 5, track.album, -1, Self.SQLITE_TRANSIENT)
            if let art = track.albumArtURI {
                sqlite3_bind_text(trackStmt, 6, art, -1, Self.SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(trackStmt, 6)
            }
            if let uri = track.uri {
                sqlite3_bind_text(trackStmt, 7, uri, -1, Self.SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(trackStmt, 7)
            }
            sqlite3_bind_text(trackStmt, 8, track.duration, -1, Self.SQLITE_TRANSIENT)
            if let meta = track.metadata {
                sqlite3_bind_text(trackStmt, 9, meta, -1, Self.SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(trackStmt, 9)
            }
            guard sqlite3_step(trackStmt) == SQLITE_DONE else { exec("ROLLBACK"); return nil }
        }
        exec("COMMIT")
        return queueID
    }

    /// Appends tracks to an existing saved queue after its last position.
    /// Returns the number appended.
    @discardableResult
    public func appendTracks(queueID: Int64, tracks: [QueueItem]) -> Int {
        guard !tracks.isEmpty else { return 0 }
        var maxStmt: OpaquePointer?
        var nextPos = 1
        if sqlite3_prepare_v2(db, "SELECT COALESCE(MAX(position),0) FROM saved_queue_tracks WHERE queue_id = ?",
                              -1, &maxStmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(maxStmt, 1, queueID)
            if sqlite3_step(maxStmt) == SQLITE_ROW { nextPos = Int(sqlite3_column_int(maxStmt, 0)) + 1 }
        }
        sqlite3_finalize(maxStmt)

        exec("BEGIN")
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, """
            INSERT INTO saved_queue_tracks
                (queue_id, position, title, artist, album, art_url, uri, duration, metadata)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, -1, &stmt, nil) == SQLITE_OK else { exec("ROLLBACK"); return 0 }
        var count = 0
        for track in tracks {
            sqlite3_reset(stmt)
            sqlite3_bind_int64(stmt, 1, queueID)
            sqlite3_bind_int(stmt, 2, Int32(nextPos))
            sqlite3_bind_text(stmt, 3, track.title, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, track.artist, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 5, track.album, -1, Self.SQLITE_TRANSIENT)
            if let art = track.albumArtURI { sqlite3_bind_text(stmt, 6, art, -1, Self.SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 6) }
            if let uri = track.uri { sqlite3_bind_text(stmt, 7, uri, -1, Self.SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 7) }
            sqlite3_bind_text(stmt, 8, track.duration, -1, Self.SQLITE_TRANSIENT)
            if let meta = track.metadata { sqlite3_bind_text(stmt, 9, meta, -1, Self.SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 9) }
            guard sqlite3_step(stmt) == SQLITE_DONE else { exec("ROLLBACK"); return 0 }
            nextPos += 1
            count += 1
        }
        exec("COMMIT")
        return count
    }

    /// Replaces all of a queue's tracks with `tracks`, renumbering positions
    /// from 1. Used by the manager's edit/reorder/remove operations, which
    /// mutate the list in memory then persist the whole order.
    public func replaceTracks(queueID: Int64, tracks: [QueueItem]) {
        exec("BEGIN")
        var del: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM saved_queue_tracks WHERE queue_id = ?", -1, &del, nil) == SQLITE_OK {
            sqlite3_bind_int64(del, 1, queueID)
            sqlite3_step(del)
        }
        sqlite3_finalize(del)
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, """
            INSERT INTO saved_queue_tracks
                (queue_id, position, title, artist, album, art_url, uri, duration, metadata)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, -1, &stmt, nil) == SQLITE_OK else { exec("ROLLBACK"); return }
        for (idx, track) in tracks.enumerated() {
            sqlite3_reset(stmt)
            sqlite3_bind_int64(stmt, 1, queueID)
            sqlite3_bind_int(stmt, 2, Int32(idx + 1))
            sqlite3_bind_text(stmt, 3, track.title, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, track.artist, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 5, track.album, -1, Self.SQLITE_TRANSIENT)
            if let art = track.albumArtURI { sqlite3_bind_text(stmt, 6, art, -1, Self.SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 6) }
            if let uri = track.uri { sqlite3_bind_text(stmt, 7, uri, -1, Self.SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 7) }
            sqlite3_bind_text(stmt, 8, track.duration, -1, Self.SQLITE_TRANSIENT)
            if let meta = track.metadata { sqlite3_bind_text(stmt, 9, meta, -1, Self.SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 9) }
            guard sqlite3_step(stmt) == SQLITE_DONE else { exec("ROLLBACK"); return }
        }
        exec("COMMIT")
    }

    public func rename(id: Int64, to newName: String) {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "UPDATE saved_queues SET name = ? WHERE id = ?",
                                 -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, newName, -1, Self.SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, id)
        sqlite3_step(stmt)
    }

    public func delete(id: Int64) {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "DELETE FROM saved_queues WHERE id = ?",
                                 -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_int64(stmt, 1, id)
        sqlite3_step(stmt)
    }

    // MARK: - Folders

    public func createFolder(name: String, parentID: Int64? = nil) -> Int64? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "INSERT INTO saved_queue_folders (name, created_at, parent_id) VALUES (?, ?, ?)",
                                 -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, name, -1, Self.SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
        if let parentID { sqlite3_bind_int64(stmt, 3, parentID) } else { sqlite3_bind_null(stmt, 3) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
        return sqlite3_last_insert_rowid(db)
    }

    /// Re-parents a folder. Guards against cycles (can't move a folder under
    /// itself or one of its own descendants). nil parent = top level.
    public func moveFolder(id: Int64, parentID: Int64?) {
        if let p = parentID, p == id || isDescendant(folderID: p, ofAncestor: id) { return }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "UPDATE saved_queue_folders SET parent_id = ? WHERE id = ?",
                                 -1, &stmt, nil) == SQLITE_OK else { return }
        if let parentID { sqlite3_bind_int64(stmt, 1, parentID) } else { sqlite3_bind_null(stmt, 1) }
        sqlite3_bind_int64(stmt, 2, id)
        sqlite3_step(stmt)
    }

    /// True when `folderID` is `ancestor` or sits somewhere below it.
    private func isDescendant(folderID: Int64, ofAncestor ancestor: Int64) -> Bool {
        let all = listFolders()
        var cur: Int64? = folderID
        var hops = 0
        while let c = cur, hops < 256 {
            if c == ancestor { return true }
            cur = all.first(where: { $0.id == c })?.parentID
            hops += 1
        }
        return false
    }

    /// Deep-copies a folder (its queues and sub-folders) into `intoParent`,
    /// appending " copy" only to the top folder's name. Returns the new id.
    public func copyFolder(id: Int64, intoParent: Int64? = nil, renameTop: Bool = true) -> Int64? {
        let all = listFolders()
        guard let src = all.first(where: { $0.id == id }) else { return nil }
        guard let newID = createFolder(name: renameTop ? "\(src.name) copy" : src.name, parentID: intoParent) else { return nil }
        // Copy this folder's direct queues.
        for q in list() where q.folderIDs.contains(id) {
            let ts = tracks(for: q.id)
            if let newQ = save(name: q.name, tracks: ts) { addToFolder(queueID: newQ, folderID: newID) }
        }
        // Recurse into sub-folders.
        for child in all where child.parentID == id {
            _ = copyFolder(id: child.id, intoParent: newID, renameTop: false)
        }
        return newID
    }

    public func renameFolder(id: Int64, to newName: String) {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "UPDATE saved_queue_folders SET name = ? WHERE id = ?",
                                 -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, newName, -1, Self.SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, id)
        sqlite3_step(stmt)
    }

    /// Deletes a folder. `ON DELETE SET NULL` orphans its queues back to the
    /// top level rather than destroying them.
    public func deleteFolder(id: Int64) {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "DELETE FROM saved_queue_folders WHERE id = ?",
                                 -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_int64(stmt, 1, id)
        sqlite3_step(stmt)
    }

    /// Duplicates a queue (and its tracks) as an independent copy, optionally
    /// placing the new copy in `folderID`. Returns the new queue id.
    @discardableResult
    public func copyQueue(id: Int64, toFolder folderID: Int64?) -> Int64? {
        let ts = tracks(for: id)
        guard let src = list().first(where: { $0.id == id }),
              let newID = save(name: src.name, tracks: ts) else { return nil }
        if let folderID { addToFolder(queueID: newID, folderID: folderID) }
        return newID
    }

    /// Sets a queue's membership to exactly `folderID` (or top level when nil).
    /// "Move" in the many-to-many world = replace all memberships.
    public func moveQueue(id: Int64, toFolder folderID: Int64?) {
        setFolders(queueID: id, folderIDs: folderID.map { [$0] } ?? [])
    }

    public func listFolders() -> [SavedQueueFolder] {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT id, name, parent_id FROM saved_queue_folders ORDER BY name COLLATE NOCASE",
                                 -1, &stmt, nil) == SQLITE_OK else { return [] }
        var out: [SavedQueueFolder] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(SavedQueueFolder(
                id: sqlite3_column_int64(stmt, 0),
                name: sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "",
                parentID: sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 2)))
        }
        return out
    }

    // MARK: - Reads

    /// All saved queues, newest first, with their folder memberships attached.
    public func list() -> [LocalSavedQueue] {
        let members = folderMemberships()
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, """
            SELECT q.id, q.name, q.created_at, COUNT(t.position)
            FROM saved_queues q
            LEFT JOIN saved_queue_tracks t ON t.queue_id = q.id
            GROUP BY q.id ORDER BY q.created_at DESC
            """, -1, &stmt, nil) == SQLITE_OK else { return [] }
        var out: [LocalSavedQueue] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            out.append(LocalSavedQueue(
                id: id,
                name: sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "",
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                trackCount: Int(sqlite3_column_int(stmt, 3)),
                folderIDs: members[id] ?? []
            ))
        }
        return out
    }

    // MARK: - Folder membership (many-to-many)

    /// queueID → [folderID].
    public func folderMemberships() -> [Int64: [Int64]] {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        var map: [Int64: [Int64]] = [:]
        guard sqlite3_prepare_v2(db, "SELECT queue_id, folder_id FROM saved_queue_folder_members", -1, &stmt, nil) == SQLITE_OK else { return map }
        while sqlite3_step(stmt) == SQLITE_ROW {
            map[sqlite3_column_int64(stmt, 0), default: []].append(sqlite3_column_int64(stmt, 1))
        }
        return map
    }

    public func foldersForQueue(_ id: Int64) -> [Int64] { folderMemberships()[id] ?? [] }

    /// Adds a queue to a folder (idempotent).
    public func addToFolder(queueID: Int64, folderID: Int64) {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO saved_queue_folder_members (queue_id, folder_id) VALUES (?, ?)", -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_int64(stmt, 1, queueID); sqlite3_bind_int64(stmt, 2, folderID)
        sqlite3_step(stmt)
    }

    public func removeFromFolder(queueID: Int64, folderID: Int64) {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "DELETE FROM saved_queue_folder_members WHERE queue_id = ? AND folder_id = ?", -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_int64(stmt, 1, queueID); sqlite3_bind_int64(stmt, 2, folderID)
        sqlite3_step(stmt)
    }

    /// Replaces all of a queue's memberships (empty = top level).
    public func setFolders(queueID: Int64, folderIDs: [Int64]) {
        var del: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM saved_queue_folder_members WHERE queue_id = ?", -1, &del, nil) == SQLITE_OK {
            sqlite3_bind_int64(del, 1, queueID); sqlite3_step(del)
        }
        sqlite3_finalize(del)
        for fid in folderIDs { addToFolder(queueID: queueID, folderID: fid) }
    }

    /// Tracks for one saved queue, in stored order.
    public func tracks(for id: Int64) -> [QueueItem] {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, """
            SELECT position, title, artist, album, art_url, uri, duration, metadata
            FROM saved_queue_tracks WHERE queue_id = ? ORDER BY position
            """, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_int64(stmt, 1, id)
        var out: [QueueItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(QueueItem(
                id: Int(sqlite3_column_int(stmt, 0)),
                title: sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "",
                artist: sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "",
                album: sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "",
                albumArtURI: sqlite3_column_text(stmt, 4).map { String(cString: $0) },
                duration: sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? "",
                uri: sqlite3_column_text(stmt, 5).map { String(cString: $0) },
                metadata: sqlite3_column_text(stmt, 7).map { String(cString: $0) }
            ))
        }
        return out
    }

    // MARK: - Helpers

    /// Idempotent column migration. Checks `PRAGMA table_info` first so an
    /// already-applied migration is a clean no-op instead of an `ALTER` that
    /// fails with "duplicate column name" and logs a false `.error` on every
    /// launch after the first (the column persists; only first launch needs it).
    private func addColumnIfMissing(table: String, column: String, definition: String) {
        guard !columnExists(table: table, column: column) else { return }
        exec("ALTER TABLE \(table) ADD COLUMN \(definition)")
    }

    private func columnExists(table: String, column: String) -> Bool {
        var stmt: OpaquePointer?
        defer { if stmt != nil { sqlite3_finalize(stmt) } }
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK else { return false }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 1), String(cString: c) == column { return true }
        }
        return false
    }

    private func exec(_ sql: String) {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            sonosDiagLog(.error, tag: "SAVEDQ",
                         "SQL failed: \(String(cString: sqlite3_errmsg(db)))",
                         context: ["sql": String(sql.prefix(60))])
        }
    }
}
