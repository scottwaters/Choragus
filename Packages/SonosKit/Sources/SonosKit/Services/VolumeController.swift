/// VolumeController.swift — Owns per-device volume and mute: the values, the
/// writes, the echo absorption for the app's own writes, and the verifier
/// fan-outs that reconcile the dictionaries with speaker state.
///
/// Takes `TopologyStore` by injection rather than calling back into the
/// façade for group and device state.
///
/// The expected-echo queues stop the app's own SOAP writes bouncing back as
/// user changes; the debounced verifiers exist because portable speakers
/// report late and bonded sets keep independent mute state; the
/// fixed-line-out set exists because a Connect/Port/Amp answers SetVolume
/// with UPnP 501.
import Foundation

@MainActor
@Observable
public final class VolumeController {

    // MARK: - State

    public private(set) var deviceVolumes: [String: Int] = [:]
    public private(set) var deviceMutes: [String: Bool] = [:]

    /// Devices whose line-out is fixed (Connect/Port/Amp). They reject
    /// SetVolume with UPnP 501, so the UI disables their slider (#50).
    public private(set) var fixedOutputDeviceIDs: Set<String> = []
    @ObservationIgnored private var checkedOutputFixed: Set<String> = []

    @ObservationIgnored private var volumeGraceUntils: [String: Date] = [:]
    @ObservationIgnored private var muteGraceUntils: [String: Date] = [:]

    /// Per-group debounced volume verifier tasks. When the coordinator's
    /// volume event fires, a single GetVolume fan-out for the group's
    /// non-coord members is scheduled ~500 ms later; further coord events
    /// for the same group cancel and reschedule. Bounds wire cost during
    /// slider drag — one GetVolume per member per coalesced action, not
    /// per intermediate slider tick.
    @ObservationIgnored private var groupVolumeVerifyTasks: [String: Task<Void, Never>] = [:]

    /// Per-group debounced mute verifier tasks. After
    /// `propagateMuteOptimistically` flips the dict for instant UI feedback,
    /// a debounced GetMute fan-out corrects members that don't follow the
    /// coordinator's group-mute round-trip — bonded stereo pairs and HT zones
    /// keep independent mute state at the speaker level.
    @ObservationIgnored private var groupMuteVerifyTasks: [String: Task<Void, Never>] = [:]

    /// Per-device debounced verifiers for the app's own outbound writes. Every
    /// `setMute` / `setVolume` schedules one; a second write for the same
    /// device within 500 ms cancels the prior task (drag/multi-tap
    /// coalescing). After the quiet window a real GetMute / GetVolume runs and
    /// reconciles the dict, making the speaker the source of truth even when
    /// it silently rejected the SOAP.
    @ObservationIgnored private var deviceMuteVerifyTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var deviceVolumeVerifyTasks: [String: Task<Void, Never>] = [:]

    /// Value-aware echo absorption for the app's own SOAP writes.
    ///
    /// A time-window approach drops *every* RC NOTIFY for the device during
    /// the grace period, including Sonos-app changes the user makes, which
    /// then flood in at once when the window expires as a delayed flip-flop
    /// cascade.
    ///
    /// Each write enqueues `(value, deadline)` for the target device. An
    /// inbound RC NOTIFY consumes the earliest matching entry FIFO; entries
    /// past their deadline are pruned. Events whose value matches no pending
    /// write — real external changes — flow through immediately.
    @ObservationIgnored private var expectedMuteEchoes: [String: [(value: Bool, deadline: Date)]] = [:]
    @ObservationIgnored private var expectedVolumeEchoes: [String: [(value: Int, deadline: Date)]] = [:]
    @ObservationIgnored private static let echoExpectationWindow: TimeInterval = 5.0
    @ObservationIgnored private static let echoQueueCap = 32

    // MARK: - Collaborators

    @ObservationIgnored private let renderingControl: RenderingControlling
    /// Injected sibling, not a back-reference to the façade.
    @ObservationIgnored private let topology: TopologyStore
    @ObservationIgnored private let publishTag: @MainActor (String) -> Void

