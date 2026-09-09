/// TransportStrategy.swift — Protocol and implementations for state update strategies.
///
/// Defines the abstraction for how the app receives state updates from Sonos speakers.
/// Two implementations:
/// - HybridEventFirstTransport: UPnP event subscriptions with targeted polling fallback
/// - LegacyPollingTransport: Original 2-second polling loop (preserved for fallback)
///
/// Both strategies update state through a delegate callback to SonosManager.
import Foundation

/// Where a track-metadata update came from. UPnP events reflect the
/// speaker's latest state; a reconciliation poll's response can land
/// seconds after the request, after a Prev/Next has already moved on.
/// SonosManager uses this tag to drop poll responses that disagree
/// with a still-recent event.
public enum TrackMetadataSource: Sendable {
    case event
    case poll
}

// MARK: - Protocol

/// Main-actor isolated: strategy implementations hold mutable state
/// (current groups/devices, SID maps, liveness sets) that concurrent
/// topology refreshes would otherwise corrupt. Isolation serializes
/// all state access; network awaits still run off-actor.
@MainActor
public protocol TransportStrategy: AnyObject {
    func start(groups: [SonosGroup], devices: [String: SonosDevice]) async
    func stop() async
    func onGroupsChanged(_ groups: [SonosGroup], devices: [String: SonosDevice]) async
    /// Rebuild any network-bound state (e.g. UPnP event SUBSCRIBE
    /// callback URLs) after the host's network path changed. Default
    /// empty — only event-driven strategies need to rebind.
    func restartForNetworkChange() async
    var delegate: TransportStrategyDelegate? { get set }
}

public extension TransportStrategy {
    func restartForNetworkChange() async {}
}

@MainActor
public protocol TransportStrategyDelegate: AnyObject {
    func transportDidUpdateState(_ groupID: String, state: TransportState)
    func transportDidUpdateTrackMetadata(_ groupID: String, metadata: TrackMetadata, source: TrackMetadataSource)
    func transportDidUpdatePlayMode(_ groupID: String, mode: PlayMode)
    /// The commands the coordinator currently accepts (skip / seek / …).
    /// Sonos publishes `CurrentTransportActions` on every AVTransport
    /// LastChange, so the delegate can gate its transport UI on what the
    /// speaker actually allows rather than on a URI-scheme guess.
    func transportDidUpdateTransportActions(_ groupID: String, actions: TransportActions)
    func transportDidUpdateVolume(_ deviceID: String, volume: Int)
    func transportDidUpdateMute(_ deviceID: String, muted: Bool)
    func transportDidUpdateTopology(_ groups: [ZoneGroupData])
    func transportDidUpdatePosition(_ groupID: String, position: TimeInterval, duration: TimeInterval)
    /// Fired when a `ZoneGroupTopology` UPnP NOTIFY arrives. The
    /// delegate should re-fetch authoritative topology via
    /// `GetZoneGroupState`. The event payload is not parsed — its
    /// triple-encoded XML yields unreliable group data — so it is a
    /// "something changed" trigger only. `originDeviceID` is the speaker
    /// that fired the event; refreshing from that speaker avoids the
    /// propagation flap seen when a sibling has not yet caught up.
    func transportRequestsTopologyRefresh(originDeviceID: String)
    /// Fired when a `ContentDirectory` NOTIFY reports that the current
    /// playback queue (`Q:0`) for `groupID` changed. The delegate
    /// should reload the queue (typically by posting `.queueChanged`
    /// so `QueueView` does its `Browse(Q:0)` round-trip). The event
    /// only signals "queue mutated" — it does not carry the new items.
    func transportDidObserveQueueChange(_ groupID: String)
    // Services for direct queries
    func getAVTransportService() -> AVTransportService
    func getRenderingControlService() -> RenderingControlService
    func getZoneGroupTopologyService() -> ZoneGroupTopologyService
}

// MARK: - Hybrid Event-First Transport

public final class HybridEventFirstTransport: TransportStrategy {
    public weak var delegate: TransportStrategyDelegate?

    private var eventListener: EventListener?
    private var subscriptionManager: EventSubscriptionManager?
    private var positionPollingTask: Task<Void, Never>?
    private var reconciliationTask: Task<Void, Never>?
    private var currentGroups: [SonosGroup] = []
    private var currentDevices: [String: SonosDevice] = [:]
    private var isRunning = false

    // Liveness cache: skip the SUBSCRIBE attempt for devices
    // that don't respond to a quick `device_description.xml` probe.
    // Stale cached speakers (different network / decommissioned /
    // powered off) would otherwise burn ~10 s timeout each on the
    // SUBSCRIBE call AND register a callback the device will never
    // honour. Probed once per (re)start; refreshed by
    // `restartForNetworkChange()` because that calls stop()+start().
    private var liveDeviceIDs: Set<String> = []

