/// SQLite-backed ring buffer for diagnostic events. Bounded by both
/// time (30-day TTL) and count (5,000 entries) so a runaway error
/// storm can't fill disk.
import Foundation
import SQLite3

public enum DiagnosticLevel: String, Codable, Sendable {
    /// Verbose runtime tracing for development. **Not persisted** to
    /// the diagnostics SQLite store — `DiagnosticsService.log` drops
    /// these on the floor so the ring buffer (5 000-entry cap, 30-day
    /// TTL) doesn't get saturated by background-noise events
    /// (per-track iTunes art-search misses were burying real
    /// warnings within minutes).
    case debug
    case info, warning, error
}

public struct DiagnosticEntry: Identifiable, Sendable {
    public let id: Int64
    public let timestamp: Date
    public let level: DiagnosticLevel
    public let tag: String
    public let message: String
    public let contextJSON: String?
}

public final class DiagnosticsRepository: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "diagnostics-repo", qos: .utility)

    private static let retentionSeconds: TimeInterval = 30 * 24 * 60 * 60
    private static let hardCap = 5_000

    public init(dbPath: String) {
        // Stays on sonosDebugLog (sidecar): this fires before
        // `DiagnosticsService.attach(repository:)` runs, so routing it
        // through `sonosDiagLog` would no-op against a service with no
        // repo attached. If the diag DB itself is broken, the sidecar
        // log is the only surviving record.
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            sonosDebugLog("[DIAG-REPO] open failed at \(dbPath): \(String(cString: sqlite3_errmsg(db)))")
            return
        }
        let create = """
        CREATE TABLE IF NOT EXISTS diagnostics (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts INTEGER NOT NULL,
            level TEXT NOT NULL,
            tag TEXT NOT NULL,
            message TEXT NOT NULL,
            context_json TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_diagnostics_ts ON diagnostics(ts DESC);
        """
        if sqlite3_exec(db, create, nil, nil, nil) != SQLITE_OK {
            sonosDebugLog("[DIAG-REPO] schema failed: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    deinit {
        if db != nil { sqlite3_close(db) }
    }

    public func insert(level: DiagnosticLevel, tag: String, message: String, contextJSON: String?) {
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            var stmt: OpaquePointer?
            defer { if stmt != nil { sqlite3_finalize(stmt) } }
            let sql = "INSERT INTO diagnostics (ts, level, tag, message, context_json) VALUES (?, ?, ?, ?, ?)"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_int64(stmt, 1, Int64(Date().timeIntervalSince1970))
            sqlite3_bind_text(stmt, 2, level.rawValue, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, tag, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, message, -1, Self.SQLITE_TRANSIENT)
            if let ctx = contextJSON {
                sqlite3_bind_text(stmt, 5, ctx, -1, Self.SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 5)
            }
            _ = sqlite3_step(stmt)
        }
    }

    public func recent(limit: Int = 1000) -> [DiagnosticEntry] {
        queue.sync {
            guard let db else { return [] }
            var stmt: OpaquePointer?
            defer { if stmt != nil { sqlite3_finalize(stmt) } }
            let sql = "SELECT id, ts, level, tag, message, context_json FROM diagnostics ORDER BY ts DESC LIMIT ?"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            sqlite3_bind_int(stmt, 1, Int32(limit))
            var out: [DiagnosticEntry] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let ts = sqlite3_column_int64(stmt, 1)
                let levelRaw = String(cString: sqlite3_column_text(stmt, 2))
                let tag = String(cString: sqlite3_column_text(stmt, 3))
                let message = String(cString: sqlite3_column_text(stmt, 4))
                let ctx: String? = sqlite3_column_type(stmt, 5) == SQLITE_NULL
                    ? nil : String(cString: sqlite3_column_text(stmt, 5))
                out.append(DiagnosticEntry(
                    id: id,
                    timestamp: Date(timeIntervalSince1970: TimeInterval(ts)),
                    level: DiagnosticLevel(rawValue: levelRaw) ?? .info,
                    tag: tag,
                    message: message,
                    contextJSON: ctx
                ))
            }
            return out
        }
    }

    public func clearAll() {
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            _ = sqlite3_exec(db, "DELETE FROM diagnostics", nil, nil, nil)
        }
    }

    /// Drop entries older than `retentionSeconds` and trim the tail to
    /// `hardCap`. Call once at app startup; cheap because both clauses
    /// hit the indexed `ts` column.
    public func purgeStale() {
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            let cutoff = Int64(Date().timeIntervalSince1970 - Self.retentionSeconds)
            var stmt: OpaquePointer?
            defer { if stmt != nil { sqlite3_finalize(stmt) } }
            if sqlite3_prepare_v2(db, "DELETE FROM diagnostics WHERE ts < ?", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(stmt, 1, cutoff)
                _ = sqlite3_step(stmt)
            }
            // Cap: if more rows than hardCap survive, drop the oldest.
            let trim = """
            DELETE FROM diagnostics WHERE id IN (
                SELECT id FROM diagnostics ORDER BY ts DESC LIMIT -1 OFFSET \(Self.hardCap)
            )
            """
            _ = sqlite3_exec(db, trim, nil, nil, nil)
        }
    }

    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
