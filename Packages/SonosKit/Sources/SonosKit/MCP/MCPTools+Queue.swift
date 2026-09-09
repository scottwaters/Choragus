/// MCPTools+Queue.swift — Reading and editing a room's play queue.
import Foundation

extension MCPTool {
    static let queue: [MCPTool] = [
        MCPTool(name: "get_queue", description: "get_queue: the room's play queue / up next list, in order with 1-based positions. Page with start and limit; total is the whole queue. Pass revision back as expected_revision to positional edits so they refuse to run if the queue changed in any way (reorders included); expected_total only guards the length.",
                inputSchema: schema(["room": room, "start": integer("1-based position to start from, default 1", min: 1),
                                     "limit": integer("1-500, default 100", min: 1, max: 500)],
                                    required: ["room"]), scope: .readOnly, outputSchema: queueOutput) { args, server in
            let manager = try server.manager
            let group = try server.group(named: try args.string("room"))
            guard let coordinator = group.coordinator else { throw MCPError.internal("Room has no coordinator") }
            let limit = args.limit(default: 100, max: 500)
            let start = max(1, args.optionalInt("start") ?? 1)
            let items = try await manager.queue.readFullQueue(device: coordinator)
            let revision = (try? await manager.queue.queueRevision(group: group)) ?? 0
            let page = items.dropFirst(start - 1).prefix(limit)
            return ["total": items.count, "revision": revision, "start": start, "has_more": start - 1 + page.count < items.count,
                    "items": page.map(Encode.queueItem)]
        },
        MCPTool(name: "play_item",
                description: "play_item: play a search / browse result. mode now (default) replaces the queue and starts playback at once; next inserts after the current track without interrupting; end appends. Containers (albums, artists, genres, playlists) add all their tracks; stations start streaming.",
                inputSchema: schema(["room": room,
                                     "item_id": string("id from search, browse_library, search_radio, list_favorites or search_service"),
                                     "mode": choice(["now", "next", "end"], "Default now")],
                                    required: ["room", "item_id"])) { args, server in
            let manager = try server.manager
            let group = try server.group(named: try args.string("room"))
            let item = try server.items([try args.string("item_id")])[0]
            switch args.optionalString("mode") ?? "now" {
            case "next": _ = try await manager.addBrowseItemToQueue(item, in: group, playNext: true)
            case "end": _ = try await manager.addBrowseItemToQueue(item, in: group, playNext: false)
            default: try await manager.playBrowseItem(item, in: group)
            }
            return ["ok": true]
        },
        MCPTool(name: "add_to_queue", description: "Add several results to the queue at once, after the current track or at the end.",
                inputSchema: schema(["room": room, "item_ids": itemIDs, "mode": choice(["next", "end"], "Default end")],
                                    required: ["room", "item_ids"])) { args, server in
            let manager = try server.manager
            let group = try server.group(named: try args.string("room"))
            let items = try server.items(try args.stringArray("item_ids"))
            _ = try await manager.addBrowseItemsToQueue(items, in: group, playNext: args.optionalString("mode") == "next")
            // Containers expand on the speaker, so the honest count is the
            // queue length before and after; remaining carries the after.
            return ["ok": true, "items_added": items.count].merging(await server.queueState(group)) { a, _ in a }
        },
        MCPTool(name: "play_queue_position", description: "play_queue_position: jump to a track in the queue by position (1-based) and play it.",
                inputSchema: schema(["room": room, "position": integer("1-based", min: 1),
                                     "expected_revision": expectedRevision, "expected_total": expectedTotal],
                                    required: ["room", "position"])) { args, server in
            let group = try server.group(named: try args.string("room"))
            try await server.checkQueueRevision(group, args)
            try await server.manager.playTrackFromQueue(group: group, trackNumber: max(1, try args.int("position")))
            return ["ok": true]
        },
        MCPTool(name: "move_in_queue", description: "move_in_queue: move a queued track from one position to another (both 1-based).",
                inputSchema: schema(["room": room, "from": integer("", min: 1), "to": integer("", min: 1),
                                     "expected_revision": expectedRevision, "expected_total": expectedTotal],
                                    required: ["room", "from", "to"])) { args, server in
            let group = try server.group(named: try args.string("room"))
            try await server.checkQueueRevision(group, args)
            try await server.manager.queue.moveTrackInQueue(group: group, from: max(1, try args.int("from")), to: max(1, try args.int("to")))
            return ["ok": true].merging(await server.queueState(group)) { a, _ in a }
        },
        MCPTool(name: "remove_from_queue", description: "remove_from_queue: remove tracks from the queue by position (1-based). All positions refer to the queue as it was before this call — [3, 5] removes the original third and fifth tracks. Not safe to retry blind: pass expected_revision from get_queue (or request_id) so a repeat after a lost reply cannot remove different tracks. Returns remaining and the new revision.",
                inputSchema: schema(["room": room, "positions": ["type": "array", "items": ["type": "integer", "minimum": 1]],
                                     "expected_revision": expectedRevision, "expected_total": expectedTotal],
                                    required: ["room", "positions"]), destructive: true) { args, server in
            let manager = try server.manager
            let group = try server.group(named: try args.string("room"))
            let positions = Set(try args.intArray("positions").filter { $0 >= 1 })
            guard !positions.isEmpty else { throw MCPError.invalidParams("positions is empty") }
            let total = try await server.checkQueueRevision(group, args)
            if let total, let beyond = positions.first(where: { $0 > total }) {
                throw MCPError.invalidParams("Position \(beyond) is beyond the queue (\(total) tracks)")
            }
            // Highest first, so each removal leaves the lower positions where they were.
            for position in positions.sorted(by: >) {
                try await manager.queue.removeFromQueue(group: group, trackIndex: position)
            }
            return ["ok": true, "removed": positions.count].merging(await server.queueState(group)) { a, _ in a }
        },
        MCPTool(name: "dedupe_queue", description: "dedupe_queue: remove repeated tracks from the queue, keeping the first of each.",
                inputSchema: schema(["room": room], required: ["room"]), destructive: true) { args, server in
            let group = try server.group(named: try args.string("room"))
            let removed = try await server.manager.queue.dedupeQueue(group: group)
            return ["ok": true, "removed": removed].merging(await server.queueState(group)) { a, _ in a }
        },
        MCPTool(name: "clear_queue", description: "clear_queue: empty the room's queue. Requires confirm=true.",
                inputSchema: schema(["room": room, "confirm": boolean("")], required: ["room", "confirm"])) { args, server in
            try server.requireConfirm(args)
            let group = try server.group(named: try args.string("room"))
            try await server.manager.clearQueue(group: group)
            return ["ok": true]
        },
        MCPTool(name: "save_queue_as_playlist", description: "save_queue_as_playlist: store the room's current queue as a Choragus playlist. Names are unique; an existing name fails unless replace=true overwrites it.",
                inputSchema: schema(["room": room, "name": string("Playlist name"), "replace": boolean("Overwrite a playlist with the same name; default false")],
                                    required: ["room", "name"]),
                scope: .manage) { args, server in
            let manager = try server.manager
            let group = try server.group(named: try args.string("room"))
            let name = String(try args.string("name").prefix(80))
            if let existing = try server.existingPlaylist(named: name, replace: args.optionalBool("replace") ?? false) {
                guard let coordinator = group.coordinator else { throw MCPError.internal("Room has no coordinator") }
                let tracks = try await manager.queue.readFullQueue(device: coordinator)
                guard !tracks.isEmpty else { throw MCPError.invalidParams("Queue is empty") }
                manager.replaceChoragusQueueTracks(id: existing.id, tracks: tracks)
                return ["ok": true, "playlist_id": existing.id, "tracks": tracks.count, "replaced": true]
            }
            let count = try await manager.saveQueueToChoragus(group: group, name: name)
            guard count > 0 else { throw MCPError.invalidParams("Queue is empty") }
            let saved = manager.localSavedQueues().last(where: { $0.name == name })
            return ["ok": true, "playlist_id": saved.map { $0.id as Any } ?? NSNull(), "tracks": count]
        },

        // MARK: Queue history

        MCPTool(name: "list_queue_snapshots",
                description: "list_queue_snapshots: queues Choragus saved automatically before it replaced them, newest first — the undo history behind the Queue panel. Omit room for every room's snapshots.",
                inputSchema: schema(["room": string("Room name; omit for every room")]), scope: .readOnly) { args, server in
            let manager = try server.manager
            if let name = args.optionalString("room") {
                let group = try server.group(named: name)
                return ["room": group.name, "snapshots": manager.queueSnapshots(group: group).map(Encode.queueSnapshot)]
            }
            return ["rooms": manager.allQueueSnapshots().map { row in
                ["room": row.room, "snapshots": row.snapshots.map(Encode.queueSnapshot)]
            }]
        },
        MCPTool(name: "restore_queue_snapshot",
                description: "restore_queue_snapshot: put a room's queue back to a saved snapshot from list_queue_snapshots. The queue being replaced is itself snapshotted first.",
                inputSchema: schema(["room": room, "snapshot_id": integer("id from list_queue_snapshots")],
                                    required: ["room", "snapshot_id"])) { args, server in
            let group = try server.group(named: try args.string("room"))
            try await server.manager.restoreQueueSnapshot(group: group, localID: Int64(try args.int("snapshot_id")))
            return ["ok": true].merging(await server.queueState(group)) { a, _ in a }
        },
        MCPTool(name: "save_queue_as_sonos_playlist",
                description: "save_queue_as_sonos_playlist: store the room's queue as a Sonos playlist, visible to every controller on the system. save_queue_as_playlist keeps it in Choragus on this Mac instead.",
                inputSchema: schema(["room": room, "name": string("Playlist name")], required: ["room", "name"]),
                scope: .manage) { args, server in
            let group = try server.group(named: try args.string("room"))
            let objectID = try await server.manager.saveQueueAsPlaylist(group: group, title: String(try args.string("name").prefix(80)))
            return ["ok": true, "object_id": objectID]
        },
    ]
}
