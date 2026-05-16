/// TransportStrategy.swift — Protocol and implementations for state update strategies.
///
/// Defines the abstraction for how the app receives state updates from Sonos speakers.
/// Two implementations:
/// - HybridEventFirstTransport: UPnP event subscriptions with targeted polling fallback
/// - LegacyPollingTransport: Original 2-second polling loop (preserved for fallback)
///
/// Both strategies update state through a delegate callback to SonosManager.
import Foundation

/// Where a track-metadata update came from. UPnP event subscriptions
/// are pushed by the speaker the moment its state changes, so they
/// reflect the latest authoritative state. Reconciliation polls
/// (`fetchGroupState` -> `getPositionInfo`) are request/response
/// round-trips whose response can land seconds after the request
/// was issued — long enough for a Prev/Next click to fly past
/// inbetween. Letting an in-flight poll's response overwrite a
/// freshly-pushed event manifested as "queue row one behind the
/// playing track" because the poll snapshot was the *pre-Prev*
/// state. SonosManager uses this tag to drop poll responses that
/// disagree with the latest event when the event is still recent.
public enum TrackMetadataSource: Sendable {
    case event
    case poll
}

// MARK: - Protocol

public protocol TransportStrategy: AnyObject {
    func start(groups: [SonosGroup], devices: [String: SonosDevice]) async
    func stop() async
    func onGroupsChanged(_ groups: [SonosGroup], devices: [String: SonosDevice]) async
    var delegate: TransportStrategyDelegate? { get set }
}

@MainActor
public protocol TransportStrategyDelegate: AnyObject {
    func transportDidUpdateState(_ groupID: String, state: TransportState)
    func transportDidUpdateTrackMetadata(_ groupID: String, metadata: TrackMetadata, source: TrackMetadataSource)
    func transportDidUpdatePlayMode(_ groupID: String, mode: PlayMode)
    func transportDidUpdateVolume(_ deviceID: String, volume: Int)
    func transportDidUpdateMute(_ deviceID: String, muted: Bool)
    func transportDidUpdateTopology(_ groups: [ZoneGroupData])
    func transportDidUpdatePosition(_ groupID: String, position: TimeInterval, duration: TimeInterval)
    /// Fired when a `ZoneGroupTopology` UPnP NOTIFY arrives. The
    /// delegate should re-fetch authoritative topology via
    /// `GetZoneGroupState`. We don't try to parse the event payload —
    /// its triple-encoded XML structure historically produced incorrect
    /// group data. The notification is just a "something changed,
    /// pull the truth" signal.
    func transportRequestsTopologyRefresh()
    // Services for direct queries
    func getAVTransportService() -> AVTransportService
    func getRenderingControlService() -> RenderingControlService
    func getZoneGroupTopologyService() -> ZoneGroupTopologyService
}

// MARK: - Hybrid Event-First Transport

public final class HybridEventFirstTransport: TransportStrategy, @unchecked Sendable {
    public weak var delegate: TransportStrategyDelegate?

    private var eventListener: EventListener?
    private var subscriptionManager: EventSubscriptionManager?
    private var positionPollingTask: Task<Void, Never>?
    private var reconciliationTask: Task<Void, Never>?
    private var currentGroups: [SonosGroup] = []
    private var currentDevices: [String: SonosDevice] = [:]
    private var isRunning = false

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

    public init() {}

