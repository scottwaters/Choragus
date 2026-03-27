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
        let artist = trackMetadata.artist
        if artist.hasPrefix("RINCON_") { return "" }
        return artist
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
    var positionPollingTask: Task<Void, Never>?

    // MARK: - Transport UI

    var actionInFlight: String?
    var crossfadeOn = false
    var isInitialized = false

    // MARK: - Art

    let art: ArtResolver

    // MARK: - Init

    init(sonosManager: any NowPlayingServices, group: SonosGroup) {
        self.sonosManager = sonosManager
        self.group = group
        self.art = ArtResolver(sonosManager: sonosManager)
    }

    // MARK: - Transport Actions

    func togglePlayPause() {
        let shouldPlay = !transportState.isPlaying
        if shouldPlay {
            sonosManager.groupTransportStates[group.coordinatorID] = .playing
        } else {
            sonosManager.groupTransportStates[group.coordinatorID] = .paused
        }
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
        sonosManager.groupPlayModes[group.coordinatorID] = newMode
        sonosManager.setModeGrace(groupID: group.coordinatorID, duration: Timing.defaultGracePeriod)
        performAction("shuffle") {
            try await self.sonosManager.setPlayMode(group: self.group, mode: newMode)
        }
    }

    func cycleRepeat() {
        let newMode = playMode.cyclingRepeat()
        sonosManager.groupPlayModes[group.coordinatorID] = newMode
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
            sonosManager.deviceMutes[member.id] = newMuted
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
        let delta = volume - lastMasterVolume
        for member in group.members {
            sonosManager.setVolumeGrace(deviceID: member.id, duration: Timing.playbackGracePeriod)
            let currentVol = speakerVolumes[member.id] ?? 0
            let newVol = max(0, min(100, currentVol + delta))
            speakerVolumes[member.id] = newVol
            sonosManager.deviceVolumes[member.id] = Int(newVol)
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
        sonosManager.deviceVolumes[device.id] = volume
        do {
            try await sonosManager.setVolume(device: device, volume: volume)
        } catch {
            sonosDebugLog("[VOLUME] setSpeakerVolume failed for \(device.roomName): \(error)")
        }
    }

    func setSpeakerMute(device: SonosDevice, muted: Bool) async {
        sonosManager.setMuteGrace(deviceID: device.id, duration: Timing.playbackGracePeriod)
        sonosManager.deviceMutes[device.id] = muted
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

    // MARK: - Metadata Enrichment

    /// Enriches track metadata from media info for radio streams.
    /// Extracts station name, title, and album art from CurrentURIMetaData DIDL.
    private func enrichMetadata(_ position: TrackMetadata, state: TransportState, coordinator: SonosDevice) async -> TrackMetadata {
        var enriched = position
        guard (position.title.isEmpty || position.stationName.isEmpty), state.isActive else {
            return enriched
        }
        let mediaInfo = try? await sonosManager.getMediaInfo(group: group)
        guard let rawDIDL = mediaInfo?["CurrentURIMetaData"], !rawDIDL.isEmpty,
              rawDIDL != "NOT_IMPLEMENTED" else {
            return enriched
        }
        let didl = rawDIDL.contains("&lt;") ? XMLResponseParser.xmlUnescape(rawDIDL) : rawDIDL
        guard let parsed = XMLResponseParser.parseDIDLMetadata(didl) else {
            return enriched
        }
        let currentURI = mediaInfo?["CurrentURI"] ?? ""
        if URIPrefix.isRadio(currentURI), !parsed.title.isEmpty {
            enriched.stationName = parsed.title
        }
        if enriched.title.isEmpty {
            enriched.title = parsed.title
        }
        let artURI = coordinator.makeAbsoluteURL(parsed.albumArtURI)
        if !artURI.isEmpty {
            enriched.albumArtURI = artURI
            if let favID = sonosManager.lastPlayedFavoriteID {
                sonosManager.cacheArtURL(artURI, forURI: "", title: enriched.stationName.isEmpty ? enriched.title : enriched.stationName, itemID: favID)
            }
        }
        return enriched
    }

    // MARK: - Position Polling & Interpolation

    func startProgressTimer() {
        stopProgressTimer()
        progressTimer = Timer.scheduledTimer(withTimeInterval: Timing.progressTimerInterval, repeats: true) { [self] _ in
            guard !isDraggingSeek else { return }
            let now = Date()
            if now > positionFrozenUntil && transportState.isPlaying {
                let elapsed = now.timeIntervalSince(lastPositionTimestamp)
                smoothPosition = lastKnownPosition + elapsed
            }
        }
        positionPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.pollPosition()
            }
        }
    }

    func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
        positionPollingTask?.cancel()
        positionPollingTask = nil
    }

    private func pollPosition() async {
        guard let coordinator = group.coordinator else { return }
        do {
            let state = try await sonosManager.getTransportState(group: group)
            let position = try await sonosManager.getPositionInfo(group: group)
            let enrichedPosition = await enrichMetadata(position, state: state, coordinator: coordinator)

            sonosManager.transportDidUpdateTrackMetadata(group.coordinatorID, metadata: enrichedPosition)

            lastKnownPosition = enrichedPosition.position
            lastPositionTimestamp = Date()
            smoothPosition = enrichedPosition.position

            await syncVolumeMuteFromSpeakers()
            crossfadeOn = (try? await sonosManager.getCrossfadeMode(group: group)) ?? false
        } catch {
            sonosDebugLog("[NOW-PLAYING] pollPosition failed: \(error)")
        }
    }

    // MARK: - Fetch Current State

    func fetchCurrentState() async {
        guard let coordinator = group.coordinator else { return }
        do {
            async let stateResult = sonosManager.getTransportState(group: group)
            async let positionResult = sonosManager.getPositionInfo(group: group)
            async let modeResult = sonosManager.getPlayMode(group: group)

            let (state, position, mode) = try await (stateResult, positionResult, modeResult)
            sonosManager.groupTransportStates[group.coordinatorID] = state
            sonosManager.groupPlayModes[group.coordinatorID] = mode

            let enrichedPosition = await enrichMetadata(position, state: state, coordinator: coordinator)

            sonosManager.transportDidUpdateTrackMetadata(group.coordinatorID, metadata: enrichedPosition)
            lastKnownPosition = enrichedPosition.position
            lastPositionTimestamp = Date()
            smoothPosition = enrichedPosition.position

            await syncVolumeMuteFromSpeakers()
            crossfadeOn = (try? await sonosManager.getCrossfadeMode(group: group)) ?? false
        } catch {
            sonosDebugLog("[NOW-PLAYING] fetchCurrentState failed: \(error)")
        }
    }

    /// Fetches volume/mute per member from speakers, skipping graced devices.
    private func syncVolumeMuteFromSpeakers() async {
        for member in group.members {
            if !sonosManager.isVolumeGraceActive(deviceID: member.id) {
                if let vol = try? await sonosManager.getVolume(device: member) {
                    sonosManager.deviceVolumes[member.id] = vol
                }
            }
            if !sonosManager.isMuteGraceActive(deviceID: member.id) {
                if let muted = try? await sonosManager.getMute(device: member) {
                    sonosManager.deviceMutes[member.id] = muted
                }
            }
        }
        syncVolumeFromManager()
        syncMuteFromManager()
    }

}
