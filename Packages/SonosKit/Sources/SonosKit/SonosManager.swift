/// SonosManager.swift — Central coordinator for all Sonos operations.
///
/// Acts as the single source of truth for speaker topology, playback control,
/// browsing, and caching. All UPnP service calls are funneled through here so
/// the UI layer never touches SOAP directly. Uses a "Quick Start" cache system
/// to show speakers instantly on launch while live discovery runs in the background.
import Foundation

public enum StartupMode: String, CaseIterable {
    case quickStart = "Quick Start"
    case classic = "Classic"
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

    @Published public var startupMode: StartupMode {
        didSet { UserDefaults.standard.set(startupMode.rawValue, forKey: "startupMode") }
    }

    // MARK: - Private Services

    private let discovery = SSDPDiscovery()
    private let soap = SOAPClient()
    // Lazy so services share a single SOAPClient (and its URLSession)
    private lazy var avTransport = AVTransportService(soap: soap)
    private lazy var renderingControl = RenderingControlService(soap: soap)
    private lazy var zoneTopology = ZoneGroupTopologyService(soap: soap)
    private lazy var contentDirectory = ContentDirectoryService(soap: soap)
    private lazy var alarmClock = AlarmClockService(soap: soap)
    private lazy var musicServices = MusicServicesService(soap: soap)

    private let cache = SonosCache()
    private var discoveredLocations: Set<String> = []  // de-dups SSDP responses
    private var refreshTimer: Timer?

    public init() {
        let saved = UserDefaults.standard.string(forKey: "startupMode") ?? StartupMode.quickStart.rawValue
        self.startupMode = StartupMode(rawValue: saved) ?? .quickStart

        discovery.onDeviceFound = { [weak self] location, ip, port in
            Task { @MainActor [weak self] in
                await self?.handleDiscoveredDevice(location: location, ip: ip, port: port)
            }
        }
    }

    // MARK: - Startup