    /// Supplies what a group is currently playing, for the portable-speaker
    /// volume=0 diagnostic only. A typed one-method dependency rather than a
    /// `[weak self]` closure: a closure over the façade is a back-reference
    /// with the type erased.
    @ObservationIgnored public weak var nowPlayingContext: NowPlayingContextProviding?

    public init(renderingControl: RenderingControlling,
                topology: TopologyStore,
                publishTag: @escaping @MainActor (String) -> Void = { _ in }) {
        self.renderingControl = renderingControl
        self.topology = topology
        self.publishTag = publishTag
    }

    /// Clears both dictionaries when the transport strategy restarts, so
    /// views re-initialise rather than showing pre-restart values.
    public func reset() {
        deviceVolumes.removeAll()
        deviceMutes.removeAll()
    }

    /// Records an intended volume before the SOAP write lands, so a preset
    /// application shows its target immediately instead of the old value.
    public func setOptimisticVolume(deviceID: String, volume: Int) {
        deviceVolumes[deviceID] = volume
    }

    /// Normalizes a device id to the bare zone-player RINCON UUID used by
    /// topology / `group.members`, stripping the UPnP MediaRenderer (`_MR`)
    /// suffix that RenderingControl events carry — so the fixed-output set keys
    /// consistently regardless of which id space produced the id.
    nonisolated static func bareDeviceID(_ id: String) -> String {
        id.hasSuffix("_MR") ? String(id.dropLast(3)) : id
    }

    /// Only Connect / Port / Amp expose a fixed line-out (and the
    /// `GetOutputFixed` action). Other models (One, Play, soundbars) fault UPnP
    /// 803 "not implemented" — so don't query them.
    private static func hasLineOut(_ modelName: String) -> Bool {
        let m = modelName.lowercased()
        return m.contains("connect") || m.contains("port") || m.contains("amp")
    }

    /// True when the device's line-out is fixed and volume can't be changed.
    public func isOutputFixed(_ deviceID: String) -> Bool {
        fixedOutputDeviceIDs.contains(Self.bareDeviceID(deviceID))
    }

    /// Re-checks the fixed-output status of a specific group's members and
    /// updates `fixedOutputDeviceIDs` BOTH ways. Called when a group is viewed
    /// and on its track changes — the fixed state isn't static (a Connect is
    /// fixed while sourcing line-in but adjustable when playing its own track),
    /// so this must override the one-shot `checkedOutputFixed` cache, removing
    /// topology.devices that are no longer fixed.
    public func ensureFixedOutputChecked(for group: SonosGroup) async {
        for member in group.members {
            let key = Self.bareDeviceID(member.id)
            // Topology members can carry an empty modelName, so resolve the full
            // device record (which has the model + a reliable endpoint) before
            // the line-out gate — otherwise the re-check is skipped and a
            // Fixed→Variable change never clears.
            let d = topology.devices.values.first { Self.bareDeviceID($0.id) == key } ?? member
            guard Self.hasLineOut(d.modelName) else { continue }
            checkedOutputFixed.insert(key)
            let fixed = await renderingControl.getOutputFixed(device: d)
            // Membership check before mutating: `.insert`/`.remove` fire
            // observation even when the set is unchanged, and this runs
            // on the 2 s position poll for every line-out group.
            if fixed {
                if !fixedOutputDeviceIDs.contains(key) {
                    fixedOutputDeviceIDs.insert(key)
                    sonosDebugLog("[VOLUME] \(d.roomName) line-out is fixed — volume control disabled (#50)")
                }
            } else if fixedOutputDeviceIDs.contains(key) {
                fixedOutputDeviceIDs.remove(key)
                sonosDebugLog("[VOLUME] \(d.roomName) line-out no longer fixed — volume control enabled")
            }
        }
    }

