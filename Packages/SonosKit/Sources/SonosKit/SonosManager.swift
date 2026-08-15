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
import Network

private let debugLogPath: String = {
    AppPaths.appSupportDirectory.appendingPathComponent("sonos_debug.log").path
}()

/// Serial background queue for log writes. Previously `sonosDebugLog`
/// did 4 synchronous syscalls (`open`/`seek`/`write`/`close`) on the
/// calling thread per log line. Combined with RC-EVENT volume polling
/// (~50 lines/second across all rooms) and per-frame STUTTER logging,
/// this saturated the main thread and caused the very stutter the
/// instrumentation was meant to capture — stutter logs that caused
/// stutter that caused more stutter logs. Writes now dispatch to this
/// utility-QoS serial queue; ordering is preserved (serial), the
/// caller returns immediately, and frame work is no longer blocked
/// on disk I/O.
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
public class SonosManager: ObservableObject {
    // MARK: - Published State

    @Published public var groups: [SonosGroup] = []
    @Published public var devices: [String: SonosDevice] = [:]

    /// Weak global handle to the most recently constructed manager.
    /// Used by `AppIntents` (Shortcuts / Spotlight / Siri actions) to
    /// reach the live manager without going through the SwiftUI
    /// environment — intents run in code paths that don't have access
    /// to `@EnvironmentObject`. Set from `ChoragusApp` at first
    /// appearance; cleared automatically when the manager deinits.
    nonisolated(unsafe) public static weak var current: SonosManager?
    @Published public var isDiscovering = false
    @Published public var browseSections: [BrowseSection] = []
    /// Per-system local-library availability, keyed by householdID. Drives the
    /// (S1/S2) browse tags and the fail-fast playback gate. Refreshed from a
    /// live `Browse("S:")` per system after topology settles.
    @Published public private(set) var householdCapabilities: [String: HouseholdCapabilities] = [:]
    @Published public var musicServicesList: [MusicService] = []

    /// Live track count during a large queue add. BrowseViewModel
    /// updates this as it walks a deep local-library hierarchy; the
    /// queue panel reads it to render "Adding N tracks…" instead of a
    /// blank spinner. Resets to 0 when no add is in flight.
    @Published public var addingToQueueProgress: Int = 0

    /// SMAPI media-URI resolver. Wired at app startup to
    /// `SMAPIAuthManager.resolveMediaURI`. The direct-play branch
    /// invokes this for any `x-sonosapi-stream:` URI before calling
    /// `SetAVTransportURI` so the speaker receives the resolved direct
    /// stream URL (the only shape current Sonos firmware accepts via
    /// the AVTransport service for SMAPI radio).
    public var smapiURIResolver: ((_ sid: Int, _ itemID: String) async throws -> String?)?

    // Cache state — drives the "Using cached data" banner in ContentView
    @Published public var isUsingCachedData = false
    @Published public var cacheAge: String = ""
    @Published public var isRefreshing = false
    @Published public var staleMessage: String?
    /// Non-fatal advisory shown when the network path is flapping between
    /// interfaces (a dual-interface Mac oscillating Wi-Fi ⇄ Ethernet). Set by
    /// the transport path monitor; user-dismissable. Distinct from
    /// `staleMessage` so it doesn't pre-empt a real stale-data banner.
    @Published public var networkAdvisory: String?

    // MARK: - Transport State (centralized, updated by transport strategy)

    /// Per-group playback state, keyed by group ID
    @Published public var groupTransportStates: [String: TransportState] = [:]
    @Published public var groupTrackMetadata: [String: TrackMetadata] = [:]
    /// Format evidence per recent track URI — restores audioFormat /
    /// streamInfoRaw when a transient bogus publish interrupts a track
    /// and the flip-back arrives as a "new" track with `.unknown`
    /// (see the restore site in the metadata merge).
    private var groupFormatMemory = AudioFormatMemory()
    @Published public var groupPlayModes: [String: PlayMode] = [:]
    /// High-churn playhead state lives on dedicated publishers rather
    /// than directly on this class — see `PositionTrackers.swift`.
    /// `groupPositions`/`groupDurations` update ~1 Hz; `anchors` rebases
    /// only on drift / play-state / seek. Views observe whichever
    /// publisher matches their churn tolerance (the karaoke window
    /// observes only `anchorTracker` so per-second position polls don't
    /// trigger 70 ms body re-evals on every tick).
    ///
    /// The old `groupPositions` / `groupDurations` / `groupPositionAnchors`
    /// names are kept below as computed-forwarder properties for the
    /// existing read-side consumers (NowPlayingViewModel, protocols,
    /// etc.) so the call sites don't have to change.
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
    @Published public private(set) var isAddingToQueue: Bool = false

    /// Overlap-safe depth behind `isAddingToQueue`. Two concurrent adds
    /// previously shared the single Bool — the first to finish cleared
    /// the flag while the second was still running. The published Bool
    /// stays as the UI-facing property; all writers go through
    /// `beginAddingToQueue` / `endAddingToQueue`.
    private var addingToQueueDepth = 0

    public func beginAddingToQueue() {
        addingToQueueDepth += 1
        if !isAddingToQueue { isAddingToQueue = true }
    }

    public func endAddingToQueue() {
        addingToQueueDepth = max(0, addingToQueueDepth - 1)
        if addingToQueueDepth == 0, isAddingToQueue { isAddingToQueue = false }
    }

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

    /// Per-group debounced volume verifier tasks. When the coordinator's
    /// volume event fires, a single GetVolume fan-out for the group's
    /// non-coord members is scheduled ~500 ms later; further coord events
    /// for the same group cancel and reschedule. Bounds wire cost during
    /// slider drag — one GetVolume per member per coalesced action, not
    /// per intermediate slider tick.
    private var groupVolumeVerifyTasks: [String: Task<Void, Never>] = [:]

    /// Per-group debounced mute verifier tasks. Mirrors the volume verifier
    /// pattern: after `propagateMuteOptimistically` flips the dict for instant
    /// UI feedback, a debounced GetMute fan-out polls each member's actual
    /// state and corrects the dict for members that don't follow the
    /// coordinator's group-mute round-trip — bonded stereo pairs and HT zones
    /// keep independent mute state at the speaker level even when the
    /// coordinator unmutes, and without this verifier the optimistic
    /// propagation leaves the dict permanently desynced from speaker reality
    /// (root cause of the "tap-mute-keeps-muting" bug for bonded primaries).
    private var groupMuteVerifyTasks: [String: Task<Void, Never>] = [:]

    /// Per-device debounced verifier tasks for our own outbound writes.
    /// Every `setMute` / `setVolume` schedules one of these; if another write
    /// for the same device happens within 500 ms, the prior task is cancelled
    /// (drag/multi-tap coalescing). After the quiet window, a real GetMute /
    /// GetVolume runs and the result is reconciled into the dict — making the
    /// speaker the source of truth even when the dict was set optimistically
    /// by `toggleMute` / `setSpeakerMute` and the speaker silently rejected
    /// the SOAP (bonded stereo pair primaries observed to do this for
    /// SetMute when the bonded set's hardware-mute is in a particular state).
    private var deviceMuteVerifyTasks: [String: Task<Void, Never>] = [:]
    private var deviceVolumeVerifyTasks: [String: Task<Void, Never>] = [:]

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
    /// `tunein-ondemand.cdnstream1.com`. Multiple 2024–2025 Sonos
    /// Community threads describe the same loop on the official app —
    /// it is a Sonos-side issue, not a controller bug. Tracking each
    /// group's current ad URI lets us log a single WARNING on entry
    /// (so the diagnostic bundle pinpoints why a station "won't
    /// advance") and INFO on exit (so the user can confirm the ad
    /// finished).
    private var groupTuneInAdLoopURI: [String: String] = [:]

    /// Value-aware echo absorption for our own SOAP writes.
    ///
    /// Replaces the old `*GraceUntils` time-window approach, which silently
    /// dropped *every* RC NOTIFY for the device for the full grace duration —
    /// including legitimate Sonos-app changes the user made during that
    /// window. Captured logs showed up to 5 external mute toggles being
    /// swallowed during a 10 s window, then flooding in at once when grace
    /// expired (visible to the user as a delayed flip-flop cascade).
    ///
    /// Each `setMute` / `setVolume` enqueues `(value, deadline)` for the
    /// target device. An inbound RC NOTIFY consumes the earliest matching
    /// queue entry FIFO; entries past their deadline are pruned. Events
    /// whose value doesn't match any pending write — i.e. real external
    /// changes — flow through to the normal apply path immediately.
    private var expectedMuteEchoes: [String: [(value: Bool, deadline: Date)]] = [:]
    private var expectedVolumeEchoes: [String: [(value: Int, deadline: Date)]] = [:]
    private static let echoExpectationWindow: TimeInterval = 5.0
    private static let echoQueueCap = 32

    /// Coordinator ID currently being dragged in the seek bar UI. Set
    /// by `NowPlayingViewModel` on drag-start; cleared on drag-end.
    /// Suppresses anchor rebases from authoritative position reports
    /// while the user is scrubbing — otherwise the slider would fight
    /// the speaker's still-pre-drag position reports.
    private var coordinatorBeingDragged: String?

    // MARK: - Position anchor thresholds
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

    @Published public var discoveryMode: DiscoveryMode {
        didSet {
            UserDefaults.standard.set(discoveryMode.rawValue, forKey: UDKey.discoveryMode)
            Task { @MainActor in await switchDiscoveryTransports() }
        }
    }

    @Published public var appearanceMode: AppearanceMode {
        didSet { UserDefaults.standard.set(appearanceMode.rawValue, forKey: UDKey.appearanceMode) }
    }

    /// Karaoke window's own theme — independent of the main `appearanceMode`.
    /// Defaults to `.dark` (see `UDKey.karaokeAppearanceMode` for rationale).
    @Published public var karaokeAppearanceMode: AppearanceMode {
        didSet { UserDefaults.standard.set(karaokeAppearanceMode.rawValue, forKey: UDKey.karaokeAppearanceMode) }
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
    /// Device IDs whose first discovery this app session has already
    /// driven a topology refresh. Distinct from `discoveredLocations`
    /// (which is cleared every 30 s by the SSDP rescan timer) and from
    /// `devices` (which is pre-populated from the persisted cache at
    /// launch, so it can't be used to distinguish "first time this run"
    /// from "previously cached"). Used to ensure each device's first
    /// SSDP response per session still triggers a `refreshTopology`
    /// even when the live response matches the cached snapshot
    /// byte-for-byte — otherwise the `isUsingCachedData` flag (cleared
    /// only inside `refreshTopology`) is stranded true and the UI shows
    /// "Using cached data" indefinitely.
    private var sessionDiscoveredDeviceIDs: Set<String> = []

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
    /// `title` and `artURL` are optional for backward compat with pre-v4.10.1
    /// cached entries that lacked those fields.
    fileprivate struct AppleMusicTrackEnrichment: Codable, Sendable {
        let artist: String
        let album: String?
        let title: String?
        let artURL: String?
    }

    /// Cached track info — populated when adding Service Search items to queue.
    /// Used to recover title/artist when the speaker returns empty TrackMetaData.
    struct CachedTrack { let title: String; let artist: String; let album: String; let artURL: String? }
    private var cachedTrackInfo: [String: CachedTrack] = [:]          // keyed by URI
    private var cachedTrackByPosition: [String: [Int: CachedTrack]] = [:] // keyed by groupID -> queue position

    /// Last-fetched queue items per group — used for track info recovery
    private var lastQueueItems: [String: [QueueItem]] = [:]

    /// Recoverable queue snapshots taken before destructive mutations
    /// (replace-all, clear, bulk remove). See `QueueHistoryStore`.
    public let queueHistory = QueueHistoryStore()

    /// Choragus-side saved queues — independent of the Sonos household.
    public lazy var savedQueueRepo = SavedQueueRepository(
        dbPath: AppPaths.appSupportDirectory.appendingPathComponent("saved_queues.sqlite").path)
    private var refreshTimer: Timer?
    private var refreshingHouseholds: Set<String> = []  // serializes topology refreshes per household (S1/S2 coexist)
    /// Households whose forced refresh arrived while a non-forced refresh
    /// was mid-flight — replayed once when the in-flight refresh completes.
    private var pendingForcedTopologyRefreshes: Set<String> = []
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

    // MARK: - Network Path Monitor
    //
    // UPnP `SUBSCRIBE` registers a CALLBACK header — our local
    // `EventListener`'s URL — with each speaker. A network path change
    // (VPN toggle, Wi-Fi roam to a different SSID, Ethernet plug/unplug)
    // can invalidate that callback URL because the host's reachable IP
    // shifts. SOAP control still works (we initiate those connections),
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

    /// Per-second `objectWillChange` emission counter — diagnostic for
    /// "every observer thrashes on every tiny state churn". Counts each
    /// publish, emits a `[MGR-PUB]` line once per second when non-zero.
    private var pubChangeSubscription: AnyCancellable?
    private var pubChangeCount: Int = 0
    private var pubChangeReporterTask: Task<Void, Never>?

    /// Per-source publish counters. Each known emission site bumps a
    /// labelled bucket via `tagPublish(_:)`; the per-second
    /// `[MGR-PUB]` reporter prints the breakdown so the karaoke-
    /// stutter investigation can identify which subsystem is firing
    /// 20+ publishes/sec. Total - sum(buckets) = "untagged" — sites
    /// we haven't instrumented yet.
    private var pubBuckets: [String: Int] = [:]

    /// Bumps the counter for `tag`. Called immediately before/after
    /// each high-frequency `@Published` write or `objectWillChange`
    /// forward. Cheap (one dict update); has no effect on the publish
    /// itself.
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
            self?.tagPublish("artCache")
            self?.objectWillChange.send()
        }