    // Network-change rebuild coalescing — see `restartForNetworkChange`.
    private var isRebuildingForNetworkChange = false
    private var networkRebuildPending = false
    /// Bumped by every start()/stop(). A start() that finds the
    /// generation changed after its awaits has been superseded and must
    /// not install its renewal loop (the orphaned-loop failure mode).
    private var lifecycleGeneration = 0
    /// SUBSCRIBE calls currently in flight, keyed `deviceID|service`.
    /// The SID map only records a subscription AFTER its network
    /// round-trip, so overlapping `onGroupsChanged` passes both saw
    /// "not subscribed" and double-subscribed the same coordinator.
    private var subscribesInFlight: Set<String> = []
    /// Consecutive failed liveness probes per device. A device must miss two
    /// probes in a row before it's dropped from `liveDeviceIDs` — a single
    /// 2.5 s timeout under network contention must not sever a working
    /// subscription and push that device onto slow polling.
    private var consecutiveProbeMisses: [String: Int] = [:]
    private static let livenessProbeTimeout: TimeInterval = 2.5

    // Track which service paths map to which device/group for routing events
    private var sidToDevice: [String: String] = [:]   // SID → deviceID
    private var sidToService: [String: String] = [:]  // SID → service type
    private let sidLock = NSLock()

    private func setSID(_ sid: String, device: String, service: String) {
        sidLock.lock()
        defer { sidLock.unlock() }
        sidToDevice[sid] = device
        sidToService[sid] = service
    }

    private func removeSID(_ sid: String) {
        sidLock.lock()
        defer { sidLock.unlock() }
        sidToDevice.removeValue(forKey: sid)
        sidToService.removeValue(forKey: sid)
    }

    private func lookupSID(_ sid: String) -> (deviceID: String, service: String)? {
        sidLock.lock()
        defer { sidLock.unlock() }
        guard let device = sidToDevice[sid], let service = sidToService[sid] else { return nil }
        return (device, service)
    }

    private func snapshotSIDs() -> (devices: [String: String], services: [String: String]) {
        sidLock.lock()
        defer { sidLock.unlock() }
        return (sidToDevice, sidToService)
    }

    private func clearAllSIDs() {
        sidLock.lock()
        defer { sidLock.unlock() }
        sidToDevice.removeAll()
        sidToService.removeAll()
    }

    // Service paths
    private static let avTransportPath = "/MediaRenderer/AVTransport/Control"
    private static let renderingControlPath = "/MediaRenderer/RenderingControl/Control"
    private static let topologyPath = "/ZoneGroupTopology/Control"
    // Each Sonos device exposes a `ContentDirectory:1` instance under
    // `/MediaServer/...`. Subscribing signals when `Q:0` (the active
    // queue), `SQ:` (saved queues / Sonos playlists), and library
    // sub-containers mutate — i.e. when the Sonos app, a voice command,
    // or another client edits the queue.
    private static let contentDirectoryPath = "/MediaServer/ContentDirectory/Control"

    public init() {}

    public func start(groups: [SonosGroup], devices: [String: SonosDevice]) async {
        guard !isRunning else { return }
        isRunning = true
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        currentGroups = groups
        currentDevices = devices

        // Start event listener and subscriptions (best-effort — reconciliation is the safety net)
        let listener = EventListener()
        // Handler installed BEFORE the socket binds: the callback port is
        // stable across launches, so a speaker holding an orphaned
        // prior-session subscription can NOTIFY the instant the bind
        // completes; assigning the closure afterwards races that delivery.
        listener.onEvent = { [weak self] sid, seq, body in
            Task { @MainActor [weak self] in
                self?.handleEvent(sid: sid, seq: seq, body: body)
            }
        }
        // Restrict event delivery to discovered speakers. Set before
        // the socket binds, so a peer cannot slip an event in during startup.
        listener.setAllowedPeers(Set(devices.values.map { $0.ip }))
        do {
            try listener.start()
            if let callbackURL = listener.callbackURL {
                self.eventListener = listener
                let subManager = EventSubscriptionManager(callbackURL: callbackURL)
                self.subscriptionManager = subManager

                await subscribeToAll(groups: groups, devices: devices)

                // A stop()/restart that interleaved with the awaits above
                // has superseded this start — installing the renewal loop
                // now would orphan it forever (nothing stops a loop whose
                // manager was already discarded). Tear down and yield to
                // the newer lifecycle.
                guard lifecycleGeneration == generation else {
                    sonosDebugLog("[TRANSPORT] start() superseded mid-flight (gen \(generation) -> \(lifecycleGeneration)) — tearing down stale listener")
                    listener.stop()
                    await subManager.unsubscribeAll()
                    return
                }
                subManager.startRenewalLoop { [weak self] expiredSub in
                    Task { [weak self] in
                        await self?.resubscribe(expiredSub)
                    }
                }
            } else {
                listener.stop()
            }
        } catch {
            sonosDebugLog("[TRANSPORT] Event listener failed, running in poll-only mode: \(error)")
        }

        // Always start reconciliation polling (safety net + position updates)
        startReconciliationPolling()

        // Always do an initial state fetch
        await fetchInitialState(groups: groups)
    }

