/// TopologyStore.swift — Owns the household view: groups, devices and the
/// bonded-channel maps derived from them.
///
/// The store holds no reference back to `SonosManager`. It answers "what does
/// the household look like" and reports what changed; deciding what to *do*
/// about a change — saving the cache, restarting the transport strategy,
/// rescanning groups — stays with the manager. A collaborator that had to call
/// back into the façade would relocate the coupling rather than remove it.
import Foundation

@MainActor
@Observable
public final class TopologyStore {

    // MARK: - State

    public private(set) var groups: [SonosGroup] = []
    public private(set) var devices: [String: SonosDevice] = [:]

    /// Parsed `HTSatChanMapSet` data: coordinator ID → [(deviceID, channel)]
    public private(set) var htSatChannelMaps: [String: [(String, SpeakerChannel)]] = [:]

    /// Parsed `ChannelMapSet` data — stereo-pair primaries map their
    /// invisible right-channel sibling here (e.g. coordinator UUID →
    /// `[(left=primary, .leftPair), (right=invisible, .rightPair)]`).
    /// Distinct from `htSatChannelMaps` so the existing `homeTheaterZones`
    /// consumer keeps its 5.1-only semantics while the bug-bundle topology
    /// snapshot can fold both maps.
    public private(set) var stereoChannelMaps: [String: [(String, SpeakerChannel)]] = [:]

    /// Returns bonded home theater zones (those with HTSatChanMapSet — sub/surrounds)
    public var homeTheaterZones: [HomeTheaterZone] {
        var zones: [HomeTheaterZone] = []
        for group in groups {
            guard let coordinator = group.coordinator else { continue }
            if let channelMap = htSatChannelMaps[coordinator.id] {
                var members: [HomeTheaterMember] = []
                // Add coordinator as LF,RF (soundbar)
                members.append(HomeTheaterMember(device: coordinator, channel: .soundbar))
                // Add satellites
                for (deviceID, channel) in channelMap {
                    if let device = devices[deviceID], deviceID != coordinator.id {
                        members.append(HomeTheaterMember(device: device, channel: channel))
                    }
                }
                zones.append(HomeTheaterZone(
                    coordinatorID: coordinator.id,
                    name: coordinator.roomName,
                    members: members.sorted { $0.channel.sortOrder < $1.channel.sortOrder }
                ))
            }
        }
        return zones
    }

    // MARK: - Collaborators and refresh bookkeeping

    @ObservationIgnored private let zoneTopology: ZoneGroupStateFetching
    /// Reports a publish tag to the owner's `[MGR-PUB]` diagnostic counters.
    /// A closure rather than a manager reference — the store needs to emit a
    /// tag, not to know what emits it.
    @ObservationIgnored private let publishTag: @MainActor (String) -> Void

    /// Serializes topology refreshes per household so S1 and S2 refreshes
    /// don't block each other but also don't race within a single household.
    @ObservationIgnored private var refreshingHouseholds: Set<String> = []
    @ObservationIgnored private var pendingForcedRefreshes: Set<String> = []
    @ObservationIgnored private var lastRefreshAt: [String: Date] = [:]
    @ObservationIgnored private let refreshMinInterval: TimeInterval

    public init(zoneTopology: ZoneGroupStateFetching,
                refreshMinInterval: TimeInterval = 10,
                publishTag: @escaping @MainActor (String) -> Void = { _ in }) {
        self.zoneTopology = zoneTopology
        self.refreshMinInterval = refreshMinInterval
        self.publishTag = publishTag
    }

    // MARK: - Refresh outcome

    /// What a refresh did, so the owner can run the right side effects
    /// without re-deriving the reasoning or reaching into the store's state.
    public struct RefreshResult: Equatable, Sendable {
        public enum Outcome: Equatable, Sendable {
            /// Another refresh already owns this household.
            case inFlight
            /// Arrived inside the minimum interval of the last success.
            case throttled
            /// Source device has no household yet; merging would wipe the
            /// S1/S2 partitioning with nil-tagged groups.
            case noHousehold
            /// Empty or all-orphan response — a satellite's self-view or an
            /// aborted parse. Carries no household information, so the
            /// previous topology is kept.
            case rejectedSelfView
            case failed
            case applied
        }

