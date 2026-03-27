/// Protocols.swift — Service protocols for dependency injection and testability.
///
/// Services conform to these protocols, enabling mock implementations for testing
/// and swappable backends. ViewModels depend on focused protocols (ISP), not the
/// full SonosManager concrete type.
import Foundation
import AppKit

// MARK: - SOAP Client

public protocol SOAPClientProtocol {
    func send(
        to baseURL: URL,
        path: String,
        service: String,
        action: String,
        arguments: [(String, String)]
    ) async throws -> [String: String]
}

// MARK: - Image Cache

public protocol ImageCacheProtocol {
    var maxSizeMB: Int { get set }
    var maxAgeDays: Int { get set }
    var diskUsage: Int { get }
    var diskUsageString: String { get }
    var fileCount: Int { get }

    func image(for url: URL) -> NSImage?
    func store(_ image: NSImage, for url: URL)
    func clearDisk()
    func clearMemory()
}

// MARK: - Topology Cache

public protocol SonosCacheProtocol {
    func save(groups: [SonosGroup], devices: [String: SonosDevice], browseSections: [BrowseSection])
    func load() -> CachedTopology?
    func clear()
    func restoreDevices(from cached: CachedTopology) -> [String: SonosDevice]
    func restoreGroups(from cached: CachedTopology, devices: [String: SonosDevice]) -> [SonosGroup]
    func restoreBrowseSections(from cached: CachedTopology) -> [BrowseSection]
    func saveArtURLs(_ urls: [String: String])
    func loadArtURLs() -> [String: String]
}

// MARK: - Album Art Search

public protocol AlbumArtSearchProtocol {
    func searchArtwork(artist: String, album: String) async -> String?
    func searchRadioTrackArt(artist: String, title: String) async -> String?
}

// MARK: - Playback Service (SRP: transport control only)

@MainActor
public protocol PlaybackServiceProtocol {
    func play(group: SonosGroup) async throws
    func pause(group: SonosGroup) async throws
    func stop(group: SonosGroup) async throws
    func next(group: SonosGroup) async throws
    func previous(group: SonosGroup) async throws
    func seek(group: SonosGroup, to time: String) async throws
    func getTransportState(group: SonosGroup) async throws -> TransportState
    func getMediaInfo(group: SonosGroup) async throws -> [String: String]
    func getPositionInfo(group: SonosGroup) async throws -> TrackMetadata
    func getPlayMode(group: SonosGroup) async throws -> PlayMode
    func setPlayMode(group: SonosGroup, mode: PlayMode) async throws
    func getCrossfadeMode(group: SonosGroup) async throws -> Bool
    func setCrossfadeMode(group: SonosGroup, enabled: Bool) async throws
    func setSleepTimer(group: SonosGroup, duration: String) async throws
    func cancelSleepTimer(group: SonosGroup) async throws
    func getSleepTimerRemaining(group: SonosGroup) async throws -> String
    func playURI(group: SonosGroup, uri: String, metadata: String, title: String, artist: String, stationName: String, albumArtURI: String?) async throws
    func playBrowseItem(_ item: BrowseItem, in group: SonosGroup) async throws
    func pauseAll() async
    func resumeAll() async
}

// MARK: - Volume Service (SRP: volume and mute only)

@MainActor
public protocol VolumeServiceProtocol {
    func getVolume(device: SonosDevice) async throws -> Int
    func setVolume(device: SonosDevice, volume: Int) async throws
    func getMute(device: SonosDevice) async throws -> Bool
    func setMute(device: SonosDevice, muted: Bool) async throws
    func setVolumeGrace(deviceID: String, duration: TimeInterval)
    func setMuteGrace(deviceID: String, duration: TimeInterval)
    func isVolumeGraceActive(deviceID: String) -> Bool
    func isMuteGraceActive(deviceID: String) -> Bool
}

// MARK: - EQ Service (SRP: equalizer controls only)

@MainActor
public protocol EQServiceProtocol {
    func getBass(device: SonosDevice) async throws -> Int
    func setBass(device: SonosDevice, bass: Int) async throws
    func getTreble(device: SonosDevice) async throws -> Int
    func setTreble(device: SonosDevice, treble: Int) async throws
    func getLoudness(device: SonosDevice) async throws -> Bool
    func setLoudness(device: SonosDevice, enabled: Bool) async throws
    func getEQ(device: SonosDevice, eqType: String) async throws -> Int
    func setEQ(device: SonosDevice, eqType: String, value: Int) async throws
}

// MARK: - Queue Service (SRP: queue management only)

