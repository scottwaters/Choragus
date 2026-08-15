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

    /// Holding the master at 0 for `zeroHoldToSyncDelay` discards the
    /// per-member spread so the group rises together (#74). Cancelled the
    /// moment the master leaves 0.
    private var zeroHoldTask: Task<Void, Never>?

    private static let zeroHoldToSyncDelay: Duration = .seconds(1)

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
            var flattened: [String: Double] = [:]
            for member in self.group.members { flattened[member.id] = 0 }
            self.dragSnapshot = (master: 0, volumes: flattened)
        }
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
        // The drag is over — a pending zero-hold must not fire against a
        // later drag's snapshot.
        zeroHoldTask?.cancel()
        zeroHoldTask = nil
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
    /// Per-device commit generation. A completing throttled task may only
    /// nil its dictionary slot when it is still the latest scheduled task
    /// for that device — an unconditional nil would wipe a NEWER task's
    /// slot (the old task can pass its cancellation check, then get
    /// cancelled mid-SOAP after the newer task has taken the slot).
    private var memberCommitGenerations: [String: Int] = [:]

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

    /// Token for the action that currently owns `actionInFlight`. Only
    /// the call that SET the flag may clear it — after a
    /// `resetForGroupChange` (which nils the flag directly), a still-
    /// running old action's completion must not clear a newer action's
    /// in-flight state.
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
        // Manual drive — speaker switches whose metadata is already
        // cached don't republish, so `.onReceive` wouldn't fire.
        handleMetadataChanged(meta)
        crossfadeOn = (try? await sonosManager.getCrossfadeMode(group: group)) ?? false

        // No local mirror to populate — `volume`, `isMuted`,
        // `speakerVolumes`, and `speakerMutes` derive directly from
        // `sonosManager.deviceVolumes` / `deviceMutes`, which `scanGroup`
        // above just refreshed. Clear any stale drag snapshot so the
        // next user drag captures fresh state — but only when no drag is
        // active NOW: the awaits above are long enough for a drag to have
        // started, and wiping its immutable reference snapshot mid-drag
        // breaks the offset-preserving distribution math.
        if !isDraggingVolume { dragSnapshot = nil }
    }

}
