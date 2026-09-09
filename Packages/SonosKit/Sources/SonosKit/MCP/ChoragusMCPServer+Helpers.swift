/// ChoragusMCPServer+Helpers.swift — Lookups shared by the tool files:
/// rooms, speakers, cached items, playlists and the matching service
/// for the playlist builder.
import Foundation

extension ChoragusMCPServer {

    /// A speaker by id or room name, resolved to the unit that takes the
    /// setting: the primary of a stereo pair, the soundbar of a
    /// home-theatre set. Naming the right-hand half, a Sub or a surround
    /// lands on its primary instead of failing, because Sonos applies
    /// EQ, alarms and inputs through that unit.
    func device(_ needle: String) throws -> SonosDevice {
        let manager = try manager
        let key = needle.trimmingCharacters(in: .whitespaces).lowercased()
        if let exact = manager.devices[needle] ?? manager.devices.values.first(where: { $0.id.lowercased() == key }) {
            return primaryDevice(for: exact)
        }
        // Visible group members are the bonded-set primaries; prefer them.
        let visible = manager.groups.flatMap(\.members)
        if let primary = visible.first(where: { $0.roomName.lowercased() == key }) { return primary }
        let hidden = manager.devices.values.filter { $0.roomName.lowercased() == key && !$0.id.hasSuffix("_MR") }
        if let any = hidden.first { return primaryDevice(for: any) }
        throw MCPError.invalidParams("No speaker or room named \(needle); see list_devices")
    }

    /// The bonded-set primary for any member id; a device that is not in
    /// a bonded set is its own primary.
    func primaryDevice(for device: SonosDevice) -> SonosDevice {
        guard let manager = SonosManager.current else { return device }
        let id = device.id.hasSuffix("_MR") ? String(device.id.dropLast(3)) : device.id
        if manager.groups.contains(where: { $0.members.contains { $0.id == id } }) { return manager.devices[id] ?? device }
        for maps in [manager.stereoChannelMaps, manager.htSatChannelMaps] {
            for (primaryID, members) in maps where members.contains(where: { $0.0 == id }) {
                if let primary = manager.devices[primaryID] { return primary }
            }
        }
        return device
    }

    /// Cached items for ids handed out by a search or browse tool.
    func items(_ ids: [String]) throws -> [BrowseItem] {
        try ids.map { id in
            guard let item = itemCache[id] else { throw MCPError.invalidParams("Unknown item id \(id); search or browse first") }
            return item
        }
    }

    func playlist(_ id: Int) throws -> LocalSavedQueue {
        guard let queue = try manager.localSavedQueues().first(where: { $0.id == Int64(id) }) else {
            throw MCPError.invalidParams("Unknown playlist_id")
        }
        return queue
    }

    /// The playlist named by `playlist_id`, or by `playlist` as a name or id.
    func playlist(_ args: [String: Any]) throws -> LocalSavedQueue {
        if let id = args.optionalInt("playlist_id") { return try playlist(id) }
        guard let ref = args.optionalString("playlist") else { throw MCPError.invalidParams("Pass playlist_id or playlist") }
        if let id = Int(ref) { return try playlist(id) }
        let live = try manager.localSavedQueues().filter { $0.deletedAt == nil }
        let matches = live.filter { $0.name.caseInsensitiveCompare(ref) == .orderedSame }
        guard let first = matches.first else { throw MCPError.invalidParams("No playlist named \(ref)") }
        guard matches.count == 1 else { throw MCPError.invalidParams("\(matches.count) playlists are named \(ref); pass playlist_id") }
        return first
    }