    /// Queries `GetOutputFixed` once per line-out device and caches the result.
    /// Restricted to line-out models so non-line-out speakers aren't pinged with
    /// an action they don't implement (UPnP 803 spam).
    public func refreshFixedOutputStatus() async {
        let toCheck = topology.devices.values.filter {
            !checkedOutputFixed.contains(Self.bareDeviceID($0.id)) && Self.hasLineOut($0.modelName)
        }
        for d in toCheck {
            let key = Self.bareDeviceID(d.id)
            checkedOutputFixed.insert(key)
            if await renderingControl.getOutputFixed(device: d) {
                fixedOutputDeviceIDs.insert(key)
                sonosDebugLog("[VOLUME] \(d.roomName) line-out is fixed — volume control disabled (#50)")
            }
        }
    }

    public func setVolumeGrace(deviceID: String, duration: TimeInterval = 5) {
        volumeGraceUntils[deviceID] = Date().addingTimeInterval(duration)
    }

    public func setMuteGrace(deviceID: String, duration: TimeInterval = 5) {
        muteGraceUntils[deviceID] = Date().addingTimeInterval(duration)
    }

    public func isVolumeGraceActive(deviceID: String) -> Bool {
        guard let until = volumeGraceUntils[deviceID] else { return false }
        return Date() < until
    }

    public func isMuteGraceActive(deviceID: String) -> Bool {
        guard let until = muteGraceUntils[deviceID] else { return false }
        return Date() < until
    }

    public func getVolume(device: SonosDevice) async throws -> Int {
        try await renderingControl.getVolume(device: device)
    }

    public func setVolume(device: SonosDevice, volume: Int) async throws {
        // Fixed line-out (Connect/Port/Amp) rejects SetVolume with UPnP 501.
        // Skip the call entirely rather than spam faults.
        if fixedOutputDeviceIDs.contains(Self.bareDeviceID(device.id)) {
            sonosDebugLog("[VOLUME] skip setVolume — \(device.roomName) line-out is fixed (#50)")
            return
        }
        recordExpectedVolumeEcho(deviceID: device.id, value: volume)
        sonosDebugLog("[RC-SOAP-WRITE] setVolume room=\(device.roomName) id=\(device.id) → \(volume)")
        // Portable speakers (Move/Roam) on Bluetooth input accept SetVolume
        // at the RenderingControl service while the audio pipeline ignores
        // it — the next GetVolume event reads back 0. Capture model + group
        // context at
        // the point of intent so a bug bundle holds both the SET attempt
        // and the subsequent rejection (logged in `updateDeviceVolume`).
        if device.isPortable {
            let groupCoord = topology.groups.first(where: { g in g.members.contains(where: { $0.id == device.id }) })?.coordinatorID ?? "?"
            sonosDiagLog(.info, tag: "PORTABLE_VOL",
                         "setVolume on portable \(device.modelName) → \(volume) (room=\(device.roomName))",
                         context: [
                            "deviceID": device.id,
                            "model": device.modelName,
                            "modelNumber": device.modelNumber,
                            "desiredVolume": String(volume),
                            "groupCoordinator": groupCoord
                         ])
        }
        do {
            try await renderingControl.setVolume(device: device, volume: volume)
        } catch {
            // A fixed line-out reports its lock late via UPnP 501. Treat as
            // benign, remember it (slider disables, no further attempts), and
            // don't surface a user-facing error.
            if case SOAPError.soapFault(let code, _) = error, code == "501" {
                fixedOutputDeviceIDs.insert(Self.bareDeviceID(device.id))
                checkedOutputFixed.insert(Self.bareDeviceID(device.id))
                sonosDiagLog(.info, tag: "VOLUME",
                             "SetVolume rejected (501) — \(device.roomName) line-out fixed; disabling control (#50)",
                             context: ["deviceID": device.id])
                return
            }
            throw error
        }
        scheduleDeviceVolumeVerify(device: device)
    }

    public func getMute(device: SonosDevice) async throws -> Bool {
        try await renderingControl.getMute(device: device)
    }