        public let outcome: Outcome
        /// True only when `outcome == .applied` and the merge differed from
        /// what was already held.
        public let changed: Bool
        /// A forced refresh arrived while this one was in flight. The owner
        /// re-drives so its side effects run for that pass too.
        public let rerunForced: Bool

        init(_ outcome: Outcome, changed: Bool = false, rerunForced: Bool = false) {
            self.outcome = outcome
            self.changed = changed
            self.rerunForced = rerunForced
        }
    }

    /// True when `deviceID` coordinates any current group. Gates optimistic
    /// propagation and verifier scheduling elsewhere, so only fast, reliable
    /// coordinator events drive group-level reactions.
    public func isCoordinator(deviceID: String) -> Bool {
        groups.contains { $0.coordinatorID == deviceID }
    }

    /// One reachable coordinator per distinct household (S1 + S2 coexist as
    /// separate households on the same LAN). Keyed by householdID, falling back
    /// to coordinatorID before the household resolves.
    public func coordinatorPerHousehold() -> [String: SonosGroup] {
        var byHousehold: [String: SonosGroup] = [:]
        for g in groups where g.coordinator != nil {
            let hh = g.householdID ?? g.coordinatorID
            if byHousehold[hh] == nil { byHousehold[hh] = g }
        }
        return byHousehold
    }

    /// A reachable coordinator in the given system, or nil. Scopes browse and
    /// search to the right S1/S2 ContentDirectory so the selected speaker's own
    /// library shares are shown.
    public func coordinatorForHousehold(_ householdID: String?) -> SonosDevice? {
        guard let householdID else { return nil }
        // Require a reachable coordinator in the predicate — the household's
        // first group may momentarily lack one while another group has it.
        return groups.first(where: {
            ($0.householdID ?? $0.coordinatorID) == householdID && $0.coordinator != nil
        })?.coordinator
    }

    /// Fallback device for household-agnostic calls.
    public var preferredDevice: SonosDevice? {
        groups.first?.coordinator ?? devices.values.first
    }

    // MARK: - Application

    /// Seeds the store from the on-disk cache at startup.
    public func applyCached(groups: [SonosGroup], devices: [String: SonosDevice]) {
        self.devices = devices
        self.groups = groups
        // Cached groups are restored verbatim, so a household persisted in
        // a broken state comes back broken; one line per launch places it
        // on the timeline.
        logTopologyOutcome("cache", groups: groups)
    }

    /// Records a fully-discovered device (SSDP or seed-by-address), which
    /// carries fields the topology stubs do not.
    public func upsertDevice(_ device: SonosDevice) {
        devices[device.id] = device
    }

    /// Pulls `GetZoneGroupState` from `device` and merges the result.
    public func refresh(from device: SonosDevice, force: Bool) async -> RefreshResult {
        // Use source device UUID when householdID is not yet known (first discovery).
        let refreshKey = device.householdID ?? device.id
        guard !refreshingHouseholds.contains(refreshKey) else {
            // A forced refresh (user-initiated group change) must not be
            // silently dropped because a non-forced refresh is mid-flight —
            // record it and report it when the in-flight one completes.
            if force { pendingForcedRefreshes.insert(refreshKey) }
            return RefreshResult(.inFlight)
        }

        // Throttle: skip refreshes that arrive within the minimum interval of
        // the previous successful refresh for this household. Keeps SSDP
        // response bursts (sub/satellite/coordinator all advertising per rescan)
        // from generating redundant GetZoneGroupState calls. User-initiated
        // group changes pass `force: true` to bypass this throttle and get
        // immediate UI feedback on the group/ungroup action.
        if !force,
           let last = lastRefreshAt[refreshKey],
           Date().timeIntervalSince(last) < refreshMinInterval {
            return RefreshResult(.throttled)
        }

        refreshingHouseholds.insert(refreshKey)
        defer { refreshingHouseholds.remove(refreshKey) }

        let outcome = await performRefresh(from: device, refreshKey: refreshKey)
        let rerun = pendingForcedRefreshes.remove(refreshKey) != nil
        return RefreshResult(outcome.0, changed: outcome.1, rerunForced: rerun)
    }