    public func stop() async {
        isRunning = false
        lifecycleGeneration += 1
        positionPollingTask?.cancel()
        positionPollingTask = nil
        reconciliationTask?.cancel()
        reconciliationTask = nil

        if let subManager = subscriptionManager {
            await subManager.unsubscribeAll()
        }
        subscriptionManager = nil

        // Waits for the socket to release: the network-change rebuild calls
        // start() immediately after this, and an unreleased fixed port sends
        // the new listener to an ephemeral one that VLAN firewall rules
        // do not cover.
        await eventListener?.stopAndWait()
        eventListener = nil

        clearAllSIDs()
    }

    public func restartForNetworkChange() async {
        guard isRunning else { return }
        // Coalesce bursts. Path changes arrive in quick succession while
        // an interface settles; a second rebuild entering mid-subscribe
        // would cancel the first's in-flight SUBSCRIBEs. One rebuild runs
        // at a time; changes arriving during it fold into one trailing re-run.
        if isRebuildingForNetworkChange {
            networkRebuildPending = true
            return
        }
        isRebuildingForNetworkChange = true
        defer { isRebuildingForNetworkChange = false }
        repeat {
            networkRebuildPending = false
            let groups = currentGroups
            let devices = currentDevices
            sonosDebugLog("[TRANSPORT] Network path changed — rebuilding event subscriptions (\(groups.count) groups, \(devices.count) devices)")
            await stop()
            await start(groups: groups, devices: devices)
        } while networkRebuildPending
    }

    public func onGroupsChanged(_ groups: [SonosGroup], devices: [String: SonosDevice]) async {
        // Snapshot the OLD membership before mutating `currentGroups`;
        // computing it afterwards leaves `removedDevices` empty and leaks
        // subscriptions (and SID mappings) to departed devices.
        let oldGroupIDs = Set(currentGroups.map(\.id))
        let oldDeviceIDs = Set(currentGroups.flatMap(\.members).map(\.id))
        currentGroups = groups
        currentDevices = devices
        // Keep the listener's accepted-peer set in step with discovery: a
        // speaker added to the household must be able to deliver events, and
        // one that has left should stop being accepted.
        eventListener?.setAllowedPeers(Set(devices.values.map { $0.ip }))

        // Unsubscribe from devices no longer in any group
        let newDeviceIDs = Set(groups.flatMap(\.members).map(\.id))
        let removedDevices = oldDeviceIDs.subtracting(newDeviceIDs)

        if let subManager = subscriptionManager {
            for deviceID in removedDevices {
                for sub in subManager.subscriptions(for: deviceID) {
                    await subManager.unsubscribe(sub)
                    removeSID(sub.sid)
                }
            }
        }

        // Subscribe to new groups/devices
        await subscribeToAll(groups: groups, devices: devices)

        // Fetch initial state for new groups
        let newGroups = groups.filter { !oldGroupIDs.contains($0.id) }
        if !newGroups.isEmpty {
            await fetchInitialState(groups: newGroups)
        }
    }

    // MARK: - Subscription Management