    public func setMute(device: SonosDevice, muted: Bool) async throws {
        recordExpectedMuteEcho(deviceID: device.id, value: muted)
        sonosDebugLog("[RC-SOAP-WRITE] setMute room=\(device.roomName) id=\(device.id) → \(muted)")
        try await renderingControl.setMute(device: device, muted: muted)
        scheduleDeviceMuteVerify(device: device)
    }

    private func recordExpectedMuteEcho(deviceID: String, value: Bool) {
        let now = Date()
        var list = expectedMuteEchoes[deviceID] ?? []
        list = list.filter { $0.deadline > now }
        list.append((value, now.addingTimeInterval(Self.echoExpectationWindow)))
        if list.count > Self.echoQueueCap { list = Array(list.suffix(Self.echoQueueCap)) }
        expectedMuteEchoes[deviceID] = list
    }

    private func recordExpectedVolumeEcho(deviceID: String, value: Int) {
        let now = Date()
        var list = expectedVolumeEchoes[deviceID] ?? []
        list = list.filter { $0.deadline > now }
        list.append((value, now.addingTimeInterval(Self.echoExpectationWindow)))
        if list.count > Self.echoQueueCap { list = Array(list.suffix(Self.echoQueueCap)) }
        expectedVolumeEchoes[deviceID] = list
    }

    /// Returns true and consumes the earliest matching pending write if
    /// the inbound mute event matches one the app issued. Returns false if no
    /// match — caller treats the event as an external state change.
    private func consumeExpectedMuteEcho(deviceID: String, value: Bool) -> Bool {
        let now = Date()
        guard var list = expectedMuteEchoes[deviceID] else { return false }
        list = list.filter { $0.deadline > now }
        if let idx = list.firstIndex(where: { $0.value == value }) {
            list.remove(at: idx)
            expectedMuteEchoes[deviceID] = list.isEmpty ? nil : list
            return true
        }
        expectedMuteEchoes[deviceID] = list.isEmpty ? nil : list
        return false
    }

    private func consumeExpectedVolumeEcho(deviceID: String, value: Int) -> Bool {
        let now = Date()
        guard var list = expectedVolumeEchoes[deviceID] else { return false }
        list = list.filter { $0.deadline > now }
        if let idx = list.firstIndex(where: { $0.value == value }) {
            list.remove(at: idx)
            expectedVolumeEchoes[deviceID] = list.isEmpty ? nil : list
            return true
        }
        expectedVolumeEchoes[deviceID] = list.isEmpty ? nil : list
        return false
    }

    public func applyObservedVolume(_ deviceID: String, volume: Int) {
        let prior = deviceVolumes[deviceID]
        let echoMatched = consumeExpectedVolumeEcho(deviceID: deviceID, value: volume)
        let isNoOp = !echoMatched && prior == volume
        let isCoord = topology.isCoordinator(deviceID: deviceID)
        // Suppress logs for the steady-state no-op case — every
        // device's volume is republished on every poll cycle, and
        // logging "value=X prior=X" pairs costs ~50 string formats /
        // sec on the main thread. Only log when something changed or
        // an echo was matched.
        if !isNoOp {
            let room = topology.devices[deviceID]?.roomName ?? deviceID
            sonosDebugLog("[RC-EVENT] vol room=\(room) id=\(deviceID) coord=\(isCoord) value=\(volume) prior=\(prior.map(String.init) ?? "nil") echoMatched=\(echoMatched)")
        }
        if echoMatched {
            if !isNoOp {
                let room = topology.devices[deviceID]?.roomName ?? deviceID
                sonosDebugLog("[RC-WRITE] vol DROP-ECHO room=\(room) value=\(volume)")
            }
            return
        }
        let changed = deviceVolumes[deviceID] != volume
        if changed {
            let room = topology.devices[deviceID]?.roomName ?? deviceID
            publishTag("vol")
            deviceVolumes[deviceID] = volume
            sonosDebugLog("[RC-WRITE] vol APPLY room=\(room) value=\(volume) changed=true")
            // A device set to Fixed line-out jumps to (and pins at) volume 100.
            // Treat a change TO 100 on a line-out model as a trigger to verify
            // GetOutputFixed immediately, so "Fixed Volume" appears without
            // waiting for the user to drag the slider.
            if volume == 100, let dev = topology.devices[deviceID], Self.hasLineOut(dev.modelName),
               !fixedOutputDeviceIDs.contains(Self.bareDeviceID(deviceID)) {
                Task { [weak self] in
                    guard let self else { return }
                    if await self.renderingControl.getOutputFixed(device: dev) {
                        self.fixedOutputDeviceIDs.insert(Self.bareDeviceID(deviceID))
                        self.checkedOutputFixed.insert(Self.bareDeviceID(deviceID))
                        sonosDebugLog("[VOLUME] \(dev.roomName) line-out fixed (vol=100 trigger) — control disabled (#50)")
                    }
                }
            }
        }
        // Group-volume propagation: when a coordinator's volume changes,
        // the Sonos cluster sets per-member volumes at proportional values,
        // but member-level RenderingControl NOTIFY arrives slowly on
        // portable speakers (FP5/Roam: several seconds). A debounced
        // single-shot GetVolume fan-out across the group's other members
        // closes the gap without flooding the wire — the verifier is
        // cancelled and re-scheduled on every coord event during slider
        // drag, so only one fan-out runs per coalesced volume action.
        if changed, isCoord {
            scheduleGroupVolumeVerifier(coordinatorID: deviceID)
        }
    }

