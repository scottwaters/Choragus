/// LastFMClient.swift — REST wrapper for the Last.fm 2.0 API.
///
/// Implements the handful of methods the scrobbler actually needs:
/// - `auth.getToken`   — kick off desktop-auth flow
/// - `auth.getSession` — exchange the approved token for a session key
/// - `track.scrobble`  — batch submit (up to 50 tracks per call)
///
/// Signing: Last.fm signs every authenticated call by MD5-hashing a string
/// built from all parameters in ascending alphabetical order concatenated
/// with the shared secret. Only `api_key`, `format`, `callback`, and `sk`
/// are excluded from the signed string (well, `sk` is INcluded — see
/// `signatureString`). The `api_sig` parameter goes on every call.
///
/// Responses: the client asks for `format=json` so every response is a JSON
/// object. Success has top-level keys specific to the method. Errors have
/// `error` (int) + `message` (string). Several error codes are retryable
/// (-16, 16, 26, 29) per the docs; the scrobbler maps them accordingly.
import Foundation
import CryptoKit

public enum LastFMError: Error, LocalizedError {
    case missingCredentials
    case missingSession
    case http(Int, String)
    case service(Int, String)         // Last.fm application-level error
    case decoding(String)
    case invalidURL

    public var errorDescription: String? {
        switch self {
        case .missingCredentials: return "Last.fm API credentials are not configured."
        case .missingSession:     return "Not signed in to Last.fm."
        case .http(let c, let b): return "Last.fm HTTP \(c): \(b)"
        case .service(let c, let m): return "Last.fm error \(c): \(m)"
        case .decoding(let m):    return "Last.fm response parse error: \(m)"
        case .invalidURL:         return "Invalid Last.fm URL."
        }
    }

    /// Which service-level error codes are worth retrying later.
    /// Per https://www.last.fm/api/errorcodes
    public var isRetryable: Bool {
        if case .http = self { return true }  // 5xx, network
        if case .service(let code, _) = self {
            return [-16, 8, 11, 16, 26, 29].contains(code)
        }
        return false
    }
}

/// Per-track outcome parsed from a `track.scrobble` batch response.
/// Last.fm's response embeds a `<scrobble>` element per submitted track
/// with an `ignored code` attribute — nonzero means the scrobble was
/// declined (timestamp too old, spam, filtered artist, etc.).
public struct ScrobbleAck {
    public let accepted: Bool
    public let ignoredCode: Int
    public let ignoredMessage: String
    public let artist: String
    public let track: String
}

@MainActor
public final class LastFMClient {
    public static let apiRoot = "https://ws.audioscrobbler.com/2.0/"
    public static let authURLTemplate = "https://www.last.fm/api/auth/?api_key=%@&token=%@"

    /// Sonos's `track.scrobble` takes up to 50 tracks per call.
    public static let maxBatchSize = 50

    private let tokenStore: LastFMTokenStore
    private let session: URLSession

    public init(tokenStore: LastFMTokenStore, session: URLSession = .shared) {
        self.tokenStore = tokenStore
        self.session = session
    }

    // MARK: - Auth flow

    /// Step 1 of the desktop auth flow: request an unauthorized token.
    /// Return it to the caller, who then opens
    /// `authorizeURL(token:)` in the user's browser to prompt approval.
    public func getAuthToken() async throws -> String {
        guard let apiKey = tokenStore.apiKey, !apiKey.isEmpty else {
            throw LastFMError.missingCredentials
        }
        let params: [String: String] = [
            "method": "auth.getToken",
            "api_key": apiKey,
        ]
        let json = try await callSigned(params: params)
        guard let token = (json["token"] as? String), !token.isEmpty else {
            throw LastFMError.decoding("auth.getToken response missing token")
        }
        return token
    }

    /// URL the user visits in their browser to approve the token. Last.fm
    /// redirects on approval but we poll instead of catching a redirect.
    public func authorizeURL(token: String) -> URL? {
        guard let apiKey = tokenStore.apiKey else { return nil }
        let urlString = String(format: Self.authURLTemplate, apiKey, token)
        return URL(string: urlString)
    }

    /// Step 2: once the user has approved the token in the browser, this
    /// exchanges it for a session key. Call repeatedly (polling) — returns
    /// `nil` for "not yet approved" so the caller can keep polling.
    /// Throws on other errors (invalid credentials, network failure).
    public func pollForSession(token: String) async throws -> (sessionKey: String, username: String)? {
        guard let apiKey = tokenStore.apiKey, !apiKey.isEmpty else {
            throw LastFMError.missingCredentials
        }
        let params: [String: String] = [
            "method": "auth.getSession",
            "api_key": apiKey,
            "token": token,
        ]
        do {
            let json = try await callSigned(params: params)
            guard let sessionObj = json["session"] as? [String: Any],
                  let key = sessionObj["key"] as? String, !key.isEmpty,
                  let name = sessionObj["name"] as? String else {
                throw LastFMError.decoding("auth.getSession response malformed")
            }
            return (key, name)
        } catch LastFMError.service(let code, _) where code == 14 {
            // Code 14 = unauthorized token (hasn't been approved yet).
            return nil
        }
    }

    // MARK: - Scrobble

