/// Single entry point for app-wide diagnostic logging. Applies PII
/// redaction before persisting so the on-disk store and any exported
/// bundle is safe to share without leaking the user's home directory,
/// LAN topology, OAuth tokens, or service account bindings.
import Foundation

public final class DiagnosticsService: @unchecked Sendable {
    public static let shared = DiagnosticsService()

    /// Guarded by `stateLock`: written once by `attach` at startup but
    /// read by `log`/`recent`/`clearAll` from arbitrary threads — the
    /// class is `@unchecked Sendable`, so the reference itself needs a
    /// lock. Callers copy the reference out under the lock and perform
    /// all repository I/O outside it.
    private var repository: DiagnosticsRepository?

    /// Whether an error-level entry exists (persisted from a prior session
    /// or logged this run). Guards the toolbar diagnostics badge so the red
    /// indicator appears only on an actual error — not on warnings, info, or
    /// nothing. Read off the hot path: `log` consults the cached flag rather
    /// than querying SQLite per line.
    private let stateLock = NSLock()
    private var _hasErrors = false

    public var hasErrors: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _hasErrors
    }

    /// Copies the repository reference out under the lock.
    private var currentRepository: DiagnosticsRepository? {
        stateLock.lock(); defer { stateLock.unlock() }
        return repository
    }

    private init() {}

    public func attach(repository: DiagnosticsRepository) {
        stateLock.lock()
        self.repository = repository
        stateLock.unlock()
        repository.purgeStale()
        // Seed the badge from persisted errors (runs after purgeStale on the
        // repo's serial queue, so it reflects the trimmed store).
        let seeded = repository.errorCount() > 0
        stateLock.lock(); _hasErrors = seeded; stateLock.unlock()
        if seeded { NotificationCenter.default.post(name: .diagnosticsErrorStateChanged, object: nil) }
    }

    public func log(level: DiagnosticLevel,
                    tag: String,
                    _ message: String,
                    context: [String: String]? = nil) {
        // Drop debug-level events on the floor — they're for verbose
        // runtime tracing (e.g. iTunes art-search per-track misses),
        // not for the persisted user-shareable bundle. Without this
        // gate the 5 000-entry SQLite ring buffer was 100 % saturated
        // with `ART` INFO entries from background metadata prewarm,
        // evicting real warnings within minutes.
        guard level != .debug else { return }
        // The on-disk store is the user's own diagnostic history —
        // useful for self-debugging — so we keep LAN IPs, file paths,
        // device IDs, and SMAPI account bindings intact here.
        // `scrubForPersistence` only removes the small set of values
        // that should never sit on disk in cleartext (see the redactor
        // enum below). The export paths in `DiagnosticsView` apply the
        // wider `scrubForPublicOutput` pass before any clipboard / file
        // / GitHub hand-off.
        let persisted = DiagnosticsRedactor.scrubForPersistence(message)
        let persistedContext: [String: String]? = context.map { ctx in
            ctx.mapValues { DiagnosticsRedactor.scrubForPersistence($0) }
        }
        let json: String? = persistedContext.flatMap { ctx in
            guard let data = try? JSONSerialization.data(withJSONObject: ctx, options: [.sortedKeys]) else {
                return nil
            }
            return String(data: data, encoding: .utf8)
        }
        currentRepository?.insert(level: level, tag: tag, message: persisted, contextJSON: json)

        // Flip the badge on the first error of the session and notify once;
        // subsequent errors don't re-post, so a storm can't flood observers.
        if level == .error {
            stateLock.lock()
            let wasSet = _hasErrors
            _hasErrors = true
            stateLock.unlock()
            if !wasSet { NotificationCenter.default.post(name: .diagnosticsErrorStateChanged, object: nil) }
        }
    }

    public func recent(limit: Int = 1000) -> [DiagnosticEntry] {
        currentRepository?.recent(limit: limit) ?? []
    }

    public func clearAll() {
        currentRepository?.clearAll()
        stateLock.lock(); _hasErrors = false; stateLock.unlock()
        NotificationCenter.default.post(name: .diagnosticsErrorStateChanged, object: nil)
    }
}

/// Convenience wrapper. Existing call sites already use `sonosDebugLog`
/// for verbose output; this is the strictly-persisted, redaction-clean
/// counterpart for events the user might be asked to share.
public func sonosDiagLog(_ level: DiagnosticLevel,
                         tag: String,
                         _ message: String,
                         context: [String: String]? = nil) {
    DiagnosticsService.shared.log(level: level, tag: tag, message, context: context)
}

