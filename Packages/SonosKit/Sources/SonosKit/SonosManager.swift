/// SonosManager.swift — Central coordinator for all Sonos operations.
///
/// Acts as the single source of truth for speaker topology, playback state,
/// volume, and browsing. Supports two communications modes:
/// - Hybrid Event-First: UPnP event subscriptions with targeted polling fallback
/// - Legacy Polling: Original periodic SOAP queries (2-second interval)
///
/// All UPnP service calls are funneled through here so the UI layer never
/// touches SOAP directly. Uses a "Quick Start" cache system to show speakers
/// instantly on launch while live discovery runs in the background.
import Foundation
import Combine

private let debugLogPath: String = {
    AppPaths.appSupportDirectory.appendingPathComponent("sonos_debug.log").path
}()

public func sonosDebugLog(_ msg: String) {
    #if DEBUG
    let line = "\(Date()): \(msg)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let handle = FileHandle(forWritingAtPath: debugLogPath) {
        handle.seekToEndOfFile()
        handle.write(data)
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: debugLogPath, contents: data, attributes: [.posixPermissions: 0o600])
    }
    #endif
}

public enum StartupMode: String, CaseIterable {
    case quickStart = "Quick Start"
    case classic = "Classic"
}

public enum CommunicationMode: String, CaseIterable {
    case hybridEventFirst = "Event-Driven"
    case legacyPolling = "Legacy Polling"
}

/// How the app finds Sonos speakers on the network.
///
/// - `auto`: run Bonjour and SSDP in parallel and merge by RINCON UUID.
///   Right answer for almost everyone — flat networks already discover via
///   SSDP; VLAN-segmented networks (UniFi/OPNsense with mDNS reflectors but
///   no SSDP reflector) light up via Bonjour without user config.
/// - `bonjour`: mDNS only. Use when SSDP multicast traffic is being filtered
///   and you want to suppress retransmits.
/// - `ssdp`: SSDP only. Original behaviour — kept as an escape hatch in case
///   `_sonos._tcp` browsing misbehaves on a particular network.
public enum DiscoveryMode: String, CaseIterable {
    case auto = "Auto"
    case bonjour = "Bonjour"
    case ssdp = "Legacy Multicast"
}

public enum AppearanceMode: String, CaseIterable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    /// Localised label for the segmented picker. The raw value stays
    /// the stable persistence key so existing UserDefaults survive.
    public var displayName: String {
        switch self {
        case .system: return L10n.system
        case .light:  return L10n.appearanceLight
        case .dark:   return L10n.appearanceDark
        }
    }
}

/// Stored as RGB array [r, g, b] in UserDefaults. [-1,-1,-1] means "use system default".
public struct StoredColor: Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public static let system = StoredColor(red: -1, green: -1, blue: -1)
    public var isSystem: Bool { red < 0 }

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public func save(to key: String) {
        UserDefaults.standard.set([red, green, blue], forKey: key)
    }

    public static func load(from key: String, default defaultValue: StoredColor = .system) -> StoredColor {
        guard let arr = UserDefaults.standard.array(forKey: key) as? [Double], arr.count == 3 else {
            return defaultValue
        }
        return StoredColor(red: arr[0], green: arr[1], blue: arr[2])
    }
}

@MainActor
public class SonosManager: ObservableObject {
    // MARK: - Published State

    @Published public var groups: [SonosGroup] = []
    @Published public var devices: [String: SonosDevice] = [:]
    @Published public var isDiscovering = false
    @Published public var browseSections: [BrowseSection] = []
    @Published public var musicServicesList: [MusicService] = []

    // Cache state — drives the "Using cached data" banner in ContentView
    @Published public var isUsingCachedData = false
    @Published public var cacheAge: String = ""
    @Published public var isRefreshing = false
    @Published public var staleMessage: String?

    // MARK: - Transport State (centralized, updated by transport strategy)

    /// Per-group playback state, keyed by group ID
    @Published public var groupTransportStates: [String: TransportState] = [:]
    @Published public var groupTrackMetadata: [String: TrackMetadata] = [:]
    @Published public var groupPlayModes: [String: PlayMode] = [:]
    @Published public var groupPositions: [String: TimeInterval] = [:]
    @Published public var groupDurations: [String: TimeInterval] = [:]

    /// Per-device volume/mute state, keyed by device ID
    @Published public var deviceVolumes: [String: Int] = [:]
    @Published public var deviceMutes: [String: Bool] = [:]

    /// Persistent art-URL cache. State + lookup + persistence live in
    /// `ArtCacheService`; SonosManager exposes the legacy `discoveredArtURLs`
    /// / `cacheArtURL` / `lookupCachedArt` surface as forwarding shims so
    /// existing call sites (and the `TransportStateProviding` protocol)
    /// keep working unchanged. Observers wanting to react to cache changes
    /// should subscribe to `artCache.$discoveredArtURLs` directly.
    public let artCache: ArtCacheService

    /// Forwarding accessor; canonical state lives in `artCache`.
    public var discoveredArtURLs: [String: String] { artCache.discoveredArtURLs }

    /// The objectID of the last favorite that was played — used to map art back to the browse list
    public var lastPlayedFavoriteID: String?

    /// Optional play history manager — set from app layer
    public var playHistoryManager: PlayHistoryManager?

    /// Set when user initiates playback, cleared only when speaker confirms playing
    @Published public var awaitingPlayback: [String: Bool] = [:]

    /// True while an add-to-queue operation is in flight for any group.
    /// QueueView observes this to show an in-progress indicator alongside
    /// its own `isLoading` flag — on S1 the per-track fallback loop can
    /// take 30 s or more and the user needs visible confirmation that
    /// something is happening the whole time, not just at the end.
    @Published public var isAddingToQueue: Bool = false

    /// Drag state for cross-view drag-and-drop (browse → queue)
    public var draggedBrowseItem: BrowseItem?

    /// Stores an art URL with multiple cache keys for flexible lookup.
    /// Forwards to `ArtCacheService`; preserved on SonosManager for
    /// `TransportStateProviding` conformance and existing call sites.
    public func cacheArtURL(_ artURL: String, forURI uri: String, title: String = "", itemID: String = "") {
        artCache.cacheArtURL(artURL, forURI: uri, title: title, itemID: itemID)
    }

    /// Looks up cached art by URI, exact title, or normalized title.
    /// Forwards to `ArtCacheService`.
    public func lookupCachedArt(uri: String?, title: String) -> String? {
        artCache.lookupCachedArt(uri: uri, title: title)
    }

    // MARK: - Grace Periods (centralized)

    private var transportGraceUntils: [String: Date] = [:]
    private var volumeGraceUntils: [String: Date] = [:]
    private var muteGraceUntils: [String: Date] = [:]
    private var modeGraceUntils: [String: Date] = [:]
    private var positionGraceUntils: [String: Date] = [:]

    public func setTransportGrace(groupID: String, duration: TimeInterval = 5) {
        transportGraceUntils[groupID] = Date().addingTimeInterval(duration)
    }

    public func setVolumeGrace(deviceID: String, duration: TimeInterval = 5) {
        volumeGraceUntils[deviceID] = Date().addingTimeInterval(duration)
    }

    public func setMuteGrace(deviceID: String, duration: TimeInterval = 5) {
        muteGraceUntils[deviceID] = Date().addingTimeInterval(duration)
    }

    public func setModeGrace(groupID: String, duration: TimeInterval = 5) {
        modeGraceUntils[groupID] = Date().addingTimeInterval(duration)
    }

    public func isVolumeGraceActive(deviceID: String) -> Bool {
        guard let until = volumeGraceUntils[deviceID] else { return false }
        return Date() < until
    }

    public func isMuteGraceActive(deviceID: String) -> Bool {
        guard let until = muteGraceUntils[deviceID] else { return false }
        return Date() < until
    }

    public func setPositionGrace(coordinatorID: String, duration: TimeInterval = 5) {
        positionGraceUntils[coordinatorID] = Date().addingTimeInterval(duration)
    }

    // MARK: - Settings

    @Published public var startupMode: StartupMode {
        didSet { UserDefaults.standard.set(startupMode.rawValue, forKey: UDKey.startupMode) }
    }

    @Published public var communicationMode: CommunicationMode {
        didSet {
            UserDefaults.standard.set(communicationMode.rawValue, forKey: UDKey.communicationMode)
            Task { await switchTransportStrategy() }
        }
    }

    @Published public var discoveryMode: DiscoveryMode {
        didSet {
            UserDefaults.standard.set(discoveryMode.rawValue, forKey: UDKey.discoveryMode)
            Task { @MainActor in await switchDiscoveryTransports() }
        }
    }

    @Published public var appearanceMode: AppearanceMode {
        didSet { UserDefaults.standard.set(appearanceMode.rawValue, forKey: UDKey.appearanceMode) }
    }

    @Published public var appLanguage: AppLanguage {
        didSet { UserDefaults.standard.set(appLanguage.rawValue, forKey: UDKey.appLanguage) }
    }

    @Published public var accentColor: StoredColor {
        didSet { accentColor.save(to: "accentColor") }
    }
    @Published public var playingZoneColor: StoredColor {
        didSet { playingZoneColor.save(to: "playingZoneColor") }
    }
    @Published public var inactiveZoneColor: StoredColor {
        didSet { inactiveZoneColor.save(to: "inactiveZoneColor") }
    }

    // MARK: - Services (injectable for testability)

    /// Active discovery transports. Populated by `applyDiscoveryMode()` based
    /// on `discoveryMode`. In `.auto` both SSDP and mDNS run concurrently;
    /// `discoveredLocations` (URL-keyed) is the dedup point so duplicate
    /// reports from the same speaker via two transports are harmless.
    private var discoveryTransports: [any SpeakerDiscovery] = []
    /// HouseholdID hints learned from mDNS TXT records, keyed by location URL.
    /// Consulted in `handleDiscoveredDevice` so we can skip `GetHouseholdID`
    /// when the network told us the answer for free.
    private var householdHints: [String: String] = [:]
    private let soap: SOAPClient
    private let cache: SonosCache
    // Lazy so services share a single SOAPClient (and its URLSession)
    private lazy var avTransport = AVTransportService(soap: soap)
    private lazy var renderingControl = RenderingControlService(soap: soap)
    private lazy var zoneTopology = ZoneGroupTopologyService(soap: soap)
    private lazy var contentDirectory = ContentDirectoryService(soap: soap)
    private lazy var alarmClock = AlarmClockService(soap: soap)
    private lazy var musicServices = MusicServicesService(soap: soap)

    private var discoveredLocations: Set<String> = []  // de-dups SSDP responses

    /// Tracks per-URI Apple-Music enrichment state so we don't fire
    /// duplicate iTunes lookups on every transport update tick.
    private var appleMusicEnrichmentInFlight: Set<String> = []

    /// Metadata cache used to persist Apple-Music-by-track-ID results
    /// across launches. Backed by the same SQLite file the lyrics /
    /// artist / album caches use. Lazy so we don't open the DB on
    /// SonosManager init for callers that never play Apple Music.
    private lazy var metadataCacheForAppleMusic: MetadataCacheRepository? = {
        let path = AppPaths.appSupportDirectory.appendingPathComponent("play_history.sqlite").path
        return MetadataCacheRepository(dbPath: path)
    }()

    /// Codable payload for the Apple-Music-by-track-ID enrichment cache.
    fileprivate struct AppleMusicTrackEnrichment: Codable, Sendable {
        let artist: String
        let album: String?
    }

    /// Cached track info — populated when adding Service Search items to queue.
    /// Used to recover title/artist when the speaker returns empty TrackMetaData.
    struct CachedTrack { let title: String; let artist: String; let album: String; let artURL: String? }
    private var cachedTrackInfo: [String: CachedTrack] = [:]          // keyed by URI
    private var cachedTrackByPosition: [String: [Int: CachedTrack]] = [:] // keyed by groupID -> queue position

    /// Last-fetched queue items per group — used for track info recovery
    private var lastQueueItems: [String: [QueueItem]] = [:]
    private var refreshTimer: Timer?
    private var refreshingHouseholds: Set<String> = []  // serializes topology refreshes per household (S1/S2 coexist)
    /// Last successful topology refresh per household. Used to throttle —
    /// within one 30 s rescan cycle we typically receive ~13 SSDP responses
    /// that would each otherwise trigger their own GetZoneGroupState call.
    /// S1 hardware is request-sensitive and can start returning inconsistent
    /// data under pressure, so we skip refreshes within 10 s of the last one.
    private var lastTopologyRefreshAt: [String: Date] = [:]
    private let topologyRefreshMinInterval: TimeInterval = 10  // seconds


    // MARK: - Transport Strategy

    private var transportStrategy: TransportStrategy?
    private var strategyStarted = false

    // Debug logging is in the sonosDebugLog free function below

    /// Number of active event subscriptions (for diagnostics in Settings)
    public var activeSubscriptionCount: Int {
        (transportStrategy as? HybridEventFirstTransport)?.activeSubscriptionCount ?? 0
    }

