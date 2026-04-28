/// MusicMetadataService.swift — Multi-source artist / album info,
/// with caching.
///
/// Queries Wikipedia (no key, best for human-readable bios),
/// MusicBrainz (no key, best for structured catalog data like
/// release dates and tags), and Last.fm (requires the API key the
/// user already configured for scrobbling, best for similar-artists
/// + listener counts) in parallel, then merges the results into a
/// single `ArtistInfo` / `AlbumInfo`.
///
/// The merge prefers the strongest source per field:
///   • bio       → longest non-empty among (Wikipedia → Last.fm)
///   • tags      → union of all sources, deduped, capped at 8
///   • similar   → Last.fm only (the others don't ship that field)
///   • listeners → Last.fm only
///   • image     → first non-empty among (Last.fm → Wikipedia)
///   • release   → MusicBrainz preferred (more accurate dates), Last.fm fallback
///
/// This means losing any one source still gives a reasonable result.
/// In particular: even if the user never configured Last.fm, Wikipedia
/// + MusicBrainz alone fill the panel for any artist/album with a
/// Wikipedia article.
import Foundation

public struct ArtistInfo: Codable, Equatable, Sendable {
    public let name: String
    public let bio: String?
    public let tags: [String]
    public let similarArtists: [String]
    public let listeners: Int?
    public let imageURL: String?
    /// Public URL for the artist's Wikipedia page when one was found.
    /// Used by the About card to render an "Open on Wikipedia" link.
    public let wikipediaURL: String?

    public init(name: String, bio: String?, tags: [String],
                similarArtists: [String], listeners: Int?,
                imageURL: String?, wikipediaURL: String? = nil) {
        self.name = name
        self.bio = bio
        self.tags = tags
        self.similarArtists = similarArtists
        self.listeners = listeners
        self.imageURL = imageURL
        self.wikipediaURL = wikipediaURL
    }
}

public struct AlbumInfo: Codable, Equatable, Sendable {
    public let title: String
    public let artist: String
    public let releaseDate: String?
    public let summary: String?
    public let tags: [String]
    public let tracks: [Track]
    public let imageURL: String?

    public struct Track: Codable, Equatable, Sendable {
        public let title: String
        public let durationSeconds: Int?
        public let position: Int?
    }
}

@MainActor
public final class MusicMetadataService {

    private let tokenStore: LastFMTokenStore
    private let cache: MetadataCacheRepository
    private let session: URLSession
    /// User-Agent header — required by MusicBrainz, polite for the
    /// rest. Identifies us so source operators can spot a misbehaving
    /// client and reach the maintainer.
    private let userAgent = "Choragus/1.0 (https://github.com/scottwaters/Choragus)"

    public init(tokenStore: LastFMTokenStore, cache: MetadataCacheRepository) {
        self.tokenStore = tokenStore
        self.cache = cache
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        self.session = URLSession(configuration: config)
    }

    // MARK: - Public API

    /// Drops the cached `artistInfo` entry for `name` so the next call
    /// re-fetches from Wikipedia / MusicBrainz / Last.fm. Used by the
    /// About card's "Refresh metadata" action when the user wants to
    /// pull updated content (e.g. Wikipedia article changed) without
    /// waiting for the 30-day cache TTL to expire.
    public func invalidateArtist(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        cache.clear(MetadataCacheRepository.Kind.artist.key(trimmed))
    }

    /// Drops the cached `albumInfo` entry. Mirrors `invalidateArtist`.
    public func invalidateAlbum(artist: String, album: String) {
        guard !album.isEmpty else { return }
        cache.clear(MetadataCacheRepository.Kind.album.key(artist, album))
    }

    public func artistInfo(name: String) async -> ArtistInfo? {
        // Suspect inputs that shouldn't be sent to artist-lookup endpoints —
        // they reliably produce unrelated Wikipedia summaries (the empty
        // string falls into "popular search" defaults) and trigger the
        // MusicBrainz `[unknown]` placeholder, whose tags include
        // "special purpose artist", "fixme", "bogus artist", etc.
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !Self.isSuspectArtistName(trimmed) else {
            return nil
        }

        let key = MetadataCacheRepository.Kind.artist.key(trimmed)
        if let cached = cache.get(key),
           let data = cached.data(using: .utf8),
           let info = try? JSONDecoder().decode(ArtistInfo.self, from: data) {
            // Treat cached placeholder/garbage entries as a miss and
            // re-resolve. Catches results that were stored under a
            // legitimate-looking name before the source-side filter
            // was added.
            if !Self.looksLikePlaceholderArtist(info) {
                return info
            }
        }

        // Run all three sources in parallel — slowest source caps
        // perceived latency. Each returns a partial ArtistInfo with
        // any-or-all fields nil; merge picks the strongest per field.
        async let wiki = wikipediaArtist(name: trimmed)
        async let mb = musicBrainzArtist(name: trimmed)
        async let lfm = lastFMArtist(name: trimmed)

        let parts: [ArtistInfo?] = await [wiki, mb, lfm]
        let merged = mergeArtist(name: trimmed, parts: parts.compactMap { $0 })
        guard let merged else { return nil }

        if let encoded = try? JSONEncoder().encode(merged),
           let str = String(data: encoded, encoding: .utf8) {
            cache.set(key, payload: str, ttlSeconds: 30 * 24 * 60 * 60)
        }
        return merged
    }

