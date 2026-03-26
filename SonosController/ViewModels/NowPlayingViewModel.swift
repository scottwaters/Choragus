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
    let sonosManager: SonosManager
    let group: SonosGroup

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
    var volumeActionPending = false
    var isDraggingVolume = false
    var lastMasterVolume: Double = 0
    var volumePendingTimer: Task<Void, Never>?
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

    var displayedArtURL: URL?
    var radioTrackArtURL: URL?
    var radioStationArtURL: URL?
    var webArtURL: URL?
    var forceWebArt = false
    var lastArtSearchKey = ""
    var lastTrackURI = ""
    var lastRadioTrackKey = ""

    // MARK: - Init

    init(sonosManager: SonosManager, group: SonosGroup) {
        self.sonosManager = sonosManager
        self.group = group
    }

    // MARK: - Transport Actions

    func togglePlayPause() {
        let shouldPlay = !transportState.isPlaying
        if shouldPlay {
            sonosManager.groupTransportStates[group.coordinatorID] = .playing
        } else {
            sonosManager.groupTransportStates[group.coordinatorID] = .paused
        }
        sonosManager.setTransportGrace(groupID: group.coordinatorID)
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
        sonosManager.setModeGrace(groupID: group.coordinatorID)
        performAction("shuffle") {
            try await self.sonosManager.setPlayMode(group: self.group, mode: newMode)
        }
    }

    func cycleRepeat() {
        let newMode = playMode.cyclingRepeat()
        sonosManager.groupPlayModes[group.coordinatorID] = newMode
        sonosManager.setModeGrace(groupID: group.coordinatorID)
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
            try? await sonosManager.seek(group: group, to: timeStr)
        }
    }

    // MARK: - Volume Actions

    func toggleMute() {
        let newMuted = !isMuted
        isMuted = newMuted
        muteGraceUntil = Date().addingTimeInterval(Timing.playbackGracePeriod)
        for member in group.members {
            sonosManager.setMuteGrace(deviceID: member.id)
            speakerMutes[member.id] = newMuted
            sonosManager.deviceMutes[member.id] = newMuted
        }
        Task {
            for member in group.members {
                try? await sonosManager.setMute(device: member, muted: newMuted)
            }
        }
    }

    func setVolume() {
        let now = Date()
        volumeGraceUntil = now.addingTimeInterval(Timing.playbackGracePeriod)
        let delta = volume - lastMasterVolume
        for member in group.members {
            sonosManager.setVolumeGrace(deviceID: member.id)
            let currentVol = speakerVolumes[member.id] ?? 0
            let newVol = max(0, min(100, currentVol + delta))
            speakerVolumes[member.id] = newVol
            sonosManager.deviceVolumes[member.id] = Int(newVol)
        }
        lastMasterVolume = volume
        showVolumePending()
    }

    func commitVolume() {
        Task {
            for member in group.members {
                let vol = Int(speakerVolumes[member.id] ?? 0)
                try? await sonosManager.setVolume(device: member, volume: vol)
            }
            clearVolumePending()
        }
    }

    private func showVolumePending() {
        volumePendingTimer?.cancel()
        volumePendingTimer = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            volumeActionPending = true
        }
    }

    private func clearVolumePending() {
        volumePendingTimer?.cancel()
        volumeActionPending = false
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

            // Enrich metadata from media info for radio streams
            var enrichedPosition = position
            if (position.title.isEmpty || position.stationName.isEmpty), state.isActive {
                let mediaInfo = try? await sonosManager.getMediaInfo(group: group)
                if let rawDIDL = mediaInfo?["CurrentURIMetaData"], !rawDIDL.isEmpty,
                   rawDIDL != "NOT_IMPLEMENTED" {
                    let didl = rawDIDL.contains("&lt;") ? XMLResponseParser.xmlUnescape(rawDIDL) : rawDIDL
                    if let parsed = XMLResponseParser.parseDIDLMetadata(didl) {
                        let currentURI = mediaInfo?["CurrentURI"] ?? ""
                        let isRadio = currentURI.contains(URIPrefix.sonosApiStream) ||
                                      currentURI.contains(URIPrefix.sonosApiRadio) ||
                                      currentURI.contains(URIPrefix.rinconMP3Radio)
                        if isRadio && !parsed.title.isEmpty {
                            enrichedPosition.stationName = parsed.title
                        }
                        if enrichedPosition.title.isEmpty {
                            enrichedPosition.title = parsed.title
                        }
                        var artURI = parsed.albumArtURI
                        if artURI.hasPrefix("/") {
                            artURI = "http://\(coordinator.ip):\(coordinator.port)\(artURI)"
                        }
                        if !artURI.isEmpty {
                            enrichedPosition.albumArtURI = artURI
                            if let favID = sonosManager.lastPlayedFavoriteID {
                                sonosManager.cacheArtURL(artURI, forURI: "", title: enrichedPosition.stationName.isEmpty ? enrichedPosition.title : enrichedPosition.stationName, itemID: favID)
                            }
                        }
                    }
                }
            }

            sonosManager.transportDidUpdateTrackMetadata(group.coordinatorID, metadata: enrichedPosition)

            lastKnownPosition = enrichedPosition.position
            lastPositionTimestamp = Date()
            smoothPosition = enrichedPosition.position

            // Fetch volume/mute per member (skip graced devices)
            for member in group.members {
                if !sonosManager.isVolumeGraceActive(deviceID: member.id) {
                    let vol = try await sonosManager.getVolume(device: member)
                    sonosManager.deviceVolumes[member.id] = vol
                }
                if !sonosManager.isMuteGraceActive(deviceID: member.id) {
                    let muted = try await sonosManager.getMute(device: member)
                    sonosManager.deviceMutes[member.id] = muted
                }
            }

            syncVolumeFromManager()
            syncMuteFromManager()
            crossfadeOn = (try? await sonosManager.getCrossfadeMode(group: group)) ?? false
        } catch {}
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

            var enrichedPosition = position
            if state.isActive {
                let mediaInfo = try? await sonosManager.getMediaInfo(group: group)
                if let rawDIDL = mediaInfo?["CurrentURIMetaData"], !rawDIDL.isEmpty,
                   rawDIDL != "NOT_IMPLEMENTED" {
                    let didl = rawDIDL.contains("&lt;") ? XMLResponseParser.xmlUnescape(rawDIDL) : rawDIDL
                    if let parsed = XMLResponseParser.parseDIDLMetadata(didl) {
                        let currentURI = mediaInfo?["CurrentURI"] ?? ""
                        let isRadio = currentURI.contains(URIPrefix.sonosApiStream) ||
                                      currentURI.contains(URIPrefix.sonosApiRadio) ||
                                      currentURI.contains(URIPrefix.rinconMP3Radio)
                        if isRadio && !parsed.title.isEmpty {
                            enrichedPosition.stationName = parsed.title
                        }
                        if enrichedPosition.title.isEmpty {
                            enrichedPosition.title = parsed.title
                        }
                        var artURI = parsed.albumArtURI
                        if artURI.hasPrefix("/") {
                            artURI = "http://\(coordinator.ip):\(coordinator.port)\(artURI)"
                        }
                        if !artURI.isEmpty {
                            enrichedPosition.albumArtURI = artURI
                            if let favID = sonosManager.lastPlayedFavoriteID {
                                sonosManager.cacheArtURL(artURI, forURI: "", title: enrichedPosition.stationName.isEmpty ? enrichedPosition.title : enrichedPosition.stationName, itemID: favID)
                            }
                        }
                    }
                }
            }

            sonosManager.transportDidUpdateTrackMetadata(group.coordinatorID, metadata: enrichedPosition)
            lastKnownPosition = enrichedPosition.position
            lastPositionTimestamp = Date()
            smoothPosition = enrichedPosition.position

            for member in group.members {
                if !sonosManager.isVolumeGraceActive(deviceID: member.id) {
                    let vol = try await sonosManager.getVolume(device: member)
                    sonosManager.deviceVolumes[member.id] = vol
                }
                if !sonosManager.isMuteGraceActive(deviceID: member.id) {
                    let muted = try await sonosManager.getMute(device: member)
                    sonosManager.deviceMutes[member.id] = muted
                }
            }

            syncVolumeFromManager()
            syncMuteFromManager()
            crossfadeOn = (try? await sonosManager.getCrossfadeMode(group: group)) ?? false
        } catch {}
    }

    // MARK: - Art Resolution

    var localFileArtURL: String? {
        guard let uri = trackMetadata.trackURI,
              URIPrefix.isLocal(uri),
              let coordinator = group.coordinator else { return nil }
        let encoded = uri.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? uri
        return "http://\(coordinator.ip):\(coordinator.port)/getaa?s=1&u=\(encoded)"
    }

    func resolveArtURL() -> URL? {
        let isLocalFile = trackMetadata.trackURI.map(URIPrefix.isLocal) ?? false
        let artURI = trackMetadata.albumArtURI ?? localFileArtURL
        if forceWebArt {
            return webArtURL ?? artURI.flatMap { URL(string: $0) }
        } else if isLocalFile && webArtURL != nil {
            return webArtURL
        } else {
            return artURI.flatMap { URL(string: $0) } ?? webArtURL
        }
    }

    func updateDisplayedArt() {
        let resolved = resolveArtURL()
        if resolved != displayedArtURL {
            if resolved == nil && displayedArtURL != nil {
                let currentURI = trackMetadata.trackURI ?? ""
                if currentURI == lastTrackURI { return }
            }
            displayedArtURL = resolved
        }
    }

    func searchRadioTrackArt() {
        guard !trackMetadata.stationName.isEmpty,
              !trackMetadata.title.isEmpty,
              trackMetadata.title != trackMetadata.stationName else {
            if radioTrackArtURL != nil { radioTrackArtURL = nil }
            return
        }
        let key = "\(trackMetadata.title)|\(trackMetadata.artist)"
        guard key != lastRadioTrackKey else { return }
        lastRadioTrackKey = key
        if radioStationArtURL == nil, let stationArt = displayedArtURL ?? trackMetadata.albumArtURI.flatMap({ URL(string: $0) }) {
            radioStationArtURL = stationArt
        }
        let artist = trackMetadata.artist.hasPrefix("RINCON_") ? "" : trackMetadata.artist
        let cleanTitle = trackMetadata.title
            .replacingOccurrences(of: "\\s*\\([^)]*\\)\\s*$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s*\\[[^\\]]*\\]\\s*$", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let searchTitle = cleanTitle.isEmpty ? trackMetadata.title : cleanTitle
        Task {
            if let artURL = await AlbumArtSearchService.shared.searchRadioTrackArt(
                artist: artist, title: searchTitle
            ) {
                radioTrackArtURL = URL(string: artURL)
            } else {
                radioTrackArtURL = nil
            }
        }
    }

    func searchWebArtIfNeeded() {
        let currentURI = trackMetadata.trackURI ?? trackMetadata.title
        if currentURI != lastTrackURI && !currentURI.isEmpty {
            lastTrackURI = currentURI
            if !forceWebArt {
                webArtURL = nil
                lastArtSearchKey = ""
            }
            displayedArtURL = trackMetadata.albumArtURI.flatMap { URL(string: $0) }
            if trackMetadata.stationName.isEmpty {
                radioTrackArtURL = nil
                radioStationArtURL = nil
                lastRadioTrackKey = ""
            }
            loadPersistedArtOverride()
        }

        let hasArt = trackMetadata.albumArtURI != nil && !(trackMetadata.albumArtURI?.isEmpty ?? true)
        let isLocalFile = trackMetadata.trackURI.map(URIPrefix.isLocal) ?? false
        if hasArt && !isLocalFile {
            if !forceWebArt { if webArtURL != nil { webArtURL = nil } }
            return
        }
        forceWebArt = false

        let searchTerm: String
        if isLocalFile && !trackMetadata.album.isEmpty {
            searchTerm = trackMetadata.album
        } else if !trackMetadata.stationName.isEmpty {
            searchTerm = trackMetadata.stationName
        } else if !trackMetadata.album.isEmpty {
            searchTerm = trackMetadata.album
        } else if !trackMetadata.title.isEmpty {
            searchTerm = trackMetadata.title
        } else {
            searchTerm = ""
        }
        let artist = displayArtist
        let key = "\(searchTerm)|\(artist)"
        guard !searchTerm.isEmpty else { return }
        guard key != lastArtSearchKey else { return }
        lastArtSearchKey = key
        webArtURL = nil
        sonosDebugLog("[ART-SEARCH] Searching iTunes for artist='\(artist)' album='\(searchTerm)'")
        Task {
            if let artURL = await AlbumArtSearchService.shared.searchArtwork(
                artist: artist, album: searchTerm
            ) {
                sonosDebugLog("[ART-SEARCH] Found: \(artURL.prefix(80))")
                webArtURL = URL(string: artURL)
            } else {
                sonosDebugLog("[ART-SEARCH] No result from iTunes")
                webArtURL = nil
            }
            updateDisplayedArt()
        }
    }

    func forceITunesArtSearch() {
        let artist = displayArtist
        let searchTerm = !trackMetadata.title.isEmpty ? trackMetadata.title :
                         !trackMetadata.stationName.isEmpty ? trackMetadata.stationName : ""
        guard !searchTerm.isEmpty else { return }
        lastArtSearchKey = ""
        forceWebArt = false
        Task {
            if let artURL = await AlbumArtSearchService.shared.searchArtwork(
                artist: artist, album: searchTerm
            ) {
                webArtURL = URL(string: artURL)
                forceWebArt = true
                let key = "artOverride:\(searchTerm.lowercased())"
                UserDefaults.standard.set(artURL, forKey: key)
                updateDisplayedArt()
            }
        }
    }

    func loadPersistedArtOverride() {
        let searchTerm = !trackMetadata.title.isEmpty ? trackMetadata.title :
                         !trackMetadata.stationName.isEmpty ? trackMetadata.stationName : ""
        guard !searchTerm.isEmpty else { return }
        let key = "artOverride:\(searchTerm.lowercased())"
        if let saved = UserDefaults.standard.string(forKey: key) {
            webArtURL = URL(string: saved)
            forceWebArt = true
            updateDisplayedArt()
        }
    }
}