    public func applyObservedMute(_ deviceID: String, muted: Bool) {
        let prior = deviceMutes[deviceID]
        let echoMatched = consumeExpectedMuteEcho(deviceID: deviceID, value: muted)
        let isNoOp = !echoMatched && prior == muted
        let isCoord = topology.isCoordinator(deviceID: deviceID)
        // Same no-op suppression as the volume path — see comment
        // there. Mute polling republishes per device per cycle.
        if !isNoOp {
            let room = topology.devices[deviceID]?.roomName ?? deviceID
            sonosDebugLog("[RC-EVENT] mute room=\(room) id=\(deviceID) coord=\(isCoord) value=\(muted) prior=\(prior.map(String.init) ?? "nil") echoMatched=\(echoMatched)")
        }
        if echoMatched {
            if !isNoOp {
                let room = topology.devices[deviceID]?.roomName ?? deviceID
                sonosDebugLog("[RC-WRITE] mute DROP-ECHO room=\(room) value=\(muted)")
            }
            return
        }
        let changed = deviceMutes[deviceID] != muted
        if changed {
            let room = topology.devices[deviceID]?.roomName ?? deviceID
            publishTag("mute")
            deviceMutes[deviceID] = muted
            sonosDebugLog("[RC-WRITE] mute APPLY room=\(room) value=\(muted) changed=true")
        }
        // Optimistic group propagation: when the *coordinator's* mute
        // event arrives, mirror to all other members on the assumption it
        // was a group-level operation. Coordinator events are consistently
        // fast and reliable across all hardware.
        //
        // Member events do NOT trigger propagation. Portable speakers
        // (Float, Roam) emit their RenderingControl NOTIFY several seconds
        // after the change; a stale member event used as a group trigger
        // flips the coordinator's freshly-correct mute state, so every
        // quick mute/unmute in the Sonos app inverts both speakers here.
        //
        // No verifying SOAP poll runs after propagation. Polling members
        // immediately races the Sonos cluster's own internal sync (1–10 s
        // on Float/Roam) and reverts correct optimistic updates with stale
        // `false` reads. Late member events are no-ops if they match; the
        // 15 s reconciliation poll catches persistent drift.
        if changed, topology.isCoordinator(deviceID: deviceID) {
            propagateMuteOptimistically(triggerDeviceID: deviceID, muted: muted)
            // Bonded stereo pairs and HT zones don't follow the coordinator's
            // group-mute round-trip — their hardware mute state stays
            // independent, so the optimistic propagation above leaves the
            // dict desynced for them. Schedule a debounced GetMute fan-out
            // to reconcile.
            scheduleGroupMuteVerifier(coordinatorID: deviceID)
        }
    }