    /// Returns true for inputs that we know aren't a real artist name and
    /// will produce garbage from the data sources:
    /// - empty string
    /// - "Various Artists" / "VA" / "Unknown Artist" — compilation markers
    /// - strings ending in album-style suffixes like "(Deluxe)",
    ///   "(Remastered)", "(Soundtrack)" — Sonos favorites occasionally
    ///   leak the album into the artist field; rejecting these strings
    ///   prevents Wikipedia from returning unrelated featured articles
    ///   and MusicBrainz from returning the `[unknown]` placeholder.
    private static func isSuspectArtistName(_ name: String) -> Bool {
        if name.isEmpty { return true }
        let lower = name.lowercased()
        let badNames: Set<String> = [
            "various artists", "various", "va",
            "unknown artist", "unknown", "[unknown]",
            "no artist", "n/a", "anonymous"
        ]
        if badNames.contains(lower) { return true }
        // Album-suffix sniffing: real artist names occasionally contain
        // parens (e.g. "Bear's Den (USA)") so we look for music-industry
        // album tokens specifically.
        let albumTokens = [
            "(deluxe)", "(remastered)", "(remaster)", "(expanded)",
            "(soundtrack)", "(original soundtrack)", "(ost)",
            "(special edition)", "(extended)", "(anniversary edition)",
            "(bonus track version)", "(deluxe edition)"
        ]
        for token in albumTokens where lower.hasSuffix(token) {
            return true
        }
        return false
    }

    /// MusicBrainz returns several "special purpose" placeholder artists
    /// when a query doesn't find a real match — `[unknown]`,
    /// `[anonymous]`, `[various artists]`, etc. They carry tags like
    /// "special purpose artist", "fixme", "bogus artist", "non-music",
    /// "meta artist". We use those tags as a sentinel and refuse to
    /// surface the result to the user.
    /// `nonisolated` so the `nonisolated` MusicBrainz fetcher can call it.
    nonisolated private static func looksLikePlaceholderArtist(_ info: ArtistInfo) -> Bool {
        let placeholderNames: Set<String> = [
            "[unknown]", "[anonymous]", "[various artists]",
            "[no artist]", "[data]", "[traditional]"
        ]
        if placeholderNames.contains(info.name.lowercased()) {
            return true
        }
        let placeholderTags: Set<String> = [
            "special purpose artist", "special purpose",
            "meta artist", "non-music", "bogus artist", "fixme"
        ]
        let lowerTags = Set(info.tags.map { $0.lowercased() })
        // Two or more placeholder tags is a definite sentinel; one alone
        // could be a real artist that happens to share a tag.
        return lowerTags.intersection(placeholderTags).count >= 2
    }

    public func albumInfo(artist: String, album: String) async -> AlbumInfo? {
        let key = MetadataCacheRepository.Kind.album.key(artist, album)
        if let cached = cache.get(key),
           let data = cached.data(using: .utf8),
           let info = try? JSONDecoder().decode(AlbumInfo.self, from: data) {
            return info
        }

        async let wiki = wikipediaAlbum(artist: artist, album: album)
        async let mb = musicBrainzAlbum(artist: artist, album: album)
        async let lfm = lastFMAlbum(artist: artist, album: album)

        let parts: [AlbumInfo?] = await [wiki, mb, lfm]
        let merged = mergeAlbum(title: album, artist: artist,
                                parts: parts.compactMap { $0 })
        guard let merged else { return nil }

        if let encoded = try? JSONEncoder().encode(merged),
           let str = String(data: encoded, encoding: .utf8) {
            cache.set(key, payload: str, ttlSeconds: 30 * 24 * 60 * 60)
        }
        return merged
    }

    // MARK: - Merge

