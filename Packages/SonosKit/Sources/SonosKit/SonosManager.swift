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

public enum AppearanceMode: String, CaseIterable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
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

    /// Cached art URLs discovered during playback
    /// Used by browse list to show art for items that lack it in their DIDL
    @Published public var discoveredArtURLs: [String: String] = [:]

    /// The objectID of the last favorite that was played — used to map art back to the browse list
    public var lastPlayedFavoriteID: String?

    /// Optional play history manager — set from app layer
    public var playHistoryManager: PlayHistoryManager?

    /// Set when user initiates playback, cleared only when speaker confirms playing
    @Published public var awaitingPlayback: [String: Bool] = [:]

    /// Drag state for cross-view drag-and-drop (browse → queue)
    public var draggedBrowseItem: BrowseItem?

    /// Stores an art URL with multiple cache keys for flexible lookup
    public func cacheArtURL(_ artURL: String, forURI uri: String, title: String = "", itemID: String = "") {
        if !uri.isEmpty {
            discoveredArtURLs[uri] = artURL
        }
        if !title.isEmpty {
            discoveredArtURLs["title:\(title.lowercased())"] = artURL
            let normalized = Self.normalizeForCache(title)
            if !normalized.isEmpty {
                discoveredArtURLs["norm:\(normalized)"] = artURL
            }
        }
        if !itemID.isEmpty {
            discoveredArtURLs[itemID] = artURL
        }
        persistArtCache()
    }

    private var artCacheSaveTask: Task<Void, Never>?

    /// Debounced persist of art URL cache to disk
    private func persistArtCache() {
        artCacheSaveTask?.cancel()
        artCacheSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Timing.rescanDebounce)
            guard !Task.isCancelled, let self else { return }
            self.cache.saveArtURLs(self.discoveredArtURLs)
        }
    }

    /// Looks up cached art by URI, exact title, or normalized title
    public func lookupCachedArt(uri: String?, title: String) -> String? {
        if let uri = uri, let art = discoveredArtURLs[uri] { return art }
        if let art = discoveredArtURLs["title:\(title.lowercased())"] { return art }
        let normalized = Self.normalizeForCache(title)
        if !normalized.isEmpty, let art = discoveredArtURLs["norm:\(normalized)"] { return art }
        return nil
    }

    private static func normalizeForCache(_ title: String) -> String {
        title.lowercased()
            .replacingOccurrences(of: " - ", with: " ")
            .replacingOccurrences(of: "radio", with: "")
            .replacingOccurrences(of: "station", with: "")
            .components(separatedBy: .alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
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

    private let discovery = SSDPDiscovery()
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

    /// Cached track info — populated when adding Service Search items to queue.
    /// Used to recover title/artist when the speaker returns empty TrackMetaData.
    struct CachedTrack { let title: String; let artist: String; let album: String; let artURL: String? }
    private var cachedTrackInfo: [String: CachedTrack] = [:]          // keyed by URI
    private var cachedTrackByPosition: [String: [Int: CachedTrack]] = [:] // keyed by groupID -> queue position

    /// Last-fetched queue items per group — used for track info recovery
    private var lastQueueItems: [String: [QueueItem]] = [:]
    private var refreshTimer: Timer?
    private var isRefreshingTopology = false  // serializes topology refreshes to prevent concurrent dictionary mutation

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

    /// Default init with production services
    public convenience init() {
        self.init(soap: SOAPClient(), cache: SonosCache())
    }

    /// Injectable init for testing
    public init(soap: SOAPClient, cache: SonosCache) {
        self.soap = soap
        self.cache = cache

        let savedStartup = UserDefaults.standard.string(forKey: UDKey.startupMode) ?? StartupMode.quickStart.rawValue
        self.startupMode = StartupMode(rawValue: savedStartup) ?? .quickStart

        let savedComms = UserDefaults.standard.string(forKey: UDKey.communicationMode) ?? CommunicationMode.hybridEventFirst.rawValue
        self.communicationMode = CommunicationMode(rawValue: savedComms) ?? .hybridEventFirst

        let savedAppearance = UserDefaults.standard.string(forKey: UDKey.appearanceMode) ?? AppearanceMode.system.rawValue
        self.appearanceMode = AppearanceMode(rawValue: savedAppearance) ?? .system

        let savedLang = UserDefaults.standard.string(forKey: UDKey.appLanguage) ?? AppLanguage.english.rawValue
        self.appLanguage = AppLanguage(rawValue: savedLang) ?? .english

        self.accentColor = StoredColor.load(from: "accentColor", default: .system)
        self.playingZoneColor = StoredColor.load(from: "playingZoneColor", default: StoredColor(red: 0.2, green: 0.78, blue: 0.35))
        self.inactiveZoneColor = StoredColor.load(from: "inactiveZoneColor", default: StoredColor(red: 0.56, green: 0.56, blue: 0.58))

        discovery.onDeviceFound = { [weak self] location, ip, port in
            Task { @MainActor [weak self] in
                await self?.handleDiscoveredDevice(location: location, ip: ip, port: port)
            }
        }
    }

    // MARK: - Startup

    public func startDiscovery() {
        guard !isDiscovering else { return }

        // Restore persisted art URL mappings (independent of startup mode)
        let savedArtURLs = cache.loadArtURLs()
        if !savedArtURLs.isEmpty {
            discoveredArtURLs = savedArtURLs
        }

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
        discovery.startDiscovery()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.discoveredLocations.removeAll()
                self?.discovery.rescan()
            }
        }
    }

    public func stopDiscovery() {
        isDiscovering = false
        discovery.stopDiscovery()
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
        discovery.rescan()
    }

    private func handleDiscoveredDevice(location: String, ip: String, port: Int) async {
        guard !discoveredLocations.contains(location) else { return }
        discoveredLocations.insert(location)

        do {
            guard let desc = try await DeviceDescriptionParser.fetch(from: location) else { return }

            let device = SonosDevice(
                id: desc.uuid,
                ip: ip,
                port: port,
                roomName: desc.roomName,
                modelName: desc.modelName,
                modelNumber: desc.modelNumber
            )

            devices[device.id] = device
            await refreshTopology(from: device)
        } catch {
            sonosDebugLog("[DISCOVERY] Device description fetch failed: \(error)")
        }
    }

    public func refreshTopology(from device: SonosDevice) async {
        // Serialize: only one topology refresh at a time. Concurrent calls get the
        // same data anyway (topology is system-wide), and racing on dictionary
        // mutations causes memory corruption (malloc free-list corruption).
        guard !isRefreshingTopology else { return }
        isRefreshingTopology = true
        defer { isRefreshingTopology = false }

        do {
            let groupData = try await zoneTopology.getZoneGroupState(device: device)

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
                    // Invisible members are Sub/Surround satellites — hide from UI
                    if !md.isInvisible {
                        members.append(dev)
                    }
                }
                let group = SonosGroup(id: gd.id, coordinatorID: gd.coordinatorUUID, members: members)
                newGroups.append(group)
            }

            let sortedGroups = newGroups.sorted { $0.name < $1.name }

            // Only update groups if topology actually changed — prevents UI flash
            let changed = sortedGroups.count != groups.count ||
                zip(sortedGroups, groups).contains { new, old in
                    new.id != old.id ||
                    new.coordinatorID != old.coordinatorID ||
                    new.members.count != old.members.count ||
                    zip(new.members, old.members).contains { $0.id != $1.id }
                }

            if changed {
                self.groups = sortedGroups
                saveCache()
            }

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
            if state.isActive,
               let mediaInfo = try? await avTransport.getMediaInfo(device: coordinator) {
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
        try await contentDirectory.removeAllTracksFromQueue(device: coordinator)
        lastQueueItems[group.coordinatorID] = nil
        cachedTrackByPosition[group.coordinatorID] = nil
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
        await refreshTopology(from: coordinator)
    }

    public func ungroupDevice(_ device: SonosDevice) async throws {
        try await avTransport.becomeCoordinatorOfStandaloneGroup(device: device)
        await refreshTopology(from: device)
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
                do {
                    try await contentDirectory.removeAllTracksFromQueue(device: coordinator)
                    _ = try await contentDirectory.addURIToQueue(
                        device: coordinator, uri: uri, metadata: meta
                    )
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
            }
        } else if item.isContainer {
            try await withStaleHandling(for: group.name) {
                try await contentDirectory.removeAllTracksFromQueue(device: coordinator)
                let containerURI = makeContainerURI(item)
                _ = try await contentDirectory.addURIToQueue(device: coordinator, uri: containerURI)
                try await avTransport.setAVTransportURI(device: coordinator, uri: "x-rincon-queue:\(coordinator.id)#0")
                try await avTransport.play(device: coordinator)
            }
        }
    }

    @discardableResult
    public func addBrowseItemToQueue(_ item: BrowseItem, in group: SonosGroup, playNext: Bool = false, atPosition: Int = 0) async throws -> Int {
        guard let coordinator = group.coordinator else { return 0 }

        // Determine insertion position
        var insertAt = atPosition
        if atPosition == 0 {
            if playNext {
                // Play next: insert after current track, or at start if queue is dormant
                let posInfo = try? await avTransport.getPositionInfo(device: coordinator)
                let currentTrack = posInfo?.trackNumber ?? 0
                insertAt = currentTrack > 0 ? currentTrack + 1 : 1
            } else {
                // Add to queue: always append at end
                let (_, total) = try await contentDirectory.browseQueue(device: coordinator, start: 0, count: 1)
                insertAt = total + 1
            }
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
            let result = try await contentDirectory.addURIToQueue(device: coordinator, uri: uri, metadata: meta, desiredFirstTrackNumberEnqueued: insertAt, enqueueAsNext: false)

            // Cache by queue position for trackNumber-based recovery
            if !item.title.isEmpty && result > 0 {
                let groupID = group.coordinatorID
                if cachedTrackByPosition[groupID] == nil { cachedTrackByPosition[groupID] = [:] }
                cachedTrackByPosition[groupID]?[result] = cached
            }
            NotificationCenter.default.post(name: .queueChanged, object: nil)
            return result
        } else if item.isContainer {
            let containerURI = makeContainerURI(item)
            sonosDebugLog("[QUEUE] Adding container to queue: \(containerURI.prefix(60)) atPos=\(insertAt)")
            let result = try await contentDirectory.addURIToQueue(device: coordinator, uri: containerURI, desiredFirstTrackNumberEnqueued: insertAt, enqueueAsNext: false)
            NotificationCenter.default.post(name: .queueChanged, object: nil)
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
        var enriched = metadata
        if enriched.title.isEmpty {
            var cached: CachedTrack?

            // Try URI match first (both encoded and decoded)
            if let uri = enriched.trackURI, !uri.isEmpty {
                cached = cachedTrackInfo[uri]
                if cached == nil, let decoded = uri.removingPercentEncoding {
                    cached = cachedTrackInfo[decoded]
                }
            }

            // Fall back to queue position match (from addURIToQueue)
            if cached == nil, enriched.trackNumber > 0 {
                cached = cachedTrackByPosition[groupID]?[enriched.trackNumber]
            }

            // Fall back to last-fetched queue items (from getQueue/browseQueue)
            if cached == nil, enriched.trackNumber > 0,
               let queueItems = lastQueueItems[groupID] {
                let idx = enriched.trackNumber - 1 // queue items are 0-indexed, trackNumber is 1-indexed
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
                if let newArt = enriched.albumArtURI, !newArt.isEmpty {
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

        // Only carry forward art if the track hasn't changed
        let isStillRadio = !updated.stationName.isEmpty
        if updated.albumArtURI == nil, let existingArt = existing.albumArtURI, !trackChanged {
            if isStillRadio || existing.stationName.isEmpty {
                updated.albumArtURI = existingArt
            }
        }
        groupTrackMetadata[groupID] = updated

        // Ensure art URL from cache is available for history recording.
        // Apple Music tracks may have /getaa? art (filtered by history) or no art,
        // but we cached the iTunes art URL when adding to queue.
        if updated.albumArtURI == nil || updated.albumArtURI?.contains("/getaa?") == true {
            if let cachedArt = lookupCachedArt(uri: updated.trackURI, title: updated.title) {
                updated.albumArtURI = cachedArt
                groupTrackMetadata[groupID] = updated
            }
        }

        // Log to play history for all groups
        if let group = groups.first(where: { $0.coordinatorID == groupID || $0.id == groupID }) {
            playHistoryManager?.trackMetadataChanged(
                groupID: groupID,
                metadata: updated,
                groupName: group.name,
                transportState: groupTransportStates[groupID] ?? .stopped
            )
        }
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
        if deviceMutes[deviceID] != muted { deviceMutes[deviceID] = muted }
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