        // Diagnostic: count `objectWillChange` emissions and log per-second.
        pubChangeSubscription = self.objectWillChange.sink { [weak self] in
            self?.pubChangeCount += 1
        }
        pubChangeReporterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                let snapshot = await MainActor.run { () -> (Int, [String: Int]) in
                    let c = self.pubChangeCount
                    let b = self.pubBuckets
                    self.pubChangeCount = 0
                    self.pubBuckets = [:]
                    return (c, b)
                }
                let count = snapshot.0
                let buckets = snapshot.1
                if count > 0 {
                    let tagged = buckets.values.reduce(0, +)
                    let untagged = max(0, count - tagged)
                    let bucketStr = buckets
                        .sorted { $0.value > $1.value }
                        .map { "\($0.key)=\($0.value)" }
                        .joined(separator: " ")
                    sonosDebugLog("[MGR-PUB] last 1s: total=\(count) \(bucketStr) untagged=\(untagged)")
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
                self.devices = cachedDevices
                self.groups = cachedGroups
                self.browseSections = cachedSections
                self.isUsingCachedData = true
                self.cacheAge = cached.ageDescription
                // Cached groups are restored verbatim, so a household that
                // was persisted in a broken state comes back broken — worth
                // one line per launch to place it on the timeline.
                logTopologyOutcome("cache", groups: cachedGroups)
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
        // a bad topology even though every speaker is directly reachable
        // (observed 2026-08-05: household wiped by a bad merge; Refresh
        // could not recover it, app restart could). Force a topology
        // re-pull over plain HTTP from one known device per household in
        // parallel with the SSDP attempt.
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
                // invalidates our UPnP event-callback URL is a change in the
                // LOCAL address speakers reach us on. Prefer that as the change
                // signal so a path event that doesn't move our speaker-facing
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
    /// is exactly the address our UPnP event-callback URL must advertise. A
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

            // Guard the write — @Published fires on every assignment, even
            // when values are identical. Unnecessary fires cascade re-renders
            // through every @EnvironmentObject observer of SonosManager.
            // Logging gated on the same condition so periodic rediscovery
            // of an unchanged device doesn't flood the debug log.
            let isNewOrChanged = devices[device.id] != device
            if isNewOrChanged {
                sonosDebugLog("[DISCOVERY] \(desc.roomName) swGen=\(desc.swGen) softwareVersion=\(desc.softwareVersion) household=\(device.householdID ?? "<nil>")")
                devices[device.id] = device
            }
            // Refresh topology when:
            //  (a) the device is new or has materially changed this run, OR
            //  (b) we haven't yet refreshed for this device in *this* app
            //      session (covers the cache-restore case where every
            //      cached device matches its live SSDP response exactly
            //      and `isNewOrChanged` is false for all of them —
            //      without this guard, `refreshTopology` is never
            //      called, so the `isUsingCachedData` flag it owns
            //      stays stuck on `true` and event-pipeline state stays
            //      in cache-restore mode).
            // Subsequent same-session SSDP responses for an unchanged
            // device still skip the refresh, preserving the
            // SSDP-rotation-flap fix that motivated this branch.
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

    public func refreshTopology(from device: SonosDevice, force: Bool = false) async {
        // Serialize per-household so S1 and S2 refreshes don't block each other but also
        // don't race within a single household (main-actor re-entry across awaits).
        // Use source device UUID when householdID is not yet known (first discovery).
        let refreshKey = device.householdID ?? device.id
        guard !refreshingHouseholds.contains(refreshKey) else {
            // A forced refresh (user-initiated group change) must not be
            // silently dropped because a non-forced refresh is mid-flight —
            // record it and re-run one forced refresh when the in-flight
            // one completes (see the defer below).
            if force { pendingForcedTopologyRefreshes.insert(refreshKey) }
            return
        }

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
        defer {
            refreshingHouseholds.remove(refreshKey)
            if pendingForcedTopologyRefreshes.contains(refreshKey) {
                pendingForcedTopologyRefreshes.remove(refreshKey)
                Task { [weak self] in
                    await self?.refreshTopology(from: device, force: true)
                }
            }
        }

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
                let group = SonosGroup(id: gd.id,
                                       coordinatorID: resolvedCoordinatorID(for: gd,
                                                                            visibleMembers: stableMembers),
                                       members: stableMembers, householdID: household)
                newGroups.append(group)
            }

            // Reject satellite self-views before the merge. A home-theater
            // satellite (or a speaker mid-reboot) answers GetZoneGroupState
            // with a topology containing only `…:orphan` groups — its own
            // isolated view, not the household. Latest-response-wins would
            // accept it and wipe every real group (observed 2026-08-05:
            // one Living Room satellite response removed all 11 S2 groups;
            // with event subscriptions torn down by the wipe and SSDP
            // blocked on this network, the empty state persisted until app
            // restart). A response with no non-orphan groups carries no
            // household information — skip the merge entirely.
            // An empty (or all-orphan) response carries no household
            // information — a real household always has at least one
            // group, so merging it would wipe every room. Empty responses
            // reach here from aborted ZoneGroupState parses (issue #81)
            // as well as satellite self-views; both keep the previous
            // topology and retry later.
            let realGroups = newGroups.filter { !$0.id.hasSuffix(":orphan") }
            if realGroups.isEmpty {
                sonosDebugLog("[MERGE] REJECTED empty/self-view topology from \(device.roomName) — \(newGroups.count) group(s), none usable; keeping previous topology")
                self.isRefreshing = false
                return
            }
            newGroups = realGroups

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
                logTopologyOutcome("refresh(\(device.roomName))", groups: mergedGroups)
                saveCache()
            } else {
                sonosDebugLog("[MERGE] source=\(device.roomName) household=\(household) newCount=\(newGroups.count) totalCount=\(mergedGroups.count) changed=false")
            }

            // Record the successful refresh so the throttle can skip bursts.
            lastTopologyRefreshAt[refreshKey] = Date()

            // Parse home theater channel maps
            parseHTChannelMaps(from: groupData)
            // Parse stereo-pair channel maps (separate attribute, same
            // shape — keeps homeTheaterZones consumer pure HT while
            // letting the bug-bundle snapshot fold both bonded forms).
            parseStereoChannelMaps(from: groupData)

            // Check newly-seen devices for a fixed line-out so the UI can
            // disable their volume slider before the user hits a 501 (#50).
            // Cheap + idempotent: only un-checked devices are queried.
            Task { [weak self] in await self?.refreshFixedOutputStatus() }