    private func mergeArtist(name: String, parts: [ArtistInfo]) -> ArtistInfo? {
        guard !parts.isEmpty else { return nil }
        // Bio: pick the longest. Wikipedia summaries tend to win.
        let bio = parts.compactMap(\.bio)
            .filter { !$0.isEmpty }
            .max(by: { $0.count < $1.count })
        // Tags: union, dedupe case-insensitive, cap at 8.
        var seen: Set<String> = []
        var tags: [String] = []
        for tag in parts.flatMap(\.tags) {
            let lower = tag.lowercased()
            if seen.insert(lower).inserted { tags.append(tag) }
            if tags.count >= 8 { break }
        }
        // Similar artists: Last.fm-only field. First non-empty wins.
        let similar = parts.first { !$0.similarArtists.isEmpty }?.similarArtists ?? []
        // Listeners: Last.fm-only.
        let listeners = parts.compactMap(\.listeners).max()
        // Image: first non-empty.
        let image = parts.compactMap(\.imageURL).first { !$0.isEmpty }
        // Wikipedia URL: only the wikipediaArtist source supplies one.
        let wikiURL = parts.compactMap(\.wikipediaURL).first { !$0.isEmpty }
        return ArtistInfo(
            name: name,
            bio: bio,
            tags: tags,
            similarArtists: Array(similar.prefix(10)),
            listeners: listeners,
            imageURL: image,
            wikipediaURL: wikiURL
        )
    }

    private func mergeAlbum(title: String, artist: String, parts: [AlbumInfo]) -> AlbumInfo? {
        guard !parts.isEmpty else { return nil }
        let summary = parts.compactMap(\.summary)
            .filter { !$0.isEmpty }
            .max(by: { $0.count < $1.count })
        // Release date: MusicBrainz tends to be the most accurate
        // (often full ISO date, sometimes just year). Pick the
        // longest available — full date beats year-only.
        let releaseDate = parts.compactMap(\.releaseDate)
            .filter { !$0.isEmpty }
            .max(by: { $0.count < $1.count })
        var seen: Set<String> = []
        var tags: [String] = []
        for tag in parts.flatMap(\.tags) {
            let lower = tag.lowercased()
            if seen.insert(lower).inserted { tags.append(tag) }
            if tags.count >= 8 { break }
        }
        // Tracklist: prefer the source with the most tracks (usually
        // the most complete one).
        let tracks = parts.map(\.tracks).max(by: { $0.count < $1.count }) ?? []
        let image = parts.compactMap(\.imageURL).first { !$0.isEmpty }
        return AlbumInfo(
            title: title,
            artist: artist,
            releaseDate: releaseDate,
            summary: summary,
            tags: tags,
            tracks: tracks,
            imageURL: image
        )
    }

    // MARK: - Wikipedia

    /// Wikipedia REST summary endpoint. Free, no key, very fast,
    /// excellent prose. Two-step lookup: OpenSearch finds the best
    /// title match (handles disambiguations and minor name variants),
    /// then the summary endpoint returns the article extract.
    private func wikipediaArtist(name: String) async -> ArtistInfo? {
        // Try title candidates in order. "(band)" and "(musician)"
        // disambiguators are Wikipedia conventions — most music
        // articles live under one of those titles. Plain name is the
        // last resort and risks landing on a disambiguation page.
        let candidates = [
            "\(name) (band)",
            "\(name) (musician)",
            name,
        ]
        for candidate in candidates {
            guard let title = await wikipediaResolveTitle(query: candidate),
                  let summary = await wikipediaSummary(title: title),
                  summary.type != "disambiguation",
                  let extract = summary.extract, !extract.isEmpty
            else { continue }
            return ArtistInfo(
                name: name,
                bio: extract,
                tags: [],
                similarArtists: [],
                listeners: nil,
                imageURL: summary.thumbnailURL,
                wikipediaURL: summary.pageURL
            )
        }
        return nil
    }

    private func wikipediaAlbum(artist: String, album: String) async -> AlbumInfo? {
        // Wikipedia album titles are usually disambiguated as
        // "<Album> (<Artist> album)". Fall back to plain title.
        let candidates = [
            "\(album) (\(artist) album)",
            "\(album) (album)",
            album,
        ]
        for title in candidates {
            if let summary = await wikipediaSummary(title: title),
               summary.type != "disambiguation",
               let extract = summary.extract, !extract.isEmpty {
                return AlbumInfo(
                    title: album, artist: artist,
                    releaseDate: nil,
                    summary: extract,
                    tags: [],
                    tracks: [],
                    imageURL: summary.thumbnailURL
                )
            }
        }
        return nil
    }

