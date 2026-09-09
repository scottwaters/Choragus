/// MCPTools.swift — The tools and resources the MCP endpoint offers.
///
/// Each tool is a name, a JSON-schema description and a handler that
/// runs on the main actor against `SonosManager`. Results are plain JSON
/// objects; the server wraps them as MCP content. The tools themselves
/// live in one file per area (`MCPTools+Playback`, `+Library`, `+Queue`,
/// `+Playlists`, `+History`, `+Builder`); this file holds the shared
/// types, argument access, encoders and the composed list.
import Foundation

struct MCPTool {
    let name: String
    let description: String
    let inputSchema: [String: Any]
    /// The token access level the tool needs; see `MCPScope`.
    let scope: MCPScope
    /// Removes or overwrites something the tool itself cannot restore:
    /// queue entries, playlist tracks, stored items. Replacing the queue
    /// to play something is not counted — the app keeps a queue history.
    /// Defaults to "takes a confirm flag".
    let destructive: Bool
    /// Shape of `structuredContent`, for clients that validate results.
    let outputSchema: [String: Any]?
    let run: @MainActor ([String: Any], ChoragusMCPServer) async throws -> [String: Any]

    init(name: String, description: String, inputSchema: [String: Any], scope: MCPScope = .control,
         destructive: Bool? = nil, outputSchema: [String: Any]? = nil,
         run: @escaping @MainActor ([String: Any], ChoragusMCPServer) async throws -> [String: Any]) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.scope = scope
        self.destructive = destructive ?? (((inputSchema["properties"] as? [String: Any])?["confirm"]) != nil)
        self.outputSchema = outputSchema
        self.run = run
    }

    var descriptor: [String: Any] {
        var out: [String: Any] = ["name": name, "description": description, "inputSchema": inputSchema,
                                  "annotations": ["readOnlyHint": scope == .readOnly, "destructiveHint": destructive,
                                                  "idempotentHint": scope == .readOnly]]
        if let outputSchema { out["outputSchema"] = outputSchema }
        return out
    }

    /// An object schema for results; extra keys stay allowed so a richer
    /// reply never fails validation.
    static func output(_ properties: [String: [String: Any]], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required, "additionalProperties": true]
    }
    static let itemOutput: [String: Any] = output(["id": ["type": "string"], "title": ["type": "string"], "artist": ["type": "string"],
                                                   "album": ["type": "string"], "kind": ["type": "string", "enum": ["track", "container", "station"]],
                                                   "container_id": ["type": "string"]], required: ["id", "title", "kind"])
    static let itemsOutput: [String: Any] = output(["items": ["type": "array", "items": itemOutput], "total": ["type": "integer"]], required: ["items"])
    static let okOutput: [String: Any] = output(["ok": ["type": "boolean"]], required: ["ok"])

    /// Every tool accepts `request_id`; a mutating call repeated with the
    /// same id returns the first result instead of running twice.
    static let requestID: [String: Any] = ["type": "string", "maxLength": 80,
                                           "description": "Optional idempotency key: repeating a call with the same request_id returns the first result instead of acting again"]

    static func schema(_ properties: [String: [String: Any]], required: [String] = [], oneOf: [[String]] = []) -> [String: Any] {
        var props = properties
        props["request_id"] = requestID
        var out: [String: Any] = ["type": "object", "properties": props, "required": required, "additionalProperties": false]
        if !oneOf.isEmpty { out["oneOf"] = oneOf.map { ["required": $0] } }
        return out
    }
    /// Text from speakers, services and files is capped before it reaches
    /// a model's context; nothing here needs more than this.
    static let textCap = 200
    static func cap(_ text: String) -> String { text.count > textCap ? String(text.prefix(textCap)) : text }
    static let room: [String: Any] = ["type": "string", "description": "Room or group name as shown in Sonos (any member room of a group works), or a coordinator id from list_rooms"]
    static let deviceID: [String: Any] = ["type": "string", "description": "Speaker id from list_devices"]
    static let playlistID: [String: Any] = ["type": "integer", "description": "id from list_playlists"]
    static let playlistRef: [String: Any] = ["type": "string", "description": "Playlist name (exact, case-insensitive) or id; alternative to playlist_id"]
    /// Both ways of naming a playlist; the handler requires one of them.
    static let playlistArgs: [String: [String: Any]] = ["playlist_id": playlistID, "playlist": playlistRef]
    static let playlistOneOf: [[String]] = [["playlist_id"], ["playlist"]]
    static let expectedRevision: [String: Any] = ["type": "integer", "minimum": 0,
                                                  "description": "The revision from get_queue; the edit is refused if the queue changed in any way since — order included"]
    static let expectedPlaylistTotal: [String: Any] = ["type": "integer", "minimum": 0,
                                                       "description": "The playlist's total from get_playlist_tracks; the edit is refused if the count changed since"]
    static let itemIDs: [String: Any] = ["type": "array", "items": ["type": "string"], "minItems": 1, "maxItems": 200,
                                         "description": "ids from search, browse_library, browse_media_server, search_radio, search_service or list_favorites"]
    static let expectedTotal: [String: Any] = ["type": "integer", "minimum": 0,
                                               "description": "The queue length you last read (total from get_queue); the edit is refused if the queue has changed size since"]
    static func string(_ description: String) -> [String: Any] { ["type": "string", "description": description] }
    static func integer(_ description: String, min: Int? = nil, max: Int? = nil) -> [String: Any] {
        var out: [String: Any] = ["type": "integer", "description": description]
        if let min { out["minimum"] = min }
        if let max { out["maximum"] = max }
        return out
    }
    static func boolean(_ description: String) -> [String: Any] { ["type": "boolean", "description": description] }
    static func choice(_ values: [String], _ description: String) -> [String: Any] {
        ["type": "string", "enum": values, "description": description]
    }

    static let all: [MCPTool] = playback + library + queue + playlists + history + alarms + builder

    static let roomOutput: [String: Any] = output([
        "id": ["type": "string"], "name": ["type": "string"], "coordinator_room": ["type": "string"],
        "rooms": ["type": "array", "items": ["type": "string"]], "state": ["type": "string"],
        "volume": ["type": ["integer", "null"]], "muted": ["type": "boolean"],
        "title": ["type": "string"], "artist": ["type": "string"], "station": ["type": "string"],
    ], required: ["id", "name", "rooms", "state"])
    static let nowPlayingOutput: [String: Any] = output([
        "room": ["type": "string"], "state": ["type": "string"], "title": ["type": "string"], "artist": ["type": "string"],
        "album": ["type": "string"], "station": ["type": "string"], "duration_seconds": ["type": "integer"],
        "position_seconds": ["type": "integer"], "queue_position": ["type": "integer"], "queue_size": ["type": "integer"],
    ], required: ["room", "state"])
    static let queueOutput: [String: Any] = output([
        "total": ["type": "integer"], "start": ["type": "integer"], "has_more": ["type": "boolean"],
        "items": ["type": "array", "items": output(["position": ["type": "integer"], "title": ["type": "string"],
                                                     "artist": ["type": "string"], "album": ["type": "string"]], required: ["position", "title"])],
    ], required: ["total", "items"])
}

