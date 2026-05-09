/// MusicServiceCatalog.swift — Authoritative source for SMAPI service
/// metadata in the running household.
///
/// Two layers:
///
/// 1. **Per-service protocol rules** — global facts about a service that
///    don't change between households (Spotify wants `x-sonos-spotify:`,
///    Apple Music tracks want `.mp4` + flags 8232, etc). Keyed by
///    canonical name (lowercased), seeded at init from a static table.
///
/// 2. **Per-household runtime descriptors** — the speaker's own answer
///    to `MusicServices/ListAvailableServices`: which sid the household
///    has assigned to "Spotify" right now, plus the SecureUri / auth
///    type / capabilities. Refreshed on speaker bind, periodically, and
///    on miss at lookup time.
///
/// The combination lets `buildPlayURI` and friends route purely on the
/// runtime sid the speaker reports, without hardcoding a guess at what
/// sid Spotify has — which varies by region, account vintage, and how
/// long ago the household added the service.
///
/// Thread-safety: read accessors are `nonisolated` and lock-guarded so
/// non-MainActor callers like `ServiceSearchProvider` can resolve a sid
/// to its rules synchronously while building a URI. Mutations happen on
/// `MainActor` so the `@Published` descriptor list stays SwiftUI-safe
/// for views that observe the catalog directly.
///
/// Leaves room for a per-(sid, sn) extension when multi-account
/// support per service is added.
import Foundation
import Combine

// MARK: - Value types

public struct ServiceDescriptor: Equatable, Sendable, Identifiable {
    /// Runtime sid as reported by the speaker for this household.
    /// May differ from any compile-time constant (the bug that motivated
    /// the catalog).
    public let id: Int
    public let name: String
    public let uri: String
    public let secureUri: String
    public let containerType: String
    public let capabilities: Int
    public let authType: String

    /// Sonos's per-service URI/DIDL identifier — invariant for a given
    /// service across households (Spotify is always 2311, Apple Music
    /// always 52231) because Sonos derives it as `(sid << 8) + 7` and
    /// the constant is stamped into the speaker's metadata templates.
    public var rinconServiceType: Int { (id << 8) + 7 }

    public init(id: Int, name: String, uri: String = "", secureUri: String = "",
                containerType: String = "", capabilities: Int = 0,
                authType: String = "Anonymous") {
        self.id = id
        self.name = name
        self.uri = uri
        self.secureUri = secureUri
        self.containerType = containerType
        self.capabilities = capabilities
        self.authType = authType
    }
}

public struct ServiceRules: Equatable, Sendable {
    public let canonicalName: String
    public let trackURIScheme: String
    public let trackURIExtension: String
    public let trackPlaybackFlags: Int
    public let streamURIScheme: String
    public let streamPlaybackFlags: Int
    public let didlTrackIdPrefix: String
    public let didlStreamIdPrefix: String
    public let didlContainerIdPrefix: String
    public let supportsAppLink: Bool
    public let defaultSerialNumber: Int

    public init(canonicalName: String,
                trackURIScheme: String = URIPrefix.sonosHTTP,
                trackURIExtension: String = "",
                trackPlaybackFlags: Int = 8224,
                streamURIScheme: String = URIPrefix.sonosApiStream,
                streamPlaybackFlags: Int = 8224,
                didlTrackIdPrefix: String = "10032020",
                didlStreamIdPrefix: String = "10092020",
                didlContainerIdPrefix: String = "1004206c",
                supportsAppLink: Bool = false,
                defaultSerialNumber: Int = 0) {
        self.canonicalName = canonicalName
        self.trackURIScheme = trackURIScheme
        self.trackURIExtension = trackURIExtension
        self.trackPlaybackFlags = trackPlaybackFlags
        self.streamURIScheme = streamURIScheme
        self.streamPlaybackFlags = streamPlaybackFlags
        self.didlTrackIdPrefix = didlTrackIdPrefix
        self.didlStreamIdPrefix = didlStreamIdPrefix
        self.didlContainerIdPrefix = didlContainerIdPrefix
        self.supportsAppLink = supportsAppLink
        self.defaultSerialNumber = defaultSerialNumber
    }

