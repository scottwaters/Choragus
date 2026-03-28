/// NowPlayingViewModel.swift — Business logic for the Now Playing view.
///
/// Handles transport control, volume management, position interpolation,
/// album art resolution, and metadata display. The view binds to published
/// state and calls action methods.
import SwiftUI
import Combine
import Observation
import SonosKit

@MainActor
@Observable
final class NowPlayingViewModel {
    var sonosManager: any NowPlayingServices
    var group: SonosGroup

    // MARK: - Transport State

    var transportState: TransportState {
        sonosManager.groupTransportStates[group.coordinatorID] ?? .stopped
    }

    var trackMetadata: TrackMetadata {
        sonosManager.groupTrackMetadata[group.coordinatorID] ?? TrackMetadata()
    }

    var playMode: PlayMode {
        sonosManager.groupPlayModes[group.coordinatorID] ?? .normal
    }

    var hasTrack: Bool {
        !trackMetadata.title.isEmpty || !trackMetadata.stationName.isEmpty || trackMetadata.duration > 0
    }

    var awaitingPlayback: Bool {
        sonosManager.awaitingPlayback[group.coordinatorID] ?? false
    }

    var currentServiceName: String? {
        if let sid = trackMetadata.serviceID,
           let name = sonosManager.musicServiceName(for: sid) { return name }
        if let uri = trackMetadata.trackURI,
           let name = sonosManager.detectServiceName(fromURI: uri) { return name }
        if let uri = trackMetadata.trackURI, URIPrefix.isLocal(uri) { return ServiceName.musicLibrary }
        return nil
    }

    var displayArtist: String {
        TrackMetadata.filterDeviceID(trackMetadata.artist)
    }

    // MARK: - Volume

    var volume: Double = 30
    var isMuted = false
    var speakerVolumes: [String: Double] = [:]
    var speakerMutes: [String: Bool] = [:]
    var isDraggingVolume = false
    var lastMasterVolume: Double = 0
    var volumeGraceUntil: Date = .distantPast
    var muteGraceUntil: Date = .distantPast

    // MARK: - Position

    var smoothPosition: TimeInterval = 0
    var isDraggingSeek = false
    var lastKnownPosition: TimeInterval = 0
    var lastPositionTimestamp: Date = .distantPast
    var positionFrozenUntil: Date = .distantPast
    var progressTimer: Timer?

    // MARK: - Transport UI

    var actionInFlight: String?
    var crossfadeOn = false
    var isInitialized = false

    // MARK: - Art

    let art: ArtResolver

    // MARK: - Init

    init(sonosManager: any NowPlayingServices, group: SonosGroup, playHistoryManager: PlayHistoryManager? = nil) {
        self.sonosManager = sonosManager
        self.group = group
        self.art = ArtResolver(playHistoryManager: playHistoryManager)
    }

    // MARK: - Transport Actions

    func togglePlayPause() {
        let shouldPlay = !transportState.isPlaying
        sonosManager.updateTransportState(group.coordinatorID, state: shouldPlay ? .playing : .paused)
        sonosManager.setTransportGrace(groupID: group.coordinatorID, duration: Timing.defaultGracePeriod)
        performAction("playPause") {
            if shouldPlay {
                try await self.sonosManager.play(group: self.group)
            } else {
                try await self.sonosManager.pause(group: self.group)
            }
        }
    }

    func toggleShuffle() {
        let newMode = playMode.togglingShuffle()
        sonosManager.updatePlayMode(group.coordinatorID, mode: newMode)
        sonosManager.setModeGrace(groupID: group.coordinatorID, duration: Timing.defaultGracePeriod)
        performAction("shuffle") {
            try await self.sonosManager.setPlayMode(group: self.group, mode: newMode)
        }
    }

    func cycleRepeat() {
        let newMode = playMode.cyclingRepeat()
        sonosManager.updatePlayMode(group.coordinatorID, mode: newMode)
        sonosManager.setModeGrace(groupID: group.coordinatorID, duration: Timing.defaultGracePeriod)
        performAction("repeat") {
            try await self.sonosManager.setPlayMode(group: self.group, mode: newMode)
        }
    }

