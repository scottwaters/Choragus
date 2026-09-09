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
    /// May differ from any compile-time constant.
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

/// How a service's SMAPI object id maps onto the id embedded in play URIs.
///
/// Most services play the object id back verbatim — a Spotify
/// `spotify:track:<id>` is also the id inside
/// `x-sonos-spotify:spotify%3atrack%3a<id>`. Amazon Music does not: its
/// SMAPI ids are `catalog:<kind>:asin:<ASIN>`, while the playable id is a
/// catalogue *path*. Using the object id verbatim faults UPnP 714.
public enum ItemIDStyle: String, Equatable, Sendable {
    /// Object id goes into the URI unchanged.
    case verbatim
    /// Amazon Music on S1: rewrite `catalog:track:asin:X` to
    /// `catalog/tracks/X/` and `catalog:album:asin:X` to
    /// `catalog/albums/X/#album_desc`.
    case amazonCatalogPath
    /// Amazon Music on S2: the object id as-is, minus the `#erefid-…`
    /// fragment search results carry. The speaker's own queue rows read
    /// `x-sonos-http:catalog%3atrack%3aasin%3a<ASIN>.mpd`.
    case amazonAsin
}

/// How a service's collections (albums, playlists, artists, stations)
/// are handed to the speaker.
public enum ContainerPlayForm: String, Equatable, Sendable {
    /// `x-rincon-cpcontainer:<prefix><id>?…&flags=8300` enqueued as a
    /// playlist container. The Sonos default.
    case cpContainer
    /// Amazon Music on S2: `x-sonosapi-radio:sp:container:station:<id>`
    /// set directly on the transport with DIDL prefix `000c0000` and
    /// class audioBroadcast — the form the Sonos app itself uses.
    /// Single tracks in the local queue fault
    /// UPnP 701 in every form on S2, so the collection is the unit of
    /// playback there.
    case stationWrapper
}