    /// cdudn (Service Account binding token) for DIDL `desc` elements.
    ///
    /// Two forms — pick by whether the controller holds an auth token
    /// for the service:
    /// - Anonymous (`SA_RINCON{type}_`) — used when no token. The
    ///   speaker auto-resolves to the household's stored binding (set
    ///   up via the official Sonos app). Confirmed by capturing the
    ///   Sonos app's own SetAVTransportURI metadata for Radio Paradise:
    ///   it sends a real per-household token (e.g. `bcf2efd3`) that
    ///   Choragus can't fabricate, so the anonymous form is the
    ///   correct fallback.
    /// - Full (`SA_RINCON{type}_X_#Svc{type}-{token}-Token`) — used
    ///   when the controller has authenticated the service via AppLink
    ///   and holds the per-household token in the local SMAPI store.
    ///
    /// The legacy literal `-0-Token` form is rejected by Sonos for
    /// services that require a binding (issue #28 / Radio Paradise),
    /// so it is no longer emitted.
    public func cdudn(rinconServiceType type: Int, authToken: String? = nil) -> String {
        if let token = authToken, !token.isEmpty {
            return "SA_RINCON\(type)_X_#Svc\(type)-\(token)-Token"
        }
        return "SA_RINCON\(type)_"
    }
}

// MARK: - Catalog

public final class MusicServiceCatalog: ObservableObject, @unchecked Sendable {
    public static let shared = MusicServiceCatalog()

    /// Per-household descriptor list — runtime answer to
    /// `ListAvailableServices`. Empty until `refresh` runs. Published so
    /// SwiftUI views (MusicServicesView, BrowseView) can observe.
    @Published public private(set) var descriptors: [ServiceDescriptor] = []

    /// Last successful refresh. Used by `ensureFresh` to gate periodic
    /// refetches behind a TTL.
    @Published public private(set) var lastRefresh: Date = .distantPast

    /// Default 6-hour TTL for opportunistic refresh. Cheap SOAP call,
    /// but no reason to hammer it.
    public static let defaultRefreshTTL: TimeInterval = 6 * 3600

    /// Speaker IP the catalog talks to. Set on speaker bind via
    /// `bind(speakerIP:)`. Periodic / miss-triggered refresh uses this
    /// when the caller doesn't pass one explicitly.
    public private(set) var ambassadorSpeakerIP: String?

    /// Lock-guarded snapshot for nonisolated reads from non-MainActor
    /// callers (notably `ServiceSearchProvider.buildPlayURI`).
    private let lock = NSLock()
    private var snapshotDescriptors: [ServiceDescriptor] = []

    private let staticRulesByName: [String: ServiceRules]
    private var refreshInFlight: Task<Void, Never>?
    private let fetcher: ListAvailableServicesFetching

    public init(fetcher: ListAvailableServicesFetching = LiveListAvailableServicesFetcher()) {
        self.staticRulesByName = Self.buildStaticRulesTable()
        self.fetcher = fetcher
    }

    // MARK: - Lookup (nonisolated, sync, lock-guarded)

    public func descriptor(forSid sid: Int) -> ServiceDescriptor? {
        lock.lock(); defer { lock.unlock() }
        return snapshotDescriptors.first { $0.id == sid }
    }

    public func descriptor(forName name: String) -> ServiceDescriptor? {
        let lower = name.lowercased()
        lock.lock(); defer { lock.unlock() }
        return snapshotDescriptors.first { $0.name.lowercased() == lower }
    }

    public func allDescriptors() -> [ServiceDescriptor] {
        lock.lock(); defer { lock.unlock() }
        return snapshotDescriptors
    }