    /// Mirrors a coordinator's mute change to every other member of its
    /// group, skipping members whose `muteGraceUntils` is currently
    /// active (those are echoes of the app's own writes). Doesn't touch
    /// the trigger device itself — `transportDidUpdateMute` already did.
    private func propagateMuteOptimistically(triggerDeviceID: String, muted: Bool) {
        guard let group = topology.groups.first(where: { $0.coordinatorID == triggerDeviceID })
        else {
            sonosDebugLog("[RC-PROP] mute SKIP no-coord-group trigger=\(triggerDeviceID)")
            return
        }
        let triggerRoom = topology.devices[triggerDeviceID]?.roomName ?? triggerDeviceID
        let memberCount = group.members.count - 1
        sonosDebugLog("[RC-PROP] mute START coord=\(triggerRoom) groupID=\(group.id) others=\(memberCount) value=\(muted)")
        for member in group.members where member.id != triggerDeviceID {
            let memberRoom = member.roomName
            if deviceMutes[member.id] != muted {
                deviceMutes[member.id] = muted
                sonosDebugLog("[RC-PROP] mute APPLIED member=\(memberRoom) → \(muted)")
            } else {
                sonosDebugLog("[RC-PROP] mute NO-OP member=\(memberRoom) already=\(muted)")
            }
        }
    }

    /// Debounced fan-out poll of non-coordinator member volumes. Cancels
    /// any pending verifier for the same group on each call so a slider
    /// drag (many coord volume events in quick succession) coalesces to
    /// one fan-out ~500 ms after the user releases.
    private func scheduleGroupVolumeVerifier(coordinatorID: String) {
        guard let group = topology.groups.first(where: { $0.coordinatorID == coordinatorID })
        else {
            sonosDebugLog("[RC-VERIFY] vol SKIP no-coord-group trigger=\(coordinatorID)")
            return
        }
        let others = group.members.filter { $0.id != coordinatorID }
        guard !others.isEmpty else {
            sonosDebugLog("[RC-VERIFY] vol SKIP solo-coord group=\(group.id)")
            return
        }
        let coordRoom = topology.devices[coordinatorID]?.roomName ?? coordinatorID
        let cancelled = groupVolumeVerifyTasks[group.id] != nil
        groupVolumeVerifyTasks[group.id]?.cancel()
        sonosDebugLog("[RC-VERIFY] vol SCHED coord=\(coordRoom) groupID=\(group.id) others=\(others.count) replaced=\(cancelled)")
        groupVolumeVerifyTasks[group.id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled {
                sonosDebugLog("[RC-VERIFY] vol CANCELLED coord=\(coordRoom)")
                return
            }
            guard let self else { return }
            sonosDebugLog("[RC-VERIFY] vol FIRE coord=\(coordRoom) groupID=\(group.id)")
            await withTaskGroup(of: Void.self) { tg in
                for member in others {
                    tg.addTask { [weak self] in
                        guard let self else { return }
                        do {
                            let val = try await self.renderingControl.getVolume(device: member)
                            await MainActor.run {
                                // Polled value is authoritative speaker state. If
                                // it matches a pending Choragus write for this
                                // member, consume the expected echo so the
                                // matching NOTIFY (when it arrives) doesn't
                                // double-apply.
                                _ = self.consumeExpectedVolumeEcho(deviceID: member.id, value: val)
                                if self.deviceVolumes[member.id] != val {
                                    let prior = self.deviceVolumes[member.id].map(String.init) ?? "nil"
                                    self.deviceVolumes[member.id] = val
                                    sonosDebugLog("[RC-VERIFY] vol APPLY member=\(member.roomName) prior=\(prior) → \(val)")
                                } else {
                                    sonosDebugLog("[RC-VERIFY] vol NO-OP member=\(member.roomName) already=\(val)")
                                }
                            }
                        } catch {
                            sonosDebugLog("[RC-VERIFY] vol FAIL member=\(member.roomName) error=\(error)")
                        }
                    }
                }
            }
        }
    }