/// Which `desc` (cdudn) the service's DIDL carries.
public enum CdudnForm: String, Equatable, Sendable {
    /// Token-bearing when the controller holds an AppLink token,
    /// anonymous otherwise.
    case tokenWhenHeld
    /// Always `SA_RINCON<type>_`: the speaker resolves the household's
    /// own account binding. Amazon S2 plays with it, and the controller's
    /// AppLink token is not the speaker's account id.
    case anonymous
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
    public let itemIDStyle: ItemIDStyle
    /// Whether a search/browse item is resolved through SMAPI `getMediaURI`
    /// before play and enqueued as the returned direct URL with empty DIDL.
    /// Right for controller-authenticated services whose speakers hold no
    /// account binding (TIDAL, Audible). Wrong for Amazon Music: its
    /// `getMediaURI` returns a signed CloudFront HLS manifest the speaker
    /// enqueues but cannot play (UPnP 701 on Play), and faults
    /// `ItemNotFound` for stations altogether. Amazon's raw
    /// `x-sonosapi-hls-static:` / `x-sonosapi-radio:` URIs with DIDL are
    /// what the speaker plays.
    public let resolvesViaGetMediaURI: Bool
    public let containerPlayForm: ContainerPlayForm
    public let cdudnForm: CdudnForm

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
                defaultSerialNumber: Int = 0,
                itemIDStyle: ItemIDStyle = .verbatim,
                resolvesViaGetMediaURI: Bool = true,
                containerPlayForm: ContainerPlayForm = .cpContainer,
                cdudnForm: CdudnForm = .tokenWhenHeld) {
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
        self.itemIDStyle = itemIDStyle
        self.resolvesViaGetMediaURI = resolvesViaGetMediaURI
        self.containerPlayForm = containerPlayForm
        self.cdudnForm = cdudnForm
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
    /// The literal `-0-Token` form is rejected by Sonos for services
    /// that require a binding (Radio Paradise), so it is never emitted.
    public func cdudn(rinconServiceType type: Int, authToken: String? = nil) -> String {
        if cdudnForm == .tokenWhenHeld, let token = authToken, !token.isEmpty {
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
    // Dynamic canonical table (lock-guarded). A canonical service can hold
    // MORE THAN ONE sid — Sonos assigns the id per household/region/registration
    // (Spotify is 9 in most systems, 12 in others), so ids are grouped by
    // service rather than hardcoded. Seeded from the well-known online id set, then
    // augmented at every `ListAvailableServices` refresh with whatever ids this
    // household actually reports.
    private var canonicalRelatedSids: [String: Set<Int>] = [:]  // lower(name) -> ids
    private var canonicalKeyBySid: [Int: String] = [:]          // sid -> lower(name)
    private var canonicalDisplayByKey: [String: String] = [:]   // lower(name) -> display

    private let staticRulesByName: [String: ServiceRules]
    /// S1-only variants, keyed like `staticRulesByName`.
    private let s1RulesByName: [String: ServiceRules]
    private var refreshInFlight: Task<Void, Never>?
    private let fetcher: ListAvailableServicesFetching

    /// Well-known starting id set, taken from the public Sonos service list
    /// (svrooij / SoCo community references) plus the ids this codebase has
    /// observed in real households. Multiple ids per service is intentional:
    /// e.g. Spotify is 9 in the documented list and 12 in some live systems.
    /// Per-household `ListAvailableServices` descriptors add any others at
    /// runtime, so this is only a seed, never the sole source of truth.
    static let seededServiceIDs: [(name: String, ids: Set<Int>)] = [
        (ServiceName.spotify, [9, 12]),
        (ServiceName.appleMusic, [204]),
        (ServiceName.amazonMusic, [201]),
        (ServiceName.deezer, [2]),
        (ServiceName.tidal, [174]),
        ("Qobuz", [31]),
        (ServiceName.soundCloud, [160]),
        (ServiceName.youTubeMusic, [284]),
        (ServiceName.tuneIn, [254, 333]),
        (ServiceName.calmRadio, [144]),
        (ServiceName.sonosRadio, [303]),
        ("Plex", [212]),
        ("Audible", [239]),
        ("Bandcamp", [157]),
        (ServiceName.pandora, [3]),
        (ServiceName.radioParadise, [308]),
        ("SomaFM Radio", [516]),
    ]

    public init(fetcher: ListAvailableServicesFetching = LiveListAvailableServicesFetcher()) {
        self.staticRulesByName = Self.buildStaticRulesTable()
        self.s1RulesByName = Self.buildS1RulesTable()
        self.fetcher = fetcher
        rebuildCanonicalTable([])  // seed-only until the first refresh
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
        rules(forSid: sid, generation: .unknown)
    }

    /// Rules for a service as played by a household of `generation`.
    /// The default table describes S2 (and unknown); `s1RulesByName`
    /// holds the services whose S1 form differs. Only Amazon Music does
    /// today: S1 plays `x-sonosapi-hls-static:catalog/tracks/<asin>/`,
    /// S2 plays `x-sonos-http:catalog:track:asin:<asin>.mpd`.
    public func rules(forSid sid: Int, generation: SonosSystemVersion) -> ServiceRules? {
        guard let name = descriptor(forSid: sid)?.name else { return nil }
        let key = name.lowercased()
        if generation == .s1, let s1 = s1RulesByName[key] { return s1 }
        return staticRulesByName[key]
    }

    /// Best-effort RINCON service type for a sid. Falls back to
    /// `(sid << 8) + 7` even when the descriptor isn't loaded — that
    /// formula is the protocol's own derivation and matches what the
    /// speaker stamps in DIDL `desc` elements.
    public func rinconServiceType(forSid sid: Int) -> Int {
        descriptor(forSid: sid)?.rinconServiceType ?? ((sid << 8) + 7)
    }

    // MARK: - Canonical service resolution (multi-id, dynamic)

    /// The canonical, display-cased service name for any resolvable sid —
    /// from the household descriptor's own name, the seeded id set, or a
    /// URI-scheme match. nil for an unrecognised sid (the caller then
    /// falls back to "Service N").
    public func canonicalDisplayName(forSid sid: Int) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let key = canonicalKeyBySid[sid] else { return nil }
        return canonicalDisplayByKey[key]
    }

    /// Every sid known to belong to the same canonical service as `sid`
    /// (e.g. Spotify → {9, 12}). Lets the UI classify a row by any of its
    /// aliases, so a household at sid 9 still matches a tested/blocked set
    /// keyed on 12. Empty when unresolved.
    public func relatedSids(forSid sid: Int) -> Set<Int> {
        lock.lock(); defer { lock.unlock() }
        guard let key = canonicalKeyBySid[sid] else { return [] }
        return canonicalRelatedSids[key] ?? []
    }

    /// Resolve a household descriptor to a canonical key: exact name match
    /// first (Sonos usually returns the brand name), then a URI-scheme / host
    /// token match so a localised or renamed descriptor still maps home.
    private func canonicalKey(forDescriptor d: ServiceDescriptor) -> String? {
        let lname = d.name.lowercased()
        if staticRulesByName[lname] != nil { return lname }
        if Self.seededServiceIDs.contains(where: { $0.name.lowercased() == lname }) { return lname }
        // Match against the host's FIRST DNS label only (e.g. "spotify-v5" from
        // "spotify-v5.ws.sonos.com"). Matching the whole host is useless — every
        // Sonos SMAPI endpoint is `*.ws.sonos.com`, so "sonos" et al. would hit
        // everything.
        let label = Self.hostFirstLabel(d.secureUri.isEmpty ? d.uri : d.secureUri)
        guard label.count > 3 else { return nil }
        // 1) Service-specific scheme token (x-sonos-spotify: → "spotify").
        for (key, rule) in staticRulesByName {
            let token = rule.trackURIScheme
                .replacingOccurrences(of: "x-sonosapi-", with: "")
                .replacingOccurrences(of: "x-sonos-", with: "")
                .replacingOccurrences(of: "x-rincon-", with: "")
                .replacingOccurrences(of: ":", with: "")
            // Same guard as the name-word pass below: `x-sonosapi-radio:`
            // reduces to "radio" and `x-sonosapi-stream:` to "stream", which
            // match any vendor whose host says what it serves rather than who
            // it is (RadioApp vs Pandora, HearDis! vs TuneIn).
            if token.count > 3, !Self.genericHostTokens.contains(token),
               label.contains(token) { return key }
        }
        // 2) Canonical name's first word in the host label — but only when
        //    that word identifies a service. "Sonos Radio" contributes the
        //    token "sonos", and vendors conventionally name their Sonos
        //    integration endpoint `sonos.<vendor>.com`; matching on it folds
        //    unrelated services into Sonos Radio's identity and makes their
        //    Settings toggles govern each other.
        for key in staticRulesByName.keys {
            guard let nameTok = key.split(separator: " ").first.map(String.init),
                  nameTok.count > 3,
                  !Self.genericHostTokens.contains(nameTok),
                  label.contains(nameTok)
            else { continue }
            return key
        }
        return nil
    }

    /// Words that appear in a canonical service name but say nothing about
    /// WHICH service a host belongs to. Matching on these folds unrelated
    /// services together.
    private static let genericHostTokens: Set<String> = [
        "sonos", "radio", "music", "player", "stream", "media", "audio",
    ]

    /// First DNS label of a URL/host string, lower-cased.
    static func hostFirstLabel(_ uri: String) -> String {
        var s = uri.lowercased()
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        return s.split(separator: ".").first.map(String.init) ?? s
    }

    /// Rebuild the canonical maps from the seed plus the current descriptors.
    /// Called at init (seed only) and on every refresh.
    func rebuildCanonicalTable(_ descriptors: [ServiceDescriptor]) {
        var related: [String: Set<Int>] = [:]
        var display: [String: String] = [:]
        for (name, ids) in Self.seededServiceIDs {
            let key = name.lowercased()
            related[key, default: []].formUnion(ids)
            display[key] = name
        }
        // The household's descriptor list is authoritative for the ids it
        // reports: evict each reported id from every seeded group first, so a
        // sid this household assigns to a different (possibly unrecognised)
        // service never resolves to the seed's service. Seeded aliases the
        // household doesn't report stay grouped.
        for d in descriptors {
            for key in related.keys { related[key]?.remove(d.id) }
        }
        // Descriptors that map to a canonical service by something other than
        // their own name are worth recording: a wrong match folds an unrelated
        // service into another's identity, which surfaces as the wrong control
        // in Settings and as one toggle appearing to govern several services.
        var foldedByHost: [String: [String]] = [:]
        for d in descriptors {
            guard let key = canonicalKey(forDescriptor: d) else { continue }
            related[key, default: []].insert(d.id)
            if display[key] == nil { display[key] = d.name }   // prefer seeded display
            if d.name.lowercased() != key {
                foldedByHost[key, default: []].append("\(d.name)(\(d.id))")
            }
        }
        for (key, folded) in foldedByHost where folded.count > 0 {
            sonosDiagLog(.info, tag: "CATALOG",
                         "Descriptors folded into a canonical service by host match",
                         context: ["canonical": key,
                                   "count": String(folded.count),
                                   "services": folded.prefix(12).joined(separator: ", ")])
        }
        var bySid: [Int: String] = [:]
        for (key, ids) in related { for id in ids { bySid[id] = key } }
        lock.lock()
        canonicalRelatedSids = related
        canonicalKeyBySid = bySid
        canonicalDisplayByKey = display
        lock.unlock()
    }

    /// Resolve a track URI scheme for a runtime sid. Falls back to
    /// `x-sonos-http:` and logs a diagnostic when the catalog has no
    /// rules for the sid (the speaker reports a Spotify sid the catalog
    /// has not seen yet).
    public func trackURIScheme(forSid sid: Int, generation: SonosSystemVersion = .unknown) -> String {
        if let scheme = rules(forSid: sid, generation: generation)?.trackURIScheme {
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

    public func trackURIExtension(forSid sid: Int, generation: SonosSystemVersion = .unknown) -> String {
        rules(forSid: sid, generation: generation)?.trackURIExtension ?? ""
    }

    public func trackPlaybackFlags(forSid sid: Int, generation: SonosSystemVersion = .unknown) -> Int {
        rules(forSid: sid, generation: generation)?.trackPlaybackFlags ?? 8224
    }

    /// DIDL `item id` prefix lookup. Per-service when the catalog has
    /// rules; generic Sonos defaults otherwise. Same pattern as
    /// `trackURIScheme(forSid:)` — the catalog wins, the universal
    /// prefix is the fallback.
    public func didlTrackIdPrefix(forSid sid: Int, generation: SonosSystemVersion = .unknown) -> String {
        rules(forSid: sid, generation: generation)?.didlTrackIdPrefix ?? "10032020"
    }

    public func didlStreamIdPrefix(forSid sid: Int) -> String {
        rules(forSid: sid)?.didlStreamIdPrefix ?? "10092020"
    }

    /// See `ServiceRules.resolvesViaGetMediaURI`. Services without a
    /// rules entry keep the historical resolve-then-enqueue behaviour.
    public func resolvesViaGetMediaURI(forSid sid: Int) -> Bool {
        rules(forSid: sid)?.resolvesViaGetMediaURI ?? true
    }

    public func didlContainerIdPrefix(forSid sid: Int, generation: SonosSystemVersion = .unknown) -> String {
        rules(forSid: sid, generation: generation)?.didlContainerIdPrefix ?? "1004206c"
    }

    /// How this service's object ids map onto play-URI ids.
    public func itemIDStyle(forSid sid: Int, generation: SonosSystemVersion = .unknown) -> ItemIDStyle {
        rules(forSid: sid, generation: generation)?.itemIDStyle ?? .verbatim
    }

    /// cdudn for the runtime sid. Resolves the RINCON service type
    /// (catalog descriptor or `(sid << 8) + 7` fallback), then delegates
    /// to the static rule's cdudn template.
    public func cdudn(forSid sid: Int, authToken: String? = nil,
                      generation: SonosSystemVersion = .unknown) -> String {
        // Apple Music: the local-device descriptor, NOT the service-account
        // form. With the SA_RINCON service descriptor the speaker validates
        // the account against Apple PER TRACK at enqueue (1.16 s vs 0.15 s
        // per AddURIToQueue); the official Sonos app's
        // queue entries carry no service descriptor at all — the `sn=` in
        // the hls-static URI binds the account at play time. Verified to
        // enqueue fast AND play.
        if rules(forSid: sid)?.canonicalName == ServiceName.appleMusic {
            return "RINCON_AssociatedZPUDN"
        }
        let type = rinconServiceType(forSid: sid)
        if let rule = rules(forSid: sid, generation: generation) {
            return rule.cdudn(rinconServiceType: type, authToken: authToken)
        }
        // No rule entry — apply the default template directly.
        if let token = authToken, !token.isEmpty {
            return "SA_RINCON\(type)_X_#Svc\(type)-\(token)-Token"
        }
        return "SA_RINCON\(type)_"
    }

    /// Returns the sid this household uses for a canonical service name,
    /// if the descriptor has been loaded.
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
    /// the catalog hasn't seen, and it must be resolved before
    /// building the play URI.
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
    /// visible in diagnostics. Drift happens when a user removes and
    /// re-adds an account in the Sonos app.
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
        rebuildCanonicalTable(incoming)
    }

    // MARK: - Static rules table

    /// Seeded once at init. Keys are canonical names, lowercased, so
    /// matches against descriptor names are case-insensitive.
    /// Services whose S1 play form differs from the S2 default.
    static func buildS1RulesTable() -> [String: ServiceRules] {
        let entries: [ServiceRules] = [
            // Amazon Music on S1: tracks as
            // `x-sonosapi-hls-static:catalog%2ftracks%2f<asin>%2f` with
            // `flags=0` and DIDL id prefix `10030000`, both taken from
            // that household's Amazon favorites. The verbatim object id
            // and the `x-sonos-http:` form fault UPnP 714 there.
            ServiceRules(
                canonicalName: ServiceName.amazonMusic,
                trackURIScheme: URIPrefix.sonosApiHLSStatic,
                trackURIExtension: "",
                trackPlaybackFlags: 0,
                streamURIScheme: URIPrefix.sonosApiRadio,
                streamPlaybackFlags: 8300,
                didlTrackIdPrefix: "10030000",
                didlStreamIdPrefix: "100c2068",
                supportsAppLink: true,
                defaultSerialNumber: 1,
                itemIDStyle: .amazonCatalogPath,
                resolvesViaGetMediaURI: false
            ),
        ]
        return Dictionary(uniqueKeysWithValues: entries.map { ($0.canonicalName.lowercased(), $0) })
    }

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
                // HLS-static matches the official app's enqueue form; the
                // `x-sonos-http:…mp4` form forces a per-track Apple
                // validation at enqueue time (slow bulk adds).
                trackURIScheme: URIPrefix.sonosApiHLSStatic,
                trackURIExtension: "",
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
            // Amazon Music, S2 form. Tracks use the id form the
            // S2 Sonos app streams — `x-sonosapi-hls-static:` with the
            // verbatim `catalog:track:asin:<ASIN>` id and `flags=0`. On an
            // Amazon Music Prime account every single-track form faults
            // UPnP 701 (Prime is station-only); that is reported as
            // `StaleDataError.serviceTierRefused`, not modelled here.
            // Albums, playlists and artists play the way the Sonos app
            // plays them: `x-sonosapi-radio:sp:container:station:<id>` set
            // on the transport, DIDL prefix `000c0000`, anonymous cdudn.
            // The S1 form lives in `buildS1RulesTable`.
            ServiceRules(
                canonicalName: ServiceName.amazonMusic,
                trackURIScheme: URIPrefix.sonosApiHLSStatic,
                trackURIExtension: "",
                trackPlaybackFlags: 0,
                streamURIScheme: URIPrefix.sonosApiRadio,
                streamPlaybackFlags: 8300,
                didlTrackIdPrefix: "10030000",
                didlStreamIdPrefix: "100c2068",
                didlContainerIdPrefix: "000c0000",
                supportsAppLink: true,
                defaultSerialNumber: 1,
                itemIDStyle: .amazonAsin,
                resolvesViaGetMediaURI: false,
                containerPlayForm: .stationWrapper,
                cdudnForm: .anonymous
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
            // SomaFM — anonymous radio. Stations play via the
            // `x-sonosapi-stream:<id>` broadcast form with `sn=0`; the
            // speaker resolves the actual HLS/PLS stream itself. Name must
            // match the household descriptor ("SomaFM Radio") so rules(forSid:)
            // resolves it.
            ServiceRules(
                canonicalName: "SomaFM Radio",
                streamURIScheme: URIPrefix.sonosApiStream,
                streamPlaybackFlags: 8224,
                supportsAppLink: false,
                defaultSerialNumber: 0
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
            // Pandora — `getAppLink` answers HTTP 200 with a link code, so
            // AppLink is on. Playback rules are untested: captures of the
            // Sonos app show stations as `x-sonosapi-radio:` with
            // `flags=8300` and a real `sn`; the `-0-Token` form faults SOAP 402.
            ServiceRules(
                canonicalName: ServiceName.pandora,
                trackURIScheme: URIPrefix.sonosApiRadio,
                trackURIExtension: "",
                trackPlaybackFlags: 8224,
                streamURIScheme: URIPrefix.sonosApiRadio,
                streamPlaybackFlags: 8300,
                didlStreamIdPrefix: "100c2068",
                supportsAppLink: true,
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
            // `x-sonosapi-stream:` / flags=8224 / prefix `10092020` fault
            // UPnP 402 for this service.
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
/// list. Production uses `LiveListAvailableServicesFetcher`.
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
        return XMLResponseParser.xmlUnescape(String(text[range.upperBound..<endQuote.lowerBound]))
    }
}