    public func start(groups: [SonosGroup], devices: [String: SonosDevice]) async {
        guard !isRunning else { return }
        isRunning = true
        currentGroups = groups
        currentDevices = devices

        // Start event listener and subscriptions (best-effort — reconciliation is the safety net)
        let listener = EventListener()
        do {
            try listener.start()
            if let callbackURL = listener.callbackURL {
                self.eventListener = listener
                let subManager = EventSubscriptionManager(callbackURL: callbackURL)
                self.subscriptionManager = subManager

                listener.onEvent = { [weak self] sid, seq, body in
                    Task { @MainActor [weak self] in
                        self?.handleEvent(sid: sid, seq: seq, body: body)
                    }
                }

                await subscribeToAll(groups: groups, devices: devices)

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
        positionPollingTask?.cancel()
        positionPollingTask = nil
        reconciliationTask?.cancel()
        reconciliationTask = nil

        if let subManager = subscriptionManager {
            await subManager.unsubscribeAll()
        }
        subscriptionManager = nil

        eventListener?.stop()
        eventListener = nil

        clearAllSIDs()
    }

    public func onGroupsChanged(_ groups: [SonosGroup], devices: [String: SonosDevice]) async {
        let oldGroupIDs = Set(currentGroups.map(\.id))
        currentGroups = groups
        currentDevices = devices

        // Unsubscribe from devices no longer in any group
        let oldDeviceIDs = Set(currentGroups.flatMap(\.members).map(\.id))
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

        // Take thread-safe snapshots
        let (deviceSnapshot, serviceSnapshot) = snapshotSIDs()

        // Subscribe to topology from one device
        if let anyDevice = groups.first?.coordinator ?? devices.values.first {
            let alreadySubscribed = serviceSnapshot.values.contains("topology")
            if !alreadySubscribed {
                await subscribeToService(device: anyDevice, path: Self.topologyPath, serviceType: "topology", manager: subManager)
            }
        }

        // Subscribe to AVTransport on each coordinator
        for group in groups {
            guard let coordinator = group.coordinator else { continue }
            let alreadySubscribed = deviceSnapshot.contains(where: { $0.value == coordinator.id && serviceSnapshot[$0.key] == "avTransport" })
            if !alreadySubscribed {
                await subscribeToService(device: coordinator, path: Self.avTransportPath, serviceType: "avTransport", manager: subManager)
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
            handleTopologyEvent(body: body)
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
        // event body. The body holds it triple-escaped — we look for
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

        if let state = event.transportState {
            delegate?.transportDidUpdateState(group.coordinatorID, state: state)
        }

        if let mode = event.currentPlayMode {
            delegate?.transportDidUpdatePlayMode(group.coordinatorID, mode: mode)
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
            let unescaped = didlXML.contains("&lt;") ? XMLResponseParser.xmlUnescape(didlXML) : didlXML
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
            // Sidestep — the raw-body streamInfo parsed above carries
            // the Atmos codec flag that the DIDL parser couldn't see
            // because Foundation.XMLParser strips it. Apply it before
            // dispatching to the delegate so the audioFormat reaches
            // the merged TrackMetadata.
            if eventAudioFormat != .unknown {
                metadata.audioFormat = eventAudioFormat
            }

            delegate?.transportDidUpdateTrackMetadata(group.coordinatorID, metadata: metadata, source: .event)
        } else if event.currentTrackURI != nil || event.currentTrackDuration != nil {
            // Event has URI/duration but no DIDL — trigger a position refresh
            // This happens on some radio stations when tracks change
            let capturedAudioFormat = eventAudioFormat
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
    private func handleTopologyEvent(body: String) {
        // Don't try to parse the event payload — its triple-encoded XML
        // structure historically produced incorrect group data. Treat
        // the event as a trigger only and have the delegate pull the
        // authoritative ZoneGroupState via SOAP. Without this signal,
        // grouping/ungrouping changes made from Sonos's app weren't
        // reflected here until the 30-second SSDP rescan caught them.
        delegate?.transportRequestsTopologyRefresh()
    }

    // MARK: - Reconciliation Polling

    /// Safety net: periodically polls full state to catch anything events missed.
    /// Runs every 15 seconds. Also handles position updates since UPnP events
    /// don't include elapsed position.
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
                    enrichedPosition.tvAudioFormat = TVAudioFormat.from(htAudioIn: raw)
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
        eventListener?.callbackURL?.absoluteString ?? "Not available"
    }
}

// MARK: - Legacy Polling Transport

public final class LegacyPollingTransport: TransportStrategy, @unchecked Sendable {
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
