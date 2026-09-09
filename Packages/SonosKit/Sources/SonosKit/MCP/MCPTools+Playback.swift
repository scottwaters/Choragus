/// MCPTools+Playback.swift — Rooms, transport, volume, play mode,
/// speakers, grouping, presets and inputs.
import Foundation

extension MCPTool {
    static let playback: [MCPTool] = [
        MCPTool(name: "list_rooms",
                description: "list_rooms: every room, zone, speaker group and what it is playing — state, volume, mute, coordinator room, current title and artist. Start here; the names it returns are what other tools take as room.",
                inputSchema: schema([:]), scope: .readOnly,
                outputSchema: output(["rooms": ["type": "array", "items": roomOutput]], required: ["rooms"])) { _, server in
            let manager = try server.manager
            return ["rooms": manager.groups.map { Encode.group($0, manager: manager) }]
        },
        MCPTool(name: "now_playing",
                description: "now_playing: the current track in one room — title, artist, album, station, position, duration, queue position.",
                inputSchema: schema(["room": room], required: ["room"]), scope: .readOnly, outputSchema: nowPlayingOutput) { args, server in
            let group = try server.group(named: try args.string("room"))
            return Encode.nowPlaying(group, manager: try server.manager)
        },
        MCPTool(name: "play", description: "Resume playback in a room.",
                inputSchema: schema(["room": room], required: ["room"])) { args, server in
            let group = try server.group(named: try args.string("room"))
            try await server.manager.play(group: group)
            return ["ok": true]
        },
        MCPTool(name: "pause", description: "Pause playback in a room.",
                inputSchema: schema(["room": room], required: ["room"])) { args, server in
            let group = try server.group(named: try args.string("room"))
            try await server.manager.pause(group: group)
            return ["ok": true]
        },
        MCPTool(name: "stop", description: "Stop playback in a room (drops the stream; use pause to keep position).",
                inputSchema: schema(["room": room], required: ["room"])) { args, server in
            let group = try server.group(named: try args.string("room"))
            try await server.manager.stop(group: group)
            return ["ok": true]
        },
        MCPTool(name: "next", description: "Skip to the next track.",
                inputSchema: schema(["room": room], required: ["room"])) { args, server in
            let group = try server.group(named: try args.string("room"))
            try await server.manager.next(group: group)
            return ["ok": true]
        },
        MCPTool(name: "previous", description: "Go back to the previous track.",
                inputSchema: schema(["room": room], required: ["room"])) { args, server in
            let group = try server.group(named: try args.string("room"))
            try await server.manager.previous(group: group)
            return ["ok": true]
        },
        MCPTool(name: "seek", description: "seek: jump to a position in the current track, absolute (seconds) or relative (delta_seconds, e.g. -15 to skip back). Clamped to the track length.",
                inputSchema: schema(["room": room,
                                     "seconds": integer("Position from the start", min: 0),
                                     "delta_seconds": integer("Move relative to the current position", min: -36000, max: 36000)],
                                    required: ["room"], oneOf: [["seconds"], ["delta_seconds"]])) { args, server in
            let manager = try server.manager
            let group = try server.group(named: try args.string("room"))
            let meta = manager.groupTrackMetadata[group.coordinatorID]
            var target: Int
            if let absolute = args.optionalInt("seconds") {
                target = absolute
            } else if let delta = args.optionalInt("delta_seconds") {
                target = Int(meta?.position ?? 0) + delta
            } else {
                throw MCPError.invalidParams("Pass seconds or delta_seconds")
            }
            target = max(0, target)
            if let duration = meta?.duration, duration > 0 { target = min(target, Int(duration)) }
            try await manager.seek(group: group, to: PlaybackTimeFormat.string(seconds: target))
            return ["ok": true, "position_seconds": target, "duration_seconds": Int(meta?.duration ?? 0)]
        },
        MCPTool(name: "pause_all", description: "Pause every room.", inputSchema: schema([:])) { _, server in
            await (try server.manager).pauseAll()
            return ["ok": true]
        },
        MCPTool(name: "resume_all", description: "Resume every room that was paused by pause_all.",
                inputSchema: schema([:])) { _, server in
            await (try server.manager).resumeAll()
            return ["ok": true]
        },

        // MARK: Volume

        MCPTool(name: "set_volume", description: "set_volume: set the volume / loudness of every speaker in a room to an absolute level (0-100). Use adjust_volume for louder / quieter by a step.",
                inputSchema: schema(["room": room, "level": integer("0-100", min: 0, max: 100)],
                                    required: ["room", "level"])) { args, server in
            let manager = try server.manager
            let group = try server.group(named: try args.string("room"))
            let level = server.cappedVolume(try args.int("level"))
            for member in group.members where !manager.isOutputFixed(member.id) {
                try await manager.setVolume(device: member, volume: level)
            }
            var out: [String: Any] = ["ok": true, "level": level, "max_level": server.maxVolume]
            // A Connect or Port set to fixed line-out ignores volume; say so
            // rather than reporting a change that did not happen.
            let fixed = group.members.filter { manager.isOutputFixed($0.id) }.map(\.roomName)
            if !fixed.isEmpty { out["fixed_output"] = fixed }
            return out
        },
        MCPTool(name: "adjust_volume", description: "Nudge every speaker in a room up or down by a number of steps.",
                inputSchema: schema(["room": room, "delta": integer("-100 to 100, e.g. -5", min: -100, max: 100)],
                                    required: ["room", "delta"])) { args, server in
            let manager = try server.manager
            let group = try server.group(named: try args.string("room"))
            let delta = min(100, max(-100, try args.int("delta")))
            var levels: [[String: Any]] = []
            for member in group.members {
                let current = try await manager.getVolume(device: member)
                let level = server.cappedVolume(current + delta)
                try await manager.setVolume(device: member, volume: level)
                levels.append(["room": member.roomName, "level": level])
            }
            return ["ok": true, "speakers": levels, "max_level": server.maxVolume]
        },
        MCPTool(name: "set_group_volume",
                description: "Move a group's overall level while keeping each speaker's relative loudness (like the app's master slider). Single rooms behave like set_volume.",
                inputSchema: schema(["room": room, "level": integer("0-100 master level", min: 0, max: 100)],
                                    required: ["room", "level"])) { args, server in
            let manager = try server.manager
            let group = try server.group(named: try args.string("room"))
            let level = server.cappedVolume(try args.int("level"))
            let current = group.members.compactMap { manager.deviceVolumes[$0.id] }
            let master = current.isEmpty ? Double(level) : Double(current.reduce(0, +)) / Double(current.count)
            let snapshot = GroupVolumeDistribution.Snapshot(
                master: master,
                volumes: Dictionary(uniqueKeysWithValues: group.members.map { ($0.id, Double(manager.deviceVolumes[$0.id] ?? Int(master))) }))
            let targets = GroupVolumeDistribution.targets(master: Double(level), memberIDs: group.members.map(\.id),
                                                          snapshot: snapshot, mode: .proportional)
            for member in group.members {
                try await manager.setVolume(device: member, volume: targets[member.id] ?? level)
            }
            return ["ok": true, "speakers": group.members.map { ["room": $0.roomName, "level": targets[$0.id] ?? level] }]
        },
        MCPTool(name: "set_mute", description: "Mute or unmute a room.",
                inputSchema: schema(["room": room, "muted": boolean("")], required: ["room", "muted"])) { args, server in
            let group = try server.group(named: try args.string("room"))
            let muted = try args.bool("muted")
            for member in group.members { try await server.manager.setMute(device: member, muted: muted) }
            return ["ok": true]
        },

        // MARK: Play mode

        MCPTool(name: "get_play_mode", description: "Shuffle, repeat, crossfade and sleep timer for a room.",
                inputSchema: schema(["room": room], required: ["room"]), scope: .readOnly) { args, server in
            let manager = try server.manager
            let group = try server.group(named: try args.string("room"))
            let mode = try await manager.getPlayMode(group: group)
            let crossfade = (try? await manager.getCrossfadeMode(group: group)) ?? false
            let sleep = (try? await manager.getSleepTimerRemaining(group: group)) ?? ""
            return ["shuffle": mode.isShuffled, "repeat": Self.repeatName(mode.repeatMode),
                    "crossfade": crossfade, "sleep_timer_remaining": sleep.isEmpty ? NSNull() : sleep]
        },
        MCPTool(name: "set_shuffle", description: "Turn shuffle on or off; repeat is kept.",
                inputSchema: schema(["room": room, "on": boolean("")], required: ["room", "on"])) { args, server in
            let manager = try server.manager
            let group = try server.group(named: try args.string("room"))
            let current = try await manager.getPlayMode(group: group)
            let wanted = try args.bool("on")
            if current.isShuffled != wanted { try await manager.setPlayMode(group: group, mode: current.togglingShuffle()) }
            return ["ok": true]
        },
        MCPTool(name: "set_repeat", description: "Repeat off, all or one; shuffle is kept.",
                inputSchema: schema(["room": room, "mode": choice(["off", "all", "one"], "")], required: ["room", "mode"])) { args, server in
            let manager = try server.manager
            let group = try server.group(named: try args.string("room"))
            let current = try await manager.getPlayMode(group: group)
            let mode: PlayMode
            switch try args.string("mode") {
            case "all": mode = current.isShuffled ? .shuffle : .repeatAll
            case "one": mode = current.isShuffled ? .shuffleRepeatOne : .repeatOne
            default: mode = current.isShuffled ? .shuffleNoRepeat : .normal
            }
            try await manager.setPlayMode(group: group, mode: mode)
            return ["ok": true]
        },
        MCPTool(name: "set_crossfade", description: "Turn crossfade on or off.",
                inputSchema: schema(["room": room, "on": boolean("")], required: ["room", "on"])) { args, server in
            let group = try server.group(named: try args.string("room"))
            try await server.manager.setCrossfadeMode(group: group, enabled: try args.bool("on"))
            return ["ok": true]
        },
        MCPTool(name: "set_sleep_timer", description: "Stop playback after a number of minutes.",
                inputSchema: schema(["room": room, "minutes": integer("1-1439", min: 1, max: 1439)],
                                    required: ["room", "minutes"])) { args, server in
            let group = try server.group(named: try args.string("room"))
            let minutes = min(1439, max(1, try args.int("minutes")))
            let duration = String(format: "%02d:%02d:00", minutes / 60, minutes % 60)
            try await server.manager.setSleepTimer(group: group, duration: duration)
            return ["ok": true, "duration": duration]
        },
        MCPTool(name: "cancel_sleep_timer", description: "Cancel the room's sleep timer.",
                inputSchema: schema(["room": room], required: ["room"])) { args, server in
            let group = try server.group(named: try args.string("room"))
            try await server.manager.cancelSleepTimer(group: group)
            return ["ok": true]
        },

        // MARK: Speakers

        MCPTool(name: "list_devices", description: "list_devices: every physical speaker / player / device — id, room, model, IP, system generation, volume. Rooms are the unit for playback; devices are for per-speaker volume and EQ.",
                inputSchema: schema([:]), scope: .readOnly) { _, server in
            let manager = try server.manager
            let devices = manager.devices.values.filter { !$0.id.hasSuffix("_MR") }
                .sorted { $0.roomName.localizedCaseInsensitiveCompare($1.roomName) == .orderedAscending }
            return ["devices": devices.map { Encode.device($0, manager: manager) }]
        },
        MCPTool(name: "set_speaker_volume", description: "set_speaker_volume: set one speaker's level (0-100), leaving the rest of its group alone. Address it by room or device_id; a pair half or surround resolves to its primary.",
                inputSchema: schema(["device_id": deviceID, "room": string("Room name; alternative to device_id"),
                                     "level": integer("0-100", min: 0, max: 100)],
                                    required: ["level"], oneOf: [["device_id"], ["room"]])) { args, server in
            let manager = try server.manager
            let device = try server.device(args.optionalString("device_id") ?? (try args.string("room")))
            guard !manager.isOutputFixed(device.id) else {
                throw MCPError.invalidParams("\(device.roomName) has a fixed line-out; its level is set on the amplifier it feeds, not on the speaker")
            }
            let level = server.cappedVolume(try args.int("level"))
            try await manager.setVolume(device: device, volume: level)
            return ["ok": true, "room": device.roomName, "level": level, "max_level": server.maxVolume]
        },
        MCPTool(name: "get_speaker_eq", description: "get_speaker_eq: a speaker's EQ — bass, treble, loudness — and, on a home-theatre set, night mode, speech enhancement (dialog), sub (enabled, gain, polarity) and surrounds (enabled, TV level, music level, ambient or full). Name it by room or device_id; a stereo pair or home-theatre set answers through its primary.",
                inputSchema: schema(["device_id": deviceID, "room": string("Room name; alternative to device_id")],
                                    oneOf: [["device_id"], ["room"]]), scope: .readOnly) { args, server in
            let device = try server.device(args.optionalString("device_id") ?? (try args.string("room")))
            return await server.eqSnapshot(device)
        },
        MCPTool(name: "set_speaker_eq",
                description: "set_speaker_eq: change EQ on a speaker. Absolute bass / treble, or relative bass_delta / treble_delta (e.g. 2 for more bass), loudness, and reset (bass 0, treble 0, loudness on). On a home-theatre set also night_mode, speech_enhancement, sub_enabled, sub_gain, sub_polarity, surround_enabled, surround_level (TV), music_surround_level and surround_mode (ambient or full). Name the speaker by room or device_id; a pair half, Sub or surround resolves to its primary, which is the unit Sonos applies EQ through.",
                inputSchema: schema([
                    "device_id": deviceID,
                    "room": string("Room name; alternative to device_id"),
                    "bass": integer("-10 to 10", min: -10, max: 10),
                    "treble": integer("-10 to 10", min: -10, max: 10),
                    "bass_delta": integer("Step from the current value", min: -20, max: 20),
                    "treble_delta": integer("Step from the current value", min: -20, max: 20),
                    "loudness": boolean(""),
                    "reset": boolean("Bass 0, treble 0, loudness on"),
                    "night_mode": boolean("Home theatre only"),
                    "speech_enhancement": boolean("Home theatre only"),
                    "sub_enabled": boolean("Home theatre with a Sub"),
                    "sub_gain": integer("-15 to 15", min: -15, max: 15),
                    "sub_polarity": choice(["normal", "inverted"], "Home theatre with a Sub"),
                    "surround_enabled": boolean("Home theatre with surrounds"),
                    "surround_level": integer("TV level, -15 to 15", min: -15, max: 15),
                    "music_surround_level": integer("Music level, -15 to 15", min: -15, max: 15),
                    "surround_mode": choice(["ambient", "full"], "How surrounds play music"),
                ], oneOf: [["device_id"], ["room"]])) { args, server in
            let manager = try server.manager
            let device = try server.device(args.optionalString("device_id") ?? (try args.string("room")))
            var changed: [String] = []
            func setEQ(_ type: String, _ value: Int, _ label: String) async throws {
                try await manager.eq.setEQ(device: device, eqType: type, value: value)
                changed.append(label)
            }
            if args.optionalBool("reset") == true {
                try await manager.eq.setBass(device: device, bass: 0)
                try await manager.eq.setTreble(device: device, treble: 0)
                try await manager.eq.setLoudness(device: device, enabled: true)
                changed.append("reset")
            }
            if let bass = args.optionalInt("bass") {
                try await manager.eq.setBass(device: device, bass: min(10, max(-10, bass)))
                changed.append("bass")
            } else if let delta = args.optionalInt("bass_delta") {
                let current = try await manager.eq.getBass(device: device)
                try await manager.eq.setBass(device: device, bass: min(10, max(-10, current + delta)))
                changed.append("bass")
            }
            if let treble = args.optionalInt("treble") {
                try await manager.eq.setTreble(device: device, treble: min(10, max(-10, treble)))
                changed.append("treble")
            } else if let delta = args.optionalInt("treble_delta") {
                let current = try await manager.eq.getTreble(device: device)
                try await manager.eq.setTreble(device: device, treble: min(10, max(-10, current + delta)))
                changed.append("treble")
            }
            if let loudness = args.optionalBool("loudness") {
                try await manager.eq.setLoudness(device: device, enabled: loudness)
                changed.append("loudness")
            }
            if let on = args.optionalBool("night_mode") { try await setEQ("NightMode", on ? 1 : 0, "night_mode") }
            if let on = args.optionalBool("speech_enhancement") { try await setEQ("DialogLevel", on ? 1 : 0, "speech_enhancement") }
            if let on = args.optionalBool("sub_enabled") { try await setEQ("SubEnable", on ? 1 : 0, "sub_enabled") }
            if let gain = args.optionalInt("sub_gain") { try await setEQ("SubGain", min(15, max(-15, gain)), "sub_gain") }
            if let polarity = args.optionalString("sub_polarity") { try await setEQ("SubPolarity", polarity == "inverted" ? 1 : 0, "sub_polarity") }
            if let on = args.optionalBool("surround_enabled") { try await setEQ("SurroundEnable", on ? 1 : 0, "surround_enabled") }
            if let level = args.optionalInt("surround_level") { try await setEQ("SurroundLevel", min(15, max(-15, level)), "surround_level") }
            if let level = args.optionalInt("music_surround_level") { try await setEQ("MusicSurroundLevel", min(15, max(-15, level)), "music_surround_level") }
            if let mode = args.optionalString("surround_mode") { try await setEQ("SurroundMode", mode == "full" ? 1 : 0, "surround_mode") }
            guard !changed.isEmpty else { throw MCPError.invalidParams("Nothing to change") }
            var out = await server.eqSnapshot(device)
            out["ok"] = true
            out["changed"] = changed
            return out
        },

        // MARK: Grouping

        MCPTool(name: "group_rooms", description: "group_rooms: join one room (room) or several (rooms) to another room's group. Playback in `with` wins: the joined rooms drop what they were playing and follow it; a room that was in another group brings that whole group along. Call snapshot_grouping first to be able to undo.",
                inputSchema: schema(["room": room,
                                     "rooms": ["type": "array", "items": room, "description": "Several rooms to join at once"],
                                     "with": room], required: ["with"], oneOf: [["room"], ["rooms"]])) { args, server in
            let manager = try server.manager
            var names = (try? args.stringArray("rooms")) ?? []
            if let one = args.optionalString("room") { names.append(one) }
            guard !names.isEmpty else { throw MCPError.invalidParams("Pass room or rooms") }
            let target = try server.group(named: try args.string("with"))
            guard let coordinator = target.coordinator else { throw MCPError.internal("Target has no coordinator") }
            // Resolve every name before touching the network so a typo
            // joins nothing rather than half the list.
            let sources = try names.map { try server.group(named: $0) }
            // Sonos cannot group across two systems; name the room that is
            // on the other one rather than failing speaker by speaker.
            if let stray = sources.first(where: { $0.householdID != target.householdID }) {
                throw MCPError.invalidParams("\(stray.name) is on a different Sonos system to \(target.name); rooms group only within one system")
            }
            var joined: [String] = []
            for source in sources {
                for member in source.members where member.id != coordinator.id {
                    try await manager.joinGroup(device: member, toCoordinator: coordinator)
                    joined.append(member.roomName)
                }
            }
            return ["ok": true, "joined": joined, "with": coordinator.roomName]
        },
        MCPTool(name: "ungroup_room", description: "Take a room out of its group so it plays on its own.",
                inputSchema: schema(["room": string("Room name")], required: ["room"])) { args, server in
            let manager = try server.manager
            let name = try args.string("room").lowercased()
            guard let device = manager.devices.values.first(where: { $0.roomName.lowercased() == name && !$0.id.hasSuffix("_MR") }) else {
                throw MCPError.invalidParams("No room named \(name)")
            }
            try await manager.ungroupDevice(device)
            return ["ok": true]
        },
        MCPTool(name: "group_all", description: "group_all (party mode): join every room to one room's group so the whole house plays what that room plays. Saves the grouping first and returns snapshot_id; undo with restore_grouping, not ungroup_all.",
                inputSchema: schema(["room": room], required: ["room"]),
                outputSchema: output(["ok": ["type": "boolean"], "joined": ["type": "array", "items": ["type": "string"]],
                                      "snapshot_id": ["type": "string"]], required: ["ok", "snapshot_id"])) { args, server in
            let manager = try server.manager
            let target = try server.group(named: try args.string("room"))
            guard let coordinator = target.coordinator else { throw MCPError.internal("Room has no coordinator") }
            let snapshot = try server.saveGroupingSnapshot()
            var joined: [String] = []
            for group in manager.groups where group.coordinatorID != target.coordinatorID {
                for member in group.members where member.householdID == coordinator.householdID {
                    try await manager.joinGroup(device: member, toCoordinator: coordinator)
                    joined.append(member.roomName)
                }
            }
            return ["ok": true, "joined": joined, "snapshot_id": snapshot.id]
        },
        MCPTool(name: "snapshot_grouping", description: "snapshot_grouping: remember the current room grouping so restore_grouping can put it back after group_rooms or group_all.",
                inputSchema: schema([:]), scope: .readOnly) { _, server in
            try server.saveGroupingSnapshot().descriptor
        },
        MCPTool(name: "restore_grouping", description: "restore_grouping: put every room back into the group it had when the snapshot was taken (rooms that were alone are split off, members rejoin their old coordinator). Playback in re-formed groups follows the old coordinator.",
                inputSchema: schema(["snapshot_id": string("From group_all or snapshot_grouping; omit for the most recent")])) { args, server in
            let id = args.optionalString("snapshot_id") ?? server.groupingSnapshotOrder.last ?? ""
            guard let snapshot = server.groupingSnapshots[id] else { throw MCPError.invalidParams("Unknown snapshot_id") }
            let result = try await server.restoreGrouping(snapshot)
            return ["ok": true, "restored": result.restored, "skipped": result.skipped]
        },
        MCPTool(name: "ungroup_all", description: "ungroup_all: split every group so each room plays on its own — including groups that existed before any agent call. To undo group_all use restore_grouping instead. Requires confirm=true.",
                inputSchema: schema(["confirm": boolean("")], required: ["confirm"])) { args, server in
            try server.requireConfirm(args)
            let manager = try server.manager
            var split: [String] = []
            for group in manager.groups where group.members.count > 1 {
                for member in group.members where member.id != group.coordinatorID {
                    try await manager.ungroupDevice(member)
                    split.append(member.roomName)
                }
            }
            return ["ok": true, "ungrouped": split]
        },

        // MARK: Presets

        MCPTool(name: "list_presets", description: "list_presets: saved group presets / scenes with what each one applies — member rooms, per-room volume, EQ — so you can describe activate_preset before calling it.",
                inputSchema: schema([:]), scope: .readOnly) { _, server in
            let manager = try server.manager
            return ["presets": (PresetManager.current?.presets ?? []).map { preset -> [String: Any] in
                var out: [String: Any] = [
                    "id": preset.id.uuidString,
                    "name": preset.name,
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
                    out["home_theater_eq"] = ["night_mode": ht.nightMode, "speech_enhancement": ht.dialogLevel,
                                              "sub_enabled": ht.subEnabled, "sub_gain": ht.subGain,
                                              "surround_enabled": ht.surroundEnabled, "surround_level": ht.surroundLevel]
                }
                return out
            }]
        },
        MCPTool(name: "get_preset", description: "get_preset: one preset's full configuration — coordinator room, every member room with its volume and EQ, and the home-theatre EQ when the preset stores one.",
                inputSchema: schema(["preset": string("Preset name or id")], required: ["preset"]), scope: .readOnly) { args, server in
            Encode.preset(try server.preset(try args.string("preset")), manager: try server.manager)
        },

        MCPTool(name: "activate_preset", description: "Apply a saved group preset: grouping, volumes and EQ.",
                inputSchema: schema(["preset": string("Preset name or id")], required: ["preset"])) { args, server in
            let manager = try server.manager
            let preset = try server.preset(try args.string("preset"))
            await (try server.presets).applyPreset(preset, using: manager)
            // The preset's own volumes may exceed the agent limit; bring
            // those members down so a token cannot get loud via a preset.
            var capped: [String] = []
            for member in preset.members where member.volume > server.maxVolume {
                if let device = manager.devices[member.deviceID] {
                    try await manager.setVolume(device: device, volume: server.maxVolume)
                    capped.append(device.roomName)
                }
            }
            return ["ok": true, "capped_to_limit": capped, "max_level": server.maxVolume]
        },
        MCPTool(name: "save_preset", description: "Save a room's current grouping, volumes and EQ as a preset.",
                inputSchema: schema(["name": string("Preset name"), "room": room, "include_eq": boolean("Default true")],
                                    required: ["name", "room"]), scope: .manage) { args, server in
            let manager = try server.manager
            let group = try server.group(named: try args.string("room"))
            let name = String(try args.string("name").prefix(60))
            let presets = try server.presets
            await presets.saveFromCurrent(name: name, group: group, deviceVolumes: manager.deviceVolumes,
                                          includeEQ: args.optionalBool("include_eq") ?? true, using: manager)
            let saved = presets.presets.last(where: { $0.name == name })
            return ["ok": true, "id": saved?.id.uuidString ?? NSNull(), "name": name]
        },
        MCPTool(name: "delete_preset", description: "Delete a saved preset. Requires confirm=true.",
                inputSchema: schema(["preset": string("Preset name or id"), "confirm": boolean("")],
                                    required: ["preset", "confirm"]), scope: .manage) { args, server in
            try server.requireConfirm(args)
            let preset = try server.preset(try args.string("preset"))
            try server.presets.deletePreset(id: preset.id)
            return ["ok": true]
        },

        // MARK: Inputs and system

        MCPTool(name: "list_inputs", description: "list_inputs: speakers with a physical line-in / aux / TV (HDMI, optical) input. A stereo pair lists both units; primary marks the one to use unless the user names the other side.",
                inputSchema: schema([:]), scope: .readOnly) { _, server in
            let manager = try server.manager
            let inputs = PhysicalInput.inputs(in: manager.devices)
            let channels: [String: String] = Dictionary(uniqueKeysWithValues:
                manager.stereoChannelMaps.values.flatMap { $0 }.map { ($0.0, "\($0.1)") })
            var seenRooms = Set<String>()
            return ["inputs": inputs.map { input -> [String: Any] in
                let device = manager.devices[input.deviceID]
                let siblings = inputs.filter { $0.roomName == input.roomName }.count
                let primary = siblings == 1 || device?.isCoordinator == true || seenRooms.insert(input.roomName).inserted && device?.isCoordinator != false
                if primary { seenRooms.insert(input.roomName) }
                var row: [String: Any] = ["id": input.deviceID, "room": input.roomName, "kind": input.kind.rawValue,
                                          "model": input.modelName, "primary": primary]
                if let channel = channels[input.deviceID] { row["channel"] = channel }
                return row
            }]
        },
        MCPTool(name: "select_input", description: "Play a speaker's line-in or TV input in a room.",
                inputSchema: schema(["input_id": string("id from list_inputs"), "room": room], required: ["input_id", "room"])) { args, server in
            let manager = try server.manager
            let id = try args.string("input_id")
            guard let input = PhysicalInput.inputs(in: manager.devices).first(where: { $0.deviceID == id }) else {
                throw MCPError.invalidParams("Unknown input_id")
            }
            let group = try server.group(named: try args.string("room"))
            try await manager.playInput(input, in: group)
            return ["ok": true]
        },
        MCPTool(name: "open_window",
                description: "open_window: open one of Choragus's own windows on the Mac and bring the app to the front — club_vis (Back of the Club, the album-art wall) and karaoke (large synced lyrics) follow a room; playlist_manager, listening_stats, alarms, diagnostics, home_theater_eq, playlist_builder and help open on their own.",
                inputSchema: schema(["window": choice(["club_vis", "karaoke", "playlist_manager", "listening_stats", "alarms", "diagnostics", "home_theater_eq", "playlist_builder", "help"], "Which window"),
                                     "room": string("Room for club_vis, karaoke and playlist_manager; omit for the room selected in the app")],
                                    required: ["window"])) { args, server in
            guard let opener = server.windowOpener else { throw MCPError.internal("Windows are unavailable") }
            let window = try args.string("window")
            let group = try args.optionalString("room").map { try server.group(named: $0) }
            guard opener(window, group) else {
                throw MCPError.invalidParams("Could not open \(window); name a room, or select one in the app first")
            }
            return ["ok": true, "window": window, "room": group?.name ?? NSNull()]
        },

        MCPTool(name: "rescan", description: "Look for speakers again and refresh grouping. Use when a room is missing.",
                inputSchema: schema([:])) { _, server in
            try server.manager.rescan()
            return ["ok": true]
        },

        // MARK: System state

        MCPTool(name: "speaker_network_status",
                description: "speaker_network_status: how each speaker sits on the network — Wi-Fi band and channel, noise floor, PHY errors, firmware, and whether it answered at all. The first place to look when one room drops out.",
                inputSchema: schema([:]), scope: .readOnly) { _, server in
            let devices = try server.manager.devices.values.filter { !$0.id.hasSuffix("_MR") }
            let report = await SpeakerNetworkDiagnosticsService().fetchAll(devices: Array(devices))
            return ["speakers": report.map { row -> [String: Any] in
                let band: String
                switch row.band {
                case .ghz24: band = "2.4 GHz"
                case .ghz5: band = "5 GHz"
                case .wired: band = "wired"
                case .homeTheater: band = "home theatre link"
                case .sonosNet: band = "SonosNet"
                case .unknown: band = "unknown"
                }
                var out: [String: Any] = ["room": row.roomName, "model": row.modelName, "reachable": row.reachable,
                                          "band": band, "software": row.softwareVersion]
                if let channel = row.ieeeChannel { out["channel"] = channel }
                if let noise = row.noiseFloorDBm { out["noise_floor_dbm"] = noise }
                if let errors = row.phyErrors { out["phy_errors"] = errors }
                if let rtt = row.httpRTTMillis { out["rtt_ms"] = rtt }
                return out
            }]
        },
        MCPTool(name: "get_diagnostics",
                description: "get_diagnostics: recent entries from the app's own diagnostics log — what Choragus and the speakers have been doing, warnings and errors first when level is set. Useful for working out why something did not play.",
                inputSchema: schema(["level": choice(["all", "warnings", "errors"], "Default warnings"),
                                     "tag": string("Only this category, e.g. QUEUE, PLAYBACK, MCP"),
                                     "limit": integer("1-200, default 50", min: 1, max: 200)]), scope: .readOnly) { args, server in
            _ = try server.manager
            let level = args.optionalString("level") ?? "warnings"
            let tag = args.optionalString("tag")?.uppercased()
            var rows = DiagnosticsService.shared.recent(limit: 1000)
            if let tag { rows = rows.filter { $0.tag.uppercased() == tag } }
            switch level {
            case "all": break
            case "errors": rows = rows.filter { $0.level == .error }
            default: rows = rows.filter { $0.level == .warning || $0.level == .error }
            }
            let iso = ISO8601DateFormatter()
            return ["level": level, "entries": rows.prefix(args.limit(default: 50, max: 200)).map { entry -> [String: Any] in
                var out: [String: Any] = ["at": iso.string(from: entry.timestamp), "level": entry.level.rawValue,
                                          "tag": entry.tag, "message": MCPTool.cap(entry.message)]
                if let context = entry.contextJSON { out["context"] = MCPTool.cap(context) }
                return out
            }]
        },
        MCPTool(name: "scrobble_status", description: "scrobble_status: whether Last.fm scrobbling is on, which rooms and services it covers, and how many plays are waiting to be sent.",
                inputSchema: schema([:]), scope: .readOnly) { _, server in
            guard let provider = server.scrobbleStatusProvider else { throw MCPError.internal("Scrobbling is unavailable") }
            return provider()
        },
        MCPTool(name: "scrobble_now", description: "scrobble_now: send the plays waiting to go to Last.fm, instead of waiting for the next five-minute run.",
                inputSchema: schema([:])) { _, server in
            guard let sender = server.scrobbleSender, let status = server.scrobbleStatusProvider else {
                throw MCPError.internal("Scrobbling is unavailable")
            }
            await sender()
            return ["ok": true].merging(status()) { a, _ in a }
        },
    ]

    static func repeatName(_ mode: RepeatMode) -> String {
        switch mode {
        case .off: return "off"
        case .all: return "all"
        case .one: return "one"
        }
    }
}

extension ChoragusMCPServer {
    var presets: PresetManager {
        get throws {
            guard let presets = PresetManager.current else { throw MCPError.internal("Presets unavailable") }
            return presets
        }
    }

    func preset(_ needle: String) throws -> GroupPreset {
        let key = needle.lowercased()
        guard let preset = try presets.presets.first(where: { $0.name.lowercased() == key || $0.id.uuidString.lowercased() == key }) else {
            throw MCPError.invalidParams("Unknown preset")
        }
        return preset
    }
}