    /// Subscription details for diagnostics
    public var subscriptionDetails: [(sid: String, deviceID: String, service: String, expiresAt: Date)] {
        (transportStrategy as? HybridEventFirstTransport)?.subscriptionDetails ?? []
    }

    /// Event callback URL for diagnostics
    public var eventCallbackURL: String {
        (transportStrategy as? HybridEventFirstTransport)?.callbackURLString ?? "Not available"
    }

    /// Album-art search service (iTunes lookup). Public + protocol-typed
    /// so tests can inject a stub and call sites can use the same instance
    /// instead of reaching for `AlbumArtSearchService.shared`.
    public let albumArtSearch: AlbumArtSearchProtocol

    /// Default init with production services
    public convenience init() {
        self.init(soap: SOAPClient(), cache: SonosCache())
    }

    /// Injectable init for testing
    private var artCacheSubscription: AnyCancellable?

    public init(soap: SOAPClient,
                cache: SonosCache,
                albumArtSearch: AlbumArtSearchProtocol = AlbumArtSearchService.shared) {
        self.soap = soap
        self.cache = cache
        self.artCache = ArtCacheService(cache: cache)
        self.albumArtSearch = albumArtSearch

        let savedStartup = UserDefaults.standard.string(forKey: UDKey.startupMode) ?? StartupMode.quickStart.rawValue
        self.startupMode = StartupMode(rawValue: savedStartup) ?? .quickStart

        let savedComms = UserDefaults.standard.string(forKey: UDKey.communicationMode) ?? CommunicationMode.hybridEventFirst.rawValue
        self.communicationMode = CommunicationMode(rawValue: savedComms) ?? .hybridEventFirst

        let savedDiscovery = UserDefaults.standard.string(forKey: UDKey.discoveryMode) ?? DiscoveryMode.auto.rawValue
        self.discoveryMode = DiscoveryMode(rawValue: savedDiscovery) ?? .auto

        let savedAppearance = UserDefaults.standard.string(forKey: UDKey.appearanceMode) ?? AppearanceMode.system.rawValue
        self.appearanceMode = AppearanceMode(rawValue: savedAppearance) ?? .system

        // First launch: snapshot the macOS preferred language so the app
        // starts in the user's own language. Persist it so the choice is
        // stable across subsequent launches even if the OS setting changes.
        if let savedLang = UserDefaults.standard.string(forKey: UDKey.appLanguage),
           let lang = AppLanguage(rawValue: savedLang) {
            self.appLanguage = lang
        } else {
            let detected = AppLanguage.systemDefault
            UserDefaults.standard.set(detected.rawValue, forKey: UDKey.appLanguage)
            self.appLanguage = detected
        }

        self.accentColor = StoredColor.load(from: "accentColor", default: .system)
        self.playingZoneColor = StoredColor.load(from: "playingZoneColor", default: StoredColor(red: 0.2, green: 0.78, blue: 0.35))
        self.inactiveZoneColor = StoredColor.load(from: "inactiveZoneColor", default: StoredColor(red: 0.56, green: 0.56, blue: 0.58))

        rebuildDiscoveryTransports()

        // Forward art cache changes so views observing `sonosManager` re-render
        // when the cache updates (preserves the prior `@Published` semantics
        // that `discoveredArtURLs` had when it lived on this class).
        artCacheSubscription = artCache.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
    }

    // MARK: - Startup