    /// Submits up to 50 scrobbles in one call. Caller should chunk larger
    /// batches. Returns per-track acknowledgements in input order.
    public func scrobble(_ tracks: [LastFMScrobblePayload]) async throws -> [ScrobbleAck] {
        guard !tracks.isEmpty else { return [] }
        precondition(tracks.count <= Self.maxBatchSize, "Last.fm accepts at most 50 tracks per scrobble call")

        guard let apiKey = tokenStore.apiKey, !apiKey.isEmpty else { throw LastFMError.missingCredentials }
        guard let session = tokenStore.sessionKey, !session.isEmpty else { throw LastFMError.missingSession }

        var params: [String: String] = [
            "method": "track.scrobble",
            "api_key": apiKey,
            "sk": session,
        ]
        for (i, t) in tracks.enumerated() {
            params["artist[\(i)]"] = t.artist
            params["track[\(i)]"] = t.title
            params["timestamp[\(i)]"] = String(Int(t.timestamp.timeIntervalSince1970))
            if !t.album.isEmpty { params["album[\(i)]"] = t.album }
            if t.duration > 0 { params["duration[\(i)]"] = String(Int(t.duration)) }
        }

        let json = try await callSigned(params: params)
        return parseScrobbleAcks(json: json, inputCount: tracks.count)
    }

    // MARK: - Low-level POST + signing

    /// Builds the signed form-body, POSTs to `apiRoot`, decodes JSON,
    /// surfaces Last.fm application-level errors as `LastFMError.service`.
    @discardableResult
    private func callSigned(params: [String: String]) async throws -> [String: Any] {
        guard let sharedSecret = tokenStore.sharedSecret, !sharedSecret.isEmpty else {
            throw LastFMError.missingCredentials
        }
        guard let url = URL(string: Self.apiRoot) else { throw LastFMError.invalidURL }

        var signed = params
        signed["api_sig"] = sign(params: params, sharedSecret: sharedSecret)
        signed["format"] = "json"  // NOT signed (excluded by protocol)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncode(signed).data(using: .utf8)
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LastFMError.http(-1, "no HTTP response")
        }

        let bodyString = String(data: data, encoding: .utf8) ?? ""
        let json: [String: Any]
        do {
            json = try (JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        } catch {
            throw LastFMError.decoding(bodyString.prefix(200).description)
        }

        // Last.fm returns 200 even for app-level errors — check the error key.
        if let code = json["error"] as? Int {
            let msg = (json["message"] as? String) ?? "unknown"
            throw LastFMError.service(code, msg)
        }

        if !(200...299).contains(http.statusCode) {
            throw LastFMError.http(http.statusCode, bodyString.prefix(200).description)
        }
        return json
    }

    /// Builds the signed parameter string per Last.fm's rules:
    /// concatenate `name + value` for every parameter in ASCII sort order
    /// of the name, exclude `format` and `callback`, append the shared
    /// secret, MD5-hash the UTF-8 bytes, return lowercase hex.
    /// Exposed `internal` for unit tests.
    func sign(params: [String: String], sharedSecret: String) -> String {
        let ignore: Set<String> = ["format", "callback"]
        let sorted = params.filter { !ignore.contains($0.key) }
                           .sorted { $0.key < $1.key }
        let concat = sorted.map { $0.key + $0.value }.joined() + sharedSecret
        let digest = Insecure.MD5.hash(data: Data(concat.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Test hook for form-encoding assertions. The real call site is
    /// private above; keeping this separate avoids widening the API.
    func formEncodeForTests(_ params: [String: String]) -> String {
        formEncode(params)
    }

    /// RFC 3986 §2.3 "unreserved" characters — alphanumerics and `-._~`.
    /// These are the only bytes guaranteed to round-trip literally through
    /// every URL and form-urlencoded context. Using `urlQueryAllowed` as a
    /// starting point and picking what to remove is brittle: `urlQueryAllowed`
    /// leaves `+` literal (valid in a URL query) but `+` means space in a
    /// form body, which caused Last.fm signature mismatches for titles like
    /// "Mike + the Mechanics". Percent-encode anything outside this set.
    private static let formUnreserved: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    private func formEncode(_ params: [String: String]) -> String {
        params.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: Self.formUnreserved) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: Self.formUnreserved) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }

    /// Parses the per-track `<scrobble>` entries out of a `track.scrobble`
    /// response (even though we asked for JSON, Last.fm's scrobble response
    /// structure nests per-entry status under `scrobbles.scrobble`). When
    /// the batch is a single track, `scrobble` is an object, not an array.
    private func parseScrobbleAcks(json: [String: Any], inputCount: Int) -> [ScrobbleAck] {
        guard let scrobbles = json["scrobbles"] as? [String: Any] else { return [] }
        let rawEntries: [[String: Any]]
        if let arr = scrobbles["scrobble"] as? [[String: Any]] {
            rawEntries = arr
        } else if let obj = scrobbles["scrobble"] as? [String: Any] {
            rawEntries = [obj]
        } else {
            return []
        }
        return rawEntries.prefix(inputCount).map { entry in
            let ignoredInfo = entry["ignoredMessage"] as? [String: Any]
            let ignoredCodeStr = (ignoredInfo?["code"] as? String) ?? "0"
            let ignoredCode = Int(ignoredCodeStr) ?? 0
            let ignoredMsg = (ignoredInfo?["#text"] as? String) ?? ""
            let artist = ((entry["artist"] as? [String: Any])?["#text"] as? String) ?? ""
            let track = ((entry["track"] as? [String: Any])?["#text"] as? String) ?? ""
            return ScrobbleAck(
                accepted: ignoredCode == 0,
                ignoredCode: ignoredCode,
                ignoredMessage: ignoredMsg,
                artist: artist,
                track: track
            )
        }
    }
}

/// Payload for a single Last.fm scrobble. Mirrors the fields Last.fm's
/// `track.scrobble` action accepts.
public struct LastFMScrobblePayload {
    public let artist: String
    public let title: String
    public let album: String
    public let timestamp: Date
    public let duration: TimeInterval

    public init(
        artist: String, title: String, album: String = "",
        timestamp: Date, duration: TimeInterval = 0
    ) {
        self.artist = artist
        self.title = title
        self.album = album
        self.timestamp = timestamp
        self.duration = duration
    }
}
