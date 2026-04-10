/// ServiceSearchProvider.swift — Searches public music APIs and constructs Sonos-playable BrowseItems.
///
/// Uses iTunes Search API (free, no auth) to find tracks, artists, and albums on Apple Music.
/// Results are returned as BrowseItems with x-sonos-http URIs that the speaker can play
/// if Apple Music is connected via the Sonos app.
import Foundation

public enum ServiceSearchEntity: String, CaseIterable, Sendable {
    case all = "All"
    case song = "Songs"
    case album = "Albums"
    case artist = "Artists"

    var iTunesEntity: String {
        switch self {
        case .all: return "song"  // iTunes "all" isn't great; songs give broadest useful results
        case .song: return "song"
        case .album: return "album"
        case .artist: return "musicArtist"
        }
    }
}

public final class ServiceSearchProvider {
    public static let shared = ServiceSearchProvider()

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 15
        self.session = URLSession(configuration: config)
    }

    // MARK: - Apple Music (iTunes Search API)

    /// Search Apple Music via the iTunes Search API.
    /// For `.all`, searches songs + albums concurrently.
    public func searchAppleMusic(query: String, entity: ServiceSearchEntity, sn: Int, limit: Int = 25) async -> [BrowseItem] {
        if entity == .all {
            async let songs = fetchiTunes(query: query, entity: .song, sn: sn, limit: 20)
            async let albums = fetchiTunes(query: query, entity: .album, sn: sn, limit: 10)
            let (s, a) = await (songs, albums)
            return a + s  // Albums first, then songs
        }
        return await fetchiTunes(query: query, entity: entity, sn: sn, limit: limit)
    }

    private func fetchiTunes(query: String, entity: ServiceSearchEntity, sn: Int, limit: Int) async -> [BrowseItem] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?term=\(encoded)&media=music&entity=\(entity.iTunesEntity)&limit=\(limit)") else {
            return []
        }

        do {
            let (data, response) = try await session.data(for: URLRequest(url: url))
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return []
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else {
                return []
            }

            let sid = ServiceID.appleMusic
            let serviceType = (sid << 8) + 7  // 52231

            switch entity {
            case .song, .all:
                return parseSongResults(results, sid: sid, serviceType: serviceType, sn: sn)
            case .album:
                return parseAlbumResults(results, sid: sid, serviceType: serviceType, sn: sn)
            case .artist:
                return parseArtistResults(results)
            }
        } catch {
            sonosDebugLog("[SERVICE_SEARCH] Apple Music search failed: \(error)")
            return []
        }
    }

    // MARK: - Result Parsers

    private func parseSongResults(_ results: [[String: Any]], sid: Int, serviceType: Int, sn: Int) -> [BrowseItem] {
        // Sort by disc then track number to maintain album order
        let sorted = results.sorted { a, b in
            let discA = a["discNumber"] as? Int ?? 1
            let discB = b["discNumber"] as? Int ?? 1
            if discA != discB { return discA < discB }
            let trackA = a["trackNumber"] as? Int ?? 0
            let trackB = b["trackNumber"] as? Int ?? 0
            return trackA < trackB
        }

        return sorted.compactMap { result in
            guard let trackId = result["trackId"] as? Int,
                  let trackName = result["trackName"] as? String,
                  let artistName = result["artistName"] as? String else {
                return nil
            }

            let albumName = result["collectionName"] as? String ?? ""
            let collectionId = result["collectionId"] as? Int ?? 0
            let artURL = upscaleArt(result["artworkUrl100"] as? String)

            let resourceURI = "x-sonos-http:song%3a\(trackId).mp4?sid=\(sid)&flags=8224&sn=\(sn)"
            let metadata = buildTrackDIDL(trackId: trackId, collectionId: collectionId, title: trackName, artist: artistName, album: albumName, serviceType: serviceType)

            return BrowseItem(
                id: "apple:\(trackId)",
                title: trackName,
                artist: artistName,
                album: albumName,
                albumArtURI: artURL,
                itemClass: .musicTrack,
                resourceURI: resourceURI,
                resourceMetadata: metadata
            )
        }
    }

    private func parseAlbumResults(_ results: [[String: Any]], sid: Int, serviceType: Int, sn: Int) -> [BrowseItem] {
        results.compactMap { result in
            guard let collectionId = result["collectionId"] as? Int,
                  let collectionName = result["collectionName"] as? String,
                  let artistName = result["artistName"] as? String else {
                return nil
            }

            let artURL = upscaleArt(result["artworkUrl100"] as? String)

            // Album container URI
            let resourceURI = "x-rincon-cpcontainer:1006206calbum%3a\(collectionId)?sid=\(sid)&flags=8300&sn=\(sn)"
            let metadata = buildAlbumDIDL(collectionId: collectionId, title: collectionName, artist: artistName, serviceType: serviceType)

            return BrowseItem(
                id: "apple:album:\(collectionId)",
                title: collectionName,
                artist: artistName,
                album: "",
                albumArtURI: artURL,
                itemClass: .musicAlbum,
                resourceURI: resourceURI,
                resourceMetadata: metadata
            )
        }
    }

    private func parseArtistResults(_ results: [[String: Any]]) -> [BrowseItem] {
        results.compactMap { result in
            guard let artistId = result["artistId"] as? Int,
                  let artistName = result["artistName"] as? String else {
                return nil
            }

            let artURL = upscaleArt(result["artworkUrl100"] as? String)
            let genre = result["primaryGenreName"] as? String ?? ""

            return BrowseItem(
                id: "apple:artist:\(artistId)",
                title: artistName,
                artist: genre,
                album: "",
                albumArtURI: artURL,
                itemClass: .musicArtist,
                resourceURI: nil,
                resourceMetadata: nil
            )
        }
    }

    /// Fetches artist artwork by looking up their first album.
    /// iTunes API doesn't return artwork for musicArtist entity — use album art as fallback.
    public func resolveArtistArtwork(for items: [BrowseItem]) async -> [BrowseItem] {
        await withTaskGroup(of: (Int, String?).self) { group in
            for (index, item) in items.enumerated() {
                guard item.itemClass == .musicArtist, item.albumArtURI == nil,
                      let artistId = Int(item.objectID.replacingOccurrences(of: "apple:artist:", with: "")) else {
                    continue
                }
                group.addTask {
                    guard let url = URL(string: "https://itunes.apple.com/lookup?id=\(artistId)&entity=album&limit=1") else {
                        return (index, nil)
                    }
                    do {
                        let (data, _) = try await self.session.data(for: URLRequest(url: url))
                        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let results = json["results"] as? [[String: Any]] else { return (index, nil) }
                        let album = results.first { ($0["wrapperType"] as? String) == "collection" }
                        let artURL = self.upscaleArt(album?["artworkUrl100"] as? String)
                        return (index, artURL)
                    } catch {
                        return (index, nil)
                    }
                }
            }
            var updated = items
            for await (index, artURL) in group {
                if let art = artURL, index < updated.count {
                    updated[index] = BrowseItem(
                        id: updated[index].objectID,
                        title: updated[index].title,
                        artist: updated[index].artist,
                        album: updated[index].album,
                        albumArtURI: art,
                        itemClass: updated[index].itemClass,
                        resourceURI: updated[index].resourceURI,
                        resourceMetadata: updated[index].resourceMetadata
                    )
                }
            }
            return updated
        }
    }

    // MARK: - Drill-Down Lookups

    /// Fetch albums by a specific artist via iTunes lookup API.
    public func lookupArtistAlbums(artistId: Int, sn: Int, limit: Int = 25) async -> [BrowseItem] {
        guard let url = URL(string: "https://itunes.apple.com/lookup?id=\(artistId)&entity=album&limit=\(limit)") else {
            return []
        }
        do {
            let (data, response) = try await session.data(for: URLRequest(url: url))
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else { return [] }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else { return [] }

            let sid = ServiceID.appleMusic
            let serviceType = (sid << 8) + 7
            // First result is the artist itself — skip it
            let albumResults = results.filter { ($0["wrapperType"] as? String) == "collection" }
            return parseAlbumResults(albumResults, sid: sid, serviceType: serviceType, sn: sn)
        } catch {
            sonosDebugLog("[SERVICE_SEARCH] Artist album lookup failed: \(error)")
            return []
        }
    }

    /// Fetch tracks for a specific album via iTunes lookup API.
    public func lookupAlbumTracks(collectionId: Int, sn: Int) async -> [BrowseItem] {
        guard let url = URL(string: "https://itunes.apple.com/lookup?id=\(collectionId)&entity=song&limit=50") else {
            return []
        }
        do {
            let (data, response) = try await session.data(for: URLRequest(url: url))
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else { return [] }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else { return [] }

            let sid = ServiceID.appleMusic
            let serviceType = (sid << 8) + 7
            // First result is the album itself — skip it
            let trackResults = results.filter { ($0["wrapperType"] as? String) == "track" }
            return parseSongResults(trackResults, sid: sid, serviceType: serviceType, sn: sn)
        } catch {
            sonosDebugLog("[SERVICE_SEARCH] Album track lookup failed: \(error)")
            return []
        }
    }

    // MARK: - TuneIn Radio (RadioTime OPML API)

    /// Search TuneIn for radio stations via the public RadioTime OPML API.
    /// No auth required. Returns BrowseItems with x-sonosapi-stream URIs.
    public func searchTuneIn(query: String, limit: Int = 25) async -> [BrowseItem] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://opml.radiotime.com/Search.ashx?query=\(encoded)&formats=mp3,aac&render=json") else {
            sonosDebugLog("[SERVICE_SEARCH] TuneIn: failed to build URL for query '\(query)'")
            return []
        }

        do {
            let (data, response) = try await session.data(for: URLRequest(url: url))
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                sonosDebugLog("[SERVICE_SEARCH] TuneIn: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return []
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let body = json["body"] as? [[String: Any]] else {
                sonosDebugLog("[SERVICE_SEARCH] TuneIn: failed to parse JSON response")
                return []
            }

            // Flatten: body may contain category groups with "children" arrays
            var stations: [[String: Any]] = []
            for item in body {
                if let children = item["children"] as? [[String: Any]] {
                    stations.append(contentsOf: children)
                } else if item["type"] as? String == "audio" {
                    stations.append(item)
                }
            }

            sonosDebugLog("[SERVICE_SEARCH] TuneIn: \(body.count) results, \(stations.count) stations for '\(query)'")

            return stations.prefix(limit).compactMap { station -> BrowseItem? in
                guard let guideId = station["guide_id"] as? String,
                      station["type"] as? String == "audio",
                      let text = station["text"] as? String else { return nil }

                let subtext = station["subtext"] as? String ?? ""
                let imageURL = station["image"] as? String

                let resourceURI = "x-sonosapi-stream:\(guideId)?sid=\(ServiceID.tuneIn)&flags=8224&sn=0"
                let metadata = buildTuneInDIDL(guideId: guideId, title: text)

                return BrowseItem(
                    id: "tunein:\(guideId)",
                    title: text,
                    artist: subtext,
                    album: "",
                    albumArtURI: imageURL,
                    itemClass: .radioStation,
                    resourceURI: resourceURI,
                    resourceMetadata: metadata
                )
            }
        } catch {
            sonosDebugLog("[SERVICE_SEARCH] TuneIn search failed: \(error)")
            return []
        }
    }

    /// Browse TuneIn categories or drill into a category URL.
    /// Returns a mix of containers (categories) and stations (playable).
    public func browseTuneIn(url browseURL: String? = nil) async -> [BrowseItem] {
        let urlString = browseURL ?? "https://opml.radiotime.com/Browse.ashx?render=json"
        // Ensure HTTPS and JSON render
        var finalURL = urlString.replacingOccurrences(of: "http://opml", with: "https://opml")
        if !finalURL.contains("render=json") {
            finalURL += finalURL.contains("?") ? "&render=json" : "?render=json"
        }

        guard let url = URL(string: finalURL) else { return [] }

        do {
            let (data, response) = try await session.data(for: URLRequest(url: url))
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else { return [] }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let body = json["body"] as? [[String: Any]] else { return [] }

            var results: [BrowseItem] = []

            for item in body {
                // Items with children: category group (e.g. "Stations", "Shows")
                if let children = item["children"] as? [[String: Any]] {
                    for child in children {
                        if let bi = parseTuneInItem(child) { results.append(bi) }
                    }
                } else {
                    if let bi = parseTuneInItem(item) { results.append(bi) }
                }
            }
            return results
        } catch {
            sonosDebugLog("[SERVICE_SEARCH] TuneIn browse failed: \(error)")
            return []
        }
    }

    private func parseTuneInItem(_ item: [String: Any]) -> BrowseItem? {
        let type = item["type"] as? String ?? ""
        let text = item["text"] as? String ?? ""
        guard !text.isEmpty else { return nil }

        let guideId = item["guide_id"] as? String ?? ""
        let imageURL = item["image"] as? String
        let subtext = item["subtext"] as? String ?? ""
        let browseURL = item["URL"] as? String

        if type == "audio" {
            // Playable station
            let resourceURI = "x-sonosapi-stream:\(guideId)?sid=\(ServiceID.tuneIn)&flags=8224&sn=0"
            let metadata = buildTuneInDIDL(guideId: guideId, title: text)
            return BrowseItem(
                id: "tunein:\(guideId)",
                title: text,
                artist: subtext,
                album: "",
                albumArtURI: imageURL,
                itemClass: .radioStation,
                resourceURI: resourceURI,
                resourceMetadata: metadata
            )
        } else if type == "link", let url = browseURL {
            // Browseable category/subcategory
            return BrowseItem(
                id: "tunein:cat:\(guideId.isEmpty ? text : guideId)",
                title: text,
                artist: subtext,
                album: url,  // Store browse URL in album field for drill-down
                albumArtURI: imageURL,
                itemClass: .container,
                resourceURI: nil,
                resourceMetadata: nil
            )
        }
        return nil
    }

    // MARK: - Calm Radio (Public API)

    /// Calm Radio category with nested channels
    public struct CalmRadioCategory: Identifiable {
        public let id: Int
        public let name: String
        public let channels: [BrowseItem]
    }

    /// Fetch Calm Radio categories and channels from the public API.
    /// Returns top-level categories (Wellness, Nature, Classical, etc.) each containing playable channels.
    public func browseCalmRadio(sn: Int) async -> [CalmRadioCategory] {
        guard let url = URL(string: "https://api.calmradio.com/channels.json") else { return [] }
        do {
            let (data, response) = try await session.data(for: URLRequest(url: url))
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else { return [] }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }

            // Also fetch category names
            let catNames = await fetchCalmRadioCategoryNames()
            let sid = ServiceID.calmRadio
            let serviceType = (sid << 8) + 7 // 36871

            return json.compactMap { entry -> CalmRadioCategory? in
                let catID = entry["category"] as? Int ?? 0
                let channels = entry["channels"] as? [[String: Any]] ?? []
                let catName = catNames[catID] ?? "Category \(catID)"
                guard !channels.isEmpty else { return nil }

                let items = channels.compactMap { ch -> BrowseItem? in
                    guard let chID = ch["id"] as? Int,
                          let title = ch["title"] as? String else { return nil }

                    let imagePath = ch["image"] as? String ?? ""
                    let imageURL = imagePath.isEmpty ? nil : "https://arts.calmradio.com\(imagePath)"
                    let cleanTitle = title.replacingOccurrences(of: "CALMRADIO - ", with: "")

                    let resourceURI = "x-sonosapi-stream:stream%3a\(chID)%3a192?sid=\(sid)&flags=8224&sn=\(sn)"
                    let metadata = buildCalmRadioDIDL(channelId: chID, title: cleanTitle, serviceType: serviceType)

                    return BrowseItem(
                        id: "calm:\(chID)",
                        title: cleanTitle,
                        artist: "",
                        album: "",
                        albumArtURI: imageURL,
                        itemClass: .radioStation,
                        resourceURI: resourceURI,
                        resourceMetadata: metadata
                    )
                }
                return CalmRadioCategory(id: catID, name: catName, channels: items)
            }
        } catch {
            sonosDebugLog("[SERVICE_SEARCH] Calm Radio browse failed: \(error)")
            return []
        }
    }

    private func fetchCalmRadioCategoryNames() async -> [Int: String] {
        guard let url = URL(string: "https://api.calmradio.com/categories.json") else { return [:] }
        do {
            let (data, _) = try await session.data(for: URLRequest(url: url))
            guard let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [:] }
            var names: [Int: String] = [:]
            for topLevel in json {
                for cat in topLevel["categories"] as? [[String: Any]] ?? [] {
                    if let id = cat["id"] as? Int, let name = cat["name"] as? String {
                        names[id] = name.capitalized
                    }
                }
            }
            return names
        } catch {
            return [:]
        }
    }

    private func buildCalmRadioDIDL(channelId: Int, title: String, serviceType: Int) -> String {
        """
        <DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"><item id="10092020stream%3a\(channelId)%3a192" parentID="" restricted="true"><dc:title>\(xmlEscape(title))</dc:title><upnp:class>object.item.audioItem.audioBroadcast</upnp:class><desc id="cdudn" nameSpace="urn:schemas-rinconnetworks-com:metadata-1-0/">SA_RINCON\(serviceType)_X_#Svc\(serviceType)-0-Token</desc></item></DIDL-Lite>
        """
    }

    // MARK: - SMAPI Search (Spotify, Amazon Music, etc.)

    /// Search any authenticated SMAPI service. Uses the service's SOAP search endpoint.
    /// Returns BrowseItems with proper playback URIs and metadata.
    public func searchSMAPI(term: String, searchID: String = "track", serviceID: Int,
                            serviceURI: String, token: SMAPIToken, sn: Int,
                            index: Int = 0, count: Int = 25) async -> [BrowseItem] {
        let client = SMAPIClient()
        do {
            let result = try await client.search(serviceURI: serviceURI, token: token,
                                                  searchID: searchID, term: term,
                                                  index: index, count: count)
            return result.items.map { smapiItemToBrowseItem($0, serviceID: serviceID, sn: sn) }
        } catch {
            sonosDebugLog("[SERVICE_SEARCH] SMAPI search failed for sid=\(serviceID): \(error)")
            return []
        }
    }

    /// Browse into a container on any authenticated SMAPI service.
    public func browseSMAPI(id: String, serviceID: Int, serviceURI: String, token: SMAPIToken,
                            sn: Int, index: Int = 0, count: Int = 50) async -> [BrowseItem] {
        let client = SMAPIClient()
        do {
            let result = try await client.getMetadata(serviceURI: serviceURI, token: token,
                                                       id: id, index: index, count: count)
            return result.items.map { smapiItemToBrowseItem($0, serviceID: serviceID, sn: sn) }
        } catch {
            sonosDebugLog("[SERVICE_SEARCH] SMAPI browse failed for sid=\(serviceID) id=\(id): \(error)")
            return []
        }
    }

    // MARK: - Anonymous SMAPI (for services like Sonos Radio)

    /// Search an anonymous SMAPI service (no auth token needed)
    public func searchSMAPIAnonymous(term: String, searchID: String = "track", serviceID: Int,
                                     serviceURI: String, deviceID: String, householdID: String = "",
                                     sn: Int, index: Int = 0, count: Int = 25) async -> [BrowseItem] {
        let client = SMAPIClient()
        do {
            let result = try await client.searchAnonymous(serviceURI: serviceURI, deviceID: deviceID,
                                                           householdID: householdID,
                                                           searchID: searchID, term: term,
                                                           index: index, count: count)
            return result.items.map { smapiItemToBrowseItem($0, serviceID: serviceID, sn: sn) }
        } catch {
            sonosDebugLog("[SERVICE_SEARCH] Anonymous SMAPI search failed for sid=\(serviceID): \(error)")
            return []
        }
    }

    /// Browse an anonymous SMAPI service container
    public func browseSMAPIAnonymous(id: String, serviceID: Int, serviceURI: String,
                                     deviceID: String, householdID: String = "",
                                     sn: Int, index: Int = 0, count: Int = 50) async -> [BrowseItem] {
        let client = SMAPIClient()
        do {
            let result = try await client.getMetadataAnonymous(serviceURI: serviceURI, deviceID: deviceID,
                                                                householdID: householdID,
                                                                id: id, index: index, count: count)
            return result.items.map { smapiItemToBrowseItem($0, serviceID: serviceID, sn: sn) }
        } catch {
            sonosDebugLog("[SERVICE_SEARCH] Anonymous SMAPI browse failed for sid=\(serviceID) id=\(id): \(error)")
            return []
        }
    }

    // MARK: - DIDL Builders

    private func buildTrackDIDL(trackId: Int, collectionId: Int, title: String, artist: String, album: String, serviceType: Int) -> String {
        """
        <DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"><item id="00032020song%3a\(trackId)" parentID="0004206calbum%3a\(collectionId)" restricted="true"><dc:title>\(xmlEscape(title))</dc:title><dc:creator>\(xmlEscape(artist))</dc:creator><upnp:album>\(xmlEscape(album))</upnp:album><upnp:class>object.item.audioItem.musicTrack</upnp:class><desc id="cdudn" nameSpace="urn:schemas-rinconnetworks-com:metadata-1-0/">SA_RINCON\(serviceType)_X_#Svc\(serviceType)-0-Token</desc></item></DIDL-Lite>
        """
    }

    private func buildAlbumDIDL(collectionId: Int, title: String, artist: String, serviceType: Int) -> String {
        """
        <DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"><item id="1006206calbum%3a\(collectionId)" parentID="" restricted="true"><dc:title>\(xmlEscape(title))</dc:title><dc:creator>\(xmlEscape(artist))</dc:creator><upnp:class>object.container.album.musicAlbum</upnp:class><desc id="cdudn" nameSpace="urn:schemas-rinconnetworks-com:metadata-1-0/">SA_RINCON\(serviceType)_X_#Svc\(serviceType)-0-Token</desc></item></DIDL-Lite>
        """
    }

    private func buildTuneInDIDL(guideId: String, title: String) -> String {
        """
        <DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"><item id="F00092020\(guideId)" parentID="L" restricted="true"><dc:title>\(xmlEscape(title))</dc:title><upnp:class>object.item.audioItem.audioBroadcast</upnp:class><desc id="cdudn" nameSpace="urn:schemas-rinconnetworks-com:metadata-1-0/">SA_RINCON3079_</desc></item></DIDL-Lite>
        """
    }

    /// Builds DIDL metadata matching the exact format Sonos favorites use for service tracks.
    /// Based on r:resMD from actual Sonos Favorite browse response.
    private func buildSMAPIDIDL(id: String, title: String, artist: String, album: String,
                                itemType: String, serviceType: Int) -> String {
        let upnpClass = itemType == "track" ? "object.item.audioItem.musicTrack" : "object.item.audioItem.audioBroadcast"
        // Sonos item ID: prefix + URL-encoded service ID (colons → %3a)
        let encodedID = id.replacingOccurrences(of: ":", with: "%3a")
        let idPrefix = itemType == "track" ? "10032020" : "1004206c"
        return """
        <DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"><item id="\(idPrefix)\(encodedID)" parentID="" restricted="true"><dc:title>\(xmlEscape(title))</dc:title><upnp:class>\(upnpClass)</upnp:class><desc id="cdudn" nameSpace="urn:schemas-rinconnetworks-com:metadata-1-0/">SA_RINCON\(serviceType)_X_#Svc\(serviceType)-0-Token</desc></item></DIDL-Lite>
        """
    }

    // MARK: - Per-Service URI Construction

    /// Known RINCON service types — SMAPI sid does not always match RINCON sid.
    private static let rinconServiceTypes: [Int: Int] = [:] // Reserved for future overrides

    /// Services that use a custom URI prefix instead of x-sonos-http
    private static let serviceURIPrefixes: [Int: String] = [
        ServiceID.spotify: "x-sonos-spotify:",
    ]

    /// Returns the correct RINCON service type for a given SMAPI service ID.
    private func rinconServiceType(for serviceID: Int) -> Int {
        Self.rinconServiceTypes[serviceID] ?? (serviceID << 8) + 7
    }

    /// Builds the correct playback URI for a track from an SMAPI service.
    /// Colons in service-specific IDs (e.g. spotify:track:xxx) must be percent-encoded to %3a.
    private func buildPlayURI(itemID: String, itemType: String, serviceID: Int, sn: Int) -> String {
        let prefix = Self.serviceURIPrefixes[serviceID] ?? "x-sonos-http:"
        // Percent-encode first, then replace colons with lowercase %3a (Sonos is case-sensitive).
        // Also lowercase any uppercase hex from addingPercentEncoding (e.g. %3A → %3a).
        var encodedID = (itemID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? itemID)
            .replacingOccurrences(of: ":", with: "%3a")
        // Force lowercase hex — Sonos rejects uppercase percent-encoding for Spotify URIs
        encodedID = encodedID.replacingOccurrences(of: "%3A", with: "%3a")
        if itemType == "stream" || itemType == "program" {
            return "x-sonosapi-stream:\(encodedID)?sid=\(serviceID)&flags=8224&sn=\(sn)"
        }
        return "\(prefix)\(encodedID)?sid=\(serviceID)&flags=8224&sn=\(sn)"
    }

    /// Converts an SMAPIMediaItem to a BrowseItem with correct per-service URI and metadata.
    public func smapiItemToBrowseItem(_ smapi: SMAPIMediaItem, serviceID: Int, sn: Int) -> BrowseItem {
        let serviceType = rinconServiceType(for: serviceID)
        let playURI: String?
        if !smapi.canBrowse && !smapi.id.isEmpty {
            playURI = buildPlayURI(itemID: smapi.id, itemType: smapi.itemType, serviceID: serviceID, sn: sn)
        } else {
            playURI = smapi.uri.isEmpty ? nil : smapi.uri
        }

        let didlMeta: String?
        if let uri = playURI, !smapi.canBrowse {
            didlMeta = buildSMAPIDIDL(id: smapi.id, title: smapi.title, artist: smapi.artist,
                                      album: smapi.album, itemType: smapi.itemType,
                                      serviceType: serviceType)
        } else {
            didlMeta = nil
        }

        return BrowseItem(
            id: "smapi:\(serviceID):\(smapi.id)",
            title: smapi.title,
            artist: smapi.artist,
            album: smapi.album,
            albumArtURI: smapi.albumArtURI.isEmpty ? nil : smapi.albumArtURI,
            itemClass: smapi.canBrowse ? .container : (smapi.itemType == "album" ? .musicAlbum : .musicTrack),
            resourceURI: playURI,
            resourceMetadata: didlMeta
        )
    }

    // MARK: - Helpers

    private func upscaleArt(_ url: String?) -> String? {
        url?.replacingOccurrences(of: "100x100", with: "600x600")
           .replacingOccurrences(of: "60x60", with: "600x600")
    }

    private func xmlEscape(_ str: String) -> String {
        str.replacingOccurrences(of: "&", with: "&amp;")
           .replacingOccurrences(of: "<", with: "&lt;")
           .replacingOccurrences(of: ">", with: "&gt;")
           .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