    public func startDiscovery() {
        guard !isDiscovering else { return }

        // Restore persisted art URL mappings (independent of startup mode).
        artCache.loadFromDisk()

        // Quick Start: load cache first for instant UI
        if startupMode == .quickStart, let cached = cache.load() {
            let cachedDevices = cache.restoreDevices(from: cached)
            let cachedGroups = cache.restoreGroups(from: cached, devices: cachedDevices)
            let cachedSections = cache.restoreBrowseSections(from: cached)

            if !cachedGroups.isEmpty {
                self.devices = cachedDevices
                self.groups = cachedGroups
                self.browseSections = cachedSections
                self.isUsingCachedData = true
                self.cacheAge = cached.ageDescription
            }
        }

        // Start live discovery (runs in background regardless of cache)
        isDiscovering = true
        isRefreshing = true
        for t in discoveryTransports { t.startDiscovery() }

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.discoveredLocations.removeAll()
                for t in self.discoveryTransports { t.rescan() }
            }
        }
    }

    public func stopDiscovery() {
        isDiscovering = false
        for t in discoveryTransports { t.stopDiscovery() }
        refreshTimer?.invalidate()
        refreshTimer = nil

        Task {
            await transportStrategy?.stop()
            transportStrategy = nil
            strategyStarted = false
        }
    }

    public func rescan() {
        discoveredLocations.removeAll()
        isRefreshing = true
        for t in discoveryTransports { t.rescan() }
    }

    /// Builds the active transport list from `discoveryMode` and wires the
    /// shared `onDeviceFound` callback. Called once at init and again on
    /// every mode change.
    private func rebuildDiscoveryTransports() {
        let modes: [any SpeakerDiscovery]
        switch discoveryMode {
        case .auto:    modes = [SSDPDiscovery(), MDNSDiscovery()]
        case .bonjour: modes = [MDNSDiscovery()]
        case .ssdp:    modes = [SSDPDiscovery()]
        }
        for t in modes {
            t.onDeviceFound = { [weak self] location, ip, port, hh in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let hh, !hh.isEmpty {
                        self.householdHints[location] = hh
                    }
                    await self.handleDiscoveredDevice(location: location, ip: ip, port: port)
                }
            }
        }
        discoveryTransports = modes
    }

    /// Tears down current transports, rebuilds for the new mode, and (if we
    /// were already discovering) starts the new set + clears the dedup cache
    /// so the next announce paints over with a current view.
    @MainActor
    private func switchDiscoveryTransports() async {
        let wasRunning = isDiscovering
        for t in discoveryTransports { t.stopDiscovery() }
        rebuildDiscoveryTransports()
        discoveredLocations.removeAll()
        householdHints.removeAll()
        if wasRunning {
            isRefreshing = true
            for t in discoveryTransports { t.startDiscovery() }
        }
    }

    private func handleDiscoveredDevice(location: String, ip: String, port: Int) async {
        guard !discoveredLocations.contains(location) else { return }
        discoveredLocations.insert(location)

        do {
            guard let desc = try await DeviceDescriptionParser.fetch(from: location) else { return }

            var device = SonosDevice(
                id: desc.uuid,
                ip: ip,
                port: port,
                roomName: desc.roomName,
                modelName: desc.modelName,
                modelNumber: desc.modelNumber,
                softwareVersion: desc.softwareVersion,
                swGen: desc.swGen
            )

            // A speaker's household ID doesn't change at runtime (it's factory-set
            // and only updated by factory reset). Once resolved, never re-query —
            // this removes one SOAP round-trip per SSDP response per speaker, which
            // matters a lot for S1 hardware that's sensitive to request pressure.
            //
            // mDNS speakers advertise `hhid` in the TXT record, so when the discovery
            // transport surfaced it we skip the SOAP call entirely (`householdHints`).
            let existing = devices[device.id]
            device.householdID = existing?.householdID
            if device.householdID == nil, let hint = householdHints[location], !hint.isEmpty {
                device.householdID = hint
            }
            if device.householdID == nil {
                if let resolved = try? await zoneTopology.getHouseholdID(device: device), !resolved.isEmpty {
                    device.householdID = resolved
                }
            }

            sonosDebugLog("[DISCOVERY] \(desc.roomName) swGen=\(desc.swGen) softwareVersion=\(desc.softwareVersion) household=\(device.householdID ?? "<nil>")")

            // Guard the write — @Published fires on every assignment, even
            // when values are identical. Unnecessary fires cascade re-renders
            // through every @EnvironmentObject observer of SonosManager.
            if devices[device.id] != device {
                devices[device.id] = device
            }
            await refreshTopology(from: device)
        } catch {
            sonosDebugLog("[DISCOVERY] Device description fetch failed: \(error)")
        }
    }

    public func refreshTopology(from device: SonosDevice, force: Bool = false) async {
        // Serialize per-household so S1 and S2 refreshes don't block each other but also
        // don't race within a single household (main-actor re-entry across awaits).
        // Use source device UUID when householdID is not yet known (first discovery).
        let refreshKey = device.householdID ?? device.id
        guard !refreshingHouseholds.contains(refreshKey) else { return }

        // Throttle: skip refreshes that arrive within the minimum interval of
        // the previous successful refresh for this household. Keeps SSDP
        // response bursts (sub/satellite/coordinator all advertising per rescan)
        // from generating redundant GetZoneGroupState calls. User-initiated
        // group changes pass `force: true` to bypass this throttle and get
        // immediate UI feedback on the group/ungroup action.
        if !force,
           let last = lastTopologyRefreshAt[refreshKey],
           Date().timeIntervalSince(last) < topologyRefreshMinInterval {
            return
        }

        refreshingHouseholds.insert(refreshKey)
        defer { refreshingHouseholds.remove(refreshKey) }

        do {
            let groupData = try await zoneTopology.getZoneGroupState(device: device)

            // Members inherit the source device's household — all groups returned by
            // GetZoneGroupState belong to the same Sonos system (S1 or S2).
            // If the source's household is unknown (GetHouseholdID failed), abort
            // the merge rather than wipe S1/S2 partitioning with nil-tagged groups.
            guard let household = device.householdID else {
                sonosDebugLog("[DISCOVERY] Skipping topology merge — source device \(device.id) has no household yet")
                self.isRefreshing = false
                return
            }
            let sourceSoftwareVersion = device.softwareVersion
            let sourceSwGen = device.swGen

            // Trust the source's topology response as the authoritative view
            // of the household. Attempts to smooth over transient inconsistency
            // between different speakers' ZoneGroupState responses caused
            // phantom groups to accumulate (a group would be reported by one
            // speaker after it had been dissolved, then preserved forever by
            // the "keep what we haven't explicitly seen removed" logic). A
            // straightforward latest-response-wins model is eventually
            // consistent with reality, which is preferable to the phantom.
            var newGroups: [SonosGroup] = []
            for gd in groupData {
                var members: [SonosDevice] = []
                for md in gd.members {
                    // Preserve existing per-device fields if we've already fetched them
                    // (members may be full devices discovered via SSDP, not just topology stubs).
                    // Empty strings should not block the household-wide fallback, so prefer
                    // non-empty existing values and fall back to the source device.
                    let existing = devices[md.uuid]
                    let existingSoftwareVersion = existing?.softwareVersion ?? ""
                    let existingSwGen = existing?.swGen ?? ""
                    let softwareVersion = existingSoftwareVersion.isEmpty ? sourceSoftwareVersion : existingSoftwareVersion
                    let swGen = existingSwGen.isEmpty ? sourceSwGen : existingSwGen
                    let dev = SonosDevice(
                        id: md.uuid,
                        ip: md.ip,
                        port: md.port,
                        roomName: md.zoneName,
                        modelName: existing?.modelName ?? "",
                        modelNumber: existing?.modelNumber ?? "",
                        softwareVersion: softwareVersion,
                        swGen: swGen,
                        householdID: household,
                        isCoordinator: md.uuid == gd.coordinatorUUID,
                        groupID: gd.id
                    )
                    // Guard the write to avoid spurious @Published fires that
                    // cascade through @EnvironmentObject re-renders and can
                    // cause onChange-driven scroll animations to trigger
                    // even when the topology is unchanged.
                    if devices[dev.id] != dev {
                        devices[dev.id] = dev
                    }
                    // Invisible members are Sub/Surround satellites — hide from UI
                    if !md.isInvisible {
                        members.append(dev)
                    }
                }
                // Sort members by id so the stored order is deterministic regardless
                // of the order the speaker returned them in — otherwise the equality
                // check below can false-positive on a pure reorder and cause flicker.
                let stableMembers = members.sorted { $0.id < $1.id }
                let group = SonosGroup(id: gd.id, coordinatorID: gd.coordinatorUUID,
                                       members: stableMembers, householdID: household)
                newGroups.append(group)
            }

            // Backfill nil householdID on legacy (pre-upgrade) cached groups whose
            // coordinator is now a known device with a household. Without this, stale
            // cache entries would surface as an "Unknown" tab after the first refresh.
            let backfilledGroups = groups.map { g -> SonosGroup in
                guard g.householdID == nil else { return g }
                guard let coord = devices[g.coordinatorID], let hh = coord.householdID else { return g }
                var patched = g
                patched.householdID = hh
                return patched
            }

            // Simple, correct merge: the source's full topology response
            // replaces every group in its household. Other-household groups
            // (S1 while refreshing S2 and vice versa) are preserved untouched.
            // No grace windows: user-initiated grouping/ungrouping actions need
            // immediate UI feedback, and any smoothing we layer on top of
            // Sonos's topology inconsistency ends up creating stale/phantom
            // groups that are worse than the underlying flicker.
            let otherHouseholdGroups = backfilledGroups.filter { $0.householdID != household }
            let mergedGroups = (otherHouseholdGroups + newGroups)
                .sorted { $0.name < $1.name }

            // Only update groups if topology actually changed — prevents UI flash.
            // SonosGroup is Equatable by synthesis (all fields Equatable), so full
            // value equality on the sorted array is both correct and order-tolerant
            // now that member arrays are stably sorted above.
            let didChange = mergedGroups != groups
            if didChange {
                // Diff the sets so we can see exactly which groups appeared or
                // disappeared — the "speaker disappearing then coming back"
                // symptom shows up as alternating added/removed for the same id.
                let oldIDs = Set(groups.map(\.id))
                let newIDs = Set(mergedGroups.map(\.id))
                let added = newIDs.subtracting(oldIDs).sorted()
                let removed = oldIDs.subtracting(newIDs).sorted()
                // For groups present in both, log any member-list differences.
                let newByID = Dictionary(uniqueKeysWithValues: mergedGroups.map { ($0.id, $0) })
                let oldByID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
                var memberDiffs: [String] = []
                for id in newIDs.intersection(oldIDs).sorted() {
                    guard let n = newByID[id], let o = oldByID[id] else { continue }
                    if n != o {
                        let newMembers = n.members.map(\.roomName).joined(separator: ",")
                        let oldMembers = o.members.map(\.roomName).joined(separator: ",")
                        memberDiffs.append("\(id): [\(oldMembers)] -> [\(newMembers)]")
                    }
                }
                sonosDebugLog("[MERGE] source=\(device.roomName) household=\(household) newCount=\(newGroups.count) totalCount=\(mergedGroups.count) changed=true added=\(added) removed=\(removed) memberDiffs=\(memberDiffs)")
                self.groups = mergedGroups
                saveCache()
            } else {
                sonosDebugLog("[MERGE] source=\(device.roomName) household=\(household) newCount=\(newGroups.count) totalCount=\(mergedGroups.count) changed=false")
            }

            // Record the successful refresh so the throttle can skip bursts.
            lastTopologyRefreshAt[refreshKey] = Date()

            // Parse home theater channel maps
            parseHTChannelMaps(from: groupData)

            self.isUsingCachedData = false
            self.isRefreshing = false
            self.staleMessage = nil

            // Start or update transport strategy
            await startOrUpdateTransportStrategy()

            // Scan all groups for current status in background (don't block UI)
            Task { await scanAllGroups() }
        } catch {
            sonosDebugLog("[DISCOVERY] Topology fetch failed: \(error)")
        }
    }

    /// Parses HTSatChanMapSet from topology data to identify surround/sub configurations
    private func parseHTChannelMaps(from groupData: [ZoneGroupData]) {
        var maps: [String: [(String, SpeakerChannel)]] = [:]
        for gd in groupData {
            for md in gd.members where !md.htSatChanMapSet.isEmpty {
                // Format: "RINCON_xxx:LF,RF;RINCON_yyy:SW;RINCON_zzz:LR;RINCON_www:RR"
                var channelList: [(String, SpeakerChannel)] = []
                let pairs = md.htSatChanMapSet.components(separatedBy: ";")
                for pair in pairs {
                    let parts = pair.components(separatedBy: ":")
                    guard parts.count == 2 else { continue }
                    let deviceID = parts[0]
                    let channelStr = parts[1]
                    if let channel = SpeakerChannel(rawValue: channelStr) {
                        channelList.append((deviceID, channel))
                    }
                }
                if !channelList.isEmpty {
                    maps[gd.coordinatorUUID] = channelList
                    break // Only need it from the coordinator's entry
                }
            }
        }
        htSatChannelMaps = maps
    }

    // MARK: - Manual Status Scan

    /// Scans all groups for current transport state, volume, mute.
    /// Called on app launch after discovery completes.
    public func scanAllGroups() async {
        for group in groups {
            await scanGroup(group)
        }
    }

    /// Scans a single group for current transport state, track metadata, volume, mute.
    /// Called when user selects a speaker/group.
    public func scanGroup(_ group: SonosGroup) async {
        guard let coordinator = group.coordinator else { return }
        do {
            let state = try await avTransport.getTransportInfo(device: coordinator)
            let position = try await avTransport.getPositionInfo(device: coordinator)
            let mode = try await avTransport.getTransportSettings(device: coordinator)

            if groupTransportStates[coordinator.id] != state {
                groupTransportStates[coordinator.id] = state
            }
            if groupPlayModes[coordinator.id] != mode {
                groupPlayModes[coordinator.id] = mode
            }

            // Pre-fetch queue items so track info recovery works for service tracks
            if lastQueueItems[coordinator.id] == nil || lastQueueItems[coordinator.id]?.isEmpty == true {
                if let queueResult = try? await contentDirectory.browseQueue(device: coordinator, start: 0, count: PageSize.queue) {
                    lastQueueItems[coordinator.id] = queueResult.items
                }
            }

            var enriched = position
            // Always fetch mediaInfo to set isQueueSource correctly
            // (prevents queue metadata leaking into direct stream playback)
            if let mediaInfo = try? await avTransport.getMediaInfo(device: coordinator) {
                enriched.enrichFromMediaInfo(mediaInfo, device: coordinator)
            }
            transportDidUpdateTrackMetadata(coordinator.id, metadata: enriched)

            for member in group.members {
                let vol = try await renderingControl.getVolume(device: member)
                let muted = try await renderingControl.getMute(device: member)
                updateDeviceVolume(member.id, volume: vol)
                updateDeviceMute(member.id, muted: muted)
            }
        } catch {
            sonosDebugLog("[SCAN] Group scan failed for \(group.name): \(error)")
        }
    }

    // MARK: - Transport Strategy Management

    private func startOrUpdateTransportStrategy() async {
        if !strategyStarted {
            let strategy = createStrategy()
            strategy.delegate = self
            transportStrategy = strategy
            strategyStarted = true
            await strategy.start(groups: groups, devices: devices)
        } else if let strategy = transportStrategy {
            await strategy.onGroupsChanged(groups, devices: devices)
        }
    }

    private func switchTransportStrategy() async {
        // Stop current strategy
        if let oldStrategy = transportStrategy {
            await oldStrategy.stop()
        }

        // Clear state so views re-initialize
        groupTransportStates.removeAll()
        groupTrackMetadata.removeAll()
        groupPlayModes.removeAll()
        groupPositions.removeAll()
        groupDurations.removeAll()
        deviceVolumes.removeAll()
        deviceMutes.removeAll()

        // Start new strategy
        let strategy = createStrategy()
        strategy.delegate = self
        transportStrategy = strategy
        strategyStarted = true
        await strategy.start(groups: groups, devices: devices)
    }

    private func createStrategy() -> TransportStrategy {
        switch communicationMode {
        case .hybridEventFirst:
            return HybridEventFirstTransport()
        case .legacyPolling:
            return LegacyPollingTransport()
        }
    }

    private func saveCache() {
        cache.save(groups: groups, devices: devices, browseSections: browseSections)
    }

    public func clearCache() {
        cache.clear()
    }

    // MARK: - Stale Data Handling

    /// Wraps a SOAP action with stale-data detection. If the action fails due to
    /// network error (device unreachable), triggers a background refresh and shows a message.
    /// This is the key mechanism for gracefully recovering from cached data that has gone stale:
    /// code 701 = "invalid object" (speaker regrouped), s:Client = generic SOAP client error.
    private func withStaleHandling<T>(for roomName: String, _ action: () async throws -> T) async throws -> T {
        do {
            return try await action()
        } catch let error as SOAPError {
            switch error {
            case .networkError:
                staleMessage = "\(roomName) is not responding. Refreshing speakers..."
                rescan()
                throw StaleDataError.deviceUnreachable(roomName)
            case .soapFault(let code, _) where code == "701" || code == "s:Client":
                staleMessage = "Command failed — speaker layout may have changed. Refreshing..."
                rescan()
                throw StaleDataError.topologyStale
            default:
                throw error
            }
        }
    }

    public func dismissStaleMessage() {
        staleMessage = nil
    }

    // MARK: - Playback Control

    public func play(group: SonosGroup) async throws {
        guard let coordinator = group.coordinator else { return }
        try await withStaleHandling(for: group.name) {
            try await avTransport.play(device: coordinator)
        }
    }

    public func pause(group: SonosGroup) async throws {
        guard let coordinator = group.coordinator else { return }
        try await withStaleHandling(for: group.name) {
            try await avTransport.pause(device: coordinator)
        }
    }

    public func stop(group: SonosGroup) async throws {
        guard let coordinator = group.coordinator else { return }
        try await withStaleHandling(for: group.name) {
            try await avTransport.stop(device: coordinator)
        }
    }

    public func next(group: SonosGroup) async throws {
        guard let coordinator = group.coordinator else { return }
        try await withStaleHandling(for: group.name) {
            try await avTransport.next(device: coordinator)
        }
    }

    public func previous(group: SonosGroup) async throws {
        guard let coordinator = group.coordinator else { return }
        try await withStaleHandling(for: group.name) {
            try await avTransport.previous(device: coordinator)
        }
    }

    public func seek(group: SonosGroup, to time: String) async throws {
        guard let coordinator = group.coordinator else { return }
        try await avTransport.seek(device: coordinator, to: time)
    }

    public func getTransportState(group: SonosGroup) async throws -> TransportState {
        guard let coordinator = group.coordinator else { return .stopped }
        return try await avTransport.getTransportInfo(device: coordinator)
    }

    public func getMediaInfo(group: SonosGroup) async throws -> [String: String] {
        guard let coordinator = group.coordinator else { return [:] }
        return try await avTransport.getMediaInfo(device: coordinator)
    }

    public func getPositionInfo(group: SonosGroup) async throws -> TrackMetadata {
        guard let coordinator = group.coordinator else { return TrackMetadata() }
        return try await avTransport.getPositionInfo(device: coordinator)
    }

    // MARK: - Play Mode

    public func getPlayMode(group: SonosGroup) async throws -> PlayMode {
        guard let coordinator = group.coordinator else { return .normal }
        return try await avTransport.getTransportSettings(device: coordinator)
    }

    public func setPlayMode(group: SonosGroup, mode: PlayMode) async throws {
        guard let coordinator = group.coordinator else { return }
        try await avTransport.setPlayMode(device: coordinator, mode: mode)
    }

    // MARK: - Crossfade

    public func getCrossfadeMode(group: SonosGroup) async throws -> Bool {
        guard let coordinator = group.coordinator else { return false }
        return try await avTransport.getCrossfadeMode(device: coordinator)
    }

    public func setCrossfadeMode(group: SonosGroup, enabled: Bool) async throws {
        guard let coordinator = group.coordinator else { return }
        try await avTransport.setCrossfadeMode(device: coordinator, enabled: enabled)
    }

    // MARK: - Pause / Resume All

    public func pauseAll() async {
        for group in groups {
            guard groupTransportStates[group.coordinatorID]?.isPlaying == true else { continue }
            try? await pause(group: group)
        }
    }

    public func resumeAll() async {
        for group in groups {
            guard groupTransportStates[group.coordinatorID] == .paused else { continue }
            try? await play(group: group)
        }
    }

    // MARK: - Sleep Timer

    public func setSleepTimer(group: SonosGroup, duration: String) async throws {
        guard let coordinator = group.coordinator else { return }
        try await avTransport.configureSleepTimer(device: coordinator, duration: duration)
    }

    public func cancelSleepTimer(group: SonosGroup) async throws {
        guard let coordinator = group.coordinator else { return }
        try await avTransport.configureSleepTimer(device: coordinator, duration: "")
    }

    public func getSleepTimerRemaining(group: SonosGroup) async throws -> String {
        guard let coordinator = group.coordinator else { return "" }
        return try await avTransport.getSleepTimerRemaining(device: coordinator)
    }

    // MARK: - Volume Control

    public func getVolume(device: SonosDevice) async throws -> Int {
        try await renderingControl.getVolume(device: device)
    }

    public func setVolume(device: SonosDevice, volume: Int) async throws {
        try await renderingControl.setVolume(device: device, volume: volume)
    }

    public func getMute(device: SonosDevice) async throws -> Bool {
        try await renderingControl.getMute(device: device)
    }

    public func setMute(device: SonosDevice, muted: Bool) async throws {
        try await renderingControl.setMute(device: device, muted: muted)
    }

    // MARK: - EQ

    public func getBass(device: SonosDevice) async throws -> Int {
        try await renderingControl.getBass(device: device)
    }

    public func setBass(device: SonosDevice, bass: Int) async throws {
        try await renderingControl.setBass(device: device, bass: bass)
    }

    public func getTreble(device: SonosDevice) async throws -> Int {
        try await renderingControl.getTreble(device: device)
    }

    public func setTreble(device: SonosDevice, treble: Int) async throws {
        try await renderingControl.setTreble(device: device, treble: treble)
    }

    public func getLoudness(device: SonosDevice) async throws -> Bool {
        try await renderingControl.getLoudness(device: device)
    }

    public func setLoudness(device: SonosDevice, enabled: Bool) async throws {
        try await renderingControl.setLoudness(device: device, enabled: enabled)
    }

    // MARK: - Home Theater EQ

    public func getEQ(device: SonosDevice, eqType: String) async throws -> Int {
        try await renderingControl.getEQ(device: device, eqType: eqType)
    }

    public func setEQ(device: SonosDevice, eqType: String, value: Int) async throws {
        try await renderingControl.setEQ(device: device, eqType: eqType, value: value)
    }

    /// Returns bonded home theater zones (those with HTSatChanMapSet — sub/surrounds)
    public var homeTheaterZones: [HomeTheaterZone] {
        var zones: [HomeTheaterZone] = []
        for group in groups {
            guard let coordinator = group.coordinator else { continue }
            // Check if this coordinator has satellite channel info
            if let channelMap = htSatChannelMaps[coordinator.id] {
                var members: [HomeTheaterMember] = []
                // Add coordinator as LF,RF (soundbar)
                members.append(HomeTheaterMember(device: coordinator, channel: .soundbar))
                // Add satellites
                for (deviceID, channel) in channelMap {
                    if let device = devices[deviceID], deviceID != coordinator.id {
                        members.append(HomeTheaterMember(device: device, channel: channel))
                    }
                }
                zones.append(HomeTheaterZone(
                    coordinatorID: coordinator.id,
                    name: coordinator.roomName,
                    members: members.sorted { $0.channel.sortOrder < $1.channel.sortOrder }
                ))
            }
        }
        return zones
    }

    /// Parsed HTSatChanMapSet data: coordinator ID → [(deviceID, channel)]
    @Published public var htSatChannelMaps: [String: [(String, SpeakerChannel)]] = [:]

    // MARK: - Queue

    public func getQueue(group: SonosGroup, start: Int = 0, count: Int = PageSize.queue) async throws -> (items: [QueueItem], total: Int) {
        guard let coordinator = group.coordinator else { return ([], 0) }
        let result = try await contentDirectory.browseQueue(device: coordinator, start: start, count: count)
        // Cache queue items for track info recovery (Apple Music tracks may have empty GetPositionInfo)
        if start == 0 && !result.items.isEmpty {
            lastQueueItems[group.coordinatorID] = result.items
        }
        return result
    }

    public func removeFromQueue(group: SonosGroup, trackIndex: Int) async throws {
        guard let coordinator = group.coordinator else { return }
        try await contentDirectory.removeTrackFromQueue(device: coordinator, objectID: "Q:0/\(trackIndex)")
    }

    public func clearQueue(group: SonosGroup) async throws {
        guard let coordinator = group.coordinator else { return }

        // Detect whether the currently-playing source is the queue itself
        // BEFORE we remove its rows. If it is, the speaker will keep
        // showing the (now-orphaned) track in `Track 1` until it advances
        // to a non-existent next position, which leaves the Now Playing
        // header stale. Stop transport and clear local metadata too so
        // the UI matches the new empty state immediately.
        let wasPlayingFromQueue = groupTrackMetadata[group.coordinatorID]?.isQueueSource == true

        try await contentDirectory.removeAllTracksFromQueue(device: coordinator)
        lastQueueItems[group.coordinatorID] = nil
        cachedTrackByPosition[group.coordinatorID] = nil

        if wasPlayingFromQueue {
            try? await avTransport.stop(device: coordinator)
            groupTrackMetadata[coordinator.id] = TrackMetadata()
            groupTransportStates[coordinator.id] = .stopped
            groupPositions[coordinator.id] = 0
            awaitingPlayback[coordinator.id] = false
        }
    }

    /// "Play All" / "Replace Queue" semantics with audio-first sequencing.
    /// Clears the queue, adds the first track, starts playback immediately,
    /// then fills the rest of the queue in the background. The user gets
    /// audio in ~1 SOAP round-trip instead of waiting for all N tracks to
    /// enqueue first.
    ///
    /// Background fill toggles `isAddingToQueue` so the QueueView shows a
    /// spinner inline; no `ErrorHandler.shared.info(...)` banner is posted
    /// (this path is fast, the spinner already communicates "still
    /// loading").
    public func playItemsReplacingQueue(_ items: [BrowseItem], in group: SonosGroup) async throws {
        guard let coordinator = group.coordinator, !items.isEmpty else { return }

        let playable = items.filter { ($0.resourceURI ?? "").isEmpty == false }
        guard let first = playable.first else { return }

        try await contentDirectory.removeAllTracksFromQueue(device: coordinator)
        lastQueueItems[group.coordinatorID] = nil
        cachedTrackByPosition[group.coordinatorID] = nil

        // 1. First track + immediate playback.
        if let uri = first.resourceURI, !uri.isEmpty {
            // Preload cached track info so any speaker poll that arrives
            // before our background fill writes art/title can recover it.
            let cached = CachedTrack(title: first.title,
                                     artist: first.artist ?? "",
                                     album: first.album ?? "",
                                     artURL: first.albumArtURI)
            if !first.title.isEmpty {
                cachedTrackInfo[uri] = cached
                if let decoded = uri.removingPercentEncoding, decoded != uri {
                    cachedTrackInfo[decoded] = cached
                }
            }

            var meta = first.resourceMetadata ?? ""
            if meta.contains("&lt;") { meta = XMLResponseParser.xmlUnescape(meta) }
            _ = try await contentDirectory.addURIToQueue(
                device: coordinator, uri: uri, metadata: meta,
                desiredFirstTrackNumberEnqueued: 0, enqueueAsNext: false
            )
            try await avTransport.setAVTransportURI(
                device: coordinator,
                uri: "x-rincon-queue:\(coordinator.id)#0"
            )
            try await avTransport.play(device: coordinator)
            // Show optimistic now-playing metadata immediately so the UI
            // updates before the speaker's first transport tick.
            var pendingMeta = TrackMetadata()
            pendingMeta.title = first.title
            pendingMeta.artist = first.artist ?? ""
            pendingMeta.album = first.album ?? ""
            pendingMeta.albumArtURI = first.albumArtURI
            pendingMeta.trackURI = uri
            groupTrackMetadata[coordinator.id] = pendingMeta
            groupTransportStates[coordinator.id] = .transitioning
            awaitingPlayback[coordinator.id] = true
            setTransportGrace(groupID: coordinator.id, duration: Timing.playbackGracePeriod)
        }

        // First-track refresh: Browse(Q:0) right now so the queue panel
        // shows the one row that's been enqueued + playing while the
        // background fill is still running. Without this, the panel
        // sits empty for the few seconds it takes the background fill
        // to do its first chunk and then refresh.
        postQueueChanged(optimisticItems: [])

        // 2. Remaining tracks in background.
        let rest = Array(playable.dropFirst())
        if !rest.isEmpty {
            Task { [weak self] in
                await self?.fillQueueInBackground(rest, in: group)
            }
        }
    }

    /// Background batched enqueue used after `playItemsReplacingQueue`
    /// has the first track playing. Sets `isAddingToQueue` so QueueView
    /// shows its spinner; never posts the green status banner.
    private func fillQueueInBackground(_ items: [BrowseItem], in group: SonosGroup) async {
        guard let coordinator = group.coordinator, !items.isEmpty else { return }
        isAddingToQueue = true
        defer {
            isAddingToQueue = false
            postQueueChanged(optimisticItems: [])
        }

        var uris: [String] = []
        var metas: [String] = []
        for item in items {
            guard let uri = item.resourceURI, !uri.isEmpty, !item.isContainer else { continue }
            uris.append(uri)
            var meta = item.resourceMetadata ?? ""
            if meta.contains("&lt;") { meta = XMLResponseParser.xmlUnescape(meta) }
            metas.append(meta)
            if !item.title.isEmpty {
                let cached = CachedTrack(title: item.title,
                                         artist: item.artist ?? "",
                                         album: item.album ?? "",
                                         artURL: item.albumArtURI)
                cachedTrackInfo[uri] = cached
                if let decoded = uri.removingPercentEncoding, decoded != uri {
                    cachedTrackInfo[decoded] = cached
                }
            }
        }
        guard !uris.isEmpty else { return }

        let chunkSize = 16
        for chunkStart in stride(from: 0, to: uris.count, by: chunkSize) {
            let end = min(chunkStart + chunkSize, uris.count)
            do {
                _ = try await contentDirectory.addMultipleURIsToQueue(
                    device: coordinator,
                    uris: Array(uris[chunkStart..<end]),
                    metadatas: Array(metas[chunkStart..<end]),
                    desiredFirstTrackNumberEnqueued: 0,
                    enqueueAsNext: false
                )
                sonosDebugLog("[QUEUE] Background fill chunk \(chunkStart)-\(end-1): \(end-chunkStart) tracks")
                // Refresh the queue panel after each chunk so large
                // playlists fill in visibly instead of jumping from
                // 1 track → N tracks at the very end.
                postQueueChanged(optimisticItems: [])
            } catch {
                sonosDebugLog("[QUEUE] Background fill chunk \(chunkStart)-\(end-1) failed: \(error). Continuing.")
            }
        }
    }

    public func playTrackFromQueue(group: SonosGroup, trackNumber: Int) async throws {
        guard let coordinator = group.coordinator else { return }

        // Fully clear existing metadata — we're switching source
        groupTrackMetadata[coordinator.id] = TrackMetadata()

        // Ensure transport is pointing at the queue (not a radio stream etc.)
        try await avTransport.setAVTransportURI(
            device: coordinator, uri: "x-rincon-queue:\(coordinator.id)#0"
        )
        try await contentDirectory.seekToTrack(device: coordinator, trackNumber: trackNumber)
        try await avTransport.play(device: coordinator)

        // Immediately fetch the new track's metadata — set directly (skip merge logic)
        groupTransportStates[coordinator.id] = .playing
        setTransportGrace(groupID: coordinator.id, duration: Timing.defaultGracePeriod)
        let position = try await avTransport.getPositionInfo(device: coordinator)
        groupTrackMetadata[coordinator.id] = position
    }

    public func moveTrackInQueue(group: SonosGroup, from: Int, to: Int) async throws {
        guard let coordinator = group.coordinator else { return }
        try await contentDirectory.reorderTracksInQueue(device: coordinator, startIndex: from, numberOfTracks: 1, insertBefore: to)
    }

    // MARK: - Playlist Management

    /// Saves the current queue as a new Sonos playlist using SaveQueue
    public func saveQueueAsPlaylist(group: SonosGroup, title: String) async throws -> String {
        guard let coordinator = group.coordinator else { return "" }
        return try await contentDirectory.saveQueue(device: coordinator, title: title)
    }

    /// Adds a browse item to an existing Sonos playlist
    public func addToPlaylist(playlistID: String, item: BrowseItem) async throws {
        guard let device = preferredDevice else { return }
        guard let uri = item.resourceURI, !uri.isEmpty else { return }
        var meta = item.resourceMetadata ?? ""
        if meta.contains("&lt;") { meta = XMLResponseParser.xmlUnescape(meta) }
        _ = try await contentDirectory.addURIToSavedQueue(device: device, objectID: playlistID, uri: uri, metadata: meta)
    }

    /// Deletes a Sonos playlist
    public func deletePlaylist(playlistID: String) async throws {
        guard let device = preferredDevice else { return }
        try await contentDirectory.destroyObject(device: device, objectID: playlistID)
    }

    /// Renames a Sonos playlist
    public func renamePlaylist(playlistID: String, oldTitle: String, newTitle: String) async throws {
        guard let device = preferredDevice else { return }
        try await contentDirectory.renameSavedQueue(device: device, objectID: playlistID, oldTitle: oldTitle, newTitle: newTitle)
    }

    /// Plays a raw URI (used for replaying history entries)
    public func playURI(group: SonosGroup, uri: String, metadata: String = "",
                        title: String = "", artist: String = "", stationName: String = "",
                        albumArtURI: String? = nil) async throws {
        guard let coordinator = group.coordinator else { return }

        // Set optimistic metadata immediately so the player view updates
        var pendingMeta = TrackMetadata()
        pendingMeta.title = title
        pendingMeta.artist = artist
        pendingMeta.stationName = stationName
        pendingMeta.albumArtURI = albumArtURI
        pendingMeta.trackURI = uri
        groupTrackMetadata[coordinator.id] = pendingMeta
        groupTransportStates[coordinator.id] = .transitioning
        awaitingPlayback[coordinator.id] = true
        setTransportGrace(groupID: coordinator.id, duration: Timing.playbackGracePeriod)

        try await avTransport.setAVTransportURI(device: coordinator, uri: uri, metadata: metadata)
        try await avTransport.play(device: coordinator)
    }

    // MARK: - Grouping

    /// Joins a device to an existing group by pointing its transport at the coordinator's rincon URI
    public func joinGroup(device: SonosDevice, toCoordinator coordinator: SonosDevice) async throws {
        let uri = "x-rincon:\(coordinator.id)"
        try await avTransport.setAVTransportURI(device: device, uri: uri)
        // User-initiated change — bypass the throttle so the sidebar reflects
        // the new grouping immediately.
        await refreshTopology(from: coordinator, force: true)
    }

    public func ungroupDevice(_ device: SonosDevice) async throws {
        try await avTransport.becomeCoordinatorOfStandaloneGroup(device: device)
        await refreshTopology(from: device, force: true)
    }

    // MARK: - Alarms

    /// Cached alarm list — populated by refreshAlarms(), read by UI
    @Published public var cachedAlarms: [SonosAlarm] = []

    /// Fetches alarms from all coordinators, picks the most complete list, caches it.
    public func refreshAlarms() async {
        var bestAlarms: [SonosAlarm] = []
        let candidates = groups.compactMap(\.coordinator)
        sonosDebugLog("[ALARM] refreshAlarms: querying \(candidates.count) coordinators")
        for device in candidates {
            do {
                let result = try await alarmClock.listAlarms(device: device)
                sonosDebugLog("[ALARM]   \(device.roomName) (\(device.ip)): \(result.count) alarms")
                if result.count > bestAlarms.count {
                    bestAlarms = result
                }
            } catch {
                sonosDebugLog("[ALARM]   \(device.roomName) (\(device.ip)): failed - \(error)")
            }
        }
        for i in bestAlarms.indices {
            if let dev = devices[bestAlarms[i].roomUUID] {
                bestAlarms[i].roomName = dev.roomName
            }
        }
        cachedAlarms = bestAlarms.sorted { $0.startTime < $1.startTime }
        sonosDebugLog("[ALARM] refreshAlarms done: \(cachedAlarms.count) alarms cached")
    }

    public func getAlarms() async throws -> [SonosAlarm] {
        await refreshAlarms()
        return cachedAlarms
    }

    @discardableResult
    public func createAlarm(_ alarm: SonosAlarm) async throws -> Int {
        guard let anyDevice = preferredDevice else { return 0 }
        return try await alarmClock.createAlarm(device: anyDevice, alarm: alarm)
    }

    public func updateAlarm(_ alarm: SonosAlarm) async throws {
        guard let anyDevice = preferredDevice else { return }
        try await alarmClock.updateAlarm(device: anyDevice, alarm: alarm)
    }

    public func deleteAlarm(_ alarm: SonosAlarm) async throws {
        guard let anyDevice = preferredDevice else { return }
        try await alarmClock.destroyAlarm(device: anyDevice, alarmID: alarm.id)
    }

    // MARK: - Browse

    public func loadBrowseSections() async {
        guard let anyDevice = preferredDevice else { return }

        var sections: [BrowseSection] = []

        sections.append(BrowseSection(id: "favorites", title: "Sonos Favorites", objectID: BrowseID.favorites, icon: "star.fill"))

        if let total = await probeContainer(device: anyDevice, objectID: BrowseID.playlists), total > 0 {
            sections.append(BrowseSection(id: "playlists", title: "Sonos Playlists", objectID: BrowseID.playlists, icon: "music.note.list"))
        }

        do {
            let (items, _) = try await contentDirectory.browse(device: anyDevice, objectID: BrowseID.libraryRoot, start: 0, count: 20)
            for item in items {
                let icon = libraryIcon(for: item.objectID)
                sections.append(BrowseSection(id: item.objectID, title: item.title, objectID: item.objectID, icon: icon))
            }
        } catch {
            sections.append(BrowseSection(id: "artists", title: "Artists", objectID: BrowseID.albumArtist, icon: "person.2"))
            sections.append(BrowseSection(id: "albums", title: "Albums", objectID: BrowseID.album, icon: "square.stack"))
            sections.append(BrowseSection(id: "tracks", title: "Tracks", objectID: BrowseID.tracks, icon: "music.note"))
        }

        if let total = await probeContainer(device: anyDevice, objectID: BrowseID.shares), total > 0 {
            sections.append(BrowseSection(id: "shares", title: "Music Library Folders", objectID: BrowseID.shares, icon: "externaldrive.connected.to.line.below"))
        }

        // Radio directory (R:0) hidden — requires TuneIn/service integration not yet enabled
        // if let total = await probeContainer(device: anyDevice, objectID: "R:0"), total > 0 {
        //     sections.append(BrowseSection(id: "radio", title: "Radio", objectID: "R:0", icon: "antenna.radiowaves.left.and.right"))
        // }

        self.browseSections = sections
        saveCache()
    }

    public func loadMusicServices() async {
        guard musicServicesList.isEmpty else { return }
        for attempt in 0..<3 {
            if attempt > 0 {
                try? await Task.sleep(for: .seconds(Timing.musicServicesRetryDelay))
            }
            do {
                let all = try await getAvailableMusicServices()
                if !all.isEmpty {
                    musicServicesList = all
                    return
                }
            } catch {
                sonosDebugLog("[SERVICES] Music services load attempt failed: \(error)")
            }
        }
    }

    /// Checks if a content container exists and has items (count=0 means just get the total)
    private func probeContainer(device: SonosDevice, objectID: String) async -> Int? {
        do {
            let (_, total) = try await contentDirectory.browse(device: device, objectID: objectID, start: 0, count: 0)
            return total
        } catch {
            return nil
        }
    }

    private func libraryIcon(for objectID: String) -> String {
        switch objectID {
        case "A:ALBUMARTIST", "A:ARTIST": return "person.2"
        case "A:ALBUM": return "square.stack"
        case "A:GENRE": return "guitars"
        case "A:TRACKS": return "music.note"
        case "A:COMPOSER": return "music.quarternote.3"
        case "A:PLAYLISTS": return "list.bullet.rectangle"
        default: return "folder"
        }
    }

    public func browseMetadata(objectID: String) async throws -> BrowseItem? {
        guard let anyDevice = preferredDevice else { return nil }
        return try await contentDirectory.browseMetadata(device: anyDevice, objectID: objectID)
    }

    public func browse(objectID: String, start: Int = 0, count: Int = PageSize.browse) async throws -> (items: [BrowseItem], total: Int) {
        guard let anyDevice = preferredDevice else { return ([], 0) }
        return try await contentDirectory.browse(device: anyDevice, objectID: objectID, start: start, count: count)
    }

    public func search(query: String, in containerID: String = BrowseID.tracks, start: Int = 0, count: Int = PageSize.search) async throws -> (items: [BrowseItem], total: Int) {
        guard let anyDevice = preferredDevice else { return ([], 0) }
        return try await contentDirectory.search(device: anyDevice, containerID: containerID, searchTerm: query, start: start, count: count)
    }

    // MARK: - Play from Browse

    public func playBrowseItem(_ item: BrowseItem, in group: SonosGroup) async throws {
        guard let coordinator = group.coordinator else { return }

        // Remember which favorite was played so art can be mapped back
        lastPlayedFavoriteID = item.objectID

        // Cache external art URL (e.g. from iTunes Search API) so it persists
        // in play history and NowPlaying even after the speaker returns different metadata
        if let art = item.albumArtURI, art.hasPrefix("http"), !art.contains("/getaa?") {
            cacheArtURL(art, forURI: item.resourceURI ?? "", title: item.title, itemID: item.objectID)
        }

        // Cache track info for recovery when speaker returns empty metadata
        if let uri = item.resourceURI, !item.title.isEmpty {
            cachedTrackInfo[uri] = CachedTrack(
                title: item.title, artist: item.artist ?? "",
                album: item.album ?? "", artURL: item.albumArtURI
            )
        }

        // Build metadata from browse item for UI display
        let isRadioStream = item.resourceURI.map(URIPrefix.isRadio) ?? false

        var initialMeta = TrackMetadata(
            title: item.title,
            artist: item.artist ?? "",
            album: item.album ?? "",
            albumArtURI: item.albumArtURI,
            stationName: isRadioStream ? item.title : ""
        )
        if let art = initialMeta.albumArtURI {
            initialMeta.albumArtURI = coordinator.makeAbsoluteURL(art)
        }

        // Show new item info immediately with transitioning state.
        // Use cached art if available so artwork appears instantly while waiting.
        let isContainer = item.resourceURI?.hasPrefix(URIPrefix.rinconContainer) == true
        awaitingPlayback[coordinator.id] = true
        if !isContainer {
            var pendingMeta = initialMeta
            // Prefer cached art (survives restart), then item's DIDL art, then nil
            if let cachedArt = discoveredArtURLs[item.objectID] ?? lookupCachedArt(uri: item.resourceURI, title: item.title) {
                pendingMeta.albumArtURI = cachedArt
            }
            groupTrackMetadata[coordinator.id] = pendingMeta
            groupTransportStates[coordinator.id] = .transitioning
            setTransportGrace(groupID: coordinator.id, duration: Timing.playbackGracePeriod)
        }

        if let uri = item.resourceURI, !uri.isEmpty {
            // Unescape metadata — browse parser stores it XML-escaped
            var meta = item.resourceMetadata ?? ""
            if meta.contains("&lt;") {
                meta = XMLResponseParser.xmlUnescape(meta)
            }

            if uri.hasPrefix(URIPrefix.rinconContainer) {
                // Streaming service containers (albums/playlists) —
                // try adding to queue first, fall back to direct transport URI
                var queueWasModified = false
                do {
                    try await contentDirectory.removeAllTracksFromQueue(device: coordinator)
                    _ = try await contentDirectory.addURIToQueue(
                        device: coordinator, uri: uri, metadata: meta
                    )
                    queueWasModified = true
                    try await avTransport.setAVTransportURI(
                        device: coordinator, uri: "x-rincon-queue:\(coordinator.id)#0"
                    )
                    try await avTransport.play(device: coordinator)
                } catch {
                    sonosDebugLog("[PLAYBACK] Queue-based play failed, falling back to direct URI: \(error)")
                    try await avTransport.setAVTransportURI(
                        device: coordinator, uri: uri, metadata: meta
                    )
                    try await avTransport.play(device: coordinator)
                }
                // Success — show new item info with transitioning state
                var pendingMeta = initialMeta
                if let cachedArt = discoveredArtURLs[item.objectID] ?? lookupCachedArt(uri: item.resourceURI, title: item.title) {
                    pendingMeta.albumArtURI = cachedArt
                }
                groupTrackMetadata[coordinator.id] = pendingMeta
                groupTransportStates[coordinator.id] = .transitioning
                setTransportGrace(groupID: coordinator.id, duration: Timing.playbackGracePeriod)
                awaitingPlayback[coordinator.id] = true
                // Notify QueueView to reload — it was previously
                // missing this signal when the queue-based play path
                // ran, leaving the panel stale until the user toggled
                // it off and back on (issue #8).
                if queueWasModified {
                    postQueueChanged(optimisticItems: [])
                }
            } else if uri.hasPrefix(URIPrefix.rinconPlaylist) || uri.hasPrefix("file:///jffs/") {
                // Sonos playlists and library playlists — add to queue then play
                try await withStaleHandling(for: group.name) {
                    try await contentDirectory.removeAllTracksFromQueue(device: coordinator)
                    _ = try await contentDirectory.addURIToQueue(
                        device: coordinator, uri: uri, metadata: meta
                    )
                    try await avTransport.setAVTransportURI(
                        device: coordinator, uri: "x-rincon-queue:\(coordinator.id)#0"
                    )
                    try await avTransport.play(device: coordinator)
                }
                postQueueChanged(optimisticItems: [])
            } else {
                // Direct playback — singles, radio streams, etc.
                sonosDebugLog("[PLAYBACK] SetAVTransportURI: \(uri.prefix(80))")
                try await withStaleHandling(for: group.name) {
                    let effectiveMeta = meta
                    try await avTransport.setAVTransportURI(
                        device: coordinator, uri: uri, metadata: effectiveMeta
                    )
                    try await avTransport.play(device: coordinator)
                }
                // Direct-URI playback bypasses the queue, but `Play
                // Now` semantics imply replacing whatever was there;
                // a notification triggers a Browse(Q:0) so the panel
                // shows the newly-empty (or radio-streaming) state.
                postQueueChanged(optimisticItems: [])
            }
        } else if item.isContainer {
            try await withStaleHandling(for: group.name) {
                try await contentDirectory.removeAllTracksFromQueue(device: coordinator)
                let containerURI = makeContainerURI(item)
                _ = try await contentDirectory.addURIToQueue(device: coordinator, uri: containerURI)
                try await avTransport.setAVTransportURI(device: coordinator, uri: "x-rincon-queue:\(coordinator.id)#0")
                try await avTransport.play(device: coordinator)
            }
            postQueueChanged(optimisticItems: [])
        }
    }

    @discardableResult
    /// Posts a `.queueChanged` notification. When `optimisticItems` is
    /// non-empty, subscribers (QueueView) append the items directly and skip
    /// the full `Browse(Q:0)` round-trip. When empty, subscribers do a full
    /// reload. Use the plural form for both single- and multi-track adds.
    private func postQueueChanged(optimisticItems: [QueueItem]) {
        if optimisticItems.isEmpty {
            NotificationCenter.default.post(name: .queueChanged, object: nil)
        } else {
            NotificationCenter.default.post(
                name: .queueChanged,
                object: nil,
                userInfo: [QueueChangeKey.optimisticItems: optimisticItems]
            )
        }
    }

    /// Batch-adds multiple tracks to the queue in a single SOAP call instead
    /// of issuing one `AddURIToQueue` per track. On S1 hardware this is the
    /// difference between "5 seconds per track" and "roughly one round-trip
    /// for the whole set." Returns the queue position of the first track.
    ///
    /// `playNext == true` inserts the batch after the current track in the
    /// same order; otherwise the batch appends to the end of the queue.
    ///
    /// Only items with a non-empty `resourceURI` are enqueued. Container
    /// items (which would expand server-side to many tracks) are skipped —
    /// use `addBrowseItemToQueue` individually for those.
    @discardableResult
    public func addBrowseItemsToQueue(_ items: [BrowseItem], in group: SonosGroup, playNext: Bool = false) async throws -> Int {
        guard !items.isEmpty else { return 0 }
        if items.count == 1 {
            return try await addBrowseItemToQueue(items[0], in: group, playNext: playNext)
        }
        guard let coordinator = group.coordinator else { return 0 }
        isAddingToQueue = true
        defer { isAddingToQueue = false }

        var uris: [String] = []
        var metas: [String] = []
        var optimisticSource: [BrowseItem] = []
        for item in items {
            guard let uri = item.resourceURI, !uri.isEmpty, !item.isContainer else { continue }
            uris.append(uri)
            var meta = item.resourceMetadata ?? ""
            if meta.contains("&lt;") {
                meta = XMLResponseParser.xmlUnescape(meta)
            }
            metas.append(meta)
            optimisticSource.append(item)
        }
        guard !uris.isEmpty else { return 0 }

        var insertAt = 0
        if playNext {
            let posInfo = try? await avTransport.getPositionInfo(device: coordinator)
            let currentTrack = posInfo?.trackNumber ?? 0
            insertAt = currentTrack > 0 ? currentTrack + 1 : 1
        }

        sonosDebugLog("[QUEUE] Batch add \(uris.count) URIs at pos \(insertAt) playNext=\(playNext)")

        // Try the single-SOAP batch action first. Sonos caps each call at
        // 16 items, so chunk the input and send multiple batches if needed.
        // If the speaker rejects the wire format (fault 402 "Invalid Args")
        // or doesn't support the action, fall back to sequential single adds.
        //
        // 16 is the firmware-imposed maximum for `AddMultipleURIsToQueue` —
        // anything larger faults with 402. Smaller batches (5/10) are
        // strictly worse: per-call SOAP overhead is fixed, so n×overhead
        // grows with the number of round-trips. The "this takes forever"
        // perception was a UI gap — a single static banner during the
        // serial chunked send. Now we update the banner per chunk so
        // the user sees progress instead of dead air.
        let total = uris.count
        ErrorHandler.shared.info("Adding 0 / \(total) tracks…")

        var firstTrack = 0
        var numAdded = 0
        var batchSucceeded = false
        do {
            let chunkSize = 16
            var nextInsertAt = insertAt
            for chunkStart in stride(from: 0, to: uris.count, by: chunkSize) {
                let end = min(chunkStart + chunkSize, uris.count)
                let uriChunk = Array(uris[chunkStart..<end])
                let metaChunk = Array(metas[chunkStart..<end])
                let result = try await contentDirectory.addMultipleURIsToQueue(
                    device: coordinator,
                    uris: uriChunk, metadatas: metaChunk,
                    desiredFirstTrackNumberEnqueued: nextInsertAt,
                    enqueueAsNext: false
                )
                sonosDebugLog("[QUEUE] Batch chunk \(chunkStart)-\(end-1): firstTrack=\(result.firstTrackNumber) numAdded=\(result.numAdded)")
                if firstTrack == 0 && result.firstTrackNumber > 0 { firstTrack = result.firstTrackNumber }
                numAdded += result.numAdded
                // Next chunk goes after the ones we just added (only relevant
                // when playNext/insertAt > 0; append mode keeps nextInsertAt=0).
                if nextInsertAt > 0 { nextInsertAt += result.numAdded }
                // Update the banner so the user can see the queue is filling.
                if numAdded < total {
                    ErrorHandler.shared.info("Adding \(numAdded) / \(total) tracks…")
                }
            }
            batchSucceeded = numAdded > 0
        } catch {
            sonosDebugLog("[QUEUE] Batch add threw: \(error). Falling back to per-track adds.")
            firstTrack = 0
            numAdded = 0
        }

        if !batchSucceeded {
            sonosDebugLog("[QUEUE] Entering per-track fallback for \(uris.count) items")
            firstTrack = 0
            numAdded = 0
            for (i, item) in optimisticSource.enumerated() {
                guard let uri = item.resourceURI, !uri.isEmpty else { continue }
                var meta = item.resourceMetadata ?? ""
                if meta.contains("&lt;") { meta = XMLResponseParser.xmlUnescape(meta) }
                let target = insertAt > 0 ? insertAt + i : 0
                do {
                    let pos = try await contentDirectory.addURIToQueue(
                        device: coordinator, uri: uri, metadata: meta,
                        desiredFirstTrackNumberEnqueued: target, enqueueAsNext: false
                    )
                    sonosDebugLog("[QUEUE] Per-track fallback \(i+1)/\(uris.count) '\(item.title)' uri=\(uri.prefix(80)) -> pos=\(pos)")
                    if firstTrack == 0 && pos > 0 { firstTrack = pos }
                    if pos > 0 { numAdded += 1 }
                    if numAdded < uris.count {
                        ErrorHandler.shared.info("Adding \(numAdded) / \(uris.count) tracks…")
                    }
                } catch {
                    sonosDebugLog("[QUEUE] Per-track fallback add FAILED for '\(item.title)': \(error)")
                    ErrorHandler.shared.handle(error, context: "QUEUE", userFacing: true)
                    // Abort the rest of the loop — if the speaker is rejecting
                    // one track it will likely reject the rest too, and we
                    // don't want to hammer it.
                    break
                }
            }
            sonosDebugLog("[QUEUE] Per-track fallback complete: added=\(numAdded)")
        }

        // Batch adds trigger a full queue reload instead of optimistic append.
        // The slowness on S1 means the user has already waited; one extra
        // Browse(Q:0) round-trip is negligible compared to the batch duration,
        // and a real reload guarantees the queue panel matches the speaker's
        // actual state — including any tracks that failed mid-loop.
        postQueueChanged(optimisticItems: [])
        if numAdded > 0 {
            ErrorHandler.shared.info("\(L10n.addToQueue): \(numAdded) \(numAdded == 1 ? "track" : "tracks")")
        }
        return firstTrack
    }

    public func addBrowseItemToQueue(_ item: BrowseItem, in group: SonosGroup, playNext: Bool = false, atPosition: Int = 0) async throws -> Int {
        guard let coordinator = group.coordinator else { return 0 }
        isAddingToQueue = true
        defer { isAddingToQueue = false }

        // Determine insertion position
        var insertAt = atPosition
        if atPosition == 0 {
            if playNext {
                // Play next: insert after current track, or at start if queue is dormant
                let posInfo = try? await avTransport.getPositionInfo(device: coordinator)
                let currentTrack = posInfo?.trackNumber ?? 0
                insertAt = currentTrack > 0 ? currentTrack + 1 : 1
            }
            // Append to end: leave insertAt = 0. Sonos's DesiredFirstTrackNumberEnqueued=0
            // means "append at end", so we skip the extra Browse round-trip that was
            // previously used solely to count the current queue size. S1 hardware
            // feels this difference — one fewer SOAP call per Add to Queue.
        }

        if let uri = item.resourceURI, !uri.isEmpty {
            let cached = CachedTrack(
                title: item.title, artist: item.artist ?? "",
                album: item.album ?? "", artURL: item.albumArtURI
            )

            // Cache track info for later recovery when speaker returns empty metadata
            if !item.title.isEmpty {
                cachedTrackInfo[uri] = cached
                if let decoded = uri.removingPercentEncoding, decoded != uri {
                    cachedTrackInfo[decoded] = cached
                }
            }

            // Unescape metadata — browse parser stores it XML-escaped
            var meta = item.resourceMetadata ?? ""
            if meta.contains("&lt;") {
                meta = XMLResponseParser.xmlUnescape(meta)
            }
            sonosDebugLog("[QUEUE] Adding URI to queue: \(uri.prefix(60)) atPos=\(insertAt) playNext=\(playNext)")
            let result: Int
            do {
                result = try await contentDirectory.addURIToQueue(device: coordinator, uri: uri, metadata: meta, desiredFirstTrackNumberEnqueued: insertAt, enqueueAsNext: false)
                sonosDebugLog("[QUEUE] Add OK: trackNumber=\(result)")
            } catch {
                sonosDebugLog("[QUEUE] Add FAILED: \(error)")
                ErrorHandler.shared.handle(error, context: "QUEUE", userFacing: true)
                throw error
            }

            // Cache by queue position for trackNumber-based recovery
            if !item.title.isEmpty && result > 0 {
                let groupID = group.coordinatorID
                if cachedTrackByPosition[groupID] == nil { cachedTrackByPosition[groupID] = [:] }
                cachedTrackByPosition[groupID]?[result] = cached
            }
            // Optimistic-update payload: the QueueView appends this item directly
            // instead of re-fetching the whole queue from the coordinator. On S1
            // hardware the full Browse round-trip after each add adds ~3-5 s of
            // delay per track; this eliminates it. Fallback reload happens only
            // when we don't know the resulting track number (result == 0).
            let optimistic: [QueueItem] = result > 0 ? [QueueItem(
                id: result,
                title: item.title,
                artist: item.artist ?? "",
                album: item.album ?? "",
                albumArtURI: item.albumArtURI,
                duration: ""
            )] : []
            postQueueChanged(optimisticItems: optimistic)
            // Visible confirmation — context-menu Add-to-Queue actions would
            // otherwise produce no on-screen feedback when the queue panel
            // isn't open.
            if result > 0 {
                let msg = item.title.isEmpty ? L10n.addToQueue : "\(L10n.addToQueue): \(item.title)"
                ErrorHandler.shared.info(msg)
            }
            return result
        } else if item.isContainer {
            let containerURI = makeContainerURI(item)
            sonosDebugLog("[QUEUE] Adding container to queue: \(containerURI.prefix(60)) atPos=\(insertAt)")
            let result = try await contentDirectory.addURIToQueue(device: coordinator, uri: containerURI, desiredFirstTrackNumberEnqueued: insertAt, enqueueAsNext: false)
            // Containers expand to multiple tracks server-side — we can't build
            // an optimistic item list without fetching the queue, so fall back
            // to a full reload here. Same-file single-track adds are optimistic.
            postQueueChanged(optimisticItems: [])
            return result
        }
        sonosDebugLog("[QUEUE] Cannot add to queue: no URI for '\(item.title)' objectID=\(item.objectID)")
        return 0
    }

    /// Builds a URI that Sonos understands for enqueuing an entire container.
    /// Each prefix maps to a different Sonos protocol scheme:
    ///   SQ: = saved queues stored in flash, A:/S: = local library playlists
    private func makeContainerURI(_ item: BrowseItem) -> String {
        let objectID = item.objectID
        if objectID.hasPrefix("SQ:") {
            return "file:///jffs/settings/savedqueues.rsq#\(objectID)"
        }
        if objectID.hasPrefix("A:") || objectID.hasPrefix("S:") {
            return "x-rincon-playlist:\(preferredDevice?.id ?? "")#\(objectID)"
        }
        return item.resourceURI ?? objectID
    }

    // MARK: - Music Services

    public func getAvailableMusicServices() async throws -> [MusicService] {
        guard let device = preferredDevice else { return [] }
        return try await musicServices.listAvailableServices(device: device)
    }

    /// Looks up a music service name by its Sonos service ID (sid=NNN in URIs)
    public func musicServiceName(for serviceID: Int) -> String? {
        if let match = musicServicesList.first(where: { $0.id == serviceID }) {
            return match.name
        }
        return ServiceID.knownNames[serviceID]
    }

    /// Detects the music service from a URI by checking both sid= and URI content patterns.
    public func detectServiceName(fromURI uri: String) -> String? {
        // Decode URL-encoded URIs and XML entities
        let decoded = (uri.removingPercentEncoding ?? uri)
            .replacingOccurrences(of: "&amp;", with: "&")

        // 1. Try sid= parameter (check both original and decoded)
        for candidate in [decoded, uri] {
            if let range = candidate.range(of: "sid=") {
                let after = candidate[range.upperBound...]
                let numStr = String(after.prefix(while: { $0.isNumber }))
                if let sid = Int(numStr), let name = musicServiceName(for: sid) {
                    return name
                }
            }
        }

        // 2. Check URI content for known service patterns
        let lower = decoded.lowercased()
        if lower.contains("spotify") { return ServiceName.spotify }
        if lower.contains("apple") { return ServiceName.appleMusic }
        if lower.contains("amazon") || lower.contains("amzn") { return ServiceName.amazonMusic }
        if lower.contains("deezer") { return ServiceName.deezer }
        if lower.contains("tidal") { return ServiceName.tidal }
        if lower.contains("soundcloud") { return ServiceName.soundCloud }
        if lower.contains("youtube") { return ServiceName.youTubeMusic }
        if lower.contains("pandora") { return ServiceName.pandora }
        if lower.contains("napster") { return "Napster" }
        if lower.contains("qobuz") { return "Qobuz" }
        if lower.contains("plex") { return "Plex" }
        if lower.contains("audible") { return "Audible" }
        if lower.contains("iheart") || lower.contains("iheartradio") { return "iHeartRadio" }
        if lower.contains("calmradio") || uri.contains("sid=144") { return ServiceName.calmRadio }

        // Radio streams — check after specific services
        if decoded.hasPrefix(URIPrefix.sonosApiStream) || decoded.hasPrefix(URIPrefix.sonosApiRadio) { return ServiceName.radio }
        if decoded.hasPrefix(URIPrefix.rinconMP3Radio) { return ServiceName.radio }

        // Streaming services via x-sonos-http (use sid if available, otherwise generic)
        if decoded.hasPrefix(URIPrefix.sonosHTTP) { return ServiceName.streaming }

        // Local sources
        if URIPrefix.isLocal(uri) { return ServiceName.musicLibrary }
        if uri.hasPrefix("file:///jffs/settings/savedqueues") { return ServiceName.sonosPlaylist }

        return nil
    }

    /// Looks up a music service name from a SA_RINCON descriptor string.
    /// e.g. "SA_RINCON52231_X_#Svc52231-0-Token" → extracts 52231 and maps it.
    /// SA_RINCON numbers map via: sid = rinconNumber / 256 (approximately)
    public func musicServiceName(fromDescriptor desc: String) -> String? {
        guard let range = desc.range(of: "SA_RINCON") else { return nil }
        let after = desc[range.upperBound...]
        let numStr = String(after.prefix(while: { $0.isNumber }))
        guard let rinconNum = Int(numStr) else { return nil }

        // Try direct match first
        if let name = musicServiceName(for: rinconNum) { return name }

        // SA_RINCON numbers are typically serviceType * 256 + 7
        let derived = (rinconNum - 7) / 256
        if let name = musicServiceName(for: derived) { return name }

        // Try common known mappings
        switch rinconNum {
        case 2311: return ServiceName.spotify
        case 52231: return ServiceName.appleMusic
        case 65031: return ServiceName.amazonMusic
        case 3079: return ServiceName.tuneIn
        case 519: return ServiceName.pandora
        case 36871: return ServiceName.calmRadio
        default: break
        }

        // Try dividing by various factors
        for divisor in [256, 257, 7] {
            let candidate = rinconNum / divisor
            if let name = musicServiceName(for: candidate) { return name }
        }

        return nil
    }

    /// Detects the service label for a BrowseItem based on URI, descriptor, metadata, and objectID.
    public func serviceLabel(for item: BrowseItem) -> String? {
        if let uri = item.resourceURI, let name = detectServiceName(fromURI: uri) { return name }
        if let desc = item.serviceDescriptor, let name = musicServiceName(fromDescriptor: desc) { return name }
        if let meta = item.resourceMetadata, let name = musicServiceName(fromDescriptor: meta) { return name }
        if item.objectID.hasPrefix("SQ:") { return ServiceName.sonosPlaylist }
        if item.objectID.hasPrefix("A:") || item.objectID.hasPrefix("S:") { return ServiceName.musicLibrary }
        if item.objectID.hasPrefix("R:") { return ServiceName.radio }
        return nil
    }

    /// Returns a reliable device for SOAP calls — prefers a group coordinator
    /// over an arbitrary device from the dictionary, since coordinators are
    /// always full speakers (never subs or satellites)
    private var preferredDevice: SonosDevice? {
        groups.first?.coordinator ?? devices.values.first
    }
}