    private func performRefresh(from device: SonosDevice,
                                refreshKey: String) async -> (RefreshResult.Outcome, Bool) {
        let groupData: [ZoneGroupData]
        do {
            groupData = try await zoneTopology.getZoneGroupState(device: device)
        } catch {
            sonosDebugLog("[DISCOVERY] Topology fetch failed: \(error)")
            return (.failed, false)
        }

        // Members inherit the source device's household — all groups returned by
        // GetZoneGroupState belong to the same Sonos system (S1 or S2).
        // If the source's household is unknown (GetHouseholdID failed), abort
        // the merge rather than wipe S1/S2 partitioning with nil-tagged groups.
        guard let household = device.householdID else {
            sonosDebugLog("[DISCOVERY] Skipping topology merge — source device \(device.id) has no household yet")
            return (.noHousehold, false)
        }

        // The source's topology response is the authoritative view of the
        // household. Smoothing over transient inconsistency between
        // speakers' ZoneGroupState responses accumulates phantom groups (a
        // dissolved group reported by one speaker, then preserved forever);
        // latest-response-wins is eventually consistent with reality.
        var newGroups = buildGroups(from: groupData,
                                    household: household,
                                    sourceSoftwareVersion: device.softwareVersion,
                                    sourceSwGen: device.swGen)

        // Reject satellite self-views before the merge. A home-theater
        // satellite (or a speaker mid-reboot) answers GetZoneGroupState
        // with a topology containing only `…:orphan` groups — its own
        // isolated view, not the household. Latest-response-wins would
        // accept it and wipe every real group; with event subscriptions
        // torn down by the wipe and SSDP blocked, the empty state persists
        // until restart. A response with no non-orphan groups carries no
        // household information, so the merge is skipped. Aborted
        // ZoneGroupState parses reach here the same way; both keep the
        // previous topology and retry later.
        let realGroups = newGroups.filter { !$0.id.hasSuffix(":orphan") }
        if realGroups.isEmpty {
            sonosDebugLog("[MERGE] REJECTED empty/self-view topology from \(device.roomName) — \(newGroups.count) group(s), none usable; keeping previous topology")
            return (.rejectedSelfView, false)
        }
        newGroups = realGroups

        // Backfill nil householdID on cached groups whose coordinator is now a
        // known device with a household; otherwise stale cache entries surface
        // as an "Unknown" tab after the first refresh.
        let backfilledGroups = groups.map { g -> SonosGroup in
            guard g.householdID == nil else { return g }
            guard let coord = devices[g.coordinatorID], let hh = coord.householdID else { return g }
            var patched = g
            patched.householdID = hh
            return patched
        }

        // The source's full topology response replaces every group in its
        // household; other-household groups (S1 while refreshing S2 and
        // vice versa) are preserved untouched. No grace windows:
        // user-initiated grouping needs immediate UI feedback, and
        // smoothing over Sonos's topology inconsistency creates phantom
        // groups that are worse than the underlying flicker.
        let otherHouseholdGroups = backfilledGroups.filter { $0.householdID != household }
        let mergedGroups = (otherHouseholdGroups + newGroups)
            .sorted { $0.name < $1.name }

        // Only update groups when topology changed — prevents UI flash.
        // SonosGroup is Equatable by synthesis (all fields Equatable), so full
        // value equality on the sorted array is correct and order-tolerant
        // (member arrays are stably sorted above).
        let didChange = mergedGroups != groups
        if didChange {
            logMergeDiff(source: device.roomName,
                         household: household,
                         newCount: newGroups.count,
                         merged: mergedGroups)
            self.groups = mergedGroups
            logTopologyOutcome("refresh(\(device.roomName))", groups: mergedGroups)
        } else {
            sonosDebugLog("[MERGE] source=\(device.roomName) household=\(household) newCount=\(newGroups.count) totalCount=\(mergedGroups.count) changed=false")
        }

        // Record the successful refresh so the throttle can skip bursts.
        lastRefreshAt[refreshKey] = Date()

        // Parse home theater channel maps
        parseHTChannelMaps(from: groupData)
        // Parse stereo-pair channel maps (separate attribute, same
        // shape — keeps homeTheaterZones consumer pure HT while
        // letting the bug-bundle snapshot fold both bonded forms).
        parseStereoChannelMaps(from: groupData)

        return (.applied, didChange)
    }