    public func rules(forName name: String) -> ServiceRules? {
        staticRulesByName[name.lowercased()]
    }

    public func rules(forSid sid: Int) -> ServiceRules? {
        guard let name = descriptor(forSid: sid)?.name else { return nil }
        return staticRulesByName[name.lowercased()]
    }

    /// Best-effort RINCON service type for a sid. Falls back to
    /// `(sid << 8) + 7` even when the descriptor isn't loaded — that
    /// formula is the protocol's own derivation and matches what the
    /// speaker stamps in DIDL `desc` elements.
    public func rinconServiceType(forSid sid: Int) -> Int {
        descriptor(forSid: sid)?.rinconServiceType ?? ((sid << 8) + 7)
    }

    /// Resolve a track URI scheme for a runtime sid. Falls back to
    /// `x-sonos-http:` and logs a diagnostic when the catalog has no
    /// rules for the sid — that's the failure mode of issue #19, where
    /// the speaker reports a Spotify sid the catalog hasn't seen yet.
    public func trackURIScheme(forSid sid: Int) -> String {
        if let scheme = rules(forSid: sid)?.trackURIScheme {
            return scheme
        }
        let known = allDescriptors()
        sonosDiagLog(.warning, tag: "CATALOG",
                     "No rules for sid; defaulting to x-sonos-http:",
                     context: [
                        "sid": "\(sid)",
                        "knownSids": known.map(\.id).sorted().map(String.init).joined(separator: ","),
                        "knownNames": known.map(\.name).joined(separator: ",")
                     ])
        return URIPrefix.sonosHTTP
    }

    public func trackURIExtension(forSid sid: Int) -> String {
        rules(forSid: sid)?.trackURIExtension ?? ""
    }

    public func trackPlaybackFlags(forSid sid: Int) -> Int {
        rules(forSid: sid)?.trackPlaybackFlags ?? 8224
    }

    /// DIDL `item id` prefix lookup. Per-service when the catalog has
    /// rules; generic Sonos defaults otherwise. Same pattern as
    /// `trackURIScheme(forSid:)` — the catalog wins, the universal
    /// prefix is the fallback.
    public func didlTrackIdPrefix(forSid sid: Int) -> String {
        rules(forSid: sid)?.didlTrackIdPrefix ?? "10032020"
    }

    public func didlStreamIdPrefix(forSid sid: Int) -> String {
        rules(forSid: sid)?.didlStreamIdPrefix ?? "10092020"
    }

    public func didlContainerIdPrefix(forSid sid: Int) -> String {
        rules(forSid: sid)?.didlContainerIdPrefix ?? "1004206c"
    }

    /// cdudn for the runtime sid. Resolves the RINCON service type
    /// (catalog descriptor or `(sid << 8) + 7` fallback), then delegates
    /// to the static rule's cdudn template.
    public func cdudn(forSid sid: Int, authToken: String? = nil) -> String {
        let type = rinconServiceType(forSid: sid)
        if let rule = rules(forSid: sid) {
            return rule.cdudn(rinconServiceType: type, authToken: authToken)
        }
        // No rule entry — apply the default template directly.
        if let token = authToken, !token.isEmpty {
            return "SA_RINCON\(type)_X_#Svc\(type)-\(token)-Token"
        }
        return "SA_RINCON\(type)_"
    }

    /// Returns the sid this household uses for a canonical service name,
    /// if the descriptor has been loaded. Useful for code paths that
    /// were built around compile-time constants and need to migrate to
    /// runtime resolution.
    public func sid(forName name: String) -> Int? {
        descriptor(forName: name)?.id
    }

    // MARK: - Refresh

    @MainActor
    public func bind(speakerIP: String) {
        ambassadorSpeakerIP = speakerIP
    }