struct MCPResource {
    let uri: String
    let name: String
    let description: String
    let read: @MainActor (ChoragusMCPServer) throws -> [String: Any]

    var descriptor: [String: Any] {
        ["uri": uri, "name": name, "description": description, "mimeType": "application/json"]
    }
}

// MARK: - Argument access

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) throws -> String {
        guard let value = self[key] as? String, !value.isEmpty else { throw MCPError.invalidParams("Missing \(key)") }
        return value
    }
    func optionalString(_ key: String) -> String? {
        guard let value = self[key] as? String, !value.isEmpty else { return nil }
        return value
    }
    func int(_ key: String, default fallback: Int? = nil) throws -> Int {
        if let value = self[key] as? Int { return value }
        if let value = self[key] as? Double { return Int(value) }
        if let fallback { return fallback }
        throw MCPError.invalidParams("Missing \(key)")
    }
    func optionalInt(_ key: String) -> Int? {
        if let value = self[key] as? Int { return value }
        if let value = self[key] as? Double { return Int(value) }
        return nil
    }
    func bool(_ key: String) throws -> Bool {
        guard let value = self[key] as? Bool else { throw MCPError.invalidParams("Missing \(key)") }
        return value
    }
    func optionalBool(_ key: String) -> Bool? { self[key] as? Bool }
    func stringArray(_ key: String) throws -> [String] {
        guard let value = self[key] as? [String], !value.isEmpty else { throw MCPError.invalidParams("Missing \(key)") }
        return value
    }
    func intArray(_ key: String) throws -> [Int] {
        let raw = self[key] as? [Any] ?? []
        let values = raw.compactMap { ($0 as? Int) ?? ($0 as? Double).map(Int.init) }
        guard !values.isEmpty else { throw MCPError.invalidParams("Missing \(key)") }
        return values
    }
    /// A 1...limit page size with a default.
    func limit(_ key: String = "limit", default fallback: Int, max cap: Int) -> Int {
        Swift.min(cap, Swift.max(1, optionalInt(key) ?? fallback))
    }
}