    /// Applies a topology delivered by a UPnP event rather than a poll.
    /// The event payload carries no per-device detail beyond the topology
    /// stubs, so unlike `refresh` it does not preserve or backfill software
    /// version fields. Returns true when the group list changed.
    @discardableResult
    public func applyEventTopology(_ groupData: [ZoneGroupData]) -> Bool {
        var newGroups: [SonosGroup] = []
        for gd in groupData {
            var members: [SonosDevice] = []
            for md in gd.members {
                let dev = SonosDevice(
                    id: md.uuid,
                    ip: md.ip,
                    port: md.port,
                    roomName: md.zoneName,
                    isCoordinator: md.uuid == gd.coordinatorUUID,
                    groupID: gd.id
                )
                // Same guard as the poll path below: an unchanged-value
                // write still fires observation and re-renders every
                // reader, once per member per topology event.
                if devices[dev.id] != dev {
                    devices[dev.id] = dev
                }
                if !md.isInvisible {
                    members.append(dev)
                }
            }
            let stableMembers = members.sorted { $0.id < $1.id }
            let group = SonosGroup(id: gd.id,
                                   coordinatorID: resolvedCoordinatorID(for: gd,
                                                                        visibleMembers: stableMembers),
                                   members: stableMembers)
            newGroups.append(group)
        }

        let sorted = newGroups.sorted { $0.name < $1.name }
        let didChange = sorted != groups
        if didChange {
            self.groups = sorted
        }
        logTopologyOutcome("event", groups: self.groups)
        return didChange
    }

    // MARK: - Group construction

    private func buildGroups(from groupData: [ZoneGroupData],
                             household: String,
                             sourceSoftwareVersion: String,
                             sourceSwGen: String) -> [SonosGroup] {
        var newGroups: [SonosGroup] = []
        for gd in groupData {
            var members: [SonosDevice] = []
            for md in gd.members {
                // Preserve per-device fields already fetched (members may be full
                // devices discovered via SSDP, not just topology stubs). Empty
                // strings should not block the household-wide fallback: prefer
                // non-empty existing values, then the source device.
                let existing = devices[md.uuid]
                let existingSoftwareVersion = existing?.softwareVersion ?? ""
                let existingSwGen = existing?.swGen ?? ""
                let softwareVersion = existingSoftwareVersion.isEmpty ? sourceSoftwareVersion : existingSoftwareVersion
                let swGen = existingSwGen.isEmpty ? sourceSwGen : existingSwGen
                let dev = SonosDevice(
                    id: md.uuid,
                    ip: md.ip,
                    port: md.port,
                    roomName: md.zoneName,
                    modelName: existing?.modelName ?? "",
                    modelNumber: existing?.modelNumber ?? "",
                    softwareVersion: softwareVersion,
                    swGen: swGen,
                    householdID: household,
                    isCoordinator: md.uuid == gd.coordinatorUUID,
                    groupID: gd.id
                )
                // Guard the write to avoid spurious observation fires that
                // cascade through re-renders and can cause onChange-driven
                // scroll animations to trigger even when topology is unchanged.
                if devices[dev.id] != dev {
                    devices[dev.id] = dev
                }
                // Invisible members are Sub/Surround satellites — hide from UI
                if !md.isInvisible {
                    members.append(dev)
                }
            }
            // Sort members by id so the stored order is deterministic regardless
            // of the order the speaker returned them in — otherwise the equality
            // check can false-positive on a pure reorder and cause flicker.
            let stableMembers = members.sorted { $0.id < $1.id }
            let group = SonosGroup(id: gd.id,
                                   coordinatorID: resolvedCoordinatorID(for: gd,
                                                                        visibleMembers: stableMembers),
                                   members: stableMembers, householdID: household)
            newGroups.append(group)
        }
        return newGroups
    }

