/// PlexDirectClient.swift — Direct-to-PMS browse and search.
///
/// Bypasses the Sonos SMAPI relay (sid=212 → plex.tv → user's PMS) and
/// talks straight to the user's Plex Media Server at `<pms-ip>:32400/...`.
/// This is what every other Plex client does — it's faster, doesn't rely
/// on plex.tv's relay being healthy, and surfaces "PMS asleep" as a
/// concrete error instead of an empty list.
///
/// Auth is Plex's PIN flow: we ask plex.tv for an alphanumeric code
/// (length varies — Plex's strong-PIN generator returns 4–8 chars
/// depending on their current settings), the user types it at
/// plex.tv/link, we poll until it's claimed, and we keep the resulting
/// `authToken` in SecretsStore alongside SMAPI tokens. Server discovery
/// uses the same token against `clients.plex.tv/api/v2/resources` to
/// enumerate the user's owned servers and pick a reachable connection
/// (LAN preferred).
///
/// This file ships the client + a MainActor manager that owns the
/// auth/discovery state. UI surfaces (PIN sheet, library browse,
/// playback URL handoff) live in their own files and call into this.
import Foundation
import Combine

// MARK: - Models

public struct PlexPin {
    public let id: Int
    public let code: String
    public let createdAt: Date
}

public struct PlexServer {
    public let name: String
    public let clientIdentifier: String
    public let accessToken: String
    /// Connections in the order we tried them (LAN first, then remote).
    public let connections: [PlexConnection]
    public let owned: Bool
}

public struct PlexConnection {
    public let uri: String  // e.g. "https://192-168-100-50.aabbcc.plex.direct:32400"
    public let local: Bool
    public let relay: Bool
}

public struct PlexLibrarySection: Identifiable {
    public let id: String       // "1", "2", etc.
    public let title: String    // "Music", "Audiobooks"
    public let type: String     // "artist", "album", "track"
    public let agent: String?
}

public enum PlexBrowseKind {
    case artists
    case albums
    case tracks
    case childrenOf(ratingKey: String)  // album → tracks, artist → albums
}

public struct PlexMediaItem {
    public let ratingKey: String        // unique server-side ID, e.g. "12345"
    public let title: String
    public let type: String             // "artist", "album", "track"
    public let parentTitle: String?     // album for tracks, artist for albums
    public let grandparentTitle: String?// artist for tracks
    public let thumb: String?           // path like "/library/metadata/12345/thumb/167..."
    public let isContainer: Bool        // true for artist/album, false for track
    /// Path to the underlying media part — only present on tracks.
    /// Combine with the chosen base URI + auth token for the playback URL.
    public let partKey: String?
    public let durationMs: Int?

    public init(ratingKey: String, title: String, type: String,
                parentTitle: String?, grandparentTitle: String?,
                thumb: String?, isContainer: Bool, partKey: String?,
                durationMs: Int?) {
        self.ratingKey = ratingKey
        self.title = title
        self.type = type
        self.parentTitle = parentTitle
        self.grandparentTitle = grandparentTitle
        self.thumb = thumb
        self.isContainer = isContainer
        self.partKey = partKey
        self.durationMs = durationMs
    }
}

public enum PlexError: Error, LocalizedError {
    case notAuthenticated
    case noServersFound
    case networkError(Error)
    case httpError(Int, String)
    case parseError(String)
    case pinExpired
    case authPending  // PIN created but user hasn't claimed it yet

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated:    return "Plex isn't connected — sign in first."
        case .noServersFound:      return "No Plex servers found on this account."
        case .networkError(let e): return "Network error: \(e.localizedDescription)"
        case .httpError(let c, _): return "Plex returned HTTP \(c)."
        case .parseError(let m):   return "Couldn't parse Plex response: \(m)"
        case .pinExpired:          return "Plex sign-in code expired — try again."
        case .authPending:         return "Waiting for plex.tv/link…"
        }
    }
}

// MARK: - Client