// MARK: - Encoders

@MainActor
enum Encode {
    static func group(_ group: SonosGroup, manager: SonosManager) -> [String: Any] {
        let volumes = group.members.compactMap { manager.deviceVolumes[$0.id] }
        let state = manager.groupTransportStates[group.coordinatorID] ?? .stopped
        var out: [String: Any] = [
            "id": group.coordinatorID,
            "name": MCPTool.cap(group.name),
            "coordinator_room": MCPTool.cap(group.coordinator?.roomName ?? ""),
            "rooms": group.members.map { MCPTool.cap($0.roomName) },
            "state": state.rawValue,
            "volume": volumes.isEmpty ? NSNull() : volumes.reduce(0, +) / volumes.count,
            "muted": group.members.allSatisfy { manager.deviceMutes[$0.id] == true },
        ]
        if let meta = manager.groupTrackMetadata[group.coordinatorID] {
            out["title"] = MCPTool.cap(meta.title)
            out["artist"] = MCPTool.cap(meta.artist)
            out["station"] = MCPTool.cap(meta.stationName)
        }
        return out
    }

    static func nowPlaying(_ group: SonosGroup, manager: SonosManager) -> [String: Any] {
        let state = manager.groupTransportStates[group.coordinatorID] ?? .stopped
        var out: [String: Any] = ["room": group.name, "state": state.rawValue]
        if let meta = manager.groupTrackMetadata[group.coordinatorID] {
            out["title"] = MCPTool.cap(meta.title)
            out["artist"] = MCPTool.cap(meta.artist)
            out["album"] = MCPTool.cap(meta.album)
            out["station"] = MCPTool.cap(meta.stationName)
            out["duration_seconds"] = Int(meta.duration)
            out["position_seconds"] = Int(meta.position)
            out["queue_position"] = meta.trackNumber
            out["queue_size"] = meta.queueSize
            out["from_queue"] = meta.isQueueSource
        }
        return out
    }

    static func device(_ device: SonosDevice, manager: SonosManager) -> [String: Any] {
        [
            "id": device.id,
            "room": device.roomName,
            "model": device.modelName,
            "ip": device.ip,
            "system": device.swGen.isEmpty ? "unknown" : "S\(device.swGen)",
            "household": device.householdID ?? "",
            "coordinator": device.isCoordinator,
            "volume": manager.deviceVolumes[device.id] ?? NSNull(),
            "muted": manager.deviceMutes[device.id] ?? false,
        ]
    }

