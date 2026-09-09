/// MCPTools+Playlists.swift — Choragus playlists (saved queues) and
/// their folders.
import Foundation

extension MCPTool {
    static let playlists: [MCPTool] = [
        MCPTool(name: "list_playlists", description: "list_playlists: every Choragus playlist (saved queue) with id, name, folder path and track count.",
                inputSchema: schema([:]), scope: .readOnly) { _, server in
            ["playlists": try server.playlistRows()]
        },
        MCPTool(name: "get_playlist_tracks", description: "get_playlist_tracks: the tracks in a Choragus playlist, in order. Name the playlist by playlist_id or playlist (name).",
                inputSchema: schema(playlistArgs.merging(["start": integer("1-based position to start from, default 1", min: 1),
                                                          "limit": integer("1-1000, default 500", min: 1, max: 1000)]) { a, _ in a }, oneOf: playlistOneOf),
                scope: .readOnly) { args, server in
            let playlist = try server.playlist(args)
            let tracks = try server.manager.savedQueueTracks(localID: playlist.id)
            let limit = args.limit(default: 500, max: 1000)
            let start = max(1, args.optionalInt("start") ?? 1)
            let page = Array(tracks.enumerated().dropFirst(start - 1).prefix(limit))
            return ["name": playlist.name, "playlist_id": playlist.id, "total": tracks.count, "start": start,
                    "has_more": start - 1 + page.count < tracks.count,
                    "tracks": page.map { index, track -> [String: Any] in
                        var row = Encode.track(track); row["position"] = index + 1; return row
                    }]
        },
        MCPTool(name: "play_playlist", description: "play_playlist: play a Choragus playlist in a room, by playlist_id or playlist (name). append defaults to false, which replaces the room's queue (recoverable from the app's queue history) and starts playback; append=true adds it to the end without interrupting.",
                inputSchema: schema(playlistArgs.merging(["room": room, "append": boolean("Default false")]) { a, _ in a },
                                    required: ["room"], oneOf: playlistOneOf)) { args, server in
            let group = try server.group(named: try args.string("room"))
            let playlist = try server.playlist(args)
            try await server.manager.loadLocalSavedQueue(id: playlist.id, group: group, append: args.optionalBool("append") ?? false)
            return ["ok": true]
        },
        MCPTool(name: "create_playlist", description: "create_playlist: make a Choragus playlist from search or browse results; containers add all their tracks. Names are unique; an existing name fails unless replace=true overwrites its tracks.",
                inputSchema: schema(["name": string("Playlist name"), "item_ids": itemIDs,
                                     "folder_id": integer("From list_folders; omit for top level"),
                                     "replace": boolean("Overwrite a playlist with the same name; default false")],
                                    required: ["name", "item_ids"]), scope: .manage) { args, server in
            let manager = try server.manager
            let name = String(try args.string("name").prefix(80))
            let items = try server.items(try args.stringArray("item_ids"))
            let id: Int64
            if let existing = try server.existingPlaylist(named: name, replace: args.optionalBool("replace") ?? false) {
                manager.replaceChoragusQueueTracks(id: existing.id, tracks: [])
                id = existing.id
                for item in items { _ = await manager.addToChoragusQueue(item: item, queueID: id) }
            } else {
                guard let created = await manager.createChoragusQueue(item: items[0], name: name) else {
                    throw MCPError.invalidParams("First item has no playable tracks")
                }
                id = created
                for item in items.dropFirst() { _ = await manager.addToChoragusQueue(item: item, queueID: id) }
            }
            if let folder = args.optionalInt("folder_id") { manager.moveSavedQueue(id: id, toFolder: Int64(folder)) }
            let count = manager.savedQueueTracks(localID: id).count
            return ["ok": true, "playlist_id": id, "tracks": count]
        },
        MCPTool(name: "add_to_playlist", description: "add_to_playlist: append search or browse results to a Choragus playlist (playlist_id or playlist name).",
                inputSchema: schema(playlistArgs.merging(["item_ids": itemIDs]) { a, _ in a }, required: ["item_ids"], oneOf: playlistOneOf),
                scope: .manage) { args, server in
            let manager = try server.manager
            let playlist = try server.playlist(args)
            var added = 0
            for item in try server.items(try args.stringArray("item_ids")) {
                added += await manager.addToChoragusQueue(item: item, queueID: playlist.id)
            }
            return ["ok": true, "added": added]
        },
        MCPTool(name: "remove_from_playlist", description: "remove_from_playlist: remove tracks from a Choragus playlist by position (1-based, from get_playlist_tracks).",
                inputSchema: schema(playlistArgs.merging(["positions": ["type": "array", "items": ["type": "integer", "minimum": 1]],
                                                          "expected_total": expectedPlaylistTotal]) { a, _ in a },
                                    required: ["positions"], oneOf: playlistOneOf), scope: .manage, destructive: true) { args, server in
            let manager = try server.manager
            let playlist = try server.playlist(args)
            let positions = Set(try args.intArray("positions"))
            let tracks = manager.savedQueueTracks(localID: playlist.id)
            if let expected = args.optionalInt("expected_total"), expected != tracks.count {
                throw MCPError.invalidParams("Playlist has \(tracks.count) tracks, not \(expected); read get_playlist_tracks again")
            }
            let kept = tracks.enumerated().filter { !positions.contains($0.offset + 1) }.map(\.element)
            guard kept.count < tracks.count else { throw MCPError.invalidParams("No such positions") }
            manager.replaceChoragusQueueTracks(id: playlist.id, tracks: kept)
            return ["ok": true, "removed": tracks.count - kept.count, "tracks": kept.count]
        },
        MCPTool(name: "rename_playlist", description: "rename_playlist: give a Choragus playlist a new, unused name.",
                inputSchema: schema(playlistArgs.merging(["name": string("New name")]) { a, _ in a }, required: ["name"], oneOf: playlistOneOf),
                scope: .manage) { args, server in
            let playlist = try server.playlist(args)
            let name = String(try args.string("name").prefix(80))
            if let clash = try server.existingPlaylist(named: name, replace: true), clash.id != playlist.id {
                throw MCPError.invalidParams("A playlist named \(clash.name) already exists (id \(clash.id))")
            }
            try server.manager.renameLocalSavedQueue(id: playlist.id, to: name)
            return ["ok": true]
        },
        MCPTool(name: "duplicate_playlist", description: "duplicate_playlist: copy a Choragus playlist under a new, unused name.",
                inputSchema: schema(playlistArgs.merging(["name": string("Name for the copy")]) { a, _ in a }, required: ["name"], oneOf: playlistOneOf),
                scope: .manage) { args, server in
            let manager = try server.manager
            let playlist = try server.playlist(args)
            let name = String(try args.string("name").prefix(80))
            _ = try server.existingPlaylist(named: name, replace: false)
            _ = manager.cloneLocalSavedQueue(id: playlist.id, name: name)
            let copy = manager.localSavedQueues().last(where: { $0.name == name })
            return ["ok": true, "playlist_id": copy.map { $0.id as Any } ?? NSNull()]
        },
        MCPTool(name: "delete_playlist", description: "delete_playlist: move a Choragus playlist (playlist_id or playlist name) to Deleted Items, recoverable for 30 days in the app. Requires confirm=true.",
                inputSchema: schema(playlistArgs.merging(["confirm": boolean("")]) { a, _ in a }, required: ["confirm"], oneOf: playlistOneOf),
                scope: .manage) { args, server in
            try server.requireConfirm(args)
            let playlist = try server.playlist(args)
            try server.manager.deleteLocalSavedQueue(id: playlist.id)
            return ["ok": true]
        },

        // MARK: Folders

        MCPTool(name: "list_folders", description: "Choragus playlist folders with their parents.",
                inputSchema: schema([:]), scope: .readOnly) { _, server in
            ["folders": try server.manager.savedQueueFolders().map {
                ["id": $0.id, "name": $0.name, "parent_id": $0.parentID.map { $0 as Any } ?? NSNull()]
            }]
        },
        MCPTool(name: "create_folder", description: "Make a playlist folder, optionally inside another.",
                inputSchema: schema(["name": string(""), "parent_id": integer("From list_folders")], required: ["name"]),
                scope: .manage) { args, server in
            let name = String(try args.string("name").prefix(60))
            let parent = args.optionalInt("parent_id").map(Int64.init)
            guard let id = try server.manager.createSavedQueueFolder(name: name, parent: parent) else {
                throw MCPError.internal("Folder was not created")
            }
            return ["ok": true, "folder_id": id]
        },
        MCPTool(name: "move_playlist", description: "move_playlist: put a Choragus playlist in a folder, or at the top level when folder_id is omitted.",
                inputSchema: schema(playlistArgs.merging(["folder_id": integer("From list_folders")]) { a, _ in a }, oneOf: playlistOneOf),
                scope: .manage) { args, server in
            let manager = try server.manager
            let playlist = try server.playlist(args)
            let folder = args.optionalInt("folder_id").map(Int64.init)
            if let folder, !manager.savedQueueFolders().contains(where: { $0.id == folder }) {
                throw MCPError.invalidParams("Unknown folder_id")
            }
            manager.moveSavedQueue(id: playlist.id, toFolder: folder)
            return ["ok": true]
        },

        // MARK: Folders, Deleted Items and export

        MCPTool(name: "rename_folder", description: "rename_folder: rename a Choragus playlist folder.",
                inputSchema: schema(["folder_id": integer("From list_folders"), "name": string("New name")],
                                    required: ["folder_id", "name"]), scope: .manage) { args, server in
            let manager = try server.manager
            let id = Int64(try args.int("folder_id"))
            guard manager.savedQueueFolders().contains(where: { $0.id == id }) else { throw MCPError.invalidParams("Unknown folder_id") }
            manager.renameSavedQueueFolder(id: id, to: String(try args.string("name").prefix(60)))
            return ["ok": true]
        },
        MCPTool(name: "move_folder", description: "move_folder: nest a folder inside another, or move it to the top level when parent_id is omitted.",
                inputSchema: schema(["folder_id": integer("From list_folders"), "parent_id": integer("From list_folders")],
                                    required: ["folder_id"]), scope: .manage) { args, server in
            let manager = try server.manager
            let id = Int64(try args.int("folder_id"))
            guard manager.savedQueueFolders().contains(where: { $0.id == id }) else { throw MCPError.invalidParams("Unknown folder_id") }
            manager.moveSavedQueueFolder(id: id, under: args.optionalInt("parent_id").map(Int64.init))
            return ["ok": true]
        },
        MCPTool(name: "delete_folder", description: "delete_folder: remove a folder. Playlists inside it move to the top level rather than being deleted. Requires confirm=true.",
                inputSchema: schema(["folder_id": integer("From list_folders"), "confirm": boolean("")],
                                    required: ["folder_id", "confirm"]), scope: .manage) { args, server in
            try server.requireConfirm(args)
            let manager = try server.manager
            let id = Int64(try args.int("folder_id"))
            guard manager.savedQueueFolders().contains(where: { $0.id == id }) else { throw MCPError.invalidParams("Unknown folder_id") }
            manager.deleteSavedQueueFolder(id: id)
            return ["ok": true]
        },
        MCPTool(name: "list_deleted_playlists", description: "list_deleted_playlists: Choragus playlists in Deleted Items, which keeps them for 30 days.",
                inputSchema: schema([:]), scope: .readOnly) { _, server in
            ["playlists": try server.manager.deletedSavedQueues().map {
                ["id": $0.id, "name": MCPTool.cap($0.name), "tracks": $0.trackCount,
                 "deleted_at": $0.deletedAt.map { ISO8601DateFormatter().string(from: $0) } ?? ""]
            }]
        },
        MCPTool(name: "restore_playlist", description: "restore_playlist: bring a playlist back from Deleted Items.",
                inputSchema: schema(["playlist_id": integer("id from list_deleted_playlists")], required: ["playlist_id"]),
                scope: .manage) { args, server in
            let manager = try server.manager
            let id = Int64(try args.int("playlist_id"))
            guard manager.deletedSavedQueues().contains(where: { $0.id == id }) else { throw MCPError.invalidParams("That playlist is not in Deleted Items") }
            manager.restoreDeletedSavedQueue(id: id)
            return ["ok": true]
        },
        MCPTool(name: "purge_playlist", description: "purge_playlist: remove a playlist from Deleted Items for good, or empty the whole of Deleted Items when playlist_id is omitted. Requires confirm=true.",
                inputSchema: schema(["playlist_id": integer("id from list_deleted_playlists; omit to empty Deleted Items"), "confirm": boolean("")],
                                    required: ["confirm"]), scope: .manage) { args, server in
            try server.requireConfirm(args)
            let manager = try server.manager
            guard let id = args.optionalInt("playlist_id") else {
                let count = manager.deletedSavedQueues().count
                manager.emptyDeletedSavedQueues()
                return ["ok": true, "removed": count]
            }
            guard manager.deletedSavedQueues().contains(where: { $0.id == Int64(id) }) else { throw MCPError.invalidParams("That playlist is not in Deleted Items") }
            manager.permanentlyDeleteSavedQueue(id: Int64(id))
            return ["ok": true, "removed": 1]
        },
        MCPTool(name: "export_playlist", description: "export_playlist: a Choragus playlist as M3U or CSV text, ready to save or paste elsewhere.",
                inputSchema: schema(playlistArgs.merging(["format": choice(["m3u", "csv"], "Default m3u")]) { a, _ in a },
                                    oneOf: playlistOneOf), scope: .readOnly) { args, server in
            let playlist = try server.playlist(args)
            let tracks = try server.manager.savedQueueTracks(localID: playlist.id)
            let asCSV = args.optionalString("format") == "csv"
            return ["name": playlist.name, "format": asCSV ? "csv" : "m3u", "tracks": tracks.count,
                    "text": SonosManager.exportTracks(tracks, asCSV: asCSV)]
        },

        // MARK: Sonos playlists (stored on the system, seen by every controller)

        MCPTool(name: "list_sonos_playlists", description: "list_sonos_playlists: playlists saved on the Sonos system itself, which every Sonos controller sees. Choragus playlists live only on this Mac; see list_playlists.",
                inputSchema: schema(["limit": integer("1-200, default 200", min: 1, max: 200)]), scope: .readOnly) { args, server in
            let result = try await server.manager.browse(objectID: BrowseID.playlists, householdID: nil, count: args.limit(default: 200, max: 200))
            return ["playlists": server.remember(result.items).map(Encode.item), "total": result.total]
        },
        MCPTool(name: "play_sonos_playlist", description: "play_sonos_playlist: play a Sonos playlist in a room. append=false (default) replaces the room's queue and starts playback.",
                inputSchema: schema(["room": room, "playlist": string("Name or id from list_sonos_playlists"),
                                     "append": boolean("Default false: replace the queue and play")],
                                    required: ["room", "playlist"])) { args, server in
            let group = try server.group(named: try args.string("room"))
            let item = try await server.sonosPlaylist(try args.string("playlist"))
            try await server.manager.playSavedQueueToRoom(objectID: item.objectID, group: group,
                                                          append: args.optionalBool("append") ?? false)
            return ["ok": true, "playlist": item.title]
        },
        MCPTool(name: "add_to_sonos_playlist", description: "add_to_sonos_playlist: append search or browse results to a Sonos playlist.",
                inputSchema: schema(["playlist": string("Name or id from list_sonos_playlists"), "item_ids": itemIDs],
                                    required: ["playlist", "item_ids"]), scope: .manage) { args, server in
            let manager = try server.manager
            let playlist = try await server.sonosPlaylist(try args.string("playlist"))
            var added = 0
            for item in try server.items(try args.stringArray("item_ids")) {
                try await manager.addToPlaylist(playlistID: playlist.objectID, item: item)
                added += 1
            }
            return ["ok": true, "added": added]
        },
        MCPTool(name: "rename_sonos_playlist", description: "rename_sonos_playlist: rename a playlist on the Sonos system.",
                inputSchema: schema(["playlist": string("Name or id from list_sonos_playlists"), "name": string("New name")],
                                    required: ["playlist", "name"]), scope: .manage) { args, server in
            let playlist = try await server.sonosPlaylist(try args.string("playlist"))
            try await server.manager.renamePlaylist(playlistID: playlist.objectID, oldTitle: playlist.title,
                                                    newTitle: String(try args.string("name").prefix(80)))
            return ["ok": true]
        },
        MCPTool(name: "delete_sonos_playlist", description: "delete_sonos_playlist: remove a playlist from the Sonos system. Sonos has no undo for this. Requires confirm=true.",
                inputSchema: schema(["playlist": string("Name or id from list_sonos_playlists"), "confirm": boolean("")],
                                    required: ["playlist", "confirm"]), scope: .manage) { args, server in
            try server.requireConfirm(args)
            let playlist = try await server.sonosPlaylist(try args.string("playlist"))
            try await server.manager.deletePlaylist(playlistID: playlist.objectID)
            return ["ok": true]
        },
        MCPTool(name: "clone_sonos_playlist", description: "clone_sonos_playlist: copy a Sonos playlist into a Choragus playlist on this Mac, which can then be edited without touching the original.",
                inputSchema: schema(["playlist": string("Name or id from list_sonos_playlists"), "name": string("Name for the copy")],
                                    required: ["playlist"]), scope: .manage) { args, server in
            let manager = try server.manager
            let playlist = try await server.sonosPlaylist(try args.string("playlist"))
            let name = String((args.optionalString("name") ?? playlist.title).prefix(80))
            _ = try server.existingPlaylist(named: name, replace: false)
            let count = try await manager.cloneSonosPlaylistToChoragus(objectID: playlist.objectID, name: name)
            let copy = manager.localSavedQueues().last { $0.name == name }
            return ["ok": true, "tracks": count, "playlist_id": copy.map { $0.id as Any } ?? NSNull()]
        },
    ]
}