    public func startDiscovery() {
        guard !isDiscovering else { return }

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
                self?.discovery.rescan()
            }
        }
    }

    public func stopDiscovery() {
        isDiscovering = false
        discovery.stopDiscovery()
        refreshTimer?.invalidate()
        refreshTimer = nil
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
            print("Failed to fetch device description from \(location): \(error)")
        }
    }

    public func refreshTopology(from device: SonosDevice) async {
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

            self.groups = newGroups.sorted { $0.name < $1.name }
            self.isUsingCachedData = false
            self.isRefreshing = false
            self.staleMessage = nil

            // Save to cache for next launch
            saveCache()
        } catch {
            print("Failed to fetch zone topology: \(error)")
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

    // MARK: - Queue

    public func getQueue(group: SonosGroup, start: Int = 0, count: Int = 100) async throws -> (items: [QueueItem], total: Int) {
        guard let coordinator = group.coordinator else { return ([], 0) }
        return try await contentDirectory.browseQueue(device: coordinator, start: start, count: count)
    }

    public func removeFromQueue(group: SonosGroup, trackIndex: Int) async throws {
        guard let coordinator = group.coordinator else { return }
        try await contentDirectory.removeTrackFromQueue(device: coordinator, objectID: "Q:0/\(trackIndex)")
    }

    public func clearQueue(group: SonosGroup) async throws {
        guard let coordinator = group.coordinator else { return }
        try await contentDirectory.removeAllTracksFromQueue(device: coordinator)
    }

    public func playTrackFromQueue(group: SonosGroup, trackNumber: Int) async throws {
        guard let coordinator = group.coordinator else { return }
        try await contentDirectory.seekToTrack(device: coordinator, trackNumber: trackNumber)
        try await avTransport.play(device: coordinator)
    }

    public func moveTrackInQueue(group: SonosGroup, from: Int, to: Int) async throws {
        guard let coordinator = group.coordinator else { return }
        try await contentDirectory.reorderTracksInQueue(device: coordinator, startIndex: from, numberOfTracks: 1, insertBefore: to)
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

    public func getAlarms() async throws -> [SonosAlarm] {
        guard let anyDevice = preferredDevice else { return [] }
        var alarms = try await alarmClock.listAlarms(device: anyDevice)
        for i in alarms.indices {
            if let dev = devices[alarms[i].roomUUID] {
                alarms[i].roomName = dev.roomName
            }
        }
        return alarms
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

        sections.append(BrowseSection(id: "favorites", title: "Sonos Favorites", objectID: "FV:2", icon: "star.fill"))

        if let total = await probeContainer(device: anyDevice, objectID: "SQ:"), total > 0 {
            sections.append(BrowseSection(id: "playlists", title: "Sonos Playlists", objectID: "SQ:", icon: "music.note.list"))
        }

        do {
            let (items, _) = try await contentDirectory.browse(device: anyDevice, objectID: "A:", start: 0, count: 20)
            for item in items {
                let icon = libraryIcon(for: item.id)
                sections.append(BrowseSection(id: item.id, title: item.title, objectID: item.id, icon: icon))
            }
        } catch {
            sections.append(BrowseSection(id: "artists", title: "Artists", objectID: "A:ALBUMARTIST", icon: "person.2"))
            sections.append(BrowseSection(id: "albums", title: "Albums", objectID: "A:ALBUM", icon: "square.stack"))
            sections.append(BrowseSection(id: "tracks", title: "Tracks", objectID: "A:TRACKS", icon: "music.note"))
        }

        if let total = await probeContainer(device: anyDevice, objectID: "S:"), total > 0 {
            sections.append(BrowseSection(id: "shares", title: "Music Library Folders", objectID: "S:", icon: "externaldrive.connected.to.line.below"))
        }

        if let total = await probeContainer(device: anyDevice, objectID: "R:0"), total > 0 {
            sections.append(BrowseSection(id: "radio", title: "Radio", objectID: "R:0", icon: "antenna.radiowaves.left.and.right"))
        }

        self.browseSections = sections
        saveCache()
    }

    public func loadMusicServices() async {
        guard musicServicesList.isEmpty else { return }
        for attempt in 0..<3 {
            if attempt > 0 {
                try? await Task.sleep(for: .seconds(3))
            }
            do {
                let all = try await getAvailableMusicServices()
                if !all.isEmpty {
                    musicServicesList = all
                    return
                }
            } catch {
                print("Music services attempt \(attempt + 1) failed: \(error)")
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

    public func browse(objectID: String, start: Int = 0, count: Int = 100) async throws -> (items: [BrowseItem], total: Int) {
        guard let anyDevice = preferredDevice else { return ([], 0) }
        return try await contentDirectory.browse(device: anyDevice, objectID: objectID, start: start, count: count)
    }

    public func search(query: String, in containerID: String = "A:TRACKS", start: Int = 0, count: Int = 50) async throws -> (items: [BrowseItem], total: Int) {
        guard let anyDevice = preferredDevice else { return ([], 0) }
        return try await contentDirectory.search(device: anyDevice, containerID: containerID, searchTerm: query, start: start, count: count)
    }

    // MARK: - Play from Browse

    public func playBrowseItem(_ item: BrowseItem, in group: SonosGroup) async throws {
        guard let coordinator = group.coordinator else { return }

        if let uri = item.resourceURI, !uri.isEmpty {
            try await withStaleHandling(for: group.name) {
                try await avTransport.setAVTransportURI(
                    device: coordinator, uri: uri, metadata: item.resourceMetadata ?? ""
                )
                try await avTransport.play(device: coordinator)
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

    public func addBrowseItemToQueue(_ item: BrowseItem, in group: SonosGroup, playNext: Bool = false) async throws {
        guard let coordinator = group.coordinator else { return }

        if let uri = item.resourceURI, !uri.isEmpty {
            _ = try await contentDirectory.addURIToQueue(device: coordinator, uri: uri, metadata: item.resourceMetadata ?? "", enqueueAsNext: playNext)
        } else if item.isContainer {
            let containerURI = makeContainerURI(item)
            _ = try await contentDirectory.addURIToQueue(device: coordinator, uri: containerURI, enqueueAsNext: playNext)
        }
    }

    /// Builds a URI that Sonos understands for enqueuing an entire container.
    /// Each prefix maps to a different Sonos protocol scheme:
    ///   SQ: = saved queues stored in flash, A:/S: = local library playlists
    private func makeContainerURI(_ item: BrowseItem) -> String {
        let objectID = item.id
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

    /// Returns a reliable device for SOAP calls — prefers a group coordinator
    /// over an arbitrary device from the dictionary, since coordinators are
    /// always full speakers (never subs or satellites)
    private var preferredDevice: SonosDevice? {
        groups.first?.coordinator ?? devices.values.first
    }
}