    private func subscribeToAll(groups: [SonosGroup], devices: [String: SonosDevice]) async {
        guard let subManager = subscriptionManager else { return }

        await probeLiveness(devices: devices)

        // Take thread-safe snapshots
        let (deviceSnapshot, serviceSnapshot) = snapshotSIDs()

        // Subscribe to ZoneGroupTopology once per household. A topology
        // subscription only reports the household of the device it is made
        // against, so one subscription per household is required.
        let coveredHouseholds = Set(serviceSnapshot.compactMap { sid, service -> String? in
            guard service == "topology", let deviceID = deviceSnapshot[sid] else { return nil }
            let device = devices[deviceID] ?? currentDevices[deviceID]
            return device?.householdID ?? deviceID
        })
        var topologyCandidates: [String: SonosDevice] = [:]
        for group in groups {
            guard let coordinator = group.coordinator else { continue }
            let household = coordinator.householdID ?? coordinator.id
            guard !coveredHouseholds.contains(household) else { continue }
            // Keep an already-chosen live candidate; otherwise take this
            // one (a later live coordinator replaces a dead earlier pick).
            if let existing = topologyCandidates[household], liveDeviceIDs.contains(existing.id) { continue }
            topologyCandidates[household] = coordinator
        }
        for device in topologyCandidates.values {
            await subscribeToService(device: device, path: Self.topologyPath, serviceType: "topology", manager: subManager)
        }

        // Subscribe to AVTransport on each coordinator
        for group in groups {
            guard let coordinator = group.coordinator else { continue }
            let alreadySubscribed = deviceSnapshot.contains(where: { $0.value == coordinator.id && serviceSnapshot[$0.key] == "avTransport" })
            if !alreadySubscribed {
                await subscribeToService(device: coordinator, path: Self.avTransportPath, serviceType: "avTransport", manager: subManager)
            }
        }

        // Subscribe to ContentDirectory on each coordinator. The queue
        // (`Q:0`) lives on the coordinator, not on grouped members, so
        // one subscription per group is sufficient.
        for group in groups {
            guard let coordinator = group.coordinator else { continue }
            let alreadySubscribed = deviceSnapshot.contains(where: { $0.value == coordinator.id && serviceSnapshot[$0.key] == "contentDirectory" })
            if !alreadySubscribed {
                await subscribeToService(device: coordinator, path: Self.contentDirectoryPath, serviceType: "contentDirectory", manager: subManager)
            }
        }

        // Subscribe to RenderingControl on each visible speaker
        for group in groups {
            for member in group.members {
                let alreadySubscribed = deviceSnapshot.contains(where: { $0.value == member.id && serviceSnapshot[$0.key] == "renderingControl" })
                if !alreadySubscribed {
                    await subscribeToService(device: member, path: Self.renderingControlPath, serviceType: "renderingControl", manager: subManager)
                }
            }
        }

    }

    private func subscribeToService(device: SonosDevice, path: String, serviceType: String, manager: EventSubscriptionManager) async {
        guard liveDeviceIDs.contains(device.id) else {
            sonosDebugLog("[TRANSPORT] Skipping SUBSCRIBE for unreachable \(device.roomName) \(serviceType) — liveness probe failed")
            return
        }
        // Reentrancy guard: overlapping subscribeToAll passes (topology
        // NOTIFY bursts) interleave at every await; without this, both
        // passes see the SID map without the not-yet-landed subscription
        // and SUBSCRIBE the same device+service twice.
        let inFlightKey = "\(device.id)|\(serviceType)"
        guard !subscribesInFlight.contains(inFlightKey) else { return }
        subscribesInFlight.insert(inFlightKey)
        defer { subscribesInFlight.remove(inFlightKey) }
        do {
            let sub = try await manager.subscribe(device: device, servicePath: path)
            setSID(sub.sid, device: device.id, service: serviceType)
            if serviceType == "renderingControl" {
                sonosDebugLog("[RC-SUB] OK room=\(device.roomName) id=\(device.id) sid=\(sub.sid)")
            }
        } catch {
            sonosDebugLog("[TRANSPORT] Subscription to \(device.roomName) \(serviceType) failed: \(error)")
            if serviceType == "renderingControl" {
                sonosDebugLog("[RC-SUB] FAIL room=\(device.roomName) id=\(device.id) error=\(error)")
            }
        }
    }

