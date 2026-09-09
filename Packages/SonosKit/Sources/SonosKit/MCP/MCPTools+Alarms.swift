/// MCPTools+Alarms.swift — Sonos alarms: list, create, change, delete.
import Foundation

extension MCPTool {
    static let recurrences = ["daily", "weekdays", "weekends", "once"]

    static let alarms: [MCPTool] = [
        MCPTool(name: "list_alarms", description: "Every Sonos alarm: time, room, recurrence, enabled, volume.",
                inputSchema: schema([:]), scope: .readOnly) { _, server in
            let alarms = try await server.manager.getAlarms()
            return ["alarms": alarms.map(Encode.alarm)]
        },
        MCPTool(name: "create_alarm",
                description: "create_alarm: add a Sonos alarm in a room. time is the household's local time (the speakers' own clock, not this Mac's). recurrence once fires at the next occurrence of that time and then stays as a disabled alarm. It plays the Sonos chime unless item_id names a station, favorite or playlist from a search or browse. Volume respects the agent volume limit.",
                inputSchema: schema([
                    "room": string("Room name"),
                    "time": string("HH:MM, 24-hour"),
                    "recurrence": choice(recurrences, "Default daily"),
                    "volume": integer("0-100, default 25", min: 0, max: 100),
                    "duration_minutes": integer("How long it plays, default 60", min: 1, max: 1439),
                    "days": ["type": "array", "items": integer("0 Sunday … 6 Saturday", min: 0, max: 6),
                             "description": "Exact weekdays; overrides recurrence"],
                    "item_id": string("What to play; omit for the chime"),
                    "shuffle": boolean("Default false"),
                    "enabled": boolean("Default true"),
                ], required: ["room", "time"]), scope: .manage) { args, server in
            let manager = try server.manager
            let device = try server.device(try args.string("room"))
            let time = try Self.alarmTime(try args.string("time"))
            let minutes = min(1439, max(1, args.optionalInt("duration_minutes") ?? 60))
            var uri = SonosAlarm.chimeURI, metadata = ""
            if let itemID = args.optionalString("item_id") {
                let item = try server.items([itemID])[0]
                guard let resource = item.resourceURI, !resource.isEmpty else { throw MCPError.invalidParams("That item cannot be an alarm program") }
                uri = resource
                metadata = item.resourceMetadata ?? ""
            }
            let alarm = SonosAlarm(id: 0, startTime: time,
                                   duration: String(format: "%02d:%02d:00", minutes / 60, minutes % 60),
                                   recurrence: Self.recurrence(args),
                                   enabled: args.optionalBool("enabled") ?? true,
                                   roomUUID: device.id, programURI: uri, programMetaData: metadata,
                                   volume: server.cappedVolume(args.optionalInt("volume") ?? 25),
                                   includeLinkedZones: false,
                                   playMode: (args.optionalBool("shuffle") ?? false) ? "SHUFFLE" : "REPEAT_ALL",
                                   roomName: device.roomName)
            let id = try await manager.createAlarm(alarm)
            guard id > 0 else { throw MCPError.internal("Speaker did not create the alarm") }
            return ["ok": true, "alarm_id": id]
        },
        MCPTool(name: "set_alarm", description: "Change an alarm: enable or disable it, move its time, volume or recurrence.",
                inputSchema: schema([
                    "alarm_id": integer("From list_alarms"),
                    "enabled": boolean(""),
                    "time": string("HH:MM, 24-hour"),
                    "volume": integer("0-100", min: 0, max: 100),
                    "recurrence": choice(recurrences, ""),
                    "days": ["type": "array", "items": integer("0 Sunday … 6 Saturday", min: 0, max: 6),
                             "description": "Exact weekdays; overrides recurrence"],
                    "shuffle": boolean(""),
                ], required: ["alarm_id"]), scope: .manage) { args, server in
            let manager = try server.manager
            var alarm = try await server.alarm(try args.int("alarm_id"))
            var changed: [String] = []
            if let enabled = args.optionalBool("enabled") { alarm.enabled = enabled; changed.append("enabled") }
            if let time = args.optionalString("time") { alarm.startTime = try Self.alarmTime(time); changed.append("time") }
            if let volume = args.optionalInt("volume") { alarm.volume = server.cappedVolume(volume); changed.append("volume") }
            if args["days"] != nil || args.optionalString("recurrence") != nil { alarm.recurrence = Self.recurrence(args); changed.append("recurrence") }
            if let shuffle = args.optionalBool("shuffle") { alarm.shuffle = shuffle; changed.append("shuffle") }
            guard !changed.isEmpty else { throw MCPError.invalidParams("Nothing to change") }
            try await manager.updateAlarm(alarm)
            return ["ok": true, "changed": changed]
        },
        MCPTool(name: "delete_alarm", description: "Remove an alarm. Requires confirm=true.",
                inputSchema: schema(["alarm_id": integer("From list_alarms"), "confirm": boolean("")],
                                    required: ["alarm_id", "confirm"]), scope: .manage) { args, server in
            try server.requireConfirm(args)
            let alarm = try await server.alarm(try args.int("alarm_id"))
            try await server.manager.deleteAlarm(alarm)
            return ["ok": true]
        },
    ]

    static func alarmTime(_ text: String) throws -> String {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else {
            throw MCPError.invalidParams("time must be HH:MM")
        }
        return String(format: "%02d:%02d:00", parts[0], parts[1])
    }

    /// `days` wins over `recurrence`; both absent means daily.
    static func recurrence(_ args: [String: Any]) -> String {
        if let days = try? args.intArray("days") { return SonosAlarm.recurrence(days: Set(days)) }
        return recurrence(args.optionalString("recurrence") ?? "daily")
    }

    static func recurrence(_ name: String) -> String {
        switch name.lowercased() {
        case "weekdays": return "WEEKDAYS"
        case "weekends": return "WEEKENDS"
        case "once": return "ONCE"
        default: return "DAILY"
        }
    }
}

extension ChoragusMCPServer {
    func alarm(_ id: Int) async throws -> SonosAlarm {
        guard let alarm = try await manager.getAlarms().first(where: { $0.id == id }) else {
            throw MCPError.invalidParams("Unknown alarm_id")
        }
        return alarm
    }
}

extension Encode {
    static func alarm(_ alarm: SonosAlarm) -> [String: Any] {
        [
            "id": alarm.id,
            "room": alarm.roomName,
            "time": String(alarm.startTime.prefix(5)),
            "recurrence": alarm.recurrence.lowercased(),
            "enabled": alarm.enabled,
            "volume": alarm.volume,
            "days": alarm.activeDays.sorted(),
            "duration": alarm.hasNoLimit ? "no limit" : alarm.duration,
            "shuffle": alarm.shuffle,
            "program": alarm.isChime ? "chime" : (alarm.programTitle.isEmpty ? alarm.programURI : alarm.programTitle),
        ]
    }
}