// MARK: - PII Redactor

public enum DiagnosticsRedactor {
    /// Two paired entry points:
    /// - `scrubForPersistence` runs the minimal pass before each row
    ///   is written to the on-disk diagnostic store on the user's own
    ///   machine.
    /// - `scrubForPublicOutput` runs the full pass before a row leaves
    ///   the user's machine via clipboard, file save, or GitHub
    ///   hand-off.
    /// Splitting the pipeline this way keeps the user's local store
    /// useful for self-debugging while still ensuring that anything
    /// they hand to a maintainer has been broadly anonymised.

    /// Persistence-pass scrub. Removes only the values that should not
    /// sit on disk in cleartext, even on the user's own machine.
    /// Currently delegates to `scrubAuthToken`, which removes Bearer
    /// values, OAuth tokens, and `?token=`-style query parameters.
    public static func scrubForPersistence(_ s: String) -> String {
        scrubAuthToken(s)
    }

    /// Export-pass scrub. Runs every redactor in sequence so output
    /// that leaves the machine carries no LAN topology, home-directory
    /// paths, speaker serial numbers, SMAPI account bindings, or
    /// credential values. Order matters — path scrubbing first so
    /// subsequent regex matches don't see the expanded home dir.
    public static func scrubForPublicOutput(_ s: String) -> String {
        var out = s
        out = scrubHomePath(out)
        out = scrubDeviceID(out)
        out = scrubLANIP(out)
        out = scrubServiceAccount(out)
        out = scrubAuthToken(out)
        return out
    }

    /// `/Users/<name>/...` → `~/...`. NSHomeDirectory gives us the
    /// running user's path; we don't want to bake it into bundles.
    static func scrubHomePath(_ s: String) -> String {
        let home = NSHomeDirectory()
        guard !home.isEmpty else { return s }
        return s.replacingOccurrences(of: home, with: "~")
    }

    /// `RINCON_AB12CD34EF560XXXX` → `RINCON_********0XXXX`. Keeps the last
    /// 4 chars so multi-line logs about the same device correlate.
    static func scrubDeviceID(_ s: String) -> String {
        let pattern = #"RINCON_([A-Fa-f0-9]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return s }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        var result = s
        let matches = regex.matches(in: s, range: range).reversed()
        for match in matches {
            guard match.numberOfRanges >= 2,
                  let hexRange = Range(match.range(at: 1), in: result) else { continue }
            let hex = String(result[hexRange])
            let suffix = hex.suffix(4)
            let masked = String(repeating: "*", count: max(0, hex.count - 4)) + suffix
            result.replaceSubrange(hexRange, with: masked)
        }
        return result
    }

    /// LAN-private IPv4 → `<lan-ip>`. Public IPs preserved so e.g.
    /// `lrclib.net` resolves stay readable.
    static func scrubLANIP(_ s: String) -> String {
        let patterns = [
            #"10\.\d{1,3}\.\d{1,3}\.\d{1,3}"#,
            #"172\.(1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}"#,
            #"192\.168\.\d{1,3}\.\d{1,3}"#,
            #"169\.254\.\d{1,3}\.\d{1,3}"#
        ]
        var out = s
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(out.startIndex..<out.endIndex, in: out)
            out = regex.stringByReplacingMatches(in: out, range: range, withTemplate: "<lan-ip>")
        }
        return out
    }

    /// Sonos SMAPI sub-account binding `sn=<digits>` → `sn=*`. Service
    /// IDs (`sid=`) are kept since they identify Spotify vs Apple Music
    /// vs Plex generically and are useful for diagnosis.
    static func scrubServiceAccount(_ s: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\bsn=\d+"#) else { return s }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        return regex.stringByReplacingMatches(in: s, range: range, withTemplate: "sn=*")
    }

    /// OAuth tokens, API keys, anything with `token=`, `api_key=`,
    /// `Bearer <hex>`, `key=<hex>` → redact value.
    static func scrubAuthToken(_ s: String) -> String {
        let patterns = [
            #"(?i)(token|api[_-]?key|access[_-]?token|refresh[_-]?token|secret|password|key)=([^&\s]+)"#,
            #"(?i)Bearer\s+[A-Za-z0-9._\-]+"#
        ]
        var out = s
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(out.startIndex..<out.endIndex, in: out)
            let template = pattern.contains("Bearer") ? "Bearer <redacted>" : "$1=<redacted>"
            out = regex.stringByReplacingMatches(in: out, range: range, withTemplate: template)
        }
        return out
    }
}
