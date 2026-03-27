/// MockSonosServices.swift — Mock implementations for protocol-based testing.
///
/// Provides in-memory mock services conforming to the segregated protocols,
/// enabling unit tests without real Sonos hardware or network access.
import Foundation
@testable import SonosKit

@MainActor
final class MockSonosServices: PlaybackServiceProtocol, VolumeServiceProtocol, EQServiceProtocol,
                                QueueServiceProtocol, BrowsingServiceProtocol, GroupingServiceProtocol,
                                AlarmServiceProtocol, MusicServiceDetectionProtocol,
                                TransportStateProviding, ArtCacheProtocol {

    // MARK: - Call Tracking

    var playCalled = false
    var pauseCalled = false
    var stopCalled = false
    var nextCalled = false
    var previousCalled = false
    var seekCalled: String?
    var lastSetVolume: (String, Int)?
    var lastSetMute: (String, Bool)?

    // MARK: - TransportStateProviding (read-only state)

    var groupTransportStates: [String: TransportState] = [:]
    var groupTrackMetadata: [String: TrackMetadata] = [:]
    var groupPlayModes: [String: PlayMode] = [:]
    var groupPositions: [String: TimeInterval] = [:]
    var groupDurations: [String: TimeInterval] = [:]
    var deviceVolumes: [String: Int] = [:]
    var deviceMutes: [String: Bool] = [:]
    var awaitingPlayback: [String: Bool] = [:]
    var discoveredArtURLs: [String: String] = [:]
    var lastPlayedFavoriteID: String?
    var draggedBrowseItem: BrowseItem?
    var groups: [SonosGroup] = []
    var devices: [String: SonosDevice] = [:]

    func updateTransportState(_ groupID: String, state: TransportState) {
        groupTransportStates[groupID] = state
    }

    func updatePlayMode(_ groupID: String, mode: PlayMode) {
        groupPlayModes[groupID] = mode
    }

    func updateDeviceVolume(_ deviceID: String, volume: Int) {
        deviceVolumes[deviceID] = volume
    }

    func updateDeviceMute(_ deviceID: String, muted: Bool) {
        deviceMutes[deviceID] = muted
    }

    func updateAwaitingPlayback(_ groupID: String, awaiting: Bool) {
        awaitingPlayback[groupID] = awaiting
    }

    var transportGraces: [String: Date] = [:]
    var modeGraces: [String: Date] = [:]
    var positionGraces: [String: Date] = [:]
    var volumeGraces: [String: Date] = [:]
    var muteGraces: [String: Date] = [:]

    func setTransportGrace(groupID: String, duration: TimeInterval) {
        transportGraces[groupID] = Date().addingTimeInterval(duration)
    }

    func setModeGrace(groupID: String, duration: TimeInterval) {
        modeGraces[groupID] = Date().addingTimeInterval(duration)
    }

    func setPositionGrace(coordinatorID: String, duration: TimeInterval) {
        positionGraces[coordinatorID] = Date().addingTimeInterval(duration)
    }

    func cacheArtURL(_ artURL: String, forURI uri: String, title: String, itemID: String) {
        if !uri.isEmpty { discoveredArtURLs[uri] = artURL }
        if !itemID.isEmpty { discoveredArtURLs[itemID] = artURL }
    }

    func lookupCachedArt(uri: String?, title: String) -> String? {
        if let uri, let art = discoveredArtURLs[uri] { return art }
        return nil
    }

    func transportDidUpdateTrackMetadata(_ groupID: String, metadata: TrackMetadata) {
        groupTrackMetadata[groupID] = metadata
    }

    // MARK: - PlaybackServiceProtocol

    func play(group: SonosGroup) async throws { playCalled = true }
    func pause(group: SonosGroup) async throws { pauseCalled = true }
    func stop(group: SonosGroup) async throws { stopCalled = true }
    func next(group: SonosGroup) async throws { nextCalled = true }
    func previous(group: SonosGroup) async throws { previousCalled = true }
    func seek(group: SonosGroup, to time: String) async throws { seekCalled = time }

    var stubbedTransportState: TransportState = .stopped
    func getTransportState(group: SonosGroup) async throws -> TransportState { stubbedTransportState }

    var stubbedMediaInfo: [String: String] = [:]
    func getMediaInfo(group: SonosGroup) async throws -> [String: String] { stubbedMediaInfo }

    var stubbedPositionInfo = TrackMetadata()
    func getPositionInfo(group: SonosGroup) async throws -> TrackMetadata { stubbedPositionInfo }

    var stubbedPlayMode: PlayMode = .normal
    func getPlayMode(group: SonosGroup) async throws -> PlayMode { stubbedPlayMode }
    func setPlayMode(group: SonosGroup, mode: PlayMode) async throws { groupPlayModes[group.coordinatorID] = mode }

    var stubbedCrossfade = false
    func getCrossfadeMode(group: SonosGroup) async throws -> Bool { stubbedCrossfade }
    func setCrossfadeMode(group: SonosGroup, enabled: Bool) async throws { stubbedCrossfade = enabled }

    func setSleepTimer(group: SonosGroup, duration: String) async throws {}
    func cancelSleepTimer(group: SonosGroup) async throws {}
    func getSleepTimerRemaining(group: SonosGroup) async throws -> String { "" }
    func playURI(group: SonosGroup, uri: String, metadata: String, title: String, artist: String, stationName: String, albumArtURI: String?) async throws {}
    func playBrowseItem(_ item: BrowseItem, in group: SonosGroup) async throws {}
    func pauseAll() async {}
    func resumeAll() async {}

    // MARK: - VolumeServiceProtocol

    func getVolume(device: SonosDevice) async throws -> Int { deviceVolumes[device.id] ?? 0 }
    func setVolume(device: SonosDevice, volume: Int) async throws { lastSetVolume = (device.id, volume) }
    func getMute(device: SonosDevice) async throws -> Bool { deviceMutes[device.id] ?? false }
    func setMute(device: SonosDevice, muted: Bool) async throws { lastSetMute = (device.id, muted) }
    func setVolumeGrace(deviceID: String, duration: TimeInterval) { volumeGraces[deviceID] = Date().addingTimeInterval(duration) }
    func setMuteGrace(deviceID: String, duration: TimeInterval) { muteGraces[deviceID] = Date().addingTimeInterval(duration) }
    func isVolumeGraceActive(deviceID: String) -> Bool { volumeGraces[deviceID].map { Date() < $0 } ?? false }
    func isMuteGraceActive(deviceID: String) -> Bool { muteGraces[deviceID].map { Date() < $0 } ?? false }

    // MARK: - EQServiceProtocol

    func getBass(device: SonosDevice) async throws -> Int { 0 }
    func setBass(device: SonosDevice, bass: Int) async throws {}
    func getTreble(device: SonosDevice) async throws -> Int { 0 }
    func setTreble(device: SonosDevice, treble: Int) async throws {}
    func getLoudness(device: SonosDevice) async throws -> Bool { false }
    func setLoudness(device: SonosDevice, enabled: Bool) async throws {}
    func getEQ(device: SonosDevice, eqType: String) async throws -> Int { 0 }
    func setEQ(device: SonosDevice, eqType: String, value: Int) async throws {}

    // MARK: - QueueServiceProtocol

    var stubbedQueue: [QueueItem] = []
    func getQueue(group: SonosGroup, start: Int, count: Int) async throws -> (items: [QueueItem], total: Int) {
        (stubbedQueue, stubbedQueue.count)
    }
    func removeFromQueue(group: SonosGroup, trackIndex: Int) async throws {}
    func clearQueue(group: SonosGroup) async throws { stubbedQueue = [] }
    func playTrackFromQueue(group: SonosGroup, trackNumber: Int) async throws {}
    func moveTrackInQueue(group: SonosGroup, from: Int, to: Int) async throws {}
    func saveQueueAsPlaylist(group: SonosGroup, title: String) async throws -> String { "SQ:1" }
    func addBrowseItemToQueue(_ item: BrowseItem, in group: SonosGroup, playNext: Bool, atPosition: Int) async throws -> Int { 1 }

    // MARK: - BrowsingServiceProtocol

    var stubbedBrowseItems: [BrowseItem] = []
    func browse(objectID: String, start: Int, count: Int) async throws -> (items: [BrowseItem], total: Int) {
        (stubbedBrowseItems, stubbedBrowseItems.count)
    }
    func browseMetadata(objectID: String) async throws -> BrowseItem? { nil }
    func search(query: String, in containerID: String, start: Int, count: Int) async throws -> (items: [BrowseItem], total: Int) { ([], 0) }
    func loadBrowseSections() async {}
    func addToPlaylist(playlistID: String, item: BrowseItem) async throws {}
    func deletePlaylist(playlistID: String) async throws {}
    func renamePlaylist(playlistID: String, oldTitle: String, newTitle: String) async throws {}

    // MARK: - GroupingServiceProtocol

    func joinGroup(device: SonosDevice, toCoordinator coordinator: SonosDevice) async throws {}
    func ungroupDevice(_ device: SonosDevice) async throws {}

    // MARK: - AlarmServiceProtocol

    func getAlarms() async throws -> [SonosAlarm] { [] }
    func createAlarm(_ alarm: SonosAlarm) async throws -> Int { 0 }
    func updateAlarm(_ alarm: SonosAlarm) async throws {}
    func deleteAlarm(_ alarm: SonosAlarm) async throws {}

    // MARK: - MusicServiceDetectionProtocol

    func musicServiceName(for serviceID: Int) -> String? { nil }
    func detectServiceName(fromURI uri: String) -> String? { nil }
    func musicServiceName(fromDescriptor desc: String) -> String? { nil }
    func serviceLabel(for item: BrowseItem) -> String? { nil }
}