// MARK: - TransportStrategyDelegate

extension SonosManager: TransportStrategyDelegate {
    public func transportDidUpdateState(_ groupID: String, state: TransportState) {
        let now = Date()
        if let grace = transportGraceUntils[groupID], now < grace {
            let currentOptimistic = groupTransportStates[groupID]
            if state == currentOptimistic {
                transportGraceUntils[groupID] = nil
            } else if currentOptimistic == .transitioning && state == .playing {
                // Allow transitioning → playing through (expected progression)
                transportGraceUntils[groupID] = nil
            } else {
                return
            }
        }
        if groupTransportStates[groupID] != state { groupTransportStates[groupID] = state }
        if state == .playing && awaitingPlayback[groupID] == true {
            awaitingPlayback[groupID] = false
        }
    }

    public func transportDidUpdateTrackMetadata(_ groupID: String, metadata: TrackMetadata) {
        guard let existing = groupTrackMetadata[groupID] else {
            // First metadata — also try to populate queue cache if playing from queue
            var initial = metadata
            if initial.title.isEmpty, initial.trackNumber > 0,
               let qi = lastQueueItems[groupID], initial.trackNumber - 1 < qi.count {
                let item = qi[initial.trackNumber - 1]
                initial.title = item.title
                if initial.artist.isEmpty { initial.artist = item.artist }
                if initial.album.isEmpty { initial.album = item.album }
                if initial.albumArtURI == nil { initial.albumArtURI = item.albumArtURI }
            }
            groupTrackMetadata[groupID] = initial
            return
        }

        // If station changed, accept the new metadata completely (don't keep old art)
        if !metadata.stationName.isEmpty && !existing.stationName.isEmpty &&
           metadata.stationName != existing.stationName {
            groupTrackMetadata[groupID] = metadata
            return
        }

        // Recover track info from cache — Apple Music/service queue tracks
        // often return empty TrackMetaData from GetPositionInfo.
        // Position-based fallbacks blocked when actively playing a radio station
        // (has stationName + radio URI), to prevent stale queue metadata from leaking.
        // Apple Music queue tracks use x-sonosapi-hls-static URIs which look like radio
        // but have no stationName — so stationName is the reliable discriminator.
        var enriched = metadata
        if enriched.title.isEmpty {
            var cached: CachedTrack?
            let isActiveRadio = !enriched.stationName.isEmpty &&
                                (enriched.trackURI.map(URIPrefix.isRadio) ?? false)

            // Try URI match first (both encoded and decoded) — always safe
            if let uri = enriched.trackURI, !uri.isEmpty {
                cached = cachedTrackInfo[uri]
                if cached == nil, let decoded = uri.removingPercentEncoding {
                    cached = cachedTrackInfo[decoded]
                }
            }

            // Queue position fallbacks — only valid when actually playing from
            // a queue. Direct-play tracks (browse → play, no queue) often report
            // trackNumber=1 from getPositionInfo, which previously caused them
            // to inherit title/artist/art from the user's last queue position 1.
            // isQueueSource is the reliable discriminator and is set by
            // enrichFromMediaInfo based on the speaker's CurrentURI.
            if cached == nil, !isActiveRadio, enriched.isQueueSource, enriched.trackNumber > 0 {
                cached = cachedTrackByPosition[groupID]?[enriched.trackNumber]
            }
            if cached == nil, !isActiveRadio, enriched.isQueueSource, enriched.trackNumber > 0,
               let queueItems = lastQueueItems[groupID] {
                let idx = enriched.trackNumber - 1
                if idx >= 0 && idx < queueItems.count {
                    let qi = queueItems[idx]
                    cached = CachedTrack(title: qi.title, artist: qi.artist, album: qi.album, artURL: qi.albumArtURI)
                }
            }

            if let cached {
                enriched.title = cached.title
                if enriched.artist.isEmpty { enriched.artist = cached.artist }
                if enriched.album.isEmpty { enriched.album = cached.album }
                if enriched.albumArtURI == nil { enriched.albumArtURI = cached.artURL }
            }
        }

        // Don't overwrite existing good metadata with empty or technical stream names
        // BUT only if the track hasn't changed (same URI = same track, just a poll update)
        let sameTrack = enriched.trackURI == existing.trackURI || enriched.trackURI == nil
        if !existing.title.isEmpty && sameTrack {
            let newTitle = enriched.title
            if newTitle.isEmpty || TrackMetadata.isTechnicalName(newTitle) {
                var merged = existing
                merged.position = enriched.position
                merged.duration = enriched.duration
                merged.trackNumber = enriched.trackNumber
                merged.trackURI = enriched.trackURI
                merged.isQueueSource = enriched.isQueueSource
                merged.queueSize = enriched.queueSize
                if !enriched.stationName.isEmpty {
                    merged.stationName = enriched.stationName
                }
                // Only accept new art if we didn't have any. Plex rotates
                // `X-Plex-Token` on every poll; replacing the art URL here
                // triggers an image reload and flickers the UI for a track
                // we're already showing correctly.
                if merged.albumArtURI == nil || merged.albumArtURI?.isEmpty == true,
                   let newArt = enriched.albumArtURI, !newArt.isEmpty {
                    merged.albumArtURI = newArt
                }
                groupTrackMetadata[groupID] = merged
                return
            }
        }

        var updated = enriched

        // Detect if the track actually changed
        let trackChanged = updated.trackURI != existing.trackURI && updated.trackURI != nil

        // Carry forward station name unless the source actually changed.
        // Clear station name when playing from queue (isQueueSource) — Apple Music
        // queue tracks use x-sonosapi-hls-static URIs that look like radio but aren't.
        if updated.isQueueSource {
            updated.stationName = ""
        } else if updated.stationName.isEmpty && !existing.stationName.isEmpty && !trackChanged {
            updated.stationName = existing.stationName
        }

        // Preserve enriched artist/album across polls. Apple Music HLS-static
        // favorites send sparse DIDL with an empty artist on every transport
        // poll; we fill it in via a one-shot iTunes lookup, but the next
        // poll would otherwise overwrite that with empty (or the original
        // album-shaped junk) again. As long as we're still on the same
        // track:
        //   - An empty incoming field never wins over a non-empty existing.
        //   - An album-shaped incoming "artist" never wins over a clean one
        //     (defends against Sonos's `dc:creator = album` quirk).
        if !trackChanged {
            let incomingArtistIsSuspect = Self.isAlbumShapedArtist(updated.artist)
            if (updated.artist.isEmpty || incomingArtistIsSuspect) && !existing.artist.isEmpty
               && !Self.isAlbumShapedArtist(existing.artist) {
                updated.artist = existing.artist
            }
            if updated.album.isEmpty && !existing.album.isEmpty {
                updated.album = existing.album
            }
        }

        // Art stability: for same track, pin the first art we saw.
        //
        // Earlier logic only replaced the incoming art when it was nil or a
        // `/getaa?` fallback, which helped for most services. Plex rotates
        // the `X-Plex-Token` query on every poll, so back-to-back poll
        // results produce visibly-identical-but-byte-different URLs. The
        // underlying `AsyncImage`/cache treats each as a new request and
        // the UI reloads, which reads as a flicker.
        //
        // Pinning is safe because the caller has already determined that
        // the TRACK hasn't changed — so whatever art we resolved on the
        // first event for that track is still the right art until the
        // track itself changes.
        // Art resolution is owned by `ArtResolver` (on the app side) — this
        // layer no longer substitutes cached art into the metadata stream.
        // Writing here competed with the view-side resolver and produced a
        // visible flicker when the two caches disagreed (e.g. Plex tracks
        // with multiple iTunes matches). We just pass through whatever the
        // speaker reported; the view asks ArtResolver for the canonical
        // URL to display.
        groupTrackMetadata[groupID] = updated

        // Log to play history for all groups
        if let group = groups.first(where: { $0.coordinatorID == groupID || $0.id == groupID }) {
            playHistoryManager?.trackMetadataChanged(
                groupID: groupID,
                metadata: updated,
                groupName: group.name,
                transportState: groupTransportStates[groupID] ?? .stopped
            )
        }

        // Apple Music favorites (saved as `x-sonosapi-hls-static:song:<id>` or
        // `x-sonos-http:song:<id>.mp4`) often deliver a sparse DIDL with no
        // artist field — Sonos's own app fills in the artist from a separate
        // lookup. We mirror that with a one-shot iTunes lookup by track ID,
        // rate-limited so it can't tip iTunes into 403.
        enrichAppleMusicArtistIfNeeded(groupID: groupID, metadata: updated)
    }