            // Equality-gate the three @Published flag writes — they
            // fire after every topology refresh attempt (which runs
            // per-speaker on a busy network). @Published has no
            // equality check; without these guards, ~10 speakers
            // refreshing each emit ~30 publishes/sec of "set the
            // already-false flag back to false", flooding the SwiftUI
            // invalidation queue and starving the karaoke
            // TimelineView's frame budget.
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
        } catch {
            sonosDebugLog("[DISCOVERY] Topology fetch failed: \(error)")
        }
    }

    /// Repairs a group whose `Coordinator` UUID names no visible member
    /// (#83) — such a group takes no transport command and reports no
    /// state. Substitutions are logged, never silent.
    private func resolvedCoordinatorID(for gd: ZoneGroupData,
                                       visibleMembers: [SonosDevice]) -> String {
        let resolution = TopologyCoordinatorResolver.resolve(
            reported: gd.coordinatorUUID,
            visibleMemberIDs: visibleMembers.map(\.id),
            previouslyKnownCoordinator: groups.first { $0.id == gd.id }?.coordinatorID)
        guard resolution.substituted else { return resolution.coordinatorID }
        sonosDiagLog(.error, tag: "TOPOLOGY",
                     "Group coordinator not among its visible members — substituting",
                     context: [
                        "groupID": gd.id,
                        "reportedCoordinator": gd.coordinatorUUID,
                        "substituted": resolution.coordinatorID,
                        "substitutedRoom": visibleMembers
                            .first { $0.id == resolution.coordinatorID }?.roomName ?? "",
                        "visibleMembers": String(visibleMembers.count),
                        "totalMembers": String(gd.members.count)
                     ])
        return resolution.coordinatorID
    }

    /// Records what each topology application produced — #83 bundles
    /// logged parse aborts but not successful merges, so a broken
    /// household left no trace of which update caused it.
    private func logTopologyOutcome(_ source: String, groups: [SonosGroup]) {
        let coordinatorless = groups.filter { $0.coordinator == nil }
        sonosDiagLog(coordinatorless.isEmpty ? .info : .error, tag: "TOPOLOGY",
                     "Topology applied from \(source)",
                     context: [
                        "groups": String(groups.count),
                        "visibleSpeakers": String(groups.reduce(0) { $0 + $1.members.count }),
                        "groupsWithoutCoordinator": String(coordinatorless.count),
                        "namesWithoutCoordinator": coordinatorless.prefix(5)
                            .map(\.name).joined(separator: ", ")
                     ])
    }

    /// Parses ChannelMapSet from topology data to identify stereo-pair
    /// primaries and their invisible right-channel siblings. Same
    /// shape as `parseHTChannelMaps`, different attribute source.
    private func parseStereoChannelMaps(from groupData: [ZoneGroupData]) {
        var maps: [String: [(String, SpeakerChannel)]] = [:]
        for gd in groupData {
            for md in gd.members where !md.channelMapSet.isEmpty {
                var channelList: [(String, SpeakerChannel)] = []
                let pairs = md.channelMapSet.components(separatedBy: ";")
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
                    // Key on the visible primary's UUID — stereo pairs
                    // are not always at the group coordinator (a stereo
                    // pair can be soft-grouped into a larger group).
                    maps[md.uuid] = channelList
                }
            }
        }
        let serialised: ([String: [(String, SpeakerChannel)]]) -> String = { m in
            m.keys.sorted().map { k in
                let pairs = (m[k] ?? []).map { "\($0.0):\($0.1.rawValue)" }.joined(separator: ",")
                return "\(k)=\(pairs)"
            }.joined(separator: "|")
        }
        if serialised(stereoChannelMaps) != serialised(maps) {
            tagPublish("stereoChannel")
            stereoChannelMaps = maps
        }
    }

    /// Parses HTSatChanMapSet into surround/sub configurations. A 5.1 zone
    /// publishes four different values — the soundbar's complete map plus
    /// one partial view per satellite — so the merge is across all members;
    /// taking the first found hid the Surrounds tab (#78).
    private func parseHTChannelMaps(from groupData: [ZoneGroupData]) {
        // Start from what is known: payloads without the bonded-channel
        // attributes would otherwise publish an empty map and flicker every
        // home-theatre zone out of existence between refreshes.
        var maps = htSatChannelMaps
        var payloadReportedAnyMap = false
        for gd in groupData {
            // Format: "RINCON_xxx:LF,RF;RINCON_yyy:SW;RINCON_zzz:LR;RINCON_www:RR"
            let merged = HomeTheaterChannelMap.merge(
                memberMapSets: gd.members.map(\.htSatChanMapSet))
            if !merged.isEmpty {
                payloadReportedAnyMap = true
                maps[gd.coordinatorUUID] = merged
            }
        }
        // Only a payload that demonstrably carries the attributes can be
        // trusted to report un-bonding.
        if payloadReportedAnyMap {
            let reportedNoMap = groupData
                .filter { HomeTheaterChannelMap.merge(memberMapSets: $0.members.map(\.htSatChanMapSet)).isEmpty }
                .map(\.coordinatorUUID)
            for coordinatorID in reportedNoMap {
                maps.removeValue(forKey: coordinatorID)
            }
        }
        // Equality-gate the @Published write — `parseHTChannelMaps`
        // runs after every topology refresh (per-speaker on a busy
        // network), and `maps` is usually identical to the existing
        // value. Without this guard the unconditional assignment
        // floods the publisher 10–20 ×/s during refresh storms,
        // which was the residual karaoke micro-stutter source after
        // the refresh-flag gates landed in B1338. Tuples aren't
        // Equatable, so serialise to a stable string for comparison.
        let serialised: ([String: [(String, SpeakerChannel)]]) -> String = { m in
            m.keys.sorted().map { k in
                let pairs = (m[k] ?? []).map { "\($0.0):\($0.1.rawValue)" }.joined(separator: ",")
                return "\(k)=\(pairs)"
            }.joined(separator: "|")
        }
        if serialised(htSatChannelMaps) != serialised(maps) {
            tagPublish("htChannel")
            htSatChannelMaps = maps
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
            if applyTransportState, groupTransportStates[coordinator.id] != state {
                tagPublish("transport")
                groupTransportStates[coordinator.id] = state
            }
            if groupPlayModes[coordinator.id] != mode {
                tagPublish("playMode")
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
    /// SOAP 714 ("no such resource") is handled separately. It used
    /// to be bundled with the topology-stale set, but in practice the
    /// dominant trigger is the speaker rejecting a SMAPI single-track
    /// direct-play URI we built — the speakers are fine, the URI
    /// shape isn't accepted (issue #42). For 714 we throw
    /// `.serviceRejected` with an actionable message and skip both
    /// the topology rescan and the misleading "Speaker layout has
    /// changed" banner.
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
    nonisolated static func isSMAPIServiceTrackURI(_ uri: String) -> Bool {
        return uri.hasPrefix("x-sonos-spotify:")
            || uri.hasPrefix("x-sonos-http:")
            || uri.hasPrefix("x-sonos-hls:")
            // Apple Music tracks now enqueue in the official app's
            // hls-static form; direct SetAVTransportURI rejects service
            // tracks, so they keep the queue-replace routing.
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
                 .nothingLoaded, .notPlayable, .tracksSkippingEarly:
                break
            }
            throw mapped
        }
    }

    private func handleStaleness(for roomName: String, kind: String) {
        let count = (consecutiveStaleFailures[roomName] ?? 0) + 1
        consecutiveStaleFailures[roomName] = count
        if count >= 2 {
            staleMessage = "Speakers reconnecting after network change… If this persists, power-cycle the speakers and relaunch Choragus."
        } else {
            staleMessage = kind == "network"
                ? "\(roomName) is not responding. Refreshing speakers..."
                : "Command failed — speaker layout may have changed. Refreshing..."
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

    // MARK: - Volume Control

    public func getVolume(device: SonosDevice) async throws -> Int {
        try await renderingControl.getVolume(device: device)
    }

    /// Device IDs whose line-out volume is Fixed (Connect / Port / Amp locked
    /// in the Sonos app). `SetVolume` faults UPnP 501 on these (issue #50), so
    /// the UI disables their slider and `setVolume` no-ops. Populated by
    /// `refreshFixedOutputStatus` and self-heals from a live 501.
    @Published public private(set) var fixedOutputDeviceIDs: Set<String> = []
    private var checkedOutputFixed: Set<String> = []

    /// Normalizes a device id to the bare zone-player RINCON UUID used by
    /// topology / `group.members`, stripping the UPnP MediaRenderer (`_MR`)
    /// suffix that RenderingControl events carry — so the fixed-output set keys
    /// consistently regardless of which id space produced the id.
    nonisolated static func bareDeviceID(_ id: String) -> String {
        id.hasSuffix("_MR") ? String(id.dropLast(3)) : id
    }

    /// True when the device's line-out is fixed and volume can't be changed.
    public func isOutputFixed(_ deviceID: String) -> Bool {
        fixedOutputDeviceIDs.contains(Self.bareDeviceID(deviceID))
    }

    /// Only Connect / Port / Amp expose a fixed line-out (and the
    /// `GetOutputFixed` action). Other models (One, Play, soundbars) fault UPnP
    /// 803 "not implemented" — so don't query them.
    private static func hasLineOut(_ modelName: String) -> Bool {
        let m = modelName.lowercased()
        return m.contains("connect") || m.contains("port") || m.contains("amp")
    }

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

    /// Re-checks the fixed-output status of a specific group's members and
    /// updates `fixedOutputDeviceIDs` BOTH ways. Called when a group is viewed
    /// and on its track changes — the fixed state isn't static (a Connect is
    /// fixed while sourcing line-in but adjustable when playing its own track),
    /// so this must override the one-shot `checkedOutputFixed` cache, removing
    /// devices that are no longer fixed.
    public func ensureFixedOutputChecked(for group: SonosGroup) async {
        for member in group.members {
            let key = Self.bareDeviceID(member.id)
            // Topology members can carry an empty modelName, so resolve the full
            // device record (which has the model + a reliable endpoint) before
            // the line-out gate — otherwise the re-check is skipped and a
            // Fixed→Variable change never clears.
            let d = devices.values.first { Self.bareDeviceID($0.id) == key } ?? member
            guard Self.hasLineOut(d.modelName) else { continue }
            checkedOutputFixed.insert(key)
            let fixed = await renderingControl.getOutputFixed(device: d)
            if fixed {
                if fixedOutputDeviceIDs.insert(key).inserted {
                    sonosDebugLog("[VOLUME] \(d.roomName) line-out is fixed — volume control disabled (#50)")
                }
            } else if fixedOutputDeviceIDs.remove(key) != nil {
                sonosDebugLog("[VOLUME] \(d.roomName) line-out no longer fixed — volume control enabled")
            }
        }
    }

    /// Queries `GetOutputFixed` once per line-out device and caches the result.
    /// Restricted to line-out models so non-line-out speakers aren't pinged with
    /// an action they don't implement (UPnP 803 spam).
    public func refreshFixedOutputStatus() async {
        let toCheck = devices.values.filter {
            !checkedOutputFixed.contains(Self.bareDeviceID($0.id)) && Self.hasLineOut($0.modelName)
        }
        for d in toCheck {
            let key = Self.bareDeviceID(d.id)
            checkedOutputFixed.insert(key)
            if await renderingControl.getOutputFixed(device: d) {
                fixedOutputDeviceIDs.insert(key)
                sonosDebugLog("[VOLUME] \(d.roomName) line-out is fixed — volume control disabled (#50)")
            }
        }
    }

    public func setVolume(device: SonosDevice, volume: Int) async throws {
        // Fixed line-out (Connect/Port/Amp) rejects SetVolume with UPnP 501.
        // Skip the call entirely so we don't spam faults (issue #50).
        if fixedOutputDeviceIDs.contains(Self.bareDeviceID(device.id)) {
            sonosDebugLog("[VOLUME] skip setVolume — \(device.roomName) line-out is fixed (#50)")
            return
        }
        recordExpectedVolumeEcho(deviceID: device.id, value: volume)
        sonosDebugLog("[RC-SOAP-WRITE] setVolume room=\(device.roomName) id=\(device.id) → \(volume)")
        // Portable speakers (Move/Roam) have a known firmware quirk:
        // when on Bluetooth input the RenderingControl service accepts
        // SetVolume but the audio pipeline ignores it — the next
        // GetVolume event reads back 0. Issue #37 reported "slider
        // jumps back to 0" on a grouped Move. Capture model + group
        // context at the point of intent so the bug bundle from the
        // affected user contains both the SET attempt and the
        // subsequent rejection (logged in `updateDeviceVolume`).
        if device.isPortable {
            let groupCoord = groups.first(where: { g in g.members.contains(where: { $0.id == device.id }) })?.coordinatorID ?? "?"
            sonosDiagLog(.info, tag: "PORTABLE_VOL",
                         "setVolume on portable \(device.modelName) → \(volume) (room=\(device.roomName))",
                         context: [
                            "deviceID": device.id,
                            "model": device.modelName,
                            "modelNumber": device.modelNumber,
                            "desiredVolume": String(volume),
                            "groupCoordinator": groupCoord
                         ])
        }
        do {
            try await renderingControl.setVolume(device: device, volume: volume)
        } catch {
            // A fixed line-out reports its lock late via UPnP 501. Treat as
            // benign, remember it (slider disables, no further attempts), and
            // don't surface a user-facing error (issue #50).
            if case SOAPError.soapFault(let code, _) = error, code == "501" {
                fixedOutputDeviceIDs.insert(Self.bareDeviceID(device.id))
                checkedOutputFixed.insert(Self.bareDeviceID(device.id))
                sonosDiagLog(.info, tag: "VOLUME",
                             "SetVolume rejected (501) — \(device.roomName) line-out fixed; disabling control (#50)",
                             context: ["deviceID": device.id])
                return
            }
            throw error
        }
        scheduleDeviceVolumeVerify(device: device)
    }

    public func getMute(device: SonosDevice) async throws -> Bool {
        try await renderingControl.getMute(device: device)
    }

    public func setMute(device: SonosDevice, muted: Bool) async throws {
        recordExpectedMuteEcho(deviceID: device.id, value: muted)
        sonosDebugLog("[RC-SOAP-WRITE] setMute room=\(device.roomName) id=\(device.id) → \(muted)")
        try await renderingControl.setMute(device: device, muted: muted)
        scheduleDeviceMuteVerify(device: device)
    }

    // MARK: - Expected-echo bookkeeping

    private func recordExpectedMuteEcho(deviceID: String, value: Bool) {
        let now = Date()
        var list = expectedMuteEchoes[deviceID] ?? []
        list = list.filter { $0.deadline > now }
        list.append((value, now.addingTimeInterval(Self.echoExpectationWindow)))
        if list.count > Self.echoQueueCap { list = Array(list.suffix(Self.echoQueueCap)) }
        expectedMuteEchoes[deviceID] = list
    }

    private func recordExpectedVolumeEcho(deviceID: String, value: Int) {
        let now = Date()
        var list = expectedVolumeEchoes[deviceID] ?? []
        list = list.filter { $0.deadline > now }
        list.append((value, now.addingTimeInterval(Self.echoExpectationWindow)))
        if list.count > Self.echoQueueCap { list = Array(list.suffix(Self.echoQueueCap)) }
        expectedVolumeEchoes[deviceID] = list
    }

    /// Returns true and consumes the earliest matching pending write if
    /// the inbound mute event matches one we issued. Returns false if no
    /// match — caller treats the event as an external state change.
    private func consumeExpectedMuteEcho(deviceID: String, value: Bool) -> Bool {
        let now = Date()
        guard var list = expectedMuteEchoes[deviceID] else { return false }
        list = list.filter { $0.deadline > now }
        if let idx = list.firstIndex(where: { $0.value == value }) {
            list.remove(at: idx)
            expectedMuteEchoes[deviceID] = list.isEmpty ? nil : list
            return true
        }
        expectedMuteEchoes[deviceID] = list.isEmpty ? nil : list
        return false
    }

    private func consumeExpectedVolumeEcho(deviceID: String, value: Int) -> Bool {
        let now = Date()
        guard var list = expectedVolumeEchoes[deviceID] else { return false }
        list = list.filter { $0.deadline > now }
        if let idx = list.firstIndex(where: { $0.value == value }) {
            list.remove(at: idx)
            expectedVolumeEchoes[deviceID] = list.isEmpty ? nil : list
            return true
        }
        expectedVolumeEchoes[deviceID] = list.isEmpty ? nil : list
        return false
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

    /// Parsed `ChannelMapSet` data — stereo-pair primaries map their
    /// invisible right-channel sibling here (e.g. coordinator UUID →
    /// `[(left=primary, .leftPair), (right=invisible, .rightPair)]`).
    /// Distinct from `htSatChannelMaps` so the existing
    /// `homeTheaterZones` consumer keeps its 5.1-only semantics
    /// while the bug-bundle topology snapshot can fold both maps.
    @Published public var stereoChannelMaps: [String: [(String, SpeakerChannel)]] = [:]

    // MARK: - Queue

    public func getQueue(group: SonosGroup, start: Int = 0, count: Int = PageSize.queue) async throws -> (items: [QueueItem], total: Int) {
        guard let coordinator = group.coordinator else { return ([], 0) }
        let result = try await contentDirectory.browseQueue(device: coordinator, start: start, count: count)
        // Recover real titles for rows where the speaker returned a filename
        // (e.g. Suno `<uuid>.mp3`) — the song name is in the play-time cache.
        let items = result.items.map { enrichQueueItemFromCache($0) }
        // Cache queue items for track info recovery (Apple Music tracks may have empty GetPositionInfo)
        if start == 0 && !items.isEmpty {
            lastQueueItems[group.coordinatorID] = items
        }
        return (items, result.total)
    }

    /// Replaces a queue row's filename/empty title (and missing artist/art)
    /// with the cached values captured at play time, keyed by the row's URI.
    /// Clips we've already kicked off a title fetch for this session, so a
    /// queue full of unresolved Suno rows triggers at most one fetch each.
    private var sunoTitleFetches = Set<String>()

    /// Self-heal a Suno track's title when it isn't in the persistent store
    /// (e.g. a clip queued without going through our resolver). Fetches the
    /// `/song/<uuid>` page in the background — which persists the title — then
    /// patches any now-playing row and refreshes the queue.
    func ensureSunoTitle(forUUID uuid: String) {
        guard SunoCatalog.title(forUUID: uuid) == nil,
              sunoTitleFetches.insert(uuid).inserted else { return }
        Task { [weak self] in
            _ = try? await SunoResolver.resolve("https://suno.com/song/\(uuid)")
            guard let self, let title = SunoCatalog.title(forUUID: uuid) else { return }
            for (gid, md) in self.groupTrackMetadata
            where md.trackURI.flatMap({ SunoCatalog.uuid(fromURI: $0) }) == uuid {
                var m = md
                m.title = title
                self.groupTrackMetadata[gid] = m
            }
            self.postQueueChanged(optimisticItems: [])
        }
    }

    // MARK: - Apple Music queue metadata repair (fast add, then named)

    /// Serial background repair chain per coordinator.
    private var queueRepairTasks: [String: Task<Void, Never>] = [:]
    /// Background queue fill per coordinator. A replace-queue action
    /// cancels the previous coordinator's fill — otherwise Play All on
    /// album B while album A's fill was mid-flight interleaved both
    /// albums' remaining chunks into the new queue.
    private var queueFillTasks: [String: Task<Void, Never>] = [:]
    /// Early-advance detector state: last observed track identity per
    /// group, and when this controller last issued a transport command
    /// (next/previous/seek) that legitimately truncates a track.
    var lastTrackIdentity: [String: (uri: String, title: String)] = [:]

    /// Timestamps of recent early advances per group, and when the user was
    /// last told, so a failing queue reports once rather than once per track.
    var earlyAdvances: [String: [Date]] = [:]
    var lastEarlyAdvanceReportAt: [String: Date] = [:]
    var lastControllerTransportCommandAt: [String: Date] = [:]
    /// Count of repairs in flight per coordinator — Q:0 GENA events are
    /// suppressed while non-zero so the swap churn doesn't blink the queue
    /// panel; one reload fires when the last chained repair finishes.
    private var queueRepairDepth: [String: Int] = [:]
    private var queueRepairActiveGroups: Set<String> {
        Set(queueRepairDepth.filter { $0.value > 0 }.map(\.key))
    }

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
    func scheduleAppleMusicQueueRepair(group: SonosGroup, rows: [(position: Int, uri: String)]) {
        guard let coordinator = group.coordinator else { return }
        let amRows = rows.filter { URIPrefix.appleMusicSongID(from: $0.uri) != nil }
        guard !amRows.isEmpty else { return }
        let previous = queueRepairTasks[coordinator.id]
        queueRepairDepth[coordinator.id, default: 0] += 1
        queueRepairTasks[coordinator.id] = Task { [weak self] in
            await previous?.value      // serialise with any in-flight repair
            guard let self else { return }
            defer {
                self.queueRepairDepth[coordinator.id, default: 1] -= 1
                if self.queueRepairDepth[coordinator.id, default: 0] <= 0 {
                    self.queueRepairDepth[coordinator.id] = nil
                    self.postQueueChanged(optimisticItems: [])
                }
            }
            let type = MusicServiceCatalog.shared.rinconServiceType(forSid: ServiceID.appleMusic)
            let desc = "SA_RINCON\(type)_X_#Svc\(type)-0-Token"
            for (pos, uri) in amRows {
                if Task.isCancelled { return }
                let playing = self.groupTrackMetadata[coordinator.id]?.trackNumber ?? -1
                if pos == playing || pos == playing + 1 { continue }
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
        }
    }

    /// One iTunes `lookup?id=` per catalog song per session — self-heals
    /// Apple Music queue rows whose speaker-side metadata is bare (the
    /// descriptor-free fast enqueue stores none, and the session cache
    /// doesn't survive a relaunch). Same pattern as `ensureSunoTitle`.
    private var amQueueMetaFetches = Set<String>()

    /// Resolved iTunes art for local-library albums, keyed by album+artist.
    /// The speaker's `getaa` art proxy 404s for some NAS files (no embedded
    /// cover, or the speaker can't extract it), leaving queue rows blank even
    /// though Now Playing shows art — because Now Playing already resolves
    /// local art through this same iTunes path. One lookup per album paints
    /// every row of that album.
    private var localAlbumArt: [String: String] = [:]
    private var localAlbumArtFetches = Set<String>()
    private var localAlbumArtLoaded = false
    private let localAlbumArtURL = AppPaths.appSupportDirectory.appendingPathComponent("local_album_art.json")

    /// Loads the persisted album→art map once. Persisting the resolved iTunes
    /// URLs (not just the image bytes, which `ImageCache` already keeps) means
    /// a relaunch paints covers instantly instead of re-hitting iTunes for
    /// every album.
    private func loadLocalAlbumArtIfNeeded() {
        guard !localAlbumArtLoaded else { return }
        localAlbumArtLoaded = true
        if let data = try? Data(contentsOf: localAlbumArtURL),
           let map = try? JSONDecoder().decode([String: String].self, from: data) {
            localAlbumArt = map
        }
    }

    private func persistLocalAlbumArt() {
        guard let data = try? JSONEncoder().encode(localAlbumArt) else { return }
        try? data.write(to: localAlbumArtURL, options: .atomic)
    }

    static func localAlbumKey(artist: String, album: String) -> String {
        "\(album.lowercased())\u{1F}\(artist.lowercased())"
    }

    func ensureLocalQueueArt(artist: String, album: String) {
        guard !artist.isEmpty, !album.isEmpty else { return }
        Task { [weak self] in
            if (await self?.resolveLocalAlbumArt(artist: artist, album: album)) != nil {
                self?.postQueueChanged(optimisticItems: [])
            }
        }
    }

    /// Awaitable cache-or-search for a local album's iTunes art, persisted to
    /// disk so each album resolves once across launches. A cache hit returns
    /// regardless of limiter state; a miss only hits iTunes when the limiter
    /// has budget (issue #64 — browsing a large library must not pile on
    /// during a cooldown), and a failed lookup stays retryable. Shared by the
    /// live-queue resolver, the Queue Library, and local-library browse art.
    public func resolveLocalAlbumArt(artist: String, album: String) async -> String? {
        guard !artist.isEmpty, !album.isEmpty else { return nil }
        loadLocalAlbumArtIfNeeded()
        let key = Self.localAlbumKey(artist: artist, album: album)
        if let cached = localAlbumArt[key] { return cached }
        // Don't attempt while iTunes is cooling down — defer so the row
        // retries once budget returns instead of staying blank.
        guard await ITunesRateLimiter.shared.snapshot().isAvailable else { return nil }
        // Dedupe concurrent lookups for the same album.
        guard localAlbumArtFetches.insert(key).inserted else { return localAlbumArt[key] }
        let art = await albumArtSearch.searchArtwork(artist: artist, album: album)
        if let art, !art.isEmpty {
            localAlbumArt[key] = art
            persistLocalAlbumArt()
            return art
        }
        // Allow a later retry (e.g. after a transient cooldown clears).
        localAlbumArtFetches.remove(key)
        return nil
    }

    /// Whether a stored/parsed art URL won't render in this household — the
    /// speaker's getaa proxy 404s for some local NAS files.
    private static func isUnreliableLocalArt(uri: String?, art: String?) -> Bool {
        (uri.map(URIPrefix.isLocal) == true) && (art == nil || art!.isEmpty || art!.contains("/getaa"))
    }

    /// Mosaic cover art for a Choragus-local saved queue, with local-library
    /// rows resolved through iTunes (the stored getaa URLs 404). Async so the
    /// resolution can await; capped at `limit` distinct albums.
    public func choragusCoverArtResolved(localID: Int64, limit: Int = 4) async -> [String] {
        var rows: [(album: String, artist: String, art: String?)] = []
        for track in savedQueueRepo.tracks(for: localID) {
            var art = track.albumArtURI
            if Self.isUnreliableLocalArt(uri: track.uri, art: art) {
                art = await resolveLocalAlbumArt(artist: track.artist, album: track.album)
            }
            rows.append((track.album, track.artist, art))
            // Stop once we likely have enough distinct albums to fill the mosaic.
            if Self.distinctAlbumArt(rows, limit: limit).count >= limit { break }
        }
        return Self.distinctAlbumArt(rows, limit: limit)
    }

    /// Resolves local-library art for an arbitrary track list (Queue Library
    /// detail / smart-queue tracks) so their rows render iTunes art instead
    /// of dead getaa URLs.
    public func resolveLocalArt(in tracks: [QueueItem]) async -> [QueueItem] {
        var out: [QueueItem] = []
        for var t in tracks {
            if Self.isUnreliableLocalArt(uri: t.uri, art: t.albumArtURI),
               let art = await resolveLocalAlbumArt(artist: t.artist, album: t.album) {
                t.albumArtURI = art
            }
            out.append(t)
        }
        return out
    }

    func ensureAppleMusicQueueMetadata(songID: String, uri: String) {
        guard amQueueMetaFetches.insert(songID).inserted else { return }
        Task { [weak self] in
            guard let url = URL(string: "https://itunes.apple.com/lookup?id=\(songID)") else { return }
            guard let (data, _) = await ITunesRateLimiter.shared.perform(
                url: url, session: URLSession.shared, maxWait: 8
            ), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let first = (json["results"] as? [[String: Any]])?.first,
               let title = first["trackName"] as? String, !title.isEmpty,
               let self else { return }
            let art = (first["artworkUrl100"] as? String)?
                .replacingOccurrences(of: "100x100", with: "600x600")
            let cached = CachedTrack(title: title,
                                     artist: first["artistName"] as? String ?? "",
                                     album: first["collectionName"] as? String ?? "",
                                     artURL: art)
            self.cachedTrackInfo[uri] = cached
            if let d = uri.removingPercentEncoding, d != uri { self.cachedTrackInfo[d] = cached }
            self.postQueueChanged(optimisticItems: [])
        }
    }

    private func enrichQueueItemFromCache(_ item: QueueItem) -> QueueItem {
        var copy = item

        // Suno code path — keyed on the suno.ai host + clip UUID in the row's
        // URI. Cover is derived from the UUID; title comes from the persistent
        // store. Both survive restarts (the speaker returns a blank getaa art
        // proxy + the filename as title for these direct-URL tracks).
        if let uri = item.uri, let uuid = SunoCatalog.uuid(fromURI: uri) {
            copy.albumArtURI = SunoCatalog.coverURL(forUUID: uuid)
            if let t = SunoCatalog.title(forUUID: uuid) {
                copy.title = t
            } else if copy.title.isEmpty || TrackMetadata.isTechnicalName(copy.title) {
                ensureSunoTitle(forUUID: uuid)
            }
            return copy
        }

        // TIDAL code path — resolved CDN URL with no embedded cover id; art /
        // title / artist come from the persistent catalog (see TidalCatalog).
        if let uri = item.uri, TidalCatalog.key(fromURI: uri) != nil {
            if let art = TidalCatalog.art(forURI: uri) { copy.albumArtURI = art }
            if copy.title.isEmpty || TrackMetadata.isTechnicalName(copy.title),
               let t = TidalCatalog.title(forURI: uri) { copy.title = t }
            if copy.artist.isEmpty, let a = TidalCatalog.artist(forURI: uri) { copy.artist = a }
            return copy
        }

        // Local-library art: the speaker's getaa proxy 404s for some NAS
        // files, so prefer iTunes-resolved album art (the same source Now
        // Playing uses for these tracks) and kick off a lookup on miss.
        if let uri = item.uri, URIPrefix.isLocal(uri),
           !copy.artist.isEmpty, !copy.album.isEmpty {
            loadLocalAlbumArtIfNeeded()
            let key = Self.localAlbumKey(artist: copy.artist, album: copy.album)
            if let resolved = localAlbumArt[key] {
                copy.albumArtURI = resolved
            } else {
                ensureLocalQueueArt(artist: copy.artist, album: copy.album)
            }
        }

        guard let uri = item.uri,
              let cached = cachedTrackInfo[uri]
                ?? (uri.removingPercentEncoding.flatMap { cachedTrackInfo[$0] })
        else {
            // Bare Apple Music row with no session cache (post-relaunch):
            // self-heal from iTunes by the URI's authoritative catalog ID,
            // then refresh the queue.
            if let uri = item.uri,
               item.title.isEmpty || TrackMetadata.isTechnicalName(item.title),
               let songID = URIPrefix.appleMusicSongID(from: uri) {
                ensureAppleMusicQueueMetadata(songID: songID, uri: uri)
            }
            // Return `copy`, not `item` — local-library rows have no session
            // cache entry, so they reach this branch, and `copy` carries the
            // iTunes-resolved album art assigned above (returning `item` here
            // discarded it, leaving local queue rows blank).
            return copy
        }
        // Title only when the speaker gave a filename/empty; artwork whenever
        // missing (direct-URL tracks often report a title but no art).
        if (copy.title.isEmpty || TrackMetadata.isTechnicalName(copy.title)), !cached.title.isEmpty {
            copy.title = cached.title
        }
        if copy.artist.isEmpty { copy.artist = cached.artist }
        if copy.album.isEmpty { copy.album = cached.album }
        if (copy.albumArtURI == nil || copy.albumArtURI?.isEmpty == true), let art = cached.artURL {
            copy.albumArtURI = art
        }
        return copy
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

        // Snapshot before clearing so the user can undo a clear.
        await snapshotQueueForHistory(group: group)

        try await contentDirectory.removeAllTracksFromQueue(device: coordinator)
        lastQueueItems[group.coordinatorID] = nil
        cachedTrackByPosition[group.coordinatorID] = nil

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
            groupTransportStates[coordinator.id] = .stopped
            groupPositions[coordinator.id] = 0
            awaitingPlayback[coordinator.id] = false
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
    /// One-shot per launch. Snapshots moved off the speaker in 4.12.x: any
    /// remaining `__cghist__*` saved queue is residue from an earlier build
    /// and is destroyed on EVERY detected system — they show up as playlists
    /// in other controllers (the official app doesn't know the prefix). Also
    /// garbage-collects local snapshot rows the history index no longer
    /// tracks (index cleared, crash between delete and persist).
    private var purgedLegacySnapshots = false
    func purgeLegacySpeakerSnapshots() async {
        guard !purgedLegacySnapshots else { return }
        purgedLegacySnapshots = true
        var failed = false
        for (_, g) in householdsByCoordinator() {
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
            savedQueueRepo.delete(id: rowID)
        }
        if failed { purgedLegacySnapshots = false }   // retry on the next trigger
    }

    public func snapshotQueueForHistory(group: SonosGroup) async {
        guard let coordinator = group.coordinator else { return }
        await purgeLegacySpeakerSnapshots()
        do {
            let collected = try await readFullQueue(device: coordinator)
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
                savedQueueRepo.delete(id: staleID)
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

    /// Pages the entire live queue WITH per-track DIDL. The metadata is what
    /// lets an Apple Music / SMAPI track re-enqueue later without faulting
    /// UPnP 800.
    private func readFullQueue(device: SonosDevice) async throws -> [QueueItem] {
        var collected: [QueueItem] = []
        var index = 0
        while true {
            let (page, total) = try await contentDirectory.browseQueue(
                device: device, start: index, count: 500, includeMetadata: true)
            collected.append(contentsOf: page.map { enrichQueueItemFromCache($0) })
            if page.isEmpty || collected.count >= total || index >= 40_000 { break }
            index += page.count
        }
        return collected
    }

    /// Reads the live queue and stores it locally under `name`. Returns the
    /// count saved.
    public func saveQueueToChoragus(group: SonosGroup, name: String) async throws -> Int {
        guard let coordinator = group.coordinator else { return 0 }
        let collected = try await readFullQueue(device: coordinator)
        guard !collected.isEmpty else { return 0 }
        _ = savedQueueRepo.save(name: name, tracks: collected)
        notifyChoragusQueuesChanged()
        return collected.count
    }

    public func localSavedQueues() -> [LocalSavedQueue] {
        savedQueueRepo.list()
    }

    public func savedQueueTracks(localID: Int64) -> [QueueItem] {
        savedQueueRepo.tracks(for: localID)
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
        let items = tracks.compactMap { track -> BrowseItem? in
            guard let uri = track.uri, !uri.isEmpty else { return nil }
            // resourceMetadata carries the preserved `<r:resMD>` DIDL —
            // Apple Music / SMAPI tracks fault UPnP 800 without it.
            return BrowseItem(id: "LOCALQ:\(id)/\(track.id)",
                              title: track.title, artist: track.artist, album: track.album,
                              albumArtURI: track.albumArtURI, itemClass: .musicTrack,
                              resourceURI: uri, resourceMetadata: track.metadata)
        }
        guard !items.isEmpty else { return }
        if append {
            _ = try await addBrowseItemsToQueue(items, in: group, playNext: false)
        } else {
            try await playItemsReplacingQueue(items, in: group)
        }
    }

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
        loadLocalAlbumArtIfNeeded()
        let rows = savedQueueRepo.tracks(for: localID).map { t -> (album: String, artist: String, art: String?) in
            var art = t.albumArtURI
            // Substitute the persisted iTunes art for local rows whose stored
            // getaa URL won't render — no web call, just a dict hit.
            if Self.isUnreliableLocalArt(uri: t.uri, art: art) {
                art = localAlbumArt[Self.localAlbumKey(artist: t.artist, album: t.album)]
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
            if Self.isUnreliableLocalArt(uri: item.resourceURI, art: art) {
                art = await resolveLocalAlbumArt(artist: item.artist, album: item.album)
            }
            rows.append((item.album, item.artist, art))
            if Self.distinctAlbumArt(rows, limit: limit).count >= limit { break }
        }
        return Self.distinctAlbumArt(rows, limit: limit)
    }

    // MARK: - Saved-queue folders

    public func savedQueueFolders() -> [SavedQueueFolder] { savedQueueRepo.listFolders() }
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
            case .mostPlayed:     return "Most played"
            case .recentlyPlayed: return "Recently played"
            case .starred:        return "Starred"
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
        guard let room, !room.isEmpty else { return true }
        let tokens = room.components(separatedBy: " + ")
        let members = entry.groupName.components(separatedBy: " + ")
        return tokens.allSatisfy { members.contains($0) }
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
        func distinct(_ source: [PlayHistoryEntry]) -> [QueueItem] {
            var seen = Set<String>()
            var out: [QueueItem] = []
            for e in source {
                guard let uri = e.sourceURI, !uri.isEmpty, !e.title.isEmpty else { continue }
                let key = "\(e.title.lowercased())\u{1F}\(e.artist.lowercased())"
                guard seen.insert(key).inserted else { continue }
                out.append(QueueItem(id: out.count + 1, title: e.title, artist: e.artist,
                                     album: e.album, albumArtURI: e.albumArtURI,
                                     duration: "", uri: uri, metadata: nil))
                if out.count >= limit { break }
            }
            return out
        }
        switch kind {
        case .starred:
            return distinct(entries.filter(\.starred).reversed())
        case .recentlyPlayed:
            return distinct(entries.reversed())
        case .mostPlayed:
            let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
            let recent = entries.filter { $0.timestamp >= cutoff }
            var counts: [String: Int] = [:]
            var rep: [String: PlayHistoryEntry] = [:]
            for e in recent where !e.title.isEmpty {
                let key = "\(e.title.lowercased())\u{1F}\(e.artist.lowercased())"
                counts[key, default: 0] += 1
                if rep[key] == nil { rep[key] = e }
            }
            let ranked = counts.sorted { $0.value > $1.value }.compactMap { rep[$0.key] }
            return distinct(ranked)
        }
    }

    public func smartQueueCoverArt(kind: SmartQueueKind, room: String? = nil, limit: Int = 4) -> [String] {
        Self.distinctAlbumArt(
            smartQueueTracks(kind: kind, room: room, limit: 60).map { ($0.album, $0.artist, $0.albumArtURI) },
            limit: limit)
    }

    /// Plays a smart queue's tracks to a room (replace or append).
    public func playSmartQueue(kind: SmartQueueKind, room: String? = nil, group: SonosGroup, append: Bool) async throws {
        let tracks = smartQueueTracks(kind: kind, room: room)
        let items = tracks.compactMap { t -> BrowseItem? in
            guard let uri = t.uri, !uri.isEmpty else { return nil }
            return BrowseItem(id: "SMART:\(kind.rawValue)/\(t.id)", title: t.title,
                              artist: t.artist, album: t.album, albumArtURI: t.albumArtURI,
                              itemClass: .musicTrack, resourceURI: uri, resourceMetadata: t.metadata)
        }
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

    public func deleteLocalSavedQueue(id: Int64) {
        savedQueueRepo.delete(id: id)
        notifyChoragusQueuesChanged()
    }

    /// Removes duplicate tracks (same resource URI) from the queue, keeping
    /// the first occurrence. Snapshots the queue first so it's undoable.
    /// Returns the number of rows removed.
    public func dedupeQueue(group: SonosGroup) async throws -> Int {
        guard let coordinator = group.coordinator else { return 0 }
        // A background queue repair (Apple Music name-swap walker) mutates
        // rows while it runs — positions computed here would be stale by
        // removal time. Skip rather than remove the wrong rows.
        if queueRepairDepth[coordinator.id, default: 0] > 0 {
            sonosDiagLog(.info, tag: "QUEUE",
                         "dedupeQueue skipped — queue repair in flight",
                         context: ["coordinator": coordinator.id])
            return 0
        }
        var collected: [QueueItem] = []
        var index = 0
        while true {
            let (page, total) = try await getQueue(group: group, start: index, count: 500)
            collected.append(contentsOf: page)
            if page.isEmpty || collected.count >= total || index >= 40_000 { break }
            index += page.count
        }
        var seen = Set<String>()
        var duplicates: [(position: Int, uri: String)] = []
        for item in collected {
            guard let uri = item.uri, !uri.isEmpty else { continue }
            if seen.contains(uri) {
                duplicates.append((position: item.id, uri: uri))
            } else {
                seen.insert(uri)
            }
        }
        guard !duplicates.isEmpty else { return 0 }
        await snapshotQueueForHistory(group: group)
        // Remove bottom-up so earlier removals don't shift later positions.
        // Positions were computed across paged awaits — re-verify each
        // row's URI with a single-row browse immediately before removing
        // so a queue mutated since the scan can't lose the wrong track.
        var removed = 0
        for (position, uri) in duplicates.sorted(by: { $0.position > $1.position }) {
            guard let row = try? await contentDirectory.browseQueue(
                    device: coordinator, start: position - 1, count: 1).items.first,
                  row.uri == uri else {
                sonosDiagLog(.info, tag: "QUEUE",
                             "dedupeQueue skipped shifted row",
                             context: ["position": String(position)])
                continue
            }
            try await contentDirectory.removeTrackFromQueue(device: coordinator, objectID: "Q:0/\(position)")
            removed += 1
        }
        postQueueChanged(optimisticItems: [])
        return removed
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

        // Snapshot the queue we're about to wipe so an accidental "play
        // this now" is recoverable from the queue history.
        await snapshotQueueForHistory(group: group)

        // Cache every track's title + art by URI up front so the queue panel
        // can recover them for ALL rows (the speaker returns a filename / no
        // art for direct-URL tracks like Suno), not just the first.
        for it in playable where !it.title.isEmpty {
            guard let u = it.resourceURI, !u.isEmpty else { continue }
            let c = CachedTrack(title: it.title, artist: it.artist, album: it.album, artURL: it.albumArtURI)
            cachedTrackInfo[u] = c
            if let d = u.removingPercentEncoding, d != u { cachedTrackInfo[d] = c }
        }

        // Stop playback first. `RemoveAllTracksFromQueue` on a Sonos
        // coordinator that's actively playing leaves the currently-
        // playing track in the queue (Sonos-side behaviour) — without
        // the stop, "Play All" on a playlist appended its tracks
        // *after* whatever was already playing, producing a 51-track
        // queue from a 50-track playlist with the prior track stuck at
        // position 1. Stopping first lets the clear actually empty the
        // queue, then we rebuild from scratch.
        try? await avTransport.stop(device: coordinator)
        try await contentDirectory.removeAllTracksFromQueue(device: coordinator)
        lastQueueItems[group.coordinatorID] = nil
        cachedTrackByPosition[group.coordinatorID] = nil

        // 1. First track + immediate playback.
        if let uri = first.resourceURI, !uri.isEmpty {
            // Preload cached track info so any speaker poll that arrives
            // before our background fill writes art/title can recover it.
            let cached = CachedTrack(title: first.title,
                                     artist: first.artist,
                                     album: first.album,
                                     artURL: first.albumArtURI)
            if !first.title.isEmpty {
                cachedTrackInfo[uri] = cached
                if let decoded = uri.removingPercentEncoding, decoded != uri {
                    cachedTrackInfo[decoded] = cached
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
            groupTransportStates[coordinator.id] = .playing
            awaitingPlayback[coordinator.id] = false
            setTransportGrace(groupID: coordinator.id, duration: Timing.playbackGracePeriod)
        }

        // First-track refresh: Browse(Q:0) right now so the queue panel
        // shows the one row that's been enqueued + playing while the
        // background fill is still running. Without this, the panel
        // sits empty for the few seconds it takes the background fill
        // to do its first chunk and then refresh.
        postQueueChanged(optimisticItems: [])

        // 2. Remaining tracks in background — cancelling any fill still
        // running for this coordinator from a previous replace, so two
        // consecutive Play All actions can't interleave their chunks.
        let rest = Array(playable.dropFirst())
        if !rest.isEmpty {
            queueFillTasks[coordinator.id]?.cancel()
            queueFillTasks[coordinator.id] = Task { [weak self] in
                await self?.fillQueueInBackground(rest, in: group)
            }
        }
    }

    /// Background batched enqueue used after `playItemsReplacingQueue`
    /// has the first track playing. Sets `isAddingToQueue` so QueueView
    /// shows its spinner; never posts the green status banner.
    ///
    /// Mirrors `addBrowseItemsToQueue`'s resilience: tries the bulk
    /// `AddMultipleURIsToQueue` first, falls back to per-track
    /// `AddURIToQueue` calls if the batch throws OR comes back with
    /// `numAdded == 0`. The previous version did neither — bulk
    /// failures were logged-and-skipped silently, so when the speaker
    /// rejected the first chunk (commonly because the queue is mid-
    /// transition immediately after `play()`), every subsequent track
    /// was lost. Symptom: Play All on a local-library album played
    /// only the first track. Add All to Queue worked because it
    /// already had the fallback.
    private func fillQueueInBackground(_ items: [BrowseItem], in group: SonosGroup) async {
        guard let coordinator = group.coordinator, !items.isEmpty else { return }
        beginAddingToQueue()
        defer {
            endAddingToQueue()
            postQueueChanged(optimisticItems: [])
        }

        // Brief settle window. Sonos has just been told to `play()`
        // for the first track; the bulk-add SOAP request that lands
        // microseconds later sometimes faults because the speaker is
        // still wiring up the new playback context. 300 ms is below
        // any user-perceptible delay (the first track is already
        // playing through the speakers) but enough for the transport
        // state to settle.
        try? await Task.sleep(nanoseconds: 300_000_000)

        var uris: [String] = []
        var metas: [String] = []
        var sources: [BrowseItem] = []
        for item in items {
            // Skip only items with no usable URI. SMAPI containers
            // (`x-rincon-cpcontainer:` album/playlist URIs from
            // Spotify, Apple Music, Plex etc.) DO have a URI and Sonos
            // expands them server-side inside AddMultipleURIsToQueue
            // / AddURIToQueue — same as the singular
            // `addBrowseItemToQueue` path. The earlier `!item.isContainer`
            // filter was silently dropping every container in the
            // background fill, which made Play All on an artist's
            // album list play only the first album.
            guard let uri = item.resourceURI, !uri.isEmpty else { continue }
            uris.append(uri)
            var meta = item.resourceMetadata ?? ""
            meta = DIDLNormalize.metadata(meta)
            metas.append(meta)
            sources.append(item)
            if !item.title.isEmpty {
                let cached = CachedTrack(title: item.title,
                                         artist: item.artist,
                                         album: item.album,
                                         artURL: item.albumArtURI)
                cachedTrackInfo[uri] = cached
                if let decoded = uri.removingPercentEncoding, decoded != uri {
                    cachedTrackInfo[decoded] = cached
                }
            }
        }
        guard !uris.isEmpty else { return }

        let chunkSize = 16
        var repairRows: [(position: Int, uri: String)] = []
        var failedTitles: [String] = []
        for chunkStart in stride(from: 0, to: uris.count, by: chunkSize) {
            // A newer replace-queue action cancels this fill; continuing
            // would append this (stale) selection's chunks into the new
            // queue.
            if Task.isCancelled { return }
            let end = min(chunkStart + chunkSize, uris.count)
            let uriChunk = Array(uris[chunkStart..<end])
            let metaChunk = Array(metas[chunkStart..<end])
            let sourceChunk = Array(sources[chunkStart..<end])

            // Items the bulk call did not land — the whole chunk on a
            // fault, or the tail beyond `numAdded` on a partial add
            // (previously a partial bulk result silently dropped the
            // remainder of the chunk).
            var pending: [BrowseItem] = []
            do {
                let result = try await contentDirectory.addMultipleURIsToQueue(
                    device: coordinator,
                    uris: uriChunk,
                    metadatas: metaChunk,
                    desiredFirstTrackNumberEnqueued: 0,
                    enqueueAsNext: false
                )
                sonosDebugLog("[QUEUE] Background fill chunk \(chunkStart)-\(end-1): firstTrack=\(result.firstTrackNumber) numAdded=\(result.numAdded)")
                if result.firstTrackNumber > 0 {
                    for (offset, u) in uriChunk.prefix(result.numAdded).enumerated() {
                        repairRows.append((position: result.firstTrackNumber + offset, uri: u))
                    }
                }
                if result.numAdded < sourceChunk.count {
                    pending = Array(sourceChunk.dropFirst(max(result.numAdded, 0)))
                }
            } catch {
                sonosDebugLog("[QUEUE] Background fill chunk \(chunkStart)-\(end-1) bulk failed: \(error). Falling back.")
                pending = sourceChunk
            }

            if !pending.isEmpty {
                // Per-track fallback. Same defensive pattern as
                // `addBrowseItemsToQueue` — single-track adds are
                // more forgiving than bulk and recover the cases
                // where the bulk variant rejects mid-transition.
                // Each failed add gets one delayed retry: the observed
                // fault mode is a transient rejection immediately after
                // stop/clear/play, which clears within a second.
                var perTrackAdded = 0
                for (i, item) in pending.enumerated() {
                    guard let uri = item.resourceURI, !uri.isEmpty else { continue }
                    var meta = item.resourceMetadata ?? ""
                    meta = DIDLNormalize.metadata(meta)
                    var added = false
                    for attempt in 1...2 {
                        do {
                            let pos = try await contentDirectory.addURIToQueue(
                                device: coordinator, uri: uri, metadata: meta,
                                desiredFirstTrackNumberEnqueued: 0,
                                enqueueAsNext: false
                            )
                            if pos > 0 { perTrackAdded += 1 }
                            added = true
                            break
                        } catch {
                            sonosDebugLog("[QUEUE] Background per-track add attempt \(attempt) failed for '\(item.title)' (chunk \(chunkStart)+\(i)): \(error)")
                            // Keep going — one bad track shouldn't kill
                            // the rest of the chunk. (Differs from the
                            // user-initiated `addBrowseItemsToQueue`
                            // which breaks on first error to avoid
                            // hammering a misbehaving speaker.)
                            if attempt == 1 {
                                try? await Task.sleep(nanoseconds: 1_000_000_000)
                            }
                        }
                    }
                    if !added { failedTitles.append(item.title) }
                }
                sonosDebugLog("[QUEUE] Background per-track fallback chunk \(chunkStart)-\(end-1): \(perTrackAdded)/\(pending.count)")
            }

            // Refresh the queue panel after each chunk so large
            // playlists fill in visibly instead of jumping from
            // 1 track → N tracks at the very end.
            postQueueChanged(optimisticItems: [])
        }
        scheduleAppleMusicQueueRepair(group: group, rows: repairRows)
        if !failedTitles.isEmpty {
            sonosDebugLog("[QUEUE] Background fill dropped \(failedTitles.count) track(s): \(failedTitles.joined(separator: ", "))")
            ErrorHandler.shared.warning(L10n.queueTracksNotAdded(failedTitles.count), context: "QUEUE")
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
        meta = DIDLNormalize.metadata(meta)
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
        setTransportGrace(groupID: coordinator.id, duration: Timing.playbackGracePeriod)

        try await avTransport.setAVTransportURI(device: coordinator, uri: uri, metadata: metadata)
        try await avTransport.play(device: coordinator)
        // Optimistic .playing — see playItemsReplacingQueue for why.
        // Written after play() so a transport error leaves the UI
        // accurate instead of claiming a play that never started.
        groupTransportStates[coordinator.id] = .playing
        awaitingPlayback[coordinator.id] = false
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

    /// One reachable coordinator per distinct household (S1 + S2 coexist as
    /// separate households on the same LAN). Keyed by householdID, falling back
    /// to coordinatorID before the household resolves.
    private func householdsByCoordinator() -> [String: SonosGroup] {
        var byHousehold: [String: SonosGroup] = [:]
        for g in groups where g.coordinator != nil {
            let hh = g.householdID ?? g.coordinatorID
            if byHousehold[hh] == nil { byHousehold[hh] = g }
        }
        return byHousehold
    }

    /// Normalised key for a library share / item objectID so the same physical
    /// share matches across systems and a child track matches its share root.
    nonisolated static func normalizedShareKey(_ objectID: String) -> String {
        objectID.lowercased()
    }

    /// Pure availability decision for a local-library item against one system's
    /// share set. `S:` items match the specific share (exact root or a child
    /// path under it); `A:` aggregated-index items just need any library.
    /// Returns nil for non-local objectIDs (not our concern).
    nonisolated static func localLibraryPlayable(objectID: String, shareIDs: Set<String>) -> Bool? {
        if objectID.hasPrefix("S:") {
            let key = normalizedShareKey(objectID)
            return shareIDs.contains { key == $0 || key.hasPrefix($0 + "/") }
        }
        if objectID.hasPrefix("A:") {
            return !shareIDs.isEmpty
        }
        return nil
    }

    /// "(S1)" / "(S2)" / "(S1/S2)" from a set of generations, deduped, ordered,
    /// `.unknown` dropped. nil when nothing meaningful remains.
    nonisolated static func availabilityTag(for generations: [SonosSystemVersion]) -> String? {
        let gens = generations
            .filter { $0 != .unknown }
            .reduce(into: [SonosSystemVersion]()) { acc, g in if !acc.contains(g) { acc.append(g) } }
            .sorted { $0.rawValue < $1.rawValue }
        guard !gens.isEmpty else { return nil }
        return "(" + gens.map(\.displayLabel).joined(separator: "/") + ")"
    }

    /// Probe each detected system for its configured library shares and cache
    /// the result. One `Browse("S:")` per system, probed concurrently so the
    /// wait is the slowest single system, not the sum — an unreachable
    /// coordinator costs one SOAP timeout, never a multiple. Fail-soft: a
    /// system that errors is recorded with no shares rather than dropped, and
    /// the next topology refresh re-probes.
    public func refreshHouseholdCapabilities() async {
        let targets: [(household: String, coordinator: SonosDevice)] =
            householdsByCoordinator().compactMap { hh, g in
                g.coordinator.map { (hh, $0) }
            }
        var caps: [String: HouseholdCapabilities] = [:]
        await withTaskGroup(of: HouseholdCapabilities.self) { group in
            for (hh, coord) in targets {
                group.addTask { @MainActor [contentDirectory] in
                    let generation = SonosSystemVersion.classify(swGen: coord.swGen, softwareVersion: coord.softwareVersion)
                    var shareIDs: Set<String> = []
                    if let result = try? await contentDirectory.browse(device: coord, objectID: "S:", start: 0, count: 100) {
                        for item in result.items {
                            shareIDs.insert(Self.normalizedShareKey(item.objectID))
                        }
                    }
                    return HouseholdCapabilities(householdID: hh, generation: generation, shareIDs: shareIDs)
                }
            }
            for await cap in group {
                caps[cap.householdID] = cap
            }
        }
        self.householdCapabilities = caps
    }

    // MARK: Per-household availability — UI helpers

    /// True when more than one Sonos system (household) is on the network, i.e.
    /// when generation tags are meaningful at all.
    public var hasMultipleSystems: Bool { Set(householdCapabilities.keys).count > 1 }

    /// The generations whose system has at least one library share configured.
    public var localLibraryGenerations: [SonosSystemVersion] {
        householdCapabilities.values
            .filter(\.hasLocalLibrary)
            .map(\.generation)
            .filter { $0 != .unknown }
            .reduce(into: [SonosSystemVersion]()) { acc, g in if !acc.contains(g) { acc.append(g) } }
            .sorted { $0.rawValue < $1.rawValue }
    }

    /// "(S1)" / "(S2)" / "(S1/S2)" for a specific share row, or nil when there's
    /// only one system (nothing to disambiguate) or the share is unknown.
    public func availabilityNote(forShareObjectID objectID: String) -> String? {
        guard hasMultipleSystems else { return nil }
        let key = Self.normalizedShareKey(objectID)
        let gens = householdCapabilities.values
            .filter { $0.shareIDs.contains(key) }
            .map(\.generation)
        return Self.availabilityTag(for: gens)
    }

    /// Section-level note for the aggregated library indexes (Artists/Albums/
    /// Tracks/Folders): only shown when systems disagree about *having* a library
    /// at all (some have one, some don't). When every system has a library the
    /// indexes all exist, so no tag — the per-share notes carry the detail.
    private func librarySectionNote() -> String? {
        guard hasMultipleSystems else { return nil }
        let total = householdCapabilities.count
        let withLibrary = householdCapabilities.values.filter(\.hasLocalLibrary).count
        guard withLibrary > 0, withLibrary < total else { return nil }
        let gens = localLibraryGenerations
        guard !gens.isEmpty else { return nil }
        return "(" + gens.map(\.displayLabel).joined(separator: "/") + ")"
    }

    /// Whether the given local-library item can play on `coordinator`'s system.
    /// Share-scoped objectIDs (`S:`) check the specific share; aggregated index
    /// objectIDs (`A:`) check whether the system has any library. Fail-open:
    /// unknown system / unknown capability returns true (never block on missing
    /// data). Returns nil for non-local items (not our concern).
    private func localLibraryPlayable(_ item: BrowseItem, on coordinator: SonosDevice) -> Bool? {
        guard item.objectID.hasPrefix("A:") || item.objectID.hasPrefix("S:") else { return nil }
        // Fail-open: unknown system / not-yet-probed capability never blocks.
        guard let hh = coordinator.householdID, let caps = householdCapabilities[hh] else { return true }
        return Self.localLibraryPlayable(objectID: item.objectID, shareIDs: caps.shareIDs) ?? true
    }

    public func loadBrowseSections() async {
        await refreshHouseholdCapabilities()
        // One-shot legacy cleanup, detached so section load never waits on it.
        Task { await self.purgeLegacySpeakerSnapshots() }
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

        // Tag the aggregated library sections (Artists/Albums/Tracks/Folders)
        // only when systems disagree about having a library at all. Per-share
        // tags inside "Music Library Folders" carry the finer detail.
        if let note = librarySectionNote() {
            sections = sections.map { s in
                guard s.objectID.hasPrefix("A:") || s.objectID.hasPrefix("S:") else { return s }
                var tagged = s
                tagged.availabilityNote = note
                return tagged
            }
        }

        self.browseSections = sections
        saveCache()
    }

    /// Triggers a local music-library reindex (`RefreshShareIndex`) on every
    /// discovered household that has at least one configured share. Hits S1 and
    /// S2 systems automatically — one coordinator per distinct household — and
    /// silently skips households with no library, so a single-system setup
    /// produces no errors. Returns how many systems a reindex was sent to and
    /// how many had a library at all.
    public func updateMusicLibrary() async -> (triggered: Int, librariesFound: Int) {
        // One reachable coordinator per distinct household (S1 + S2).
        let byHousehold = householdsByCoordinator()
        var triggered = 0
        var librariesFound = 0
        for (hh, g) in byHousehold {
            guard let coord = g.coordinator else { continue }
            // Only reindex households that actually have a music-library share —
            // RefreshShareIndex on a library-less household is pointless and can
            // fault. `S:` is the share-list container.
            let shareCount = (try? await contentDirectory.browse(device: coord, objectID: "S:", count: 1).total) ?? 0
            guard shareCount > 0 else {
                sonosDebugLog("[LIBRARY] household \(hh) has no music-library share — skipped")
                continue
            }
            librariesFound += 1
            do {
                try await contentDirectory.refreshShareIndex(device: coord)
                triggered += 1
                sonosDebugLog("[LIBRARY] RefreshShareIndex sent to household \(hh) via \(coord.roomName)")
            } catch {
                sonosDebugLog("[LIBRARY] RefreshShareIndex failed for household \(hh): \(error)")
            }
        }
        return (triggered, librariesFound)
    }

    // MARK: - Music library shares (#75)

    /// One configured music-library share, per household.
    public struct LibraryShare: Identifiable, Hashable {
        /// Unique per household. The browse id alone is NOT unique: two
        /// systems indexing the same NAS path report the identical
        /// `S://host/share` id, and a `ForEach` over duplicate ids
        /// renders one element twice — which showed both rows with the
        /// first row's system tag and would have sent a removal to the
        /// wrong system.
        public var id: String { "\(householdID)|\(objectID)" }
        /// Browse id, e.g. `S://192.168.1.10/Media/Music`. What
        /// `DestroyObject` takes.
        public let objectID: String
        /// UNC path as the speaker reports it.
        public let path: String
        public let householdID: String
        /// Room of the coordinator the share was read from — the same
        /// device any mutation must be sent to.
        public let coordinatorRoom: String
        /// Which system indexes this share. Households running S1 beside
        /// S2 configure the same path twice, once per system, so the
        /// rows are otherwise indistinguishable.
        public let systemVersion: SonosSystemVersion
    }

    /// Lists every household's configured shares. Fail-soft per system:
    /// an unreachable coordinator contributes nothing rather than
    /// failing the whole listing.
    public func libraryShares() async -> [LibraryShare] {
        var out: [LibraryShare] = []
        for (household, group) in householdsByCoordinator() {
            guard let coordinator = group.coordinator else { continue }
            guard let result = try? await contentDirectory.browse(device: coordinator,
                                                                  objectID: BrowseID.shares,
                                                                  start: 0, count: 100) else { continue }
            for item in result.items {
                out.append(LibraryShare(objectID: item.objectID,
                                        path: item.title,
                                        householdID: household,
                                        coordinatorRoom: coordinator.roomName,
                                        systemVersion: group.systemVersion))
            }
        }
        return out.sorted {
            $0.path == $1.path ? $0.systemVersion.displayLabel < $1.systemVersion.displayLabel
                               : $0.path < $1.path
        }
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

    /// A reachable coordinator in the given system, or nil to fall back to the
    /// global `preferredDevice`. Scopes browse/search to the right S1/S2
    /// ContentDirectory so the selected speaker's own library shares are shown.
    private func coordinatorForHousehold(_ householdID: String?) -> SonosDevice? {
        guard let householdID else { return nil }
        // Require a reachable coordinator in the predicate — the household's
        // first group may momentarily lack one while another group has it.
        return groups.first(where: {
            ($0.householdID ?? $0.coordinatorID) == householdID && $0.coordinator != nil
        })?.coordinator
    }

    public func browse(objectID: String, householdID: String?, start: Int = 0, count: Int = PageSize.browse) async throws -> (items: [BrowseItem], total: Int) {
        guard let device = coordinatorForHousehold(householdID) ?? preferredDevice else { return ([], 0) }
        return try await contentDirectory.browse(device: device, objectID: objectID, start: start, count: count)
    }

    public func search(query: String, in containerID: String = BrowseID.tracks, householdID: String?, start: Int = 0, count: Int = PageSize.search) async throws -> (items: [BrowseItem], total: Int) {
        guard let device = coordinatorForHousehold(householdID) ?? preferredDevice else { return ([], 0) }
        return try await contentDirectory.search(device: device, containerID: containerID, searchTerm: query, start: start, count: count)
    }

    // MARK: - Play from Browse

    public func playBrowseItem(_ item: BrowseItem, in group: SonosGroup) async throws {
        guard let coordinator = group.coordinator else { return }

        // Fail-fast: a local-library item whose share isn't configured on the
        // selected speaker's system would 701 on play and surface as a
        // misleading "speaker layout changed" error. Tell the user which Sonos
        // app to add the folders in instead. Fail-open — `localLibraryPlayable`
        // returns true on unknown capability, so we never block on missing data.
        if let playable = localLibraryPlayable(item, on: coordinator), !playable {
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
        // an accidental tap is recoverable from history. This is the canonical
        // "played something by accident" path; it previously had no snapshot,
        // so a built-up queue vanished without a history entry. Self-guards on
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
                    groupTransportStates[coordinator.id] = .playing
                    setTransportGrace(groupID: coordinator.id, duration: Timing.playbackGracePeriod)
                    awaitingPlayback[coordinator.id] = false
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
                    // Promote past the preflight .transitioning.
                    groupTransportStates[coordinator.id] = .playing
                    awaitingPlayback[coordinator.id] = false
                    postQueueChanged(optimisticItems: [])
                } else {
                    // Pre-strategy gate: SMAPI service-track URIs
                    // (`x-sonos-spotify:`, `x-sonos-http:`, `x-sonos-hls:`)
                    // are rejected by direct `SetAVTransportURI` with UPnP
                    // 714 regardless of which strategy would run next. The
                    // `.smapiResolveThenEmpty` resolver makes this strictly
                    // worse for Spotify — it rewrites the URI to
                    // `x-spotify://…` which the speaker also rejects, with
                    // the side effect of stripping the DIDL metadata. We
                    // route every SMAPI service track through the queue
                    // path (same as the working "Play All" button) using
                    // the ORIGINAL `uri` + `meta`, bypassing the strategy
                    // switch entirely. Issue #42.
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
                        // This applies the same resolution the enqueue path
                        // (addBrowseItemToQueue) already does — play and
                        // enqueue now resolve identically.
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
                                try await avTransport.play(device: coordinator)
                            }
                            postQueueChanged(optimisticItems: [])
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
                                groupTransportStates[coordinator.id] = .playing
                                awaitingPlayback[coordinator.id] = false
                                postQueueChanged(optimisticItems: [])
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
                            groupTransportStates[coordinator.id] = .playing
                            awaitingPlayback[coordinator.id] = false
                            postQueueChanged(optimisticItems: [])
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
                    groupTransportStates[coordinator.id] = .playing
                    awaitingPlayback[coordinator.id] = false
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
        } catch {
            awaitingPlayback[coordinator.id] = false
            throw error
        }
    }

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
    /// Pulled out so the regression test in
    /// `BatchQueueFilterTests` can pin the contract that drove issue
    /// "Add All silently no-op'd on artist albums".
    static func isQueueable(_ item: BrowseItem) -> Bool {
        guard let uri = item.resourceURI, !uri.isEmpty else { return false }
        return true
    }

    public func addBrowseItemsToQueue(_ items: [BrowseItem], in group: SonosGroup, playNext: Bool = false) async throws -> Int {
        guard !items.isEmpty else { return 0 }
        if items.count == 1 {
            return try await addBrowseItemToQueue(items[0], in: group, playNext: playNext)
        }
        guard let coordinator = group.coordinator else { return 0 }
        beginAddingToQueue()
        defer { endAddingToQueue() }

        var uris: [String] = []
        var metas: [String] = []
        var optimisticSource: [BrowseItem] = []
        for item in items {
            // Skip only items with no usable URI. SMAPI containers
            // (`x-rincon-cpcontainer:` album/playlist URIs from
            // Spotify, Apple Music, Plex etc.) DO have a URI and Sonos
            // expands them server-side. The earlier `!item.isContainer`
            // filter was silently dropping every container, which is
            // why Add All on an artist's album list (or any list of
            // album/playlist containers) was a no-op while the
            // singular Play Next / Add to Queue paths worked — those
            // never ran the filter. If batch faults on a mixed
            // container payload, the per-item fallback below uses
            // `addURIToQueue` per item, which already accepts
            // containers (see the singular `addBrowseItemToQueue`).
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
                let cached = CachedTrack(title: item.title, artist: item.artist,
                                         album: item.album, artURL: item.albumArtURI)
                cachedTrackInfo[uri] = cached
                if let decoded = uri.removingPercentEncoding, decoded != uri {
                    cachedTrackInfo[decoded] = cached
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
        // Bulk path: try each chunk independently. A single mis-encoded
        // track in the middle of a 21k-track sweep used to abort the
        // whole add — verified via direct SOAP testing that the speaker
        // accepts almost every chunk. Now we collect the failures and
        // retry them per-track instead of throwing away everything.
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
                addingToQueueProgress = numAdded
                consecutiveBulkFailures = 0
                chunkIndex += 1
                if chunkIndex % queueRefreshInterval == 0 {
                    postQueueChanged(optimisticItems: [])
                }
            } catch {
                consecutiveBulkFailures += 1
                // Speaker queue-full detection. Once N chunks fail
                // back-to-back with the same fault, we are past the
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
        // path / metadata) without aborting the rest — the prior
        // assumption "one fail = all fail" was empirically wrong.
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
        postQueueChanged(optimisticItems: [])
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
            // means "append at end", so we skip the extra Browse round-trip that was
            // previously used solely to count the current queue size. S1 hardware
            // feels this difference — one fewer SOAP call per Add to Queue.
        }

        if let rawURI = item.resourceURI, !rawURI.isEmpty {
            let rawMeta = DIDLNormalize.metadata(item.resourceMetadata ?? "")
            // Resolve controller-authenticated SMAPI items (e.g. TIDAL) to a
            // direct stream URL with empty DIDL — same step the play path
            // applies. Without it the raw `sid=…&sn=…` URI faults UPnP 800.
            let (uri, meta) = await resolveSMAPIPlayback(item, uri: rawURI, meta: rawMeta)

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
            postQueueChanged(optimisticItems: optimistic)
            if result > 0 {
                scheduleAppleMusicQueueRepair(group: group, rows: [(position: result, uri: uri)])
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
        if let canonical = MusicServiceCatalog.shared.canonicalDisplayName(forSid: serviceID) {
            return canonical
        }
        return ServiceID.knownNames[serviceID]
    }

    /// Detects the music service from a URI by checking both sid= and URI content patterns.
    /// Memoised wrapper around the original detection logic. Each URI
    /// goes through the same percent-decode + 13 `.contains` + several
    /// `.hasPrefix` chain regardless of how often it's called, so we
    /// cache the result. Hot paths previously hit this function ~30
    /// times per body re-eval (per-row in BrowseListView via
    /// `serviceLabel(for:)` plus the now-playing service tag), and the
    /// cumulative string work was a measurable burst on the main
    /// thread. URIs are immutable so the cache never needs eviction;
    /// in pathological cases (browsing huge libraries) the cache is
    /// still bounded by the URI vocabulary, not by call count.
    private var detectServiceNameCache: [String: String?] = [:]

    public func detectServiceName(fromURI uri: String) -> String? {
        if let cached = detectServiceNameCache[uri] { return cached }
        let result = detectServiceNameUncached(uri)
        detectServiceNameCache[uri] = result
        return result
    }

    private func detectServiceNameUncached(_ uri: String) -> String? {
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
        if groupTransportStates[groupID] != state {
            tagPublish("transport")
            groupTransportStates[groupID] = state
        }
        if state == .playing && awaitingPlayback[groupID] == true {
            awaitingPlayback[groupID] = false
        }
    }

    /// Detects the Sonos TuneIn ad-pre-roll loop by URI signature.
    /// Logs a WARNING when a group enters the ad state and an INFO
    /// when it exits. The user-visible signal is the diagnostic bundle:
    /// when a station "won't play", the bundle now contains an
    /// explicit `[TUNEIN-AD]` event so it's clear Sonos's ad backend
    /// is the cause, not Choragus.
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
        // user unless we say so. Observed with TIDAL queue entries holding
        // an expired pre-signed URL; re-adding the track fixes it.
        let now = Date()
        var recent = (earlyAdvances[groupID] ?? []).filter { now.timeIntervalSince($0) < 60 }
        recent.append(now)
        earlyAdvances[groupID] = recent
        if recent.count >= 3, now.timeIntervalSince(lastEarlyAdvanceReportAt[groupID] ?? .distantPast) > 120 {
            lastEarlyAdvanceReportAt[groupID] = now
            earlyAdvances[groupID] = []
            ErrorHandler.shared.handle(StaleDataError.tracksSkippingEarly,
                                       context: "PLAYBACK", userFacing: true)
        }
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
        // The stale-poll guard that used to live here was wrong in the
        // general case — empirically Sonos's events also lie after a
        // seek/auto-advance combo, so dropping disagreeing polls
        // sometimes filters the only correct source. QueueView now
        // schedules an authoritative `loadQueue()` refresh on any
        // trackURI change instead, which converges on the right state
        // regardless of which source happened to be racy this time.
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
                ensureSunoTitle(forUUID: uuid)
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

        // Recover track info from cache — Apple Music/service queue tracks
        // often return empty TrackMetaData from GetPositionInfo.
        // Position-based fallbacks blocked when actively playing a radio station
        // (has stationName + radio URI), to prevent stale queue metadata from leaking.
        // Apple Music queue tracks use x-sonosapi-hls-static URIs which look like radio
        // but have no stationName — so stationName is the reliable discriminator.
        var enriched = metadata
        // Recover when the speaker gives us no title OR a technical filename —
        // direct-URL tracks (e.g. a Suno CDN `<uuid>.mp3`) report the file name
        // as the title; the real song name is in the play-time cache.
        if enriched.title.isEmpty || TrackMetadata.isTechnicalName(enriched.title) {
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

        // Artwork recovery, independent of the title check above. Direct-URL
        // tracks (e.g. a Suno CDN MP3) frequently report a usable title but no
        // album art on the speaker's poll — without this, art that was already
        // showing gets blanked. Backfill from the play-time art cache.
        if enriched.albumArtURI == nil || enriched.albumArtURI?.isEmpty == true,
           let uri = enriched.trackURI {
            let art = cachedTrackInfo[uri]?.artURL
                ?? (uri.removingPercentEncoding.flatMap { cachedTrackInfo[$0]?.artURL })
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
                // Content-equality gate: skip the publish when only
                // position/duration drifted. The displayed-content view
                // tree (karaoke header, lyrics, ClubVis card) doesn't
                // care about per-poll position deltas — those live on
                // `PositionTracker`. Storing `merged` here without
                // republishing would only affect the snapshot value
                // anyone reads from `groupTrackMetadata`, so we just
                // skip outright when content matches.
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
        // poll; we fill it in via a one-shot iTunes lookup, but the next
        // poll would otherwise overwrite that with empty (or the original
        // album-shaped junk) again. As long as we're still on the same
        // track:
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
        // restored on any flip-back. Observed live 2026-08-08: Silence
        // (Instrumental) atmos → stray publish → same URI back as
        // unknown, pills gone.
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

        // Content-equality gate: see `merged` write above for the
        // rationale. Position-only drift (every 1 Hz poll) used to
        // burst-fire this publisher and re-evaluate every observing
        // view; the content-only check pins the publish to actual
        // content changes (track / album art / station / format flip).
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
        // lookup. We mirror that with a one-shot iTunes lookup by track ID,
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
        // Bail if the track moved on while we waited.
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
        //   1. HLS-favorite DIDLs with empty / album-shaped artist —
        //      original v4.9 use case (fill in the blank).
        //   2. HLS-static playback where Sonos's reported text leaks
        //      stale title/artist from the previous track but the URI
        //      carries the correct catalog ID. iTunes is authoritative
        //      for that ID, so we override the speaker's reported
        //      title/artist with the lookup result.
        guard let uri = metadata.trackURI, !uri.isEmpty else { return }
        guard let songID = URIPrefix.appleMusicSongID(from: uri) else { return }

        // Persistent cache: subsequent plays of the same track hit the
        // local store and skip the network call.
        // Pre-v4.10.1 entries lack `title` / `artURL` — treat them as a
        // miss so the catalog text/art override gets populated on the
        // next play. Within 90 days (current TTL) every replayed track
        // self-migrates without user action.
        let cacheKey = MetadataCacheRepository.Kind.appleMusicTrack.key(songID)
        if let cached = metadataCacheForAppleMusic?.get(cacheKey),
           let data = cached.data(using: .utf8),
           let payload = try? JSONDecoder().decode(AppleMusicTrackEnrichment.self, from: data),
           payload.title != nil {
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
            let trackName = first["trackName"] as? String
            // Upscale 100→600 the same way `AlbumArtSearchService` does.
            let artURL = (first["artworkUrl100"] as? String)
                .map { $0.replacingOccurrences(of: "100x100", with: "600x600") }

            let payload = AppleMusicTrackEnrichment(
                artist: artistName, album: albumName,
                title: trackName, artURL: artURL
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
    /// Standard variations exist and we'd rather preserve Sonos's value
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
        if changed {
            groupTrackMetadata[groupID] = meta
            sonosDebugLog("[ENRICH] Apple Music \(source) → \(payload.title ?? "?") / \(payload.artist) / \(payload.album ?? "?")")
        }
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
    /// Detects technical stream names that should not replace friendly titles.
    /// e.g. "moviesoundtracks_mobile_mp3", "s233145", "stream_128k"

    public func transportDidUpdatePlayMode(_ groupID: String, mode: PlayMode) {
        let now = Date()
        if let grace = modeGraceUntils[groupID], now < grace { return }
        if groupPlayModes[groupID] != mode {
            tagPublish("playMode")
            groupPlayModes[groupID] = mode
        }
    }

    public func transportDidUpdateVolume(_ deviceID: String, volume: Int) {
        let prior = deviceVolumes[deviceID]
        let echoMatched = consumeExpectedVolumeEcho(deviceID: deviceID, value: volume)
        let isNoOp = !echoMatched && prior == volume
        let isCoord = isGroupCoordinator(deviceID: deviceID)
        // Suppress logs for the steady-state no-op case — every
        // device's volume is republished on every poll cycle, and
        // logging "value=X prior=X" pairs here was costing ~50
        // string formats / sec on the main thread (peak observed
        // 4–6 dropped frames per RC-EVENT burst). Only log when
        // something actually changed or an echo was matched.
        if !isNoOp {
            let room = devices[deviceID]?.roomName ?? deviceID
            sonosDebugLog("[RC-EVENT] vol room=\(room) id=\(deviceID) coord=\(isCoord) value=\(volume) prior=\(prior.map(String.init) ?? "nil") echoMatched=\(echoMatched)")
        }
        if echoMatched {
            if !isNoOp {
                let room = devices[deviceID]?.roomName ?? deviceID
                sonosDebugLog("[RC-WRITE] vol DROP-ECHO room=\(room) value=\(volume)")
            }
            return
        }
        let changed = deviceVolumes[deviceID] != volume
        if changed {
            let room = devices[deviceID]?.roomName ?? deviceID
            tagPublish("vol")
            deviceVolumes[deviceID] = volume
            sonosDebugLog("[RC-WRITE] vol APPLY room=\(room) value=\(volume) changed=true")
            // A device set to Fixed line-out jumps to (and pins at) volume 100.
            // Treat a change TO 100 on a line-out model as a trigger to verify
            // GetOutputFixed immediately, so "Fixed Volume" appears without
            // waiting for the user to drag the slider (#50).
            if volume == 100, let dev = devices[deviceID], Self.hasLineOut(dev.modelName),
               !fixedOutputDeviceIDs.contains(Self.bareDeviceID(deviceID)) {
                Task { [weak self] in
                    guard let self else { return }
                    if await self.renderingControl.getOutputFixed(device: dev) {
                        self.fixedOutputDeviceIDs.insert(Self.bareDeviceID(deviceID))
                        self.checkedOutputFixed.insert(Self.bareDeviceID(deviceID))
                        sonosDebugLog("[VOLUME] \(dev.roomName) line-out fixed (vol=100 trigger) — control disabled (#50)")
                    }
                }
            }
        }
        // Group-volume propagation: when a coordinator's volume changes,
        // the Sonos cluster sets per-member volumes at proportional values,
        // but member-level RenderingControl NOTIFY arrives slowly on
        // portable speakers (FP5/Roam: several seconds). A debounced
        // single-shot GetVolume fan-out across the group's other members
        // closes the gap without flooding the wire — the verifier is
        // cancelled and re-scheduled on every coord event during slider
        // drag, so only one fan-out runs per coalesced volume action.
        if changed, isCoord {
            scheduleGroupVolumeVerifier(coordinatorID: deviceID)
        }
    }

    public func transportDidUpdateMute(_ deviceID: String, muted: Bool) {
        let prior = deviceMutes[deviceID]
        let echoMatched = consumeExpectedMuteEcho(deviceID: deviceID, value: muted)
        let isNoOp = !echoMatched && prior == muted
        let isCoord = isGroupCoordinator(deviceID: deviceID)
        // Same no-op suppression as the volume path — see comment
        // there. Mute polling republishes per device per cycle.
        if !isNoOp {
            let room = devices[deviceID]?.roomName ?? deviceID
            sonosDebugLog("[RC-EVENT] mute room=\(room) id=\(deviceID) coord=\(isCoord) value=\(muted) prior=\(prior.map(String.init) ?? "nil") echoMatched=\(echoMatched)")
        }
        if echoMatched {
            if !isNoOp {
                let room = devices[deviceID]?.roomName ?? deviceID
                sonosDebugLog("[RC-WRITE] mute DROP-ECHO room=\(room) value=\(muted)")
            }
            return
        }
        let changed = deviceMutes[deviceID] != muted
        if changed {
            let room = devices[deviceID]?.roomName ?? deviceID
            tagPublish("mute")
            deviceMutes[deviceID] = muted
            sonosDebugLog("[RC-WRITE] mute APPLY room=\(room) value=\(muted) changed=true")
        }
        // Optimistic group propagation: when the *coordinator's* mute
        // event arrives, mirror to all other members on the assumption it
        // was a group-level operation. Coordinator events are consistently
        // fast and reliable across all hardware.
        //
        // Member events do NOT trigger propagation. Portable speakers
        // (Float, Roam) emit their RenderingControl NOTIFY several seconds
        // after the actual change; treating a stale member event as a
        // group trigger caused those late events to flip the coordinator's
        // freshly-correct mute state — every quick mute/unmute on the
        // Sonos app would invert both speakers in the Choragus UI.
        //
        // No verifying SOAP poll runs after propagation. Polling members
        // immediately races the Sonos cluster's own internal sync (1–10 s
        // on Float/Roam) and was reverting correct optimistic updates
        // with stale `false` reads. Late member UPnP events arrive
        // eventually and are no-ops if they match; the 15 s reconciliation
        // poll catches any persistent drift.
        if changed, isGroupCoordinator(deviceID: deviceID) {
            propagateMuteOptimistically(triggerDeviceID: deviceID, muted: muted)
            // Bonded stereo pairs and HT zones don't follow the coordinator's
            // group-mute round-trip — their hardware mute state stays
            // independent. The optimistic propagation above is fine for
            // instant UI feedback on conventional members, but leaves the
            // dict desynced from speaker reality for bonded sets. Schedule
            // a debounced GetMute fan-out to reconcile.
            scheduleGroupMuteVerifier(coordinatorID: deviceID)
        }
    }

    /// True when `deviceID` is the coordinator of any current group.
    /// Used to gate optimistic propagation and verifier scheduling so
    /// only fast, reliable coordinator events drive group-level
    /// reactions.
    private func isGroupCoordinator(deviceID: String) -> Bool {
        groups.contains { $0.coordinatorID == deviceID }
    }

    /// Mirrors a coordinator's mute change to every other member of its
    /// group, skipping members whose `muteGraceUntils` is currently
    /// active (those are echoes of writes we just made). Doesn't touch
    /// the trigger device itself — `transportDidUpdateMute` already did.
    private func propagateMuteOptimistically(triggerDeviceID: String, muted: Bool) {
        guard let group = groups.first(where: { $0.coordinatorID == triggerDeviceID })
        else {
            sonosDebugLog("[RC-PROP] mute SKIP no-coord-group trigger=\(triggerDeviceID)")
            return
        }
        let triggerRoom = devices[triggerDeviceID]?.roomName ?? triggerDeviceID
        let memberCount = group.members.count - 1
        sonosDebugLog("[RC-PROP] mute START coord=\(triggerRoom) groupID=\(group.id) others=\(memberCount) value=\(muted)")
        for member in group.members where member.id != triggerDeviceID {
            let memberRoom = member.roomName
            if deviceMutes[member.id] != muted {
                deviceMutes[member.id] = muted
                sonosDebugLog("[RC-PROP] mute APPLIED member=\(memberRoom) → \(muted)")
            } else {
                sonosDebugLog("[RC-PROP] mute NO-OP member=\(memberRoom) already=\(muted)")
            }
        }
    }

    /// Debounced fan-out poll of non-coordinator member volumes. Cancels
    /// any pending verifier for the same group on each call so a slider
    /// drag (many coord volume events in quick succession) coalesces to
    /// one fan-out ~500 ms after the user releases.
    private func scheduleGroupVolumeVerifier(coordinatorID: String) {
        guard let group = groups.first(where: { $0.coordinatorID == coordinatorID })
        else {
            sonosDebugLog("[RC-VERIFY] vol SKIP no-coord-group trigger=\(coordinatorID)")
            return
        }
        let others = group.members.filter { $0.id != coordinatorID }
        guard !others.isEmpty else {
            sonosDebugLog("[RC-VERIFY] vol SKIP solo-coord group=\(group.id)")
            return
        }
        let coordRoom = devices[coordinatorID]?.roomName ?? coordinatorID
        let cancelled = groupVolumeVerifyTasks[group.id] != nil
        groupVolumeVerifyTasks[group.id]?.cancel()
        sonosDebugLog("[RC-VERIFY] vol SCHED coord=\(coordRoom) groupID=\(group.id) others=\(others.count) replaced=\(cancelled)")
        groupVolumeVerifyTasks[group.id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled {
                sonosDebugLog("[RC-VERIFY] vol CANCELLED coord=\(coordRoom)")
                return
            }
            guard let self else { return }
            sonosDebugLog("[RC-VERIFY] vol FIRE coord=\(coordRoom) groupID=\(group.id)")
            await withTaskGroup(of: Void.self) { tg in
                for member in others {
                    tg.addTask { [weak self] in
                        guard let self else { return }
                        do {
                            let val = try await self.renderingControl.getVolume(device: member)
                            await MainActor.run {
                                // Polled value is authoritative speaker state. If
                                // it matches a pending Choragus write for this
                                // member, consume the expected echo so the
                                // matching NOTIFY (when it arrives) doesn't
                                // double-apply.
                                _ = self.consumeExpectedVolumeEcho(deviceID: member.id, value: val)
                                if self.deviceVolumes[member.id] != val {
                                    let prior = self.deviceVolumes[member.id].map(String.init) ?? "nil"
                                    self.deviceVolumes[member.id] = val
                                    sonosDebugLog("[RC-VERIFY] vol APPLY member=\(member.roomName) prior=\(prior) → \(val)")
                                } else {
                                    sonosDebugLog("[RC-VERIFY] vol NO-OP member=\(member.roomName) already=\(val)")
                                }
                            }
                        } catch {
                            sonosDebugLog("[RC-VERIFY] vol FAIL member=\(member.roomName) error=\(error)")
                        }
                    }
                }
            }
        }
    }

    /// Debounced fan-out poll of non-coordinator member mute state.
    /// Mirrors `scheduleGroupVolumeVerifier`: cancels any pending verifier
    /// for the same group on each call so a rapid mute/unmute toggle
    /// coalesces to one fan-out ~500 ms after the last coord event.
    /// Polled values are authoritative speaker state and override the
    /// optimistic propagation written by `propagateMuteOptimistically`.
    private func scheduleGroupMuteVerifier(coordinatorID: String) {
        guard let group = groups.first(where: { $0.coordinatorID == coordinatorID })
        else {
            sonosDebugLog("[RC-VERIFY] mute SKIP no-coord-group trigger=\(coordinatorID)")
            return
        }
        let others = group.members.filter { $0.id != coordinatorID }
        guard !others.isEmpty else {
            sonosDebugLog("[RC-VERIFY] mute SKIP solo-coord group=\(group.id)")
            return
        }
        let coordRoom = devices[coordinatorID]?.roomName ?? coordinatorID
        let cancelled = groupMuteVerifyTasks[group.id] != nil
        groupMuteVerifyTasks[group.id]?.cancel()
        sonosDebugLog("[RC-VERIFY] mute SCHED coord=\(coordRoom) groupID=\(group.id) others=\(others.count) replaced=\(cancelled)")
        groupMuteVerifyTasks[group.id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled {
                sonosDebugLog("[RC-VERIFY] mute CANCELLED coord=\(coordRoom)")
                return
            }
            guard let self else { return }
            sonosDebugLog("[RC-VERIFY] mute FIRE coord=\(coordRoom) groupID=\(group.id)")
            await withTaskGroup(of: Void.self) { tg in
                for member in others {
                    tg.addTask { [weak self] in
                        guard let self else { return }
                        do {
                            let val = try await self.renderingControl.getMute(device: member)
                            await MainActor.run {
                                // Polled value is authoritative speaker state.
                                // Consume any pending Choragus-write echo so
                                // the matching NOTIFY (when it arrives)
                                // doesn't double-apply.
                                _ = self.consumeExpectedMuteEcho(deviceID: member.id, value: val)
                                if self.deviceMutes[member.id] != val {
                                    let prior = self.deviceMutes[member.id].map(String.init) ?? "nil"
                                    self.deviceMutes[member.id] = val
                                    sonosDebugLog("[RC-VERIFY] mute APPLY member=\(member.roomName) prior=\(prior) → \(val)")
                                } else {
                                    sonosDebugLog("[RC-VERIFY] mute NO-OP member=\(member.roomName) already=\(val)")
                                }
                            }
                        } catch {
                            sonosDebugLog("[RC-VERIFY] mute FAIL member=\(member.roomName) error=\(error)")
                        }
                    }
                }
            }
        }
    }

    /// Per-device debounced GetMute reconciliation, scheduled by `setMute`.
    /// Speaker-as-source-of-truth: after we fire SetMute, schedule a real
    /// GetMute 500 ms later and overwrite the dict with the actual hardware
    /// state. Catches bonded-set members that silently ignore SetMute. Cancel
    /// and reschedule on every successive setMute for the same device, so a
    /// rapid mute/unmute toggle coalesces to one verify after the user stops.
    private func scheduleDeviceMuteVerify(device: SonosDevice) {
        deviceMuteVerifyTasks[device.id]?.cancel()
        deviceMuteVerifyTasks[device.id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            guard let self else { return }
            do {
                let val = try await self.renderingControl.getMute(device: device)
                await MainActor.run {
                    _ = self.consumeExpectedMuteEcho(deviceID: device.id, value: val)
                    if self.deviceMutes[device.id] != val {
                        let prior = self.deviceMutes[device.id].map(String.init) ?? "nil"
                        self.deviceMutes[device.id] = val
                        sonosDebugLog("[RC-VERIFY] mute APPLY device=\(device.roomName) prior=\(prior) → \(val)")
                    } else {
                        sonosDebugLog("[RC-VERIFY] mute NO-OP device=\(device.roomName) already=\(val)")
                    }
                    self.deviceMuteVerifyTasks[device.id] = nil
                }
            } catch {
                sonosDebugLog("[RC-VERIFY] mute FAIL device=\(device.roomName) error=\(error)")
                await MainActor.run { self.deviceMuteVerifyTasks[device.id] = nil }
            }
        }
    }

    /// Mirror of `scheduleDeviceMuteVerify` for SetVolume. Same coalescing
    /// pattern; same source-of-truth contract.
    private func scheduleDeviceVolumeVerify(device: SonosDevice) {
        deviceVolumeVerifyTasks[device.id]?.cancel()
        deviceVolumeVerifyTasks[device.id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            guard let self else { return }
            do {
                let val = try await self.renderingControl.getVolume(device: device)
                await MainActor.run {
                    _ = self.consumeExpectedVolumeEcho(deviceID: device.id, value: val)
                    if self.deviceVolumes[device.id] != val {
                        let prior = self.deviceVolumes[device.id].map(String.init) ?? "nil"
                        self.deviceVolumes[device.id] = val
                        sonosDebugLog("[RC-VERIFY] vol APPLY device=\(device.roomName) prior=\(prior) → \(val)")
                    } else {
                        sonosDebugLog("[RC-VERIFY] vol NO-OP device=\(device.roomName) already=\(val)")
                    }
                    self.deviceVolumeVerifyTasks[device.id] = nil
                }
            } catch {
                sonosDebugLog("[RC-VERIFY] vol FAIL device=\(device.roomName) error=\(error)")
                await MainActor.run { self.deviceVolumeVerifyTasks[device.id] = nil }
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
            let stableMembers = members.sorted { $0.id < $1.id }
            let group = SonosGroup(id: gd.id,
                                   coordinatorID: resolvedCoordinatorID(for: gd,
                                                                        visibleMembers: stableMembers),
                                   members: stableMembers)
            newGroups.append(group)
        }

        self.groups = newGroups.sorted { $0.name < $1.name }
        logTopologyOutcome("event", groups: self.groups)
        saveCache()

        // Notify transport strategy about topology change
        Task {
            await transportStrategy?.onGroupsChanged(groups, devices: devices)
        }
    }

    public func transportDidUpdatePosition(_ groupID: String, position: TimeInterval, duration: TimeInterval) {
        let now = Date()
        if let grace = positionGraceUntils[groupID], now < grace { return }
        // Position + duration live on `positionTracker` (own publisher).
        // Writing here no longer triggers `SonosManager.objectWillChange`,
        // so views observing only the manager don't re-evaluate per
        // 1 Hz position poll. The `[MGR-PUB]` diagnostic stays accurate.
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

    /// Drift-tolerant rebase from a speaker-reported position. Logic
    /// matches the panel's previous in-VM implementation byte-for-byte
    /// — relocated here so every consumer (panel + karaoke window)
    /// reads from one anchor instead of independently rebuilding their
    /// own and drifting apart.
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
        // originator isn't in our cache yet (newly-discovered speaker
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
        if queueRepairActiveGroups.contains(groupID) { return }
        // ContentDirectory `Q:0` event fired. Hand off to the same
        // notification path the optimistic-update sites use so
        // QueueView's existing `onReceive(.queueChanged)` does the
        // `Browse(Q:0)` reload. Empty `optimisticItems` ⇒ subscribers
        // perform a full refresh.
        postQueueChanged(optimisticItems: [])
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
        // Keep the shared playhead anchor in step with play/pause so
        // every consumer freezes/resumes the projection together.
        updatePositionAnchorPlayingState(coordinatorID: groupID,
                                         isPlaying: state.isPlaying)
    }

    public func updatePlayMode(_ groupID: String, mode: PlayMode) {
        groupPlayModes[groupID] = mode
    }

    public func updateDeviceVolume(_ deviceID: String, volume: Int) {
        // Portable-speaker volume diagnostic. When a Move/Roam reports
        // volume=0 we capture model + transport URI + group state so
        // the maintainer can confirm whether the speaker is on
        // Bluetooth input (the audio pipeline ignores WiFi-side
        // RenderingControl in that mode). Fires before the equality
        // gate so a sustained "always 0" condition still leaves one
        // entry in the diag log per group state change. Gated to
        // portables to avoid drowning the log in legitimate
        // user-muted=0 reads from regular speakers.
        if volume == 0,
           let device = devices[deviceID],
           device.isPortable {
            let group = groups.first(where: { g in g.members.contains(where: { $0.id == deviceID }) })
            let coord = group?.coordinatorID ?? "?"
            let trackURI = group.flatMap { groupTrackMetadata[$0.coordinatorID]?.trackURI } ?? "?"
            let transport = group.flatMap { groupTransportStates[$0.coordinatorID]?.rawValue } ?? "?"
            sonosDiagLog(.info, tag: "PORTABLE_VOL",
                         "Portable \(device.modelName) reports volume=0 (room=\(device.roomName))",
                         context: [
                            "deviceID": deviceID,
                            "model": device.modelName,
                            "modelNumber": device.modelNumber,
                            "groupCoordinator": coord,
                            "trackURI": trackURI,
                            "transportState": transport,
                            "groupMemberCount": String(group?.members.count ?? 0)
                         ])
        }
        // Equality gate — `scanGroup()` calls this for every member of
        // every group after every topology refresh, and the value is
        // typically unchanged from the prior poll. Without the guard,
        // 10 speakers refreshing each emit 10+ publishes/sec of
        // identical-value writes that flood the karaoke window's
        // invalidation queue.
        if deviceVolumes[deviceID] != volume {
            tagPublish("vol")
            deviceVolumes[deviceID] = volume
        }
    }

    public func updateDeviceMute(_ deviceID: String, muted: Bool) {
        if deviceMutes[deviceID] != muted {
            tagPublish("mute")
            deviceMutes[deviceID] = muted
        }
    }

    public func updateAwaitingPlayback(_ groupID: String, awaiting: Bool) {
        if awaitingPlayback[groupID] != awaiting {
            tagPublish("awaiting")
            awaitingPlayback[groupID] = awaiting
        }
    }
}
extension SonosManager: ArtCacheProtocol {}