    /// Debounced fan-out poll of non-coordinator member mute state.
    /// Mirrors `scheduleGroupVolumeVerifier`: cancels any pending verifier
    /// for the same group on each call so a rapid mute/unmute toggle
    /// coalesces to one fan-out ~500 ms after the last coord event.
    /// Polled values are authoritative speaker state and override the
    /// optimistic propagation written by `propagateMuteOptimistically`.
    private func scheduleGroupMuteVerifier(coordinatorID: String) {
        guard let group = topology.groups.first(where: { $0.coordinatorID == coordinatorID })
        else {
            sonosDebugLog("[RC-VERIFY] mute SKIP no-coord-group trigger=\(coordinatorID)")
            return
        }
        let others = group.members.filter { $0.id != coordinatorID }
        guard !others.isEmpty else {
            sonosDebugLog("[RC-VERIFY] mute SKIP solo-coord group=\(group.id)")
            return
        }
        let coordRoom = topology.devices[coordinatorID]?.roomName ?? coordinatorID
        let cancelled = groupMuteVerifyTasks[group.id] != nil
        groupMuteVerifyTasks[group.id]?.cancel()
        sonosDebugLog("[RC-VERIFY] mute SCHED coord=\(coordRoom) groupID=\(group.id) others=\(others.count) replaced=\(cancelled)")
        groupMuteVerifyTasks[group.id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled {
                sonosDebugLog("[RC-VERIFY] mute CANCELLED coord=\(coordRoom)")
                return
            }
            guard let self else { return }
            sonosDebugLog("[RC-VERIFY] mute FIRE coord=\(coordRoom) groupID=\(group.id)")
            await withTaskGroup(of: Void.self) { tg in
                for member in others {
                    tg.addTask { [weak self] in
                        guard let self else { return }
                        do {
                            let val = try await self.renderingControl.getMute(device: member)
                            await MainActor.run {
                                // Polled value is authoritative speaker state.
                                // Consume any pending Choragus-write echo so
                                // the matching NOTIFY (when it arrives)
                                // doesn't double-apply.
                                _ = self.consumeExpectedMuteEcho(deviceID: member.id, value: val)
                                if self.deviceMutes[member.id] != val {
                                    let prior = self.deviceMutes[member.id].map(String.init) ?? "nil"
                                    self.deviceMutes[member.id] = val
                                    sonosDebugLog("[RC-VERIFY] mute APPLY member=\(member.roomName) prior=\(prior) → \(val)")
                                } else {
                                    sonosDebugLog("[RC-VERIFY] mute NO-OP member=\(member.roomName) already=\(val)")
                                }
                            }
                        } catch {
                            sonosDebugLog("[RC-VERIFY] mute FAIL member=\(member.roomName) error=\(error)")
                        }
                    }
                }
            }
        }
    }

    /// Per-device debounced GetMute reconciliation, scheduled by `setMute`.
    /// Speaker-as-source-of-truth: after SetMute fires, schedule a real
    /// GetMute 500 ms later and overwrite the dict with the actual hardware
    /// state. Catches bonded-set members that silently ignore SetMute. Cancel
    /// and reschedule on every successive setMute for the same device, so a
    /// rapid mute/unmute toggle coalesces to one verify after the user stops.
    private func scheduleDeviceMuteVerify(device: SonosDevice) {
        deviceMuteVerifyTasks[device.id]?.cancel()
        deviceMuteVerifyTasks[device.id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            guard let self else { return }
            do {
                let val = try await self.renderingControl.getMute(device: device)
                await MainActor.run {
                    _ = self.consumeExpectedMuteEcho(deviceID: device.id, value: val)
                    if self.deviceMutes[device.id] != val {
                        let prior = self.deviceMutes[device.id].map(String.init) ?? "nil"
                        self.deviceMutes[device.id] = val
                        sonosDebugLog("[RC-VERIFY] mute APPLY device=\(device.roomName) prior=\(prior) → \(val)")
                    } else {
                        sonosDebugLog("[RC-VERIFY] mute NO-OP device=\(device.roomName) already=\(val)")
                    }
                    self.deviceMuteVerifyTasks[device.id] = nil
                }
            } catch {
                sonosDebugLog("[RC-VERIFY] mute FAIL device=\(device.roomName) error=\(error)")
                await MainActor.run { self.deviceMuteVerifyTasks[device.id] = nil }
            }
        }
    }