    private func enrichAppleMusicArtistIfNeeded(groupID: String, metadata: TrackMetadata) {
        // Enrich when the existing artist field is empty OR when it looks
        // album-shaped (Sonos sometimes leaks the album name into
        // `<dc:creator>` for HLS-static Apple Music favorites). We
        // overwrite a suspect value because it's worse-than-nothing — it
        // poisons every downstream lookup.
        guard metadata.artist.isEmpty || Self.isAlbumShapedArtist(metadata.artist) else { return }
        guard let uri = metadata.trackURI, !uri.isEmpty else { return }
        guard let songID = Self.extractAppleMusicSongID(from: uri) else { return }

        // Persistent cache: subsequent plays of the same favorite hit the
        // local store and skip both the network call and the stale-trip
        // around `appleMusicEnrichmentResolved` (which only lives for the
        // process lifetime).
        let cacheKey = MetadataCacheRepository.Kind.appleMusicTrack.key(songID)
        if let cached = metadataCacheForAppleMusic?.get(cacheKey),
           let data = cached.data(using: .utf8),
           let payload = try? JSONDecoder().decode(AppleMusicTrackEnrichment.self, from: data) {
            applyAppleMusicEnrichment(groupID: groupID, uri: uri, payload: payload, source: "cache")
            return
        }

        if appleMusicEnrichmentInFlight.contains(songID) { return }
        appleMusicEnrichmentInFlight.insert(songID)

        Task { [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    self?.appleMusicEnrichmentInFlight.remove(songID)
                }
            }
            guard let url = URL(string: "https://itunes.apple.com/lookup?id=\(songID)") else { return }
            // Goes through the shared rate limiter so the existing 403
            // protection covers this lookup too.
            guard let (data, _) = await ITunesRateLimiter.shared.perform(
                url: url, session: URLSession.shared, maxWait: 5
            ) else { return }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]],
                  let first = results.first,
                  let artistName = first["artistName"] as? String,
                  !artistName.isEmpty else { return }
            let albumName = first["collectionName"] as? String

            let payload = AppleMusicTrackEnrichment(artist: artistName, album: albumName)

            await MainActor.run { [weak self] in
                guard let self else { return }
                // Persist for next time — 90-day TTL is plenty since
                // Apple Music track IDs are stable.
                if let store = self.metadataCacheForAppleMusic,
                   let encoded = try? JSONEncoder().encode(payload),
                   let str = String(data: encoded, encoding: .utf8) {
                    store.set(cacheKey, payload: str, ttlSeconds: 90 * 24 * 60 * 60)
                }
                self.applyAppleMusicEnrichment(groupID: groupID, uri: uri, payload: payload, source: "network")
            }
        }
    }

    /// Writes the enriched fields onto `groupTrackMetadata[groupID]` when
    /// the track URI still matches and the existing artist is either empty
    /// or album-shaped. If an album-shaped value is overwritten, we move
    /// it into the `album` field when that field is empty — it really was
    /// the album, just labelled wrong.
    private func applyAppleMusicEnrichment(groupID: String, uri: String,
                                           payload: AppleMusicTrackEnrichment, source: String) {
        guard var meta = groupTrackMetadata[groupID] else { return }
        guard meta.trackURI == uri else { return }
        let existingArtistIsAlbum = Self.isAlbumShapedArtist(meta.artist)
        guard meta.artist.isEmpty || existingArtistIsAlbum else { return }

        // Reclaim a misplaced album label before overwriting the artist.
        if existingArtistIsAlbum && meta.album.isEmpty {
            meta.album = meta.artist
        }
        meta.artist = payload.artist
        if meta.album.isEmpty, let albumName = payload.album, !albumName.isEmpty {
            meta.album = albumName
        }
        groupTrackMetadata[groupID] = meta
        sonosDebugLog("[ENRICH] Apple Music \(source) → \(payload.artist) — \(payload.album ?? "")")
    }

    /// Returns true when an "artist" string is actually an album label —
    /// Sonos occasionally writes the album into `<dc:creator>` for HLS
    /// favorites. We mirror the suffix list from `MusicMetadataService`
    /// so the enrichment trigger and the About-tab guard agree on what
    /// "looks album-shaped" means.
    private static func isAlbumShapedArtist(_ s: String) -> Bool {
        let lower = s.lowercased()
        let albumSuffixes = [
            "(deluxe)", "(deluxe edition)", "(remastered)", "(remaster)",
            "(expanded)", "(soundtrack)", "(original soundtrack)", "(ost)",
            "(special edition)", "(extended)", "(anniversary edition)",
            "(bonus track version)"
        ]
        for suffix in albumSuffixes where lower.hasSuffix(suffix) { return true }
        return false
    }

    /// Pulls the numeric song ID out of an Apple-Music-flavoured Sonos URI.
    /// Matches both:
    ///   `x-sonos-http:song%3a<ID>.mp4?…`
    ///   `x-sonosapi-hls-static:song%3a<ID>?…`
    /// Returns nil for any other URI shape.
    private static func extractAppleMusicSongID(from uri: String) -> String? {
        guard uri.contains("x-sonos-http:song") || uri.contains("x-sonosapi-hls-static:song") else {
            return nil
        }
        // Decode percent-encoding so `song%3a123` → `song:123`.
        let decoded = uri.removingPercentEncoding ?? uri
        // Find "song:" then read consecutive digits.
        guard let range = decoded.range(of: "song:") else { return nil }
        let after = decoded[range.upperBound...]
        let digits = after.prefix { $0.isNumber }
        return digits.isEmpty ? nil : String(digits)
    }

    /// Detects technical stream names that should not replace friendly titles.
    /// e.g. "moviesoundtracks_mobile_mp3", "s233145", "stream_128k"

    public func transportDidUpdatePlayMode(_ groupID: String, mode: PlayMode) {
        let now = Date()
        if let grace = modeGraceUntils[groupID], now < grace { return }
        if groupPlayModes[groupID] != mode { groupPlayModes[groupID] = mode }
    }

    public func transportDidUpdateVolume(_ deviceID: String, volume: Int) {
        let now = Date()
        if let grace = volumeGraceUntils[deviceID], now < grace { return }
        if deviceVolumes[deviceID] != volume { deviceVolumes[deviceID] = volume }
    }

    public func transportDidUpdateMute(_ deviceID: String, muted: Bool) {
        let now = Date()
        if let grace = muteGraceUntils[deviceID], now < grace { return }
        let changed = deviceMutes[deviceID] != muted
        if changed { deviceMutes[deviceID] = muted }
        // Sonos's group-mute (from its own app, voice control, scenes)
        // sends individual SetMute calls per member, but the per-member
        // UPnP NOTIFY events arrive at very different latencies on
        // different hardware — wired Connect/One: ~50 ms; portable
        // Float/Roam: up to ~10 s on unmute. Waiting for each speaker's
        // own event leaves the UI badly out of sync during that window.
        //
        // Optimistic group propagation: when one member's mute toggles,
        // mirror to all other members in the same group on the
        // assumption it was a group-level operation. The verifying
        // GetMute fan-out below corrects within ~150 ms in the rare
        // per-speaker-mute case where the assumption is wrong (brief
        // visible flicker is acceptable; FP5's 10 s real lag is not).
        if changed {
            propagateMuteOptimistically(triggerDeviceID: deviceID, muted: muted)
            scheduleGroupMuteResync(triggerDeviceID: deviceID)
        }
    }

    /// Mirrors a mute change from one member to every other member of
    /// its group, skipping members whose `muteGraceUntils` is currently
    /// active (those are echoes of writes we just made). Doesn't touch
    /// the trigger device itself — `transportDidUpdateMute` already did.
    private func propagateMuteOptimistically(triggerDeviceID: String, muted: Bool) {
        guard let group = groups.first(where: {
            $0.members.contains { $0.id == triggerDeviceID }
        }) else { return }
        let now = Date()
        for member in group.members where member.id != triggerDeviceID {
            if let grace = muteGraceUntils[member.id], now < grace { continue }
            if deviceMutes[member.id] != muted {
                deviceMutes[member.id] = muted
            }
        }
    }

    /// Verifies the optimistic propagation by polling each non-trigger
    /// member's actual mute state via SOAP. Corrects any speaker that
    /// the optimistic update mirrored incorrectly (e.g. user only
    /// muted one speaker via Sonos's app). Bypasses the
    /// `muteGraceUntils` filter for the polled values because we're
    /// reading authoritative speaker state, not echoing our own write.
    private func scheduleGroupMuteResync(triggerDeviceID: String) {
        guard let group = groups.first(where: {
            $0.members.contains { $0.id == triggerDeviceID }
        }) else { return }
        let others = group.members.filter { $0.id != triggerDeviceID }
        guard !others.isEmpty else { return }
        Task { [weak self] in
            await withTaskGroup(of: Void.self) { tg in
                for member in others {
                    tg.addTask { [weak self] in
                        guard let self else { return }
                        do {
                            let val = try await self.renderingControl.getMute(device: member)
                            await MainActor.run {
                                if self.deviceMutes[member.id] != val {
                                    self.deviceMutes[member.id] = val
                                }
                            }
                        } catch {
                            // Quiet failure — the periodic reconciliation
                            // poll will catch any persistent mismatch.
                        }
                    }
                }
            }
        }
    }

    public func transportDidUpdateTopology(_ groupData: [ZoneGroupData]) {
        // Topology changed via event — refresh from the data
        var newGroups: [SonosGroup] = []
        for gd in groupData {
            var members: [SonosDevice] = []
            for md in gd.members {
                let dev = SonosDevice(
                    id: md.uuid,
                    ip: md.ip,
                    port: md.port,
                    roomName: md.zoneName,
                    isCoordinator: md.uuid == gd.coordinatorUUID,
                    groupID: gd.id
                )
                devices[dev.id] = dev
                if !md.isInvisible {
                    members.append(dev)
                }
            }
            let group = SonosGroup(id: gd.id, coordinatorID: gd.coordinatorUUID, members: members)
            newGroups.append(group)
        }

        self.groups = newGroups.sorted { $0.name < $1.name }
        saveCache()

        // Notify transport strategy about topology change
        Task {
            await transportStrategy?.onGroupsChanged(groups, devices: devices)
        }
    }

    public func transportDidUpdatePosition(_ groupID: String, position: TimeInterval, duration: TimeInterval) {
        let now = Date()
        if let grace = positionGraceUntils[groupID], now < grace { return }
        // Only publish if values actually changed (avoids unnecessary SwiftUI re-renders)
        if groupPositions[groupID] != position { groupPositions[groupID] = position }
        if groupDurations[groupID] != duration { groupDurations[groupID] = duration }
    }

    public func getAVTransportService() -> AVTransportService {
        avTransport
    }

    public func getRenderingControlService() -> RenderingControlService {
        renderingControl
    }

    public func getZoneGroupTopologyService() -> ZoneGroupTopologyService {
        zoneTopology
    }

    /// Triggered by `ZoneGroupTopology` UPnP NOTIFY events. Doesn't try
    /// to parse the event payload (its triple-encoded XML structure is
    /// unreliable) — instead pulls authoritative `GetZoneGroupState`
    /// from any known coordinator. Without this, group/ungroup actions
    /// made from Sonos's app weren't reflected here until the next
    /// 30-second SSDP rescan.
    public func transportRequestsTopologyRefresh() {
        guard let device = groups.first?.coordinator ?? devices.values.first else { return }
        Task {
            await refreshTopology(from: device, force: true)
        }
    }
}

