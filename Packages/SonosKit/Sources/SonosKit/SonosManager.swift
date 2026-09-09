/// SonosManager.swift — Central coordinator for all Sonos operations.
///
/// Acts as the single source of truth for speaker topology, playback state,
/// volume, and browsing. Supports two communications modes:
/// - Hybrid Event-First: UPnP event subscriptions with targeted polling fallback
/// - Legacy Polling: periodic SOAP queries (2-second interval)
///
/// All UPnP service calls are funneled through here so the UI layer never
/// touches SOAP directly. Uses a "Quick Start" cache system to show speakers
/// instantly on launch while live discovery runs in the background.
import Foundation
import Combine
import Network

private let debugLogPath: String = {
    AppPaths.appSupportDirectory.appendingPathComponent("sonos_debug.log").path
}()

/// Serial background queue for log writes. Synchronous per-line file I/O
/// on the calling thread stalls frame work under high-rate logging; the
/// serial queue preserves ordering and returns to the caller immediately.
private let _sonosDebugLogQueue = DispatchQueue(label: "sonos-debug-log",
                                                qos: .utility)

public func sonosDebugLog(_ msg: String) {
    #if DEBUG
    // Build the timestamped line on the caller's thread (cheap)
    // so the log preserves wall-clock order even if the queue
    // backs up briefly.
    let line = "\(Date()): \(msg)\n"
    guard let data = line.data(using: .utf8) else { return }
    _sonosDebugLogQueue.async {
        if let handle = FileHandle(forWritingAtPath: debugLogPath) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: debugLogPath,
                                           contents: data,
                                           attributes: [.posixPermissions: 0o600])
        }
    }
    #endif
}

public enum StartupMode: String, CaseIterable {
    case quickStart = "Quick Start"
    case classic = "Classic"

    /// Localised label for the segmented picker; rawValue stays
    /// stable as the persistence key.
    public var displayName: String {
        switch self {
        case .quickStart: return L10n.quickStart
        case .classic:    return L10n.classic
        }
    }
}

public enum CommunicationMode: String, CaseIterable {
    case hybridEventFirst = "Event-Driven"
    case legacyPolling = "Legacy Polling"

    public var displayName: String {
        switch self {
        case .hybridEventFirst: return L10n.eventDriven
        case .legacyPolling:    return L10n.legacyPolling
        }
    }
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
@Observable
public class SonosManager {
    // MARK: - Published State

    /// Household view. Storage lives in `topology`; these forward so
    /// observation still registers on the property read.
    public var groups: [SonosGroup] { topology.groups }
    public var devices: [String: SonosDevice] { topology.devices }

    /// Weak global handle to the most recently constructed manager.
    /// Used by `AppIntents` (Shortcuts / Spotlight / Siri actions) to
    /// reach the live manager without going through the SwiftUI
    /// environment — intents run in code paths that don't have access
    /// to `@EnvironmentObject`. Set from `ChoragusApp` at first
    /// appearance; cleared automatically when the manager deinits.
    nonisolated(unsafe) public static weak var current: SonosManager?
    public var isDiscovering = false
    public var browseSections: [BrowseSection] { library.browseSections }
    /// UPnP/DLNA media servers found on the network. Sonos cannot browse
    /// these itself, so they are an addition rather than a replacement for
    /// anything the speaker offers.
    public var mediaServers: [MediaServer] = []
    public var isDiscoveringMediaServers = false
    /// Per-speaker verdicts by server id, from the last reachability check.
    public var mediaServerReachability: [String: [MediaServerReachability.SpeakerVerdict]] = [:]
    /// (done, total) while a check runs for a server id; absent when idle.
    public var mediaServerCheckProgress: [String: (Int, Int)] = [:]
    /// host:port the last check probed, by server id — the media
    /// port a firewall rule must allow, not the control port.
    public var mediaServerProbeTarget: [String: String] = [:]
    /// Per-system local-library availability, keyed by householdID. Drives the
    /// (S1/S2) browse tags and the fail-fast playback gate. Refreshed from a
    /// live `Browse("S:")` per system after topology settles.
    public var householdCapabilities: [String: HouseholdCapabilities] { library.householdCapabilities }
    public var musicServicesList: [MusicService] = []


    /// SMAPI media-URI resolver. Wired at app startup to
    /// `SMAPIAuthManager.resolveMediaURI`. The direct-play branch
    /// invokes this for any `x-sonosapi-stream:` URI before calling
    /// `SetAVTransportURI` so the speaker receives the resolved direct
    /// stream URL (the only shape current Sonos firmware accepts via
    /// the AVTransport service for SMAPI radio).
    public var smapiURIResolver: ((_ sid: Int, _ itemID: String) async throws -> String?)?

    // Cache state — drives the "Using cached data" banner in ContentView
    public var isUsingCachedData = false
    public var cacheAge: String = ""
    public var isRefreshing = false
    public var staleMessage: String?
    /// Non-fatal advisory shown when the network path is flapping between
    /// interfaces (a dual-interface Mac oscillating Wi-Fi ⇄ Ethernet). Set by
    /// the transport path monitor; user-dismissable. Distinct from
    /// `staleMessage` so it doesn't pre-empt a real stale-data banner.
    public var networkAdvisory: String?

    // MARK: - Transport State (centralized, updated by transport strategy)

    /// Per-group playback state, keyed by group ID
    public private(set) var groupTransportStates: [String: TransportState] = [:]
    public var groupTrackMetadata: [String: TrackMetadata] = [:] {
        didSet {
            groupTrackMetadataPublisher.send(groupTrackMetadata)
            notifyPlexReporterOfTrackChanges(from: oldValue)
        }
    }
    /// Combine feed of the property above. @Observable has no projected
    /// publishers; the art coordinator, prewarm service and two views are
    /// pipelines, not render dependencies, so they keep a subject.
    @ObservationIgnored
    public let groupTrackMetadataPublisher = CurrentValueSubject<[String: TrackMetadata], Never>([:])
    /// Combine feed of `groupTransportStates`, for the same pipelines;
    /// emits only when a group's state changes (see `updateTransportState`).
    @ObservationIgnored
    public let groupTransportStatePublisher = CurrentValueSubject<[String: TransportState], Never>([:])
    /// Format evidence per recent track URI — restores audioFormat /
    /// streamInfoRaw when a transient bogus publish interrupts a track
    /// and the flip-back arrives as a "new" track with `.unknown`
    /// (see the restore site in the metadata merge).
    @ObservationIgnored private var groupFormatMemory = AudioFormatMemory()
    public private(set) var groupPlayModes: [String: PlayMode] = [:]
    /// What the coordinator says it accepts right now (skip / seek / …),
    /// keyed by group ID. Absent means "not reported yet" — see
    /// `canSkipNext(group:)` for the fallback that covers that window.
    public private(set) var groupTransportActions: [String: TransportActions] = [:]
    /// High-churn playhead state lives on dedicated publishers rather
    /// than directly on this class — see `PositionTrackers.swift`.
    /// `groupPositions`/`groupDurations` update ~1 Hz; `anchors` rebases
    /// only on drift / play-state / seek. Views observe whichever
    /// publisher matches their churn tolerance (the karaoke window
    /// observes only `anchorTracker` so per-second position polls don't
    /// trigger 70 ms body re-evals on every tick).
    ///
    /// `groupPositions` / `groupDurations` / `groupPositionAnchors` are
    /// computed forwarders onto the trackers for read-side consumers.
    public let positionTracker = PositionTracker()
    public let anchorTracker = AnchorTracker()

    public var groupPositions: [String: TimeInterval] {
        get { positionTracker.groupPositions }
        set { positionTracker.groupPositions = newValue }
    }
    public var groupDurations: [String: TimeInterval] {
        get { positionTracker.groupDurations }
        set { positionTracker.groupDurations = newValue }
    }
    public var groupPositionAnchors: [String: PositionAnchor] {
        get { anchorTracker.groupPositionAnchors }
        set { anchorTracker.groupPositionAnchors = newValue }
    }

    /// Per-device volume/mute state, keyed by device ID
    /// Storage lives in `volume`; these forward so existing call sites keep
    /// working and observation still lands on the property read.
    public var deviceVolumes: [String: Int] { volume.deviceVolumes }
    public var deviceMutes: [String: Bool] { volume.deviceMutes }
    public var fixedOutputDeviceIDs: Set<String> { volume.fixedOutputDeviceIDs }

    /// Persistent art-URL cache. State + lookup + persistence live in
    /// `ArtCacheService`; `discoveredArtURLs` / `cacheArtURL` /
    /// `lookupCachedArt` forward to it for `TransportStateProviding`.
    /// Cache-change observers subscribe to `artCache.$discoveredArtURLs`.
    public let artCache: ArtCacheService

    /// Forwarding accessor; canonical state lives in `artCache`.
    public var discoveredArtURLs: [String: String] { artCache.discoveredArtURLs }

    /// The objectID of the last favorite that was played — used to map art back to the browse list
    public var lastPlayedFavoriteID: String?

    /// Optional play history manager — set from app layer
    public var playHistoryManager: PlayHistoryManager?
    /// Reports direct-Plex playback back to the Plex server (sessions,
    /// play counts). Optional so the manager builds without Plex.
    public var plexPlaybackReporter: PlexPlaybackReporter?

    /// Set when user initiates playback, cleared only when speaker confirms playing
    public private(set) var awaitingPlayback: [String: Bool] = [:]

    /// True while an add-to-queue operation is in flight for any group.
    /// QueueView observes this to show an in-progress indicator alongside
    /// its own `isLoading` flag — on S1 the per-track fallback loop can
    /// take 30 s or more and the user needs visible confirmation that
    /// something is happening the whole time, not just at the end.
    /// Derived from the queue controller's nesting counter — one writer, one
    /// source of truth; a mirrored flag drifts out of step.
    public var isAddingToQueue: Bool { queue.isAdding }


    public func beginAddingToQueue() { queue.beginAdding() }

    public func endAddingToQueue() { queue.endAdding() }

    /// Drag state for cross-view drag-and-drop (browse → queue)
    public var draggedBrowseItem: BrowseItem?

    /// Stores an art URL with multiple cache keys for flexible lookup.
    /// Forwards to `ArtCacheService` (`TransportStateProviding` conformance).
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
    private var modeGraceUntils: [String: Date] = [:]
    private var positionGraceUntils: [String: Date] = [:]

    /// Per-group one-shot re-poll that recovers the settled DIDL after an
    /// HLS-static track transition reports stale/empty title (issue #69:
    /// YouTube Music — and any non-iTunes HLS-static service — leaks the prior
    /// track's title/artist onto the first event of the new track, then settles).
    private var metadataResettleTasks: [String: Task<Void, Never>] = [:]
    private var metadataResettleURI: [String: String] = [:]
    private static let metadataResettleDelay: UInt64 = 1_800_000_000  // 1.8s

    /// Per-group tracking for Sonos's TuneIn ad-pre-roll loop. The
    /// speaker hosts a Sonos-Radio container station (sid=303,
    /// `tunein:31971`) that occasionally takes over a normal TuneIn
    /// station's slot and streams a never-advancing ad from
    /// `tunein-ondemand.cdnstream1.com`; the official app shows the same
    /// loop. Tracking each group's current ad URI gives one WARNING on
    /// entry (so the diagnostic bundle pinpoints why a station "won't
    /// advance") and INFO on exit.
    private var groupTuneInAdLoopURI: [String: String] = [:]

    /// Coordinator ID currently being dragged in the seek bar UI. Set
    /// by `NowPlayingViewModel` on drag-start; cleared on drag-end.
    /// Suppresses anchor rebases from authoritative position reports
    /// while the user is scrubbing — otherwise the slider would fight
    /// the speaker's still-pre-drag position reports.
    private var coordinatorBeingDragged: String?

    // MARK: - Grace periods and position-anchor thresholds
    //
    // Asymmetric: forward catchups beyond 2 s rebase the anchor (covers
    // legitimate cases like a late-attached track change or buffering
    // catchup, comfortably above the observed Sonos↔wall-clock skew of
    // ~0.2–0.8 s and below the smallest user-perceptible seek). Backward
    // drift is ignored unless catastrophic — Sonos UPnP events sometimes
    // arrive late or out-of-order, and rebasing on stale events produced
    // visible backward jumps in the seek bar and lyrics. Real backward
    // seeks never reach this path; they go through `setPositionAnchor`
    // explicitly. 30 s is empirically beyond the worst stale-event
    // delay observed.
    private static let forwardRebaseThreshold: TimeInterval = 2.0
    private static let backwardRebaseThreshold: TimeInterval = 30.0

    public func setTransportGrace(groupID: String, duration: TimeInterval = 5) {
        transportGraceUntils[groupID] = Date().addingTimeInterval(duration)
    }



    public func setModeGrace(groupID: String, duration: TimeInterval = 5) {
        modeGraceUntils[groupID] = Date().addingTimeInterval(duration)
    }



    public func setPositionGrace(coordinatorID: String, duration: TimeInterval = 5) {
        positionGraceUntils[coordinatorID] = Date().addingTimeInterval(duration)
    }

    // MARK: - Settings

    public var startupMode: StartupMode {
        didSet { UserDefaults.standard.set(startupMode.rawValue, forKey: UDKey.startupMode) }
    }

    public var communicationMode: CommunicationMode {
        didSet {
            UserDefaults.standard.set(communicationMode.rawValue, forKey: UDKey.communicationMode)
            // Serialize switches: two rapid toggles would otherwise
            // interleave across the stop/start awaits and leave two live
            // strategies running. Each new switch awaits the previous
            // switch task before stopping/creating strategies.
            let previous = strategySwitchTask
            strategySwitchTask = Task { [weak self] in
                await previous?.value
                await self?.switchTransportStrategy()
            }
        }
    }

    /// In-flight communication-mode switch — chained so switches run
    /// strictly one at a time (see `communicationMode.didSet`).
    private var strategySwitchTask: Task<Void, Never>?

    public var discoveryMode: DiscoveryMode {
        didSet {
            UserDefaults.standard.set(discoveryMode.rawValue, forKey: UDKey.discoveryMode)
            Task { @MainActor in await switchDiscoveryTransports() }
        }
    }

    public var appearanceMode: AppearanceMode {
        didSet { UserDefaults.standard.set(appearanceMode.rawValue, forKey: UDKey.appearanceMode) }
    }

    /// Karaoke window's own theme — independent of the main `appearanceMode`.
    /// Defaults to `.dark` (see `UDKey.karaokeAppearanceMode` for rationale).
    public var karaokeAppearanceMode: AppearanceMode {
        didSet { UserDefaults.standard.set(karaokeAppearanceMode.rawValue, forKey: UDKey.karaokeAppearanceMode) }
    }

    public var appLanguage: AppLanguage {
        didSet { UserDefaults.standard.set(appLanguage.rawValue, forKey: UDKey.appLanguage) }
    }

    public var accentColor: StoredColor {
        didSet { accentColor.save(to: "accentColor") }
    }
    public var playingZoneColor: StoredColor {
        didSet { playingZoneColor.save(to: "playingZoneColor") }
    }
    public var inactiveZoneColor: StoredColor {
        didSet { inactiveZoneColor.save(to: "inactiveZoneColor") }
    }

    // MARK: - Services (injectable for testability)

    /// Active discovery transports. Populated by `applyDiscoveryMode()` based
    /// on `discoveryMode`. In `.auto` both SSDP and mDNS run concurrently;
    /// `discoveredLocations` (URL-keyed) is the dedup point so duplicate
    /// reports from the same speaker via two transports are harmless.
    private var discoveryTransports: [any SpeakerDiscovery] = []
    /// HouseholdID hints learned from mDNS TXT records, keyed by location URL.
    /// Consulted in `handleDiscoveredDevice` to skip `GetHouseholdID`
    /// when the network already supplied the answer.
    private var householdHints: [String: String] = [:]
    private let soap: SOAPClient
    private let cache: SonosCache
    // Lazy so services share a single SOAPClient (and its URLSession)
    @ObservationIgnored private lazy var avTransport = AVTransportService(soap: soap)
    @ObservationIgnored private lazy var renderingControl = RenderingControlService(soap: soap)

    /// EQ collaborator. `RenderingControlService` already implements every
    /// member of `EQServiceProtocol`, so EQ needs no wrapper of its own.
    /// Views call `sonosManager.eq.setEQ(…)`.
    public var eq: EQServiceProtocol { renderingControl }
    @ObservationIgnored private lazy var zoneTopology = ZoneGroupTopologyService(soap: soap)

    /// Owns groups, devices and the bonded-channel maps. The manager
    /// orchestrates around it and holds no topology state of its own.
    /// Owns per-device volume and mute. Takes `topology` by injection.
    /// Owns the live queue: reads, mutations, and the repair/fill bookkeeping.
    /// Every queue read runs through the enricher.
    @ObservationIgnored public private(set) lazy var queue: QueueController = {
        let q = QueueController(contentDirectory: contentDirectory, enricher: enricher)
        q.snapshotter = self
        q.rowRepairer = self
        q.durationSource = { [weak self] in self?.playHistoryManager }
        return q
    }()

    /// Owns the play-time metadata cache, the local-album-art store and the
    /// self-heals that fill either in.
    @ObservationIgnored public private(set) lazy var enricher: TrackMetadataEnricher = {
        let e = TrackMetadataEnricher(albumArtSearch: albumArtSearch)
        e.nowPlayingPatcher = self
        e.mediaServerHosts = self
        return e
    }()

    /// Owns local-library capability, share rules and the browse sections.
    /// Media-server sections are contributed by the manager so the store stays
    /// unaware of that feature.
    @ObservationIgnored public private(set) lazy var library: LibraryStore = {
        let l = LibraryStore(contentDirectory: contentDirectory, topology: topology)
        l.sectionContributor = self
        return l
    }()

    @ObservationIgnored public private(set) lazy var volume: VolumeController = {
        let v = VolumeController(renderingControl: renderingControl,
                                 topology: topology,
                                 publishTag: { [weak self] tag in self?.tagPublish(tag) })
        v.nowPlayingContext = self
        return v
    }()

    @ObservationIgnored public private(set) lazy var topology = TopologyStore(
        zoneTopology: zoneTopology,
        refreshMinInterval: 10,
        publishTag: { [weak self] tag in self?.tagPublish(tag) })
    @ObservationIgnored private lazy var contentDirectory = ContentDirectoryService(soap: soap)
    @ObservationIgnored private lazy var alarmClock = AlarmClockService(soap: soap)
    @ObservationIgnored private lazy var musicServices = MusicServicesService(soap: soap)

    private var discoveredLocations: Set<String> = []  // de-dups SSDP responses
    /// Device IDs whose first discovery this app session has already
    /// driven a topology refresh. Distinct from `discoveredLocations`
    /// (cleared every 30 s by the rescan timer) and from `devices`
    /// (pre-populated from the persisted cache at launch). Ensures each
    /// device's first SSDP response per session triggers `refreshTopology`
    /// even when it matches the cached snapshot — otherwise
    /// `isUsingCachedData` (cleared only there) is stranded true.
    private var sessionDiscoveredDeviceIDs: Set<String> = []

    /// Per-URI Apple-Music enrichment in flight, so transport update
    /// ticks don't fire duplicate iTunes lookups.
    private var appleMusicEnrichmentInFlight: Set<String> = []

    /// Metadata cache used to persist Apple-Music-by-track-ID results
    /// across launches. Backed by the same SQLite file the lyrics /
    /// artist / album caches use. Lazy so the DB is not opened on
    /// init for callers that never play Apple Music.
    @ObservationIgnored private lazy var metadataCacheForAppleMusic: MetadataCacheRepository? = {
        let path = AppPaths.appSupportDirectory.appendingPathComponent("play_history.sqlite").path
        return MetadataCacheRepository(dbPath: path)
    }()

    /// Codable payload for the Apple-Music-by-track-ID enrichment cache.
    /// `title` and `artURL` are optional: older cached entries lack them.
    fileprivate struct AppleMusicTrackEnrichment: Codable, Sendable {
        let artist: String
        let album: String?
        let title: String?
        let artURL: String?
        /// Track length from the catalogue. Optional so entries cached
        /// before it was recorded still decode; a bare queue row (one the
        /// speaker could not resolve) reports no length of its own, and
        /// the transport shows "Live" for a zero duration.
        var durationSeconds: TimeInterval? = nil
    }



    /// Recoverable queue snapshots taken before destructive mutations
    /// (replace-all, clear, bulk remove). See `QueueHistoryStore`.
    public let queueHistory = QueueHistoryStore()

    /// Choragus-side saved queues — independent of the Sonos household.
    @ObservationIgnored public lazy var savedQueueRepo: SavedQueueRepository = {
        let repo = SavedQueueRepository(
            dbPath: AppPaths.appSupportDirectory.appendingPathComponent("saved_queues.sqlite").path)
        repo.purgeDeleted(before: Self.deletedSavedQueueCutoff())
        return repo
    }()

    /// Deleted Items older than the retention window are gone.
    private static func deletedSavedQueueCutoff() -> Date {
        Date().addingTimeInterval(-TimeInterval(Timing.deletedSavedQueueRetentionDays) * 86_400)
    }
    private var refreshTimer: Timer?


    // MARK: - Transport Strategy

    private var transportStrategy: TransportStrategy?
    private var strategyStarted = false

    // MARK: - Network Path Monitor
    //
    // UPnP `SUBSCRIBE` registers a CALLBACK header — the local
    // `EventListener`'s URL — with each speaker. A network path change
    // (VPN toggle, Wi-Fi roam to a different SSID, Ethernet plug/unplug)
    // can invalidate that callback URL because the host's reachable IP
    // shifts. SOAP control still works (outbound connections),
    // but events stop arriving. Rebind subscriptions on path change.
    private var transportPathMonitor: NWPathMonitor?
    private let transportPathQueue = DispatchQueue(label: "com.choragus.sonos.transport-path")
    private var lastTransportPathSignature: String = ""
    private var pendingTransportRestart: Task<Void, Never>?
    /// Trailing timestamps of genuine interface-class swaps, in a rolling
    /// window. A Mac with both Wi-Fi and Ethernet active can oscillate the
    /// primary path every ~minute; each swap is real, so the signature
    /// changes every time and would otherwise rebind subscriptions per flip
    /// (issue #46). Used to detect that flapping and throttle the rebind.
    private var transportPathChangeTimes: [Date] = []
    /// When the last actual subscription rebind ran. Gates the rebind rate so
    /// sustained flapping collapses to one rebind per flap interval.
    private var lastTransportRebind: Date = .distantPast

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
        (transportStrategy as? HybridEventFirstTransport)?.callbackURLString ?? L10n.notAvailable
    }

    /// Album-art search service (iTunes lookup). Public + protocol-typed
    /// so tests can inject a stub and call sites can use the same instance
    /// instead of reaching for `AlbumArtSearchService.shared`.
    public let albumArtSearch: AlbumArtSearchProtocol

    /// Default init with production services
    public convenience init() {
        self.init(soap: SOAPClient(), cache: SonosCache())
    }

    private var artCacheSubscription: AnyCancellable?

    /// Bumped whenever the art cache changes; views that render cached art
    /// through this manager read it (even implicitly via helpers) so the
    /// per-property tracking re-renders them.
    public private(set) var artCacheVersion: Int = 0

    /// Per-second write counter — diagnostic for "every observer thrashes
    /// on every tiny state churn". With @Observable there is no single
    /// publish stream to count, so the total is the sum of tagged sites.
    private var pubChangeReporterTask: Task<Void, Never>?

    /// Per-source publish counters. Each known emission site bumps a
    /// labelled bucket via `tagPublish(_:)`; the per-second `[MGR-PUB]`
    /// reporter prints the breakdown. Total - sum(buckets) = untagged sites.
    private var pubBuckets: [String: Int] = [:]

    /// Bumps the counter for `tag`. Cheap (one dict update); has no
    /// effect on the publish itself.
    @inline(__always)
    private func tagPublish(_ tag: String) {
        pubBuckets[tag, default: 0] += 1
    }

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

        // Karaoke theme defaults to dark on first launch — the karaoke
        // window is an immersive surface; light mode is selectable but
        // not the default. Existing users without a stored value pick
        // up `.dark` automatically.
        let savedKaraokeAppearance = UserDefaults.standard.string(forKey: UDKey.karaokeAppearanceMode) ?? AppearanceMode.dark.rawValue
        self.karaokeAppearanceMode = AppearanceMode(rawValue: savedKaraokeAppearance) ?? .dark

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
        startTransportPathMonitor()

