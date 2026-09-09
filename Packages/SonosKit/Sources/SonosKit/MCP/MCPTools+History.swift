/// MCPTools+History.swift — Play history, most-played rankings, stars
/// and the smart queues built from them.
import Foundation

extension MCPTool {
    static let history: [MCPTool] = [
        MCPTool(name: "recently_played", description: "Tracks played most recently, newest first, optionally in one room.",
                inputSchema: schema(["room": string("Room name; omit for every room"),
                                     "limit": integer("1-200, default 20", min: 1, max: 200)]), scope: .readOnly) { args, server in
            let history = try server.history
            let limit = args.limit(default: 20, max: 200)
            let entries: [PlayHistoryEntry]
            if let room = args.optionalString("room") {
                entries = Array(history.queryFiltered(room: room).prefix(limit))
            } else {
                entries = history.recentlyPlayed(limit: limit)
            }
            return ["entries": entries.map(Encode.historyEntry)]
        },
        MCPTool(name: "most_played",
                description: "What has been played most: tracks, artists, albums or stations, counted over the last N days.",
                inputSchema: schema(["kind": choice(["tracks", "artists", "albums", "stations"], "Default tracks"),
                                     "days": integer("Window in days, default 30; 0 for all time", min: 0, max: 3650),
                                     "room": string("Room name; omit for every room"),
                                     "limit": integer("1-100, default 20", min: 1, max: 100)]), scope: .readOnly) { args, server in
            let history = try server.history
            let kind = args.optionalString("kind") ?? "tracks"
            let days = args.optionalInt("days") ?? 30
            let since = days > 0 ? Calendar.current.date(byAdding: .day, value: -days, to: Date()) : nil
            let entries = history.queryFiltered(since: since, room: args.optionalString("room"))
            let limit = args.limit(default: 20, max: 100)
            var counts: [String: Int] = [:]
            var labels: [String: [String: Any]] = [:]
            for entry in entries {
                let key: String
                switch kind {
                case "artists":
                    guard !entry.artist.isEmpty else { continue }
                    key = entry.artist.lowercased(); labels[key] = ["artist": entry.artist]
                case "albums":
                    guard !entry.album.isEmpty else { continue }
                    key = "\(entry.album)|\(entry.artist)".lowercased(); labels[key] = ["album": entry.album, "artist": entry.artist]
                case "stations":
                    guard !entry.stationName.isEmpty else { continue }
                    key = entry.stationName.lowercased(); labels[key] = ["station": entry.stationName]
                default:
                    guard !entry.title.isEmpty else { continue }
                    key = "\(entry.title)|\(entry.artist)".lowercased()
                    labels[key] = ["title": entry.title, "artist": entry.artist, "album": entry.album]
                }
                counts[key, default: 0] += 1
            }
            let ranked = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(limit)
            return ["kind": kind, "days": days, "items": ranked.map { key, count -> [String: Any] in
                var row = labels[key] ?? [:]; row["plays"] = count; return row
            }]
        },
        MCPTool(name: "star_track", description: "Star a track that appears in the play history.",
                inputSchema: schema(["title": string(""), "artist": string("")], required: ["title", "artist"]),
                scope: .manage) { args, server in
            let history = try server.history
            let title = try args.string("title"), artist = try args.string("artist")
            history.starCurrentTrack(title: title, artist: artist)
            guard history.isStarred(title: title, artist: artist) else {
                throw MCPError.invalidParams("No play history entry for that track")
            }
            return ["ok": true]
        },
        MCPTool(name: "starred_tracks", description: "Tracks starred in the play history.",
                inputSchema: schema(["limit": integer("1-500, default 100", min: 1, max: 500)]), scope: .readOnly) { args, server in
            let entries = try server.history.starredEntries.prefix(args.limit(default: 100, max: 500))
            return ["entries": entries.map(Encode.historyEntry)]
        },
        MCPTool(name: "listening_stats",
                description: "listening_stats: listening habits and patterns — total hours, plays per day over the window, plays by hour of day, by source (service) and by room, and the current daily streak.",
                inputSchema: schema(["days": integer("Window for the daily series, default 30", min: 1, max: 365)]), scope: .readOnly) { args, server in
            let history = try server.history
            let days = args.optionalInt("days") ?? 30
            let day = ISO8601DateFormatter(); day.formatOptions = [.withFullDate]
            return [
                "total_hours": (history.totalListeningHours * 10).rounded() / 10,
                "plays_total": history.entries.count,
                "current_streak_days": history.currentStreak,
                "daily": history.dailyActivity(days: days).map { ["date": day.string(from: $0.0), "plays": $0.1] },
                "by_hour": history.hourlyDistribution.map { ["hour": $0.0, "plays": $0.1] },
                "by_source": history.sourceDistribution.map { ["source": $0.0, "plays": $0.1] },
                "by_room": history.roomDistribution.map { ["room": $0.0, "plays": $0.1] },
            ]
        },
        MCPTool(name: "play_smart_queue",
                description: "Play a queue built from the play history: most_played (last 30 days), recently_played, or starred.",
                inputSchema: schema(["kind": choice(["most_played", "recently_played", "starred"], ""),
                                     "room": room,
                                     "history_room": string("Only count plays from this room; omit for every room"),
                                     "append": boolean("Default false")],
                                    required: ["kind", "room"])) { args, server in
            let manager = try server.manager
            let group = try server.group(named: try args.string("room"))
            let kind: SonosManager.SmartQueueKind
            switch try args.string("kind") {
            case "most_played": kind = .mostPlayed
            case "recently_played": kind = .recentlyPlayed
            case "starred": kind = .starred
            default: throw MCPError.invalidParams("Unknown kind")
            }
            let tracks = manager.smartQueueTracks(kind: kind, room: args.optionalString("history_room"))
            guard !tracks.isEmpty else { throw MCPError.invalidParams("No history for that queue") }
            try await manager.playSmartQueue(kind: kind, room: args.optionalString("history_room"), group: group,
                                             append: args.optionalBool("append") ?? false)
            return ["ok": true, "tracks": tracks.count]
        },

        MCPTool(name: "unstar_track", description: "unstar_track: take the star off a track in the play history.",
                inputSchema: schema(["title": string(""), "artist": string("")], required: ["title", "artist"]),
                scope: .manage) { args, server in
            let history = try server.history
            let title = try args.string("title"), artist = try args.string("artist")
            guard history.isStarred(title: title, artist: artist) else { throw MCPError.invalidParams("That track is not starred") }
            for entry in history.entries where entry.title == title && entry.artist == artist && entry.starred {
                history.toggleStar(id: entry.id)
            }
            return ["ok": true]
        },
        MCPTool(name: "export_history", description: "export_history: the play history as CSV text, ready to save or paste into a spreadsheet.",
                inputSchema: schema([:]), scope: .readOnly) { _, server in
            let history = try server.history
            return ["plays": history.entries.count, "format": "csv", "text": history.exportCSV()]
        },
        MCPTool(name: "delete_history_entries",
                description: "delete_history_entries: remove rows from the play history. Address them by id (the id field on recently_played, most_played is aggregated and has none) or by an exact title, artist or station match — the matches are combined, so title plus artist removes only that pairing. Stream metadata rows such as a station's sponsor message are the usual reason to use this. Requires confirm=true.",
                inputSchema: schema(["ids": ["type": "array", "items": ["type": "string"], "maxItems": 500,
                                             "description": "Entry ids from recently_played or starred_tracks"],
                                     "title": string("Exact track title to match"),
                                     "artist": string("Exact artist to match"),
                                     "station": string("Exact station name to match"),
                                     "confirm": boolean("")],
                                    required: ["confirm"]), scope: .manage) { args, server in
            try server.requireConfirm(args)
            let history = try server.history
            var ids = Set<UUID>()
            for text in (args["ids"] as? [String] ?? []) {
                guard let id = UUID(uuidString: text) else { throw MCPError.invalidParams("Not an entry id: \(text)") }
                ids.insert(id)
            }
            let title = args.optionalString("title")
            let artist = args.optionalString("artist")
            let station = args.optionalString("station")
            if title != nil || artist != nil || station != nil {
                for entry in history.entries {
                    if let title, entry.title.caseInsensitiveCompare(title) != .orderedSame { continue }
                    if let artist, entry.artist.caseInsensitiveCompare(artist) != .orderedSame { continue }
                    if let station, entry.stationName.caseInsensitiveCompare(station) != .orderedSame { continue }
                    ids.insert(entry.id)
                }
            }
            guard !ids.isEmpty else { throw MCPError.invalidParams("No history entry matched") }
            history.deleteEntries(ids)
            return ["ok": true, "removed": ids.count]
        },
        MCPTool(name: "clear_history", description: "clear_history: erase the whole play history on this Mac. Stars, play counts and the smart queues go with it, and it cannot be undone. Requires confirm=true.",
                inputSchema: schema(["confirm": boolean("")], required: ["confirm"]), scope: .manage) { args, server in
            try server.requireConfirm(args)
            let history = try server.history
            let count = history.entries.count
            history.clearHistory()
            return ["ok": true, "removed": count]
        },
    ]
}

extension ChoragusMCPServer {
    var history: PlayHistoryManager {
        get throws {
            guard let history = try manager.playHistoryManager else { throw MCPError.internal("Play history unavailable") }
            return history
        }
    }
}