    func toggleCrossfade() {
        let newValue = !crossfadeOn
        crossfadeOn = newValue
        performAction("crossfade") {
            try await self.sonosManager.setCrossfadeMode(group: self.group, enabled: newValue)
        }
    }

    func seekToPosition(_ seconds: TimeInterval) {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        let timeStr = String(format: "%d:%02d:%02d", hours, minutes, secs)
        positionFrozenUntil = Date().addingTimeInterval(Timing.positionFreezeAfterSeek)
        sonosManager.setPositionGrace(coordinatorID: group.coordinatorID, duration: Timing.positionFreezeAfterSeek)
        Task {
            do {
                try await sonosManager.seek(group: group, to: timeStr)
            } catch {
                sonosDebugLog("[NOW-PLAYING] Seek failed: \(error)")
            }
        }
    }

    // MARK: - Volume Actions

    func toggleMute() {
        let newMuted = !isMuted
        isMuted = newMuted
        muteGraceUntil = Date().addingTimeInterval(Timing.playbackGracePeriod)
        for member in group.members {
            sonosManager.setMuteGrace(deviceID: member.id, duration: Timing.playbackGracePeriod)
            speakerMutes[member.id] = newMuted
            sonosManager.updateDeviceMute(member.id, muted: newMuted)
        }
        Task {
            for member in group.members {
                do {
                    try await sonosManager.setMute(device: member, muted: newMuted)
                } catch {
                    sonosDebugLog("[NOW-PLAYING] setMute failed for \(member.roomName): \(error)")
                }
            }
        }
    }

    func setVolume() {
        let now = Date()
        volumeGraceUntil = now.addingTimeInterval(Timing.playbackGracePeriod)
        let oldMaster = lastMasterVolume
        let newMaster = volume
        let proportional = UserDefaults.standard.bool(forKey: UDKey.proportionalGroupVolume)

        for member in group.members {
            sonosManager.setVolumeGrace(deviceID: member.id, duration: Timing.playbackGracePeriod)
            let currentVol = speakerVolumes[member.id] ?? 0

            let newVol: Double
            if proportional && oldMaster > 0 {
                // Proportional: each speaker keeps its ratio relative to the master.
                // e.g. speakers at 30,40 (master=35) → master to 70 → speakers become 60,80
                newVol = currentVol * (newMaster / oldMaster)
            } else if proportional && oldMaster == 0 {
                // Master was at 0 — can't scale proportionally, set all to new master
                newVol = newMaster
            } else {
                // Linear: all speakers shift by the same absolute delta
                newVol = currentVol + (newMaster - oldMaster)
            }

            let clamped = max(0, min(100, newVol))
            speakerVolumes[member.id] = clamped
            sonosManager.updateDeviceVolume(member.id, volume: Int(clamped))
        }
        lastMasterVolume = volume
    }

    func commitVolume() {
        Task {
            for member in group.members {
                let vol = Int(speakerVolumes[member.id] ?? 0)
                do {
                    try await sonosManager.setVolume(device: member, volume: vol)
                } catch {
                    sonosDebugLog("[NOW-PLAYING] commitVolume failed for \(member.roomName): \(error)")
                }
            }
        }
    }

    // MARK: - Per-Speaker Volume/Mute (called from VolumeControlView)

    func setSpeakerVolume(device: SonosDevice, volume: Int) async {
        sonosManager.setVolumeGrace(deviceID: device.id, duration: Timing.playbackGracePeriod)
        sonosManager.updateDeviceVolume(device.id, volume: volume)
        do {
            try await sonosManager.setVolume(device: device, volume: volume)
        } catch {
            sonosDebugLog("[VOLUME] setSpeakerVolume failed for \(device.roomName): \(error)")
        }
    }