/// Stateless HTTP client. Auth state lives on `PlexAuthManager` below.
public final class PlexDirectClient: Sendable {

    public static let shared = PlexDirectClient()

    private let session: URLSession
    /// Cached cross-launch UUID identifying THIS app installation.
    /// Plex requires this header on every call; if it changes between
    /// runs the user's existing PIN/server list shows duplicate clients.
    public let clientIdentifier: String

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8   // tight by design — we want
        config.timeoutIntervalForResource = 12 // a quick fallback to SMAPI
        self.session = URLSession(configuration: config)
        self.clientIdentifier = Self.loadOrCreateClientID()
    }

    private static let clientIDKey = "plex.clientIdentifier"

    private static func loadOrCreateClientID() -> String {
        if let existing = UserDefaults.standard.string(forKey: clientIDKey),
           !existing.isEmpty {
            return existing
        }
        let new = UUID().uuidString
        UserDefaults.standard.set(new, forKey: clientIDKey)
        return new
    }

    private func plexHeaders() -> [String: String] {
        let bundle = Bundle.main
        let version = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
        let device = ProcessInfo.processInfo.hostName
        return [
            "X-Plex-Client-Identifier": clientIdentifier,
            "X-Plex-Product":           "Choragus",
            "X-Plex-Device":            device,
            "X-Plex-Platform":          "macOS",
            "X-Plex-Version":           version,
            "Accept":                   "application/json",
        ]
    }

    // MARK: - Auth (PIN flow)

    /// Step 1: ask plex.tv for a fresh PIN. The user takes `code` to
    /// plex.tv/link. Code length varies (Plex's strong-PIN generator
    /// has changed between 4 and 8 chars across recent releases).
    public func createPin() async throws -> PlexPin {
        guard let url = URL(string: "https://plex.tv/api/v2/pins?strong=true") else {
            throw PlexError.parseError("invalid pin URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (k, v) in plexHeaders() { request.setValue(v, forHTTPHeaderField: k) }

        let (data, response) = try await dataAndCheck(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? Int,
              let code = json["code"] as? String else {
            // Don't dump the raw response body — Plex's error JSON can
            // include account email and other PII that has no business
            // sitting in a long-lived debug log.
            sonosDiagLog(.error, tag: "PLEX",
                         "createPin parse fail: missing id/code",
                         context: ["status": String((response as? HTTPURLResponse)?.statusCode ?? -1)])
            throw PlexError.parseError("missing id/code in pin response")
        }
        // Don't log `code` — it's the short-lived claim secret a third
        // party pastes into plex.tv/link to authorise this app. Even
        // 15 minutes is too long to leave it sitting in Console.app.
        sonosDebugLog("[PLEX] PIN created: id=\(id) status=\((response as? HTTPURLResponse)?.statusCode ?? -1)")
        return PlexPin(id: id, code: code, createdAt: Date())
    }

    /// Step 2: poll until the PIN's `authToken` is non-null. Returns nil
    /// while still pending; throws on hard errors / expiry.
    public func checkPin(_ pin: PlexPin) async throws -> String? {
        guard let url = URL(string: "https://plex.tv/api/v2/pins/\(pin.id)") else {
            throw PlexError.parseError("invalid pin lookup URL")
        }
        var request = URLRequest(url: url)
        for (k, v) in plexHeaders() { request.setValue(v, forHTTPHeaderField: k) }

        let (data, response) = try await dataAndCheck(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 {
            throw PlexError.pinExpired
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PlexError.parseError("non-JSON pin lookup")
        }
        // `authToken` is null until the user claims the code; once
        // claimed it's the long-lived token we keep.
        if let token = json["authToken"] as? String, !token.isEmpty {
            return token
        }
        return nil
    }

    // MARK: - Server discovery

    /// Lists all servers the account owns/has access to. Pick one with
    /// `pickReachableConnection` — we don't auto-pick because the
    /// caller may want to surface a multi-server picker.
    public func listServers(authToken: String) async throws -> [PlexServer] {
        guard let url = URL(string: "https://clients.plex.tv/api/v2/resources?includeHttps=1&includeRelay=1") else {
            throw PlexError.parseError("invalid resources URL")
        }
        var request = URLRequest(url: url)
        for (k, v) in plexHeaders() { request.setValue(v, forHTTPHeaderField: k) }
        request.setValue(authToken, forHTTPHeaderField: "X-Plex-Token")

        let (data, _) = try await dataAndCheck(for: request)
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw PlexError.parseError("non-array resources response")
        }
        var out: [PlexServer] = []
        for entry in arr {
            // `provides` is a comma-separated list — we want servers, not players.
            let provides = (entry["provides"] as? String) ?? ""
            guard provides.contains("server") else { continue }

            let name = (entry["name"] as? String) ?? "Plex Server"
            let cid = (entry["clientIdentifier"] as? String) ?? ""
            let token = (entry["accessToken"] as? String) ?? authToken
            let owned = (entry["owned"] as? Bool) ?? false
            let connsRaw = (entry["connections"] as? [[String: Any]]) ?? []
            // LAN before WAN before relay — fewer hops, fewer surprises.
            let conns: [PlexConnection] = connsRaw.compactMap { c in
                guard let uri = c["uri"] as? String else { return nil }
                let local = (c["local"] as? Bool) ?? false
                let relay = (c["relay"] as? Bool) ?? false
                return PlexConnection(uri: uri, local: local, relay: relay)
            }.sorted { lhs, rhs in
                if lhs.local != rhs.local { return lhs.local }
                if lhs.relay != rhs.relay { return !lhs.relay }
                return false
            }
            out.append(PlexServer(name: name, clientIdentifier: cid,
                                  accessToken: token, connections: conns, owned: owned))
        }
        sonosDebugLog("[PLEX] listServers found \(out.count) servers")
        return out
    }

    /// Probe each connection in order until one returns a 200 to
    /// `/identity`. Returns the working base URI (without trailing slash)
    /// or throws if none respond.
    public func pickReachableConnection(for server: PlexServer) async throws -> String {
        for conn in server.connections {
            let trimmed = conn.uri.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let url = URL(string: "\(trimmed)/identity") else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 4 // any single connection should answer fast
            for (k, v) in plexHeaders() { request.setValue(v, forHTTPHeaderField: k) }
            request.setValue(server.accessToken, forHTTPHeaderField: "X-Plex-Token")
            do {
                let (_, response) = try await session.data(for: request)
                if (response as? HTTPURLResponse)?.statusCode == 200 {
                    sonosDebugLog("[PLEX] picked connection: \(trimmed) (local=\(conn.local) relay=\(conn.relay))")
                    return trimmed
                }
            } catch {
                LocalNetworkPermissionMonitor.shared.record(error)
                continue
            }
        }
        throw PlexError.noServersFound
    }

    // MARK: - Browse & search

    public func listLibraries(baseURI: String, authToken: String) async throws -> [PlexLibrarySection] {
        let json = try await getJSON(baseURI: baseURI,
                                     path: "/library/sections",
                                     authToken: authToken)
        let directories = (json["MediaContainer"] as? [String: Any])?["Directory"] as? [[String: Any]] ?? []
        return directories.compactMap { dir -> PlexLibrarySection? in
            guard let key = dir["key"] as? String,
                  let title = dir["title"] as? String,
                  let type = dir["type"] as? String else { return nil }
            return PlexLibrarySection(id: key, title: title, type: type,
                                      agent: dir["agent"] as? String)
        }
    }

    public func browse(baseURI: String, authToken: String,
                       sectionID: String, kind: PlexBrowseKind,
                       offset: Int = 0, limit: Int = 50) async throws -> (items: [PlexMediaItem], total: Int) {
        let path: String
        switch kind {
        case .artists:                       path = "/library/sections/\(sectionID)/all?type=8"
        case .albums:                        path = "/library/sections/\(sectionID)/all?type=9"
        case .tracks:                        path = "/library/sections/\(sectionID)/all?type=10"
        case .childrenOf(let ratingKey):     path = "/library/metadata/\(ratingKey)/children"
        }
        let url = "\(path)\(path.contains("?") ? "&" : "?")X-Plex-Container-Start=\(offset)&X-Plex-Container-Size=\(limit)"
        return try await getMediaList(baseURI: baseURI, path: url, authToken: authToken)
    }

    public func search(baseURI: String, authToken: String,
                       query: String, limit: Int = 30) async throws -> [PlexMediaItem] {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        // /hubs/search returns grouped results (hubs of artists, albums, tracks).
        // /search is older + flatter — easier to consume here.
        let path = "/search?query=\(q)&limit=\(limit)"
        let result = try await getMediaList(baseURI: baseURI, path: path, authToken: authToken)
        return result.items
    }

    /// Mints a transient token (~6 min lifetime) for use in a playback
    /// URL. Limits blast radius if a Sonos URI cache leaks the token.
    ///
    /// Falls back to the long-lived `authToken` on ANY error: some PMS
    /// versions return HTTP 400 from `/security/token?type=transient`
    /// (it's a permissioned endpoint that not every account/server
    /// combo allows). The transient token is defense-in-depth — playing
    /// through with the long-lived token is functionally fine.
    public func transientToken(baseURI: String, authToken: String) async throws -> String {
        do {
            let json = try await getJSON(baseURI: baseURI,
                                         path: "/security/token?type=transient",
                                         authToken: authToken)
            if let token = json["token"] as? String, !token.isEmpty { return token }
            if let mc = json["MediaContainer"] as? [String: Any],
               let t = mc["token"] as? String, !t.isEmpty { return t }
            sonosDiagLog(.warning, tag: "PLEX",
                         "transientToken: unexpected JSON shape, falling back to auth token",
                         context: ["keys": json.keys.sorted().joined(separator: ",")])
            return authToken
        } catch {
            sonosDiagLog(.warning, tag: "PLEX",
                         "transientToken endpoint refused — falling back to long-lived token: \(error.localizedDescription)")
            return authToken
        }
    }

    // MARK: - Internal HTTP

    private func dataAndCheck(for request: URLRequest) async throws -> (Data, URLResponse) {
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch {
            LocalNetworkPermissionMonitor.shared.record(error)
            throw PlexError.networkError(error)
        }
        if let http = result.1 as? HTTPURLResponse, !(200...299).contains(http.statusCode), http.statusCode != 404 {
            let body = String(data: result.0, encoding: .utf8) ?? ""
            throw PlexError.httpError(http.statusCode, body)
        }
        return result
    }

    private func getJSON(baseURI: String, path: String, authToken: String) async throws -> [String: Any] {
        guard let url = URL(string: "\(baseURI)\(path)") else {
            throw PlexError.parseError("invalid url \(baseURI)\(path)")
        }
        var request = URLRequest(url: url)
        for (k, v) in plexHeaders() { request.setValue(v, forHTTPHeaderField: k) }
        request.setValue(authToken, forHTTPHeaderField: "X-Plex-Token")
        let (data, _) = try await dataAndCheck(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PlexError.parseError("non-JSON for \(path)")
        }
        return json
    }

    private func getMediaList(baseURI: String, path: String,
                              authToken: String) async throws -> (items: [PlexMediaItem], total: Int) {
        let json = try await getJSON(baseURI: baseURI, path: path, authToken: authToken)
        guard let mc = json["MediaContainer"] as? [String: Any] else {
            return ([], 0)
        }
        let totalSize = (mc["totalSize"] as? Int) ?? (mc["size"] as? Int) ?? 0
        // Plex returns items under different keys depending on type:
        // "Metadata" for tracks/albums/artists, "Directory" for sections.
        let metadata = (mc["Metadata"] as? [[String: Any]]) ?? []
        let items = metadata.compactMap(Self.parseMediaItem)
        return (items, totalSize)
    }

    private static func parseMediaItem(_ dict: [String: Any]) -> PlexMediaItem? {
        guard let ratingKey = dict["ratingKey"] as? String ?? (dict["ratingKey"] as? Int).map({ "\($0)" }),
              let title = dict["title"] as? String,
              let type = dict["type"] as? String else { return nil }
        let isContainer = (type == "artist" || type == "album" || type == "playlist")
        let media = (dict["Media"] as? [[String: Any]])?.first
        let part = (media?["Part"] as? [[String: Any]])?.first
        let partKey = part?["key"] as? String
        let durationMs = (dict["duration"] as? Int) ?? (media?["duration"] as? Int)
        return PlexMediaItem(
            ratingKey: ratingKey,
            title: title,
            type: type,
            parentTitle: dict["parentTitle"] as? String,
            grandparentTitle: dict["grandparentTitle"] as? String,
            thumb: dict["thumb"] as? String,
            isContainer: isContainer,
            partKey: partKey,
            durationMs: durationMs
        )
    }
}

// MARK: - Manager

/// Owns the persistent auth/discovery state. UI binds to this; browse
/// and playback code pulls `authToken` and `baseURI` off it.
@MainActor
public final class PlexAuthManager: ObservableObject {

    public static let shared = PlexAuthManager()

    private let client = PlexDirectClient.shared
    private let secrets = SecretsStore.shared

    /// Long-lived Plex auth token, persisted in SecretsStore. Empty
    /// string means "not connected".
    @Published public private(set) var authToken: String = ""

    /// Reachable base URI for the user's chosen server (no trailing slash).
    /// Re-discovered on demand if the cached one stops responding.
    @Published public private(set) var baseURI: String = ""

    @Published public private(set) var serverName: String = ""

    /// PIN flow state — drives the auth UI.
    @Published public private(set) var activePin: PlexPin?
    @Published public private(set) var pinPollError: String?
    @Published public private(set) var isPolling: Bool = false

    public var isAuthenticated: Bool { !authToken.isEmpty }

    private static let tokenKey = "plex.direct.authToken"
    private static let baseURIKey = "plex.direct.baseURI"
    private static let serverNameKey = "plex.direct.serverName"

    private init() {
        // Default the "prefer direct" toggle to true on first launch —
        // direct is the better experience when it works, and we let the
        // user fall back to the SMAPI relay via the toggle in
        // MusicServicesView if their PMS isn't reachable from the LAN.
        UserDefaults.standard.register(defaults: [UDKey.plexPreferDirect: true])
        // Tokens come out of the unified SecretsStore (one Keychain prompt
        // per dev rebuild, not one per service).
        if let stored = secrets.get(Self.tokenKey), !stored.isEmpty {
            self.authToken = stored
        }
        self.baseURI = UserDefaults.standard.string(forKey: Self.baseURIKey) ?? ""
        self.serverName = UserDefaults.standard.string(forKey: Self.serverNameKey) ?? ""
    }

    // MARK: - PIN flow

    private var pollTask: Task<Void, Never>?

    /// Builds the OAuth-style authorize URL the user should open.
    /// Strong PINs (which we use for security) aren't typeable codes —
    /// they're random tokens embedded in this URL. The user clicks the
    /// link, authorizes inside Plex's web UI, we poll until it lands.
    /// Reference: https://forums.plex.tv/t/authenticating-with-plex/609370
    public func authorizeURL() -> URL? {
        guard let pin = activePin else { return nil }
        let cid = client.clientIdentifier
        let code = pin.code
        // Fragment-encoded URL — Plex's auth page reads params from the
        // URL fragment, not the query string. Bracket chars in
        // `context[device][...]` must be percent-encoded.
        let encodedCode = code.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? code
        let encodedCID = cid.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? cid
        let raw = "https://app.plex.tv/auth#?clientID=\(encodedCID)&code=\(encodedCode)" +
                  "&context%5Bdevice%5D%5Bproduct%5D=Choragus" +
                  "&context%5Bdevice%5D%5Bplatform%5D=macOS"
        return URL(string: raw)
    }

    /// Starts a fresh PIN flow. Returns the strong code (long
    /// alphanumeric, NOT typeable at plex.tv/link). The user reaches
    /// the authorize page via `authorizeURL()`. The manager polls in
    /// the background until the user claims it (or `cancelPin` is
    /// called).
    public func startPin() async throws -> String {
        cancelPin()
        let pin = try await client.createPin()
        activePin = pin
        pinPollError = nil
        isPolling = true
        pollTask = Task { [weak self] in
            await self?.pollPinUntilDone(pin)
        }
        return pin.code
    }

    public func cancelPin() {
        pollTask?.cancel()
        pollTask = nil
        isPolling = false
        activePin = nil
        pinPollError = nil
    }

    private func pollPinUntilDone(_ pin: PlexPin) async {
        // Plex PINs live ~15 minutes. Poll every 2s for up to 5 min —
        // anything past that and the user has wandered off.
        let deadline = Date().addingTimeInterval(300)
        while !Task.isCancelled, Date() < deadline {
            do {
                if let token = try await client.checkPin(pin), !token.isEmpty {
                    await MainActor.run { self.completeAuth(token: token) }
                    return
                }
            } catch PlexError.pinExpired {
                await MainActor.run {
                    self.pinPollError = "Plex sign-in code expired — try again."
                    self.isPolling = false
                    self.activePin = nil
                }
                sonosDiagLog(.warning, tag: "PLEX",
                             "PIN expired before user completed plex.tv/link")
                return
            } catch {
                sonosDiagLog(.warning, tag: "PLEX",
                             "PIN poll error: \(error.localizedDescription)")
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        await MainActor.run {
            self.isPolling = false
            self.activePin = nil
            if self.pinPollError == nil {
                self.pinPollError = "Timed out waiting for plex.tv/link."
                sonosDiagLog(.error, tag: "PLEX",
                             "PIN polling timed out — user did not complete plex.tv/link")
            }
        }
    }

    private func completeAuth(token: String) {
        authToken = token
        secrets.set(Self.tokenKey, token)
        isPolling = false
        activePin = nil
        pinPollError = nil
        // Discover servers immediately so the first browse doesn't pay
        // the discovery latency.
        Task { try? await self.refreshServer() }
    }

    public func signOut() {
        authToken = ""
        baseURI = ""
        serverName = ""
        secrets.set(Self.tokenKey, nil)
        UserDefaults.standard.removeObject(forKey: Self.baseURIKey)
        UserDefaults.standard.removeObject(forKey: Self.serverNameKey)
        cancelPin()
    }

    // MARK: - Server discovery

    /// Lists servers and picks the first one with a reachable connection.
    /// Caches the result; call `forceRefresh: true` if the cached base
    /// URI starts failing.
    @discardableResult
    public func refreshServer() async throws -> String {
        guard !authToken.isEmpty else { throw PlexError.notAuthenticated }
        let servers = try await client.listServers(authToken: authToken)
        guard !servers.isEmpty else { throw PlexError.noServersFound }
        // Owned servers first — guests' shared libraries can have weird
        // permission edges that aren't worth fighting through here.
        let ordered = servers.sorted { $0.owned && !$1.owned }
        for server in ordered {
            if let uri = try? await client.pickReachableConnection(for: server) {
                self.baseURI = uri
                self.serverName = server.name
                UserDefaults.standard.set(uri, forKey: Self.baseURIKey)
                UserDefaults.standard.set(server.name, forKey: Self.serverNameKey)
                return uri
            }
        }
        throw PlexError.noServersFound
    }

    /// Returns a base URI guaranteed to have responded recently. If the
    /// cached one is empty or stale, kicks off discovery.
    public func ensureBaseURI() async throws -> String {
        if !baseURI.isEmpty { return baseURI }
        return try await refreshServer()
    }
}