    /// Mirror of `scheduleDeviceMuteVerify` for SetVolume. Same coalescing
    /// pattern; same source-of-truth contract.
    private func scheduleDeviceVolumeVerify(device: SonosDevice) {
        deviceVolumeVerifyTasks[device.id]?.cancel()
        deviceVolumeVerifyTasks[device.id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            guard let self else { return }
            do {
                let val = try await self.renderingControl.getVolume(device: device)
                await MainActor.run {
                    _ = self.consumeExpectedVolumeEcho(deviceID: device.id, value: val)
                    if self.deviceVolumes[device.id] != val {
                        let prior = self.deviceVolumes[device.id].map(String.init) ?? "nil"
                        self.deviceVolumes[device.id] = val
                        sonosDebugLog("[RC-VERIFY] vol APPLY device=\(device.roomName) prior=\(prior) → \(val)")
                    } else {
                        sonosDebugLog("[RC-VERIFY] vol NO-OP device=\(device.roomName) already=\(val)")
                    }
                    self.deviceVolumeVerifyTasks[device.id] = nil
                }
            } catch {
                sonosDebugLog("[RC-VERIFY] vol FAIL device=\(device.roomName) error=\(error)")
                await MainActor.run { self.deviceVolumeVerifyTasks[device.id] = nil }
            }
        }
    }

    public func updateDeviceVolume(_ deviceID: String, volume: Int) {
        // Portable-speaker volume diagnostic. When a Move/Roam reports
        // volume=0, capture model + transport URI + group state to
        // confirm whether the speaker is on Bluetooth input (the audio
        // pipeline ignores WiFi-side RenderingControl in that mode).
        // Fires before the equality gate so a sustained "always 0"
        // condition still leaves one entry in the diag log per group
        // state change. Gated to portables to avoid drowning the log in
        // legitimate user-muted=0 reads from regular speakers.
        if volume == 0,
           let device = topology.devices[deviceID],
           device.isPortable {
            let group = topology.groups.first(where: { g in g.members.contains(where: { $0.id == deviceID }) })
            let coord = group?.coordinatorID ?? "?"
            let context = group.flatMap { nowPlayingContext?.nowPlayingContext(forCoordinator: $0.coordinatorID) }
            let trackURI = context?.trackURI ?? "?"
            let transport = context?.state ?? "?"
            sonosDiagLog(.info, tag: "PORTABLE_VOL",
                         "Portable \(device.modelName) reports volume=0 (room=\(device.roomName))",
                         context: [
                            "deviceID": deviceID,
                            "model": device.modelName,
                            "modelNumber": device.modelNumber,
                            "groupCoordinator": coord,
                            "trackURI": trackURI,
                            "transportState": transport,
                            "groupMemberCount": String(group?.members.count ?? 0)
                         ])
        }
        // Equality gate — `scanGroup()` calls this for every member of
        // every group after every topology refresh, and the value is
        // typically unchanged from the prior poll. Without the guard,
        // 10 speakers refreshing each emit 10+ publishes/sec of
        // identical-value writes that flood the karaoke window's
        // invalidation queue.
        if deviceVolumes[deviceID] != volume {
            publishTag("vol")
            deviceVolumes[deviceID] = volume
        }
    }

    public func updateDeviceMute(_ deviceID: String, muted: Bool) {
        if deviceMutes[deviceID] != muted {
            publishTag("mute")
            deviceMutes[deviceID] = muted
        }
    }
}
