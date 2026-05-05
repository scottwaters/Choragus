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

    /// Thread-safe mirror of SMAPI auth tokens, keyed by sid. Pushed
    /// in from `SMAPIAuthManager` whenever its token store changes.
    /// `buildSMAPIDIDL` reads this synchronously to inject the
    /// per-service token into cdudn — needed for services Choragus
    /// has authenticated via AppLink (the speaker household's own
    /// binding token is not retrievable from current firmware).
    private let authTokenLock = NSLock()
    private var cachedAuthTokens: [Int: String] = [:]

    public func updateAuthTokens(_ tokens: [Int: String]) {
        authTokenLock.lock()
        defer { authTokenLock.unlock() }
        cachedAuthTokens = tokens
    }

    private func authToken(forSid sid: Int) -> String? {
        authTokenLock.lock()
        defer { authTokenLock.unlock() }
        return cachedAuthTokens[sid]
    }

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
              let url = URL(string: "https://itunes.apple.com/search?term=\(encoded)&media=music&entity=\(entity.iTunesEntity)&limit=\(limit)\(Self.countryQueryParam())") else {
            return []
        }

        // User-facing search bypasses the self-throttle so background art
        // lookups can't starve it. Apple-side 403/429 still short-circuits
        // (and the UI can surface that via `ITunesRateLimiter.snapshot()`).
        guard let (data, _) = await ITunesRateLimiter.shared.performUnthrottled(url: url, session: session) else {
            return []
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            return []
        }

        // Resolve via the catalog so households whose Apple Music sid
        // drifted from the compile-time constant get the right runtime
        // value. Falls back to the constant when the catalog hasn't
        // loaded yet (first-launch race), matching pre-catalog behaviour.
        let sid = MusicServiceCatalog.shared.sid(forName: ServiceName.appleMusic) ?? ServiceID.appleMusic
        let serviceType = MusicServiceCatalog.shared.rinconServiceType(forSid: sid)

        switch entity {
        case .song, .all:
            return parseSongResults(results, sid: sid, serviceType: serviceType, sn: sn)
        case .album:
            return parseAlbumResults(results, sid: sid, serviceType: serviceType, sn: sn)
        case .artist:
            return parseArtistResults(results)
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
            let relDate = Self.parseISODate(result["releaseDate"] as? String)

            // Reverted to v3.7's working form: hardcoded `flags=8224`.
            // The `serviceFlagsOverrides` table (which maps Apple Music
            // → 8232) is for SMAPI-browse items routed through
            // `buildPlayURI`; iTunes-search-derived items use the
            // legacy `8224` flag and have done so reliably since the
            // feature first shipped.
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
                resourceMetadata: metadata,
                releaseDate: relDate
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
            let relDate = Self.parseISODate(result["releaseDate"] as? String)

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
                resourceMetadata: metadata,
                releaseDate: relDate
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
                    guard let url = URL(string: "https://itunes.apple.com/lookup?id=\(artistId)&entity=album&limit=1\(Self.countryQueryParam())") else {
                        return (index, nil)
                    }
                    guard let (data, _) = await ITunesRateLimiter.shared.perform(url: url, session: self.session) else {
                        return (index, nil)
                    }
                    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let results = json["results"] as? [[String: Any]] else { return (index, nil) }
                    let album = results.first { ($0["wrapperType"] as? String) == "collection" }
                    let artURL = self.upscaleArt(album?["artworkUrl100"] as? String)
                    return (index, artURL)
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

    /// Returns `&country=<region>` based on the user's current locale, or
    /// empty string if the region can't be determined. Critical for
    /// Apple-Music-derived track/album IDs to match the user's actual
    /// storefront — without it, iTunes Search defaults to US, and the
    /// US-specific track IDs don't exist in non-US Apple Music catalogues
    /// (Sonos returns "item is no longer available" on play).
    private static func countryQueryParam() -> String {
        guard let region = Locale.current.region?.identifier, !region.isEmpty else {
            return ""
        }
        return "&country=\(region.lowercased())"
    }

    /// Fetch albums by a specific artist via iTunes lookup API.
    public func lookupArtistAlbums(artistId: Int, sn: Int, limit: Int = 25) async -> [BrowseItem] {
        guard let url = URL(string: "https://itunes.apple.com/lookup?id=\(artistId)&entity=album&limit=\(limit)\(Self.countryQueryParam())") else {
            return []
        }
        // User-initiated drill-down — bypass the self-throttle (background
        // art enrichment can starve it otherwise). Apple-side 403/429 still
        // respected; the UI surfaces that via the cooldown banner.
        guard let (data, _) = await ITunesRateLimiter.shared.performUnthrottled(url: url, session: session) else {
            return []
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return [] }

        let sid = MusicServiceCatalog.shared.sid(forName: ServiceName.appleMusic) ?? ServiceID.appleMusic
        let serviceType = MusicServiceCatalog.shared.rinconServiceType(forSid: sid)
        // First result is the artist itself — skip it
        let albumResults = results.filter { ($0["wrapperType"] as? String) == "collection" }
        return parseAlbumResults(albumResults, sid: sid, serviceType: serviceType, sn: sn)
    }

    /// Fetch tracks for a specific album via iTunes lookup API.
    public func lookupAlbumTracks(collectionId: Int, sn: Int) async -> [BrowseItem] {
        guard let url = URL(string: "https://itunes.apple.com/lookup?id=\(collectionId)&entity=song&limit=50\(Self.countryQueryParam())") else {
            return []
        }
        // User-initiated drill-down — same reasoning as lookupArtistAlbums.
        guard let (data, _) = await ITunesRateLimiter.shared.performUnthrottled(url: url, session: session) else {
            return []
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return [] }

        let sid = MusicServiceCatalog.shared.sid(forName: ServiceName.appleMusic) ?? ServiceID.appleMusic
        let serviceType = MusicServiceCatalog.shared.rinconServiceType(forSid: sid)
        // First result is the album itself — skip it
        let trackResults = results.filter { ($0["wrapperType"] as? String) == "track" }
        return parseSongResults(trackResults, sid: sid, serviceType: serviceType, sn: sn)
    }

    // MARK: - TuneIn Radio (RadioTime OPML API)

    /// True for TuneIn guide IDs that aren't live broadcast stations —
    /// topics (t-prefix) are show episodes, programs (p-prefix) are
    /// podcast feeds, and recordings (g-prefix) are on-demand. These
    /// reject `x-sonosapi-stream:` with UPnP 800 because they're not
    /// audioBroadcasts; they need RadioTime's Tune.ashx resolver to a
    /// direct MP3/HLS URL.
    private func tuneInNeedsResolve(_ guideId: String) -> Bool {
        guard let first = guideId.first else { return false }
        return first == "t" || first == "p" || first == "g"
    }

    /// Result of resolving a TuneIn guide ID via RadioTime's public
    /// Tune.ashx endpoint. The `directURL` is the raw HTTPS URL the
    /// speaker should fetch (passed verbatim to AddURIToQueue for
    /// finite content like podcast episodes); `sonosStreamURI` is the
    /// `x-rincon-mp3radio://` form for continuous broadcasts. Caller
    /// chooses the playback path: queue-based for media types that are
    /// finite (mp3 podcast file), stream-based for live audio.
    public struct TuneInResolved: Sendable {
        public let directURL: String
        public let sonosStreamURI: String
        public let mediaType: String
    }

    /// Resolves a TuneIn guide ID to a directly playable Sonos URI by
    /// calling `https://opml.radiotime.com/Tune.ashx?id=<guideId>`.
    /// Returns nil if RadioTime returns no playable entry. The caller
    /// is expected to fetch this at play time (some entries return
    /// short-lived JWT-tokenised URLs that go stale within minutes).
    public func resolveTuneIn(guideId: String) async -> TuneInResolved? {
        guard let url = URL(string: "https://opml.radiotime.com/Tune.ashx?id=\(guideId)&render=json&formats=mp3,aac,ogg,hls") else {
            sonosDebugLog("[TUNEIN-RESOLVE] failed to build Tune.ashx URL for \(guideId)")
            return nil
        }
        do {
            let (data, response) = try await session.data(for: URLRequest(url: url))
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                sonosDebugLog("[TUNEIN-RESOLVE] HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0) for \(guideId)")
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let body = json["body"] as? [[String: Any]] else {
                sonosDebugLog("[TUNEIN-RESOLVE] unparseable Tune.ashx response for \(guideId)")
                return nil
            }
            // Prefer is_direct entries; fall through to first entry with a URL.
            let entry = body.first(where: { ($0["is_direct"] as? Bool) == true })
                ?? body.first(where: { ($0["url"] as? String).map { !$0.isEmpty } ?? false })
            guard let entry,
                  let urlStr = entry["url"] as? String,
                  !urlStr.isEmpty else {
                sonosDebugLog("[TUNEIN-RESOLVE] no playable entry for \(guideId)")
                return nil
            }
            let mediaType = (entry["media_type"] as? String)?.lowercased() ?? "mp3"
            // Two URI forms are returned and the caller decides which to
            // use based on whether the content is finite or continuous:
            // - sonosStreamURI: `x-rincon-mp3radio://<host_and_path>` —
            //   the legacy Sonos ICY/Shoutcast scheme. Strips https; the
            //   speaker connects via HTTP. Works for live broadcasts but
            //   fails on HTTPS-only podcast CDNs (fireside.fm, etc.) and
            //   one-shot finite files (Sonos rejects the `:https://`
            //   variant with UPnP 714 Illegal MIME Type).
            // - directURL: the raw URL untouched. For podcast episodes
            //   pass this to AddURIToQueue with a track DIDL; Sonos's
            //   queue fetches HTTPS correctly.
            let stripped = urlStr
                .replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: "http://", with: "")
            let sonosStreamURI: String
            switch mediaType {
            case "hls":
                sonosStreamURI = "x-sonosapi-hls:\(urlStr)"
            default:
                sonosStreamURI = "x-rincon-mp3radio://\(stripped)"
            }
            sonosDebugLog("[TUNEIN-RESOLVE] \(guideId) → \(mediaType) directURL=\(urlStr.prefix(80))")
            return TuneInResolved(directURL: urlStr, sonosStreamURI: sonosStreamURI, mediaType: mediaType)
        } catch {
            sonosDebugLog("[TUNEIN-RESOLVE] failed for \(guideId): \(error)")
            return nil
        }
    }

    /// Minimal generic-broadcast DIDL for resolved TuneIn items. Plays
    /// without a `SA_RINCON*` cdudn because the URI is a direct stream
    /// URL — no service binding is required.
    public func buildResolvedTuneInDIDL(title: String) -> String {
        """
        <DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"><item id="-1" parentID="-1" restricted="true"><dc:title>\(xmlEscape(title))</dc:title><upnp:class>object.item.audioItem.audioBroadcast</upnp:class></item></DIDL-Lite>
        """
    }

    /// Track-class DIDL with `<res>` for queue-based playback of a
    /// finite media file (podcast episode). The `protocolInfo` reflects
    /// the resolved media type so the speaker advertises the right MIME
    /// to its decoder. Used by AddURIToQueue when the URI is an HTTPS
    /// direct URL that the legacy `x-rincon-mp3radio://` scheme can't
    /// reach.
    public func buildResolvedTuneInTrackDIDL(title: String, artist: String, url: String, mediaType: String) -> String {
        let protocolInfo: String
        switch mediaType.lowercased() {
        case "aac":  protocolInfo = "http-get:*:audio/aac:*"
        case "ogg":  protocolInfo = "http-get:*:audio/ogg:*"
        case "hls":  protocolInfo = "http-get:*:application/vnd.apple.mpegurl:*"
        default:     protocolInfo = "http-get:*:audio/mpeg:*"
        }
        return """
        <DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"><item id="-1" parentID="-1" restricted="true"><dc:title>\(xmlEscape(title))</dc:title><dc:creator>\(xmlEscape(artist))</dc:creator><upnp:class>object.item.audioItem.musicTrack</upnp:class><res protocolInfo="\(protocolInfo)">\(xmlEscape(url))</res></item></DIDL-Lite>
        """
    }


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

                let tuneInSid = MusicServiceCatalog.shared.sid(forName: ServiceName.tuneIn) ?? ServiceID.tuneIn
                let resourceURI = "x-sonosapi-stream:\(guideId)?sid=\(tuneInSid)&flags=8224&sn=0"
                let metadata = buildTuneInDIDL(guideId: guideId, title: text)

                var item = BrowseItem(
                    id: "tunein:\(guideId)",
                    title: text,
                    artist: subtext,
                    album: "",
                    albumArtURI: imageURL,
                    itemClass: .radioStation,
                    resourceURI: resourceURI,
                    resourceMetadata: metadata
                )
                if tuneInNeedsResolve(guideId) {
                    item.playbackStrategy = .tuneInResolveViaRadioTime
                }
                return item
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
            // Playable station or topic/podcast episode.
            let resourceURI = "x-sonosapi-stream:\(guideId)?sid=\(ServiceID.tuneIn)&flags=8224&sn=0"
            let metadata = buildTuneInDIDL(guideId: guideId, title: text)
            var item = BrowseItem(
                id: "tunein:\(guideId)",
                title: text,
                artist: subtext,
                album: "",
                albumArtURI: imageURL,
                itemClass: .radioStation,
                resourceURI: resourceURI,
                resourceMetadata: metadata
            )
            if tuneInNeedsResolve(guideId) {
                item.playbackStrategy = .tuneInResolveViaRadioTime
            }
            return item
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
            let sid = MusicServiceCatalog.shared.sid(forName: ServiceName.calmRadio) ?? ServiceID.calmRadio
            let serviceType = MusicServiceCatalog.shared.rinconServiceType(forSid: sid)

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
        let client = SMAPIClient.shared
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
        let client = SMAPIClient.shared
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
        let client = SMAPIClient.shared
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
        let client = SMAPIClient.shared
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

    /// Track DIDL for iTunes-search-derived Apple Music tracks.
    /// Matches v3.7's working form exactly — `00032020song:<id>` ID with
    /// `0004206calbum:<collectionId>` parent, including `dc:creator` and
    /// `upnp:album`. This is what Sonos accepted for both single-track
    /// `AddURIToQueue` and bulk `AddMultipleURIsToQueue` in the released
    /// build. Earlier "fixes" to mirror the SMAPI-favorite shape
    /// (`10032020song:` + empty parentID, drop creator/album) caused
    /// "item no longer available" rejections during queue-advance.
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
                                itemType: String, serviceID: Int, serviceType: Int) -> String {
        let upnpClass = itemType == "track" ? "object.item.audioItem.musicTrack" : "object.item.audioItem.audioBroadcast"
        // Sonos item ID: prefix + URL-encoded service ID (colons → %3a)
        let encodedID = id.replacingOccurrences(of: ":", with: "%3a")
        // Prefix selection routes through MusicServiceCatalog so any
        // per-service overrides win, with the universal Sonos prefixes
        // as the fallback when the catalog has no rules for this sid.
        // `10032020` = musicTrack, `10092020` = audioBroadcast
        // (stream/program), `1004206c` = generic container.
        let catalog = MusicServiceCatalog.shared
        let idPrefix: String
        switch itemType {
        case "track":              idPrefix = catalog.didlTrackIdPrefix(forSid: serviceID)
        case "stream", "program":  idPrefix = catalog.didlStreamIdPrefix(forSid: serviceID)
        default:                   idPrefix = catalog.didlContainerIdPrefix(forSid: serviceID)
        }
        // cdudn auth-token resolution: prefer a Choragus-side AppLink
        // token if the user authenticated the service through us;
        // otherwise emit the anonymous cdudn (which the speaker
        // accepts only for genuinely-anonymous services like Sonos
        // Radio and TuneIn-anonymous).
        let cdudn: String = catalog.cdudn(forSid: serviceID, authToken: authToken(forSid: serviceID))
        return """
        <DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"><item id="\(idPrefix)\(encodedID)" parentID="-1" restricted="true"><dc:title>\(xmlEscape(title))</dc:title><upnp:class>\(upnpClass)</upnp:class><desc id="cdudn" nameSpace="urn:schemas-rinconnetworks-com:metadata-1-0/">\(cdudn)</desc></item></DIDL-Lite>
        """
    }

    // MARK: - Per-Service URI Construction

    /// RINCON service type for the runtime sid the speaker reports.
    /// Routes through the catalog so households whose sid for a service
    /// drifted (issue #19) still get the correct RINCON value, with the
    /// `(sid << 8) + 7` formula as the fallback when the catalog hasn't
    /// loaded yet.
    private func rinconServiceType(for serviceID: Int) -> Int {
        MusicServiceCatalog.shared.rinconServiceType(forSid: serviceID)
    }

    /// Builds the correct playback URI for a track from an SMAPI service.
    /// Colons in service-specific IDs (e.g. spotify:track:xxx) must be percent-encoded to %3a.
    ///
    /// Resolution path: looks the runtime sid up in `MusicServiceCatalog`
    /// → service name → protocol rules. Per-service URI quirks (Spotify
    /// wants `x-sonos-spotify:`, Apple Music wants `.mp4` + flags 8232,
    /// etc.) live in the catalog so the lookup tracks the household's
    /// actual sid for the service rather than a compile-time guess. The
    /// previous compile-time tables silently mis-routed any household
    /// whose sid for a service didn't match the constants — see
    /// issue #19 for the resulting "x-sonos-http: → SOAP 714" failure
    /// on accounts where Spotify is sid 9 instead of 12.
    ///
    /// Falls back to `x-sonos-http:` and logs a CATALOG diagnostic when
    /// the catalog has no rules for this sid (either it hasn't been
    /// refreshed yet or this is a service we don't know about).
    private func buildPlayURI(itemID: String, itemType: String, serviceID: Int, sn: Int) -> String {
        let catalog = MusicServiceCatalog.shared
        // Percent-encode first, then replace colons with lowercase %3a (Sonos is case-sensitive).
        // Also lowercase any uppercase hex from addingPercentEncoding (e.g. %3A → %3a).
        var encodedID = (itemID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? itemID)
            .replacingOccurrences(of: ":", with: "%3a")
        // Force lowercase hex — Sonos rejects uppercase percent-encoding for Spotify URIs
        encodedID = encodedID.replacingOccurrences(of: "%3A", with: "%3a")
        if itemType == "stream" || itemType == "program" {
            let streamScheme = catalog.rules(forSid: serviceID)?.streamURIScheme ?? URIPrefix.sonosApiStream
            let streamFlags = catalog.rules(forSid: serviceID)?.streamPlaybackFlags ?? 8224
            return "\(streamScheme)\(encodedID)?sid=\(serviceID)&flags=\(streamFlags)&sn=\(sn)"
        }
        let prefix = catalog.trackURIScheme(forSid: serviceID)
        let ext = catalog.trackURIExtension(forSid: serviceID)
        let flags = catalog.trackPlaybackFlags(forSid: serviceID)
        return "\(prefix)\(encodedID)\(ext)?sid=\(serviceID)&flags=\(flags)&sn=\(sn)"
    }

    /// Converts an SMAPIMediaItem to a BrowseItem with correct per-service URI and metadata.
    public func smapiItemToBrowseItem(_ smapi: SMAPIMediaItem, serviceID: Int, sn: Int) -> BrowseItem {
        let serviceType = rinconServiceType(for: serviceID)
        let playURI: String?
        // Server-supplied URI wins when present — Sonos's SMAPI returns
        // the canonical play URI in <uri> for services whose scheme
        // can't be derived from sid/itemType alone (Radio Paradise's
        // resume tokens, services with custom schemes, etc.). Falling
        // through to `buildPlayURI` is the legacy path for services
        // that omit <uri> from mediaMetadata.
        if !smapi.uri.isEmpty {
            playURI = smapi.uri
            sonosDiagLog(.info, tag: "SERVICE-SEARCH",
                         "Using server-supplied URI for SMAPI item",
                         context: [
                            "sid": String(serviceID),
                            "itemType": smapi.itemType
                         ])
        } else if !smapi.canBrowse && !smapi.id.isEmpty {
            playURI = buildPlayURI(itemID: smapi.id, itemType: smapi.itemType, serviceID: serviceID, sn: sn)
        } else {
            playURI = nil
        }

        let didlMeta: String?
        if let uri = playURI, !smapi.canBrowse {
            didlMeta = buildSMAPIDIDL(id: smapi.id, title: smapi.title, artist: smapi.artist,
                                      album: smapi.album, itemType: smapi.itemType,
                                      serviceID: serviceID, serviceType: serviceType)
        } else {
            didlMeta = nil
        }

        var item = BrowseItem(
            id: "smapi:\(serviceID):\(smapi.id)",
            title: smapi.title,
            artist: smapi.artist,
            album: smapi.album,
            albumArtURI: smapi.albumArtURI.isEmpty ? nil : smapi.albumArtURI,
            itemClass: smapi.canBrowse ? .container : (smapi.itemType == "album" ? .musicAlbum : .musicTrack),
            resourceURI: playURI,
            resourceMetadata: didlMeta
        )
        // SMAPI search items resolve via getMediaURI before play; the
        // resolved URL carries credentials and plays with empty DIDL.
        // Mark the strategy here so SonosManager.playBrowseItem dispatches
        // correctly without inferring from the objectID prefix.
        item.playbackStrategy = .smapiResolveThenEmpty
        return item
    }

    // MARK: - Helpers

    private func upscaleArt(_ url: String?) -> String? {
        url?.replacingOccurrences(of: "100x100", with: "600x600")
           .replacingOccurrences(of: "60x60", with: "600x600")
    }

    // MARK: - Release Date Enrichment

    /// Enriches browse items with release dates from iTunes Search API.
    /// Used for SMAPI service results (Spotify, etc.) that don't include dates.
    /// Returns updated items — call on background, update UI when complete.
    public func enrichWithReleaseDates(_ items: [BrowseItem]) async -> [BrowseItem] {
        var updated = items
        // Batch unique album queries to avoid duplicate lookups
        var albumDates: [String: Date] = [:] // "artist|album" -> date
        var queries: [(index: Int, key: String)] = []

        for (i, item) in items.enumerated() {
            guard item.releaseDate == nil else { continue }
            let artist = item.artist
            let album = item.itemClass == .musicAlbum ? item.title : item.album
            guard !album.isEmpty else { continue }
            let key = "\(artist.lowercased())|\(album.lowercased())"
            if albumDates[key] != nil { continue } // already queued
            albumDates[key] = .distantPast // mark as pending
            queries.append((i, key))
        }

        // Fetch dates concurrently (limit concurrency to avoid rate limiting)
        await withTaskGroup(of: (String, Date?).self) { group in
            for (_, key) in queries {
                let parts = key.components(separatedBy: "|")
                let artist = parts.first ?? ""
                let album = parts.count > 1 ? parts[1] : ""
                group.addTask {
                    let query = [artist, album].filter { !$0.isEmpty }.joined(separator: " ")
                    guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                          let url = URL(string: "https://itunes.apple.com/search?term=\(encoded)&media=music&entity=album&limit=1\(Self.countryQueryParam())") else {
                        return (key, nil)
                    }
                    guard let (data, _) = await ITunesRateLimiter.shared.perform(url: url, session: self.session) else {
                        return (key, nil)
                    }
                    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let results = json["results"] as? [[String: Any]],
                          let first = results.first,
                          let dateStr = first["releaseDate"] as? String else {
                        return (key, nil)
                    }
                    return (key, Self.parseISODate(dateStr))
                }
            }
            for await (key, date) in group {
                if let date {
                    albumDates[key] = date
                }
            }
        }

        // Apply dates to items
        for i in updated.indices {
            guard updated[i].releaseDate == nil else { continue }
            let artist = updated[i].artist
            let album = updated[i].itemClass == .musicAlbum ? updated[i].title : updated[i].album
            guard !album.isEmpty else { continue }
            let key = "\(artist.lowercased())|\(album.lowercased())"
            if let date = albumDates[key], date != .distantPast {
                updated[i].releaseDate = date
            }
        }
        return updated
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func parseISODate(_ str: String?) -> Date? {
        guard let str, !str.isEmpty else { return nil }
        return isoFormatter.date(from: str) ?? ISO8601DateFormatter().date(from: str)
    }

    private func xmlEscape(_ str: String) -> String {
        str.replacingOccurrences(of: "&", with: "&amp;")
           .replacingOccurrences(of: "<", with: "&lt;")
           .replacingOccurrences(of: ">", with: "&gt;")
           .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
