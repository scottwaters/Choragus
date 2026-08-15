/// SunoResolver.swift — Resolve a public suno.com link to a playable track.
///
/// Suno is not a Sonos music service (no SMAPI sid, no RINCON binding). A
/// publicly shared Suno song exposes a direct, unauthenticated MP3 on its
/// CDN (`https://cdn1.suno.ai/<uuid>.mp3`). This resolver turns a user-pasted
/// share link (`https://suno.com/s/<code>`) or song link
/// (`https://suno.com/song/<uuid>`) into a `BrowseItem` whose `resourceURI`
/// is that CDN MP3, ready for queue-based HTTP-get playback (see
/// `BrowsePlaybackStrategy.directHTTPSQueue`).
///
/// No Discord OAuth is required — only public songs resolve. A private song's
/// share page carries no usable clip id, so resolution throws `.notPublic`.
import Foundation

public enum SunoResolver {
    public enum ResolveError: Error {
        /// Input wasn't a suno.com link or a clip UUID.
        case invalidLink
        /// Reachable page, but no public clip id (private / unlisted song).
        case notPublic
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    /// A clip UUID as embedded in a `/song/<uuid>` path or pasted bare.
    private static let uuidPattern =
        "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"

    /// Resolve a pasted Suno reference to a playable `BrowseItem`.
    /// Accepts a share URL, a song URL, or a bare clip UUID.
    public static func resolve(_ input: String) async throws -> BrowseItem {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ResolveError.invalidLink }

        // Get the clip UUID. In-app hrefs are /song/<uuid> (and bare UUIDs), so
        // it's usually right in the string; a /s/<code> share link is followed
        // once to its canonical /song/<uuid>.
        var uuid = firstMatch(uuidPattern, in: trimmed)
        if uuid == nil, let url = normalizedURL(trimmed), url.host?.contains("suno.com") == true {
            if let (_, response) = try? await session.data(for: clipRequest(url)) {
                uuid = firstMatch(uuidPattern, in: (response as? HTTPURLResponse)?.url?.absoluteString ?? "")
            }
        }
        guard let uuid else { throw ResolveError.invalidLink }

        // The clip API is authoritative: it returns the real `audio_url` (some
        // tracks — e.g. video uploads — aren't at cdn1/<uuid>.mp3), the title,
        // the creator, and art, and 404s for non-playable ids, so we never
        // queue a silent track.
        guard let clip = await fetchClip(uuid: uuid), let audio = clip.audioURL, !audio.isEmpty else {
            sonosDebugLog("[SUNO] resolve: no playable clip for \(uuid)")
            throw ResolveError.notPublic
        }
        let title = clip.title.isEmpty ? "Suno Track" : clip.title
        SunoCatalog.remember(uuid: uuid, title: title)
        if !clip.genre.isEmpty { SunoCatalog.rememberGenre(uuid: uuid, genre: clip.genre) }
        if !clip.artist.isEmpty { SunoCatalog.rememberArtist(uuid: uuid, artist: clip.artist) }
        sonosDebugLog("[SUNO] resolved \(uuid) → \(title) [\(clip.genre)]")

        let isMP4 = audio.lowercased().contains(".mp4") || audio.lowercased().contains(".m4a")
        var item = BrowseItem(
            id: "suno:\(uuid)",
            title: title,
            artist: clip.artist,
            album: "",
            albumArtURI: clip.artURL,
            itemClass: .musicTrack,
            resourceURI: audio,
            resourceMetadata: ServiceSearchProvider.shared.buildDirectHTTPTrackDIDL(
                title: title, artist: clip.artist, url: audio,
                mediaType: isMP4 ? "mp4" : "mp3", albumArtURI: clip.artURL
            )
        )
        item.playbackStrategy = .directHTTPSQueue
        return item
    }

    private struct Clip { let title: String; let artist: String; let audioURL: String?; let artURL: String?; let genre: String }