@MainActor
public protocol QueueServiceProtocol {
    func getQueue(group: SonosGroup, start: Int, count: Int) async throws -> (items: [QueueItem], total: Int)
    func removeFromQueue(group: SonosGroup, trackIndex: Int) async throws
    func clearQueue(group: SonosGroup) async throws
    func playTrackFromQueue(group: SonosGroup, trackNumber: Int) async throws
    func moveTrackInQueue(group: SonosGroup, from: Int, to: Int) async throws
    func saveQueueAsPlaylist(group: SonosGroup, title: String) async throws -> String
    @discardableResult
    func addBrowseItemToQueue(_ item: BrowseItem, in group: SonosGroup, playNext: Bool, atPosition: Int) async throws -> Int
}

// MARK: - Browsing Service (SRP: content browsing only)

@MainActor
public protocol BrowsingServiceProtocol {
    func browse(objectID: String, start: Int, count: Int) async throws -> (items: [BrowseItem], total: Int)
    func browseMetadata(objectID: String) async throws -> BrowseItem?
    func search(query: String, in containerID: String, start: Int, count: Int) async throws -> (items: [BrowseItem], total: Int)
    func loadBrowseSections() async
    func addToPlaylist(playlistID: String, item: BrowseItem) async throws
    func deletePlaylist(playlistID: String) async throws
    func renamePlaylist(playlistID: String, oldTitle: String, newTitle: String) async throws
}

// MARK: - Grouping Service (SRP: speaker grouping only)

@MainActor
public protocol GroupingServiceProtocol {
    func joinGroup(device: SonosDevice, toCoordinator coordinator: SonosDevice) async throws
    func ungroupDevice(_ device: SonosDevice) async throws
}

// MARK: - Alarm Service (SRP: alarm management only)

@MainActor
public protocol AlarmServiceProtocol {
    func getAlarms() async throws -> [SonosAlarm]
    func updateAlarm(_ alarm: SonosAlarm) async throws
    func deleteAlarm(_ alarm: SonosAlarm) async throws
}

// MARK: - Music Service Detection (SRP: service name resolution)

@MainActor
public protocol MusicServiceDetectionProtocol {
    func musicServiceName(for serviceID: Int) -> String?
    func detectServiceName(fromURI uri: String) -> String?
    func musicServiceName(fromDescriptor desc: String) -> String?
    func serviceLabel(for item: BrowseItem) -> String?
}

// MARK: - Transport State Provider (read-only state for ViewModels)

@MainActor
public protocol TransportStateProviding {
    var groupTransportStates: [String: TransportState] { get set }
    var groupTrackMetadata: [String: TrackMetadata] { get set }
    var groupPlayModes: [String: PlayMode] { get set }
    var groupPositions: [String: TimeInterval] { get set }
    var groupDurations: [String: TimeInterval] { get set }
    var deviceVolumes: [String: Int] { get set }
    var deviceMutes: [String: Bool] { get set }
    var awaitingPlayback: [String: Bool] { get set }
    var discoveredArtURLs: [String: String] { get set }
    var lastPlayedFavoriteID: String? { get set }
    var draggedBrowseItem: BrowseItem? { get set }
    var groups: [SonosGroup] { get }

    func setTransportGrace(groupID: String, duration: TimeInterval)
    func setModeGrace(groupID: String, duration: TimeInterval)
    func setPositionGrace(coordinatorID: String, duration: TimeInterval)
    func cacheArtURL(_ artURL: String, forURI uri: String, title: String, itemID: String)
    func lookupCachedArt(uri: String?, title: String) -> String?
    func transportDidUpdateTrackMetadata(_ groupID: String, metadata: TrackMetadata)
}

// MARK: - Art Cache Protocol (SRP: art URL cache management)

@MainActor
public protocol ArtCacheProtocol {
    var discoveredArtURLs: [String: String] { get }
    func cacheArtURL(_ artURL: String, forURI uri: String, title: String, itemID: String)
    func lookupCachedArt(uri: String?, title: String) -> String?
}

// MARK: - Composite Protocol Typealiases
// These combine focused protocols for ViewModels that need multiple capabilities.
// ViewModels declare their dependency as the composite type, which SonosManager conforms to.

/// Everything the Now Playing view needs
public typealias NowPlayingServices = PlaybackServiceProtocol & VolumeServiceProtocol & TransportStateProviding & MusicServiceDetectionProtocol

/// Everything the Browse view needs
public typealias BrowsingServices = BrowsingServiceProtocol & PlaybackServiceProtocol & QueueServiceProtocol & MusicServiceDetectionProtocol & TransportStateProviding

/// Everything the Queue view needs
public typealias QueueServices = QueueServiceProtocol & PlaybackServiceProtocol & TransportStateProviding
