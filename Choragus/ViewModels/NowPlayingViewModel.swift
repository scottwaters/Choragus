/// NowPlayingViewModel.swift — Business logic for the Now Playing view.
///
/// Handles transport control, volume management, position interpolation,
/// album art resolution, and metadata display. The view binds to published
/// state and calls action methods.
import SwiftUI
import Combine
import Observation
import SonosKit

/// Playhead position comes from the `PositionAnchor` in SonosKit,
/// maintained by `SonosManager` and shared by the inline panel and the
/// karaoke popout. Views wrap `projected(at:)` in a `TimelineView` so the
/// playhead advances smoothly between authoritative events; this view
/// model is a pure consumer.

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

    // MARK: - Volume / Mute (derived from SonosManager)
    //
    // No local mirror dictionaries. Volumes and mutes read directly from
    // `sonosManager.deviceVolumes` / `deviceMutes` so the UI re-renders
    // the moment the manager publishes, with no intermediate-state race
    // between multiple writes inside one event handler.

    /// Master slider scratchpad, used only while the user is dragging.
    /// Outside a drag, `volume` derives from current member volumes.
    var dragVolume: Double = 0
    var isDraggingVolume = false

    /// Immutable drag-start reference: per-member volumes + master
    /// baseline. Every mid-drag tick computes targets against it, never
    /// the running values — otherwise members clamped at 0/100 lose their
    /// offset to master permanently. Cleared by `commitVolume`,
    /// `resetForGroupChange`, and at the end of `fetchCurrentState`.
    private var dragSnapshot: (master: Double, volumes: [String: Double])?

    /// Holding the master at 0 for `zeroHoldToSyncDelay` discards the
    /// per-member spread so the group rises together (#74). Cancelled the
    /// moment the master leaves 0.
    private var zeroHoldTask: Task<Void, Never>?

    private static let zeroHoldToSyncDelay: Duration = .seconds(1)

    // MARK: - Position

    /// Shared playhead anchor maintained by `SonosManager`; every
    /// position-displaying view reads from it so they stay in lockstep.
    var positionAnchor: PositionAnchor {
        sonosManager.groupPositionAnchors[group.coordinatorID] ?? .zero
    }

    /// Seek-slider drag scratchpad. Time text and lyrics still project
    /// from `positionAnchor`; on drag-end this seeds the seek + new anchor.
    var dragPosition: TimeInterval = 0
    var isDraggingSeek = false

    // MARK: - Transport UI

    var actionInFlight: String?
    var crossfadeOn = false

    // MARK: - Derived state (read directly from SonosManager)

    /// Master volume — average of the group's per-member volumes when
    /// idle; the drag value while a slider is in flight. Reading it
    /// registers a SwiftUI dependency on `sonosManager.deviceVolumes`.
    var volume: Double {
        if isDraggingVolume { return dragVolume }
        return currentAverageVolume
    }

    /// True iff every group member is muted. Derived from
    /// `sonosManager.deviceMutes` on every read so optimistic mute
    /// propagation surfaces in the master toggle immediately.
    var isMuted: Bool {
        let members = group.members
        guard !members.isEmpty else { return false }
        return members.allSatisfy { sonosManager.deviceMutes[$0.id] ?? false }
    }

    /// Per-member volume map. Computed view over manager state — set
    /// via the `Binding` in `VolumeControlView` whose setter routes
    /// each diff through `sonosManager.updateDeviceVolume`.
    var speakerVolumes: [String: Double] {
        var result: [String: Double] = [:]
        for member in group.members {
            result[member.id] = Double(sonosManager.deviceVolumes[member.id] ?? 0)
        }
        return result
    }

    /// Per-member mute map. Same pattern as `speakerVolumes`.
    var speakerMutes: [String: Bool] {
        var result: [String: Bool] = [:]
        for member in group.members {
            result[member.id] = sonosManager.deviceMutes[member.id] ?? false
        }
        return result
    }

    private var currentAverageVolume: Double {
        let members = group.members
        guard !members.isEmpty else { return 0 }
        let sum = members.reduce(0.0) { $0 + Double(sonosManager.deviceVolumes[$1.id] ?? 0) }
        return sum / Double(members.count)
    }

    // MARK: - Art

    var art: ArtResolver {
        artCoordinator.resolver(for: group.coordinatorID)
    }

    private let artCoordinator: ArtCoordinator

    // MARK: - Init

    init(sonosManager: any NowPlayingServices,
         group: SonosGroup,
         artCoordinator: ArtCoordinator) {
        self.sonosManager = sonosManager
        self.group = group
        self.artCoordinator = artCoordinator
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

    /// Seek-by-offset for the ±15s / ±30s skip buttons. Clamps to the
    /// track range; disabled at the call site for radio/stream sources.
    func seekRelative(by deltaSeconds: TimeInterval) {
        let now = currentPosition
        let target = max(0, now + deltaSeconds)
        let duration = trackMetadata.duration
        let clamped: TimeInterval
        if duration > 0 {
            // Stop a second before the end so holding +30 near the track
            // end doesn't trigger a queue advance.
            clamped = min(target, max(0, duration - 1))
        } else {
            clamped = target
        }
        seekToPosition(clamped)
    }

    func seekToPosition(_ seconds: TimeInterval) {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        let timeStr = String(format: "%d:%02d:%02d", hours, minutes, secs)
        // Apply the seek to the shared anchor immediately so panel and
        // karaoke window reflect it before the speaker's confirmation
        // event arrives.
        sonosManager.setPositionAnchor(
            coordinatorID: group.coordinatorID,
            PositionAnchor(time: max(0, seconds),
                           wallClock: Date(),
                           isPlaying: transportState.isPlaying)
        )
        sonosManager.setPositionGrace(coordinatorID: group.coordinatorID, duration: Timing.positionFreezeAfterSeek)
        Task {
            do {
                try await sonosManager.seek(group: group, to: timeStr)
            } catch {
                sonosDebugLog("[NOW-PLAYING] Seek failed: \(error)")
            }
        }
    }

    /// Snapshot of the projected playhead for one-shot consumers. Views
    /// should call `positionAnchor.projected(at:)` inside a `TimelineView`
    /// so the read happens on each animation frame.
    var currentPosition: TimeInterval {
        positionAnchor.projected(at: Date())
    }

    // MARK: - Volume Actions

    func toggleMute() {
        let newMuted = !isMuted
        sonosDebugLog("[UI-TAP] toggleMute group=\(group.name) target=\(newMuted)")
        // Optimistic write straight into the manager; view bindings read
        // back from `sonosManager.deviceMutes` on the next render.
        for member in group.members {
            sonosManager.updateDeviceMute(member.id, muted: newMuted)
        }
        sonosDebugLog("[UI-OPT] toggleMute applied to \(group.members.count) members value=\(newMuted)")
        let members = group.members
        Task {
            sonosDebugLog("[UI-SOAP-START] toggleMute group=\(self.group.name)")
            let started = Date()
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
            let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
            sonosDebugLog("[UI-SOAP-END] toggleMute group=\(self.group.name) elapsed=\(elapsedMs)ms")
        }
    }

    private var scrollVolumeCommitTask: Task<Void, Never>?

    /// Throttled mid-drag commit: a per-member SOAP fan-out at most once
    /// per 250 ms so other controllers see progressive volume change.
    /// Cancelled at drag-end so `commitVolume` is the final write.
    private var throttledMasterCommitTask: Task<Void, Never>?
    /// Per-device throttled commits for the per-speaker sliders.
    private var throttledMemberCommitTasks: [String: Task<Void, Never>] = [:]
    private static let throttleInterval: UInt64 = 250_000_000  // 250 ms

    /// Applies a scroll-wheel step to the master volume and debounces the
    /// SOAP commit. Only called from the mouse-wheel capture so the
    /// debounce window can't interact with the slider's commit-on-release.
    func applyScrollVolumeStep(_ step: Int) {
        let current = currentAverageVolume
        let next = max(0, min(100, current + Double(step)))
        guard next != current else { return }
        applyMasterVolume(next)
        scrollVolumeCommitTask?.cancel()
        scrollVolumeCommitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Timing.scrollVolumeCommitDelay)
            guard !Task.isCancelled, let self else { return }
            self.commitVolume()
        }
    }

    /// Master slider drag-tick: distributes `newMaster` across members
    /// (proportional or linear) into `sonosManager.deviceVolumes`. Targets
    /// are computed against the immutable drag-start snapshot so members
    /// clamped at 0/100 recover their offset when dragged back.
    func applyMasterVolume(_ newMaster: Double) {
        dragVolume = newMaster
        let snap = dragSnapshot ?? captureDragSnapshot()
        let mode: GroupVolumeDistribution.Mode =
            UserDefaults.standard.bool(forKey: UDKey.proportionalGroupVolume) ? .proportional : .linear

        // Ratios, the zero-master case and clamp recovery live in
        // GroupVolumeDistribution.
        let targets = GroupVolumeDistribution.targets(
            master: newMaster,
            memberIDs: group.members.map(\.id),
            snapshot: .init(master: snap.master, volumes: snap.volumes),
            mode: mode)

        for member in group.members {
            guard let volume = targets[member.id] else { continue }
            sonosManager.updateDeviceVolume(member.id, volume: volume)
        }
        updateZeroHold(master: newMaster)
        scheduleThrottledMasterCommit()
    }

    /// Arms or cancels the hold-at-zero sync. Members are already at 0;
    /// what the hold changes is the snapshot they rise from.
    private func updateZeroHold(master: Double) {
        guard master <= 0 else {
            zeroHoldTask?.cancel()
            zeroHoldTask = nil
            return
        }
        guard zeroHoldTask == nil else { return }   // already counting
        zeroHoldTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.zeroHoldToSyncDelay)
            guard let self, !Task.isCancelled, self.dragVolume <= 0 else { return }
            let levelled = GroupVolumeDistribution.levelledSnapshot(
                memberIDs: self.group.members.map(\.id))
            self.dragSnapshot = (master: levelled.master, volumes: levelled.volumes)
        }
    }

    /// Captures the drag-start reference (master baseline + per-member
    /// volumes). Never rewritten until `commitVolume` clears it.
    @discardableResult
    private func captureDragSnapshot() -> (master: Double, volumes: [String: Double]) {
        var volumes: [String: Double] = [:]
        for member in group.members {
            volumes[member.id] = Double(sonosManager.deviceVolumes[member.id] ?? 0)
        }
        let snap = (master: currentAverageVolume, volumes: volumes)
        dragSnapshot = snap
        return snap
    }

    /// Coalesces drag ticks: each tick cancels the pending task and
    /// schedules a fresh one, so SOAP fires only after 250 ms of quiet.
    /// `commitVolume` cancels it at drag-end and writes the final value.
    private func scheduleThrottledMasterCommit() {
        throttledMasterCommitTask?.cancel()
        throttledMasterCommitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.throttleInterval)
            guard !Task.isCancelled, let self else { return }
            let snapshot = self.group.members.map { ($0, self.sonosManager.deviceVolumes[$0.id] ?? 0) }
            await withTaskGroup(of: Void.self) { tg in
                for (member, vol) in snapshot {
                    tg.addTask { @MainActor in
                        try? await self.sonosManager.setVolume(device: member, volume: vol)
                    }
                }
            }
        }
    }

    func commitVolume() {
        // The final SOAP below is authoritative; drop the pending
        // throttled commit.
        throttledMasterCommitTask?.cancel()
        throttledMasterCommitTask = nil
        // A pending zero-hold must not fire against a later drag's snapshot.
        zeroHoldTask?.cancel()
        zeroHoldTask = nil
        // Per-device SOAPs fan out concurrently so an N-speaker commit
        // completes in one round-trip rather than N.
        let members = group.members
        let snapshot = members.map { ($0, sonosManager.deviceVolumes[$0.id] ?? 0) }
        dragSnapshot = nil
        Task {
            sonosDebugLog("[UI-SOAP-START] commitVolume group=\(self.group.name)")
            let started = Date()
            await withTaskGroup(of: Void.self) { tg in
                for (member, vol) in snapshot {
                    tg.addTask {
                        do {
                            try await self.sonosManager.setVolume(device: member, volume: vol)
                        } catch {
                            sonosDebugLog("[NOW-PLAYING] commitVolume failed for \(member.roomName): \(error)")
                        }
                    }
                }
            }
            let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
            sonosDebugLog("[UI-SOAP-END] commitVolume group=\(self.group.name) elapsed=\(elapsedMs)ms")
        }
    }

    // MARK: - Per-Speaker Volume/Mute (called from VolumeControlView)

    func setSpeakerVolume(device: SonosDevice, volume: Int) async {
        // Drag-end final commit; the pending throttled SOAP is dropped.
        throttledMemberCommitTasks[device.id]?.cancel()
        throttledMemberCommitTasks[device.id] = nil
        sonosDebugLog("[UI-TAP] setSpeakerVolume room=\(device.roomName) target=\(volume)")
        sonosManager.updateDeviceVolume(device.id, volume: volume)
        sonosDebugLog("[UI-OPT] setSpeakerVolume applied")
        sonosDebugLog("[UI-SOAP-START] setSpeakerVolume room=\(device.roomName)")
        let started = Date()
        do {
            try await sonosManager.setVolume(device: device, volume: volume)
        } catch {
            sonosDebugLog("[VOLUME] setSpeakerVolume failed for \(device.roomName): \(error)")
        }
        let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
        sonosDebugLog("[UI-SOAP-END] setSpeakerVolume room=\(device.roomName) elapsed=\(elapsedMs)ms")
    }

    /// Per-device commit generation. A completing throttled task may only
    /// nil its dictionary slot while it is still the latest task for that
    /// device; an unconditional nil would wipe a newer task's slot.
    private var memberCommitGenerations: [String: Int] = [:]

    /// Per-device equivalent of `scheduleThrottledMasterCommit`, invoked
    /// from the per-speaker slider on each drag tick. Cancelled by
    /// `setSpeakerVolume` at drag-end.
    func scheduleThrottledSpeakerCommit(device: SonosDevice, volume: Int) {
        throttledMemberCommitTasks[device.id]?.cancel()
        let generation = (memberCommitGenerations[device.id] ?? 0) + 1
        memberCommitGenerations[device.id] = generation
        throttledMemberCommitTasks[device.id] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.throttleInterval)
            guard !Task.isCancelled, let self else { return }
            do {
                try await self.sonosManager.setVolume(device: device, volume: volume)
            } catch {
                sonosDebugLog("[VOLUME] throttled mid-drag setVolume failed for \(device.roomName): \(error)")
            }
            if self.memberCommitGenerations[device.id] == generation {
                self.throttledMemberCommitTasks[device.id] = nil
            }
        }
    }

    func setSpeakerMute(device: SonosDevice, muted: Bool) async {
        sonosDebugLog("[UI-TAP] setSpeakerMute room=\(device.roomName) target=\(muted)")
        sonosManager.updateDeviceMute(device.id, muted: muted)
        sonosDebugLog("[UI-OPT] setSpeakerMute applied")
        sonosDebugLog("[UI-SOAP-START] setSpeakerMute room=\(device.roomName)")
        let started = Date()
        do {
            try await sonosManager.setMute(device: device, muted: muted)
        } catch {
            sonosDebugLog("[VOLUME] setSpeakerMute failed for \(device.roomName): \(error)")
        }
        let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
        sonosDebugLog("[UI-SOAP-END] setSpeakerMute room=\(device.roomName) elapsed=\(elapsedMs)ms")
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

    /// Token for the action that owns `actionInFlight`. Only the call
    /// that set the flag may clear it, so a still-running old action's
    /// completion can't clear a newer action's in-flight state.
    private var actionGeneration = 0

    func performAction(_ id: String, _ action: @escaping () async throws -> Void) {
        guard actionInFlight == nil else { return }
        actionInFlight = id
        actionGeneration += 1
        let generation = actionGeneration
        Task {
            do {
                try await action()
            } catch {
                ErrorHandler.shared.handle(error, context: "TRANSPORT")
            }
            if generation == actionGeneration { actionInFlight = nil }
        }
    }

    // MARK: - Group lifecycle

    /// Resets transient UI state when switching group. Volume / mute
    /// derive from the manager and need no reset.
    func resetForGroupChange() {
        isDraggingVolume = false
        isDraggingSeek = false
        dragSnapshot = nil
        sonosManager.setPositionAnchor(coordinatorID: group.coordinatorID, .zero)
        dragPosition = 0
        crossfadeOn = false
        actionInFlight = nil
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

    /// One-shot formatted position (e.g. accessibility labels). The
    /// visible time text formats from `positionAnchor.projected(at:)`
    /// inside a `TimelineView` so it updates each frame.
    var smoothPositionString: String {
        formatTime(currentPosition)
    }

    func formatTime(_ interval: TimeInterval) -> String {
        PlaybackTimeFormat.string(interval)
    }

    // MARK: - Track-change side effects (position anchor only)

    func handleMetadataChanged(_ metadata: TrackMetadata) {
        let uriChanged = art.lastTrackURI != (metadata.trackURI ?? metadata.title)
        // Hard discontinuity — bypass drift threshold.
        if uriChanged {
            sonosManager.setPositionAnchor(
                coordinatorID: group.coordinatorID,
                PositionAnchor(time: max(0, metadata.position),
                               wallClock: Date(),
                               isPlaying: transportState.isPlaying)
            )
        }
    }

    func onArtAppear() {
        art.loadPersistedArtOverride(trackMetadata: trackMetadata, group: group)
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

    // MARK: - Fetch Current State

    /// `LastChange` events exclude `RelativeTimePosition`, so the
    /// visible seek bar needs a direct poll for the active group.
    func pollActivePosition() async {
        guard group.coordinator != nil else { return }
        do {
            let position = try await sonosManager.getPositionInfo(group: group)
            sonosManager.transportDidUpdatePosition(
                group.coordinatorID,
                position: position.position,
                duration: position.duration
            )
        } catch {
            // Reconciliation poll is the safety net.
        }
    }

    /// Bypasses cache, grace periods, and thresholds — always sets exact current values.
    func fetchCurrentState() async {
        // Direct speaker query for all state
        if let manager = sonosManager as? SonosManager {
            await manager.scanGroup(group)
        }

        // Explicit user action: the anchor snaps to the fetched position
        // with no grace period or threshold checks.
        let meta = sonosManager.groupTrackMetadata[group.coordinatorID] ?? TrackMetadata()
        sonosManager.setPositionAnchor(
            coordinatorID: group.coordinatorID,
            PositionAnchor(time: max(0, meta.position),
                           wallClock: Date(),
                           isPlaying: transportState.isPlaying)
        )
        // Speaker switches whose metadata is already cached don't
        // republish, so drive the handler directly.
        handleMetadataChanged(meta)
        crossfadeOn = (try? await sonosManager.getCrossfadeMode(group: group)) ?? false

        // Clear the stale drag snapshot so the next drag captures fresh
        // state — but not mid-drag: the awaits above are long enough for
        // a drag to have started, and wiping its reference snapshot breaks
        // the offset-preserving distribution.
        if !isDraggingVolume { dragSnapshot = nil }
    }

}
