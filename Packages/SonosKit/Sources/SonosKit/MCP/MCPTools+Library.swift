/// MCPTools+Library.swift — The Sonos music library, media servers,
/// radio, favorites and streaming-service search. Every result carries
/// an id that play_item, add_to_queue and the playlist tools accept.
import Foundation

extension MCPTool {
    static let searchTypes: [String: String] = [
        "tracks": BrowseID.tracks,
        "artists": "A:ARTIST",
        "album_artists": BrowseID.albumArtist,
        "albums": BrowseID.album,
        "genres": "A:GENRE",
        "composers": "A:COMPOSER",
        "playlists": "A:PLAYLISTS",
    ]

    static let library: [MCPTool] = [
        MCPTool(name: "search",
                description: "search: find music in the local Sonos music library (NAS / shared folders) — songs, tracks, artists, albums, genres, composers, imported playlists. type picks what to match (default tracks). Artists, albums and genres come back as containers to browse_library into. For streaming services use search_service; for radio search_radio.",
                inputSchema: schema(["query": string("Words to match"),
                                     "type": choice(Array(searchTypes.keys).sorted(), "Default tracks"),
                                     "limit": integer("1-50, default 20", min: 1, max: 50)],
                                    required: ["query"]), scope: .readOnly) { args, server in
            let manager = try server.manager
            let query = String(try args.string("query").prefix(200))
            let type = args.optionalString("type") ?? "tracks"
            guard let container = searchTypes[type] else { throw MCPError.invalidParams("Unknown type \(type)") }
            let limit = args.limit(default: 20, max: 50)
            let result = try await manager.search(query: query, in: container, householdID: nil, count: limit)
            return ["items": server.remember(result.items).map(Encode.item), "total": result.total, "type": type]
        },
        MCPTool(name: "browse_library",
                description: "Walk the Sonos music library. Without container_id, lists the top-level sections (artists, albums, genres, composers, folders, Sonos favorites, Sonos playlists). Pass a container_id from any result to open it.",
                inputSchema: schema(["container_id": string("From browse_library or search; omit for the top level"),
                                     "start": integer("Offset for paging, default 0", min: 0),
                                     "limit": integer("1-100, default 50", min: 1, max: 100)]), scope: .readOnly) { args, server in
            let manager = try server.manager
            guard let container = args.optionalString("container_id") else {
                if manager.browseSections.isEmpty { await manager.loadBrowseSections() }
                return ["sections": manager.browseSections.map {
                    ["title": $0.title, "container_id": $0.objectID, "note": $0.availabilityNote ?? ""]
                }]
            }
            let start = max(0, args.optionalInt("start") ?? 0)
            let limit = args.limit(default: 50, max: 100)
            let result = try await manager.browse(objectID: container, householdID: nil, start: start, count: limit)
            return ["items": server.remember(result.items).map(Encode.item), "total": result.total, "start": start]
        },
        MCPTool(name: "library_shares", description: "The network folders the Sonos music library indexes, per system.",
                inputSchema: schema([:]), scope: .readOnly) { _, server in
            let shares = await (try server.manager).libraryShares()
            return ["shares": shares.map { ["path": $0.objectID, "household": $0.householdID] }]
        },
        MCPTool(name: "reindex_library", description: "Ask every system to re-scan its music library folders. Requires confirm=true.",
                inputSchema: schema(["confirm": boolean("")], required: ["confirm"]), scope: .manage) { args, server in
            try server.requireConfirm(args)
            let result = await (try server.manager).updateMusicLibrary()
            return ["ok": result.triggered > 0, "systems_triggered": result.triggered, "libraries_found": result.librariesFound]
        },

        // MARK: Media servers

        MCPTool(name: "list_media_servers", description: "DLNA/UPnP media servers (Plex, MinimServer, NAS) found on the network.",
                inputSchema: schema([:]), scope: .readOnly) { _, server in
            let manager = try server.manager
            if manager.mediaServers.isEmpty, manager.mediaServersEnabled { await manager.discoverMediaServers() }
            return ["servers": manager.mediaServers.map { server -> [String: Any] in
                var row: [String: Any] = ["id": server.id, "name": server.name, "model": server.modelName]
                // The name the server itself announces, when the user has
                // given it another; either resolves in the other tools.
                if server.isRenamed { row["advertised_name"] = server.advertisedName }
                return row
            }]
        },
        MCPTool(name: "browse_media_server", description: "Walk a media server's folders. Omit container_id for its root.",
                inputSchema: schema(["server": string("Name or id from list_media_servers"),
                                     "container_id": string("From a previous browse"),
                                     "start": integer("Offset, default 0", min: 0),
                                     "limit": integer("1-200, default 50", min: 1, max: 200)],
                                    required: ["server"]), scope: .readOnly) { args, server in
            let target = try server.mediaServer(try args.string("server"))
            let start = max(0, args.optionalInt("start") ?? 0)
            let limit = args.limit(default: 50, max: 200)
            let items: [BrowseItem]
            if let container = args.optionalString("container_id") {
                items = try await MediaServerService.browse(server: target, objectID: container, start: start, count: limit)
            } else {
                items = await MediaServerService.browseRoot(server: target)
            }
            return ["items": server.remember(items).map(Encode.item), "start": start]
        },
        MCPTool(name: "search_media_server", description: "Search a media server's tracks by title words.",
                inputSchema: schema(["server": string("Name or id from list_media_servers"),
                                     "query": string(""),
                                     "limit": integer("1-50, default 20", min: 1, max: 50)],
                                    required: ["server", "query"]), scope: .readOnly) { args, server in
            let target = try server.mediaServer(try args.string("server"))
            let query = String(try args.string("query").prefix(200))
            let items = await MediaServerService.search(server: target, term: query, count: args.limit(default: 20, max: 50))
            return ["items": server.remember(items).map(Encode.item)]
        },

        // MARK: Radio and favorites

        MCPTool(name: "search_radio", description: "Find internet radio stations by name or topic (TuneIn). Play a result with play_item.",
                inputSchema: schema(["query": string(""), "limit": integer("1-50, default 20", min: 1, max: 50)],
                                    required: ["query"]), scope: .readOnly) { args, server in
            _ = try server.manager
            let query = String(try args.string("query").prefix(200))
            let items = await ServiceSearchProvider.shared.searchTuneIn(query: query, limit: args.limit(default: 20, max: 50))
            return ["items": server.remember(items).map(Encode.item)]
        },
        MCPTool(name: "list_favorites", description: "Sonos favorites (stations, albums, playlists saved in the Sonos app). Play one with play_item.",
                inputSchema: schema(["limit": integer("1-100, default 100", min: 1, max: 100)]), scope: .readOnly) { args, server in
            let manager = try server.manager
            let result = try await manager.browse(objectID: BrowseID.favorites, householdID: nil, count: args.limit(default: 100, max: 100))
            return ["items": server.remember(result.items).map(Encode.item), "total": result.total]
        },

        // MARK: Streaming services

        MCPTool(name: "list_music_services", description: "Streaming services this household can search and play from.",
                inputSchema: schema([:]), scope: .readOnly) { _, server in
            _ = try server.manager
            var services: [[String: Any]] = [["name": ServiceName.appleMusic, "signed_in": true, "search": true]]
            if let smapi = SMAPIAuthManager.current {
                services += smapi.authenticatedServiceList
                    .filter { $0.name != ServiceName.appleMusic }
                    .map { ["name": $0.name, "signed_in": true, "search": true] }
            }
            return ["services": services, "match_services": server.matchServiceNames()]
        },
        MCPTool(name: "search_service", description: "Search a streaming service (Apple Music, or any signed-in service from list_music_services).",
                inputSchema: schema(["service": string("Service name"),
                                     "query": string(""),
                                     "type": choice(["songs", "albums", "artists"], "Default songs"),
                                     "limit": integer("1-50, default 20", min: 1, max: 50)],
                                    required: ["service", "query"]), scope: .readOnly) { args, server in
            _ = try server.manager
            let name = try args.string("service")
            let query = String(try args.string("query").prefix(200))
            let type = args.optionalString("type") ?? "songs"
            let limit = args.limit(default: 20, max: 50)
            let items: [BrowseItem]
            if name.lowercased() == ServiceName.appleMusic.lowercased() || name.lowercased() == "apple_music" {
                let entity: ServiceSearchEntity = type == "albums" ? .album : (type == "artists" ? .artist : .song)
                items = await ServiceSearchProvider.shared.searchAppleMusic(query: query, entity: entity,
                                                                           sn: try server.appleMusicSerial, limit: limit)
            } else {
                let smapi = try server.smapi
                let service = try server.musicService(name)
                guard let token = smapi.tokenStore.getToken(for: service.id) else {
                    throw MCPError.invalidParams("\(service.name) has no stored sign-in")
                }
                // Search ids are per service. Most answer to the generic
                // `track` / `album` / `artist`, but a service may publish
                // its own — Amazon Music uses `catalog:tracks:search` and
                // friends, and answers a generic id with an EMPTY result
                // rather than a fault, so the wrong id used to read as a
                // search that simply found nothing.
                let kind: SMAPISearchCategories.Kind = type == "albums" ? .albums
                    : (type == "artists" ? .artists : .tracks)
                let categories = await SMAPISearchCategories.resolve(
                    serviceID: service.id, serviceURI: service.secureUri, token: token)
                let sn = smapi.serialNumber(for: service.id)
                var found: [BrowseItem] = []
                var failure: Error?
                // Each id in turn until one answers: the service's own
                // category for this kind, then its search-everything
                // category (Amazon's tracks category returns nothing for
                // terms its universal category matches), then the generic.
                for searchID in SMAPISearchCategories.searchIDs(for: kind, in: categories) {
                    do {
                        found = try await ServiceSearchProvider.shared.searchSMAPIThrowing(
                            term: query, searchID: searchID, serviceID: service.id,
                            serviceURI: service.secureUri, token: token, sn: sn, count: limit)
                        failure = nil
                        if !found.isEmpty { break }
                    } catch {
                        failure = error
                    }
                }
                // Every id failed to answer. An empty list would say the
                // service found nothing, which is a different thing.
                if let failure, found.isEmpty {
                    throw MCPError.internal("\(service.name) search failed: \(failure.localizedDescription)")
                }
                items = found
            }
            return ["items": server.remember(items).map(Encode.item)]
        },

        MCPTool(name: "check_media_server", description: "check_media_server: ask every speaker whether it can reach a media server, and name the ones that cannot — the usual cause of a server that browses but will not play.",
                inputSchema: schema(["server": string("Name or id from list_media_servers")], required: ["server"])) { args, server in
            let manager = try server.manager
            let target = try server.mediaServer(try args.string("server"))
            await manager.verifyMediaServerReachability(id: target.id)
            let verdicts = manager.mediaServerReachability[target.id] ?? []
            return ["server": target.name,
                    "speakers": verdicts.map { ["room": $0.roomName, "state": $0.state.rawValue] },
                    "unreachable": verdicts.filter { $0.state != .reachable }.map(\.roomName)]
        },
        MCPTool(name: "play_suno_link", description: "play_suno_link: play a suno.com song or share link (or a bare clip id) in a room, the way pasting the link into Browse does.",
                inputSchema: schema(["room": room, "link": string("suno.com URL or clip id"),
                                     "mode": choice(["now", "next", "end"], "Default now")],
                                    required: ["room", "link"])) { args, server in
            let manager = try server.manager
            let group = try server.group(named: try args.string("room"))
            let item: BrowseItem
            do {
                item = try await SunoResolver.resolve(String(try args.string("link").prefix(500)))
            } catch {
                throw MCPError.invalidParams("That Suno link could not be resolved")
            }
            _ = server.remember([item])
            switch args.optionalString("mode") ?? "now" {
            case "next": _ = try await manager.addBrowseItemToQueue(item, in: group, playNext: true)
            case "end": _ = try await manager.addBrowseItemToQueue(item, in: group, playNext: false)
            default: try await manager.playBrowseItem(item, in: group)
            }
            return ["ok": true, "title": MCPTool.cap(item.title), "artist": MCPTool.cap(item.artist)]
        },
        MCPTool(name: "get_lyrics", description: "get_lyrics: lyrics for what a room is playing, or for a named track — synced line by line where they exist, otherwise plain text.",
                inputSchema: schema(["room": string("Room whose current track to look up"),
                                     "title": string("Track title; alternative to room"),
                                     "artist": string("Track artist; used with title")],
                                    oneOf: [["room"], ["title"]]), scope: .readOnly) { args, server in
            guard let provider = server.lyricsProvider else { throw MCPError.internal("Lyrics are unavailable") }
            var title = args.optionalString("title") ?? ""
            var artist = args.optionalString("artist") ?? ""
            var album: String?
            var uri: String?
            if let roomName = args.optionalString("room") {
                let group = try server.group(named: roomName)
                guard let meta = try server.manager.groupTrackMetadata[group.coordinatorID], !meta.title.isEmpty else {
                    throw MCPError.invalidParams("\(group.name) is not playing a track")
                }
                title = meta.title; artist = meta.artist; album = meta.album; uri = meta.trackURI
            }
            guard !title.isEmpty else { throw MCPError.invalidParams("Pass room, or title and artist") }
            guard let lyrics = await provider(artist, title, album, uri) else {
                return ["title": MCPTool.cap(title), "artist": MCPTool.cap(artist), "found": false]
            }
            var out: [String: Any] = ["title": MCPTool.cap(title), "artist": MCPTool.cap(artist), "found": true,
                                      "instrumental": lyrics.instrumental]
            if let plain = lyrics.plain { out["plain"] = plain }
            if let synced = lyrics.synced { out["synced"] = synced }
            return out
        },
        MCPTool(name: "get_artist_info", description: "get_artist_info: the artist biography, tags, similar artists and listener count Choragus shows in the About tab.",
                inputSchema: schema(["artist": string("Artist name")], required: ["artist"]), scope: .readOnly) { args, server in
            guard let provider = server.artistInfoProvider else { throw MCPError.internal("Artist information is unavailable") }
            let name = String(try args.string("artist").prefix(200))
            guard let info = await provider(name) else { return ["artist": name, "found": false] }
            return info.merging(["found": true]) { a, _ in a }
        },
        MCPTool(name: "get_album_info", description: "get_album_info: release date, summary, tags and track list for an album.",
                inputSchema: schema(["artist": string("Artist name"), "album": string("Album title")],
                                    required: ["artist", "album"]), scope: .readOnly) { args, server in
            guard let provider = server.albumInfoProvider else { throw MCPError.internal("Album information is unavailable") }
            let artist = String(try args.string("artist").prefix(200)), album = String(try args.string("album").prefix(200))
            guard let info = await provider(artist, album) else { return ["artist": artist, "album": album, "found": false] }
            return info.merging(["found": true]) { a, _ in a }
        },
    ]
}