    /// Force a refresh against the given speaker. Coalesces concurrent
    /// callers — if a refresh is already in flight, awaits its
    /// completion rather than starting a second SOAP call.
    @MainActor
    public func refresh(speakerIP: String) async {
        if let inFlight = refreshInFlight {
            await inFlight.value
            return
        }
        let task = Task { @MainActor [weak self] in
            await self?.performRefresh(speakerIP: speakerIP)
            return ()
        }
        refreshInFlight = task
        await task.value
        refreshInFlight = nil
    }

    /// Refresh only if the descriptor list is older than `ttl`. Used by
    /// periodic checks and pre-flight before opening service-aware UI.
    @MainActor
    public func ensureFresh(ttl: TimeInterval = MusicServiceCatalog.defaultRefreshTTL) async {
        guard let ip = ambassadorSpeakerIP else { return }
        guard Date().timeIntervalSince(lastRefresh) > ttl else { return }
        await refresh(speakerIP: ip)
    }

    /// Refresh if the given sid isn't currently known. The "miss at
    /// play time" path: the speaker just minted a track URI with a sid
    /// the catalog hasn't seen, and we need to resolve it before
    /// building the play URI ourselves.
    @MainActor
    public func ensureSidKnown(_ sid: Int) async {
        if descriptor(forSid: sid) != nil { return }
        guard let ip = ambassadorSpeakerIP else { return }
        await refresh(speakerIP: ip)
    }

    @MainActor
    private func performRefresh(speakerIP: String) async {
        do {
            let parsed = try await fetcher.fetch(speakerIP: speakerIP)
            applyRefresh(parsed)
            lastRefresh = Date()
            sonosDiagLog(.info, tag: "CATALOG",
                         "Refreshed service descriptors",
                         context: [
                            "count": "\(parsed.count)",
                            "services": parsed.map { "\($0.name)(\($0.id))" }.joined(separator: ",")
                         ])
        } catch {
            sonosDiagLog(.warning, tag: "CATALOG",
                         "Refresh failed",
                         context: ["error": "\(error)"])
        }
    }

    /// Diff incoming descriptors against the current cache. Logs any
    /// drift (a service whose sid changed between refreshes) so it's
    /// visible in diagnostics. Drift is rare but real — happens if a
    /// user removes-and-re-adds an account in the Sonos app, which is
    /// exactly the symptom path that produced issue #19's failure mode.
    @MainActor
    func applyRefresh(_ incoming: [ServiceDescriptor]) {
        let prior = snapshotDescriptors
        for new in incoming {
            if let existing = prior.first(where: { $0.name.lowercased() == new.name.lowercased() }),
               existing.id != new.id {
                sonosDiagLog(.warning, tag: "CATALOG",
                             "Service sid changed",
                             context: [
                                "service": new.name,
                                "oldSid": "\(existing.id)",
                                "newSid": "\(new.id)"
                             ])
            }
        }
        lock.lock()
        snapshotDescriptors = incoming
        lock.unlock()
        descriptors = incoming
    }

    // MARK: - Static rules table

