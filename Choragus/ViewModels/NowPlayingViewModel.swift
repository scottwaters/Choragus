/// NowPlayingViewModel.swift — Business logic for the Now Playing view.
///
/// Handles transport control, volume management, position interpolation,
/// album art resolution, and metadata display. The view binds to published
/// state and calls action methods.
import SwiftUI
import Combine
import Observation
import SonosKit

/// Anchored position model — single source of truth for "where the
/// playhead is right now" used by every position-displaying view
/// (seek slider, time text, synced lyrics). The view layer wraps
/// `projected(at:)` in a `TimelineView` to advance smoothly between
/// authoritative events.
///
/// Why this exists: the previous design wrote `smoothPosition` from
/// two competing sources (a 1 Hz timer that nudged forward in 0.5 s
/// deadband-filtered steps, plus event-driven snap-overwrites from
/// `groupPositions`). Each write reached the view as a discrete
/// jump — backward when the speaker's authoritative time lagged the
/// wall-clock projection, forward when it led, never smooth between.
/// A single anchor + per-frame wall-clock projection eliminates the
/// jumps by construction: between authoritative events the view
/// extrapolates monotonically, and authoritative events only rebase
/// the anchor when drift exceeds the noise floor.
// `PositionAnchor` now lives in SonosKit (`Models/PositionAnchor.swift`) so
// the karaoke popout window and the inline panel read from a single
// shared anchor maintained by `SonosManager`. The drift-tolerant rebase
// logic moved alongside it; this VM is now a pure consumer.

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
    // `sonosManager.deviceVolumes` / `deviceMutes` so UI re-renders the
    // moment the manager publishes — no `.onReceive` middleman, no
    // intermediate-state race when multiple `@Published` writes happen
    // inside one event handler (the bug that left FP5 visually unmuted
    // for 10+ s after Office's coord event already propagated to its
    // member volume).

    /// Master slider scratchpad — only used while the user is actively
    /// dragging. Outside of drag, `volume` derives from current member
    /// volumes so external Sonos-app changes surface immediately.
    var dragVolume: Double = 0
    var isDraggingVolume = false

    /// Drag snapshot of per-member volumes + master baseline, captured
    /// on the first `applyMasterVolume` call after the previous drag
    /// committed. The snapshot is the IMMUTABLE reference for the entire
    /// drag — every mid-drag tick computes targets against it, never
    /// against the running per-member values. Without this, members that
    /// hit 0/100 lose their offset to master permanently (the running
    /// values get clamped, then on the way back the clamped value is
    /// treated as the "real" value, leaving alignment compressed forever).
    /// Cleared by `commitVolume`, `resetForGroupChange`, and at the end
    /// of `fetchCurrentState`.
    private var dragSnapshot: (master: Double, volumes: [String: Double])?

    // MARK: - Position

    /// Shared playhead anchor maintained by `SonosManager`. Every
    /// position-displaying view (panel seek bar, time text, synced
    /// lyrics, karaoke popout) reads from this single source so they
    /// stay in lockstep.
    var positionAnchor: PositionAnchor {
        sonosManager.groupPositionAnchors[group.coordinatorID] ?? .zero
    }

    /// Drag scratchpad — populated only while the user is actively
    /// dragging the seek slider. The slider's binding writes here; the
    /// time text and lyrics still project from `positionAnchor`. On
    /// drag-end this value seeds the seek + new anchor.
    var dragPosition: TimeInterval = 0
    var isDraggingSeek = false

    var metadataPollingTask: Task<Void, Never>?

    // MARK: - Transport UI

    var actionInFlight: String?
    var crossfadeOn = false

    // MARK: - Derived state (read directly from SonosManager)

    /// Master volume — average of the group's per-member volumes when
    /// idle; the user's drag value while a slider is in flight. Reading
    /// this property registers a SwiftUI dependency on
    /// `sonosManager.deviceVolumes`, so external speaker-side changes
    /// reach the slider on the very next render tick.
    var volume: Double {
        if isDraggingVolume { return dragVolume }
        return currentAverageVolume
    }

    /// True iff every group member is muted. No stored copy — derived
    /// from `sonosManager.deviceMutes` on every read so optimistic
    /// coord-driven mute propagation surfaces in the master toggle the
    /// instant the manager dictionary is written.
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

    /// Convenience seek-by-offset for the ±15s / ±30s skip buttons in
    /// the Now Playing transport row. Reads the projected playhead via
    /// `currentPosition`, clamps to the track range, and dispatches to
    /// the absolute-position seek path. Disabled at the call site for
    /// non-queue radio/stream sources where seeking is meaningless.
    func seekRelative(by deltaSeconds: TimeInterval) {
        let now = currentPosition
        let target = max(0, now + deltaSeconds)
        let duration = trackMetadata.duration
        let clamped: TimeInterval
        if duration > 0 {
            // Stop a hair before the end so we don't trigger an immediate
            // queue advance when the user holds +30 near the track end —
            // they wanted to skip in-track, not to the next song.
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
        // Apply the seek to the shared anchor immediately so every UI
        // (panel + karaoke window) reflects the new position before the
        // speaker's confirmation event arrives (Sonos's grace window
        // suppresses incoming position events for ~3 s anyway).
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

    // Anchor maintenance moved to `SonosManager` — both the inline
    // panel and the karaoke popout now consume the same shared anchor
    // via `sonosManager.groupPositionAnchors[coordinatorID]`. The drift-
    // tolerant rebase, transport-state freeze, and seek-explicit set
    // all happen there.

    /// Project the current playhead. Used by code paths that need a
    /// snapshot value (history logging, copy-track-info, etc.). Views
    /// should use `TimelineView` and call `positionAnchor.projected(at:)`
    /// directly so the read happens on each animation frame.
    var currentPosition: TimeInterval {
        positionAnchor.projected(at: Date())
    }

    // MARK: - Volume Actions

    func toggleMute() {
        let newMuted = !isMuted
        sonosDebugLog("[UI-TAP] toggleMute group=\(group.name) target=\(newMuted)")
        // Optimistic write straight into the manager. View bindings read
        // back from `sonosManager.deviceMutes` on the next render — no
        // local mirror to drift, no `.onReceive` race window.
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

    /// Throttled mid-drag commit. Fires a per-member SOAP fan-out at
    /// most once every 250 ms while the master slider is actively
    /// being dragged so other listeners (Sonos app on phone, second
    /// controller) hear progressive volume change instead of jumping
    /// at drag-end. Cancelled at drag-end so `commitVolume` is the
    /// authoritative final write.
    private var throttledMasterCommitTask: Task<Void, Never>?
    /// Per-device throttled commits for the per-speaker sliders.
    private var throttledMemberCommitTasks: [String: Task<Void, Never>] = [:]
    private static let throttleInterval: UInt64 = 250_000_000  // 250 ms

    /// Applies a scroll-wheel volume step to the coordinator's master volume
    /// and debounces the SOAP commit. Called from the mouse-wheel capture in
    /// NowPlayingView — intentionally not exposed to any other path so the
    /// debounce window (300 ms of quiet) can't interact with the drag-slider
    /// commit-on-release flow. Pure step application: uses the same
    /// `setVolume()` routing as the slider (grace periods, proportional
    /// group volume, per-speaker fan-out) to stay feature-consistent.
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

    /// Master slider drag-tick: distribute `newMaster` across members
    /// (proportional or linear) and write the per-member values straight
    /// into `sonosManager.deviceVolumes`. The slider's get-side reads
    /// `dragVolume` while a drag is in flight, so visual position
    /// matches the pointer regardless of clamping at 0/100.
    ///
    /// Computes targets against an immutable drag-start snapshot, NOT the
    /// running per-member values. This preserves member offsets when the
    /// master pushes them past 0/100 — clamping doesn't poison the next
    /// tick's math, so dragging back recovers the original spread.
    /// SOAP commit is deferred to drag-end (`commitVolume`).
    func applyMasterVolume(_ newMaster: Double) {
        dragVolume = newMaster
        let snap = dragSnapshot ?? captureDragSnapshot()

        // Master at the extremes is absolute: 0 silences everything, 100
        // drives everything to max. The snapshot is preserved unchanged,
        // so as soon as the master leaves the extreme the original spread
        // recovers via the normal distribution math below.
        let absoluteTarget: Int?
        if newMaster <= 0 { absoluteTarget = 0 }
        else if newMaster >= 100 { absoluteTarget = 100 }
        else { absoluteTarget = nil }

        let proportional = UserDefaults.standard.bool(forKey: UDKey.proportionalGroupVolume)

        for member in group.members {
            let clamped: Int
            if let abs = absoluteTarget {
                clamped = abs
            } else {
                let original = snap.volumes[member.id] ?? snap.master
                let newVol: Double
                if proportional, snap.master > 0 {
                    // Each member keeps its ratio to the snapshot master.
                    // e.g. members at 30,40 (master=35) → master to 70 → 60,80.
                    newVol = original * (newMaster / snap.master)
                } else if proportional {
                    // Snapshot master was 0 — ratio undefined; drive all to newMaster.
                    newVol = newMaster
                } else {
                    // Linear: shift each member by the master delta. Offsets
                    // relative to the snapshot are preserved across the drag.
                    newVol = original + (newMaster - snap.master)
                }
                clamped = Int(max(0, min(100, newVol)))
            }
            sonosManager.updateDeviceVolume(member.id, volume: clamped)
        }
        scheduleThrottledMasterCommit()
    }

    /// Captures the immutable drag-start state — current master baseline
    /// and each member's current volume. Subsequent ticks within the
    /// same drag use this as the reference; the snapshot itself is never
    /// rewritten until `commitVolume` clears it.
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

    /// 250 ms-quiet throttled commit during master drag. Coalesces
    /// rapid drag ticks: each tick cancels the prior pending task and
    /// schedules a fresh one. SOAP only fires after the user pauses
    /// for 250 ms, so a continuous drag produces 0 mid-drag SOAPs;
    /// a slower drag produces ~4/sec, capped by the round-trip time
    /// the speaker can drain anyway. `commitVolume` cancels the
    /// pending task at drag-end and fires the final write itself.
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
        // Cancel any pending throttled mid-drag commit; the final
        // SOAP below is authoritative.
        throttledMasterCommitTask?.cancel()
        throttledMasterCommitTask = nil
        // Per-device SOAPs in parallel — for a group of N speakers a
        // serial loop took N × ~150 ms (the cumulative SOAP round-trip
        // time), which read as sluggish on 3+ speaker groups. TaskGroup
        // fires them concurrently so the whole commit completes in one
        // round-trip instead of N. Reads volumes straight from the
        // manager (the optimistic distribution wrote them there).
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
        // Drag-end final commit. Cancel any pending throttled
        // mid-drag SOAP for this device — this call is
        // authoritative.
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

    /// Schedules a 250 ms-quiet SOAP commit for a single member,
    /// invoked from the per-speaker slider's binding setter on each
    /// drag tick. Same coalescing pattern as
    /// `scheduleThrottledMasterCommit` but per-device — different
    /// members can have independent in-flight throttles when the
    /// user nudges them in turn. Cancelled by `setSpeakerVolume`
    /// (drag-end) so the final SOAP is the authoritative write.
    func scheduleThrottledSpeakerCommit(device: SonosDevice, volume: Int) {
        throttledMemberCommitTasks[device.id]?.cancel()
        throttledMemberCommitTasks[device.id] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.throttleInterval)
            guard !Task.isCancelled, let self else { return }
            do {
                try await self.sonosManager.setVolume(device: device, volume: volume)
            } catch {
                sonosDebugLog("[VOLUME] throttled mid-drag setVolume failed for \(device.roomName): \(error)")
            }
            self.throttledMemberCommitTasks[device.id] = nil
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

    // MARK: - Group lifecycle

    /// Reset transient UI state when switching to a different group.
    /// No volume/mute mirror to clear — those derive directly from
    /// `sonosManager.deviceVolumes` / `deviceMutes` keyed by the new
    /// group's members.
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

    /// Snapshot stringification — for code paths that need a one-shot
    /// value (e.g. accessibility labels). The visible time text is
    /// driven by `TimelineView` in the view layer and formats from
    /// `positionAnchor.projected(at: ctx.date)` directly so the digit
    /// updates each frame instead of once per render.
    var smoothPositionString: String {
        formatTime(currentPosition)
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

        // Reset position on source/track change to avoid stale time display.
        // Bypasses the drift threshold — track change is by definition a
        // hard discontinuity, never noise.
        if uriChanged {
            sonosManager.setPositionAnchor(
                coordinatorID: group.coordinatorID,
                PositionAnchor(time: max(0, metadata.position),
                               wallClock: Date(),
                               isPlaying: transportState.isPlaying)
            )
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
        var artist = TrackMetadata.filterDeviceID(metadata.artist)
        // Radio streams routinely populate the artist field with the
        // station or soundtrack name rather than the actual performer
        // (e.g. station "Movie Ticket Radio" sends artist="Animal House").
        // Searching iTunes with that string poisons the result. When the
        // artist matches the station name verbatim, drop it — the
        // service's title-only and OST-shape strategies are more
        // reliable than an artist+title query against a wrong artist.
        if !metadata.stationName.isEmpty,
           artist.caseInsensitiveCompare(metadata.stationName) == .orderedSame {
            artist = ""
        }
        // For radio streams, keep the full title including parenthetical content
        // since it often contains the movie/album name (e.g. "Tristania (Troia Troy)")
        let searchTitle = metadata.title
        Task {
            if let artURL = await sonosManager.albumArtSearch.searchRadioTrackArt(
                artist: artist, title: searchTitle
            ) {
                sonosDebugLog("[ART/RADIO] resolved \(searchTitle) – \(artist) → \(artURL.prefix(80))")
                art.setRadioTrackArt(URL(string: artURL), forKey: key)
                art.playHistoryManager?.updateArtwork(
                    forTitle: metadata.title, artist: metadata.artist, artURL: artURL
                )
                // Cache so menu bar and other views can find it
                sonosManager.cacheArtURL(artURL, forURI: metadata.trackURI ?? "", title: metadata.title, itemID: "")
            } else {
                sonosDebugLog("[ART/RADIO] no result for \(searchTitle) – \(artist)")
                art.setRadioTrackArt(nil, forKey: key)
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
        // No 1 Hz `Timer` advance any more. Position display is now
        // driven entirely by `TimelineView { ctx in
        //   positionAnchor.projected(at: ctx.date) }` at the view
        // layer — the visible position updates at display refresh
        // (60/120 Hz) rather than in 1 s discrete chunks, eliminating
        // the seek-bar / time-text "pause then jump" rhythm and
        // letting the synced lyrics scroll continuously.
        //
        // Lightweight metadata poll stays — it catches radio track
        // changes that don't trigger UPnP events. The poll updates the
        // anchor through `handleMetadataChanged` (track-change branch)
        // and `updateAnchorFromAuthoritative` (drift branch).
        metadataPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Timing.metadataPolling)
                guard !Task.isCancelled, let self else { return }
                guard let coordinator = group.coordinator else { return }
                do {
                    let position = try await sonosManager.getPositionInfo(group: group)
                    let enriched = await enrichMetadata(position, state: transportState, coordinator: coordinator)
                    handleMetadataChanged(enriched)
                    // Hand the polled position to the manager so the
                    // shared anchor's drift-tolerant rebase runs and
                    // every consumer (panel + karaoke) sees the same
                    // result.
                    sonosManager.transportDidUpdatePosition(
                        group.coordinatorID,
                        position: enriched.position,
                        duration: enriched.duration
                    )
                } catch {
                    sonosDebugLog("[NOW-PLAYING] Metadata poll failed: \(error)")
                }
            }
        }
    }

    func stopProgressTimer() {
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

        // Force-set local state from the just-fetched @Published values.
        // No grace period or threshold checks — this is an explicit
        // user action, so the anchor snaps directly to the freshly
        // fetched position.
        let meta = sonosManager.groupTrackMetadata[group.coordinatorID] ?? TrackMetadata()
        sonosManager.setPositionAnchor(
            coordinatorID: group.coordinatorID,
            PositionAnchor(time: max(0, meta.position),
                           wallClock: Date(),
                           isPlaying: transportState.isPlaying)
        )
        crossfadeOn = (try? await sonosManager.getCrossfadeMode(group: group)) ?? false

        // No local mirror to populate — `volume`, `isMuted`,
        // `speakerVolumes`, and `speakerMutes` derive directly from
        // `sonosManager.deviceVolumes` / `deviceMutes`, which `scanGroup`
        // above just refreshed. Clear any stale drag snapshot so the
        // next user drag captures fresh state.
        dragSnapshot = nil
    }

}
