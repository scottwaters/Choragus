/// MCPTools+Builder.swift — The AI playlist builder: song lists from a
/// brief, matching on a service as a background job, and delivery into
/// a queue as matches land.
import Foundation

extension MCPTool {
    static let builder: [MCPTool] = [
        MCPTool(name: "list_ai_profiles", description: "The AI services configured in Settings for generate_song_list, and which is selected.",
                inputSchema: schema([:]), scope: .readOnly) { _, _ in
            let selected = AIServiceProfileStore.selectedID
            return ["profiles": AIServiceProfileStore.load().map {
                ["name": $0.name, "provider": $0.provider.rawValue, "model": $0.model, "selected": $0.id == selected, "verified": $0.verified]
            }]
        },
        MCPTool(name: "generate_song_list",
                description: "Ask the AI service selected in Settings for a song list from a brief (\"20 upbeat 80s pop songs\"). Returns title/artist pairs for build_playlist. Unnecessary when you can write the list yourself.",
                inputSchema: schema(["brief": string("Up to 1000 characters"),
                                     "catalog_hint": string("Service the songs must exist on, e.g. Spotify; omit for a local library")],
                                    required: ["brief"])) { args, _ in
            guard let config = SongListAIConfig.stored() else {
                throw MCPError.invalidParams("No AI service with a key is selected in Settings → AI")
            }
            let brief = String(try args.string("brief").prefix(SongListAIService.maxBriefLength))
            let songs = try await SongListAIService.generate(brief: brief, config: config, catalogHint: args.optionalString("catalog_hint"))
            return ["songs": songs.map { ["title": $0.title, "artist": $0.artist] }, "model": config.model]
        },
        MCPTool(name: "build_playlist",
                description: """
                build_playlist: turn a song list (titles and artists) into real tracks by matching each on a music source — \
                the AI playlist / smart playlist / mixtape builder. As each song is found it can be added to a room's queue. \
                Runs in the background: returns a job_id at once; read progress with build_status. \
                service: "library" (default, the Sonos music library), "apple_music", a signed-in service name from list_music_services, or a media server name. \
                fallback_service re-tries the misses on a second source. \
                deliver: "none" (default), "queue" (append each match as found) or "play" (first match plays, the rest queue). \
                save=true (default) also stores the matched tracks as a Choragus playlist when matching ends; playlist names are unique, so an existing name fails at the end unless replace=true overwrites it. \
                playlist (id or name) appends the matches to that existing playlist instead — use it when retrying unmatched songs on another source. \
                Order: matches keep the order of songs; misses are dropped, never placeholders. Partial failure: a track the speaker refuses to queue is counted in queue_errors and the job carries on; tracks already queued stay if the job is cancelled.
                """,
                inputSchema: schema([
                    "name": string("Playlist name"),
                    "songs": ["type": "array", "maxItems": 200, "items": schema(["title": string(""), "artist": string("")], required: ["title", "artist"])],
                    "service": string("Where to match; default library"),
                    "fallback_service": string("Second source for songs the first misses"),
                    "deliver": choice(["none", "queue", "play"], "Default none"),
                    "room": room,
                    "save": boolean("Store the result as a Choragus playlist; default true"),
                    "replace": boolean("Overwrite a playlist with the same name; default false"),
                    "playlist": playlistRef,
                    "playlist_id": playlistID,
                ], required: ["name", "songs"])) { args, server in
            let manager = try server.manager
            let name = String(try args.string("name").prefix(80))
            let songs = ((args["songs"] as? [[String: Any]]) ?? []).compactMap { row -> SongSpec? in
                guard let title = row["title"] as? String, let artist = row["artist"] as? String,
                      !title.isEmpty, !artist.isEmpty else { return nil }
                return SongSpec(title: String(title.prefix(200)), artist: String(artist.prefix(200)))
            }
            guard !songs.isEmpty else { throw MCPError.invalidParams("songs is empty") }
            guard songs.count <= 200 else { throw MCPError.invalidParams("At most 200 songs") }

            var passes: [MCPBuildJobs.Pass] = []
            let primary = try server.resolveService(args.optionalString("service") ?? "library")
            passes.append(.init(label: primary.label, service: primary.service))
            if let fallback = args.optionalString("fallback_service") {
                let second = try server.resolveService(fallback)
                guard second.label != primary.label else { throw MCPError.invalidParams("fallback_service must differ from service") }
                passes.append(.init(label: second.label, service: second.service))
            }

            let deliver = args.optionalString("deliver") ?? "none"
            let save = args.optionalBool("save") ?? true
            guard deliver != "none" || save else { throw MCPError.invalidParams("Nothing to do: deliver is none and save is false") }
            let replace = args.optionalBool("replace") ?? false
            let appendTarget: LocalSavedQueue? = (args["playlist"] != nil || args["playlist_id"] != nil) ? try server.playlist(args) : nil
            if save {
                try server.requireScope(.manage, for: "Saving a playlist")
                // Fail now, not after a minute of matching.
                if appendTarget == nil { _ = try server.existingPlaylist(named: name, replace: replace) }
            }
            var group: SonosGroup?
            if deliver != "none" {
                guard let roomName = args.optionalString("room") else {
                    throw MCPError.invalidParams("room is required when deliver is \(deliver)")
                }
                group = try server.group(named: roomName)
            }

            let onHit: MCPBuildJobs.Hit? = group.map { group in
                { [weak manager] item, index in
                    guard let manager, let browseItem = item.browseItem(id: "MCP:\(name)/\(index)") else { return nil }
                    if deliver == "play", index == 1 {
                        try await manager.playItemsReplacingQueue([browseItem], in: group)
                        return 1
                    }
                    let position = try await manager.addBrowseItemToQueue(browseItem, in: group, playNext: false)
                    return position > 0 ? position : nil
                }
            }
            let finish: MCPBuildJobs.Finish = { [weak manager] tracks in
                var playlistID: Int64?
                if save {
                    guard let manager, let server = ChoragusMCPServer.shared as ChoragusMCPServer? else {
                        throw MCPError.internal("Playlist was not saved")
                    }
                    if let appendTarget {
                        _ = manager.appendToChoragusPlaylist(queueID: appendTarget.id, tracks: tracks)
                        playlistID = appendTarget.id
                    } else if let existing = try server.existingPlaylist(named: name, replace: replace) {
                        manager.replaceChoragusQueueTracks(id: existing.id, tracks: tracks)
                        playlistID = existing.id
                    } else {
                        guard let id = manager.saveChoragusPlaylist(name: name, tracks: tracks) else {
                            throw MCPError.internal("Playlist was not saved")
                        }
                        playlistID = id
                    }
                }
                let saved = appendTarget != nil ? "append" : "save"
                return (deliver == "none" ? saved : (save ? "\(deliver)+\(saved)" : deliver), playlistID)
            }
            let job: MCPBuildJobs.Job
            do {
                job = try server.buildJobs.start(name: name, specs: songs, passes: passes, onHit: onHit, finish: finish)
            } catch {
                throw MCPError.invalidParams("\(MCPBuildJobs.maxRunning) builds are already running; wait for one to finish or cancel it")
            }
            if let group { server.buildRooms[job.id] = group.coordinatorID }
            server.buildCreatedPlaylist[job.id] = save && appendTarget == nil && (try? server.existingPlaylist(named: name, replace: false)) == nil
            sonosDiagLog(.info, tag: "MCP", "Build started",
                         context: ["job": job.id, "songs": String(songs.count), "services": passes.map(\.label).joined(separator: ","), "deliver": deliver])
            return ["job_id": job.id, "total": songs.count, "services": passes.map(\.label), "deliver": deliver, "save": save]
        },
        MCPTool(name: "build_status",
                description: "Progress of a build_playlist job: status (working, completed, failed, cancelled), matched and unmatched songs so far. wait_seconds blocks up to that long while the job is working.",
                inputSchema: schema(["job_id": string(""), "wait_seconds": integer("0-25", min: 0, max: 25)],
                                    required: ["job_id"]), scope: .readOnly) { args, server in
            guard let job = server.buildJobs.job(try args.string("job_id")) else { throw MCPError.invalidParams("Unknown job_id") }
            let wait = min(25, max(0, args.optionalInt("wait_seconds") ?? 0))
            if wait > 0 { await server.buildJobs.wait(job, upTo: wait) }
            return job.snapshot
        },
        MCPTool(name: "cancel_build", description: "cancel_build: stop a running build_playlist job. Tracks already queued stay unless undo=true, which also removes them and deletes a playlist the job created (see undo_build).",
                inputSchema: schema(["job_id": string(""), "undo": boolean("Also undo what the job did so far; default false")],
                                    required: ["job_id"])) { args, server in
            let id = try args.string("job_id")
            guard server.buildJobs.cancel(id) else { throw MCPError.invalidParams("No running job with that id") }
            guard args.optionalBool("undo") ?? false, let job = server.buildJobs.job(id) else { return ["ok": true] }
            return try await server.undoBuild(job)
        },
        MCPTool(name: "undo_build", description: "undo_build: take back what a build_playlist job did — remove the tracks it queued (only if the queue has not changed since, checked by length) and delete the playlist it created. Playlists it appended to or replaced are left alone.",
                inputSchema: schema(["job_id": string("")], required: ["job_id"]), scope: .manage, destructive: true) { args, server in
            guard let job = server.buildJobs.job(try args.string("job_id")) else { throw MCPError.invalidParams("Unknown job_id") }
            guard job.state != .working else { throw MCPError.invalidParams("Job is still running; cancel_build with undo=true") }
            return try await server.undoBuild(job)
        },
    ]
}