    /// Seeded once at init. Keys are canonical names, lowercased, so
    /// matches against descriptor names are case-insensitive.
    static func buildStaticRulesTable() -> [String: ServiceRules] {
        let entries: [ServiceRules] = [
            ServiceRules(
                canonicalName: ServiceName.spotify,
                trackURIScheme: "x-sonos-spotify:",
                trackURIExtension: "",
                trackPlaybackFlags: 8224,
                supportsAppLink: true,
                defaultSerialNumber: 1
            ),
            ServiceRules(
                canonicalName: ServiceName.appleMusic,
                trackURIScheme: URIPrefix.sonosHTTP,
                trackURIExtension: ".mp4",
                trackPlaybackFlags: 8232,
                supportsAppLink: false,
                defaultSerialNumber: 1
            ),
            ServiceRules(
                canonicalName: "Plex",
                trackURIScheme: URIPrefix.sonosHTTP,
                trackURIExtension: ".mp3",
                trackPlaybackFlags: 8232,
                supportsAppLink: true,
                defaultSerialNumber: 1
            ),
            ServiceRules(
                canonicalName: ServiceName.amazonMusic,
                trackURIScheme: URIPrefix.sonosHTTP,
                trackURIExtension: "",
                trackPlaybackFlags: 8224,
                supportsAppLink: false,
                defaultSerialNumber: 1
            ),
            ServiceRules(
                canonicalName: ServiceName.tidal,
                trackURIScheme: URIPrefix.sonosHTTP,
                trackURIExtension: "",
                trackPlaybackFlags: 8224,
                supportsAppLink: true,
                defaultSerialNumber: 1
            ),
            ServiceRules(
                canonicalName: ServiceName.deezer,
                trackURIScheme: URIPrefix.sonosHTTP,
                trackURIExtension: "",
                trackPlaybackFlags: 8224,
                supportsAppLink: true,
                defaultSerialNumber: 1
            ),
            ServiceRules(
                canonicalName: "Qobuz",
                trackURIScheme: URIPrefix.sonosHTTP,
                trackURIExtension: "",
                trackPlaybackFlags: 8224,
                supportsAppLink: true,
                defaultSerialNumber: 1
            ),
            ServiceRules(
                canonicalName: ServiceName.soundCloud,
                trackURIScheme: URIPrefix.sonosHTTP,
                trackURIExtension: "",
                trackPlaybackFlags: 8224,
                supportsAppLink: true,
                defaultSerialNumber: 1
            ),
            ServiceRules(
                canonicalName: ServiceName.youTubeMusic,
                trackURIScheme: URIPrefix.sonosHTTP,
                trackURIExtension: "",
                trackPlaybackFlags: 8224,
                supportsAppLink: false,
                defaultSerialNumber: 1
            ),
            ServiceRules(
                canonicalName: ServiceName.tuneIn,
                trackURIScheme: URIPrefix.sonosApiStream,
                trackURIExtension: "",
                trackPlaybackFlags: 8224,
                streamURIScheme: URIPrefix.sonosApiStream,
                streamPlaybackFlags: 8224,
                supportsAppLink: false,
                defaultSerialNumber: 0
            ),
            ServiceRules(
                canonicalName: ServiceName.calmRadio,
                trackURIScheme: URIPrefix.sonosApiStream,
                trackURIExtension: "",
                trackPlaybackFlags: 8224,
                streamURIScheme: URIPrefix.sonosApiStream,
                streamPlaybackFlags: 8224,
                supportsAppLink: false,
                defaultSerialNumber: 0
            ),
            ServiceRules(
                canonicalName: ServiceName.pandora,
                trackURIScheme: URIPrefix.sonosApiRadio,
                trackURIExtension: "",
                trackPlaybackFlags: 8224,
                supportsAppLink: false,
                defaultSerialNumber: 1
            ),
            ServiceRules(
                canonicalName: ServiceName.sonosRadio,
                trackURIScheme: URIPrefix.sonosApiStream,
                trackURIExtension: "",
                trackPlaybackFlags: 8224,
                streamURIScheme: URIPrefix.sonosApiRadio,
                streamPlaybackFlags: 8224,
                supportsAppLink: false,
                defaultSerialNumber: 0
            ),
            // Radio Paradise — derived directly from a Sonos favorite
            // dump (FV:2 ContentDirectory.Browse). The household-stamped
            // <res> element on a Radio Paradise favorite shows:
            //   x-sonosapi-radio:channel%3a0%3a2%3aresume?sid=308&flags=8232&sn=26
            // and the embedded <r:resMD> DIDL uses item-id prefix
            // 100c2028 plus parentID="10fe2064bitrate%3aradio128".
            // The previous defaults (`x-sonosapi-stream:`, flags=8224,
            // didl prefix `10092020`) produced UPnP fault 402 because
            // every field was wrong for this service. Pandora uses a
            // similar `x-sonosapi-radio:` shape, hence the precedent.
            ServiceRules(
                canonicalName: ServiceName.radioParadise,
                trackURIScheme: URIPrefix.sonosApiRadio,
                trackURIExtension: "",
                trackPlaybackFlags: 8232,
                streamURIScheme: URIPrefix.sonosApiRadio,
                streamPlaybackFlags: 8232,
                didlTrackIdPrefix: "100c2028",
                didlStreamIdPrefix: "100c2028",
                didlContainerIdPrefix: "10fe2064",
                supportsAppLink: true,
                defaultSerialNumber: 1
            ),
        ]
        var dict: [String: ServiceRules] = [:]
        for rule in entries {
            dict[rule.canonicalName.lowercased()] = rule
        }
        return dict
    }
}

