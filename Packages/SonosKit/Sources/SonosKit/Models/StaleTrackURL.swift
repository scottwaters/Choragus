/// StaleTrackURL.swift — Recognises playback URLs that have expired.
///
/// Controller-authenticated services (TIDAL, Qobuz, Suno) are played from a
/// pre-signed CDN URL resolved by `getMediaURI` at enqueue time, not from a
/// service URI the speaker resolves itself. Those URLs carry an expiry, and
/// once it passes the speaker fetches nothing, advances immediately and
/// reports `STOPPED / OK` — no UPnP fault, no error state. A saved queue or a
/// history snapshot holding such URLs therefore rots silently.
///
/// This type answers two questions about a URL, and deliberately refuses to
/// guess beyond them:
///   - Has it definitely expired? (`expiry` is readable and in the past)
///   - Could it expire at all? (`carriesRotatingCredential`)
///
/// A URL with an opaque token and no readable expiry returns `nil` from
/// `expiry` — unknown, not "valid". Callers treat unknown as worth
/// re-resolving only after playback has failed.
import Foundation

public enum StaleTrackURL {
    /// Query parameters that carry an absolute expiry instant, in the order
    /// they should be trusted. Values are epoch seconds or milliseconds.
    private static let expiryParameters = [
        "Expires", "expires", "exp", "oauth2_expiry", "X-Amz-Expires"
    ]

    /// Query parameters whose presence means the URL is signed and therefore
    /// perishable, whether or not the expiry itself is readable.
    private static let credentialParameters = [
        "token", "sig", "signature", "hdnts", "X-Amz-Signature", "Policy", "Key-Pair-Id"
    ]

    /// Epoch values above this are milliseconds, not seconds: it is the year
    /// 5138 read as seconds, and 2001 read as milliseconds. No real expiry
    /// falls between those, so the threshold separates the two encodings
    /// without needing to know which the service used.
    private static let millisecondThreshold: Double = 100_000_000_000

    /// True for a URL the speaker fetches directly over HTTP rather than a
    /// Sonos service URI it resolves itself. Only these can go stale.
    public static func isDirectStream(_ uri: String) -> Bool {
        uri.hasPrefix("http://") || uri.hasPrefix("https://")
    }

    /// The instant this URL stops being valid, when it states one.
    ///
    /// `X-Amz-Expires` is a lifetime in seconds rather than an instant, so it
    /// is combined with `X-Amz-Date`; without that companion it is unreadable
    /// and returns nil rather than a fabricated instant.
    public static func expiry(in uri: String) -> Date? {
        let params = queryParameters(of: uri)
        // Akamai-style short tokens carry the expiry as their leading field:
        // `token=1787287532~<hmac>` (TIDAL's lgf CDN uses exactly this), and
        // `hdnts=st=...~exp=1787287532~acl=...`. Neither is a standalone
        // parameter, so the loop below never sees them.
        if let token = params["token"], let mark = token.firstIndex(of: "~"),
           let epoch = Double(token[..<mark]), epoch > 1_000_000_000 {
            return Date(timeIntervalSince1970: epoch > millisecondThreshold ? epoch / 1000 : epoch)
        }
        if let hdnts = params["hdnts"] {
            for field in hdnts.split(separator: "~") {
                if field.hasPrefix("exp="), let epoch = Double(field.dropFirst(4)) {
                    return Date(timeIntervalSince1970: epoch > millisecondThreshold ? epoch / 1000 : epoch)
                }
            }
        }
        for name in expiryParameters {
            guard let raw = params[name], let value = Double(raw) else { continue }
            if name == "X-Amz-Expires" {
                guard let signed = amazonSignedDate(params["X-Amz-Date"]) else { continue }
                return signed.addingTimeInterval(value)
            }
            guard value > 0 else { continue }
            let seconds = value > millisecondThreshold ? value / 1000 : value
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }

    /// True when the URL states an expiry and that expiry has passed.
    ///
    /// `tolerance` absorbs clock skew between this Mac and the signing
    /// service: a URL within tolerance of expiry is not yet called expired,
    /// because a false positive discards a URL that would have played.
    public static func isExpired(_ uri: String, now: Date = Date(),
                                tolerance: TimeInterval = 30) -> Bool {
        guard let expiry = expiry(in: uri) else { return false }
        return now.timeIntervalSince(expiry) > tolerance
    }

    /// True when the URL is signed and will expire at some point, whether or
    /// not the expiry instant is readable. A queue full of these is worth
    /// re-resolving once playback has failed, even where `expiry` is nil.
    public static func carriesRotatingCredential(_ uri: String) -> Bool {
        guard isDirectStream(uri) else { return false }
        let params = queryParameters(of: uri)
        return credentialParameters.contains { params[$0] != nil }
    }

    /// True when this URL cannot be trusted to play: it has definitely
    /// expired, or it is signed and the caller has already seen it fail.
    public static func isStale(_ uri: String, playbackFailed: Bool = false,
                              now: Date = Date()) -> Bool {
        guard isDirectStream(uri) else { return false }
        if isExpired(uri, now: now) { return true }
        return playbackFailed && carriesRotatingCredential(uri)
    }

    // MARK: - Parsing

    /// Query parameters of `uri`, unescaped. Hand-rolled rather than
    /// `URLComponents` because a resolved CDN URL can carry characters that
    /// make `URLComponents` return nil outright, and losing the whole URL to
    /// one unencoded character would read as "never expires".
    private static func queryParameters(of uri: String) -> [String: String] {
        guard let mark = uri.firstIndex(of: "?") else { return [:] }
        let query = uri[uri.index(after: mark)...]
        var found: [String: String] = [:]
        for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
            guard let equals = pair.firstIndex(of: "=") else { continue }
            let name = String(pair[..<equals])
            let value = String(pair[pair.index(after: equals)...])
            guard !name.isEmpty, found[name] == nil else { continue }
            found[name] = value.removingPercentEncoding ?? value
        }
        return found
    }

    /// `X-Amz-Date` in ISO 8601 basic form (`20260817T101530Z`).
    private static func amazonSignedDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: raw)
    }
}