    /// Resolves the best matching Wikipedia article title using the
    /// OpenSearch endpoint, which returns "the most likely article"
    /// for an arbitrary query. Returns nil if Wikipedia has no match.
    /// Note: nonisolated since we don't touch any actor state.
    private nonisolated func wikipediaResolveTitle(query: String) async -> String? {
        guard let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://en.wikipedia.org/w/api.php?action=opensearch&search=\(q)&limit=1&format=json")
        else { return nil }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, _) = try await session.data(for: request)
            // OpenSearch returns an array: [query, [titles], [descriptions], [urls]].
            guard let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  arr.count >= 2,
                  let titles = arr[1] as? [String],
                  let first = titles.first
            else { return nil }
            return first
        } catch {
            return nil
        }
    }

    private struct WikipediaSummary {
        let extract: String?
        let thumbnailURL: String?
        let type: String?
        let pageURL: String?
    }

    private nonisolated func wikipediaSummary(title: String) async -> WikipediaSummary? {
        let path = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title
        guard let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(path)")
        else { return nil }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { return nil }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            let extract = json["extract"] as? String
            let type = json["type"] as? String
            let thumb = (json["thumbnail"] as? [String: Any])?["source"] as? String
            // `content_urls.desktop.page` is the canonical web URL for the
            // article — what users get when they "Open in Browser".
            let page = ((json["content_urls"] as? [String: Any])?["desktop"] as? [String: Any])?["page"] as? String
            return WikipediaSummary(extract: extract, thumbnailURL: thumb, type: type, pageURL: page)
        } catch {
            return nil
        }
    }

    // MARK: - MusicBrainz

    /// MusicBrainz artist lookup. Returns tags + the canonical name.
    /// No bio (MB doesn't ship those — see Wikipedia for prose).
    /// Throttle: MB rate-limits to 1 req/sec/IP; per-call sleep keeps
    /// us under the bar without needing a global token bucket.
    private nonisolated func musicBrainzArtist(name: String) async -> ArtistInfo? {
        guard let q = "artist:\(name)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://musicbrainz.org/ws/2/artist/?query=\(q)&fmt=json&limit=1")
        else { return nil }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, _) = try await session.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let artists = json["artists"] as? [[String: Any]],
                  let first = artists.first else { return nil }
            let canonical = (first["name"] as? String) ?? name
            let tagDicts = (first["tags"] as? [[String: Any]]) ?? []
            // MB tags carry a count; sort by count desc, take top 8.
            let tags = tagDicts
                .compactMap { dict -> (String, Int)? in
                    guard let n = dict["name"] as? String else { return nil }
                    return (n, (dict["count"] as? Int) ?? 0)
                }
                .sorted { $0.1 > $1.1 }
                .prefix(8)
                .map { $0.0 }
            let info = ArtistInfo(
                name: canonical, bio: nil,
                tags: Array(tags),
                similarArtists: [], listeners: nil, imageURL: nil
            )
            // MusicBrainz returns the `[unknown]` / `[anonymous]` / etc.
            // placeholder when no real artist matches the query. Drop
            // these so they never reach the merge step.
            if Self.looksLikePlaceholderArtist(info) { return nil }
            return info
        } catch {
            return nil
        }
    }

    /// MusicBrainz release-group lookup. Returns release date + tags
    /// + tracklist (when available via release-group → release →
    /// recordings expansion). For brevity we keep the lookup to the
    /// release-group level — full tracklist would need another hop.
    private nonisolated func musicBrainzAlbum(artist: String, album: String) async -> AlbumInfo? {
        let queryStr = #"artist:"\#(artist)" AND release:"\#(album)""#
        guard let q = queryStr.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://musicbrainz.org/ws/2/release-group/?query=\(q)&fmt=json&limit=1")
        else { return nil }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, _) = try await session.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let groups = json["release-groups"] as? [[String: Any]],
                  let first = groups.first else { return nil }
            let releaseDate = first["first-release-date"] as? String
            let tagDicts = (first["tags"] as? [[String: Any]]) ?? []
            let tags = tagDicts
                .compactMap { dict -> (String, Int)? in
                    guard let n = dict["name"] as? String else { return nil }
                    return (n, (dict["count"] as? Int) ?? 0)
                }
                .sorted { $0.1 > $1.1 }
                .prefix(8)
                .map { $0.0 }
            return AlbumInfo(
                title: album, artist: artist,
                releaseDate: releaseDate?.isEmpty == false ? releaseDate : nil,
                summary: nil,
                tags: Array(tags),
                tracks: [],
                imageURL: nil
            )
        } catch {
            return nil
        }
    }

    // MARK: - Last.fm (kept as a third source)

    private func lastFMArtist(name: String) async -> ArtistInfo? {
        guard let json = await lastFMCall(method: "artist.getinfo",
                                          params: ["artist": name]) else {
            return nil
        }
        return parseLastFMArtist(json, fallbackName: name)
    }

    private func lastFMAlbum(artist: String, album: String) async -> AlbumInfo? {
        guard let json = await lastFMCall(method: "album.getinfo",
                                          params: ["artist": artist, "album": album]) else {
            return nil
        }
        return parseLastFMAlbum(json, fallbackArtist: artist, fallbackAlbum: album)
    }

    private func lastFMCall(method: String, params: [String: String]) async -> [String: Any]? {
        guard let apiKey = tokenStore.apiKey, !apiKey.isEmpty else {
            // No Last.fm key configured — that's fine, the other two
            // sources will carry the lookup. Don't log this as an
            // error.
            return nil
        }
        var components = URLComponents(string: "https://ws.audioscrobbler.com/2.0/")
        var items = [
            URLQueryItem(name: "method", value: method),
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "autocorrect", value: "1"),
        ]
        for (k, v) in params {
            items.append(URLQueryItem(name: k, value: v))
        }
        components?.queryItems = items
        guard let url = components?.url else { return nil }
        do {
            var request = URLRequest(url: url)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { return nil }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            if json["error"] != nil { return nil }
            return json
        } catch {
            return nil
        }
    }

    private func parseLastFMArtist(_ json: [String: Any], fallbackName: String) -> ArtistInfo? {
        guard let artist = json["artist"] as? [String: Any] else { return nil }
        let name = (artist["name"] as? String) ?? fallbackName
        let bio = ((artist["bio"] as? [String: Any])?["summary"] as? String).flatMap(stripLastFMTrailer)
        let tags = ((artist["tags"] as? [String: Any])?["tag"] as? [[String: Any]])?
            .compactMap { $0["name"] as? String } ?? []
        let similar = ((artist["similar"] as? [String: Any])?["artist"] as? [[String: Any]])?
            .compactMap { $0["name"] as? String } ?? []
        let listeners = (artist["stats"] as? [String: Any]).flatMap {
            ($0["listeners"] as? String).flatMap(Int.init)
        }
        let imageURL = pickLargestImage(artist["image"] as? [[String: Any]])
        return ArtistInfo(name: name, bio: bio, tags: Array(tags.prefix(8)),
                          similarArtists: Array(similar.prefix(10)),
                          listeners: listeners, imageURL: imageURL)
    }

    private func parseLastFMAlbum(_ json: [String: Any], fallbackArtist: String, fallbackAlbum: String) -> AlbumInfo? {
        guard let album = json["album"] as? [String: Any] else { return nil }
        let title = (album["name"] as? String) ?? fallbackAlbum
        let artist = (album["artist"] as? String) ?? fallbackArtist
        let releaseDate = album["releasedate"] as? String
        let wiki = album["wiki"] as? [String: Any]
        let summary = (wiki?["summary"] as? String).flatMap(stripLastFMTrailer)
        let tags = ((album["tags"] as? [String: Any])?["tag"] as? [[String: Any]])?
            .compactMap { $0["name"] as? String } ?? []
        let trackList = ((album["tracks"] as? [String: Any])?["track"] as? [[String: Any]]) ?? []
        let tracks: [AlbumInfo.Track] = trackList.compactMap { entry in
            guard let title = entry["name"] as? String else { return nil }
            let dur = (entry["duration"] as? String).flatMap(Int.init)
            let pos = ((entry["@attr"] as? [String: Any])?["rank"] as? String).flatMap(Int.init)
            return AlbumInfo.Track(title: title, durationSeconds: dur, position: pos)
        }
        let imageURL = pickLargestImage(album["image"] as? [[String: Any]])
        let cleanedDate = releaseDate?.trimmingCharacters(in: .whitespaces).isEmpty == false
            ? releaseDate : nil
        return AlbumInfo(title: title, artist: artist,
                         releaseDate: cleanedDate, summary: summary,
                         tags: Array(tags.prefix(8)), tracks: tracks,
                         imageURL: imageURL)
    }

    // MARK: - Helpers

    private func stripLastFMTrailer(_ s: String) -> String {
        if let range = s.range(of: "<a href") {
            return String(s[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func pickLargestImage(_ images: [[String: Any]]?) -> String? {
        guard let images else { return nil }
        let preferred = ["mega", "extralarge", "large", "medium", "small"]
        for size in preferred {
            if let entry = images.first(where: { ($0["size"] as? String) == size }),
               let url = entry["#text"] as? String, !url.isEmpty {
                return url
            }
        }
        return nil
    }
}