// MARK: - Fetcher protocol

/// Indirection so `MusicServiceCatalog` is testable without a live
/// speaker — tests inject a stub fetcher returning a canned descriptor
/// list. Production uses `LiveListAvailableServicesFetcher`, which
/// drives the same SOAP call that `SMAPIAuthManager` and
/// `MusicServicesService` previously each owned a copy of.
public protocol ListAvailableServicesFetching: Sendable {
    func fetch(speakerIP: String) async throws -> [ServiceDescriptor]
}

public struct LiveListAvailableServicesFetcher: ListAvailableServicesFetching {
    public init() {}

    public func fetch(speakerIP: String) async throws -> [ServiceDescriptor] {
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
         s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
        <s:Body>
        <u:ListAvailableServices xmlns:u="urn:schemas-upnp-org:service:MusicServices:1"/>
        </s:Body></s:Envelope>
        """
        let port = SonosProtocol.defaultPort
        guard let url = URL(string: "http://\(speakerIP):\(port)/MusicServices/Control") else {
            return []
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:MusicServices:1#ListAvailableServices\"",
                         forHTTPHeaderField: "SOAPAction")
        request.httpBody = body.data(using: .utf8)
        request.timeoutInterval = 10

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let xml = String(data: data, encoding: .utf8) else { return [] }
        return MusicServiceCatalogParser.parse(xml)
    }
}

/// XML extractor shared between the live fetcher and the test stub.
/// Public so the unit test can verify the parser in isolation.
public enum MusicServiceCatalogParser {
    public static func parse(_ xml: String) -> [ServiceDescriptor] {
        let unescaped = XMLResponseParser.xmlUnescape(xml)
        var services: [ServiceDescriptor] = []
        let parts = unescaped.components(separatedBy: "<Service ")
        for part in parts.dropFirst() {
            guard let idStr = extractAttr(part, "Id"),
                  let id = Int(idStr),
                  let name = extractAttr(part, "Name") else { continue }

            let secureUri = extractAttr(part, "SecureUri") ?? ""
            let uri = extractAttr(part, "Uri") ?? ""
            let containerType = extractAttr(part, "ContainerType") ?? ""
            let capabilities = Int(extractAttr(part, "Capabilities") ?? "0") ?? 0
            var authType = "Anonymous"
            if let policyRange = part.range(of: "Auth=\""),
               let endQuote = part[policyRange.upperBound...].range(of: "\"") {
                authType = String(part[policyRange.upperBound..<endQuote.lowerBound])
            }
            services.append(ServiceDescriptor(
                id: id, name: name, uri: uri, secureUri: secureUri,
                containerType: containerType, capabilities: capabilities,
                authType: authType
            ))
        }
        return services.sorted { $0.name < $1.name }
    }

    private static func extractAttr(_ text: String, _ name: String) -> String? {
        guard let range = text.range(of: "\(name)=\""),
              let endQuote = text[range.upperBound...].range(of: "\"") else { return nil }
        return String(text[range.upperBound..<endQuote.lowerBound])
    }
}
