/// PlayHistoryManager.swift — Tracks play history with SQLite persistence and stats.
import Foundation
import SQLite3

@MainActor
public final class PlayHistoryManager: ObservableObject {
    @Published public var entries: [PlayHistoryEntry] = []

    public var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: UDKey.playHistoryEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: UDKey.playHistoryEnabled); objectWillChange.send() }
    }

    private var db: OpaquePointer?
    private let dbPath: String
    private var lastLoggedTrack: [String: String] = [:]
    private var reloadTask: Task<Void, Never>?
    private static let maxEntries = 50_000

    // Legacy JSON path for migration
    private let legacyJSONURL: URL

    public init() {
        self.dbPath = AppPaths.appSupportDirectory.appendingPathComponent("play_history.sqlite").path
        self.legacyJSONURL = AppPaths.appSupportDirectory.appendingPathComponent("play_history.json")

        // Default to enabled
        if !UserDefaults.standard.bool(forKey: UDKey.playHistoryEnabledSet) {
            UserDefaults.standard.set(true, forKey: UDKey.playHistoryEnabled)
            UserDefaults.standard.set(true, forKey: UDKey.playHistoryEnabledSet)
        }

        openDatabase()
        migrateFromJSONIfNeeded()
        loadEntries()
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Database Setup

    private func openDatabase() {
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            sonosDebugLog("[HISTORY] Failed to open database: \(String(cString: sqlite3_errmsg(db)))")
            return
        }

        // WAL mode for better concurrent read performance
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

        exec("CREATE INDEX IF NOT EXISTS idx_history_timestamp ON history(timestamp)")
        exec("CREATE INDEX IF NOT EXISTS idx_history_artist ON history(artist)")
    }

    private func migrateFromJSONIfNeeded() {
        guard FileManager.default.fileExists(atPath: legacyJSONURL.path) else { return }
        guard let data = try? Data(contentsOf: legacyJSONURL),
              let jsonEntries = try? JSONDecoder().decode([PlayHistoryEntry].self, from: data),
              !jsonEntries.isEmpty else { return }

        sonosDebugLog("[HISTORY] Migrating \(jsonEntries.count) entries from JSON to SQLite")

        exec("BEGIN TRANSACTION")
        for entry in jsonEntries {
            insertEntry(entry)
        }
        exec("COMMIT")

        // Remove legacy file
        try? FileManager.default.removeItem(at: legacyJSONURL)
        sonosDebugLog("[HISTORY] Migration complete, removed JSON file")
    }

    // MARK: - CRUD

    private func insertEntry(_ entry: PlayHistoryEntry) {
        let sql = """
            INSERT OR IGNORE INTO history (id, timestamp, title, artist, album, station_name, source_uri, group_name, duration, album_art_uri)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        let idStr = entry.id.uuidString
        sqlite3_bind_text(stmt, 1, (idStr as NSString).utf8String, -1, nil)
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

    private func loadEntries() {
        entries.removeAll()
        let sql = "SELECT id, timestamp, title, artist, album, station_name, source_uri, group_name, duration, album_art_uri FROM history ORDER BY timestamp ASC"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
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
                albumArtURI: sqlite3_column_type(stmt, 9) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 9)) : nil
            )
            entries.append(entry)
        }

        pruneIfNeeded()
    }

    private func pruneIfNeeded() {
        guard entries.count > Self.maxEntries else { return }
        let toRemove = entries.count - Self.maxEntries
        let oldEntries = entries.prefix(toRemove)
        let sql = "DELETE FROM history WHERE id = ?"
        for entry in oldEntries {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            sqlite3_bind_text(stmt, 1, (entry.id.uuidString as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        entries.removeFirst(toRemove)
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Timing.reloadDebounce)
            guard !Task.isCancelled, let self else { return }
            self.loadEntries()
        }
    }

    /// Called by SonosManager when track metadata changes
    public func trackMetadataChanged(groupID: String, metadata: TrackMetadata,
                                     groupName: String, transportState: TransportState) {
        guard isEnabled else { return }
        guard transportState == .playing else { return }
        guard !metadata.title.isEmpty else { return }

        // Normalize whitespace for dedup (radio streams often vary trailing spaces)
        let normTitle = metadata.title.trimmingCharacters(in: .whitespaces)
        let normArtist = metadata.artist.trimmingCharacters(in: .whitespaces)
        let dedupKey = "\(normTitle)|\(normArtist)|\(groupID)"
        guard lastLoggedTrack[groupID] != dedupKey else { return }

        // For radio/streaming, also check DB to avoid duplicates across app restarts
        if !metadata.stationName.isEmpty || (metadata.trackURI.map { URIPrefix.isRadio($0) } ?? false) {
            let fiveMinAgo = Date().timeIntervalSince1970 - 300
            if hasRecentEntry(title: normTitle, artist: normArtist, groupName: groupName, since: fiveMinAgo) {
                lastLoggedTrack[groupID] = dedupKey
                return
            }
        }

        lastLoggedTrack[groupID] = dedupKey

        let entry = PlayHistoryEntry(
            title: metadata.title,
            artist: metadata.artist,
            album: metadata.album,
            stationName: metadata.stationName,
            sourceURI: metadata.trackURI,
            groupName: groupName,
            duration: metadata.duration,
            albumArtURI: metadata.albumArtURI
        )
        insertEntry(entry)
        entries.append(entry)
    }

    /// Updates the album art URI for the most recent entry matching title+artist on a group
    public func updateArtwork(forTitle title: String, artist: String, artURL: String) {
        // Update in-memory
        for i in entries.indices.reversed() {
            if entries[i].title == title && entries[i].artist == artist {
                guard entries[i].albumArtURI != artURL else { return }
                entries[i].albumArtURI = artURL
                // Update in database
                let sql = "UPDATE history SET album_art_uri = ? WHERE id = ?"
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_text(stmt, 1, (artURL as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (entries[i].id.uuidString as NSString).utf8String, -1, nil)
                if sqlite3_step(stmt) != SQLITE_DONE {
                    sonosDebugLog("[HISTORY] Update art failed: \(String(cString: sqlite3_errmsg(db)))")
                }
                return
            }
        }
    }

    public func clearHistory() {
        entries.removeAll()
        lastLoggedTrack.removeAll()
        exec("DELETE FROM history")
    }

    /// Checks if a matching entry was logged recently (used to dedup radio across restarts)
    private func hasRecentEntry(title: String, artist: String, groupName: String, since: TimeInterval) -> Bool {
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

    private func exec(_ sql: String) {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            sonosDebugLog("[HISTORY] SQL error: \(String(cString: sqlite3_errmsg(db))) for: \(sql)")
        }
    }

    // MARK: - Stats

    public var totalEntries: Int { entries.count }

    public var totalListeningHours: Double {
        entries.reduce(0) { $0 + $1.duration } / 3600.0
    }

    public var uniqueArtists: [String] {
        Array(Set(entries.compactMap { $0.artist.isEmpty ? nil : $0.artist })).sorted()
    }

    public var uniqueRooms: [String] {
        Array(Set(entries.compactMap { $0.groupName.isEmpty ? nil : $0.groupName })).sorted()
    }

    /// Returns the most recent unique tracks/stations, deduplicated.
    public func recentlyPlayed(limit: Int = 20) -> [PlayHistoryEntry] {
        var seen = Set<String>()
        var seenStations = Set<String>()
        var result: [PlayHistoryEntry] = []
        for entry in entries.reversed() {
            guard !entry.title.isEmpty else { continue }

            if !entry.stationName.isEmpty {
                let key = "station:\(entry.stationName)"
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                seenStations.insert(entry.stationName)
                var stationEntry = entry
                stationEntry.title = entry.stationName
                result.append(stationEntry)
            } else if let uri = entry.sourceURI, URIPrefix.isRadio(uri) {
                continue
            } else {
                let key = "track:\(entry.title)|\(entry.artist)"
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                result.append(entry)
            }

            if result.count >= limit { break }
        }
        return result
    }

    /// Determines service name from a history entry's source URI
    public func sourceServiceName(for entry: PlayHistoryEntry) -> String {
        if !entry.stationName.isEmpty { return entry.stationName }
        guard let uri = entry.sourceURI else { return ServiceName.local }
        if URIPrefix.isLocal(uri) { return ServiceName.musicLibrary }
        if URIPrefix.isRadio(uri) { return ServiceName.radio }
        let decoded = (uri.removingPercentEncoding ?? uri).replacingOccurrences(of: "&amp;", with: "&")
        if let range = decoded.range(of: "sid=") {
            let numStr = String(decoded[range.upperBound...].prefix(while: { $0.isNumber }))
            if let sid = Int(numStr), let name = ServiceID.knownNames[sid] { return name }
        }
        if decoded.contains("spotify") { return ServiceName.spotify }
        return ServiceName.streaming
    }

    /// Plays per day for the last N days (fills in zeros for days with no plays)
    public func dailyActivity(days: Int = 30) -> [(Date, Int)] {
        let calendar = Calendar.current
        let now = Date()
        var counts: [Date: Int] = [:]
        for entry in entries {
            let day = calendar.startOfDay(for: entry.timestamp)
            counts[day, default: 0] += 1
        }
        return (0..<days).reversed().map { offset in
            let day = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -offset, to: now)!)
            return (day, counts[day] ?? 0)
        }
    }

    /// Plays per hour of day (0-23) across all history
    public var hourlyDistribution: [(Int, Int)] {
        let calendar = Calendar.current
        var counts = [Int](repeating: 0, count: 24)
        for entry in entries {
            let hour = calendar.component(.hour, from: entry.timestamp)
            counts[hour] += 1
        }
        return counts.enumerated().map { ($0.offset, $0.element) }
    }

    /// Peak listening hour
    public var peakHour: Int {
        hourlyDistribution.max(by: { $0.1 < $1.1 })?.0 ?? 12
    }

    /// Source distribution for pie chart
    public var sourceDistribution: [(String, Int)] {
        var counts: [String: Int] = [:]
        for entry in entries {
            let source = sourceServiceName(for: entry)
            counts[source, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }
    }

    public var mostPlayedArtists: [(String, Int)] {
        var counts: [String: Int] = [:]
        for e in entries where !e.artist.isEmpty {
            counts[e.artist, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }
    }

    public var mostPlayedTracks: [(String, String, Int)] {
        var counts: [String: Int] = [:]
        var trackArtist: [String: String] = [:]
        for e in entries where !e.title.isEmpty {
            let key = "\(e.title)|\(e.artist)"
            counts[key, default: 0] += 1
            trackArtist[key] = e.artist
        }
        return counts.sorted { $0.value > $1.value }.map { (key, count) in
            let parts = key.components(separatedBy: "|")
            return (parts[0], parts.count > 1 ? parts[1] : "", count)
        }
    }

    public var mostPlayedStations: [(String, Int)] {
        var counts: [String: Int] = [:]
        for e in entries where !e.stationName.isEmpty {
            counts[e.stationName, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }
    }

    // MARK: - Export

    public func exportCSV() -> String {
        let formatter = ISO8601DateFormatter()
        var csv = "Date,Title,Artist,Album,Station,Room,Duration\n"
        for e in entries {
            let date = formatter.string(from: e.timestamp)
            let dur = String(format: "%.0f", e.duration)
            csv += "\(csvEscape(date)),\(csvEscape(e.title)),\(csvEscape(e.artist)),\(csvEscape(e.album)),\(csvEscape(e.stationName)),\(csvEscape(e.groupName)),\(dur)\n"
        }
        return csv
    }

    private func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }
}
