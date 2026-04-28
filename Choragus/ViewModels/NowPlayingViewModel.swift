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
    var metadataPollingTask: Task<Void, Never>?

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
        self.art = ArtResolver(
            playHistoryManager: playHistoryManager,
            albumArtSearch: sonosManager.albumArtSearch
        )
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
        let members = group.members
        Task {
            await withTaskGroup(of: Void.self) { tg in
                for member in members {
                    tg.addTask {
                        do {
                            try await self.sonosManager.setMute(device: member, muted: newMuted)
                        } catch {
                            sonosDebugLog("[NOW-PLAYING] setMute failed for \(member.roomName): \(error)")
                        }
                    }
                }
            }
        }
    }

    private var scrollVolumeCommitTask: Task<Void, Never>?

    /// Applies a scroll-wheel volume step to the coordinator's master volume
    /// and debounces the SOAP commit. Called from the mouse-wheel capture in
    /// NowPlayingView — intentionally not exposed to any other path so the
    /// debounce window (300 ms of quiet) can't interact with the drag-slider
    /// commit-on-release flow. Pure step application: uses the same
    /// `setVolume()` routing as the slider (grace periods, proportional
    /// group volume, per-speaker fan-out) to stay feature-consistent.
    func applyScrollVolumeStep(_ step: Int) {
        let current = volume
        let next = max(0, min(100, current + Double(step)))
        guard next != current else { return }
        volume = next
        setVolume()
        scrollVolumeCommitTask?.cancel()
        scrollVolumeCommitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Timing.scrollVolumeCommitDelay)
            guard !Task.isCancelled, let self else { return }
            self.commitVolume()
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
        // Per-device SOAPs in parallel — for a group of N speakers a
        // serial loop took N × ~150 ms (the cumulative SOAP round-trip
        // time), which read as sluggish on 3+ speaker groups. TaskGroup
        // fires them concurrently so the whole commit completes in one
        // round-trip instead of N.
        let members = group.members
        let snapshot = speakerVolumes
        Task {
            await withTaskGroup(of: Void.self) { tg in
                for member in members {
                    let vol = Int(snapshot[member.id] ?? 0)
                    tg.addTask {
                        do {
                            try await self.sonosManager.setVolume(device: member, volume: vol)
                        } catch {
                            sonosDebugLog("[NOW-PLAYING] commitVolume failed for \(member.roomName): \(error)")
                        }
                    }
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

    /// Reset all local state when switching to a different group
    func resetForGroupChange() {
        isInitialized = false
        isDraggingVolume = false
        isDraggingSeek = false
        volumeGraceUntil = .distantPast
        muteGraceUntil = .distantPast
        speakerVolumes.removeAll()
        speakerMutes.removeAll()
        volume = 0
        isMuted = false
        smoothPosition = 0
        lastKnownPosition = 0
        lastPositionTimestamp = .distantPast
        crossfadeOn = false
        actionInFlight = nil
    }

    func syncFromManager() {
        isInitialized = true
        syncVolumeFromManager()
        syncMuteFromManager()
    }

    func syncVolumeFromManager() {
        guard !isDraggingVolume else { return } // Don't override while user is dragging

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

        // Always update display art (handles ad break → station art switch)
        art.updateDisplayedArt(trackMetadata: metadata, group: group)

        // During ad breaks, skip searches but still update display
        guard !metadata.isAdBreak else { return }

        // Update from new albumArtURI if available
        if let artStr = metadata.albumArtURI, !artStr.isEmpty, let url = URL(string: artStr) {
            if art.displayedArtURL != url && !art.forceWebArt {
                art.displayedArtURL = url
            }
            // The speaker's reported art is the source of truth. If we had
            // previously pinned a different URL for this track (e.g. an early
            // metadata frame during a queue advance held a stale /getaa URL
            // from the previous track until Sonos refreshed its internal
            // art), invalidate that stale pin so the next resolution starts
            // fresh from the current metadata.
            if let pinned = art.pinnedURL(for: metadata), pinned != url, !art.forceWebArt {
                art.invalidateArtResolution(for: metadata)
            }
        } else if !art.forceWebArt {
            // Speaker now reports no art at all for this track. Any pin set
            // from an earlier (stale) metadata frame is wrong — clear it.
            if art.pinnedURL(for: metadata) != nil {
                art.invalidateArtResolution(for: metadata)
            }
            // Also clear displayedArtURL: updateDisplayedArt's sticky guard
            // (currentURI == lastTrackURI && resolved == nil) preserves the
            // previous frame's URL across same-track metadata polls, which
            // here would keep showing the stale URL after the speaker
            // reverted to "no art". Sync to truth.
            if art.displayedArtURL != nil {
                art.displayedArtURL = nil
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
        // Don't override manually chosen art
        if art.forceWebArt { return }

        // Once we've resolved art for a track in this session (via any path
        // — metadata, cached, iTunes search), don't keep re-searching on
        // every poll. iTunes returns different top hits across calls for
        // queries like "Air + The Virgin Suicides" (Redux vs Original
        // Soundtrack), so repeated searches visibly flip the cover. Only
        // explicit user actions (Search Artwork, Refresh Artwork, Ignore,
        // Clear) invalidate this and allow another search.
        if art.isArtResolved(for: metadata) { return }

        let hasArt = metadata.albumArtURI != nil && !(metadata.albumArtURI?.isEmpty ?? true)
        let isLocalFile = metadata.trackURI.map(URIPrefix.isLocal) ?? false
        let hasLocalOnlyArt = hasArt && (metadata.albumArtURI?.contains("/getaa?") ?? false)
        // For service tracks with persistent art URLs, no search needed —
        // pin the metadata URL as the canonical answer for this track.
        //
        // EXCEPT on radio: `albumArtURI` for a radio stream is the
        // station's logo URL, not track-specific art. Pinning it
        // shadows the `radioTrackArtURL` that `searchRadioTrackArt`
        // resolves async — the user sees the station logo even when
        // we've successfully found cover art for the song.
        let onRadio = !metadata.stationName.isEmpty || metadata.isRadioStream
        if hasArt && !hasLocalOnlyArt {
            art.clearWebArt()
            if !onRadio,
               let artStr = metadata.albumArtURI, let url = URL(string: artStr) {
                art.markArtResolved(for: metadata, url: url)
            }
            return
        }
        // Trust whatever art the speaker is serving via /getaa? — that's
        // either the file's embedded art (local files), the album folder
        // image, or service-supplied art proxied through the speaker
        // (Spotify, Apple Music, Tidal, etc.). Only fall through to iTunes
        // when the speaker has no art at all. This avoids generic
        // title-collision results (e.g. "This Christmas" returning a
        // Toni Braxton album for a Joe track) from overriding correct art.
        if hasLocalOnlyArt {
            art.clearWebArt()
            if !onRadio,
               let artStr = metadata.albumArtURI, let url = URL(string: artStr) {
                art.markArtResolved(for: metadata, url: url)
            }
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
        // Strip parenthetical content and everything after unclosed ( or [
        var cleanedSearchTerm = searchTerm
            .replacingOccurrences(of: "\\s*\\([^)]*\\)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s*\\[[^\\]]*\\]", with: "", options: .regularExpression)
        if let p = cleanedSearchTerm.firstIndex(of: "(") { cleanedSearchTerm = String(cleanedSearchTerm[..<p]) }
        if let b = cleanedSearchTerm.firstIndex(of: "[") { cleanedSearchTerm = String(cleanedSearchTerm[..<b]) }
        cleanedSearchTerm = cleanedSearchTerm.trimmingCharacters(in: .whitespaces)
        let effectiveSearch = cleanedSearchTerm.isEmpty ? searchTerm : cleanedSearchTerm

        Task {
            var foundArt = await sonosManager.albumArtSearch.searchArtwork(
                artist: artist, album: effectiveSearch
            )

            // If no result, try artist only
            if foundArt == nil, !artist.isEmpty {
                foundArt = await sonosManager.albumArtSearch.searchArtwork(
                    artist: artist, album: ""
                )
            }

            if let artURL = foundArt, let url = URL(string: artURL) {
                // Always update history and cache with the found art
                art.playHistoryManager?.updateArtwork(
                    forTitle: metadata.title, artist: metadata.artist, artURL: artURL
                )
                sonosManager.cacheArtURL(artURL, forURI: metadata.trackURI ?? "", title: metadata.title, itemID: "")
                art.setWebArtResult(url)
                // Pin the resolved URL so every subsequent display call
                // returns this exact URL for this track — no more iTunes
                // reruns, no more alternation between candidate covers.
                art.markArtResolved(for: metadata, url: url)
                art.updateDisplayedArt(trackMetadata: metadata, group: group)
            } else {
                if !hasLocalOnlyArt {
                    art.setWebArtResult(nil)
                }
            }
        }
    }

    private func searchRadioTrackArt(_ metadata: TrackMetadata) {
        // While paused on a radio stream, metadata can churn — title briefly
        // goes empty between stream-content pings and then repopulates. Each
        // oscillation would otherwise clear radioTrackArtURL, then search,
        // then set it again, producing a visible artwork flicker. Don't
        // re-evaluate radio track art while paused; the existing art stays.
        guard transportState.isActive else { return }

        // Real "no current track" cases — clear and bail.
        if metadata.stationName.isEmpty || metadata.isAdBreak {
            art.clearRadioTrackArt()
            return
        }
        // Transient empty/echoed title while still on the same station —
        // don't clear `radioTrackArtURL`, just don't re-search. Holds the
        // last-good track art across the metadata blip instead of flicking
        // back to the station logo. Without this, every poll where the
        // title hasn't repopulated yet (or matches the station name as a
        // placeholder) clears the art and the next iTunes search may not
        // re-resolve it (e.g. tracks where the radio's "artist" tag is the
        // composer/conductor, not the recording artist).
        if metadata.title.isEmpty || metadata.title == metadata.stationName {
            return
        }
        let key = "\(metadata.title)|\(metadata.artist)"
        guard art.shouldSearchRadioTrack(key: key) else { return }
        art.setRadioTrackKey(key)
        if art.radioStationArtURL == nil, let stationArt = art.displayedArtURL ?? metadata.albumArtURI.flatMap({ URL(string: $0) }) {
            art.radioStationArtURL = stationArt
        }
        let artist = TrackMetadata.filterDeviceID(metadata.artist)
        // For radio streams, keep the full title including parenthetical content
        // since it often contains the movie/album name (e.g. "Tristania (Troia Troy)")
        let searchTitle = metadata.title
        Task {
            if let artURL = await sonosManager.albumArtSearch.searchRadioTrackArt(
                artist: artist, title: searchTitle
            ) {
                sonosDebugLog("[ART/RADIO] resolved \(searchTitle) – \(artist) → \(artURL.prefix(80))")
                art.setRadioTrackArt(URL(string: artURL))
                art.playHistoryManager?.updateArtwork(
                    forTitle: metadata.title, artist: metadata.artist, artURL: artURL
                )
                // Cache so menu bar and other views can find it
                sonosManager.cacheArtURL(artURL, forURI: metadata.trackURI ?? "", title: metadata.title, itemID: "")
            } else {
                sonosDebugLog("[ART/RADIO] no result for \(searchTitle) – \(artist)")
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
        // Position interpolation — no network calls
        progressTimer = Timer.scheduledTimer(withTimeInterval: Timing.progressTimerInterval, repeats: true) { [weak self] _ in
            guard let self, !isDraggingSeek else { return }
            let now = Date()
            if now > positionFrozenUntil && transportState.isPlaying {
                let elapsed = now.timeIntervalSince(lastPositionTimestamp)
                let newPosition = lastKnownPosition + elapsed
                if abs(newPosition - smoothPosition) >= 0.5 {
                    smoothPosition = newPosition
                }
            }
        }
        // Lightweight metadata poll for active group — catches radio track changes
        // that don't trigger UPnP events. Single getPositionInfo call every 5s.
        // Updates display state only — history logging handled by TransportStrategy.
        metadataPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Timing.metadataPolling)
                guard !Task.isCancelled, let self else { return }
                guard let coordinator = group.coordinator else { return }
                do {
                    let position = try await sonosManager.getPositionInfo(group: group)
                    let enriched = await enrichMetadata(position, state: transportState, coordinator: coordinator)
                    lastKnownPosition = enriched.position
                    lastPositionTimestamp = Date()
                    handleMetadataChanged(enriched)
                } catch {
                    sonosDebugLog("[NOW-PLAYING] Metadata poll failed: \(error)")
                }
            }
        }
    }

    func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
        metadataPollingTask?.cancel()
        metadataPollingTask = nil
    }

    // MARK: - Fetch Current State

    /// Fetches live state for the selected group directly from speakers.
    /// Bypasses cache, grace periods, and thresholds — always sets exact current values.
    func fetchCurrentState() async {
        // Direct speaker query for all state
        if let manager = sonosManager as? SonosManager {
            await manager.scanGroup(group)
        }

        // Force-set local state from the just-fetched @Published values
        // No grace period or threshold checks — this is an explicit user action
        let meta = sonosManager.groupTrackMetadata[group.coordinatorID] ?? TrackMetadata()
        lastKnownPosition = meta.position
        lastPositionTimestamp = Date()
        smoothPosition = meta.position
        crossfadeOn = (try? await sonosManager.getCrossfadeMode(group: group)) ?? false

        // Force volume/mute from live data — bypass grace periods
        var totalVol = 0.0
        for member in group.members {
            let v = Double(sonosManager.deviceVolumes[member.id] ?? 0)
            speakerVolumes[member.id] = v
            speakerMutes[member.id] = sonosManager.deviceMutes[member.id] ?? false
            totalVol += v
        }
        if group.members.count > 1 {
            volume = totalVol / Double(group.members.count)
        } else {
            volume = totalVol
        }
        lastMasterVolume = volume
        isMuted = group.members.allSatisfy { sonosManager.deviceMutes[$0.id] == true }
    }

}