    func setSpeakerMute(device: SonosDevice, muted: Bool) async {
        sonosManager.setMuteGrace(deviceID: device.id, duration: Timing.playbackGracePeriod)
        sonosManager.updateDeviceMute(device.id, muted: muted)
        do {
            try await sonosManager.setMute(device: device, muted: muted)
        } catch {
            sonosDebugLog("[VOLUME] setSpeakerMute failed for \(device.roomName): \(error)")
        }
    }

    // MARK: - Copy Track Info

    func copyTrackInfo() {
        var lines: [String] = []
        if !trackMetadata.stationName.isEmpty {
            lines.append("\(L10n.sourceLabel): \(trackMetadata.stationName)")
        } else if let sid = trackMetadata.serviceID,
                  let serviceName = sonosManager.musicServiceName(for: sid) {
            lines.append("\(L10n.sourceLabel): \(serviceName)")
        }
        if !displayArtist.isEmpty {
            lines.append("\(L10n.artistLabel): \(displayArtist)")
        }
        if !trackMetadata.album.isEmpty {
            lines.append("\(L10n.albumLabel): \(trackMetadata.album)")
        }
        if !trackMetadata.title.isEmpty {
            lines.append("\(L10n.trackLabel): \(trackMetadata.title)")
        }
        let text = lines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Action Runner

    func performAction(_ id: String, _ action: @escaping () async throws -> Void) {
        guard actionInFlight == nil else { return }
        actionInFlight = id
        Task {
            do {
                try await action()
            } catch {
                ErrorHandler.shared.handle(error, context: "TRANSPORT")
            }
            actionInFlight = nil
        }
    }

    // MARK: - Sync from Manager

    func syncFromManager() {
        isInitialized = true
        syncVolumeFromManager()
        syncMuteFromManager()
    }

    func syncVolumeFromManager() {
        guard !isDraggingVolume else { return } // Don't override while user is dragging
        let now = Date()
        guard now > volumeGraceUntil else { return }

        if group.members.count > 1 {
            var totalVol = 0.0
            for member in group.members {
                if sonosManager.isVolumeGraceActive(deviceID: member.id) {
                    let v = Double(sonosManager.deviceVolumes[member.id] ?? 0)
                    if abs((speakerVolumes[member.id] ?? 0) - v) > 0.5 {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            speakerVolumes[member.id] = v
                        }
                    }
                    totalVol += v
                    continue
                }
                let v = Double(sonosManager.deviceVolumes[member.id] ?? 0)
                if abs((speakerVolumes[member.id] ?? 0) - v) > 0.5 || !isInitialized {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        speakerVolumes[member.id] = v
                    }
                }
                totalVol += v
            }
            let avg = totalVol / Double(group.members.count)
            if abs(volume - avg) > 0.5 || !isInitialized {
                withAnimation(.easeInOut(duration: 0.3)) {
                    volume = avg
                }
            }
            lastMasterVolume = volume
        } else if let device = group.coordinator {
            let v = Double(sonosManager.deviceVolumes[device.id] ?? 0)
            if abs(volume - v) > 0.5 || !isInitialized {
                withAnimation(.easeInOut(duration: 0.3)) {
                    volume = v
                }
            }
            lastMasterVolume = volume
        }
    }

    func syncMuteFromManager() {
        let now = Date()
        guard now > muteGraceUntil else { return }

        for member in group.members {
            if !sonosManager.isMuteGraceActive(deviceID: member.id) {
                speakerMutes[member.id] = sonosManager.deviceMutes[member.id] ?? false
            }
        }
        syncMasterMuteFromSpeakers()
    }

    func syncMasterMuteFromSpeakers() {
        let allMuted = group.members.allSatisfy { speakerMutes[$0.id] == true }
        if allMuted != isMuted {
            isMuted = allMuted
        }
    }

    // MARK: - Helpers

    var volumeIcon: String {
        if isMuted { return "speaker.slash.fill" }
        if volume < 33 { return "speaker.wave.1.fill" }
        if volume < 66 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    var repeatIcon: String {
        switch playMode.repeatMode {
        case .off, .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    var smoothPositionString: String {
        formatTime(smoothPosition)
    }

    func formatTime(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    // MARK: - Art Orchestration (single entry point — View calls this, not art.* directly)

    func handleMetadataChanged(_ metadata: TrackMetadata) {
        // Track URI changed — reset search state and position
        let uriChanged = art.lastTrackURI != (metadata.trackURI ?? metadata.title)
        art.handleTrackURIChanged(trackMetadata: metadata, group: group)

        // Reset position on source/track change to avoid stale time display
        if uriChanged {
            lastKnownPosition = metadata.position
            lastPositionTimestamp = Date()
            smoothPosition = metadata.position
        }

        // During ad breaks, just update display state (show station art)
        guard !metadata.isAdBreak else {
            art.updateDisplayedArt(trackMetadata: metadata, group: group)
            return
        }

        // Update from new albumArtURI if available
        if let artStr = metadata.albumArtURI, !artStr.isEmpty, let url = URL(string: artStr) {
            if art.displayedArtURL != url && !art.forceWebArt {
                art.displayedArtURL = url
            }
        }

        // Search for web art if metadata art is missing
        searchWebArtIfNeeded(metadata)
        art.updateDisplayedArt(trackMetadata: metadata, group: group)

        // Radio: search for track-specific art
        searchRadioTrackArt(metadata)
    }

    func onArtAppear() {
        art.loadPersistedArtOverride(trackMetadata: trackMetadata, group: group)
        handleMetadataChanged(trackMetadata)
    }

    // MARK: - Art Search (orchestration — delegates to AlbumArtSearchService)

    private func searchWebArtIfNeeded(_ metadata: TrackMetadata) {
        let hasArt = metadata.albumArtURI != nil && !(metadata.albumArtURI?.isEmpty ?? true)
        let isLocalFile = metadata.trackURI.map(URIPrefix.isLocal) ?? false
        // Local files with art from /getaa — don't override with iTunes search
        if hasArt && isLocalFile && !art.forceWebArt {
            art.clearWebArt()
            return
        }
        if hasArt && !isLocalFile {
            if !art.forceWebArt { art.clearWebArt() }
            return
        }
        art.clearWebArt()

        let searchTerm: String
        if isLocalFile && !metadata.album.isEmpty {
            searchTerm = metadata.album
        } else if !metadata.stationName.isEmpty {
            searchTerm = metadata.stationName
        } else if !metadata.album.isEmpty {
            searchTerm = metadata.album
        } else if !metadata.title.isEmpty {
            searchTerm = metadata.title
        } else {
            return
        }
        let artist = displayArtist
        let key = "\(searchTerm)|\(artist)"
        guard art.shouldSearch(key: key) else { return }
        art.setSearchKey(key)
        art.setWebArtResult(nil)
        Task {
            if let artURL = await AlbumArtSearchService.shared.searchArtwork(
                artist: artist, album: searchTerm
            ) {
                art.setWebArtResult(URL(string: artURL))
                art.playHistoryManager?.updateArtwork(
                    forTitle: metadata.title, artist: metadata.artist, artURL: artURL
                )
            } else {
                art.setWebArtResult(nil)
            }
            art.updateDisplayedArt(trackMetadata: metadata, group: group)
        }
    }

    private func searchRadioTrackArt(_ metadata: TrackMetadata) {
        guard !metadata.stationName.isEmpty,
              !metadata.title.isEmpty,
              metadata.title != metadata.stationName,
              !metadata.isAdBreak else {
            art.clearRadioTrackArt()
            return
        }
        let key = "\(metadata.title)|\(metadata.artist)"
        guard art.shouldSearchRadioTrack(key: key) else { return }
        art.setRadioTrackKey(key)
        if art.radioStationArtURL == nil, let stationArt = art.displayedArtURL ?? metadata.albumArtURI.flatMap({ URL(string: $0) }) {
            art.radioStationArtURL = stationArt
        }
        let artist = TrackMetadata.filterDeviceID(metadata.artist)
        let cleanTitle = AlbumArtSearchService.cleanTrackTitle(metadata.title)
        let searchTitle = cleanTitle.isEmpty ? metadata.title : cleanTitle
        Task {
            if let artURL = await AlbumArtSearchService.shared.searchRadioTrackArt(
                artist: artist, title: searchTitle
            ) {
                art.setRadioTrackArt(URL(string: artURL))
                art.playHistoryManager?.updateArtwork(
                    forTitle: metadata.title, artist: metadata.artist, artURL: artURL
                )
            } else {
                art.setRadioTrackArt(nil)
            }
        }
    }

    // MARK: - Metadata Enrichment

    /// Enriches track metadata from media info for radio streams.
    /// Uses the shared TrackMetadata.enrichFromMediaInfo helper, then caches art for favorites.
    private func enrichMetadata(_ position: TrackMetadata, state: TransportState, coordinator: SonosDevice) async -> TrackMetadata {
        var enriched = position
        guard (position.title.isEmpty || position.stationName.isEmpty), state.isActive else {
            return enriched
        }
        guard let mediaInfo = try? await sonosManager.getMediaInfo(group: group) else {
            return enriched
        }
        enriched.enrichFromMediaInfo(mediaInfo, device: coordinator)
        // Cache art URL for favorites lookup
        if let artURI = enriched.albumArtURI, !artURI.isEmpty,
           let favID = sonosManager.lastPlayedFavoriteID {
            sonosManager.cacheArtURL(artURI, forURI: "", title: enriched.stationName.isEmpty ? enriched.title : enriched.stationName, itemID: favID)
        }
        return enriched
    }

    // MARK: - Position Polling & Interpolation

    func startProgressTimer() {
        stopProgressTimer()
        // Position interpolation only — no network calls.
        // TransportStrategy handles all SOAP polling and updates @Published state.
        progressTimer = Timer.scheduledTimer(withTimeInterval: Timing.progressTimerInterval, repeats: true) { [weak self] _ in
            guard let self, !isDraggingSeek else { return }
            let now = Date()
            if now > positionFrozenUntil && transportState.isPlaying {
                let elapsed = now.timeIntervalSince(lastPositionTimestamp)
                let newPosition = lastKnownPosition + elapsed
                // Only update if changed by ≥0.5s to avoid unnecessary SwiftUI re-renders
                if abs(newPosition - smoothPosition) >= 0.5 {
                    smoothPosition = newPosition
                }
            }
        }
    }

    func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    // MARK: - Fetch Current State

    /// One-time fetch on appear to populate initial state.
    /// TransportStrategy handles ongoing updates via events + reconciliation polling.
    func fetchCurrentState() async {
        guard let coordinator = group.coordinator else { return }
        do {
            async let stateResult = sonosManager.getTransportState(group: group)
            async let positionResult = sonosManager.getPositionInfo(group: group)
            async let modeResult = sonosManager.getPlayMode(group: group)

            let (state, position, mode) = try await (stateResult, positionResult, modeResult)
            sonosManager.updateTransportState(group.coordinatorID, state: state)
            sonosManager.updatePlayMode(group.coordinatorID, mode: mode)

            let enrichedPosition = await enrichMetadata(position, state: state, coordinator: coordinator)

            sonosManager.transportDidUpdateTrackMetadata(group.coordinatorID, metadata: enrichedPosition)
            lastKnownPosition = enrichedPosition.position
            lastPositionTimestamp = Date()
            smoothPosition = enrichedPosition.position

            crossfadeOn = (try? await sonosManager.getCrossfadeMode(group: group)) ?? false
            syncVolumeFromManager()
            syncMuteFromManager()
        } catch {
            sonosDebugLog("[NOW-PLAYING] fetchCurrentState failed: \(error)")
        }
    }

}