    /// Parallel probe of `device_description.xml` for every device.
    /// 2.5 s timeout each, 8-way bounded concurrency. Result is a set
    /// of `device.id`s that responded; the SUBSCRIBE gate consults this
    /// set so dead speakers don't burn their full ~10 s SUBSCRIBE
    /// timeout or register a callback against an unreachable URL.
    /// Devices stay in the sidebar; live discovery refreshes them.
    private func probeLiveness(devices: [String: SonosDevice]) async {
        let unique = Array(devices.values)
        guard !unique.isEmpty else {
            liveDeviceIDs = []
            return
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Self.livenessProbeTimeout
        config.timeoutIntervalForResource = Self.livenessProbeTimeout
        let session = URLSession(configuration: config)
        let alive: Set<String> = await withTaskGroup(of: String?.self) { group in
            var nextIdx = 0
            var inFlight = 0
            let maxConcurrent = 8
            while nextIdx < unique.count && inFlight < maxConcurrent {
                let d = unique[nextIdx]
                group.addTask { await Self.probe(device: d, session: session) }
                nextIdx += 1
                inFlight += 1
            }
            var hits: Set<String> = []
            for await result in group {
                inFlight -= 1
                if let id = result { hits.insert(id) }
                if nextIdx < unique.count {
                    let d = unique[nextIdx]
                    group.addTask { await Self.probe(device: d, session: session) }
                    nextIdx += 1
                    inFlight += 1
                }
            }
            return hits
        }
        // Hysteresis: keep a live device through ONE missed probe. A single
        // 2.5 s timeout under transient contention would otherwise drop the
        // device, skip its SUBSCRIBE, and force its transport state onto
        // slow polling. Two consecutive misses drop it.
        var newLive: Set<String> = []
        for d in unique {
            if alive.contains(d.id) {
                consecutiveProbeMisses[d.id] = 0
                newLive.insert(d.id)
            } else {
                let misses = (consecutiveProbeMisses[d.id] ?? 0) + 1
                consecutiveProbeMisses[d.id] = misses
                if misses < 2 && liveDeviceIDs.contains(d.id) {
                    newLive.insert(d.id)  // grace — was live, first miss
                }
            }
        }
        liveDeviceIDs = newLive
        let dead = unique.count - newLive.count
        if dead > 0 {
            sonosDebugLog("[TRANSPORT] Liveness probe: \(newLive.count)/\(unique.count) live (\(alive.count) probed OK, \(newLive.count - alive.count) held on grace), skipping SUBSCRIBE for \(dead)")
        }
    }

    private nonisolated static func probe(device: SonosDevice, session: URLSession) async -> String? {
        guard let url = URL(string: "http://\(device.ip):\(device.port)/xml/device_description.xml") else { return nil }
        do {
            let (_, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                return device.id
            }
        } catch {
            // timeout / connection refused / unreachable — treat as dead
        }
        return nil
    }

    private func resubscribe(_ expiredSub: EventSubscription) async {
        guard isRunning, let subManager = subscriptionManager else { return }
        guard let device = currentDevices[expiredSub.deviceID] else { return }
        let serviceType = lookupSID(expiredSub.sid)?.service ?? "unknown"

        // Clean up old mapping
        removeSID(expiredSub.sid)

        // Re-subscribe
        await subscribeToService(device: device, path: expiredSub.servicePath, serviceType: serviceType, manager: subManager)
    }

    // MARK: - Event Handling

    @MainActor
    private func handleEvent(sid: String, seq: UInt32, body: String) {
        guard let info = lookupSID(sid) else {
            return
        }
        let serviceType = info.service
        let deviceID = info.deviceID

        // Broadcast every parsed event for observers (e.g. the in-app
        // Live Events tab in Diagnostics). Posted unconditionally —
        // there's no consumer cost when nothing is subscribed.
        NotificationCenter.default.post(
            name: SonosUPnPEventNotification.name,
            object: nil,
            userInfo: [
                SonosUPnPEventNotification.serviceKey: serviceType,
                SonosUPnPEventNotification.deviceIDKey: deviceID,
                SonosUPnPEventNotification.bodyKey: body
            ]
        )

        switch serviceType {
        case "avTransport":
            handleAVTransportEvent(body: body, deviceID: deviceID)
        case "renderingControl":
            handleRenderingControlEvent(body: body, deviceID: deviceID)
        case "topology":
            handleTopologyEvent(body: body, deviceID: deviceID)
        case "contentDirectory":
            handleContentDirectoryEvent(body: body, deviceID: deviceID)
        default:
            break
        }
    }

    @MainActor
    private func handleAVTransportEvent(body: String, deviceID: String) {
        let event = LastChangeParser.parseAVTransportEvent(body)

        // Foundation's XMLParser silently fails on Sonos's LastChange
        // event XML for some service streams (Apple Music HLS-static
        // among them), so `event.currentTrackMetaData` arrives empty
        // and the `r:streamInfo` codec descriptor that Sonos publishes
        // never reaches `enrichFromDIDL`. Sidestep the parser entirely
        // by string-matching the descriptor directly out of the raw
        // event body. The body holds it triple-escaped: look for
        // the deepest-escape form (`&amp;lt;r:streamInfo&amp;gt;...`)
        // which sits in the val= attribute of `<CurrentTrackMetaData>`,
        // then fall back to single-escape (`&lt;r:streamInfo&gt;...`)
        // for events where one decode pass has already happened.
        let bodyStreamInfo: String = {
            let needles: [(open: String, close: String)] = [
                ("&amp;lt;r:streamInfo&amp;gt;", "&amp;lt;/r:streamInfo&amp;gt;"),
                ("&lt;r:streamInfo&gt;", "&lt;/r:streamInfo&gt;"),
                ("<r:streamInfo>", "</r:streamInfo>")
            ]
            for (open, close) in needles {
                if let r1 = body.range(of: open),
                   let r2 = body.range(of: close, range: r1.upperBound..<body.endIndex) {
                    return String(body[r1.upperBound..<r2.lowerBound])
                }
            }
            return ""
        }()
        let eventAudioFormat = TrackMetadata.audioFormat(fromStreamInfo: bodyStreamInfo)

        // Find the group this coordinator belongs to
        guard let group = currentGroups.first(where: { $0.coordinatorID == deviceID }) else {
            return
        }

        // Record the decoded stream format (first sighting per launch
        // is diag-logged; distinct formats persist for playback tags).
        // `.unknown` here means an empty/all-zero descriptor — the
        // speaker hasn't decoded yet, not a new format — so skip it.
        if eventAudioFormat != .unknown {
            AudioFormatObserver.shared.recordStreamInfo(
                bodyStreamInfo, mapped: eventAudioFormat,
                room: group.coordinator?.roomName ?? "")
        }

        if let state = event.transportState {
            delegate?.transportDidUpdateState(group.coordinatorID, state: state)
        }

        if let mode = event.currentPlayMode {
            delegate?.transportDidUpdatePlayMode(group.coordinatorID, mode: mode)
        }

        if let actions = event.currentTransportActions {
            delegate?.transportDidUpdateTransportActions(group.coordinatorID, actions: actions)
        }

        // Parse track metadata from DIDL
        if let didlXML = event.currentTrackMetaData, !didlXML.isEmpty,
           didlXML != "NOT_IMPLEMENTED",
           let device = currentDevices[deviceID] {
            var metadata = TrackMetadata()
            metadata.trackURI = event.currentTrackURI
            metadata.enrichFromDIDL(didlXML, device: device)

            // Radio/stream: parse r:streamContent for current track info (Artist - Title)
            // enrichFromDIDL only extracts dc:title (station name) — the actual song info
            // lives in r:streamContent which must be parsed separately.
            let unescaped = DIDLNormalize.metadata(didlXML)
            let parsed = XMLResponseParser.parseDIDLMetadata(unescaped)
            // Fallback: if streamContent is empty (bare & breaks XML parser), extract with string matching
            let streamContent: String? = {
                if let sc = parsed?.streamContent, !sc.isEmpty { return sc }
                return XMLResponseParser.extractStreamContent(unescaped)
            }()
            if let content = streamContent, !content.isEmpty,
               let stream = TrackMetadata.parseStreamContent(content) {
                metadata.artist = stream.artist
                metadata.title = stream.title
            }

            if let durStr = event.currentTrackDuration {
                metadata.duration = TrackMetadata.parseTimeString(durStr)
            }
            if let numTracks = event.numberOfTracks {
                metadata.queueSize = numTracks
            }
            // The speaker's own queue position; QueuePositionResolver rule 1
            // needs it on the event path, not only the polling path.
            if let track = event.currentTrack {
                metadata.trackNumber = track
            }
            // Sidestep — the raw-body streamInfo parsed above carries
            // the Atmos codec flag that the DIDL parser couldn't see
            // because Foundation.XMLParser strips it. Apply it before
            // dispatching to the delegate so the audioFormat reaches
            // the merged TrackMetadata.
            if eventAudioFormat != .unknown {
                metadata.audioFormat = eventAudioFormat
                metadata.streamInfoRaw = bodyStreamInfo
            }

            delegate?.transportDidUpdateTrackMetadata(group.coordinatorID, metadata: metadata, source: .event)
        } else if event.currentTrackURI != nil || event.currentTrackDuration != nil {
            // Event has URI/duration but no DIDL — trigger a position refresh
            // This happens on some radio stations when tracks change
            let capturedAudioFormat = eventAudioFormat
            let capturedStreamInfo = bodyStreamInfo
            Task {
                guard let delegate = await self.delegate else { return }
                let avTransport = await delegate.getAVTransportService()
                guard let device = currentDevices[deviceID] else { return }
                if let position = try? await avTransport.getPositionInfo(device: device) {
                    var enriched = position
                    enriched.trackURI = event.currentTrackURI ?? position.trackURI
                    if let mediaInfo = try? await avTransport.getMediaInfo(device: device) {
                        enriched.enrichFromMediaInfo(mediaInfo, device: device)
                    }
                    if capturedAudioFormat != .unknown {
                        enriched.audioFormat = capturedAudioFormat
                        enriched.streamInfoRaw = capturedStreamInfo
                    }
                    await delegate.transportDidUpdateTrackMetadata(group.coordinatorID, metadata: enriched, source: .event)
                }
            }
        }
    }

    @MainActor
    private func handleRenderingControlEvent(body: String, deviceID: String) {
        let event = LastChangeParser.parseRenderingControlEvent(body)
        let room = currentDevices[deviceID]?.roomName ?? deviceID
        sonosDebugLog("[RC-RAW] room=\(room) id=\(deviceID) volume=\(event.volume.map(String.init) ?? "nil") mute=\(event.mute.map(String.init) ?? "nil")")

        if let volume = event.volume {
            delegate?.transportDidUpdateVolume(deviceID, volume: volume)
        }
        if let muted = event.mute {
            delegate?.transportDidUpdateMute(deviceID, muted: muted)
        }
    }

    @MainActor
    private func handleContentDirectoryEvent(body: String, deviceID: String) {
        let event = LastChangeParser.parseContentDirectoryEvent(body)
        // Only `Q:0` (active queue) triggers a queue reload. Other
        // container updates (`SQ:`, `R:0/0`, `A:*`, …) are out of scope
        // for this hook — favorites, playlists and library mutations
        // are infrequent and don't drive idle CPU.
        guard event.queueChanged else { return }
        // ContentDirectory subscriptions are opened per coordinator,
        // so the SID's deviceID *is* the coordinator's groupID.
        guard currentGroups.contains(where: { $0.coordinatorID == deviceID }) else {
            return
        }
        delegate?.transportDidObserveQueueChange(deviceID)
    }

    @MainActor
    private func handleTopologyEvent(body: String, deviceID: String) {
        // The event payload is not parsed (triple-encoded XML, unreliable
        // group data); it is a trigger for the delegate to pull
        // ZoneGroupState via SOAP. Pass the originating device so the
        // refresh hits the speaker that published the change — a sibling
        // that has not yet propagated it produces a group/ungroup flap.
        delegate?.transportRequestsTopologyRefresh(originDeviceID: deviceID)
    }

    // MARK: - Reconciliation Polling

    /// Safety net: periodically polls full state to catch anything
    /// events missed. Runs at `Timing.reconciliationPolling` (15 s);
    /// kept tight while the cache-restore / `isUsingCachedData`
    /// interaction with event flow is being stabilised. Elapsed
    /// position for the *visible* group is rebased more aggressively
    /// by `NowPlayingViewModel.pollActivePosition` at 2 s; this poll
    /// exists for everything else (background groups, TV-mode HDMI
    /// audio-format updates, and silent subscription death).
    private func startReconciliationPolling() {
        reconciliationTask?.cancel()
        reconciliationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Timing.reconciliationPolling))
                guard let self = self, self.isRunning else { return }
                await self.reconcileAllGroups()
            }
        }
    }

    private func reconcileAllGroups() async {
        for group in currentGroups {
            guard !Task.isCancelled else { return }
            await fetchGroupState(group, context: "Reconciliation")
        }
    }

    // MARK: - Initial State Fetch

    private func fetchInitialState(groups: [SonosGroup]) async {
        for group in groups {
            await fetchGroupState(group, context: "Initial state fetch")
        }
    }

    /// Shared helper: fetches transport state, track metadata, play mode, volume, and mute
    /// for a single group. Used by both initial fetch and reconciliation polling.
    private func fetchGroupState(_ group: SonosGroup, context: String) async {
        guard let coordinator = group.coordinator else { return }
        do {
            guard let delegate = await self.delegate else { return }

            let avTransport = await delegate.getAVTransportService()
            let renderingControl = await delegate.getRenderingControlService()
            let zoneTopology = await delegate.getZoneGroupTopologyService()

            async let stateResult = avTransport.getTransportInfo(device: coordinator)
            async let positionResult = avTransport.getPositionInfo(device: coordinator)
            async let modeResult = avTransport.getTransportSettings(device: coordinator)

            let (state, position, mode) = try await (stateResult, positionResult, modeResult)

            var enrichedPosition = position
            // Always fetch mediaInfo to set isQueueSource correctly
            // (prevents queue metadata leaking into direct stream playback)
            if let mediaInfo = try? await avTransport.getMediaInfo(device: coordinator) {
                enrichedPosition.enrichFromMediaInfo(mediaInfo, device: coordinator)
            }

            // HDMI / line-in mode: pull the speaker's current audio
            // input format from DeviceProperties.GetZoneInfo. The
            // AVTransport channel only carries this on input-mode
            // transitions, so reconciliation polling is what keeps the
            // readout current as the TV's output format shifts (e.g.
            // commercial break → 5.1 movie).
            if let trackURI = enrichedPosition.trackURI,
               trackURI.contains("x-sonos-htastream:") ||
               trackURI.contains("x-rincon-stream:") {
                if let raw = try? await zoneTopology.getHTAudioIn(device: coordinator) {
                    let mapped = TVAudioFormat.from(htAudioIn: raw)
                    enrichedPosition.tvAudioFormat = mapped
                    AudioFormatObserver.shared.recordHTAudioIn(
                        raw, mapped: mapped,
                        room: coordinator.roomName, model: coordinator.modelName)
                }
            }

            await delegate.transportDidUpdateState(group.coordinatorID, state: state)
            await delegate.transportDidUpdateTrackMetadata(group.coordinatorID, metadata: enrichedPosition, source: .poll)
            await delegate.transportDidUpdatePlayMode(group.coordinatorID, mode: mode)
            await delegate.transportDidUpdatePosition(group.coordinatorID, position: enrichedPosition.position, duration: enrichedPosition.duration)

            for member in group.members {
                let vol = try await renderingControl.getVolume(device: member)
                let muted = try await renderingControl.getMute(device: member)
                await delegate.transportDidUpdateVolume(member.id, volume: vol)
                await delegate.transportDidUpdateMute(member.id, muted: muted)
            }
        } catch {
            sonosDebugLog("[TRANSPORT] \(context) failed for group: \(error)")
        }
    }

    /// Current active subscription count (for diagnostics)
    public var activeSubscriptionCount: Int {
        subscriptionManager?.activeSubscriptionCount ?? 0
    }

    /// Subscription details for diagnostics
    public var subscriptionDetails: [(sid: String, deviceID: String, service: String, expiresAt: Date)] {
        guard let subs = subscriptionManager?.allSubscriptions else { return [] }
        let (_, serviceSnapshot) = snapshotSIDs()
        return subs.map { sub in
            let service = serviceSnapshot[sub.sid] ?? "unknown"
            return (sid: sub.sid, deviceID: sub.deviceID, service: service, expiresAt: sub.expiresAt)
        }
    }

    /// The callback URL being used for events
    public var callbackURLString: String {
        eventListener?.callbackURL?.absoluteString ?? L10n.notAvailable
    }
}