// MARK: - Protocol Conformances (ISP)
// SonosManager conforms to segregated protocols so ViewModels depend on
// narrow interfaces instead of the full 121-method class.

extension SonosManager: PlaybackServiceProtocol {}
extension SonosManager: VolumeServiceProtocol {}
extension SonosManager: EQServiceProtocol {}
extension SonosManager: QueueServiceProtocol {}
extension SonosManager: BrowsingServiceProtocol {}
extension SonosManager: GroupingServiceProtocol {}
extension SonosManager: AlarmServiceProtocol {}
extension SonosManager: MusicServiceDetectionProtocol {}
extension SonosManager: TransportStateProviding {
    public func updateTransportState(_ groupID: String, state: TransportState) {
        groupTransportStates[groupID] = state
    }

    public func updatePlayMode(_ groupID: String, mode: PlayMode) {
        groupPlayModes[groupID] = mode
    }

    public func updateDeviceVolume(_ deviceID: String, volume: Int) {
        deviceVolumes[deviceID] = volume
    }

    public func updateDeviceMute(_ deviceID: String, muted: Bool) {
        deviceMutes[deviceID] = muted
    }

    public func updateAwaitingPlayback(_ groupID: String, awaiting: Bool) {
        awaitingPlayback[groupID] = awaiting
    }
}
extension SonosManager: ArtCacheProtocol {}