        // Forward art cache changes so views observing `sonosManager` re-render
        // when the cache updates (preserves the prior `@Published` semantics
        // that `discoveredArtURLs` had when it lived on this class).
        artCacheSubscription = artCache.objectWillChange.sink { [weak self] in
            // The sink closure is nonisolated; hop explicitly so the
            // MainActor-isolated writes stay legal when the package moves
            // to the Swift 6 language mode.
            Task { @MainActor [weak self] in
                self?.tagPublish("artCache")
                self?.artCacheVersion &+= 1
            }
        }
        pubChangeReporterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                let buckets = await MainActor.run { () -> [String: Int] in
                    let b = self.pubBuckets
                    self.pubBuckets = [:]
                    return b
                }
                let count = buckets.values.reduce(0, +)
                if count > 0 {
                    let bucketStr = buckets
                        .sorted { $0.value > $1.value }
                        .map { "\($0.key)=\($0.value)" }
                        .joined(separator: " ")
                    sonosDebugLog("[MGR-PUB] last 1s: total=\(count) \(bucketStr)")
                }
            }
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
            // Cached groups are restored verbatim, so a household persisted
            // by a build with the #83 coordinator defect would come back
            // just as inert. Repair on the way in — same rule as the live
            // topology paths.
            let cachedGroups = cache.restoreGroups(from: cached, devices: cachedDevices)
                .map { group -> SonosGroup in
                    let resolution = TopologyCoordinatorResolver.resolve(
                        reported: group.coordinatorID,
                        visibleMemberIDs: group.members.map(\.id))
                    guard resolution.substituted else { return group }
                    sonosDiagLog(.error, tag: "TOPOLOGY",
                                 "Cached group had no usable coordinator — substituting",
                                 context: [
                                    "groupID": group.id,
                                    "reportedCoordinator": group.coordinatorID,
                                    "substituted": resolution.coordinatorID
                                 ])
                    return SonosGroup(id: group.id,
                                      coordinatorID: resolution.coordinatorID,
                                      members: group.members,
                                      householdID: group.householdID)
                }
            let cachedSections = cache.restoreBrowseSections(from: cached)

            if !cachedGroups.isEmpty {
                topology.applyCached(groups: cachedGroups, devices: cachedDevices)
                library.applyCachedSections(cachedSections)
                self.isUsingCachedData = true
                self.cacheAge = cached.ageDescription
            }
        }

        // Start live discovery (runs in background regardless of cache)
        isDiscovering = true
        isRefreshing = true
        for t in discoveryTransports { t.startDiscovery() }

        // Safety timeout — same as `rescan()`. Without it, `isRefreshing`
        // stays true forever when no speakers respond to the M-SEARCH
        // (multicast blocked, network wedged) and the spinner spins
        // indefinitely.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self else { return }
            if self.isRefreshing {
                sonosDebugLog("[DISCOVERY] Startup discovery timeout — no devices responded within 8 s")
                self.isRefreshing = false
            }
        }

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

    /// Best-effort GENA cleanup for app quit — unsubscribes every event
    /// subscription so the speakers don't spend the next lease period
    /// timing out against a dead callback before serving live subscribers.
    public func unsubscribeAllForShutdown() async {
        await transportStrategy?.stop()
        transportStrategy = nil
        strategyStarted = false
    }

    public func rescan() {
        sonosDebugLog("[DISCOVERY] Manual rescan triggered — clearing \(discoveredLocations.count) cached locations, pinging \(discoveryTransports.count) transport(s)")
        discoveredLocations.removeAll()
        isRefreshing = true
        for t in discoveryTransports { t.rescan() }
        // Unicast fallback: SSDP M-SEARCH is multicast and dies silently
        // on networks that filter it — leaving Refresh unable to correct
        // a bad topology even though every speaker is directly reachable.
        // Force a topology re-pull over plain HTTP from one known device
        // per household in parallel with the SSDP attempt.
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Coordinators first — a satellite's topology answer is a
            // self-view the merge guard rejects, so it wastes the shot.
            let candidates = self.devices.values
                .filter { !$0.id.hasSuffix("_MR") }
                .sorted { ($0.isCoordinator ? 0 : 1) < ($1.isCoordinator ? 0 : 1) }
            var refreshedHouseholds = Set<String>()
            for device in candidates {
                let household = device.householdID ?? device.id
                guard !refreshedHouseholds.contains(household) else { continue }
                refreshedHouseholds.insert(household)
                await self.refreshTopology(from: device, force: true)
            }
        }
        // Safety timeout — without this, `isRefreshing` stays true
        // forever when no speakers respond to the M-SEARCH (router
        // change wedged the network, multicast blocked, etc.) and
        // the spinner spins indefinitely.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self else { return }
            if self.isRefreshing {
                sonosDebugLog("[DISCOVERY] Rescan timeout — no devices responded within 8 s")
                self.isRefreshing = false
            }
        }
    }

    /// Watches for network path changes and rebinds UPnP event
    /// subscriptions when the path signature shifts. Signature folds
    /// status + first-interface-type so a same-class roam (Wi-Fi to
    /// Wi-Fi at a different SSID) doesn't unnecessarily churn — but a
    /// real interface-class swap (Wi-Fi ↔ Ethernet, VPN on/off) does.
    /// 800 ms debounce coalesces the flurry of path updates that fire
    /// during the actual transition.
    private func startTransportPathMonitor() {
        guard transportPathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let iface = path.availableInterfaces.first.map { String(describing: $0.type) } ?? "none"
            let sig = "\(path.status)|\(iface)"
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Speaker-subnet affinity: the only thing that actually
                // invalidates the UPnP event-callback URL is a change in the
                // LOCAL address speakers reach this host on. Prefer that as the
                // change signal so a path event that doesn't move the speaker-facing
                // IP (VPN toggle, signal blip, same-class roam) doesn't churn
                // subscriptions. Fall back to the interface-class signature
                // until a speaker is known (issue #46).
                let effectiveSig = self.localAddressFacingSpeakers().map { "ip:\($0)" } ?? sig
                if self.lastTransportPathSignature.isEmpty {
                    self.lastTransportPathSignature = effectiveSig
                    return
                }
                guard effectiveSig != self.lastTransportPathSignature else { return }
                self.lastTransportPathSignature = effectiveSig

                // Flap detection: count genuine speaker-facing changes in a
                // rolling 2-minute window. ≥3 means the link is oscillating,
                // not a one-off transition.
                let now = Date()
                self.transportPathChangeTimes.append(now)
                self.transportPathChangeTimes.removeAll { now.timeIntervalSince($0) > 120 }
                let flapping = self.transportPathChangeTimes.count >= 3
                if flapping { self.networkAdvisory = L10n.networkUnstableAdvisory }

                self.pendingTransportRestart?.cancel()
                self.pendingTransportRestart = Task { @MainActor [weak self] in
                    // Trailing-edge debounce coalesces the flurry of one
                    // transition.
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    guard !Task.isCancelled, let self else { return }
                    // Under flapping, throttle hard: collapse all swaps into at
                    // most one rebind per flap interval rather than one per
                    // flip. The periodic rescan reconciles speakers meanwhile,
                    // so rebinding on every flip is futile churn (issue #46).
                    if flapping {
                        let wait = self.lastTransportRebind.addingTimeInterval(180).timeIntervalSinceNow
                        if wait > 0 {
                            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                            guard !Task.isCancelled else { return }
                        }
                    }
                    self.lastTransportRebind = Date()
                    await self.transportStrategy?.restartForNetworkChange()
                    // Clear the advisory once the link has settled below the
                    // flap threshold.
                    let settled = Date()
                    self.transportPathChangeTimes.removeAll { settled.timeIntervalSince($0) > 120 }
                    if self.transportPathChangeTimes.count < 3 { self.networkAdvisory = nil }
                }
            }
        }
        monitor.start(queue: transportPathQueue)
        transportPathMonitor = monitor
    }

    /// The local IPv4 address the OS would use to reach the speakers, or nil
    /// if no speaker is known yet. A connected UDP socket sends no packets —
    /// the kernel just resolves the source address for that destination, which
    /// is exactly the address the UPnP event-callback URL must advertise. A
    /// change in it is the true trigger for re-subscribing; a path event that
    /// leaves it unchanged is cosmetic and can be ignored (issue #46).
    private func localAddressFacingSpeakers() -> String? {
        guard let host = groups.first?.coordinator?.ip ?? devices.values.first?.ip,
              !host.isEmpty else { return nil }
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var dest = sockaddr_in()
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = in_port_t(UInt16(1400).bigEndian)   // any port; route only
        guard inet_pton(AF_INET, host, &dest.sin_addr) == 1 else { return nil }
        let connected = withUnsafePointer(to: &dest) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }
        var local = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &local) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard got == 0 else { return nil }
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &local.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buf)
    }

    /// Builds the active transport list from `discoveryMode` and wires the
    /// shared `onDeviceFound` callback. Called once at init and again on
    /// every mode change.
    private func rebuildDiscoveryTransports() {
        var modes: [any SpeakerDiscovery]
        switch discoveryMode {
        case .auto:    modes = [SSDPDiscovery(), MDNSDiscovery()]
        case .bonjour: modes = [MDNSDiscovery()]
        case .ssdp:    modes = [SSDPDiscovery()]
        }
        // Seed addresses run in every mode. They are the escape hatch for
        // networks that block multicast outright, where neither transport
        // above can work and no hop limit changes that.
        if !Self.seedAddresses().isEmpty {
            modes.append(SeedAddressDiscovery(addresses: { Self.seedAddresses() }))
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

    /// User-supplied probe addresses, one per line, blank lines ignored.
    nonisolated static func seedAddresses() -> [String] {
        (UserDefaults.standard.string(forKey: UDKey.seedSpeakerAddresses) ?? "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Tears down current transports, rebuilds for the new mode, and (if
    /// already discovering) starts the new set + clears the dedup cache
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

    /// Locations whose description fetch failed, with exponential backoff.
    /// After a VLAN / subnet move the topology cache and the Mac's stale
    /// mDNS answers keep re-surfacing the speakers' OLD addresses on every
    /// 30 s rescan; without backoff each dead address burns a full fetch
    /// timeout per cycle and the real (reflected) locations queue behind
    /// them — observed as live speakers "slowly appearing" after launch.
    private var failedLocationBackoff: [String: (failures: Int, until: Date)] = [:]

    private func handleDiscoveredDevice(location: String, ip: String, port: Int) async {
        guard !discoveredLocations.contains(location) else { return }
        if let backoff = failedLocationBackoff[location], backoff.until > Date() { return }
        discoveredLocations.insert(location)

        do {
            guard let desc = try await DeviceDescriptionParser.fetch(from: location) else { return }
            failedLocationBackoff[location] = nil

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
            // transport surfaced it the SOAP call is skipped entirely (`householdHints`).
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

            // Guard the write — fires on every assignment, even
            // when values are identical. Unnecessary fires cascade re-renders
            // through every @EnvironmentObject observer of SonosManager.
            // Logging gated on the same condition so periodic rediscovery
            // of an unchanged device doesn't flood the debug log.
            let isNewOrChanged = devices[device.id] != device
            if isNewOrChanged {
                sonosDebugLog("[DISCOVERY] \(desc.roomName) swGen=\(desc.swGen) softwareVersion=\(desc.softwareVersion) household=\(device.householdID ?? "<nil>")")
                topology.upsertDevice(device)
            }
            // Refresh topology when:
            //  (a) the device is new or has materially changed this run, OR
            //  (b) no refresh has run for this device in this app session
            //      (cache-restore case: every cached device matches its live
            //      SSDP response, `isNewOrChanged` is false for all of them,
            //      and `refreshTopology` — which owns `isUsingCachedData` —
            //      would otherwise never run).
            // Subsequent same-session SSDP responses for an unchanged
            // device still skip the refresh (SSDP-rotation flap).
            let isFirstThisSession = !sessionDiscoveredDeviceIDs.contains(device.id)
            sessionDiscoveredDeviceIDs.insert(device.id)
            if isNewOrChanged || isFirstThisSession {
                await refreshTopology(from: device)
            }
        } catch {
            let failures = (failedLocationBackoff[location]?.failures ?? 0) + 1
            // 1 min → 2 → 4 → … capped at 15 min between retries.
            let delay = min(900.0, 60.0 * pow(2.0, Double(failures - 1)))
            failedLocationBackoff[location] = (failures, Date().addingTimeInterval(delay))
            sonosDebugLog("[DISCOVERY] Device description fetch failed (attempt \(failures), retry in \(Int(delay))s): \(location)")
        }
    }

    /// Pulls topology from `device` and runs the side effects an applied
    /// merge implies. The merge itself — serialization, throttling,
    /// self-view rejection, coordinator repair, channel maps — belongs to
    /// `TopologyStore`; what remains here is orchestration.
    public func refreshTopology(from device: SonosDevice, force: Bool = false) async {
        let result = await topology.refresh(from: device, force: force)

        switch result.outcome {
        case .inFlight, .throttled, .failed:
            break
        case .noHousehold, .rejectedSelfView:
            // The merge was declined, so the refresh is over: clear the
            // spinner.
            if isRefreshing { isRefreshing = false }
        case .applied:
            if result.changed { saveCache() }

            // Check newly-seen devices for a fixed line-out so the UI can
            // disable their volume slider before the user hits a 501 (#50).
            // Cheap + idempotent: only un-checked devices are queried.
            Task { [weak self] in await self?.refreshFixedOutputStatus() }

            // Equality-gate the three flag writes: they fire after every
            // per-speaker topology refresh, and ~30 unchanged publishes/sec
            // starve the karaoke TimelineView's frame budget.
            if self.isUsingCachedData != false {
                tagPublish("flag")
                self.isUsingCachedData = false
            }
            if self.isRefreshing != false {
                tagPublish("flag")
                self.isRefreshing = false
            }
            if self.staleMessage != nil {
                tagPublish("flag")
                self.staleMessage = nil
            }

            // Start or update transport strategy
            await startOrUpdateTransportStrategy()

            // Scan all groups for current status in background (don't block UI)
            Task { await scanAllGroups() }
        }

        // A forced refresh that arrived mid-flight was deferred rather than
        // dropped; re-drive through this method so its side effects run too.
        if result.rerunForced {
            Task { [weak self] in await self?.refreshTopology(from: device, force: true) }
        }
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

            // Same grace check as the event path (`transportDidUpdateState`):
            // a poll whose result predates an optimistic write must not
            // revert it (e.g. stale .stopped clobbering an optimistic
            // .playing set by a play action moments earlier).
            var applyTransportState = true
            if let grace = transportGraceUntils[coordinator.id], Date() < grace {
                let currentOptimistic = groupTransportStates[coordinator.id]
                if state == currentOptimistic {
                    transportGraceUntils[coordinator.id] = nil
                } else if currentOptimistic == .transitioning && state == .playing {
                    transportGraceUntils[coordinator.id] = nil
                } else {
                    applyTransportState = false
                }
            }
            if applyTransportState {
                updateTransportState(coordinator.id, state: state)
            }
            updatePlayMode(coordinator.id, mode: mode)

            // Pre-fetch queue items so track info recovery works for service tracks
            if enricher.lastQueueItems[coordinator.id] == nil || enricher.lastQueueItems[coordinator.id]?.isEmpty == true {
                if let queueResult = try? await contentDirectory.browseQueue(device: coordinator, start: 0, count: PageSize.queue) {
                    // Through the enricher, not straight into the dictionary,
                    // so this path and `getQueue` store the same enriched rows.
                    enricher.recordQueuePage(queueResult.items, for: coordinator.id)
                }
            }

            // Polling path only: the event path gets the same value for
            // free out of every AVTransport LastChange.
            if let actions = try? await avTransport.getCurrentTransportActions(device: coordinator) {
                transportDidUpdateTransportActions(coordinator.id, actions: actions)
            }

            var enriched = position
            // Always fetch mediaInfo to set isQueueSource correctly
            // (prevents queue metadata leaking into direct stream playback)
            if let mediaInfo = try? await avTransport.getMediaInfo(device: coordinator) {
                enriched.enrichFromMediaInfo(mediaInfo, device: coordinator)
            }
            transportDidUpdateTrackMetadata(coordinator.id, metadata: enriched, source: .poll)

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
        groupTransportStatePublisher.send(groupTransportStates)
        groupTrackMetadata.removeAll()
        groupPlayModes.removeAll()
        groupTransportActions.removeAll()
        groupPositions.removeAll()
        groupDurations.removeAll()
        volume.reset()

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

    /// Per-room consecutive AVTransport-failure counter. Reset on the
    /// next successful call. Used by `handleStaleness` to escalate
    /// the user-facing message after the second failure in a row.
    private var consecutiveStaleFailures: [String: Int] = [:]
    /// Debounces `rescan()` calls triggered by `handleStaleness` so a
    /// burst of failures (e.g., the user mashing Play after a router
    /// change) doesn't fire repeated discovery rounds. 10 s window
    /// is long enough for one rescan to publish topology before the
    /// next is considered.
    private var lastStalenessRescanAt: Date = .distantPast

    /// Wraps a SOAP action with stale-data detection. Successful
    /// returns clear the per-room failure counter. Triggers covered:
    ///   - `networkError` (device unreachable)
    ///   - SOAP 701 ("invalid object" — speaker regrouped or stale
    ///     topology cache)
    ///   - `s:Client` (generic SOAP client-side error)
    /// Two consecutive failures surface a clearer "speakers
    /// reconnecting…" message hinting that a power-cycle may be
    /// needed if the auto-rediscovery doesn't fix it.
    ///
    /// SOAP 714 ("no such resource") is handled separately: the dominant
    /// trigger is the speaker rejecting a SMAPI single-track direct-play
    /// URI (issue #42), not stale topology. For 714 the call throws
    /// `.serviceRejected` and skips both the topology rescan and the
    /// "Speaker layout has changed" banner.
    /// True when `uri` is a SMAPI service-track scheme that the
    /// speaker rejects via direct `SetAVTransportURI` (UPnP 714) and
    /// must be enqueued instead. Issue #42. Covers:
    ///   - `x-sonos-spotify:` — Spotify single tracks
    ///   - `x-sonos-http:` — HTTP-backed SMAPI tracks (Calm Radio sid=310,
    ///     and any other service whose tracks resolve to this scheme)
    ///   - `x-sonos-hls:` — HLS-backed SMAPI tracks
    /// Deliberately excludes `x-sonosapi-stream:` (TuneIn music
    /// stations — direct play works), `x-rincon-mp3radio:` /
    /// `https:` (raw radio streams), and the already-queue-based
    /// `x-rincon-queue:` / `x-rincon-cpcontainer:` URIs.
    /// True when the URI's `sid=` names the household's Amazon Music
    /// service.
    nonisolated static func isAmazonMusicURI(_ uri: String) -> Bool {
        guard let sid = ServiceSearchProvider.extractSid(from: uri) else { return false }
        return MusicServiceCatalog.shared.rules(forSid: sid)?.canonicalName == ServiceName.amazonMusic
    }

    nonisolated static func isSMAPIServiceTrackURI(_ uri: String) -> Bool {
        return uri.hasPrefix("x-sonos-spotify:")
            || uri.hasPrefix("x-sonos-http:")
            || uri.hasPrefix("x-sonos-hls:")
            // Apple Music tracks use the official app's hls-static form;
            // direct SetAVTransportURI rejects service tracks, so they
            // keep the queue-replace routing.
            || uri.hasPrefix(URIPrefix.sonosApiHLSStatic)
    }

    /// Pure classification of a SOAP fault into a `StaleDataError`.
    /// Returns `nil` to indicate "rethrow the underlying SOAP error as-is".
    /// Side effects (rescan trigger, user-visible banner) live in
    /// `withStaleHandling` and key off the same code paths. Extracted
    /// as a static helper so the mapping rules can be unit-tested
    /// without bringing up a live `SonosManager`.
    nonisolated static func classifySOAPFault(_ error: SOAPError, roomName: String) -> StaleDataError? {
        switch error {
        case .networkError:
            return .deviceUnreachable(roomName)
        case .soapFault(let code, _) where code == "714":
            return .serviceRejected
        case .soapFault(let code, _) where code == "701" || code == "s:Client":
            return .topologyStale
        default:
            return nil
        }
    }

    private func withStaleHandling<T>(for roomName: String, _ action: () async throws -> T) async throws -> T {
        do {
            let result = try await action()
            consecutiveStaleFailures[roomName] = 0
            return result
        } catch let error as SOAPError {
            guard let mapped = Self.classifySOAPFault(error, roomName: roomName) else {
                throw error
            }
            // Trigger rescan + banner for topology-like errors only.
            // `.serviceRejected` is intentionally quiet — it's a
            // per-track URI rejection, not a topology event.
            switch mapped {
            case .deviceUnreachable:
                handleStaleness(for: roomName, kind: "network")
            case .topologyStale:
                if case .soapFault(let code, _) = error {
                    handleStaleness(for: roomName, kind: code)
                }
            case .serviceRejected, .groupChanged, .serviceUnavailable, .libraryNotConfigured,
                 .nothingLoaded, .notPlayable, .tracksSkippingEarly, .serviceTierRefused:
                break
            }
            throw mapped
        }
    }

    private func handleStaleness(for roomName: String, kind: String) {
        let count = (consecutiveStaleFailures[roomName] ?? 0) + 1
        consecutiveStaleFailures[roomName] = count
        if count >= 2 {
            staleMessage = L10n.staleReconnecting
        } else {
            staleMessage = kind == "network"
                ? L10n.staleRoomNotResponding(roomName)
                : L10n.staleLayoutChanged
        }
        let now = Date()
        if now.timeIntervalSince(lastStalenessRescanAt) > 10 {
            lastStalenessRescanAt = now
            rescan()
        }
        sonosDebugLog("[STALE] \(roomName) AVTransport fault=\(kind) consecutive=\(count) — rescan triggered=\(now.timeIntervalSince(lastStalenessRescanAt) <= 0.1)")
    }

    public func dismissStaleMessage() {
        staleMessage = nil
    }

    public func dismissNetworkAdvisory() {
        networkAdvisory = nil
    }

    // MARK: - Playback Control

    public func play(group: SonosGroup) async throws {
        guard let coordinator = group.coordinator else { return }
        try await transportCommand(for: group, on: coordinator) {
            try await self.avTransport.play(device: coordinator)
        }
    }

    public func pause(group: SonosGroup) async throws {
        guard let coordinator = group.coordinator else { return }
        try await transportCommand(for: group, on: coordinator) {
            try await self.avTransport.pause(device: coordinator)
        }
    }

    /// Play/Pause against a transport with no source loaded faults UPnP 701 —
    /// the same code stale topology produces (issue #72). One `GetMediaInfo`
    /// on the failure path distinguishes them BEFORE the staleness machinery
    /// fires, so an empty transport reports the actual situation instead of a
    /// rescan and a "layout changed" banner. Every other failure re-enters
    /// `withStaleHandling` so its classification and side effects stay in one
    /// place.
    private func transportCommand(for group: SonosGroup, on coordinator: SonosDevice,
                                  _ action: () async throws -> Void) async throws {
        do {
            try await action()
            consecutiveStaleFailures[group.name] = 0
        } catch let error as SOAPError {
            if case .soapFault(let code, _) = error, code == "701",
               let media = try? await avTransport.getMediaInfo(device: coordinator),
               (media["CurrentURI"] ?? "").isEmpty {
                sonosDiagLog(.info, tag: "TRANSPORT",
                             "Transport command rejected: nothing loaded on the speaker (issue #72)",
                             context: ["room": group.name])
                throw StaleDataError.nothingLoaded
            }
            return try await withStaleHandling(for: group.name) { throw error }
        }
    }

    public func stop(group: SonosGroup) async throws {
        guard let coordinator = group.coordinator else { return }
        try await withStaleHandling(for: group.name) {
            try await avTransport.stop(device: coordinator)
        }
    }

    /// Whether `Next` is available for `group` right now.
    ///
    /// The speaker's own `CurrentTransportActions` is authoritative and
    /// the only thing that gets service radio right: an Amazon Music
    /// station reports `Set, Stop, Pause, Play, Next` (Amazon grants a
    /// limited number of skips per station) while a TuneIn stream on the
    /// same `x-sonosapi-radio:` scheme reports no skip at all. Until the
    /// speaker has reported — the window between launch and the first
    /// event or poll — fall back to the URI-shape heuristic so the
    /// button doesn't flash enabled on a stream that can't skip.
    public func canSkipNext(group: SonosGroup) -> Bool {
        groupTransportActions[group.coordinatorID]?.canSkipNext
            ?? skipHeuristic(for: group)
    }

    /// Whether `Previous` is available — see `canSkipNext(group:)`.
    /// Service radio typically allows `Next` but not `Previous`.
    public func canSkipPrevious(group: SonosGroup) -> Bool {
        groupTransportActions[group.coordinatorID]?.canSkipPrevious
            ?? skipHeuristic(for: group)
    }

    /// Pre-report fallback: queue playback always skips; a radio URI or a
    /// station name outside the queue means no skip.
    private func skipHeuristic(for group: SonosGroup) -> Bool {
        guard let metadata = groupTrackMetadata[group.coordinatorID] else { return true }
        if metadata.isQueueSource { return true }
        return !metadata.isRadioStream && metadata.stationName.isEmpty
    }

    public func next(group: SonosGroup) async throws {
        lastControllerTransportCommandAt[group.coordinatorID] = Date()
        guard let coordinator = group.coordinator else { return }
        try await withStaleHandling(for: group.name) {
            try await avTransport.next(device: coordinator)
        }
    }

    public func previous(group: SonosGroup) async throws {
        lastControllerTransportCommandAt[group.coordinatorID] = Date()
        guard let coordinator = group.coordinator else { return }
        try await withStaleHandling(for: group.name) {
            try await avTransport.previous(device: coordinator)
        }
    }

    public func seek(group: SonosGroup, to time: String) async throws {
        lastControllerTransportCommandAt[group.coordinatorID] = Date()
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

    // MARK: - Line-in sources
    //
    // Transport state, not volume: derives from each group's current
    // track URI.

    /// Device IDs whose line-out volume is Fixed (Connect / Port / Amp locked
    /// in the Sonos app). `SetVolume` faults UPnP 501 on these (issue #50), so
    /// the UI disables their slider and `setVolume` no-ops. Populated by
    /// `refreshFixedOutputStatus` and self-heals from a live 501.




    /// Device IDs currently acting as a line-in SOURCE — some group is
    /// streaming their analog input (`x-rincon-stream:RINCON_<id>`). Used to
    /// badge the speaker list, so a room with an active line-in is obvious even
    /// when the source speaker itself shows "no music".
    public var lineInSourceDeviceIDs: Set<String> {
        let prefix = "x-rincon-stream:"
        var ids = Set<String>()
        for md in groupTrackMetadata.values {
            guard let uri = md.trackURI, uri.hasPrefix(prefix) else { continue }
            let id = uri.dropFirst(prefix.count).prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            if !id.isEmpty { ids.insert(String(id)) }
        }
        return ids
    }






    // MARK: - Apple Music queue repair

    /// Stays on the façade: it drives the queue controller's repair
    /// bookkeeping but reads `groupTrackMetadata` (transport state) to know
    /// which row is playing.
    /// Apple Music rows enqueue descriptor-free for speed (~0.15 s/track vs
    /// ~1.1 s — the slow form makes the speaker fetch metadata from Apple
    /// per track at enqueue), but the speaker then stores NO title, so other
    /// controllers (incl. the official app) show unnamed rows. This walker
    /// repairs each row in the background: insert a service-descriptor copy
    /// at the same position (speaker fetches the canonical name, ~1.1 s) and
    /// remove the bare row — net-zero position shift, names appear
    /// progressively in every controller while playback already runs.
    ///
    /// Each swap re-verifies the row (same URI, still bare) so user
    /// reorders/removals make it skip rather than corrupt, and rows at or
    /// adjacent to the playing position are left alone (removing the playing
    /// row would skip playback; +1 covers an advance mid-swap).
    public func scheduleAppleMusicQueueRepair(group: SonosGroup, rows: [(position: Int, uri: String)]) {
        scheduleAppleMusicQueueRepair(group: group, rows: rows, pass: 1)
    }

    /// Rows at or just after the playing position cannot be swapped
    /// while they sit there (removing the playing row skips playback,
    /// +1 covers an advance mid-swap). They used to be dropped, which
    /// left the row bare for good: no title, no duration, and Now
    /// Playing reading "Live" when it came round. A pass that had to
    /// leave rows behind now books another for them once playback has
    /// had time to move on; each pass re-verifies the row is the same
    /// URI and still bare, so a row that resolved or moved is skipped.
    static let repairRetryDelay: TimeInterval = 20
    /// Long enough to outlast the playing track: a row after the playing
    /// one stays deferred for that track's whole length (a 4:11 song
    /// outlived the earlier 12-pass budget by 30 seconds). Playback
    /// advancing also kicks a pass at once, so this is the ceiling, not
    /// the wait.
    static let repairMaxPasses = 90

    /// Rows a repair had to leave next to playback, waiting for it to move.
    private var pendingRepairRows: [String: [(position: Int, uri: String)]] = [:]

    /// Called when the playing track number changes: rows deferred for
    /// sitting next to the old position are tried again now rather than
    /// on the next timer tick.
    func retryDeferredRepairsIfPlaybackMoved(coordinatorID: String, from oldTrack: Int, to newTrack: Int) {
        guard oldTrack != newTrack, let rows = pendingRepairRows[coordinatorID], !rows.isEmpty,
              let group = groups.first(where: { $0.coordinatorID == coordinatorID }) else { return }
        pendingRepairRows[coordinatorID] = nil
        scheduleAppleMusicQueueRepair(group: group, rows: rows, pass: 1)
    }

    /// True when `position` must be left alone on this pass.
    static func repairShouldDefer(position: Int, playing: Int) -> Bool {
        position == playing || position == playing + 1
    }

    private func scheduleAppleMusicQueueRepair(group: SonosGroup, rows: [(position: Int, uri: String)], pass: Int) {
        guard let coordinator = group.coordinator else { return }
        let amRows = rows.filter { URIPrefix.appleMusicSongID(from: $0.uri) != nil }
        guard !amRows.isEmpty else { return }
        let previous = self.queue.queueRepairTasks[coordinator.id]
        self.queue.queueRepairDepth[coordinator.id, default: 0] += 1
        self.queue.queueRepairTasks[coordinator.id] = Task { [weak self] in
            await previous?.value      // serialise with any in-flight repair
            guard let self else { return }
            defer {
                self.queue.queueRepairDepth[coordinator.id, default: 1] -= 1
                if self.queue.queueRepairDepth[coordinator.id, default: 0] <= 0 {
                    self.queue.queueRepairDepth[coordinator.id] = nil
                    self.enricher.postQueueChanged(optimisticItems: [])
                }
            }
            let type = MusicServiceCatalog.shared.rinconServiceType(forSid: ServiceID.appleMusic)
            let desc = "SA_RINCON\(type)_X_#Svc\(type)-0-Token"
            var deferred: [(position: Int, uri: String)] = []
            for (pos, uri) in amRows {
                if Task.isCancelled { return }
                let playing = self.groupTrackMetadata[coordinator.id]?.trackNumber ?? -1
                if Self.repairShouldDefer(position: pos, playing: playing) {
                    deferred.append((pos, uri))
                    continue
                }
                guard let row = try? await self.contentDirectory.browseQueue(
                        device: coordinator, start: pos - 1, count: 1).items.first,
                      row.uri == uri,
                      row.title.isEmpty || TrackMetadata.isTechnicalName(row.title)
                else { continue }
                let songID = URIPrefix.appleMusicSongID(from: uri) ?? ""
                let didl = """
                <DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"><item id="10032020song%3a\(songID)" parentID="-1" restricted="true"><upnp:class>object.item.audioItem.musicTrack</upnp:class><desc id="cdudn" nameSpace="urn:schemas-rinconnetworks-com:metadata-1-0/">\(desc)</desc></item></DIDL-Lite>
                """
                do {
                    _ = try await self.contentDirectory.addURIToQueue(
                        device: coordinator, uri: uri, metadata: didl,
                        desiredFirstTrackNumberEnqueued: pos, enqueueAsNext: true)
                    try await self.contentDirectory.removeTrackFromQueue(
                        device: coordinator, objectID: "Q:0/\(pos + 1)")
                } catch {
                    sonosDiagLog(.warning, tag: "QUEUE",
                                 "AM metadata repair failed at position \(pos)",
                                 context: ["uri": uri, "error": String(describing: error)])
                    continue
                }
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
            // Final reload is posted by the defer above when the last
            // chained repair for this coordinator completes.
            if !deferred.isEmpty, pass < Self.repairMaxPasses {
                sonosDebugLog("[QUEUE] AM metadata repair pass \(pass): \(deferred.count) row(s) adjacent to playback, retrying in \(Int(Self.repairRetryDelay))s")
                self.pendingRepairRows[coordinator.id] = deferred
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(Self.repairRetryDelay * 1_000_000_000))
                    guard let self, !Task.isCancelled else { return }
                    // Playback moving may already have kicked this pass.
                    guard let still = self.pendingRepairRows[coordinator.id], !still.isEmpty else { return }
                    self.pendingRepairRows[coordinator.id] = nil
                    self.scheduleAppleMusicQueueRepair(group: group, rows: still, pass: pass + 1)
                }
            } else if !deferred.isEmpty {
                sonosDiagLog(.warning, tag: "QUEUE", "AM metadata repair gave up on rows next to playback",
                             context: ["rows": deferred.map { String($0.position) }.joined(separator: ","),
                                       "passes": String(pass)])
            }
        }
    }

    // MARK: - Local library (forwarded to LibraryStore)

    public func loadBrowseSections() async {
        // Persist only when the store applied sections. A pass with
        // no reachable device leaves them untouched, and saving then would
        // rewrite the cache from an unchanged picture.
        if await library.loadBrowseSections() { saveCache() }
        // One-shot legacy cleanup, detached so section load never waits on it.
        // Triggered here rather than inside the store: purging queue-history
        // snapshots is not the library's business.
        Task { [weak self] in await self?.purgeLegacySpeakerSnapshots() }
    }

    public func refreshHouseholdCapabilities() async {
        await library.refreshHouseholdCapabilities()
    }

    public func libraryShares() async -> [LibraryStore.LibraryShare] {
        await library.libraryShares()
    }

    public func updateMusicLibrary() async -> (triggered: Int, librariesFound: Int) {
        await library.updateMusicLibrary()
    }

    public var hasMultipleSystems: Bool { library.hasMultipleSystems }
    public var localLibraryGenerations: [SonosSystemVersion] { library.localLibraryGenerations }

    public func availabilityNote(forShareObjectID objectID: String) -> String? {
        library.availabilityNote(forShareObjectID: objectID)
    }

    // MARK: - Volume and mute (forwarded to VolumeController)

    public func transportDidUpdateVolume(_ deviceID: String, volume newValue: Int) {
        volume.applyObservedVolume(deviceID, volume: newValue)
    }

    public func transportDidUpdateMute(_ deviceID: String, muted: Bool) {
        volume.applyObservedMute(deviceID, muted: muted)
    }

    public func getVolume(device: SonosDevice) async throws -> Int {
        try await volume.getVolume(device: device)
    }

    public func setVolume(device: SonosDevice, volume newValue: Int) async throws {
        try await volume.setVolume(device: device, volume: newValue)
    }

    public func getMute(device: SonosDevice) async throws -> Bool {
        try await volume.getMute(device: device)
    }

    public func setMute(device: SonosDevice, muted: Bool) async throws {
        try await volume.setMute(device: device, muted: muted)
    }

    public func isOutputFixed(_ deviceID: String) -> Bool {
        volume.isOutputFixed(deviceID)
    }

    public func ensureFixedOutputChecked(for group: SonosGroup) async {
        await volume.ensureFixedOutputChecked(for: group)
    }

    public func refreshFixedOutputStatus() async {
        await volume.refreshFixedOutputStatus()
    }

    public func setVolumeGrace(deviceID: String, duration: TimeInterval = 5) {
        volume.setVolumeGrace(deviceID: deviceID, duration: duration)
    }

    public func setMuteGrace(deviceID: String, duration: TimeInterval = 5) {
        volume.setMuteGrace(deviceID: deviceID, duration: duration)
    }

    public func isVolumeGraceActive(deviceID: String) -> Bool {
        volume.isVolumeGraceActive(deviceID: deviceID)
    }

    public func isMuteGraceActive(deviceID: String) -> Bool {
        volume.isMuteGraceActive(deviceID: deviceID)
    }

    public func updateDeviceVolume(_ deviceID: String, volume newValue: Int) {
        volume.updateDeviceVolume(deviceID, volume: newValue)
    }

    public func updateDeviceMute(_ deviceID: String, muted: Bool) {
        volume.updateDeviceMute(deviceID, muted: muted)
    }

    // MARK: - Bonded zones (forwarded to TopologyStore)





    /// Returns bonded home theater zones (those with HTSatChanMapSet — sub/surrounds)
    public var homeTheaterZones: [HomeTheaterZone] { topology.homeTheaterZones }

    /// Parsed HTSatChanMapSet data: coordinator ID → [(deviceID, channel)]
    public var htSatChannelMaps: [String: [(String, SpeakerChannel)]] { topology.htSatChannelMaps }

    /// Parsed `ChannelMapSet` data — stereo-pair primaries map their
    /// invisible right-channel sibling here.
    public var stereoChannelMaps: [String: [(String, SpeakerChannel)]] { topology.stereoChannelMaps }



    // MARK: - Apple Music queue metadata repair (fast add, then named)

    /// Early-advance detector state: last observed track identity per
    /// group, and when this controller last issued a transport command
    /// (next/previous/seek) that legitimately truncates a track.
    @ObservationIgnored var lastTrackIdentity: [String: (uri: String, title: String)] = [:]

    /// Timestamps of recent early advances per group, and when the user was
    /// last told, so a failing queue reports once rather than once per track.
    @ObservationIgnored var earlyAdvances: [String: [Date]] = [:]
    @ObservationIgnored var lastEarlyAdvanceReportAt: [String: Date] = [:]
    @ObservationIgnored var lastControllerTransportCommandAt: [String: Date] = [:]










    /// Mosaic cover art for a Choragus-local saved queue, with local-library
    /// rows resolved through iTunes (the stored getaa URLs 404). Async so the
    /// resolution can await; capped at `limit` distinct albums.
    public func choragusCoverArtResolved(localID: Int64, limit: Int = 4) async -> [String] {
        var rows: [(album: String, artist: String, art: String?)] = []
        for track in savedQueueRepo.tracks(for: localID, limit: 24) {
            var art = track.albumArtURI
            if TrackMetadataEnricher.isUnreliableLocalArt(uri: track.uri, art: art) {
                art = await enricher.resolveLocalAlbumArt(artist: track.artist, album: track.album)
            }
            rows.append((track.album, track.artist, art))
            // Stop once there are likely enough distinct albums to fill the mosaic.
            if Self.distinctAlbumArt(rows, limit: limit).count >= limit { break }
        }
        return Self.distinctAlbumArt(rows, limit: limit)
    }





    public func clearQueue(group: SonosGroup) async throws {
        guard let coordinator = group.coordinator else { return }

        // Detect whether the currently-playing source is the queue itself
        // BEFORE its rows are removed. If it is, the speaker will keep
        // showing the (now-orphaned) track in `Track 1` until it advances
        // to a non-existent next position, which leaves the Now Playing
        // header stale. Stop transport and clear local metadata too so
        // the UI matches the new empty state immediately.
        let wasPlayingFromQueue = groupTrackMetadata[group.coordinatorID]?.isQueueSource == true

        // Snapshot before clearing so the user can undo a clear.
        await snapshotQueueForHistory(group: group)

        try await contentDirectory.removeAllTracksFromQueue(device: coordinator)
        enricher.forgetQueuePage(for: group.coordinatorID)
        enricher.cachedTrackByPosition[group.coordinatorID] = nil

        // The cached-metadata read above predates two long awaits — the
        // source may have changed meanwhile (e.g. user started a radio
        // stream from another controller). Re-read the live transport URI
        // just before the stop decision; fall back to the cached answer
        // if the read fails.
        var playingFromQueueNow = wasPlayingFromQueue
        if let mediaInfo = try? await avTransport.getMediaInfo(device: coordinator),
           let currentURI = mediaInfo["CurrentURI"] {
            playingFromQueueNow = currentURI.hasPrefix(URIPrefix.rinconQueue)
        }

        if playingFromQueueNow {
            try? await avTransport.stop(device: coordinator)
            groupTrackMetadata[coordinator.id] = TrackMetadata()
            updateTransportState(coordinator.id, state: .stopped)
            groupPositions[coordinator.id] = 0
            clearAwaitingPlayback(coordinator: coordinator.id)
        }
    }

    // MARK: - Queue History (recoverable snapshots)

    /// Captures the current queue as a hidden Choragus-side saved queue
    /// (database row, never a speaker-side saved queue) and registers it in
    /// `queueHistory`, pruning anything past the retention depth. Call this
    /// immediately BEFORE a destructive mutation (replace-all / clear /
    /// bulk remove) so the prior state can be restored.
    ///
    /// Best-effort by contract: a failure here must never block the
    /// destructive op the user actually asked for, so it swallows errors
    /// (logged) rather than throwing. No-op on an empty queue — there's
    /// nothing to recover.
    /// One-shot per launch. Snapshots live locally; any `__cghist__*` saved
    /// queue still on a speaker is destroyed on EVERY detected system — they
    /// show up as playlists in other controllers (the official app doesn't
    /// know the prefix). Also garbage-collects local snapshot rows the
    /// history index no longer tracks (index cleared, crash between delete
    /// and persist).
    private var purgedLegacySnapshots = false
    func purgeLegacySpeakerSnapshots() async {
        guard !purgedLegacySnapshots else { return }
        purgedLegacySnapshots = true
        var failed = false
        for (_, g) in topology.coordinatorPerHousehold() {
            guard let coord = g.coordinator else { continue }
            // Enumerate fully BEFORE destroying — DestroyObject reindexes the
            // container, so paging while destroying skips entries.
            var legacyIDs: [String] = []
            var start = 0
            while true {
                guard let (page, total) = try? await contentDirectory.browse(
                    device: coord, objectID: BrowseID.playlists, start: start, count: PageSize.browse)
                else {
                    failed = true
                    break
                }
                legacyIDs.append(contentsOf:
                    page.filter { QueueHistoryStore.isHistoryTitle($0.title) }.map(\.objectID))
                start += page.count
                if page.isEmpty || start >= total { break }
            }
            for objectID in legacyIDs {
                do {
                    try await contentDirectory.destroyObject(device: coord, objectID: objectID)
                    sonosDiagLog(.info, tag: "QUEUE",
                                 "Destroyed legacy queue-history snapshot \(objectID)")
                } catch {
                    failed = true
                }
            }
        }
        let known = queueHistory.allTrackedLocalIDs()
        for rowID in savedQueueRepo.snapshotRowIDs() where !known.contains(rowID) {
            savedQueueRepo.purge(id: rowID)
        }
        if failed { purgedLegacySnapshots = false }   // retry on the next trigger
    }

    public func snapshotQueueForHistory(group: SonosGroup) async {
        guard let coordinator = group.coordinator else { return }
        await purgeLegacySpeakerSnapshots()
        do {
            let collected = try await queue.readFullQueue(device: coordinator)
            guard !collected.isEmpty else { return }
            let now = Date()
            guard let localID = savedQueueRepo.save(name: QueueHistoryStore.snapshotTitle(at: now),
                                                    tracks: collected, snapshot: true) else { return }
            let firstTitle = collected.first?.title ?? ""
            let summary = firstTitle.isEmpty
                ? "\(collected.count) tracks"
                : "\(collected.count) tracks · \(firstTitle)"
            let snapshot = QueueSnapshot(localID: localID, savedAt: now,
                                         trackCount: collected.count, summary: summary)
            let overflow = queueHistory.register(snapshot, for: group.coordinatorID)
            for staleID in overflow {
                savedQueueRepo.purge(id: staleID)
            }
        } catch {
            sonosDiagLog(.warning, tag: "QUEUE",
                         "snapshotQueueForHistory failed: \(error.localizedDescription)")
        }
    }

    /// Snapshots available to restore for a group, newest first.
    public func queueSnapshots(group: SonosGroup) -> [QueueSnapshot] {
        queueHistory.snapshots(for: group.coordinatorID)
    }

    /// Best-effort display room name for a coordinator ID. Handles the
    /// coordinator having since been regrouped as a non-coordinator member.
    public func roomName(forCoordinator coordinatorID: String) -> String {
        if let g = groups.first(where: { $0.coordinatorID == coordinatorID }) { return g.name }
        for g in groups {
            if let m = g.members.first(where: { $0.id == coordinatorID }) { return m.roomName }
        }
        return coordinatorID
    }

    /// All queue-history snapshots across every room, each tagged with its
    /// resolved room name. Used by the Queue Library History view.
    public func allQueueSnapshots() -> [(coordinatorID: String, room: String, snapshots: [QueueSnapshot])] {
        queueHistory.snapshotsByCoordinator
            .filter { !$0.value.isEmpty }
            .map { (coordinatorID: $0.key, room: roomName(forCoordinator: $0.key), snapshots: $0.value) }
            .sorted { $0.room.localizedCaseInsensitiveCompare($1.room) == .orderedAscending }
    }

    /// Restores a previously-snapshotted queue from its stored rows. The
    /// current queue is itself snapshotted first, so a restore is undoable.
    /// The snapshot row is left intact (it stays in the history list) so the
    /// same restore point can be reused.
    public func restoreQueueSnapshot(group: SonosGroup, localID: Int64) async throws {
        // Touch the restore target to the head of the ring BEFORE the
        // replace path takes its pre-restore snapshot. With the ring at
        // depth, restoring the oldest entry would otherwise evict — and
        // delete — the very rows being restored.
        if let target = queueHistory.snapshots(for: group.coordinatorID)
            .first(where: { $0.localID == localID }) {
            _ = queueHistory.register(target, for: group.coordinatorID)
        }
        // loadLocalSavedQueue rebuilds BrowseItems with their preserved DIDL
        // and routes them through the normal replace path, whose per-track
        // resolution Apple Music / SMAPI rows need (UPnP 800 otherwise).
        // The replace path snapshots the current queue first, so the restore
        // is itself undoable.
        try await loadLocalSavedQueue(id: localID, group: group, append: false)
    }

    // MARK: - Choragus-side saved queues


    /// Saves an arbitrary track list as a Choragus playlist and notifies
    /// open UI. The Playlist Builder's save path — writing through
    /// `savedQueueRepo` directly skips the notification and leaves an
    /// open Queue Library stale.
    @discardableResult
    public func saveChoragusPlaylist(name: String, tracks: [QueueItem]) -> Int64? {
        let id = savedQueueRepo.save(name: name, tracks: tracks)
        if id != nil { notifyChoragusQueuesChanged() }
        return id
    }

    /// Appends an arbitrary track list to an existing Choragus playlist and
    /// notifies open UI. Returns the count appended.
    @discardableResult
    public func appendToChoragusPlaylist(queueID: Int64, tracks: [QueueItem]) -> Int {
        guard !tracks.isEmpty else { return 0 }
        let n = savedQueueRepo.appendTracks(queueID: queueID, tracks: tracks)
        if n > 0 { notifyChoragusQueuesChanged() }
        return n
    }

    /// The live-queue rows at `positions` (1-based), read WITH per-track
    /// DIDL so Apple Music / SMAPI rows re-enqueue later without faulting.
    /// The panel's own rows are fetched without metadata, so a copy has to
    /// re-read rather than reuse them.
    public func liveQueueTracks(group: SonosGroup, positions: Set<Int>) async throws -> [QueueItem] {
        guard let coordinator = group.coordinator, !positions.isEmpty else { return [] }
        return try await queue.readFullQueue(device: coordinator).filter { positions.contains($0.id) }
    }

    /// Reads the live queue and stores it locally under `name`. Returns the
    /// count saved.
    public func saveQueueToChoragus(group: SonosGroup, name: String) async throws -> Int {
        guard let coordinator = group.coordinator else { return 0 }
        let collected = try await queue.readFullQueue(device: coordinator)
        guard !collected.isEmpty else { return 0 }
        _ = savedQueueRepo.save(name: name, tracks: collected)
        notifyChoragusQueuesChanged()
        return collected.count
    }

    public func localSavedQueues() -> [LocalSavedQueue] {
        savedQueueRepo.list()
    }

    public func savedQueueTracks(localID: Int64) -> [QueueItem] {
        queue.fillingDurations(savedQueueRepo.tracks(for: localID))
    }

    private func notifyChoragusQueuesChanged() {
        NotificationCenter.default.post(name: .choragusSavedQueuesChanged, object: nil)
    }

    /// Expands a browse item into queue tracks: a container (album / playlist)
    /// is paged into its tracks; a single track maps to one. Carries each
    /// row's DIDL so Apple Music / SMAPI tracks re-enqueue without faulting.
    public func choragusQueueTracks(from item: BrowseItem) async -> [QueueItem] {
        var items: [BrowseItem] = []
        if item.isContainer {
            var idx = 0
            while true {
                guard let (page, total) = try? await browse(objectID: item.objectID, start: idx, count: 500) else { break }
                items.append(contentsOf: page)
                if page.isEmpty || items.count >= total || idx >= 40_000 { break }
                idx += page.count
            }
        } else {
            items = [item]
        }
        return items.enumerated().compactMap { offset, it in
            guard let uri = it.resourceURI, !uri.isEmpty else { return nil }
            return QueueItem(id: offset + 1, title: it.title, artist: it.artist, album: it.album,
                             albumArtURI: it.albumArtURI, duration: "", uri: uri, metadata: it.resourceMetadata)
        }
    }

    /// Appends a browse item (album/track) to an existing Choragus-local queue.
    @discardableResult
    public func addToChoragusQueue(item: BrowseItem, queueID: Int64) async -> Int {
        let tracks = await choragusQueueTracks(from: item)
        guard !tracks.isEmpty else { return 0 }
        let n = savedQueueRepo.appendTracks(queueID: queueID, tracks: tracks)
        notifyChoragusQueuesChanged()
        return n
    }

    /// Creates a new Choragus-local queue seeded from a browse item.
    @discardableResult
    public func createChoragusQueue(item: BrowseItem, name: String) async -> Int64? {
        let tracks = await choragusQueueTracks(from: item)
        guard !tracks.isEmpty else { return nil }
        let id = savedQueueRepo.save(name: name, tracks: tracks)
        notifyChoragusQueuesChanged()
        return id
    }

    /// Converts already-expanded browse items (e.g. Apple Music tracks the
    /// caller resolved) into queue tracks.
    private func choragusQueueTracks(fromItems items: [BrowseItem]) -> [QueueItem] {
        items.enumerated().compactMap { offset, it in
            guard let uri = it.resourceURI, !uri.isEmpty else { return nil }
            return QueueItem(id: offset + 1, title: it.title, artist: it.artist, album: it.album,
                             albumArtURI: it.albumArtURI, duration: "", uri: uri, metadata: it.resourceMetadata)
        }
    }

    @discardableResult
    public func addToChoragusQueue(items: [BrowseItem], queueID: Int64) -> Int {
        let tracks = choragusQueueTracks(fromItems: items)
        guard !tracks.isEmpty else { return 0 }
        let n = savedQueueRepo.appendTracks(queueID: queueID, tracks: tracks)
        notifyChoragusQueuesChanged()
        return n
    }

    @discardableResult
    public func createChoragusQueue(items: [BrowseItem], name: String) -> Int64? {
        let tracks = choragusQueueTracks(fromItems: items)
        guard !tracks.isEmpty else { return nil }
        let id = savedQueueRepo.save(name: name, tracks: tracks)
        notifyChoragusQueuesChanged()
        return id
    }

    /// Loads a Choragus-side saved queue onto the speaker. `append: false`
    /// replaces the queue (history snapshot taken by the replace path) and
    /// starts playback; `append: true` adds to the end. Rows are rebuilt as
    /// `BrowseItem`s so the normal enqueue machinery handles service DIDL
    /// reconstruction, track-info caching, and Apple Music row repair.
    public func loadLocalSavedQueue(id: Int64, group: SonosGroup, append: Bool) async throws {
        let tracks = savedQueueRepo.tracks(for: id)
        let items = tracks.compactMap { $0.browseItem(id: "LOCALQ:\(id)/\($0.id)") }
            .map(Self.describingRowsSavedWithoutMetadata)
        guard !items.isEmpty else { return }
        let playable = await reresolvingStalePlayURLs(items)
        if append {
            _ = try await addBrowseItemsToQueue(playable, in: group, playNext: false)
        } else {
            try await playItemsReplacingQueue(playable, in: group)
        }
    }

    /// Rebuilds the DIDL envelope for a saved row the speaker described
    /// without one.
    ///
    /// A queue read preserves `<r:resMD>` when the speaker sends it, and
    /// for many rows it does not. Re-enqueueing such a row as a bare URI
    /// plays the track, but the speaker resolves no metadata for it: the
    /// queue row it writes carries no `dc:title`, `dc:creator` or
    /// `upnp:album`, so the panel, the next snapshot, and every restore
    /// of that snapshot show nothing — the loss compounds each round.
    ///
    /// A service track needs the envelope shape the service expects, not
    /// a generic one built from the row's fields: an envelope carrying
    /// `<res>` and display text is discarded whole (verified on Spotify —
    /// the speaker rewrote the row back to a bare item). The play-history
    /// replay path already reconstructs the right one from the URI, so it
    /// is the single builder for both.
    static func describingRowsSavedWithoutMetadata(_ item: BrowseItem) -> BrowseItem {
        guard (item.resourceMetadata ?? "").isEmpty,
              !item.title.isEmpty,
              let uri = item.resourceURI, !uri.isEmpty else { return item }
        var described = item
        described.resourceMetadata = ServiceSearchProvider.shared.buildHistoryReplayDIDL(
            uri: uri, title: item.title, artist: item.artist,
            album: item.album, albumArtURI: item.albumArtURI)
        return described
    }

    /// Replaces expired pre-signed play URLs with freshly resolved ones before
    /// a saved queue is enqueued.
    ///
    /// A saved queue stores the URL the track played from. For a service the
    /// controller authenticates against (TIDAL, Qobuz, Suno) that URL is
    /// signed and short-lived; an expired one plays silence, advances, and
    /// reports no fault. Only signed URLs with a known service origin are
    /// touched. Resolution is sequential and capped, because each entry is a
    /// network round-trip to the service.
    private func reresolvingStalePlayURLs(_ items: [BrowseItem]) async -> [BrowseItem] {
        guard let resolver = smapiURIResolver else { return items }
        var refreshed = items
        var resolved = 0
        var failed = 0
        for (index, item) in items.enumerated() {
            guard resolved + failed < Self.maxRestoreReresolutions else { break }
            guard let uri = item.resourceURI,
                  StaleTrackURL.carriesRotatingCredential(uri) else { continue }
            // An unexpired URL still plays; spend the round-trip only on the
            // ones that have expired or that state no expiry to check.
            if let expiry = StaleTrackURL.expiry(in: uri), expiry.timeIntervalSinceNow > 60 { continue }
            guard let origin = ResolvedPlaybackRegistry.origin(ofPlayURL: uri) else { continue }
            guard let fresh = try? await resolver(origin.sid, origin.itemID),
                  StaleTrackURL.isDirectStream(fresh) else {
                failed += 1
                continue
            }
            if fresh != uri {
                refreshed[index].resourceURI = fresh
                ResolvedPlaybackRegistry.remember(playURL: fresh, sid: origin.sid,
                                                  itemID: origin.itemID)
            }
            resolved += 1
        }
        if resolved > 0 || failed > 0 {
            sonosDiagLog(.info, tag: "QUEUELIB", "Re-resolved saved-queue play URLs",
                         context: ["resolved": String(resolved), "failed": String(failed),
                                   "tracks": String(items.count)])
        }
        return refreshed
    }

    /// Ceiling on per-restore re-resolutions. Each is a service round-trip, so
    /// a thousand-track queue would otherwise stall the restore; the tracks
    /// beyond it are repaired by the playback-failure path instead.
    private static let maxRestoreReresolutions = 200

    /// Up to `limit` DISTINCT-ALBUM art URLs for a mosaic cover. Dedupes by
    /// album identity (album+artist, falling back to the art URL) so a queue
    /// of tracks from one album contributes a single tile rather than four
    /// repeats. The image bytes themselves are memory/disk cached by the
    /// view layer (`CachedAsyncImage` → `ImageCache`), fetched on miss.
    private static func distinctAlbumArt(_ rows: [(album: String, artist: String, art: String?)],
                                         limit: Int) -> [String] {
        var seenAlbum = Set<String>()
        var seenArt = Set<String>()
        var out: [String] = []
        for row in rows {
            guard let art = row.art, !art.isEmpty else { continue }
            // Dedupe by album NAME alone, not album+artist: a various-artists
            // compilation shares one cover across many artists, and four tiles
            // of the same album art read as a bug. Fall back to the art URL
            // only when the album is untagged.
            let key = row.album.isEmpty ? art : row.album.lowercased()
            guard seenArt.insert(art).inserted, seenAlbum.insert(key).inserted else { continue }
            out.append(art)
            if out.count >= limit { break }
        }
        return out
    }

    public func choragusCoverArt(localID: Int64, limit: Int = 4) -> [String] {
        enricher.loadLocalAlbumArtIfNeeded()
        // First 24 rows are enough to find `limit` distinct albums in
        // any real queue; a full read scales with queue length on the
        // main thread for 4 covers.
        let rows = savedQueueRepo.tracks(for: localID, limit: 24).map { t -> (album: String, artist: String, art: String?) in
            var art = t.albumArtURI
            // Substitute the persisted iTunes art for local rows whose stored
            // getaa URL won't render — no web call, just a dict hit.
            if TrackMetadataEnricher.isUnreliableLocalArt(uri: t.uri, art: art) {
                art = enricher.localAlbumArt[TrackMetadataEnricher.localAlbumKey(artist: t.artist, album: t.album)]
            }
            return (t.album, t.artist, art)
        }
        return Self.distinctAlbumArt(rows, limit: limit)
    }

    /// Up to `limit` distinct-album art URLs for a Sonos saved queue (`SQ:`),
    /// browsed lazily. Local-library rows resolve through iTunes (their getaa
    /// art 404s). Used for the Queue Library mosaic cover.
    public func savedQueueCoverArt(objectID: String, limit: Int = 4) async -> [String] {
        guard let (items, _) = try? await browse(objectID: objectID, start: 0, count: 60) else { return [] }
        var rows: [(album: String, artist: String, art: String?)] = []
        for item in items {
            var art = item.albumArtURI
            if TrackMetadataEnricher.isUnreliableLocalArt(uri: item.resourceURI, art: art) {
                art = await enricher.resolveLocalAlbumArt(artist: item.artist, album: item.album)
            }
            rows.append((item.album, item.artist, art))
            if Self.distinctAlbumArt(rows, limit: limit).count >= limit { break }
        }
        return Self.distinctAlbumArt(rows, limit: limit)
    }

    // MARK: - Saved-queue folders

    public func savedQueueFolders() -> [SavedQueueFolder] { savedQueueRepo.listFolders() }
    /// Folders and queues nested for menus; one read of each list.
    public func savedQueueTree() -> SavedQueueTree {
        SavedQueueTree(folders: savedQueueRepo.listFolders(), queues: savedQueueRepo.list())
    }
    @discardableResult
    public func createSavedQueueFolder(name: String, parent: Int64? = nil) -> Int64? { let id = savedQueueRepo.createFolder(name: name, parentID: parent); notifyChoragusQueuesChanged(); return id }
    public func renameSavedQueueFolder(id: Int64, to newName: String) { savedQueueRepo.renameFolder(id: id, to: newName); notifyChoragusQueuesChanged() }
    public func deleteSavedQueueFolder(id: Int64) { savedQueueRepo.deleteFolder(id: id); notifyChoragusQueuesChanged() }
    public func moveSavedQueue(id: Int64, toFolder folderID: Int64?) { savedQueueRepo.moveQueue(id: id, toFolder: folderID); notifyChoragusQueuesChanged() }
    /// Duplicates a queue into a folder (drag with Option held).
    @discardableResult
    public func copySavedQueue(id: Int64, toFolder folderID: Int64?) -> Int64? { let newID = savedQueueRepo.copyQueue(id: id, toFolder: folderID); notifyChoragusQueuesChanged(); return newID }
    /// Adds a queue to a folder without removing it from others (many-to-many).
    public func addSavedQueueToFolder(id: Int64, folderID: Int64) { savedQueueRepo.addToFolder(queueID: id, folderID: folderID); notifyChoragusQueuesChanged() }
    public func removeSavedQueueFromFolder(id: Int64, folderID: Int64) { savedQueueRepo.removeFromFolder(queueID: id, folderID: folderID); notifyChoragusQueuesChanged() }
    public func setSavedQueueFolders(id: Int64, folderIDs: [Int64]) { savedQueueRepo.setFolders(queueID: id, folderIDs: folderIDs); notifyChoragusQueuesChanged() }
    /// Re-parents a folder for sub-folder nesting (nil = top level).
    public func moveSavedQueueFolder(id: Int64, under parent: Int64?) { savedQueueRepo.moveFolder(id: id, parentID: parent); notifyChoragusQueuesChanged() }
    /// Deep-duplicates a folder (its queues and sub-folders).
    @discardableResult
    public func copySavedQueueFolder(id: Int64) -> Int64? { let newID = savedQueueRepo.copyFolder(id: id); notifyChoragusQueuesChanged(); return newID }

    // MARK: - Smart queues (play-history rules)

    public enum SmartQueueKind: String, CaseIterable {
        case mostPlayed       // last 30 days, ranked by play count
        case recentlyPlayed   // most recent distinct tracks
        case starred          // favourited tracks

        public var title: String {
            switch self {
            case .mostPlayed:     return L10n.smartQueueMostPlayed
            case .recentlyPlayed: return L10n.recentlyPlayed
            case .starred:        return L10n.statStarred
            }
        }
        public var icon: String {
            switch self {
            case .mostPlayed:     return "flame.fill"
            case .recentlyPlayed: return "clock.fill"
            case .starred:        return "star.fill"
            }
        }
    }

    /// Token-membership room match, matching `PlayHistoryView`: an entry's
    /// grouping ("Office + Float") matches the selected room ("Office") when
    /// every token of the selection is a member of the entry's grouping.
    /// nil room matches everything.
    private static func entryMatchesRoom(_ entry: PlayHistoryEntry, _ room: String?) -> Bool {
        SmartQueueRules.entryMatchesRoom(groupName: entry.groupName, room: room)
    }

    /// Rooms available for the smart-queue filter, mirroring history.
    public func smartQueueRoomOptions() -> [String] {
        playHistoryManager?.roomFilterOptions ?? []
    }

    /// Builds a smart queue's tracks from play history. Caveat: history rows
    /// carry the playable URI but no DIDL, so Apple Music / SMAPI tracks may
    /// fault UPnP 800 on re-enqueue — local-library and radio replay cleanly.
    /// Capped at `limit` distinct (title+artist) tracks. `room` scopes the
    /// source entries by token-membership match (nil = all rooms).
    public func smartQueueTracks(kind: SmartQueueKind, room: String? = nil, limit: Int = 100) -> [QueueItem] {
        guard let history = playHistoryManager else { return [] }
        let entries = history.entries.filter { Self.entryMatchesRoom($0, room) }
        // De-duplication, room scoping and the Most Played window live in
        // SmartQueueRules so they can be tested against a fixed history.
        func distinct(_ source: [PlayHistoryEntry]) -> [QueueItem] {
            SmartQueueRules.distinct(source, limit: limit,
                                     uri: \.sourceURI, title: \.title, artist: \.artist)
                .enumerated()
                .map { index, e in
                    QueueItem(id: index + 1, title: e.title, artist: e.artist,
                              album: e.album, albumArtURI: e.albumArtURI,
                              duration: "", uri: e.sourceURI, metadata: nil)
                }
        }
        switch kind {
        case .starred:
            return distinct(entries.filter(\.starred).reversed())
        case .recentlyPlayed:
            return distinct(entries.reversed())
        case .mostPlayed:
            return distinct(SmartQueueRules.rankByPlayCount(
                entries, timestamp: \.timestamp, title: \.title, artist: \.artist))
        }
    }

    public func smartQueueCoverArt(kind: SmartQueueKind, room: String? = nil, limit: Int = 4) -> [String] {
        Self.smartQueueCoverArt(from: smartQueueTracks(kind: kind, room: room, limit: 60), limit: limit)
    }

    /// Mosaic covers for a smart queue whose tracks are already in hand, so a
    /// caller that has just built the track list does not rank the history a
    /// second time for four cover URLs.
    public static func smartQueueCoverArt(from tracks: [QueueItem], limit: Int = 4) -> [String] {
        distinctAlbumArt(tracks.map { ($0.album, $0.artist, $0.albumArtURI) }, limit: limit)
    }

    /// Plays a smart queue's tracks to a room (replace or append).
    public func playSmartQueue(kind: SmartQueueKind, room: String? = nil, group: SonosGroup, append: Bool) async throws {
        let tracks = smartQueueTracks(kind: kind, room: room)
        let items = tracks.compactMap { $0.browseItem(id: "SMART:\(kind.rawValue)/\($0.id)") }
        guard !items.isEmpty else { return }
        if append {
            _ = try await addBrowseItemsToQueue(items, in: group, playNext: false)
        } else {
            try await playItemsReplacingQueue(items, in: group)
        }
    }

    /// Saves a smart queue as a Choragus-local queue (snapshot in time).
    @discardableResult
    public func freezeSmartQueueToChoragus(kind: SmartQueueKind, room: String? = nil, name: String) -> Int {
        let tracks = smartQueueTracks(kind: kind, room: room)
        guard !tracks.isEmpty else { return 0 }
        _ = savedQueueRepo.save(name: name, tracks: tracks)
        notifyChoragusQueuesChanged()
        return tracks.count
    }

    // MARK: - Export

    /// Serialises a track list to an extended-M3U or CSV string for export.
    public static func exportTracks(_ tracks: [QueueItem], asCSV: Bool) -> String {
        if asCSV {
            var lines = ["Title,Artist,Album,URI"]
            for t in tracks {
                func q(_ s: String) -> String { "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\"" }
                lines.append([q(t.title), q(t.artist), q(t.album), q(t.uri ?? "")].joined(separator: ","))
            }
            return lines.joined(separator: "\n")
        }
        var lines = ["#EXTM3U"]
        for t in tracks {
            lines.append("#EXTINF:-1,\(t.artist) - \(t.title)")
            lines.append(t.uri ?? "")
        }
        return lines.joined(separator: "\n")
    }

    /// Copies a Sonos saved queue (`SQ:`) into the Choragus-local store,
    /// preserving each track's DIDL so it re-enqueues without faulting.
    /// Returns the track count saved.
    @discardableResult
    public func cloneSonosPlaylistToChoragus(objectID: String, name: String) async throws -> Int {
        var items: [BrowseItem] = []
        var index = 0
        while true {
            let (page, total) = try await browse(objectID: objectID, start: index, count: 500)
            items.append(contentsOf: page)
            if page.isEmpty || items.count >= total || index >= 40_000 { break }
            index += page.count
        }
        let tracks = items.enumerated().compactMap { offset, item -> QueueItem? in
            guard let uri = item.resourceURI, !uri.isEmpty else { return nil }
            return QueueItem(id: offset + 1, title: item.title, artist: item.artist,
                             album: item.album, albumArtURI: item.albumArtURI,
                             duration: "", uri: uri, metadata: item.resourceMetadata)
        }
        guard !tracks.isEmpty else { return 0 }
        _ = savedQueueRepo.save(name: name, tracks: tracks)
        return tracks.count
    }

    /// Duplicates an existing Choragus-local saved queue under a new name.
    @discardableResult
    public func cloneLocalSavedQueue(id: Int64, name: String) -> Int {
        let tracks = savedQueueRepo.tracks(for: id)
        guard !tracks.isEmpty else { return 0 }
        _ = savedQueueRepo.save(name: name, tracks: tracks)
        notifyChoragusQueuesChanged()
        return tracks.count
    }

    /// Loads a Sonos saved queue (`SQ:`) to a room. Pages the container to
    /// individual tracks first (carrying each track's DIDL) so Apple Music /
    /// SMAPI rows don't fault UPnP 800 — the same reason history restore
    /// pages rather than enqueuing the `.rsq` container directly.
    public func playSavedQueueToRoom(objectID: String, group: SonosGroup, append: Bool) async throws {
        var items: [BrowseItem] = []
        var index = 0
        while true {
            let (page, total) = try await browse(objectID: objectID, start: index, count: 500)
            items.append(contentsOf: page)
            if page.isEmpty || items.count >= total || index >= 40_000 { break }
            index += page.count
        }
        let playable = items.filter { !($0.resourceURI ?? "").isEmpty }
        guard !playable.isEmpty else { return }
        if append {
            _ = try await addBrowseItemsToQueue(playable, in: group, playNext: false)
        } else {
            try await playItemsReplacingQueue(playable, in: group)
        }
    }

    /// Persists an edited/reordered track list for a Choragus-local queue.
    public func replaceChoragusQueueTracks(id: Int64, tracks: [QueueItem]) {
        savedQueueRepo.replaceTracks(queueID: id, tracks: tracks)
        notifyChoragusQueuesChanged()
    }

    /// Appends tracks to an existing Choragus-local queue (drag-to-copy in the
    /// Queue Library). Returns the number appended.
    @discardableResult
    public func appendTracksToChoragusQueue(id: Int64, tracks: [QueueItem]) -> Int {
        let n = savedQueueRepo.appendTracks(queueID: id, tracks: tracks)
        notifyChoragusQueuesChanged()
        return n
    }

    public func renameLocalSavedQueue(id: Int64, to newName: String) {
        savedQueueRepo.rename(id: id, to: newName)
        notifyChoragusQueuesChanged()
    }

    /// Moves a playlist to Deleted Items; `restoreDeletedSavedQueue`
    /// brings it back until the retention window ends.
    public func deleteLocalSavedQueue(id: Int64) {
        savedQueueRepo.softDelete(id: id)
        notifyChoragusQueuesChanged()
    }

    // MARK: - Deleted Items

    /// Playlists in Deleted Items, expiring any past the retention window first.
    public func deletedSavedQueues() -> [LocalSavedQueue] {
        savedQueueRepo.purgeDeleted(before: Self.deletedSavedQueueCutoff())
        return savedQueueRepo.listDeleted()
    }

    public func restoreDeletedSavedQueue(id: Int64) {
        savedQueueRepo.restore(id: id)
        notifyChoragusQueuesChanged()
    }

    public func permanentlyDeleteSavedQueue(id: Int64) {
        savedQueueRepo.purge(id: id)
        notifyChoragusQueuesChanged()
    }

    public func emptyDeletedSavedQueues() {
        savedQueueRepo.purgeAllDeleted()
        notifyChoragusQueuesChanged()
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

        // Snapshot the queue about to be wiped so an accidental "play
        // this now" is recoverable from the queue history.
        await snapshotQueueForHistory(group: group)

        // Cache every track's title + art by URI up front so the queue panel
        // can recover them for ALL rows (the speaker returns a filename / no
        // art for direct-URL tracks like Suno), not just the first.
        for it in playable where !it.title.isEmpty {
            guard let u = it.resourceURI, !u.isEmpty else { continue }
            let c = TrackMetadataEnricher.CachedTrack(title: it.title, artist: it.artist, album: it.album, artURL: it.albumArtURI)
            enricher.cachedTrackInfo[u] = c
            if let d = u.removingPercentEncoding, d != u { enricher.cachedTrackInfo[d] = c }
        }

        // Stop playback first. `RemoveAllTracksFromQueue` on a Sonos
        // coordinator that's actively playing leaves the currently-
        // playing track in the queue (Sonos-side behaviour) — without
        // the stop, "Play All" on a playlist appended its tracks
        // *after* whatever was already playing, producing a 51-track
        // queue from a 50-track playlist with the prior track stuck at
        // position 1. Stopping first lets the clear actually empty the
        // queue before the rebuild.
        try? await avTransport.stop(device: coordinator)
        try await contentDirectory.removeAllTracksFromQueue(device: coordinator)
        enricher.forgetQueuePage(for: group.coordinatorID)
        enricher.cachedTrackByPosition[group.coordinatorID] = nil

        // 1. First track + immediate playback.
        if let uri = first.resourceURI, !uri.isEmpty {
            // Preload cached track info so any speaker poll that arrives
            // before the background fill writes art/title can recover it.
            let cached = TrackMetadataEnricher.CachedTrack(title: first.title,
                                     artist: first.artist,
                                     album: first.album,
                                     artURL: first.albumArtURI)
            if !first.title.isEmpty {
                enricher.cachedTrackInfo[uri] = cached
                if let decoded = uri.removingPercentEncoding, decoded != uri {
                    enricher.cachedTrackInfo[decoded] = cached
                }
            }

            var meta = first.resourceMetadata ?? ""
            meta = DIDLNormalize.metadata(meta)
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
            pendingMeta.artist = first.artist
            pendingMeta.album = first.album
            pendingMeta.albumArtURI = first.albumArtURI
            pendingMeta.trackURI = uri
            groupTrackMetadata[coordinator.id] = pendingMeta
            // Optimistic .playing — UI stays stuck on .transitioning
            // when the AVT SUBSCRIBE callback URL is stale (network
            // path change). Real AVT event resolves to same value.
            confirmPlaying(coordinator: coordinator.id)
            setTransportGrace(groupID: coordinator.id, duration: Timing.playbackGracePeriod)
        }

        // First-track refresh: Browse(Q:0) now so the queue panel shows
        // the enqueued row while the background fill runs its first chunk,
        // rather than sitting empty for those seconds.
        enricher.postQueueChanged(optimisticItems: [])

        // 2. Remaining tracks in background — cancelling any fill still
        // running for this coordinator from a previous replace, so two
        // consecutive Play All actions can't interleave their chunks.
        let rest = Array(playable.dropFirst())
        if !rest.isEmpty {
            queue.queueFillTasks[coordinator.id]?.cancel()
            // The fill issues the same chunked adds a batch add does, so
            // it holds the same per-coordinator exclusivity — otherwise
            // a library batch add started mid-fill interleaves chunks.
            // A superseded fill must not clear the flag the newer fill
            // holds: only the fill still registered releases it.
            let generation = (queueFillGeneration[coordinator.id] ?? 0) + 1
            queueFillGeneration[coordinator.id] = generation
            batchAddInFlightCoordinators.insert(coordinator.id)
            queue.queueFillTasks[coordinator.id] = Task { [weak self] in
                await self?.queue.fillQueueInBackground(rest, in: group)
                guard let self, self.queueFillGeneration[coordinator.id] == generation else { return }
                self.batchAddInFlightCoordinators.remove(coordinator.id)
            }
        }
    }


    public func playTrackFromQueue(group: SonosGroup, trackNumber: Int) async throws {
        guard let coordinator = group.coordinator else { return }

        // Fully clear existing metadata — the source is changing
        groupTrackMetadata[coordinator.id] = TrackMetadata()

        // Ensure transport is pointing at the queue (not a radio stream etc.)
        try await avTransport.setAVTransportURI(
            device: coordinator, uri: "x-rincon-queue:\(coordinator.id)#0"
        )
        try await contentDirectory.seekToTrack(device: coordinator, trackNumber: trackNumber)
        try await avTransport.play(device: coordinator)

        // Immediately fetch the new track's metadata — set directly (skip merge logic)
        updateTransportState(coordinator.id, state: .playing)
        setTransportGrace(groupID: coordinator.id, duration: Timing.defaultGracePeriod)
        let position = try await avTransport.getPositionInfo(device: coordinator)
        groupTrackMetadata[coordinator.id] = position
    }


    // MARK: - Playlist Management

    /// Saves the current queue as a new Sonos playlist using SaveQueue
    public func saveQueueAsPlaylist(group: SonosGroup, title: String) async throws -> String {
        guard let coordinator = group.coordinator else { return "" }
        return try await contentDirectory.saveQueue(device: coordinator, title: title)
    }

    /// Adds a browse item to an existing Sonos playlist
    public func addToPlaylist(playlistID: String, item: BrowseItem) async throws {
        guard let device = topology.preferredDevice else { return }
        guard let uri = item.resourceURI, !uri.isEmpty else { return }
        var meta = item.resourceMetadata ?? ""
        meta = DIDLNormalize.metadata(meta)
        _ = try await contentDirectory.addURIToSavedQueue(device: device, objectID: playlistID, uri: uri, metadata: meta)
    }

    /// Deletes a Sonos playlist
    public func deletePlaylist(playlistID: String) async throws {
        guard let device = topology.preferredDevice else { return }
        try await contentDirectory.destroyObject(device: device, objectID: playlistID)
    }

    /// Renames a Sonos playlist
    public func renamePlaylist(playlistID: String, oldTitle: String, newTitle: String) async throws {
        guard let device = topology.preferredDevice else { return }
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
        setTransportGrace(groupID: coordinator.id, duration: Timing.playbackGracePeriod)

        try await avTransport.setAVTransportURI(device: coordinator, uri: uri, metadata: metadata)
        try await avTransport.play(device: coordinator)
        // Optimistic .playing — see playItemsReplacingQueue for why.
        // Written after play() so a transport error leaves the UI
        // accurate instead of claiming a play that never started.
        confirmPlaying(coordinator: coordinator.id)
    }

    /// Plays a speaker's physical input (analog line-in or TV) through
    /// `group`. Same path as the Browse "Line-In" list and the Select
    /// Input Shortcuts intent.
    public func playInput(_ input: PhysicalInput, in group: SonosGroup) async throws {
        try await playBrowseItem(input.browseItem, in: group)
    }

    // MARK: - Grouping

    /// Joins a device to an existing group by pointing its transport at the coordinator's rincon URI
    public func joinGroup(device: SonosDevice, toCoordinator coordinator: SonosDevice) async throws {
        let uri = "x-rincon:\(coordinator.id)"
        let priorVol = deviceVolumes[device.id].map(String.init) ?? "nil"
        let priorMute = deviceMutes[device.id].map(String.init) ?? "nil"
        sonosDebugLog("[JOIN-START] member=\(device.roomName) id=\(device.id) coord=\(coordinator.roomName) priorVolDict=\(priorVol) priorMuteDict=\(priorMute)")
        try await avTransport.setAVTransportURI(device: device, uri: uri)
        // User-initiated change — bypass the throttle so the sidebar reflects
        // the new grouping immediately.
        await refreshTopology(from: coordinator, force: true)
        let postVol = deviceVolumes[device.id].map(String.init) ?? "nil"
        let postMute = deviceMutes[device.id].map(String.init) ?? "nil"
        sonosDebugLog("[JOIN-DONE] member=\(device.roomName) postVolDict=\(postVol) postMuteDict=\(postMute) — watch for RC-EVENT vol/mute that follow")
    }

    public func ungroupDevice(_ device: SonosDevice) async throws {
        sonosDebugLog("[UNGROUP-START] member=\(device.roomName) id=\(device.id)")
        try await avTransport.becomeCoordinatorOfStandaloneGroup(device: device)
        await refreshTopology(from: device, force: true)
        sonosDebugLog("[UNGROUP-DONE] member=\(device.roomName)")
    }

    // MARK: - Alarms

    /// Cached alarm list — populated by refreshAlarms(), read by UI
    public var cachedAlarms: [SonosAlarm] = []

    /// The speaker that owns the household's alarm list. Any zone player
    /// answers ListAlarms, but a copy read from another player right
    /// after a create or delete is stale for a few seconds, which showed
    /// as alarms that would not delete or appeared late. The list's
    /// version string names the master; reads and writes go there.
    private func alarmMaster() async -> SonosDevice? {
        guard let seed = topology.preferredDevice else { return nil }
        guard let list = try? await alarmClock.listAlarmList(device: seed),
              let id = list.masterID, let master = devices[id] else { return seed }
        return master
    }

    /// Fetches the alarm list from its master speaker and caches it.
    public func refreshAlarms() async {
        var bestAlarms: [SonosAlarm] = []
        if let master = await alarmMaster() {
            do {
                bestAlarms = try await alarmClock.listAlarms(device: master)
                sonosDebugLog("[ALARM] refreshAlarms: \(master.roomName) (\(master.ip)) master, \(bestAlarms.count) alarms")
            } catch {
                sonosDebugLog("[ALARM] refreshAlarms: \(master.roomName) (\(master.ip)) failed - \(error)")
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
        guard let master = await alarmMaster() else { return 0 }
        return try await alarmClock.createAlarm(device: master, alarm: alarm)
    }

    public func updateAlarm(_ alarm: SonosAlarm) async throws {
        guard let master = await alarmMaster() else { return }
        try await alarmClock.updateAlarm(device: master, alarm: alarm)
    }

    public func deleteAlarm(_ alarm: SonosAlarm) async throws {
        guard let master = await alarmMaster() else { return }
        try await alarmClock.destroyAlarm(device: master, alarmID: alarm.id)
    }







    // MARK: Per-household availability — UI helpers








    // MARK: - Music library shares (#75)



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



    public func browseMetadata(objectID: String) async throws -> BrowseItem? {
        guard let anyDevice = topology.preferredDevice else { return nil }
        return try await contentDirectory.browseMetadata(device: anyDevice, objectID: objectID)
    }


    public func browse(objectID: String, householdID: String?, start: Int = 0, count: Int = PageSize.browse) async throws -> (items: [BrowseItem], total: Int) {
        // Media-server ids are namespaced `MS:<serverID>/<objectID>` so one
        // browse entry point serves both sources and the view layer does not
        // need to know which is which.
        if let (server, remoteID) = mediaServerTarget(for: objectID) {
            // The root gets the pruned view: top-level containers that answer
            // a probe empty (photo/video subtrees on audio-profile browses)
            // carry nothing a music controller can use. The whole root is
            // returned in one page — handing later pages to the plain browse
            // re-introduces the pruned entries at start=1.
            if remoteID == "0" {
                guard start == 0 else { return ([], 0) }
                let items = await MediaServerService.browseRoot(server: server)
                return (items.map { namespaced($0, server: server) }, items.count)
            }
            let items = try await MediaServerService.browse(server: server, objectID: remoteID,
                                                            start: start, count: count)
            return (items.map { namespaced($0, server: server) }, items.count)
        }
        guard let device = topology.coordinatorForHousehold(householdID) ?? topology.preferredDevice else { return ([], 0) }
        return try await contentDirectory.browse(device: device, objectID: objectID, start: start, count: count)
    }

    /// Splits `MS:<serverID>/<objectID>` into the server and its own id.
    private func mediaServerTarget(for objectID: String) -> (MediaServer, String)? {
        guard objectID.hasPrefix("MS:") else { return nil }
        let body = objectID.dropFirst(3)
        guard let slash = body.firstIndex(of: "/") else { return nil }
        let serverID = String(body[..<slash])
        guard let server = mediaServers.first(where: { $0.id == serverID }) else { return nil }
        return (server, String(body[body.index(after: slash)...]))
    }

    /// Re-namespaces a server's own object ids so descending stays on that
    /// server. Tracks keep their resource URI untouched — that URL is what the
    /// speaker fetches.
    private func namespaced(_ item: BrowseItem, server: MediaServer) -> BrowseItem {
        guard item.isContainer else { return item }
        var copy = BrowseItem(id: "MS:\(server.id)/\(item.objectID)",
                              title: item.title, artist: item.artist, album: item.album,
                              albumArtURI: item.albumArtURI, itemClass: item.itemClass,
                              resourceURI: item.resourceURI,
                              resourceMetadata: item.resourceMetadata)
        copy.playbackStrategy = item.playbackStrategy
        return copy
    }

    /// Adds a media server by address, for networks where SSDP does not reach
    /// or where the server ignores it. Returns nil when nothing answered.
    @discardableResult
    public func addMediaServer(address: String) async -> MediaServer? {
        guard let server = await MediaServerService.probe(address: address) else {
            sonosDiagLog(.warning, tag: "MEDIASERVER", "No media server at that address",
                         context: ["address": address])
            return nil
        }
        MediaServerService.Pinned.pin(id: server.id)
        if !mediaServers.contains(where: { $0.id == server.id }) {
            mediaServers.append(contentsOf: MediaServerService.CustomTitles.applying(to: [server]))
            await loadBrowseSections()
        }
        sonosDiagLog(.info, tag: "MEDIASERVER", "Media server added by address",
                     context: ["server": server.name, "address": address])
        Task { await verifyMediaServerReachability(id: server.id) }
        return server
    }

    /// Probes every speaker against the server without touching playback —
    /// see MediaServerReachability for the mechanism. The three network
    /// failures this surfaces are silent in every transport response.
    public func verifyMediaServerReachability(id: String) async {
        guard let server = mediaServers.first(where: { $0.id == id }) else { return }
        guard mediaServerCheckProgress[id] == nil else { return }
        // Visible group members only: bonded satellites (surrounds, subs,
        // right-channel pairs) share the room's name, never fetch content,
        // and their sat-link fails probes their primary passes, listing
        // one room three times.
        var seen = Set<String>()
        let speakers = groups.flatMap(\.members)
            .filter { seen.insert($0.id).inserted }
            .map { (id: $0.id, name: $0.roomName, ip: $0.ip) }
        guard !speakers.isEmpty else { return }
        mediaServerCheckProgress[id] = (0, speakers.count)
        let result = await MediaServerReachability.verify(
            server: server, devices: speakers,
            onProgress: { [weak self] done, total in
                Task { @MainActor in self?.mediaServerCheckProgress[id] = (done, total) }
            })
        let verdicts = result.verdicts
        mediaServerCheckProgress[id] = nil
        mediaServerReachability[id] = verdicts
        if let target = result.probedTarget { mediaServerProbeTarget[id] = target }
        let unreachable = verdicts.filter { $0.state == .unreachable }.map(\.roomName)
        sonosDiagLog(unreachable.isEmpty ? .info : .warning, tag: "MEDIASERVER",
                     "Reachability check finished",
                     context: ["server": server.name,
                               "speakers": String(verdicts.count),
                               "unreachable": unreachable.joined(separator: ", ")])
    }

    /// The media server serving this URL, matched on host and port.
    func mediaServerServing(_ uri: String) -> MediaServer? {
        guard uri.hasPrefix("http://") || uri.hasPrefix("https://"),
              let host = URL(string: uri)?.host else { return nil }
        // Content is usually served on a different port from the control
        // endpoint (Synology: control 50001, media 50002), so the host alone
        // is the match.
        if let direct = mediaServers.first(where: { $0.baseURL.host == host }) { return direct }
        // Content can be served from a host the control endpoint does not use.
        guard let id = MediaServerService.ContentHosts.serverID(servingHost: host) else { return nil }
        return mediaServers.first { $0.id == id }
    }

    /// Forgets a media server: drops it from the list and from the remembered
    /// set, so it does not reappear on the next launch. Discovery can still
    /// find it again; removing is not blocking.
    public func removeMediaServer(id: String) async {
        MediaServerService.Remembered.forget(id: id)
        MediaServerService.Pinned.unpin(id: id)
        MediaServerService.CustomTitles.forget(id: id)
        mediaServers.removeAll { $0.id == id }
        sonosDiagLog(.info, tag: "MEDIASERVER", "Media server removed", context: ["id": id])
        await loadBrowseSections()
    }

    /// Searches the network for media servers and publishes what answered.
    /// Safe to call repeatedly; a server that stops answering drops out.
    public func discoverMediaServers() async {
        guard !isDiscoveringMediaServers else { return }
        isDiscoveringMediaServers = true
        defer { isDiscoveringMediaServers = false }
        guard mediaServersEnabled else {
            if !mediaServers.isEmpty {
                mediaServers = []
                await loadBrowseSections()
            }
            return
        }
        var found = await MediaServerDiscovery().discover()
        if UserDefaults.standard.bool(forKey: UDKey.mediaServersManualOnly) {
            let pinned = MediaServerService.Pinned.ids()
            found = found.filter { pinned.contains($0.id) }
        }
        guard found.map(\.id) != mediaServers.map(\.id) else { return }
        mediaServers = MediaServerService.CustomTitles.applying(to: found)
        await loadBrowseSections()
    }

    /// Gives a media server the name the user wants to see for it. A blank
    /// title reverts to the advertised name. The sidebar section is rebuilt
    /// because it carries the name.
    public func renameMediaServer(id: String, title: String?) async {
        MediaServerService.CustomTitles.set(title, for: id)
        guard let index = mediaServers.firstIndex(where: { $0.id == id }) else { return }
        let renamed = mediaServers[index].renamed(to: MediaServerService.CustomTitles.title(for: id))
        guard renamed.name != mediaServers[index].name else { return }
        mediaServers[index] = renamed
        sonosDiagLog(.info, tag: "MEDIASERVER", "Media server renamed",
                     context: ["id": id, "name": renamed.name, "advertised": renamed.advertisedName])
        await loadBrowseSections()
    }

    /// Defaults to on: discovery is passive and the section only appears when
    /// a server answers. Stored inverted-checkable so the absence of
    /// the key reads as enabled.
    public var mediaServersEnabled: Bool {
        (UserDefaults.standard.object(forKey: UDKey.mediaServersEnabled) as? Bool) ?? true
    }

    public func search(query: String, in containerID: String = BrowseID.tracks, householdID: String?, start: Int = 0, count: Int = PageSize.search) async throws -> (items: [BrowseItem], total: Int) {
        guard let device = topology.coordinatorForHousehold(householdID) ?? topology.preferredDevice else { return ([], 0) }
        return try await contentDirectory.search(device: device, containerID: containerID, searchTerm: query, start: start, count: count)
    }

    // MARK: - Play from Browse

    public func playBrowseItem(_ item: BrowseItem, in group: SonosGroup) async throws {
        guard let coordinator = group.coordinator else { return }

        // Fail-fast: a local-library item whose share isn't configured on the
        // selected speaker's system would 701 on play and surface as a
        // misleading "speaker layout changed" error. Tell the user which Sonos
        // app to add the folders in instead. Fail-open — `localLibraryPlayable`
        // returns true on unknown capability, so missing data never blocks.
        if let playable = library.localLibraryPlayable(item, on: coordinator), !playable {
            let generation = SonosSystemVersion.classify(swGen: coordinator.swGen,
                                                         softwareVersion: coordinator.softwareVersion)
            sonosDiagLog(.info, tag: "PLAYBACK",
                         "Blocked local-library play: not set up on selected system",
                         context: [
                            "objectID": item.objectID,
                            "title": item.title,
                            "generation": generation.displayLabel,
                            "household": coordinator.householdID ?? "<nil>"
                         ])
            throw StaleDataError.libraryNotConfigured(generation)
        }

        // "Play Now" replaces the queue — snapshot the outgoing queue first so
        // an accidental tap is recoverable from history. Self-guards on
        // a non-empty queue, so a play with no current queue costs one getQueue.
        await snapshotQueueForHistory(group: group)

        // Remember which favorite was played so art can be mapped back
        lastPlayedFavoriteID = item.objectID

        // Cache external art URL (e.g. from iTunes Search API) so it persists
        // in play history and NowPlaying even after the speaker returns different metadata
        if let art = item.albumArtURI, art.hasPrefix("http"), !art.contains("/getaa?") {
            cacheArtURL(art, forURI: item.resourceURI ?? "", title: item.title, itemID: item.objectID)
        }

        // Cache track info for recovery when speaker returns empty metadata
        if let uri = item.resourceURI, !item.title.isEmpty {
            enricher.cachedTrackInfo[uri] = TrackMetadataEnricher.CachedTrack(
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
        beginAwaitingPlayback(coordinator: coordinator.id)
        if !isContainer {
            var pendingMeta = initialMeta
            // Prefer cached art (survives restart), then item's DIDL art, then nil
            if let cachedArt = discoveredArtURLs[item.objectID] ?? lookupCachedArt(uri: item.resourceURI, title: item.title) {
                pendingMeta.albumArtURI = cachedArt
            }
            groupTrackMetadata[coordinator.id] = pendingMeta
            updateTransportState(coordinator.id, state: .transitioning)
            setTransportGrace(groupID: coordinator.id, duration: Timing.playbackGracePeriod)
        }

        // Every throw below this point would otherwise leave
        // `awaitingPlayback` stuck true (spinner never clears) — clear
        // it on the way out and rethrow.
        do {

            // Containers (local-library playlists, library albums, Sonos
            // saved queues, streaming-service containers) report a
            // `resourceURI` that points at the source — e.g. the raw CIFS
            // path to `iTunes Music Library.xml` for a local playlist.
            // `SetAVTransportURI` rejects those with UPnP fault 800 because
            // they're containers, not playable resources. Route containers
            // through `makeContainerURI`, which rewrites `S:` / `A:` /
            // `SQ:` objectIDs to the Sonos-internal `x-rincon-playlist:` /
            // `file:///jffs/` form the queue-based playlist branch below
            // knows how to enqueue and play. Items without a recognised
            // prefix fall through to their original `resourceURI`, so
            // streaming-service `x-rincon-cpcontainer:` containers keep
            // their existing path.
            let candidateURI: String? = item.isContainer
                ? makeContainerURI(item)
                : item.resourceURI
            if let uri = candidateURI, !uri.isEmpty {
                var meta = DIDLNormalize.metadata(item.resourceMetadata ?? "")

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
                    // Optimistic .playing — see playItemsReplacingQueue.
                    var pendingMeta = initialMeta
                    if let cachedArt = discoveredArtURLs[item.objectID] ?? lookupCachedArt(uri: item.resourceURI, title: item.title) {
                        pendingMeta.albumArtURI = cachedArt
                    }
                    groupTrackMetadata[coordinator.id] = pendingMeta
                    updateTransportState(coordinator.id, state: .playing)
                    setTransportGrace(groupID: coordinator.id, duration: Timing.playbackGracePeriod)
                    clearAwaitingPlayback(coordinator: coordinator.id)
                    // Notify QueueView to reload; the queue-based play path
                    // otherwise leaves the panel stale (issue #8).
                    if queueWasModified {
                        enricher.postQueueChanged(optimisticItems: [])
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
                    // Promote past the preflight .transitioning.
                    confirmPlaying(coordinator: coordinator.id)
                    enricher.postQueueChanged(optimisticItems: [])
                } else {
                    // Pre-strategy gate: SMAPI service-track URIs
                    // (`x-sonos-spotify:`, `x-sonos-http:`, `x-sonos-hls:`)
                    // are rejected by direct `SetAVTransportURI` with UPnP
                    // 714 regardless of which strategy would run next, and
                    // the `.smapiResolveThenEmpty` resolver rewrites Spotify
                    // to `x-spotify://…` (also rejected) while stripping the
                    // DIDL metadata. Every SMAPI service track therefore goes
                    // through the queue path with the ORIGINAL `uri` + `meta`,
                    // bypassing the strategy switch (issue #42).
                    if Self.isSMAPIServiceTrackURI(uri) {
                        // Controller-authenticated SMAPI services (Audible
                        // sid=239, TIDAL) fault UPnP 800 on AddURIToQueue
                        // with the raw `x-sonos-http:…?sid=…&sn=…` URI — they
                        // have no speaker-side account binding and must be
                        // resolved to a direct stream URL via getMediaURI
                        // first. resolveSMAPIPlayback is a no-op for
                        // speaker-account-bound services: Spotify keeps its
                        // raw `x-sonos-spotify:…?sid=12` + DIDL because its
                        // getMediaURI returns an `x-spotify://` URI the
                        // http-guard rejects, so issue #42 is preserved.
                        // Same resolution as the enqueue path (addBrowseItemToQueue).
                        let (queueURI, queueMeta) = await resolveSMAPIPlayback(item, uri: uri, meta: meta)
                        // Fail-fast pre-flight: a container id inside a
                        // track-shaped item is a guaranteed UPnP 800 from
                        // AddURIToQueue (#77 — a Spotify error row titled
                        // "Unable to access playlist" carried a playlist
                        // URI through this leaf path).
                        let decodedQueueURI = queueURI.removingPercentEncoding ?? queueURI
                        if decodedQueueURI.contains(":playlist:")
                            || decodedQueueURI.contains(":album:")
                            || decodedQueueURI.contains(":artist:") {
                            sonosDiagLog(.error, tag: "PLAYBACK",
                                         "Container id in single-track path — refusing pre-flight",
                                         context: [
                                            "uri": queueURI,
                                            "title": item.title,
                                            "service": serviceLabel(for: item) ?? "unknown"
                                         ])
                            throw StaleDataError.notPlayable
                        }
                        sonosDiagLog(.info, tag: "PLAYBACK",
                                     "SMAPI single track via queue: \(item.title.isEmpty ? "<no title>" : item.title)",
                                     context: [
                                        "uri": queueURI,
                                        "resolved": String(queueURI != uri),
                                        "objectID": item.objectID,
                                        "service": serviceLabel(for: item) ?? "unknown"
                                     ])
                        do {
                            try await withStaleHandling(for: group.name) {
                                // "Play Now" for a SMAPI single track:
                                // match the official Sonos app — replace
                                // the queue with this one track and play.
                                // Sonos rejects direct `SetAVTransportURI`
                                // for SMAPI URIs with UPnP 714, so the
                                // queue path is the only working route.
                                // Stop first because
                                // `removeAllTracksFromQueue` on an
                                // actively-playing coordinator leaves the
                                // current track in place, which would push
                                // the new row to position 2 and break
                                // playback.
                                try? await avTransport.stop(device: coordinator)
                                try await contentDirectory.removeAllTracksFromQueue(device: coordinator)
                                _ = try await contentDirectory.addURIToQueue(
                                    device: coordinator, uri: queueURI, metadata: queueMeta
                                )
                                try await avTransport.setAVTransportURI(
                                    device: coordinator,
                                    uri: "x-rincon-queue:\(coordinator.id)#0"
                                )
                                do {
                                    try await avTransport.play(device: coordinator)
                                } catch let soap as SOAPError {
                                    // Amazon Music Prime: the row enqueues and
                                    // resolves, then Play faults 701 on every
                                    // track form. Report the tier instead of a
                                    // stale-topology rescan.
                                    if case .soapFault(let code, _) = soap, code == "701",
                                       Self.isAmazonMusicURI(queueURI) {
                                        throw StaleDataError.serviceTierRefused
                                    }
                                    throw soap
                                }
                            }
                            enricher.postQueueChanged(optimisticItems: [])
                            return
                        } catch {
                            sonosDiagLog(.error, tag: "PLAYBACK",
                                         "SMAPI single track via queue failed for \(item.title.isEmpty ? "<no title>" : item.title)",
                                         context: [
                                            "uri": queueURI,
                                            "resolved": String(queueURI != uri),
                                            "error": String(describing: error),
                                            "service": serviceLabel(for: item) ?? "unknown"
                                         ])
                            throw error
                        }
                    }

                    // Direct playback — dispatch on the item's per-service
                    // playback strategy. Each strategy is a closed unit: one
                    // service's quirks live in one place and changes there
                    // can't bleed into another service's path.
                    var effectiveURI = uri
                    var effectiveMeta = meta
                    switch item.playbackStrategy {
                    case .smapiResolveThenEmpty:
                        // SMAPI search items: getMediaURI returns the direct
                        // stream URL (with embedded credentials). The speaker
                        // rejects the raw `x-sonosapi-stream:` SMAPI control
                        // URI with UPnP 402, but accepts the resolved URL
                        // with empty DIDL. Recently-played items already hold
                        // the resolved URL via play history.
                        (effectiveURI, effectiveMeta) = await resolveSMAPIPlayback(item, uri: uri, meta: meta)
                    case .directURIWithDIDL:
                        // TuneIn music stations (s-prefix), Sonos favourites,
                        // raw HTTP/HLS, line-in, etc. The URI is the
                        // authoritative target and the DIDL carries cdudn /
                        // source identification the speaker needs
                        // (SA_RINCON3079_ for TuneIn). No resolve, no
                        // metadata stripping.
                        break
                    case .tuneInResolveViaRadioTime:
                        // TuneIn topics / programs / podcast episodes
                        // (t/p/g-prefix). Resolve via RadioTime's Tune.ashx
                        // to the direct CDN URL, then play queue-based
                        // (AddURIToQueue + SetAVTransportURI to queue +
                        // play). Queue-based play is required because:
                        //   - x-sonosapi-stream: rejects topics with 800
                        //     (they're not audioBroadcasts).
                        //   - x-rincon-mp3radio://<host_and_path> strips
                        //     https:// and fails on HSTS-protected CDNs
                        //     (fireside.fm rejects the speaker's plain
                        //     HTTP fetch).
                        //   - x-rincon-mp3radio:https://... is rejected
                        //     with UPnP 714 (Illegal MIME Type).
                        // AddURIToQueue with the raw https:// URL plus a
                        // track DIDL declaring the MIME lets Sonos's queue
                        // fetcher use TLS correctly. Mirrors how the
                        // official app handles podcast playback.
                        let guideId = item.objectID.hasPrefix("tunein:")
                            ? String(item.objectID.dropFirst("tunein:".count))
                            : item.objectID
                        if let resolved = await ServiceSearchProvider.shared.resolveTuneIn(guideId: guideId) {
                            // Stations are continuous broadcasts: the queue
                            // path below is for finite episodes, and a live
                            // stream belongs on the broadcast form the
                            // speaker manages itself.
                            if guideId.hasPrefix("s") {
                                let broadcastDIDL = ServiceSearchProvider.shared.buildRadioBroadcastDIDL(
                                    title: item.title, artURI: item.albumArtURI)
                                sonosDiagLog(.info, tag: "PLAYBACK",
                                             "TuneIn station via direct stream: \(item.title)",
                                             context: ["guideId": guideId,
                                                       "streamURI": resolved.sonosStreamURI])
                                try await withStaleHandling(for: group.name) {
                                    try await avTransport.setAVTransportURI(
                                        device: coordinator,
                                        uri: resolved.sonosStreamURI,
                                        metadata: broadcastDIDL)
                                    try await avTransport.play(device: coordinator)
                                }
                                confirmPlaying(coordinator: coordinator.id)
                                enricher.postQueueChanged(optimisticItems: [])
                                return
                            }
                            let trackDIDL = ServiceSearchProvider.shared.buildDirectHTTPTrackDIDL(
                                title: item.title,
                                artist: item.artist ?? "",
                                url: resolved.directURL,
                                mediaType: resolved.mediaType
                            )
                            sonosDiagLog(.info, tag: "PLAYBACK",
                                         "TuneIn topic via queue: \(item.title)",
                                         context: [
                                            "guideId": guideId,
                                            "directURL": resolved.directURL,
                                            "mediaType": resolved.mediaType
                                         ])
                            do {
                                try await withStaleHandling(for: group.name) {
                                    try await contentDirectory.removeAllTracksFromQueue(device: coordinator)
                                    _ = try await contentDirectory.addURIToQueue(
                                        device: coordinator,
                                        uri: resolved.directURL,
                                        metadata: trackDIDL
                                    )
                                    try await avTransport.setAVTransportURI(
                                        device: coordinator,
                                        uri: "x-rincon-queue:\(coordinator.id)#0"
                                    )
                                    try await avTransport.play(device: coordinator)
                                }
                                // Optimistic .playing — see playItemsReplacingQueue.
                                // Without it a stale AVT SUBSCRIBE callback after a
                                // network-path change can leave the UI on .transitioning.
                                confirmPlaying(coordinator: coordinator.id)
                                enricher.postQueueChanged(optimisticItems: [])
                                return
                            } catch {
                                sonosDiagLog(.error, tag: "PLAYBACK",
                                             "TuneIn topic queue-based play failed",
                                             context: [
                                                "guideId": guideId,
                                                "directURL": resolved.directURL,
                                                "error": String(describing: error)
                                             ])
                                throw error
                            }
                        } else {
                            sonosDiagLog(.warning, tag: "PLAYBACK",
                                         "TuneIn Tune.ashx resolve returned no playable URL; falling back to raw URI",
                                         context: ["guideId": guideId])
                        }
                    case .directHTTPSQueue:
                        // Direct finite HTTPS media file that isn't a Sonos
                        // service (e.g. a public Suno CDN MP3). `uri` is already
                        // the direct CDN URL and `meta` already carries the
                        // http-get track DIDL — no resolve step. Direct
                        // SetAVTransportURI of a raw https:// URL is rejected
                        // (UPnP 714); queue-based play is the only working route,
                        // identical to the TuneIn-topic branch above.
                        sonosDiagLog(.info, tag: "PLAYBACK",
                                     "Direct HTTPS queue play: \(item.title.isEmpty ? "<no title>" : item.title)",
                                     context: ["uri": uri])
                        do {
                            try await withStaleHandling(for: group.name) {
                                try await contentDirectory.removeAllTracksFromQueue(device: coordinator)
                                _ = try await contentDirectory.addURIToQueue(
                                    device: coordinator, uri: uri, metadata: meta
                                )
                                try await avTransport.setAVTransportURI(
                                    device: coordinator,
                                    uri: "x-rincon-queue:\(coordinator.id)#0"
                                )
                                try await avTransport.play(device: coordinator)
                            }
                            // Optimistic .playing — see playItemsReplacingQueue.
                            confirmPlaying(coordinator: coordinator.id)
                            enricher.postQueueChanged(optimisticItems: [])
                            return
                        } catch {
                            sonosDiagLog(.error, tag: "PLAYBACK",
                                         "Direct HTTPS queue play failed",
                                         context: ["uri": uri, "error": String(describing: error)])
                            throw error
                        }
                    }
                    sonosDebugLog("[PLAYBACK] SetAVTransportURI: \(effectiveURI.prefix(80))")
                    sonosDiagLog(.info, tag: "PLAYBACK",
                                 "Direct play attempt: \(item.title.isEmpty ? "<no title>" : item.title)",
                                 context: [
                                    "uri": effectiveURI,
                                    "uri_original": uri,
                                    "didl_metadata": meta,
                                    "sent_metadata": effectiveMeta,
                                    "title": item.title,
                                    "artist": item.artist ?? "",
                                    "service": serviceLabel(for: item) ?? "unknown",
                                    "objectID": item.objectID
                                 ])
                    do {
                        try await withStaleHandling(for: group.name) {
                            try await avTransport.setAVTransportURI(
                                device: coordinator, uri: effectiveURI, metadata: effectiveMeta
                            )
                            try await avTransport.play(device: coordinator)
                        }
                    } catch where item.objectID.hasPrefix("tunein:") {
                        // A household that has lost the legacy TuneIn service
                        // rejects the `x-sonosapi-stream:…sid=254` form
                        // outright. RadioTime's public Tune.ashx returns the
                        // station's direct stream URL, which the speaker plays
                        // with no Sonos service involved. Fallback only:
                        // households that still carry the service keep the
                        // richer service-side behaviour.
                        let guideId = String(item.objectID.dropFirst("tunein:".count))
                        sonosDiagLog(.warning, tag: "PLAYBACK",
                                     "TuneIn service form rejected; retrying via RadioTime direct stream",
                                     context: ["guideId": guideId,
                                               "error": String(describing: error)])
                        guard let resolved = await ServiceSearchProvider.shared.resolveTuneIn(guideId: guideId) else {
                            throw error
                        }
                        let broadcastDIDL = ServiceSearchProvider.shared.buildRadioBroadcastDIDL(
                            title: item.title, artURI: item.albumArtURI)
                        try await withStaleHandling(for: group.name) {
                            try await avTransport.setAVTransportURI(
                                device: coordinator,
                                uri: resolved.sonosStreamURI,
                                metadata: broadcastDIDL)
                            try await avTransport.play(device: coordinator)
                        }
                    } catch {
                        // Capture the URI + metadata that triggered the failure so
                        // diagnostics can pinpoint single-track service plays that
                        // need queue-routed handling instead.
                        sonosDiagLog(.error, tag: "PLAYBACK",
                                     "Direct play failed for \(item.title.isEmpty ? "<no title>" : item.title)",
                                     context: [
                                        "uri": uri,
                                        "didl_metadata": meta,
                                        "error": String(describing: error),
                                        "title": item.title,
                                        "artist": item.artist ?? "",
                                        "service": serviceLabel(for: item) ?? "unknown"
                                     ])
                        // A persistent 701 on a single-track direct play (after the
                        // stale-handling rescan) means the speaker can't resolve the
                        // URI — almost always because the track's service/library
                        // isn't set up on this speaker's system. Surface that
                        // instead of a misleading "speaker layout changed" error.
                        if case StaleDataError.topologyStale = error {
                            throw StaleDataError.serviceUnavailable
                        }
                        throw error
                    }
                    // Optimistic .playing — see playItemsReplacingQueue.
                    confirmPlaying(coordinator: coordinator.id)
                    // Direct-URI playback bypasses the queue, but `Play
                    // Now` semantics imply replacing whatever was there;
                    // a notification triggers a Browse(Q:0) so the panel
                    // shows the newly-empty (or radio-streaming) state.
                    enricher.postQueueChanged(optimisticItems: [])
                }
            } else if item.isContainer {
                try await withStaleHandling(for: group.name) {
                    try await contentDirectory.removeAllTracksFromQueue(device: coordinator)
                    let containerURI = makeContainerURI(item)
                    _ = try await contentDirectory.addURIToQueue(device: coordinator, uri: containerURI)
                    try await avTransport.setAVTransportURI(device: coordinator, uri: "x-rincon-queue:\(coordinator.id)#0")
                    try await avTransport.play(device: coordinator)
                }
                enricher.postQueueChanged(optimisticItems: [])
            }
        } catch {
            clearAwaitingPlayback(coordinator: coordinator.id)
            throw error
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
    /// Filter for batch queue actions (`addBrowseItemsToQueue`,
    /// `fillQueueInBackground`). The contract: an item is queueable
    /// when it carries a non-empty `resourceURI`, regardless of
    /// whether it's a container — Sonos's `AddURIToQueue` /
    /// `AddMultipleURIsToQueue` actions both expand SMAPI containers
    /// (`x-rincon-cpcontainer:` album / playlist URIs from Spotify,
    /// Apple Music, Plex, etc.) server-side. Items with no URI (UPnP
    /// browse-only containers like local-library albums) need a
    /// separate child-fetch path and are not queueable as-is.
    ///
    /// Pulled out so `BatchQueueFilterTests` can pin the contract.
    static func isQueueable(_ item: BrowseItem) -> Bool {
        guard let uri = item.resourceURI, !uri.isEmpty else { return false }
        return true
    }

    /// Coordinators with a batch add (or play-now background fill)
    /// mid-flight. A second batch for the same coordinator is refused
    /// instead of interleaved: overlapping adds multiply the queue,
    /// saturate the speaker with concurrent SOAP calls, and time out
    /// transport reconciliation. @ObservationIgnored deliberately:
    /// consumers poll it at action time (`isBatchAddInFlight`); it drives
    /// no live UI.
    @ObservationIgnored private var batchAddInFlightCoordinators: Set<String> = []
    /// Per-coordinator count of background fills started; a finishing
    /// fill releases the exclusivity flag only when it is the latest.
    @ObservationIgnored private var queueFillGeneration: [String: Int] = [:]

    /// A queue mutation was refused because one is already running for
    /// the same coordinator.
    public struct QueueBusyError: LocalizedError {
        public init() {}
        public var errorDescription: String? { L10n.queueAddInProgress }
    }

    /// True while a batch add is running against `group`'s coordinator —
    /// UI replay/add controls disable on this.
    public func isBatchAddInFlight(for group: SonosGroup) -> Bool {
        batchAddInFlightCoordinators.contains(group.coordinatorID)
    }

    public func addBrowseItemsToQueue(_ items: [BrowseItem], in group: SonosGroup, playNext: Bool = false) async throws -> Int {
        guard !items.isEmpty else { return 0 }
        if items.count == 1 {
            return try await addBrowseItemToQueue(items[0], in: group, playNext: playNext)
        }
        guard let coordinator = group.coordinator else { return 0 }
        guard !batchAddInFlightCoordinators.contains(coordinator.id) else {
            sonosDebugLog("[QUEUE] Batch add refused — add already in flight for \(coordinator.id)")
            // Throw, never return 0: a silent zero read as success at
            // call sites that show an "added" confirmation.
            throw QueueBusyError()
        }
        batchAddInFlightCoordinators.insert(coordinator.id)
        defer { batchAddInFlightCoordinators.remove(coordinator.id) }
        beginAddingToQueue()
        defer { endAddingToQueue() }

        var uris: [String] = []
        var metas: [String] = []
        var optimisticSource: [BrowseItem] = []
        for item in items {
            // Skip only items with no usable URI. SMAPI containers
            // (`x-rincon-cpcontainer:` album/playlist URIs from
            // Spotify, Apple Music, Plex etc.) DO have a URI and Sonos
            // expands them server-side; filtering on `isContainer` would
            // drop them. If batch faults on a mixed container payload,
            // the per-item fallback below uses `addURIToQueue`, which
            // accepts containers (see the singular `addBrowseItemToQueue`).
            guard let uri = item.resourceURI, !uri.isEmpty else { continue }
            uris.append(uri)
            let meta = DIDLNormalize.metadata(item.resourceMetadata ?? "")
            metas.append(meta)
            optimisticSource.append(item)
            // Cache track info for queue-row recovery: Apple Music enqueues
            // are descriptor-free (fast path), so the SPEAKER stores no
            // title/artist for them — the queue panel recovers from this
            // cache. The Play All path already did this; Add All / Play
            // Next didn't, which left freshly-added rows blank.
            if !item.title.isEmpty {
                let cached = TrackMetadataEnricher.CachedTrack(title: item.title, artist: item.artist,
                                         album: item.album, artURL: item.albumArtURI)
                enricher.cachedTrackInfo[uri] = cached
                if let decoded = uri.removingPercentEncoding, decoded != uri {
                    enricher.cachedTrackInfo[decoded] = cached
                }
            }
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
        // grows with the number of round-trips.
        let total = uris.count

        var firstTrack = 0
        var numAdded = 0
        let chunkSize = 16
        var nextInsertAt = insertAt
        var repairRows: [(position: Int, uri: String)] = []
        var failedChunks: [(start: Int, end: Int)] = []
        var chunkIndex = 0
        let queueRefreshInterval = 10  // refresh every ~160 tracks
        var consecutiveBulkFailures = 0
        let bulkFailureCapThreshold = 5
        var queueCapHit = false
        // Bulk path: try each chunk independently. The speaker accepts
        // almost every chunk; a single mis-encoded track must not abort
        // the whole add, so failures are collected and retried per-track.
        for chunkStart in stride(from: 0, to: uris.count, by: chunkSize) {
            let end = min(chunkStart + chunkSize, uris.count)
            let uriChunk = Array(uris[chunkStart..<end])
            let metaChunk = Array(metas[chunkStart..<end])
            do {
                let result = try await contentDirectory.addMultipleURIsToQueue(
                    device: coordinator,
                    uris: uriChunk, metadatas: metaChunk,
                    desiredFirstTrackNumberEnqueued: nextInsertAt,
                    enqueueAsNext: false
                )
                sonosDebugLog("[QUEUE] Batch chunk \(chunkStart)-\(end-1): firstTrack=\(result.firstTrackNumber) numAdded=\(result.numAdded)")
                if firstTrack == 0 && result.firstTrackNumber > 0 { firstTrack = result.firstTrackNumber }
                if result.firstTrackNumber > 0 {
                    for (offset, u) in uriChunk.prefix(result.numAdded).enumerated() {
                        repairRows.append((position: result.firstTrackNumber + offset, uri: u))
                    }
                }
                numAdded += result.numAdded
                if nextInsertAt > 0 { nextInsertAt += result.numAdded }
                queue.addingToQueueProgress = numAdded
                consecutiveBulkFailures = 0
                chunkIndex += 1
                if chunkIndex % queueRefreshInterval == 0 {
                    enricher.postQueueChanged(optimisticItems: [])
                }
            } catch {
                consecutiveBulkFailures += 1
                // Speaker queue-full detection. Once N chunks fail
                // back-to-back with the same fault, the add is past the
                // speaker's queue capacity — stop adding and log
                // once instead of continuing to flood diagnostics.
                if consecutiveBulkFailures >= bulkFailureCapThreshold {
                    sonosDiagLog(.warning, tag: "QUEUE",
                                 "Speaker queue cap reached at \(numAdded) tracks — stopping bulk add",
                                 context: ["faultsInARow": String(consecutiveBulkFailures)])
                    queueCapHit = true
                    break
                }
                sonosDiagLog(.warning, tag: "QUEUE",
                             "Batch chunk \(chunkStart)-\(end-1) threw — will retry per-track: \(error.localizedDescription)")
                failedChunks.append((chunkStart, end))
            }
        }
        if queueCapHit {
            // Queue cap hit — skip the per-track retry on collected
            // failed chunks; they will all hit the same cap and just
            // produce more diagnostic noise.
            failedChunks.removeAll()
        }

        // Per-track retry only for the chunks that bulk-failed. Skips
        // tracks that throw individually (e.g., specific malformed
        // path / metadata) without aborting the rest.
        if !failedChunks.isEmpty {
            sonosDebugLog("[QUEUE] Retrying \(failedChunks.count) failed chunks per-track")
            var consecutiveFailures = 0
            for (chunkStart, chunkEnd) in failedChunks {
                for i in chunkStart..<chunkEnd {
                    let item = optimisticSource[i]
                    guard let uri = item.resourceURI, !uri.isEmpty else { continue }
                    var meta = item.resourceMetadata ?? ""
                    meta = DIDLNormalize.metadata(meta)
                    let target = insertAt > 0 ? insertAt + i : 0
                    do {
                        let pos = try await contentDirectory.addURIToQueue(
                            device: coordinator, uri: uri, metadata: meta,
                            desiredFirstTrackNumberEnqueued: target, enqueueAsNext: false
                        )
                        if firstTrack == 0 && pos > 0 { firstTrack = pos }
                        if pos > 0 { numAdded += 1 }
                        consecutiveFailures = 0
                    } catch {
                        consecutiveFailures += 1
                        sonosDiagLog(.warning, tag: "QUEUE",
                                     "Per-track retry skipped '\(item.title)': \(error.localizedDescription)",
                                     context: ["uri": uri])
                        // Only abort if many in a row — that signals a
                        // global problem (network, speaker reset),
                        // not a single bad track.
                        if consecutiveFailures >= 10 {
                            sonosDiagLog(.error, tag: "QUEUE",
                                         "Per-track retry aborted after 10 consecutive failures")
                            break
                        }
                    }
                }
                if consecutiveFailures >= 10 { break }
            }
        }

        // Batch adds trigger a full queue reload instead of optimistic append.
        // The slowness on S1 means the user has already waited; one extra
        // Browse(Q:0) round-trip is negligible compared to the batch duration,
        // and a real reload guarantees the queue panel matches the speaker's
        // actual state — including any tracks that failed mid-loop.
        enricher.postQueueChanged(optimisticItems: [])
        // Background-name the freshly-added Apple Music rows for other
        // controllers (fast add stores no speaker-side metadata).
        scheduleAppleMusicQueueRepair(group: group, rows: repairRows)
        return firstTrack
    }

    /// Resolves a `.smapiResolveThenEmpty` browse item to its direct stream
    /// URL via `getMediaURI` (using Choragus's stored token), returning the
    /// resolved URL with empty DIDL. Returns the original `uri`/`meta`
    /// unchanged for any other item or when resolution fails.
    ///
    /// Centralised so play and enqueue apply identical resolution.
    /// Controller-authenticated services (e.g. TIDAL) have no speaker-side
    /// account binding, so the raw `x-sonos-http:…?sid=…&sn=…` URI faults
    /// UPnP 800; the resolved direct URL plays without any account binding,
    /// which also makes the `sn` value irrelevant.
    private func resolveSMAPIPlayback(_ item: BrowseItem, uri: String, meta: String) async -> (uri: String, meta: String) {
        guard item.playbackStrategy == .smapiResolveThenEmpty,
              let resolver = smapiURIResolver,
              item.objectID.hasPrefix("smapi:") else { return (uri, meta) }
        let trimmed = item.objectID.dropFirst("smapi:".count)
        guard let colon = trimmed.firstIndex(of: ":"),
              let sid = Int(trimmed[..<colon]) else { return (uri, meta) }
        let itemID = String(trimmed[trimmed.index(after: colon)...])
        do {
            if let resolved = try await resolver(sid, itemID), !resolved.isEmpty {
                // Only adopt a resolved URL that is a DIRECT stream. The whole
                // point of this step is to swap a controller-authenticated
                // service track (e.g. TIDAL → https://…tidal.com CDN) for a URL
                // the speaker can play with empty DIDL. Some services return
                // another Sonos service URI from getMediaURI — Spotify gives
                // `x-spotify://spotify:track:ID`, which needs DIDL + account
                // binding and the speaker REJECTS on AddURIToQueue (UPnP 804).
                // Keep the original `x-sonos-spotify:…?sid=12` + DIDL in that
                // case, which the queue accepts (same form background-fill uses).
                guard resolved.hasPrefix("http://") || resolved.hasPrefix("https://") else {
                    return (uri, meta)
                }
                // Persist TIDAL's browse-time art/title/artist keyed to the
                // resolved play URL — the empty DIDL strips them otherwise, and
                // the CDN URL carries no recoverable cover id (unlike Suno).
                if sid == ServiceID.tidal {
                    TidalCatalog.remember(playURL: resolved, art: item.albumArtURI,
                                          title: item.title, artist: item.artist ?? "")
                }
                // The resolved URL is pre-signed and will expire. Record which
                // service item produced it so an expired queue entry can be
                // re-resolved instead of needing a manual re-add.
                ResolvedPlaybackRegistry.remember(playURL: resolved, sid: sid, itemID: itemID)
                return (resolved, "")
            }
        } catch {
            sonosDiagLog(.warning, tag: "PLAYBACK",
                         "SMAPI getMediaURI resolve failed; falling back to raw URI",
                         context: ["sid": String(sid), "itemID": itemID,
                                   "error": String(describing: error)])
        }
        return (uri, meta)
    }

    public func addBrowseItemToQueue(_ item: BrowseItem, in group: SonosGroup, playNext: Bool = false, atPosition: Int = 0) async throws -> Int {
        guard let coordinator = group.coordinator else { return 0 }
        beginAddingToQueue()
        defer { endAddingToQueue() }

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
            // means "append at end", so no Browse round-trip is needed to count
            // the current queue size — one fewer SOAP call per Add to Queue,
            // which matters on S1 hardware.
        }

        if let rawURI = item.resourceURI, !rawURI.isEmpty {
            let rawMeta = DIDLNormalize.metadata(item.resourceMetadata ?? "")
            // Resolve controller-authenticated SMAPI items (e.g. TIDAL) to a
            // direct stream URL with empty DIDL — same step the play path
            // applies. Without it the raw `sid=…&sn=…` URI faults UPnP 800.
            let (uri, meta) = await resolveSMAPIPlayback(item, uri: rawURI, meta: rawMeta)

            let cached = TrackMetadataEnricher.CachedTrack(
                title: item.title, artist: item.artist ?? "",
                album: item.album ?? "", artURL: item.albumArtURI
            )

            // Cache track info for later recovery when speaker returns empty metadata
            if !item.title.isEmpty {
                enricher.cachedTrackInfo[uri] = cached
                if let decoded = uri.removingPercentEncoding, decoded != uri {
                    enricher.cachedTrackInfo[decoded] = cached
                }
            }

            // Record the server's art at every enqueue, not only at browse
            // time: history and play-next re-adds carry a BrowseItem that
            // never went through MediaServerService.browse, and this is the
            // last point where the art URL is still attached to the play URL.
            if mediaServerServing(uri) != nil {
                MediaServerService.PublishedArt.remember(playURL: uri, art: item.albumArtURI)
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
                if enricher.cachedTrackByPosition[groupID] == nil { enricher.cachedTrackByPosition[groupID] = [:] }
                enricher.cachedTrackByPosition[groupID]?[result] = cached
            }
            // Optimistic-update payload: the QueueView appends this item directly
            // instead of re-fetching the whole queue from the coordinator. On S1
            // hardware the full Browse round-trip after each add adds ~3-5 s of
            // delay per track; this eliminates it. Fallback reload happens only
            // when the resulting track number is unknown (result == 0).
            //
            // playNext = true skips optimistic — the insert shifts every
            // following queue position by one, so the simple "append by id"
            // path drops the new row as a duplicate of the existing track
            // that just got pushed down. Force a full reload in that case.
            let optimistic: [QueueItem] = (result > 0 && !playNext) ? [QueueItem(
                id: result,
                title: item.title,
                artist: item.artist ?? "",
                album: item.album ?? "",
                albumArtURI: item.albumArtURI,
                duration: ""
            )] : []
            enricher.postQueueChanged(optimisticItems: optimistic)
            if result > 0 {
                scheduleAppleMusicQueueRepair(group: group, rows: [(position: result, uri: uri)])
            }
            return result
        } else if item.isContainer {
            let containerURI = makeContainerURI(item)
            sonosDebugLog("[QUEUE] Adding container to queue: \(containerURI.prefix(60)) atPos=\(insertAt)")
            let result = try await contentDirectory.addURIToQueue(device: coordinator, uri: containerURI, desiredFirstTrackNumberEnqueued: insertAt, enqueueAsNext: false)
            // Containers expand to multiple tracks server-side — no
            // an optimistic item list without fetching the queue, so fall back
            // to a full reload here. Same-file single-track adds are optimistic.
            enricher.postQueueChanged(optimisticItems: [])
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
            return "x-rincon-playlist:\(topology.preferredDevice?.id ?? "")#\(objectID)"
        }
        return item.resourceURI ?? objectID
    }

    // MARK: - Music Services

    public func getAvailableMusicServices() async throws -> [MusicService] {
        guard let device = topology.preferredDevice else { return [] }
        return try await musicServices.listAvailableServices(device: device)
    }

    /// Looks up a music service name by its Sonos service ID (sid=NNN in URIs)
    public func musicServiceName(for serviceID: Int) -> String? {
        if let match = musicServicesList.first(where: { $0.id == serviceID }) {
            return match.name
        }
        if let canonical = MusicServiceCatalog.shared.canonicalDisplayName(forSid: serviceID) {
            return canonical
        }
        return ServiceID.knownNames[serviceID]
    }

    /// Detects the music service from a URI by checking both sid= and URI content patterns.
    /// Memoised wrapper around the detection logic. Each URI goes through
    /// a percent-decode + `.contains` / `.hasPrefix` chain, and hot paths
    /// call it per row per body re-eval, so the result is cached. URIs
    /// are immutable, so the cache never needs eviction and stays bounded
    /// by the URI vocabulary, not by call count.
    private var detectServiceNameCache: [String: String?] = [:]

    public func detectServiceName(fromURI uri: String) -> String? {
        if let cached = detectServiceNameCache[uri] { return cached }
        let result = detectServiceNameUncached(uri)
        detectServiceNameCache[uri] = result
        return result
    }

    private func detectServiceNameUncached(_ uri: String) -> String? {
        // A media server's tracks are plain HTTP URLs with no sid and no Sonos
        // scheme, so nothing else here can name them. Matching the host:port
        // against the known servers names the row after the server rather
        // than generic "Streaming".
        if let server = mediaServerServing(uri) { return server.name }

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
        if lower.contains("suno.ai") { return ServiceName.suno }
        // Services whose SMAPI resolves to a plain HTTPS stream carry no sid=
        // and no Sonos scheme, so the host is the only signal left. Without
        // these the Now Playing service row is absent — the track shows its
        // format badge and nothing underneath.
        if lower.contains("radioparadise") { return ServiceName.radioParadise }
        if lower.contains("somafm") { return "SomaFM Radio" }

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
        updateTransportState(groupID, state: state)
        if state == .playing && awaitingPlayback[groupID] == true {
            clearAwaitingPlayback(coordinator: groupID)
        }
    }

    /// Detects the Sonos TuneIn ad-pre-roll loop by URI signature.
    /// Logs a WARNING when a group enters the ad state and an INFO
    /// when it exits. The user-visible signal is the diagnostic bundle:
    /// when a station "won't play", the bundle carries an explicit
    /// `[TUNEIN-AD]` event attributing it to Sonos's ad backend.
    /// Diagnostics for speaker-side early track advances. A track that
    /// changes while the previous one had ≥ 20 s left — with no
    /// controller transport command in the last 8 s — is the signature
    /// of a stream-delivery failure (the speaker abandons the track and
    /// moves on without surfacing any UPnP fault to controllers).
    /// Detection only; playback is untouched.
    private func logEarlyTrackAdvanceIfNeeded(groupID: String, incoming: TrackMetadata) {
        guard let newURI = incoming.trackURI, !newURI.isEmpty else { return }
        defer { lastTrackIdentity[groupID] = (newURI, incoming.title) }
        guard let previous = lastTrackIdentity[groupID], previous.uri != newURI else { return }
        let position = positionTracker.groupPositions[groupID] ?? 0
        let duration = positionTracker.groupDurations[groupID] ?? 0
        guard duration > 60, position > 5, duration - position >= 20 else { return }
        if let commandAt = lastControllerTransportCommandAt[groupID],
           Date().timeIntervalSince(commandAt) < 8 { return }
        sonosDiagLog(.warning, tag: "PLAYBACK",
                     "Track advanced early — possible stream failure",
                     context: [
                        "previousTitle": previous.title,
                        "playedSeconds": String(Int(position)),
                        "durationSeconds": String(Int(duration)),
                        "shortfallSeconds": String(Int(duration - position)),
                        "nextTitle": incoming.title
                     ])

        // One early advance is ordinary — a user skip that raced the
        // command window, or a single bad track. Several in a row is a
        // queue whose media URLs no longer resolve: the speaker plays
        // silence, advances, and reports no fault, so nothing reaches the
        // user unless reported here. Observed with TIDAL queue entries holding
        // an expired pre-signed URL; re-adding the track fixes it.
        let now = Date()
        var recent = (earlyAdvances[groupID] ?? []).filter { now.timeIntervalSince($0) < 60 }
        recent.append(now)
        earlyAdvances[groupID] = recent
        guard recent.count >= 3,
              now.timeIntervalSince(lastEarlyAdvanceReportAt[groupID] ?? .distantPast) > 120
        else { return }
        lastEarlyAdvanceReportAt[groupID] = now
        earlyAdvances[groupID] = []
        // Repair before reporting: a stale pre-signed URL is re-resolvable
        // whenever the service item behind it was recorded at enqueue time.
        // Only when that fails does the user need to act.
        let staleURI = previous.uri
        Task { [weak self] in
            guard let self else { return }
            if await self.repairStaleQueueEntries(groupID: groupID, failedURI: staleURI) { return }
            ErrorHandler.shared.handle(StaleDataError.tracksSkippingEarly,
                                       context: "PLAYBACK", userFacing: true)
        }
    }

    /// Health-monitor entry: repair every expired row the registry knows the
    /// origin of, without waiting for a playback failure. Reuses the failure
    /// path with the first expired row standing in as the trigger URI.
    public func repairExpiredQueueEntries(groupID: String) async -> Bool {
        guard let group = groups.first(where: { $0.id == groupID }),
              let coordinator = group.coordinator else { return false }
        let rows = (try? await contentDirectory.browseQueue(
            device: coordinator, start: 0, count: PageSize.queue).items) ?? []
        // The playing row is left alone: replacing it in place interrupts
        // playback, and its URL is evidently still being served.
        let playing = (try? await avTransport.getPositionInfo(device: coordinator))?.trackNumber ?? 0
        guard let firstExpired = rows.first(where: { row in
            row.id > playing && (row.uri.map { StaleTrackURL.isExpired($0) } ?? false)
        })?.uri else { return false }
        return await repairStaleQueueEntries(groupID: groupID, failedURI: firstExpired,
                                             afterPosition: playing)
    }

    /// Re-resolves queue entries whose pre-signed URLs have expired, replacing
    /// each in place, and reports whether anything was repaired.
    ///
    /// The speaker gives no fault for an expired URL, so the trigger is the
    /// observed early-advance pattern rather than an error. `failedURI` is
    /// repaired first, then any other entry whose stated expiry has passed,
    /// so one pass fixes a whole queue rather than one track per failure.
    /// Entries with no recorded service origin cannot be repaired.
    private func repairStaleQueueEntries(groupID: String, failedURI: String,
                                         afterPosition: Int = 0) async -> Bool {
        guard let group = groups.first(where: { $0.id == groupID }),
              let coordinator = group.coordinator,
              let resolver = smapiURIResolver else { return false }
        guard StaleTrackURL.isStale(failedURI, playbackFailed: true) else { return false }

        let rows = (try? await contentDirectory.browseQueue(
            device: coordinator, start: 0, count: PageSize.queue).items) ?? []
        guard !rows.isEmpty else { return false }

        let candidates = rows.filter { row in
            guard row.id > afterPosition, let uri = row.uri else { return false }
            return uri == failedURI || StaleTrackURL.isExpired(uri)
        }
        guard !candidates.isEmpty else { return false }

        var repaired = 0
        for row in candidates {
            guard let uri = row.uri,
                  let origin = ResolvedPlaybackRegistry.origin(ofPlayURL: uri) else { continue }
            // `try?` flattens the resolver's `String?` return, so one
            // binding covers both a thrown error and a nil resolution.
            guard let fresh = try? await resolver(origin.sid, origin.itemID),
                  StaleTrackURL.isDirectStream(fresh), fresh != uri else { continue }
            // Each completed insert-then-remove leaves later positions
            // unchanged, so pre-repair positions stay valid only while
            // every step succeeds; the stale row is removed at the
            // position the speaker reports for the insert, and any
            // failure ends the pass rather than removing a good track.
            do {
                let insertedAt = try await contentDirectory.addURIToQueue(
                    device: coordinator, uri: fresh, metadata: "",
                    desiredFirstTrackNumberEnqueued: row.id, enqueueAsNext: true)
                let position = insertedAt > 0 ? insertedAt : row.id
                try await contentDirectory.removeTrackFromQueue(
                    device: coordinator, objectID: "Q:0/\(position + 1)")
                ResolvedPlaybackRegistry.remember(playURL: fresh, sid: origin.sid,
                                                  itemID: origin.itemID)
                repaired += 1
            } catch {
                sonosDiagLog(.warning, tag: "QUEUE",
                             "Stale queue entry replacement failed",
                             context: ["position": String(row.id),
                                       "sid": String(origin.sid),
                                       "error": String(describing: error)])
                break
            }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }

        guard repaired > 0 else { return false }
        sonosDiagLog(.info, tag: "QUEUE", "Re-resolved expired queue entries",
                     context: ["repaired": String(repaired),
                               "examined": String(candidates.count)])
        enricher.postQueueChanged(optimisticItems: [])
        return true
    }


    private func detectTuneInAdLoop(groupID: String, metadata: TrackMetadata) {
        let adURI: String? = {
            // Only an actively-playing group can be "in" an ad pre-roll. A
            // stopped/paused speaker still reports its last-loaded URI as the
            // current track, so without this gate a relaunch (which clears
            // `groupTuneInAdLoopURI`) re-detects a days-old loaded station and
            // logs a false "ad is playing" warning (observed: stopped station,
            // no playback for days).
            guard groupTransportStates[groupID]?.isActive == true else { return nil }
            guard let uri = metadata.trackURI, !uri.isEmpty else { return nil }
            // Sonos Radio container station 31971 is the ad pre-roll
            // wrapper; the cdnstream1.com host is its content origin;
            // sali.sonos.superhi.fi the art origin.
            if uri.contains("tunein%3a31971") { return uri }
            if uri.contains("tunein-ondemand.cdnstream1.com") { return uri }
            return nil
        }()
        let prior = groupTuneInAdLoopURI[groupID]
        switch (prior, adURI) {
        case (nil, let new?):
            groupTuneInAdLoopURI[groupID] = new
            sonosDiagLog(.warning, tag: "TUNEIN-AD",
                         "Sonos's TuneIn ad pre-roll is playing — station won't advance until the ad completes (or never, on stuck loops)",
                         context: [
                            "groupID": groupID,
                            "uri": new,
                            "title": metadata.title,
                            "stationName": metadata.stationName
                         ])
        case (let was?, nil):
            groupTuneInAdLoopURI[groupID] = nil
            sonosDiagLog(.info, tag: "TUNEIN-AD",
                         "Ad pre-roll cleared",
                         context: [
                            "groupID": groupID,
                            "priorURI": was
                         ])
        default:
            // No transition — either both nil (no ad) or both set
            // (still in ad). Nothing to log.
            break
        }
    }

    public func transportDidUpdateTrackMetadata(_ groupID: String, metadata: TrackMetadata, source: TrackMetadataSource = .event) {
        // No stale-poll guard here: Sonos events also lie after a
        // seek/auto-advance combo, so dropping disagreeing polls can filter
        // the only correct source. QueueView schedules an authoritative
        // `loadQueue()` refresh on any trackURI change instead.
        detectTuneInAdLoop(groupID: groupID, metadata: metadata)
        logEarlyTrackAdvanceIfNeeded(groupID: groupID, incoming: metadata)

        // Only GetMediaInfo reports `CurrentURI`, so event-sourced updates
        // leave `isQueueSource` at its false default. Publishing that
        // default killed the queue highlight, bars and auto-scroll on every
        // event-driven advance, so the last observed value carries forward.
        // The inherited value is not marked as observed (one carry-forward
        // must not authorise the next), and a radio-scheme track URI drops
        // it outright — otherwise queue→radio keeps the queue UI lit.
        var metadata = metadata
        if !metadata.didReportTransportSource,
           let existing = groupTrackMetadata[groupID],
           existing.didReportTransportSource {
            let uri = metadata.trackURI ?? ""
            let looksLikeStream = !uri.isEmpty && URIPrefix.isRadio(uri)
            metadata.isQueueSource = looksLikeStream ? false : existing.isQueueSource
            if metadata.queueSize == 0 { metadata.queueSize = existing.queueSize }
        }

        // Suno normalization up front so it applies on every path below
        // (including the first-metadata and station-change early returns):
        // derive the cover from the clip id, recover the persisted title, and
        // lazily fetch it if this clip has never been resolved.
        if let uri = metadata.trackURI, let uuid = SunoCatalog.uuid(fromURI: uri) {
            metadata.albumArtURI = SunoCatalog.coverURL(forUUID: uuid)
            if let t = SunoCatalog.title(forUUID: uuid) {
                metadata.title = t
            } else if metadata.title.isEmpty || TrackMetadata.isTechnicalName(metadata.title) {
                enricher.ensureSunoTitle(forUUID: uuid)
            }
            // Suno's style tags become the track genre (the speaker reports
            // none for direct-URL tracks) — feeds history + Club Vis matching.
            if metadata.genre.isEmpty, let g = SunoCatalog.genre(forUUID: uuid) {
                metadata.genre = g
            }
            // Suno creator → track artist (speaker reports none for direct URLs).
            if metadata.artist.isEmpty, let a = SunoCatalog.artist(forUUID: uuid) {
                metadata.artist = a
            }
        }
        // TIDAL normalization: tracks play via a resolved CDN URL with empty
        // DIDL, so recover art/title/artist from the persistent catalog keyed
        // on the play URL (populated at resolve time).
        if let uri = metadata.trackURI, TidalCatalog.key(fromURI: uri) != nil {
            if let art = TidalCatalog.art(forURI: uri) { metadata.albumArtURI = art }
            if metadata.title.isEmpty || TrackMetadata.isTechnicalName(metadata.title),
               let t = TidalCatalog.title(forURI: uri) { metadata.title = t }
            if metadata.artist.isEmpty, let a = TidalCatalog.artist(forURI: uri) { metadata.artist = a }
        }

        // Line-In: `x-rincon-stream:RINCON_<sourceID>` is an analog input from
        // another speaker — name the source room so Now Playing reads "Line-In"
        // / "Guest Room 2" instead of a bare "Line-In".
        let lineInPrefix = "x-rincon-stream:"
        if let uri = metadata.trackURI, uri.hasPrefix(lineInPrefix) {
            let sourceID = String(uri.dropFirst(lineInPrefix.count).prefix { $0.isLetter || $0.isNumber || $0 == "_" })
            let sourceRoom = devices[sourceID]?.roomName ?? ""
            metadata.title = "Line-In"
            if !sourceRoom.isEmpty { metadata.artist = sourceRoom }
        }

        guard let existing = groupTrackMetadata[groupID] else {
            // First metadata — also try to populate queue cache if playing from queue
            var initial = metadata
            if initial.title.isEmpty, initial.trackNumber > 0,
               let qi = enricher.lastQueueItems[groupID], initial.trackNumber - 1 < qi.count {
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

        // Issue #69: a new HLS-static track (YouTube Music etc.) often arrives
        // with the PRIOR track's title/artist — or an empty title — then settles
        // a beat later. Apple Music recovers via its catalog-ID iTunes lookup;
        // sid-284 ids are opaque, so there is no repair source — but the speaker
        // DOES settle. When the URI changes to an HLS-static track yet the title
        // is empty or unchanged (the leak signature), schedule one delayed
        // GetPositionInfo re-poll to pull the settled metadata. Gated to the leak
        // signature so a steady-state radio doesn't re-poll every song.
        if let newURI = metadata.trackURI,
           newURI != (existing.trackURI ?? ""),
           newURI.hasPrefix(URIPrefix.sonosApiHLSStatic) {
            let incomingTitle = metadata.title.trimmingCharacters(in: .whitespaces)
            let priorTitle = existing.title.trimmingCharacters(in: .whitespaces)
            if incomingTitle.isEmpty
               || incomingTitle.caseInsensitiveCompare(priorTitle) == .orderedSame {
                scheduleMetadataResettle(groupID: groupID, trackURI: newURI)
            }
        }

        if existing.trackNumber != metadata.trackNumber, metadata.trackNumber > 0 {
            retryDeferredRepairsIfPlaybackMoved(coordinatorID: groupID, from: existing.trackNumber,
                                                to: metadata.trackNumber)
        }

        // Recover track info from cache — Apple Music/service queue tracks
        // often return empty TrackMetaData from GetPositionInfo.
        // Position-based fallbacks blocked when actively playing a radio station
        // (has stationName + radio URI), to prevent stale queue metadata from leaking.
        // Apple Music queue tracks use x-sonosapi-hls-static URIs which look like radio
        // but have no stationName — so stationName is the reliable discriminator.
        var enriched = metadata
        // Recover when the speaker reports no title OR a technical filename —
        // direct-URL tracks (e.g. a Suno CDN `<uuid>.mp3`) report the file name
        // as the title; the real song name is in the play-time cache.
        if enriched.title.isEmpty || TrackMetadata.isTechnicalName(enriched.title) {
            var cached: TrackMetadataEnricher.CachedTrack?
            let isActiveRadio = !enriched.stationName.isEmpty &&
                                (enriched.trackURI.map(URIPrefix.isRadio) ?? false)

            // Try URI match first (both encoded and decoded) — always safe
            if let uri = enriched.trackURI, !uri.isEmpty {
                cached = enricher.cachedTrackInfo[uri]
                if cached == nil, let decoded = uri.removingPercentEncoding {
                    cached = enricher.cachedTrackInfo[decoded]
                }
            }

            // Queue position fallbacks — only valid when actually playing from
            // a queue. Direct-play tracks (browse → play, no queue) often report
            // trackNumber=1 from getPositionInfo and would otherwise inherit
            // title/artist/art from the last queue position 1.
            // isQueueSource is the reliable discriminator and is set by
            // enrichFromMediaInfo based on the speaker's CurrentURI.
            if cached == nil, !isActiveRadio, enriched.isQueueSource, enriched.trackNumber > 0 {
                cached = enricher.cachedTrackByPosition[groupID]?[enriched.trackNumber]
            }
            if cached == nil, !isActiveRadio, enriched.isQueueSource, enriched.trackNumber > 0,
               let queueItems = enricher.lastQueueItems[groupID] {
                let idx = enriched.trackNumber - 1
                if idx >= 0 && idx < queueItems.count {
                    let qi = queueItems[idx]
                    cached = TrackMetadataEnricher.CachedTrack(title: qi.title, artist: qi.artist, album: qi.album, artURL: qi.albumArtURI)
                }
            }

            if let cached {
                enriched.title = cached.title
                if enriched.artist.isEmpty { enriched.artist = cached.artist }
                if enriched.album.isEmpty { enriched.album = cached.album }
                if enriched.albumArtURI == nil { enriched.albumArtURI = cached.artURL }
            }
        }

        // Duration recovery. A bare queue row (an Apple Music row the
        // speaker could not resolve at enqueue) reports no length, and the
        // transport shows "Live" for a zero duration. Queue rows already
        // fill a missing length from play history; the playing track gets
        // the same source so a known song shows its time.
        if enriched.duration <= 0, enriched.isQueueSource, enriched.stationName.isEmpty,
           let learned = playHistoryManager?.learnedDuration(uri: enriched.trackURI, title: enriched.title,
                                                              artist: enriched.artist, album: enriched.album),
           learned > 0 {
            enriched.duration = learned
        }

        // Artwork recovery, independent of the title check above. Direct-URL
        // tracks (e.g. a Suno CDN MP3) frequently report a usable title but no
        // album art on the speaker's poll — without this, art that was already
        // showing gets blanked. Backfill from the play-time art cache.
        if enriched.albumArtURI == nil || enriched.albumArtURI?.isEmpty == true,
           let uri = enriched.trackURI {
            let art = enricher.cachedTrackInfo[uri]?.artURL
                ?? (uri.removingPercentEncoding.flatMap { enricher.cachedTrackInfo[$0]?.artURL })
            if let art, !art.isEmpty { enriched.albumArtURI = art }
        }
        // (Suno normalization already applied at the top of this method.)

        // Don't overwrite existing good metadata with empty or technical stream names
        // BUT only if the track hasn't changed (same URI = same track, just a poll update)
        let sameTrack = enriched.trackURI == existing.trackURI || enriched.trackURI == nil
        if !existing.title.isEmpty && sameTrack {
            let newTitle = enriched.title
            if newTitle.isEmpty || TrackMetadata.isTechnicalName(newTitle) {
                var merged = existing
                merged.position = enriched.position
                merged.duration = enriched.duration
                // Queue positions are 1-based, so 0 means "this update did
                // not report one" — not "row zero". Overwriting a known
                // position with the sentinel would let a trackNumber-less
                // update undo an authoritative resolution.
                if enriched.trackNumber > 0 {
                    merged.trackNumber = enriched.trackNumber
                }
                merged.trackURI = enriched.trackURI
                merged.isQueueSource = enriched.isQueueSource
                merged.queueSize = enriched.queueSize
                if !enriched.stationName.isEmpty {
                    merged.stationName = enriched.stationName
                }
                // Only accept new art if none is held. Plex rotates
                // `X-Plex-Token` on every poll; replacing the art URL here
                // triggers an image reload and flickers the UI for a track
                // already showing correctly.
                if merged.albumArtURI == nil || merged.albumArtURI?.isEmpty == true,
                   let newArt = enriched.albumArtURI, !newArt.isEmpty {
                    merged.albumArtURI = newArt
                }
                // Content-equality gate: skip the publish when only
                // position/duration drifted. The displayed-content view
                // tree (karaoke header, lyrics, ClubVis card) doesn't
                // care about per-poll position deltas — those live on
                // `PositionTracker`. Storing `merged` here without
                // republishing would only affect the snapshot value
                // anyone reads from `groupTrackMetadata`, so the write is
                // skipped outright when content matches.
                let existingMeta = groupTrackMetadata[groupID]
                if existingMeta == nil || !(existingMeta?.contentEquals(merged) ?? false) {
                    tagPublish("metadata")
                    groupTrackMetadata[groupID] = merged
                }
                return
            }
        }

        var updated = enriched

        // Detect if the track actually changed.
        //
        // For queued playback (Apple Music, Spotify, local library, etc.)
        // the trackURI is unique per song, so a URI change = a song change.
        //
        // For RADIO STREAMS the trackURI is the station's stream URL —
        // it stays identical for the whole listening session while
        // different songs play through it. The signal that a song
        // changed within a stream is the title (and usually artist)
        // changing in the streamContent payload. Without this, the
        // merge logic below would see `trackChanged=false` for every
        // intra-stream song change and inherit the previous song's
        // artist/album whenever Sonos's next event arrives with those
        // fields empty (a routine occurrence — radio metadata events
        // are partial, not snapshots).
        let trackChanged: Bool = {
            if updated.trackURI != existing.trackURI && updated.trackURI != nil {
                return true
            }
            let onRadio = !existing.stationName.isEmpty || !updated.stationName.isEmpty ||
                          (updated.trackURI.map(URIPrefix.isRadio) ?? false)
            guard onRadio else { return false }
            let newTitle = updated.title.trimmingCharacters(in: .whitespaces)
            let oldTitle = existing.title.trimmingCharacters(in: .whitespaces)
            // Only treat as a song change when the new title is real
            // and differs from the previous one. Empty / technical /
            // unchanged titles fall through to the "same song" path so
            // mid-song polls with sparse DIDL don't masquerade as a
            // transition and clobber the displayed metadata.
            guard !newTitle.isEmpty,
                  !TrackMetadata.isTechnicalName(newTitle),
                  newTitle.caseInsensitiveCompare(oldTitle) != .orderedSame
            else { return false }
            return true
        }()

        // Carry forward station name unless the source actually changed.
        // Clear station name when playing from queue (isQueueSource) — Apple Music
        // queue tracks use x-sonosapi-hls-static URIs that look like radio but aren't.
        if updated.isQueueSource {
            updated.stationName = ""
        } else if updated.stationName.isEmpty && !existing.stationName.isEmpty {
            // Always inherit the station name across intra-stream song
            // changes — the user is still on the same station and the
            // streamContent payload only carries the song fields.
            updated.stationName = existing.stationName
        }

        // Preserve enriched artist/album across polls. Apple Music HLS-static
        // favorites send sparse DIDL with an empty artist on every transport
        // poll; a one-shot iTunes lookup fills it in, but the next
        // poll would otherwise overwrite that with empty (or the original
        // album-shaped junk) again. As long as the track is unchanged:
        //   - An empty incoming field never wins over a non-empty existing.
        //   - An album-shaped incoming "artist" never wins over a clean one
        //     (defends against Sonos's `dc:creator = album` quirk).
        //
        // Skipped on radio song changes — the per-song fields (artist,
        // album, albumArtURI) belonged to the *previous* song and must
        // not bleed into the new one. Whatever the new event contains
        // (even if empty) is authoritative.
        if !trackChanged {
            let incomingArtistIsSuspect = Self.isAlbumShapedArtist(updated.artist)
            if (updated.artist.isEmpty || incomingArtistIsSuspect) && !existing.artist.isEmpty
               && !Self.isAlbumShapedArtist(existing.artist) {
                updated.artist = existing.artist
            }
            if updated.album.isEmpty && !existing.album.isEmpty {
                updated.album = existing.album
            }
        } else {
            // Radio song change — clear stale per-song art so a new
            // event with no albumArtURI doesn't keep displaying the
            // previous song's cover. Station logo still resolves via
            // ArtResolver.radioStationArtURL.
            if updated.albumArtURI == nil || updated.albumArtURI?.isEmpty == true {
                updated.albumArtURI = nil
            }
        }

        // Art resolution is owned by `ArtResolver` (app side); this layer
        // passes the speaker's reported art through unchanged. Substituting
        // cached art here competes with the view-side resolver and flickers
        // when the two caches disagree (e.g. Plex tracks with multiple
        // iTunes matches).
        // Persist audioFormat across event-to-event rebuilds. The
        // speaker only includes `r:streamInfo` (where the Dolby/Atmos
        // flag lives) in TRANSITIONING-state events at track start;
        // subsequent steady-state polls and events arrive with the tag
        // missing, so a freshly-constructed `TrackMetadata` defaults to
        // `.unknown`. Without this carry-over a track briefly badged
        // `.atmos` on transition would lose the badge a second later.
        if !trackChanged, updated.audioFormat == .unknown,
           existing.audioFormat != .unknown {
            updated.audioFormat = existing.audioFormat
            updated.streamInfoRaw = existing.streamInfoRaw
        }
        // The carry-over above only survives same-track rebuilds. A
        // transient bogus publish (#47-class HLS-static leak: a stray
        // song id with flags=0 flashes in and back) makes the
        // flip-back a track CHANGE, and streamInfo is only broadcast
        // at transitions — the returning track would stay `.unknown`
        // for its remainder. Format evidence is remembered per URI and
        // restored on any flip-back.
        if updated.audioFormat == .unknown, let uri = updated.trackURI,
           let remembered = groupFormatMemory.recall(group: groupID, uri: uri) {
            updated.audioFormat = remembered.format
            updated.streamInfoRaw = remembered.streamInfo
        } else if let uri = updated.trackURI {
            groupFormatMemory.remember(group: groupID, uri: uri,
                                       format: updated.audioFormat,
                                       streamInfo: updated.streamInfoRaw)
        }
        // Same sticky-carry-over for the TV/HDMI audio format. Only
        // `fetchGroupState` (reconciliation poll) repopulates it from
        // `DeviceProperties.GetZoneInfo`; per-tick event-driven
        // rebuilds otherwise reset the field to `.unknown` and the UI
        // pill would flicker between updates.
        if !trackChanged, updated.tvAudioFormat == .unknown,
           existing.tvAudioFormat != .unknown {
            updated.tvAudioFormat = existing.tvAudioFormat
        }

        // On a real track change, write a single diagnostic line
        // recording the audio format the speaker reported for the
        // incoming track. Surfaces in the bug-report bundle so users
        // who file "the Atmos badge didn't show on track X" reports
        // include the wire evidence (or its absence). Skipped for
        // mid-track refreshes — once per track is enough.
        if trackChanged, !updated.title.isEmpty {
            let trackLabel = updated.artist.isEmpty
                ? updated.title
                : "\(updated.artist) — \(updated.title)"
            let isHTSource = (updated.trackURI?.contains("x-sonos-htastream:") ?? false)
                || (updated.trackURI?.contains("x-rincon-stream:") ?? false)
            let formatLabel: String
            if isHTSource {
                formatLabel = "tv:\(updated.tvAudioFormat.rawValue)"
            } else {
                formatLabel = "stream:\(updated.audioFormat.rawValue)"
            }
            sonosDiagLog(.info, tag: "PLAYBACK",
                         "Track started: \(trackLabel) [\(formatLabel)]",
                         context: [
                            "groupID": groupID,
                            "trackURI": updated.trackURI ?? "",
                            "audioFormat": updated.audioFormat.rawValue,
                            "tvAudioFormat": updated.tvAudioFormat.rawValue
                         ])
        }

        // Content-equality gate: see `merged` write above. Position-only
        // drift (every 1 Hz poll) must not re-evaluate every observing
        // view; the check pins the publish to actual content changes
        // (track / album art / station / format flip).
        let existingMeta = groupTrackMetadata[groupID]
        let changed = existingMeta == nil || !(existingMeta?.contentEquals(updated) ?? false)
        if changed {
            tagPublish("metadata")
            groupTrackMetadata[groupID] = updated
        }

        // Record the delivery format on every content publish — track
        // changes AND late format decodes (streamInfo often settles
        // after track start, and the sticky carry-over above keeps it
        // attached). Covers normal audio: HDMI sources are skipped
        // inside the observer, which records them via HTAudioIn.
        if changed, !updated.title.isEmpty,
           let uri = updated.trackURI, !uri.isEmpty {
            AudioFormatObserver.shared.recordTrack(
                uri: uri,
                streamInfo: updated.streamInfoRaw,
                audioFormat: updated.audioFormat,
                room: devices[groupID]?.roomName ?? "")
        }

        // Log to play history for all groups — only when the metadata
        // actually changed, since play-history needs distinct events.
        if changed, let group = groups.first(where: { $0.coordinatorID == groupID || $0.id == groupID }) {
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
        // lookup. Mirrored here with a one-shot iTunes lookup by track ID,
        // rate-limited so it can't tip iTunes into 403.
        enrichAppleMusicArtistIfNeeded(groupID: groupID, metadata: updated)
    }

    /// Schedules a single delayed GetPositionInfo re-poll for a group whose
    /// HLS-static track just transitioned with stale/empty metadata (issue #69).
    /// At most once per `trackURI`; the handler no-ops unless the speaker has
    /// since settled to a real, different title for the same track.
    private func scheduleMetadataResettle(groupID: String, trackURI: String) {
        guard metadataResettleURI[groupID] != trackURI else { return }
        metadataResettleURI[groupID] = trackURI
        metadataResettleTasks[groupID]?.cancel()
        metadataResettleTasks[groupID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.metadataResettleDelay)
            await self?.performMetadataResettle(groupID: groupID, trackURI: trackURI)
        }
    }

    private func performMetadataResettle(groupID: String, trackURI: String) async {
        guard let group = groups.first(where: { $0.coordinatorID == groupID || $0.id == groupID }),
              let coordinator = group.coordinator else { return }
        // Bail if the track moved on during the wait.
        guard (groupTrackMetadata[groupID]?.trackURI ?? "") == trackURI else { return }
        guard let fresh = try? await avTransport.getPositionInfo(device: coordinator),
              (fresh.trackURI ?? "") == trackURI else { return }
        let freshTitle = fresh.title.trimmingCharacters(in: .whitespaces)
        let shownTitle = (groupTrackMetadata[groupID]?.title ?? "").trimmingCharacters(in: .whitespaces)
        // Only act once the speaker has settled to a real, distinct title —
        // otherwise the merge would be a no-op (or re-commit the same leak).
        guard !freshTitle.isEmpty,
              !TrackMetadata.isTechnicalName(freshTitle),
              freshTitle.caseInsensitiveCompare(shownTitle) != .orderedSame else { return }
        sonosDiagLog(.info, tag: "PLAYBACK",
                     "HLS-static metadata re-poll settled the title (issue #69)",
                     context: ["groupID": groupID, "trackURI": trackURI])
        transportDidUpdateTrackMetadata(groupID, metadata: fresh, source: .poll)
    }

    private func enrichAppleMusicArtistIfNeeded(groupID: String, metadata: TrackMetadata) {
        // Fires for every Apple Music URI that carries a catalog song
        // ID. Two situations it covers:
        //   1. HLS-favorite DIDLs with empty / album-shaped artist.
        //   2. HLS-static playback where Sonos's reported text leaks
        //      stale title/artist from the previous track but the URI
        //      carries the correct catalog ID. iTunes is authoritative
        //      for that ID, so the lookup result overrides the speaker's
        //      reported title/artist.
        guard let uri = metadata.trackURI, !uri.isEmpty else { return }
        guard let songID = URIPrefix.appleMusicSongID(from: uri) else { return }

        // Persistent cache: subsequent plays of the same track skip the
        // network call. Entries lacking `title` / `artURL` are treated as
        // a miss so the catalog text/art override gets populated.
        let cacheKey = MetadataCacheRepository.Kind.appleMusicTrack.key(songID)
        if let cached = metadataCacheForAppleMusic?.get(cacheKey),
           let data = cached.data(using: .utf8),
           let payload = try? JSONDecoder().decode(AppleMusicTrackEnrichment.self, from: data),
           payload.title != nil {
            applyAppleMusicEnrichment(groupID: groupID, uri: uri, payload: payload, source: "cache")
            // An entry written before the length was recorded serves the
            // text now and is refreshed once when the speaker has no
            // length either; otherwise it is complete.
            if payload.durationSeconds != nil || metadata.duration > 0 { return }
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
            // protection covers this lookup too, on the `.nowPlaying` lane:
            // the artwork pipeline can hold the background share of the
            // window for minutes at a time (every relaunch re-pins art
            // across the queue), and this lookup is what gives a bare
            // Apple Music row its title and length while it plays. The
            // retries cover a window the reserved slots have already been
            // spent in; the transport does not call back in while a track
            // plays on unchanged, so one denied attempt used to be the only
            // attempt for that play.
            var fetched: (Data, URLResponse)?
            for attempt in 0..<4 {
                if attempt > 0 {
                    try? await Task.sleep(nanoseconds: 25_000_000_000)
                    let stillPlaying = await MainActor.run { [weak self] in
                        self?.groupTrackMetadata[groupID]?.trackURI == uri
                    }
                    guard stillPlaying == true else { return }
                }
                fetched = await ITunesRateLimiter.shared.perform(url: url, session: URLSession.shared, maxWait: 5, lane: .nowPlaying)
                if fetched != nil { break }
            }
            guard let (data, _) = fetched else { return }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]],
                  let first = results.first,
                  let artistName = first["artistName"] as? String,
                  !artistName.isEmpty else { return }
            let albumName = first["collectionName"] as? String
            let trackName = first["trackName"] as? String
            // Upscale 100→600 the same way `AlbumArtSearchService` does.
            let artURL = (first["artworkUrl100"] as? String)
                .map { $0.replacingOccurrences(of: "100x100", with: "600x600") }
            let millis = first["trackTimeMillis"] as? Double
            let durationSeconds = millis.map { ($0 / 1000).rounded() }.flatMap { $0 > 0 ? $0 : nil }

            let payload = AppleMusicTrackEnrichment(
                artist: artistName, album: albumName,
                title: trackName, artURL: artURL,
                durationSeconds: durationSeconds
            )

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

    /// Writes catalog-authoritative fields onto `groupTrackMetadata[groupID]`
    /// when the track URI still matches. Title and artist override
    /// unconditionally (catalog ID is the source of truth — speaker text
    /// metadata can leak from the previous track on HLS-static
    /// transitions). Album fills only when empty (legitimate Deluxe /
    /// Standard variations exist, so Sonos's value is preserved
    /// when it's already present). Art URL fills only when empty or
    /// when the current value is a `/getaa?` proxy (the proxy is flaky
    /// for HLS and the iTunes URL is more reliable).
    private func applyAppleMusicEnrichment(groupID: String, uri: String,
                                           payload: AppleMusicTrackEnrichment, source: String) {
        guard var meta = groupTrackMetadata[groupID] else { return }
        guard meta.trackURI == uri else { return }

        var changed = false
        // Reclaim a misplaced album label before overwriting the artist.
        let existingArtistIsAlbum = Self.isAlbumShapedArtist(meta.artist)
        if existingArtistIsAlbum && meta.album.isEmpty {
            meta.album = meta.artist
            changed = true
        }
        if let title = payload.title, !title.isEmpty, meta.title != title {
            meta.title = title
            changed = true
        }
        if !payload.artist.isEmpty, meta.artist != payload.artist {
            meta.artist = payload.artist
            changed = true
        }
        if meta.album.isEmpty, let albumName = payload.album, !albumName.isEmpty {
            meta.album = albumName
            changed = true
        }
        if let art = payload.artURL, !art.isEmpty {
            let currentArt = meta.albumArtURI ?? ""
            if currentArt.isEmpty || currentArt.contains("/getaa?") {
                meta.albumArtURI = art
                changed = true
            }
        }
        // Length fills only when the speaker reported none: its own value
        // is authoritative when present, and a zero here reads as "Live".
        if meta.duration <= 0, let seconds = payload.durationSeconds, seconds > 0 {
            meta.duration = seconds
            changed = true
        }
        if changed {
            groupTrackMetadata[groupID] = meta
            sonosDebugLog("[ENRICH] Apple Music \(source) → \(payload.title ?? "?") / \(payload.artist) / \(payload.album ?? "?")")
        }
    }

    /// Returns true when an "artist" string is actually an album label —
    /// Sonos occasionally writes the album into `<dc:creator>` for HLS
    /// favorites. Mirrors the suffix list from `MusicMetadataService`
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
    /// Detects technical stream names that should not replace friendly titles.
    /// e.g. "moviesoundtracks_mobile_mp3", "s233145", "stream_128k"

    public func transportDidUpdateTransportActions(_ groupID: String, actions: TransportActions) {
        if groupTransportActions[groupID] != actions {
            tagPublish("transportActions")
            groupTransportActions[groupID] = actions
        }
    }

    public func transportDidUpdatePlayMode(_ groupID: String, mode: PlayMode) {
        let now = Date()
        if let grace = modeGraceUntils[groupID], now < grace { return }
        updatePlayMode(groupID, mode: mode)
    }



    /// True when `deviceID` is the coordinator of any current group.
    /// Used to gate optimistic propagation and verifier scheduling so
    /// only fast, reliable coordinator events drive group-level
    /// reactions.
    private func isGroupCoordinator(deviceID: String) -> Bool {
        groups.contains { $0.coordinatorID == deviceID }
    }






    public func transportDidUpdateTopology(_ groupData: [ZoneGroupData]) {
        // Topology changed via event — apply it, then react.
        topology.applyEventTopology(groupData)
        saveCache()

        // Notify transport strategy about topology change
        Task {
            await transportStrategy?.onGroupsChanged(groups, devices: devices)
        }
    }

    public func transportDidUpdatePosition(_ groupID: String, position: TimeInterval, duration: TimeInterval) {
        let now = Date()
        if let grace = positionGraceUntils[groupID], now < grace { return }
        // Position + duration live on `positionTracker` (own publisher), so
        // views observing only the manager don't re-evaluate per 1 Hz poll.
        if positionTracker.groupPositions[groupID] != position {
            positionTracker.groupPositions[groupID] = position
        }
        if positionTracker.groupDurations[groupID] != duration {
            positionTracker.groupDurations[groupID] = duration
        }
        // Drive the shared anchor too. Skip while user is dragging the
        // seek bar — the slider would otherwise fight the pre-drag
        // position reports the speaker is still emitting.
        if coordinatorBeingDragged != groupID {
            let isPlaying = groupTransportStates[groupID]?.isPlaying ?? false
            updatePositionAnchorFromAuthoritative(coordinatorID: groupID,
                                                  position: position,
                                                  isPlaying: isPlaying,
                                                  at: now)
        }
    }

    // MARK: - Position anchor: authoritative updates (single source of truth)

    /// Drift-tolerant rebase from a speaker-reported position. One anchor
    /// shared by every consumer (panel + karaoke window) so they cannot drift apart.
    private func updatePositionAnchorFromAuthoritative(coordinatorID: String,
                                                       position: TimeInterval,
                                                       isPlaying: Bool,
                                                       at: Date) {
        let current = anchorTracker.groupPositionAnchors[coordinatorID] ?? .zero
        let wasUninitialised = current.wallClock == .distantPast
        let playingFlipped = current.isPlaying != isPlaying
        if wasUninitialised || playingFlipped {
            anchorTracker.groupPositionAnchors[coordinatorID] = PositionAnchor(time: max(0, position),
                                                                 wallClock: at,
                                                                 isPlaying: isPlaying)
            return
        }
        let projected = current.projected(at: at)
        let drift = position - projected
        let shouldRebase = drift >= Self.forwardRebaseThreshold
            || drift <= -Self.backwardRebaseThreshold
        if shouldRebase {
            anchorTracker.groupPositionAnchors[coordinatorID] = PositionAnchor(time: max(0, position),
                                                                 wallClock: at,
                                                                 isPlaying: isPlaying)
        }
        // Otherwise leave it alone — the wall-clock projection is
        // advancing monotonically and overwriting on every poll's
        // sub-second skew would produce visible jitter.
    }

    /// Pause/resume hook. Preserves the currently-projected position
    /// so resume picks up exactly where pause left off without drifting
    /// forward by the duration of the pause.
    private func updatePositionAnchorPlayingState(coordinatorID: String,
                                                  isPlaying: Bool,
                                                  at: Date = Date()) {
        let current = anchorTracker.groupPositionAnchors[coordinatorID] ?? .zero
        guard current.isPlaying != isPlaying else { return }
        let frozenAt = current.projected(at: at)
        anchorTracker.groupPositionAnchors[coordinatorID] = PositionAnchor(time: frozenAt,
                                                             wallClock: at,
                                                             isPlaying: isPlaying)
    }

    /// Explicit anchor write — used for seeks and the rare hard-reset
    /// paths where the caller already has an authoritative time.
    /// Bypasses drift thresholds.
    public func setPositionAnchor(coordinatorID: String, _ anchor: PositionAnchor) {
        anchorTracker.groupPositionAnchors[coordinatorID] = anchor
    }

    /// Mark/unmark the seek bar as being dragged. While set, authoritative
    /// position reports won't rebase the anchor — the user is in control.
    /// Pass `nil` to clear.
    public func setPositionDragInProgress(coordinatorID: String?) {
        coordinatorBeingDragged = coordinatorID
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
    public func transportRequestsTopologyRefresh(originDeviceID: String) {
        // Prefer the device that fired the topology event — its
        // self-reported `GetZoneGroupState` is consistent with the change
        // it just published. Fall back to any known device only if the
        // originator isn't cached yet (newly-discovered speaker
        // whose first event arrives before SSDP description fetch
        // completes).
        let device = devices[originDeviceID]
            ?? groups.first?.coordinator
            ?? devices.values.first
        guard let device else { return }
        Task {
            await refreshTopology(from: device, force: true)
        }
    }

    public func transportDidObserveQueueChange(_ groupID: String) {
        // The Apple Music metadata repair walker generates two Q:0 events
        // per row (insert + remove) with a NET-ZERO visible result in this
        // app (titles already shown from the session cache). Reloading on
        // each made the queue panel blink for the whole repair; suppress
        // reloads while the walker runs — it posts one final reload when
        // it finishes.
        if queue.queueRepairActiveGroups.contains(groupID) { return }
        // ContentDirectory `Q:0` event fired. Hand off to the same
        // notification path the optimistic-update sites use so
        // QueueView's existing `onReceive(.queueChanged)` does the
        // `Browse(Q:0)` reload. Empty `optimisticItems` ⇒ subscribers
        // perform a full refresh.
        enricher.postQueueChanged(optimisticItems: [])
    }
}

// MARK: - Collaborator callbacks (protocol conformances)

extension SonosManager: NowPlayingTitlePatching, QueueSnapshotting, QueueRowRepairing,
                        NowPlayingContextProviding, BrowseSectionContributing,
                        MediaServerHostProviding {

    public func knownMediaServerHosts() -> [String] {
        mediaServers.compactMap { $0.baseURL.host }
    }


    /// What a group is playing, for the portable-speaker volume diagnostic.
    public func nowPlayingContext(forCoordinator coordinatorID: String) -> (trackURI: String, state: String)? {
        (trackURI: groupTrackMetadata[coordinatorID]?.trackURI ?? "?",
         state: groupTransportStates[coordinatorID]?.rawValue ?? "?")
    }

    /// Sonos cannot browse media servers at all, so they sit alongside the
    /// speaker's own sources rather than replacing them, and disappear when the
    /// server stops answering.
    public func contributedBrowseSections() -> [BrowseSection] {
        mediaServers.map { server in
            BrowseSection(id: "mediaserver-\(server.id)",
                          title: server.name,
                          objectID: "MS:\(server.id)/0",
                          icon: "externaldrive.badge.wifi",
                          availabilityNote: server.advertisedHostMismatch == nil ? nil : L10n.checkNetwork)
        }
    }

    /// Applied when a Suno title resolves after the row was already playing.
    /// Lives here because now-playing rows are transport state; the enricher
    /// only knows a title arrived.
    public func patchNowPlayingTitle(_ title: String, forSunoUUID uuid: String) {
        for (gid, md) in groupTrackMetadata
        where md.trackURI.flatMap({ SunoCatalog.uuid(fromURI: $0) }) == uuid {
            var m = md
            m.title = title
            groupTrackMetadata[gid] = m
        }
    }
}

// MARK: - Protocol Conformances (ISP)

/// The transport-coupled queue half plus the saved-queue surface; queue
/// mechanics live on `QueueController`.
extension SonosManager: QueueServiceProtocol {}

// SonosManager conforms to segregated protocols so ViewModels depend on
// narrow interfaces instead of the full 121-method class.

extension SonosManager: PlaybackServiceProtocol {}
extension SonosManager: VolumeServiceProtocol {}
extension SonosManager: BrowsingServiceProtocol {}
extension SonosManager: GroupingServiceProtocol {}
extension SonosManager: AlarmServiceProtocol {}
extension SonosManager: MusicServiceDetectionProtocol {}
extension SonosManager: TransportStateProviding {
    public func updateTransportState(_ groupID: String, state: TransportState) {
        // Equality gate: every event/poll tick calls this, and an
        // ungated write dirties the dictionary for Observation even
        // when the value is unchanged — re-rendering every view that
        // reads any group's transport state, dozens of times a second.
        guard groupTransportStates[groupID] != state else { return }
        tagPublish("transport")
        groupTransportStates[groupID] = state
        groupTransportStatePublisher.send(groupTransportStates)
        // Keep the shared playhead anchor in step with play/pause so
        // every consumer freezes/resumes the projection together.
        updatePositionAnchorPlayingState(coordinatorID: groupID,
                                         isPlaying: state.isPlaying)
        plexPlaybackReporter?.transportChanged(coordinatorID: groupID, state: state,
                                               trackURI: groupTrackMetadata[groupID]?.trackURI,
                                               room: roomLabel(forCoordinator: groupID))
    }

    /// Plex reporting keys off the track URI, whichever write path set
    /// it (event merge, launch fetch, play command, enrichment); the
    /// event-merge hook alone misses a group's first metadata.
    /// One trackURI comparison per group per write.
    private func notifyPlexReporterOfTrackChanges(from old: [String: TrackMetadata]) {
        guard let reporter = plexPlaybackReporter else { return }
        for (id, meta) in groupTrackMetadata where meta.trackURI != old[id]?.trackURI {
            reporter.trackChanged(coordinatorID: id,
                                  trackURI: meta.trackURI,
                                  room: roomLabel(forCoordinator: id),
                                  state: groupTransportStates[id] ?? .stopped)
        }
    }

    /// Group name when topology knows the coordinator, else its room.
    private func roomLabel(forCoordinator id: String) -> String {
        groups.first(where: { $0.coordinatorID == id || $0.id == id })?.name
            ?? devices[id]?.roomName ?? ""
    }

    /// The coordinator's shared playhead anchor; nil when none is set.
    public func positionAnchor(coordinatorID: String) -> PositionAnchor? {
        anchorTracker.groupPositionAnchors[coordinatorID]
    }

    public func updatePlayMode(_ groupID: String, mode: PlayMode) {
        guard groupPlayModes[groupID] != mode else { return }
        tagPublish("playMode")
        groupPlayModes[groupID] = mode
    }



    /// The speaker has confirmed playback for this coordinator: it is playing
    /// and nothing is pending. Both writes are equality-gated and tagged.
    public func confirmPlaying(coordinator: String) {
        updateTransportState(coordinator, state: .playing)
        updateAwaitingPlayback(coordinator, awaiting: false)
    }

    /// A play command has been sent and the speaker has not yet confirmed.
    public func beginAwaitingPlayback(coordinator: String) {
        updateAwaitingPlayback(coordinator, awaiting: true)
    }

    /// Nothing is pending for this coordinator any more — the command
    /// completed, failed, or the queue it targeted is gone.
    public func clearAwaitingPlayback(coordinator: String) {
        updateAwaitingPlayback(coordinator, awaiting: false)
    }

    public func updateAwaitingPlayback(_ groupID: String, awaiting: Bool) {
        if awaitingPlayback[groupID] != awaiting {
            tagPublish("awaiting")
            awaitingPlayback[groupID] = awaiting
        }
    }
}
extension SonosManager: ArtCacheProtocol {}