    /// Playlist names are unique for agents: a live playlist with `name`
    /// makes a save fail unless `replace` is set, in which case its id is
    /// returned so the caller overwrites it in place.
    func existingPlaylist(named name: String, replace: Bool) throws -> LocalSavedQueue? {
        let live = try manager.localSavedQueues().filter { $0.deletedAt == nil }
        guard let existing = live.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return nil }
        guard replace else {
            throw MCPError.invalidParams("A playlist named \(existing.name) already exists (id \(existing.id)); pass replace=true to overwrite it or choose another name")
        }
        return existing
    }

    /// Every live playlist with its folder path, top level first.
    func playlistRows() throws -> [[String: Any]] {
        let tree = try manager.savedQueueTree()
        var rows: [[String: Any]] = tree.queues.map { Encode.playlist($0, folder: "") }
        func walk(_ nodes: [SavedQueueTree.Node], _ path: String) {
            for node in nodes {
                let here = path.isEmpty ? node.folder.name : "\(path)/\(node.folder.name)"
                rows += node.queues.map { Encode.playlist($0, folder: here) }
                walk(node.folders, here)
            }
        }
        walk(tree.folders, "")
        return rows
    }

    /// A Sonos-side playlist (`SQ:`) by name or object id.
    func sonosPlaylist(_ needle: String) async throws -> BrowseItem {
        let key = needle.trimmingCharacters(in: .whitespaces).lowercased()
        let result = try await manager.browse(objectID: BrowseID.playlists, householdID: nil, count: 200)
        let matches = result.items.filter { $0.objectID.lowercased() == key || $0.title.lowercased() == key }
        guard let first = matches.first else { throw MCPError.invalidParams("No Sonos playlist named \(needle)") }
        guard matches.count == 1 else { throw MCPError.invalidParams("\(matches.count) Sonos playlists are named \(needle); pass its id") }
        return first
    }

    func mediaServer(_ needle: String) throws -> MediaServer {
        let key = needle.trimmingCharacters(in: .whitespaces).lowercased()
        guard let server = try manager.mediaServers.first(where: {
            $0.id.lowercased() == key || $0.name.lowercased() == key || $0.advertisedName.lowercased() == key
        }) else {
            throw MCPError.invalidParams("No media server \(needle); see list_media_servers")
        }
        return server
    }

    var smapi: SMAPIAuthManager {
        get throws {
            guard let smapi = SMAPIAuthManager.current else { throw MCPError.internal("Music services unavailable") }
            return smapi
        }
    }

    /// An authenticated streaming service by name.
    func musicService(_ needle: String) throws -> SMAPIServiceDescriptor {
        let key = needle.trimmingCharacters(in: .whitespaces).lowercased()
        guard let service = try smapi.authenticatedServiceList.first(where: { $0.name.lowercased() == key }) else {
            throw MCPError.invalidParams("\(needle) is not a signed-in music service; see list_music_services")
        }
        return service
    }

    var appleMusicSerial: Int {
        get throws {
            let sid = MusicServiceCatalog.shared.sid(forName: ServiceName.appleMusic) ?? ServiceID.appleMusic
            return try smapi.serialNumber(for: sid)
        }
    }

    /// Where the playlist builder matches songs. `library` is the Sonos
    /// music library, `apple_music` the household's Apple Music, any
    /// other value a signed-in service name or a media server name.
    func resolveService(_ name: String) throws -> (service: PlaylistResolveService, label: String) {
        let manager = try manager
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        switch key {
        case "library", "local", "local_library", "sonos_library":
            return (.localLibrary(search: { [weak manager] term in
                (try? await manager?.search(query: term, householdID: nil, count: 15))?.items ?? []
            }), "library")
        case "apple_music", "apple music":
            return (.appleMusic(sn: try appleMusicSerial), "apple_music")
        default:
            if let server = manager.mediaServers.first(where: { $0.id.lowercased() == key || $0.name.lowercased() == key }) {
                return (.mediaServer(search: { term in
                    await MediaServerService.search(server: server, term: term)
                }), server.name)
            }
            let smapi = try smapi
            let service = try musicService(name)
            guard let token = smapi.tokenStore.getToken(for: service.id) else {
                throw MCPError.invalidParams("\(service.name) has no stored sign-in")
            }
            return (.smapi(serviceID: service.id, serviceURI: service.secureUri, token: token,
                           sn: smapi.serialNumber(for: service.id)), service.name)
        }
    }

    /// Refuses a positional edit when `expected_total` was given and the
    /// queue no longer has that many tracks. Returns the current length
    /// when it was read.
    @discardableResult
    func checkQueueRevision(_ group: SonosGroup, _ args: [String: Any]) async throws -> Int? {
        let manager = try manager
        if let expectedRevision = args.optionalInt("expected_revision") {
            let revision = try await manager.queue.queueRevision(group: group)
            guard revision == expectedRevision else {
                throw MCPError.invalidParams("Queue revision is \(revision), not \(expectedRevision); the queue changed — read get_queue again before editing by position")
            }
        }
        guard let expected = args.optionalInt("expected_total") else { return nil }
        guard let coordinator = group.coordinator else { throw MCPError.internal("Room has no coordinator") }
        let total = try await manager.queue.readFullQueue(device: coordinator).count
        guard total == expected else {
            throw MCPError.invalidParams("Queue has \(total) tracks, not \(expected); read get_queue again before editing by position")
        }
        return total
    }

    /// Length and revision of a room's queue, for results that follow an edit.
    func queueState(_ group: SonosGroup) async -> [String: Any] {
        guard let manager = SonosManager.current, let coordinator = group.coordinator else { return [:] }
        var out: [String: Any] = [:]
        if let total = try? await manager.queue.readFullQueue(device: coordinator).count { out["remaining"] = total }
        if let revision = try? await manager.queue.queueRevision(group: group) { out["revision"] = revision }
        return out
    }

    /// Removes the queue rows a build added and the playlist it created.
    /// Queue removal is refused when the queue length no longer matches
    /// what the job left behind, since positions would then be wrong.
    func undoBuild(_ job: MCPBuildJobs.Job) async throws -> [String: Any] {
        let manager = try manager
        var out: [String: Any] = ["ok": true, "job_id": job.id]
        if let coordinatorID = buildRooms[job.id], let group = manager.groups.first(where: { $0.coordinatorID == coordinatorID }),
           let coordinator = group.coordinator, !job.queuedPositions.isEmpty {
            let total = try await manager.queue.readFullQueue(device: coordinator).count
            let expected = job.queuedPositions.max() ?? 0
            if total >= expected {
                for position in Set(job.queuedPositions).sorted(by: >) {
                    try await manager.queue.removeFromQueue(group: group, trackIndex: position)
                }
                out["removed_from_queue"] = job.queuedPositions.count
            } else {
                out["removed_from_queue"] = 0
                out["queue_note"] = "Queue changed since the build; its tracks were left in place"
            }
        }
        if buildCreatedPlaylist[job.id] == true, let id = job.playlistID {
            manager.deleteLocalSavedQueue(id: id)
            out["deleted_playlist_id"] = id
        }
        buildCreatedPlaylist[job.id] = false
        return out
    }

    /// Every EQ value the speaker answers for; a unit without a Sub or
    /// surrounds simply omits those keys.
    func eqSnapshot(_ device: SonosDevice) async -> [String: Any] {
        guard let manager = SonosManager.current else { return [:] }
        var out: [String: Any] = ["room": device.roomName, "device_id": device.id]
        if let bass = try? await manager.eq.getBass(device: device) { out["bass"] = bass }
        if let treble = try? await manager.eq.getTreble(device: device) { out["treble"] = treble }
        if let loudness = try? await manager.eq.getLoudness(device: device) { out["loudness"] = loudness }
        // Only a soundbar answers the home-theatre types; asking anything
        // else earns a UPnP 402 per call and fills the diagnostics log.
        let isHomeTheater = PhysicalInput.kind(forModelName: device.modelName) == .tv
            || manager.htSatChannelMaps[device.id] != nil
        guard isHomeTheater else { return out }
        for (type, key) in [("NightMode", "night_mode"), ("DialogLevel", "speech_enhancement"),
                            ("SubEnable", "sub_enabled"), ("SurroundEnable", "surround_enabled")] {
            if let value = try? await manager.eq.getEQ(device: device, eqType: type) { out[key] = value == 1 }
        }
        if let gain = try? await manager.eq.getEQ(device: device, eqType: "SubGain") { out["sub_gain"] = gain }
        if let polarity = try? await manager.eq.getEQ(device: device, eqType: "SubPolarity") {
            out["sub_polarity"] = polarity == 1 ? "inverted" : "normal"
        }
        if let level = try? await manager.eq.getEQ(device: device, eqType: "SurroundLevel") { out["surround_level"] = level }
        if let level = try? await manager.eq.getEQ(device: device, eqType: "MusicSurroundLevel") { out["music_surround_level"] = level }
        if let mode = try? await manager.eq.getEQ(device: device, eqType: "SurroundMode") {
            out["surround_mode"] = mode == 1 ? "full" : "ambient"
        }
        return out
    }

    // MARK: Grouping snapshots

    /// Records the current groups and returns the snapshot's id.
    func saveGroupingSnapshot() throws -> MCPGroupingSnapshot {
        let manager = try manager
        let snapshot = MCPGroupingSnapshot(groups: manager.groups.map { group in
            MCPGroupingSnapshot.Group(coordinatorID: group.coordinatorID,
                                      memberIDs: group.members.map(\.id),
                                      rooms: group.members.map(\.roomName))
        })
        groupingSnapshots[snapshot.id] = snapshot
        groupingSnapshotOrder.append(snapshot.id)
        while groupingSnapshotOrder.count > 10 {
            groupingSnapshots.removeValue(forKey: groupingSnapshotOrder.removeFirst())
        }
        return snapshot
    }

    /// Puts every room back into the group it had in `snapshot`: members
    /// rejoin their old coordinator, rooms that were alone leave whatever
    /// group they are in now. Unknown speakers are skipped and reported.
    func restoreGrouping(_ snapshot: MCPGroupingSnapshot) async throws -> (restored: [String], skipped: [String]) {
        let manager = try manager
        var restored: [String] = []
        var skipped: [String] = []
        for saved in snapshot.groups {
            guard let coordinator = manager.devices[saved.coordinatorID] else { skipped += saved.rooms; continue }
            if saved.memberIDs.count == 1 {
                let current = manager.groups.first { $0.members.contains { $0.id == coordinator.id } }
                if let current, current.members.count > 1 {
                    try await manager.ungroupDevice(coordinator)
                    restored.append(coordinator.roomName)
                }
                continue
            }
            for memberID in saved.memberIDs where memberID != saved.coordinatorID {
                guard let member = manager.devices[memberID] else { skipped.append(memberID); continue }
                let already = manager.groups.first { $0.coordinatorID == saved.coordinatorID }?.members.contains { $0.id == memberID } ?? false
                if !already {
                    try await manager.joinGroup(device: member, toCoordinator: coordinator)
                }
                restored.append(member.roomName)
            }
        }
        return (restored, skipped)
    }

    /// Names `resolveService` accepts right now.
    func matchServiceNames() -> [String] {
        var names = ["library", "apple_music"]
        if let manager = SonosManager.current {
            names += manager.mediaServers.map(\.name)
        }
        if let smapi = SMAPIAuthManager.current {
            names += smapi.authenticatedServiceList.map(\.name).filter { $0 != ServiceName.appleMusic }
        }
        return names
    }
}