// MARK: - Legacy Polling Transport

public final class LegacyPollingTransport: TransportStrategy {
    public weak var delegate: TransportStrategyDelegate?

    private var pollingTask: Task<Void, Never>?
    private var currentGroups: [SonosGroup] = []
    private var currentDevices: [String: SonosDevice] = [:]
    private var isRunning = false

    public init() {}

    public func start(groups: [SonosGroup], devices: [String: SonosDevice]) async {
        guard !isRunning else { return }
        isRunning = true
        currentGroups = groups
        currentDevices = devices
        startPolling()
    }

    public func stop() async {
        isRunning = false
        pollingTask?.cancel()
        pollingTask = nil
    }

    public func onGroupsChanged(_ groups: [SonosGroup], devices: [String: SonosDevice]) async {
        currentGroups = groups
        currentDevices = devices
    }

    private func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self, self.isRunning else { return }
                await self.pollAllGroups()
                try? await Task.sleep(for: .seconds(Timing.legacyPolling))
            }
        }
    }

    private func pollAllGroups() async {
        for group in currentGroups {
            guard !Task.isCancelled else { return }
            guard let coordinator = group.coordinator else { continue }

            do {
                guard let delegate = await self.delegate else { return }

                let avTransport = await delegate.getAVTransportService()
                let renderingControl = await delegate.getRenderingControlService()

                async let stateResult = avTransport.getTransportInfo(device: coordinator)
                async let positionResult = avTransport.getPositionInfo(device: coordinator)
                async let modeResult = avTransport.getTransportSettings(device: coordinator)

                let (state, position, mode) = try await (stateResult, positionResult, modeResult)

                await delegate.transportDidUpdateState(group.coordinatorID, state: state)
                await delegate.transportDidUpdateTrackMetadata(group.coordinatorID, metadata: position, source: .poll)
                await delegate.transportDidUpdatePlayMode(group.coordinatorID, mode: mode)
                await delegate.transportDidUpdatePosition(group.coordinatorID, position: position.position, duration: position.duration)

                // Poll volume and mute per member
                for member in group.members {
                    let vol = try await renderingControl.getVolume(device: member)
                    let muted = try await renderingControl.getMute(device: member)
                    await delegate.transportDidUpdateVolume(member.id, volume: vol)
                    await delegate.transportDidUpdateMute(member.id, muted: muted)
                }
            } catch {
                sonosDebugLog("[TRANSPORT] Poll failed for group: \(error)")
            }
        }
    }
}

/// Notification keys for the live UPnP event broadcast emitted by
/// `HybridEventFirstTransport.handleEvent`. Consumed by the in-app
/// Live Events tab in Diagnostics. Lives here (rather than in
/// `EventListener`) because the notification carries the resolved
/// `serviceType` + `deviceID` from `lookupSID`, which only the
/// transport knows.
public enum SonosUPnPEventNotification {
    public static let name = Notification.Name("SonosUPnPEventNotification")
    public static let serviceKey = "service"   // "avTransport" / "renderingControl" / "topology"
    public static let deviceIDKey = "deviceID" // RINCON UUID
    public static let bodyKey = "body"         // Raw NOTIFY XML
}