    /// Authoritative clip metadata from Suno's public clip endpoint. Returns nil
    /// for 404 / non-clip ids so they're never played as silence.
    private static func fetchClip(uuid: String) async -> Clip? {
        guard let url = URL(string: "https://studio-api.prod.suno.com/api/clip/\(uuid)"),
              let (data, resp) = try? await session.data(for: clipRequest(url)),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let title = (json["title"] as? String) ?? ""
        let artist = (json["display_name"] as? String)
            ?? ((json["user"] as? [String: Any])?["display_name"] as? String) ?? ""
        let audio = json["audio_url"] as? String
        let art = (json["image_large_url"] as? String) ?? (json["image_url"] as? String)
        // `display_tags` is Suno's curated style list (e.g. "nostalgic pop,
        // synth-pop") — clean enough to use as the track genre. `metadata.tags`
        // is the verbose style prompt, used only as a fallback.
        let genre = (json["display_tags"] as? String)
            ?? ((json["metadata"] as? [String: Any])?["tags"] as? String) ?? ""
        return Clip(title: title, artist: artist, audioURL: audio, artURL: art, genre: genre)
    }

    private static func clipRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        return request
    }

    /// Fetch a Suno playlist / genre page and return its song URLs in order
    /// (de-duplicated by clip UUID). The page server-renders every `/song/<uuid>`
    /// link, so this works without the page being open in the web view.
    public static func playlistSongURLs(_ playlistURL: String) async -> [String] {
        guard let url = URL(string: playlistURL) else { return [] }
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        guard let (data, _) = try? await session.data(for: request) else { return [] }
        let html = String(data: data, encoding: .utf8) ?? ""
        guard let re = try? NSRegularExpression(pattern: "/song/(\(uuidPattern))") else { return [] }
        let ns = html as NSString
        var seen = Set<String>()
        var out: [String] = []
        re.enumerateMatches(in: html, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m = m else { return }
            let uuid = ns.substring(with: m.range(at: 1)).lowercased()
            if seen.insert(uuid).inserted { out.append("https://suno.com/song/\(uuid)") }
        }
        sonosDebugLog("[SUNO] playlist \(url.lastPathComponent) → \(out.count) songs")
        return out
    }

    /// Fetch a clip's lyrics from Suno's public clip endpoint (no auth for
    /// public songs). Lyrics live in `metadata.prompt` (with [Verse]/[Chorus]
    /// section tags). Opportunistically remembers the title for the catalog.
    public static func lyrics(forUUID uuid: String) async -> String? {
        guard let url = URL(string: "https://studio-api.prod.suno.com/api/clip/\(uuid)") else { return nil }
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        guard let (data, _) = try? await session.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            sonosDebugLog("[SUNO] lyrics fetch failed for \(uuid)")
            return nil
        }
        if let title = json["title"] as? String { SunoCatalog.remember(uuid: uuid, title: title) }
        if let tags = json["display_tags"] as? String { SunoCatalog.rememberGenre(uuid: uuid, genre: tags) }
        if let artist = json["display_name"] as? String { SunoCatalog.rememberArtist(uuid: uuid, artist: artist) }
        let meta = json["metadata"] as? [String: Any]
        let prompt = (meta?["prompt"] as? String) ?? (json["prompt"] as? String)
        let text = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        sonosDebugLog("[SUNO] lyrics \(uuid) → \((text?.count ?? 0)) chars")
        return (text?.isEmpty == false) ? text : nil
    }

    /// Builds an `ArtistInfo` for a Suno clip's creator — used to populate the
    /// Now Playing "About" card for Suno tracks (Last.fm has no AI creators).
    /// Combines the clip (creator name, avatar, style tags) with the creator's
    /// public profile (bio, better avatar). `listeners` is left nil so the card
    /// doesn't mislabel a follower count as "listeners on Last.fm".
    public static func artistProfile(forUUID uuid: String) async -> ArtistInfo? {
        guard let url = URL(string: "https://studio-api.prod.suno.com/api/clip/\(uuid)"),
              let (data, _) = try? await session.data(for: clipRequest(url)),
              let clip = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let name = (clip["display_name"] as? String) ?? ""
        let handle = (clip["handle"] as? String) ?? ""
        var avatar = clip["avatar_image_url"] as? String
        let tags = ((clip["display_tags"] as? String) ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !name.isEmpty || !handle.isEmpty else { return nil }

        // Creator profile → bio + (better) avatar. The endpoint requires the
        // two sort params or it 422s.
        var bio: String?
        if !handle.isEmpty,
           case let encoded = URLEncode.pathSegment(handle),
           let purl = URL(string: "https://studio-api.prod.suno.com/api/profiles/\(encoded)?playlists_sort_by=created_at&clips_sort_by=created_at"),
           let (pdata, _) = try? await session.data(for: clipRequest(purl)),
           let prof = try? JSONSerialization.jsonObject(with: pdata) as? [String: Any] {
            bio = (prof["profile_description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let a = prof["avatar_image_url"] as? String, !a.isEmpty { avatar = a }
        }
        sonosDebugLog("[SUNO] artist profile \(handle) → tags=\(tags.count) bio=\(bio?.isEmpty == false)")
        return ArtistInfo(name: name.isEmpty ? handle : name, bio: bio, tags: tags,
                          similarArtists: [], listeners: nil, imageURL: avatar)
    }

    // MARK: - Parsing helpers

    private static func normalizedURL(_ s: String) -> URL? {
        if s.lowercased().hasPrefix("http") { return URL(string: s) }
        return URL(string: "https://\(s)")
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range),
              let r = Range(m.range, in: text) else { return nil }
        return String(text[r])
    }

}

/// Persistent name/art recovery for Suno tracks.
///
/// Sonos can't carry a Suno track's real metadata: the speaker proxies art via
/// `getaa` (blank — Suno MP3s have no embedded ID3 art) and reports the URL
/// filename (`<uuid>.mp3`) as the title. The cover is derivable from the clip
/// UUID, and the title is remembered (UserDefaults) when the track is resolved,
/// so both survive an app restart — unlike the in-memory track cache.
public enum SunoCatalog {
    private static let titlesKey = "sunoTrackTitles"
    private static let uuidPattern =
        "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
    /// Serializes each remember's read-modify-write — UserDefaults
    /// guarantees atomicity per call, not across a read + write pair,
    /// so unlocked concurrent remembers could lose entries.
    private static let storeLock = NSLock()

    /// Locked read-modify-write for the `[key: value]` stores backing
    /// titles / genres / artists.
    private static func rememberValue(_ value: String, forKey key: String, store storeKey: String) {
        storeLock.lock()
        defer { storeLock.unlock() }
        var store = (UserDefaults.standard.dictionary(forKey: storeKey) as? [String: String]) ?? [:]
        guard store[key] != value else { return }
        store[key] = value
        UserDefaults.standard.set(store, forKey: storeKey)
    }

    /// Compiled once — called per history entry in hot paths (Club
    /// Vis pool build).
    private static let uuidRegex = try? NSRegularExpression(pattern: uuidPattern)

    /// The clip UUID embedded in a Suno CDN / song URI, or nil if not Suno.
    public static func uuid(fromURI uri: String) -> String? {
        guard uri.lowercased().contains("suno") else { return nil }
        guard let re = uuidRegex else { return nil }
        let range = NSRange(uri.startIndex..., in: uri)
        guard let m = re.firstMatch(in: uri, range: range),
              let r = Range(m.range, in: uri) else { return nil }
        return String(uri[r]).lowercased()
    }

    /// The track's cover art, derived from the clip UUID (no network / cache).
    public static func coverURL(forUUID uuid: String) -> String {
        "https://cdn2.suno.ai/image_large_\(uuid).jpeg"
    }

    /// Persist a resolved title so it survives app restarts.
    public static func remember(uuid: String, title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.lowercased() != "suno track" else { return }
        rememberValue(t, forKey: uuid.lowercased(), store: titlesKey)
    }

    public static func title(forUUID uuid: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: titlesKey) as? [String: String])?[uuid.lowercased()]
    }

    private static let genresKey = "sunoTrackGenres"

    /// Persist a track's Suno style tags (`display_tags`) as its genre, so it
    /// survives restarts and feeds now-playing / history / Club Vis genre
    /// matching for direct-URL Suno tracks the speaker reports no genre for.
    public static func rememberGenre(uuid: String, genre: String) {
        let g = genre.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !g.isEmpty else { return }
        rememberValue(g, forKey: uuid.lowercased(), store: genresKey)
    }

    public static func genre(forUUID uuid: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: genresKey) as? [String: String])?[uuid.lowercased()]
    }

    private static let artistsKey = "sunoTrackArtists"

    /// Persist the Suno creator (`display_name`) as the track artist, so it
    /// shows in Now Playing for direct-URL Suno tracks the speaker reports no
    /// artist for. Survives restarts.
    public static func rememberArtist(uuid: String, artist: String) {
        let a = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty else { return }
        rememberValue(a, forKey: uuid.lowercased(), store: artistsKey)
    }

    public static func artist(forUUID uuid: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: artistsKey) as? [String: String])?[uuid.lowercased()]
    }
}