    /// Repairs a group whose `Coordinator` UUID names no visible member
    /// (#83) — such a group takes no transport command and reports no
    /// state. Substitutions are logged, never silent.
    private func resolvedCoordinatorID(for gd: ZoneGroupData,
                                       visibleMembers: [SonosDevice]) -> String {
        let resolution = TopologyCoordinatorResolver.resolve(
            reported: gd.coordinatorUUID,
            visibleMemberIDs: visibleMembers.map(\.id),
            previouslyKnownCoordinator: groups.first { $0.id == gd.id }?.coordinatorID)
        guard resolution.substituted else { return resolution.coordinatorID }
        sonosDiagLog(.error, tag: "TOPOLOGY",
                     "Group coordinator not among its visible members — substituting",
                     context: [
                        "groupID": gd.id,
                        "reportedCoordinator": gd.coordinatorUUID,
                        "substituted": resolution.coordinatorID,
                        "substitutedRoom": visibleMembers
                            .first { $0.id == resolution.coordinatorID }?.roomName ?? "",
                        "visibleMembers": String(visibleMembers.count),
                        "totalMembers": String(gd.members.count)
                     ])
        return resolution.coordinatorID
    }

    // MARK: - Diagnostics

    /// Diffs the sets so the log shows exactly which groups appeared or
    /// disappeared — the "speaker disappearing then coming back" symptom
    /// shows up as alternating added/removed for the same id.
    private func logMergeDiff(source: String,
                              household: String,
                              newCount: Int,
                              merged: [SonosGroup]) {
        let oldIDs = Set(groups.map(\.id))
        let newIDs = Set(merged.map(\.id))
        let added = newIDs.subtracting(oldIDs).sorted()
        let removed = oldIDs.subtracting(newIDs).sorted()
        // For groups present in both, log any member-list differences.
        // `uniquingKeysWith` rather than `uniqueKeysWithValues`: the latter
        // traps on a duplicate key, and this is diagnostics — a speaker that
        // reports the same group id twice in one ZoneGroupState response must
        // produce a confusing log line, never a crash.
        let newByID = Dictionary(merged.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let oldByID = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var memberDiffs: [String] = []
        for id in newIDs.intersection(oldIDs).sorted() {
            guard let n = newByID[id], let o = oldByID[id] else { continue }
            if n != o {
                let newMembers = n.members.map(\.roomName).joined(separator: ",")
                let oldMembers = o.members.map(\.roomName).joined(separator: ",")
                memberDiffs.append("\(id): [\(oldMembers)] -> [\(newMembers)]")
            }
        }
        sonosDebugLog("[MERGE] source=\(source) household=\(household) newCount=\(newCount) totalCount=\(merged.count) changed=true added=\(added) removed=\(removed) memberDiffs=\(memberDiffs)")
    }

    /// Records what each topology application produced, so a bug bundle
    /// shows which update broke a household, not only parse aborts.
    private func logTopologyOutcome(_ source: String, groups: [SonosGroup]) {
        let coordinatorless = groups.filter { $0.coordinator == nil }
        sonosDiagLog(coordinatorless.isEmpty ? .info : .error, tag: "TOPOLOGY",
                     "Topology applied from \(source)",
                     context: [
                        "groups": String(groups.count),
                        "visibleSpeakers": String(groups.reduce(0) { $0 + $1.members.count }),
                        "groupsWithoutCoordinator": String(coordinatorless.count),
                        "namesWithoutCoordinator": coordinatorless.prefix(5)
                            .map(\.name).joined(separator: ", ")
                     ])
    }

    // MARK: - Channel maps

    /// Parses ChannelMapSet from topology data to identify stereo-pair
    /// primaries and their invisible right-channel siblings. Same
    /// shape as `parseHTChannelMaps`, different attribute source.
    private func parseStereoChannelMaps(from groupData: [ZoneGroupData]) {
        var maps: [String: [(String, SpeakerChannel)]] = [:]
        for gd in groupData {
            for md in gd.members where !md.channelMapSet.isEmpty {
                var channelList: [(String, SpeakerChannel)] = []
                let pairs = md.channelMapSet.components(separatedBy: ";")
                for pair in pairs {
                    let parts = pair.components(separatedBy: ":")
                    guard parts.count == 2 else { continue }
                    let deviceID = parts[0]
                    let channelStr = parts[1]
                    if let channel = SpeakerChannel(rawValue: channelStr) {
                        channelList.append((deviceID, channel))
                    }
                }
                if !channelList.isEmpty {
                    // Key on the visible primary's UUID — stereo pairs
                    // are not always at the group coordinator (a stereo
                    // pair can be soft-grouped into a larger group).
                    maps[md.uuid] = channelList
                }
            }
        }
        if Self.serialise(stereoChannelMaps) != Self.serialise(maps) {
            publishTag("stereoChannel")
            stereoChannelMaps = maps
        }
    }

    /// Parses HTSatChanMapSet into surround/sub configurations. A 5.1 zone
    /// publishes four different values — the soundbar's complete map plus
    /// one partial view per satellite — so the merge is across all members;
    /// taking the first found hid the Surrounds tab (#78).
    private func parseHTChannelMaps(from groupData: [ZoneGroupData]) {
        // Start from what is known: payloads without the bonded-channel
        // attributes would otherwise publish an empty map and flicker every
        // home-theatre zone out of existence between refreshes.
        var maps = htSatChannelMaps
        var payloadReportedAnyMap = false
        for gd in groupData {
            // Format: "RINCON_xxx:LF,RF;RINCON_yyy:SW;RINCON_zzz:LR;RINCON_www:RR"
            let merged = HomeTheaterChannelMap.merge(
                memberMapSets: gd.members.map(\.htSatChanMapSet))
            if !merged.isEmpty {
                payloadReportedAnyMap = true
                maps[gd.coordinatorUUID] = merged
            }
        }
        // Only a payload that demonstrably carries the attributes can be
        // trusted to report un-bonding.
        if payloadReportedAnyMap {
            let reportedNoMap = groupData
                .filter { HomeTheaterChannelMap.merge(memberMapSets: $0.members.map(\.htSatChanMapSet)).isEmpty }
                .map(\.coordinatorUUID)
            for coordinatorID in reportedNoMap {
                maps.removeValue(forKey: coordinatorID)
            }
        }
        // Equality-gate the write — `parseHTChannelMaps` runs after every
        // topology refresh (per-speaker on a busy network), and `maps` is
        // usually identical to the existing value. An unconditional
        // assignment floods observers 10–20 ×/s during refresh storms —
        // visible as karaoke micro-stutter.
        if Self.serialise(htSatChannelMaps) != Self.serialise(maps) {
            publishTag("htChannel")
            htSatChannelMaps = maps
        }
    }

    /// Tuples aren't `Equatable`, so channel maps are compared by a stable
    /// serialisation. Shared by both parsers.
    private static func serialise(_ m: [String: [(String, SpeakerChannel)]]) -> String {
        m.keys.sorted().map { k in
            let pairs = (m[k] ?? []).map { "\($0.0):\($0.1.rawValue)" }.joined(separator: ",")
            return "\(k)=\(pairs)"
        }.joined(separator: "|")
    }
}