    static func item(_ item: BrowseItem) -> [String: Any] {
        var out: [String: Any] = [
            "id": item.id.uuidString,
            "title": MCPTool.cap(item.title),
            "artist": MCPTool.cap(item.artist),
            "album": MCPTool.cap(item.album),
            // Stations first: a radio station is a "container" class in
            // DIDL terms but plays directly, so it must not read as browsable.
            "kind": item.isStation ? "station" : (item.isContainer ? "container" : "track"),
        ]
        if item.isContainer, !item.isStation { out["container_id"] = item.objectID }
        if let year = item.releaseYear { out["year"] = year }
        return out
    }

    static func queueItem(_ item: QueueItem) -> [String: Any] {
        ["position": item.id, "title": MCPTool.cap(item.title), "artist": MCPTool.cap(item.artist),
         "album": MCPTool.cap(item.album), "duration": item.duration]
    }

    static func track(_ item: QueueItem) -> [String: Any] {
        ["title": MCPTool.cap(item.title), "artist": MCPTool.cap(item.artist), "album": MCPTool.cap(item.album), "duration": item.duration]
    }

    static func playlist(_ queue: LocalSavedQueue, folder: String) -> [String: Any] {
        ["id": queue.id, "name": queue.name, "folder": folder, "tracks": queue.trackCount]
    }

    static func preset(_ preset: GroupPreset, manager: SonosManager) -> [String: Any] {
        var out: [String: Any] = [
            "id": preset.id.uuidString,
            "name": MCPTool.cap(preset.name),
            "coordinator_room": manager.devices[preset.coordinatorDeviceID]?.roomName ?? preset.coordinatorDeviceID,
            "includes_eq": preset.includesEQ,
            "members": preset.members.map { member -> [String: Any] in
                var row: [String: Any] = ["room": manager.devices[member.deviceID]?.roomName ?? member.deviceID,
                                          "device_id": member.deviceID, "volume": member.volume]
                if let eq = member.eq { row["eq"] = ["bass": eq.bass, "treble": eq.treble, "loudness": eq.loudness] }
                return row
            },
        ]
        if let ht = preset.homeTheaterEQ {
            out["home_theater_eq"] = [
                "night_mode": ht.nightMode, "speech_enhancement": ht.dialogLevel,
                "sub_enabled": ht.subEnabled, "sub_gain": ht.subGain,
                "sub_polarity": ht.subPolarity ? "inverted" : "normal",
                "surround_enabled": ht.surroundEnabled, "surround_level": ht.surroundLevel,
                "music_surround_level": ht.musicSurroundLevel,
                "surround_mode": ht.surroundMode == 1 ? "full" : "ambient",
            ]
        }
        return out
    }

    static func queueSnapshot(_ snapshot: QueueSnapshot) -> [String: Any] {
        ["id": snapshot.localID, "saved_at": ISO8601DateFormatter().string(from: snapshot.savedAt),
         "tracks": snapshot.trackCount, "summary": MCPTool.cap(snapshot.summary)]
    }

    static func historyEntry(_ entry: PlayHistoryEntry) -> [String: Any] {
        [
            "id": entry.id.uuidString,
            "title": MCPTool.cap(entry.title),
            "artist": MCPTool.cap(entry.artist),
            "album": MCPTool.cap(entry.album),
            "station": MCPTool.cap(entry.stationName),
            "room": MCPTool.cap(entry.groupName),
            "played_at": ISO8601DateFormatter().string(from: entry.timestamp),
            "starred": entry.starred,
        ]
    }
}

// MARK: - Resources

extension MCPResource {
    static let all: [MCPResource] = [
        MCPResource(uri: "choragus://rooms", name: "Rooms",
                    description: "Rooms and groups with state and volume.") { server in
            let manager = try server.manager
            return ["rooms": manager.groups.map { Encode.group($0, manager: manager) }]
        },
        MCPResource(uri: "choragus://now-playing", name: "Now playing",
                    description: "What every room is playing.") { server in
            let manager = try server.manager
            return ["rooms": manager.groups.map { Encode.nowPlaying($0, manager: manager) }]
        },
        MCPResource(uri: "choragus://playlists", name: "Choragus playlists",
                    description: "Choragus playlists with their folder paths.") { server in
            ["playlists": try server.playlistRows()]
        },
    ]
}
