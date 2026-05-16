/// AlbumArtSearchService.swift — Fetches album art from iTunes Search API.
///
/// Used as a fallback when Sonos doesn't provide album art.
/// Supports album searches, artist searches, and combined searches.
/// No API key required. Results are cached in memory to avoid repeat lookups.
import Foundation

public final class AlbumArtSearchService: AlbumArtSearchProtocol {
    public static let shared = AlbumArtSearchService()

    /// Optional Apple Music enrichment hooks. Set by the host app when
    /// MusicKit authorisation is granted; consulted before iTunes Search
    /// in every artwork lookup. Returning nil falls through to the
    /// existing iTunes-based strategies, so a MusicKit miss never
    /// degrades the result vs. the no-MusicKit baseline.
    public nonisolated(unsafe) static var appleMusicAlbumArtLookup: ((_ artist: String, _ album: String) async -> String?)?
    public nonisolated(unsafe) static var appleMusicArtistArtLookup: ((_ artist: String) async -> String?)?
    public nonisolated(unsafe) static var appleMusicTrackArtLookup: ((_ artist: String, _ title: String) async -> String?)?

    private let session: URLSession
    private var cache: [String: String?] = [:] // cacheKey -> artURL (nil = not found)
    private let cacheLock = NSLock()

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        self.session = URLSession(configuration: config)
    }

    /// Searches iTunes for album art. Tries multiple strategies:
    /// 1. Album search with artist + title
    /// 2. Album search with just title
    /// 3. Artist search (for artist-level containers)
    ///
    /// **No-maxWait variant is the UI path** — runs `unthrottled: true`
    /// so background `backfillMissingArtwork` sweeps can't saturate the
    /// local 12 req/min self-throttle and starve a now-playing or
    /// browse-render lookup. Apple-side 403/429 cooldown still applies.
    public func searchArtwork(artist: String, album: String) async -> String? {
        await searchArtworkInternal(artist: artist, album: album, maxWait: 0, unthrottled: true)
    }

    /// Patient variant — for background backfill sweeps. Stays on the
    /// throttled path so it yields slots to UI requests above. With
    /// `maxWait` typically set to 60–120 s, backfill completes over
    /// minutes without dropping entries on transient saturation.
    public func searchArtwork(artist: String, album: String, maxWait: TimeInterval) async -> String? {
        await searchArtworkInternal(artist: artist, album: album, maxWait: maxWait, unthrottled: false)
    }

    private func searchArtworkInternal(artist: String, album: String, maxWait: TimeInterval, unthrottled: Bool) async -> String? {
        let cacheKey = "art:\(artist.lowercased())|\(album.lowercased())"
        cacheLock.lock()
        if let cached = cache[cacheKey] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        // Strategy 0: Apple Music catalog when the user has authorised
        // MusicKit. Tried first because catalog metadata is higher-quality
        // than iTunes Search results and the rate limits are separate, so
        // a hit here also relieves pressure on the iTunes-side throttle.
        if let lookup = Self.appleMusicAlbumArtLookup, !artist.isEmpty || !album.isEmpty {
            if let url = await lookup(artist, album) {
                cacheSet(cacheKey, url)
                return url
            }
        }

        // Strategy 1: Combined artist + album search
        if !artist.isEmpty && !album.isEmpty {
            if let url = await iTunesSearch(query: "\(artist) \(album)", entity: "album", maxWait: maxWait, unthrottled: unthrottled) {
                cacheSet(cacheKey, url)
                return url
            }
        }

        // Strategy 2: Album-only search
        if !album.isEmpty {
            if let url = await iTunesSearch(query: album, entity: "album", maxWait: maxWait, unthrottled: unthrottled) {
                cacheSet(cacheKey, url)
                return url
            }
        }

        // Strategy 3: Artist search (returns artist image)
        let artistQuery = !artist.isEmpty ? artist : album
        if !artistQuery.isEmpty {
            if let url = await iTunesSearch(query: artistQuery, entity: "musicArtist", maxWait: maxWait, unthrottled: unthrottled) {
                cacheSet(cacheKey, url)
                return url
            }
        }

        // Strategy 4: Broad song search (might find artwork from a popular track)
        if !album.isEmpty {
            if let url = await iTunesSearch(query: album, entity: "song", maxWait: maxWait, unthrottled: unthrottled) {
                cacheSet(cacheKey, url)
                return url
            }
        }

        cacheSet(cacheKey, nil)
        return nil
    }

    /// Artist-image lookup via iTunes Search. Used by
    /// `MusicMetadataService` as a fallback when neither Last.fm
    /// (placeholder-filtered post-2019) nor Wikipedia returned an
    /// artist photo.
    ///
    /// Cascades through three iTunes entity types because the API has
    /// a quirk: `musicArtist` records frequently come back *without*
    /// `artworkUrl100` populated — iTunes stores artist photos in
    /// their Store frontend but not consistently in the Search JSON.
    /// Album and song entities always carry artwork. A representative
    /// album cover beats a blank silhouette in the About card, even
    /// if it isn't a true artist photo.
    public func searchArtistArt(artist: String) async -> String? {
        let trimmed = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let cacheKey = "artist:\(trimmed.lowercased())"
        cacheLock.lock()
        if let cached = cache[cacheKey] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        // Apple Music catalog first when authorised — see `appleMusicArtistArtLookup`.
        if let lookup = Self.appleMusicArtistArtLookup {
            if let url = await lookup(trimmed) {
                cacheSet(cacheKey, url)
                return url
            }
        }

        // Strip straight + smart quotes from the query. iTunes Search
        // treats query quotes as phrase delimiters — names like
        // `"Weird Al" Yankovic` return zero results when sent literally
        // even though the catalog entry exists.
        let cleaned = trimmed.replacingOccurrences(
            of: "[\"\u{201C}\u{201D}\u{2018}\u{2019}]",
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)

        for entity in ["musicArtist", "album", "song"] {
            // `unthrottled: true` so the user-initiated artist-image
            // lookup isn't starved by background `backfillMissingArtwork`
            // calls that can saturate the local 12 req/min self-throttle.
            // Same policy the radio-track-art lookup uses for the same
            // reason: this is a user-facing latency-sensitive path,
            // infrequent enough that bypassing the local soft cap is
            // safe. Apple-side 403/429 cooldown still applies.
            if let url = await iTunesSearch(query: cleaned, entity: entity, unthrottled: true) {
                // Demoted to debug — successful lookups happen on every
                // track change in the background prewarm, and a saturated
                // INFO-level diagnostics ring buffer evicts real warnings
                // within minutes. Keep this line for verbose debugging
                // sessions only.
                sonosDiagLog(.debug, tag: "ART/ARTIST",
                             "iTunes \(entity) hit for \(trimmed) → \(url.prefix(80))")
                cacheSet(cacheKey, url)
                return url
            }
        }
        let snapshot = await ITunesRateLimiter.shared.snapshot()
        sonosDiagLog(.warning, tag: "ART/ARTIST",
                     "iTunes returned no artwork across musicArtist/album/song for \(trimmed) (cleaned: \(cleaned)) — limiter: available=\(snapshot.isAvailable), cooldownUntil=\(snapshot.cooldownUntil.map { String(describing: $0) } ?? "nil"), cooldownStatus=\(snapshot.cooldownStatus.map(String.init) ?? "nil"), requestsInWindow=\(snapshot.requestsInWindow)")
        cacheSet(cacheKey, nil)
        return nil
    }

    /// Optimized search for radio track artwork — uses song entity first for better accuracy.
    /// Radio stream metadata often has movie/show names as "artist" which confuse album searches.
    public func searchRadioTrackArt(artist: String, title: String) async -> String? {
        let cacheKey = "radio:\(artist.lowercased())|\(title.lowercased())"
        cacheLock.lock()
        if let cached = cache[cacheKey] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        // Apple Music catalog first when authorised. Same dual-key arrangement
        // as the album/artist paths above.
        if let lookup = Self.appleMusicTrackArtLookup, !title.isEmpty {
            if let url = await lookup(artist, title) {
                cacheSet(cacheKey, url)
                return url
            }
        }

        // The user is actively watching the now-playing pane while a
        // radio track plays — this is a user-facing latency-sensitive
        // path, equivalent in priority to the manual Search Artwork
        // dialog. Bypass the self-throttle so background browse art
        // enrichment can't starve us when the rate window is full.
        // Apple-side 403/429 cooldown still applies.
        let unt = true

        // Strategy 0a: Soundtrack-track shape via title ("X End Titles",
        // "Theme From X", etc.) — see `extractMovieName`. Strong signal
        // (title pattern) so it stays at the top.
        if Self.titleHasSoundtrackShape(title),
           let movie = Self.extractMovieName(from: title), !movie.isEmpty {
            if let url = await iTunesSearch(query: "\(movie) soundtrack", entity: "album", unthrottled: unt) {
                sonosDebugLog("[ART/RADIO] OST hit (title) movie=\(movie) artist=\(artist)")
                cacheSet(cacheKey, url)
                return url
            }
        }

        // Strategy 1: Verified song search with artist + title.
        // Promoted ahead of the "artist-as-movie" OST guess (was Strategy
        // 0b) — that earlier order returned compilation albums for
        // legitimate artists (e.g. Billy Joel + "Say Goodbye To Hollywood"
        // resolved to "The Essential Billy Joel" via "Billy Joel
        // soundtrack" because iTunes loosely matches "soundtrack" against
        // marketing copy). Verified song search is exact and wins for
        // every real performing artist; the OST guess remains as a
        // fallback for soundtrack stations (Strategy 3 below).
        if !artist.isEmpty {
            if let url = await verifiedSongSearch(query: "\(artist) \(title)", expectedTitle: title, unthrottled: unt) {
                cacheSet(cacheKey, url)
                return url
            }
        }

        // Strategy 2: Verified song search with just title
        if let url = await verifiedSongSearch(query: title, expectedTitle: title, unthrottled: unt) {
            cacheSet(cacheKey, url)
            return url
        }

        // Strategy 2b (was 0b): Soundtrack stations frequently put the
        // *movie name* in the artist field instead of the actual
        // composer/performer (e.g. 1.FM Movie Soundtracks Hits sends
        // artist="Beauty and the Beast" for "Battle on the Tower").
        // After verified song search has missed, try treating the artist
        // string as the movie name and search its OST. Constrained to
        // non-trivial multi-character strings so we don't fire for
        // empty / one-word artists.
        if !artist.isEmpty, artist.count >= 3 {
            if let url = await iTunesSearch(query: "\(artist) soundtrack", entity: "album", unthrottled: unt) {
                sonosDebugLog("[ART/RADIO] OST hit (artist-as-movie) movie=\(artist)")
                cacheSet(cacheKey, url)
                return url
            }
        }

        // Strategy 3: Album search with title only (for soundtrack albums)
        // Use title without artist — the artist (orchestra) is too generic for soundtrack matching
        if let url = await iTunesSearch(query: "\(title) soundtrack", entity: "album", unthrottled: unt) {
            cacheSet(cacheKey, url)
            return url
        }

        // Strategy 4: Cleaned title/artist fallback — strips source suffixes, special chars, multi-artist
        let cleanedTitle = cleanForSearch(title)
        let cleanedArtist = cleanArtist(artist)
        let titleChanged = cleanedTitle != title.lowercased().trimmingCharacters(in: .whitespaces)
        let artistChanged = cleanedArtist != artist.lowercased().trimmingCharacters(in: .whitespaces)

        if titleChanged || artistChanged {
            if !cleanedArtist.isEmpty && !cleanedTitle.isEmpty {
                if let url = await verifiedSongSearch(query: "\(cleanedArtist) \(cleanedTitle)", expectedTitle: cleanedTitle, unthrottled: unt) {
                    cacheSet(cacheKey, url)
                    return url
                }
            }
            if !cleanedTitle.isEmpty {
                if let url = await verifiedSongSearch(query: cleanedTitle, expectedTitle: cleanedTitle, unthrottled: unt) {
                    cacheSet(cacheKey, url)
                    return url
                }
            }
        }

        cacheSet(cacheKey, nil)
        return nil
    }

    // MARK: - Shared Utilities

    /// Soundtrack-track suffix keywords — appear at the END of titles like
    /// "Willow End Titles" or "Star Wars Main Theme". Longest-first so
    /// multi-word matches win over single-word ones during prefix checks.
    private static let soundtrackTrackSuffixes: [String] = [
        "main theme", "main title", "end titles", "end title",
        "opening credits", "closing credits",
        "overture", "prologue", "epilogue", "finale",
        "credits", "theme", "suite", "score", "opening", "closing",
        "intro", "outro"
    ]

    /// Soundtrack-track prefix patterns — appear at the START of titles
    /// like "Theme From Jurassic Park" or "Music From Star Wars".
    /// Each ends in a space so the match cleanly precedes the movie name.
    private static let soundtrackTrackPrefixes: [String] = [
        "theme from ", "music from ", "main theme from ",
        "suite from ", "score from ", "song from ",
        "selections from ", "highlights from ",
        "end titles from ", "end title from "
    ]

    /// True when the title carries soundtrack-track shape — either a
    /// recognised suffix (e.g. "X End Titles") or prefix (e.g. "Theme
    /// From X"). Used to gate the OST-album search strategy because for
    /// these tracks iTunes rarely has the recording itself but reliably
    /// has the original soundtrack album under the bare movie name.
    static func titleHasSoundtrackShape(_ title: String) -> Bool {
        let stripped = title
            .replacingOccurrences(of: "\\s*\\([^)]*\\)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s*\\[[^\\]]*\\]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        for suffix in soundtrackTrackSuffixes {
            if stripped.hasSuffix(" " + suffix) || stripped == suffix {
                return true
            }
        }
        for prefix in soundtrackTrackPrefixes where stripped.hasPrefix(prefix) {
            return true
        }
        return false
    }

    /// Best-effort movie/film name extracted from a soundtrack-track
    /// title. Strips parentheticals (which often hold localized titles)
    /// and either a recognised soundtrack-track suffix ("Willow End
    /// Titles" → "Willow") or prefix ("Theme From Jurassic Park" →
    /// "Jurassic Park"). Returns nil if nothing meaningful is left.
    static func extractMovieName(from title: String) -> String? {
        var t = title
            .replacingOccurrences(of: "\\s*\\([^)]*\\)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s*\\[[^\\]]*\\]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let tLower = t.lowercased()
        // Try suffixes first — they're more common and leave a movie name
        // followed by an optional punctuator we trim below.
        for suffix in soundtrackTrackSuffixes {
            if tLower.hasSuffix(" " + suffix) {
                let cutoff = t.count - suffix.count - 1
                t = String(t.prefix(cutoff)).trimmingCharacters(in: .whitespaces)
                break
            }
            if tLower == suffix {
                t = ""
                break
            }
        }
        // If suffix didn't match (or fully consumed the title), try prefixes.
        if t == title || t.isEmpty {
            for prefix in soundtrackTrackPrefixes where tLower.hasPrefix(prefix) {
                t = String(title.dropFirst(prefix.count))
                    .replacingOccurrences(of: "\\s*\\([^)]*\\)", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "\\s*\\[[^\\]]*\\]", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
                break
            }
        }
        // Strip trailing punctuators (dash/colon/comma) left after the cut.
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " -–—:,"))
        return t.count >= 2 ? t : nil
    }

    /// Constructs a /getaa URL to extract embedded art from a local file via the Sonos speaker
    public static func getaaURL(speakerIP: String, port: Int = SonosProtocol.defaultPort, trackURI: String) -> String {
        let encoded = trackURI.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trackURI
        return "http://\(speakerIP):\(port)/getaa?s=1&u=\(encoded)"
    }

    /// Cleans a track title for deduplication/search: strips parenthetical/bracket suffixes
    public static func cleanTrackTitle(_ title: String) -> String {
        var cleaned = title
            .replacingOccurrences(of: "\\s*\\([^)]*\\)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s*\\[[^\\]]*\\]", with: "", options: .regularExpression)
        // Handle unclosed parenthesis — strip from first ( onwards
        if let parenIdx = cleaned.firstIndex(of: "(") {
            cleaned = String(cleaned[cleaned.startIndex..<parenIdx])
        }
        if let bracketIdx = cleaned.firstIndex(of: "[") {
            cleaned = String(cleaned[cleaned.startIndex..<bracketIdx])
        }
        // Strip common track-specific suffixes that don't identify the album
        let suffixes = [" End Titles", " Main Theme", " Main Title", " End Credits",
                        " Opening Credits", " Opening Theme", " Closing Credits",
                        " Suite", " Finale", " Overture", " Prologue", " Epilogue",
                        " Reprise", " Instrumental"]
        for suffix in suffixes {
            if cleaned.hasSuffix(suffix) {
                cleaned = String(cleaned.dropLast(suffix.count))
                break
            }
        }
        return cleaned.trimmingCharacters(in: .whitespaces)
    }

    private func cacheSet(_ key: String, _ value: String?) {
        cacheLock.lock()
        cache[key] = value
        cacheLock.unlock()
    }

    /// Low-level iTunes Search API call. `unthrottled` routes around
    /// the self-throttle (12 req/min cap) for user-facing latency-
    /// sensitive paths — matches the policy in
    /// `ServiceSearchProvider.fetchiTunes` and `ArtworkSearchView` so
    /// background art enrichment can't starve the now-playing radio
    /// art lookup. Apple-side 403/429 cooldown still applies in both
    /// modes; only the local soft-limit is bypassed.
    private func iTunesSearch(query: String, entity: String, limit: Int = 1, maxWait: TimeInterval = 0, unthrottled: Bool = false) async -> String? {
        let result = await iTunesSearchFull(query: query, entity: entity, limit: limit, maxWait: maxWait, unthrottled: unthrottled)
        return result?.artURL
    }

    /// iTunes search that also returns metadata for verification
    private func iTunesSearchFull(query: String, entity: String, limit: Int = 3, maxWait: TimeInterval = 0, unthrottled: Bool = false) async -> (artURL: String, artistName: String, collectionName: String, trackName: String)? {
        // Explicit `country=US` so the US iTunes catalog is searched
        // regardless of the caller's IP geolocation. Maximises chance
        // of finding artists who may not have storefronts in every region.
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?term=\(encoded)&media=music&entity=\(entity)&limit=\(limit)&country=US") else {
            return nil
        }

        let result: (Data, URLResponse)?
        if unthrottled {
            result = await ITunesRateLimiter.shared.performUnthrottled(url: url, session: session)
        } else {
            result = await ITunesRateLimiter.shared.perform(url: url, session: session, maxWait: maxWait)
        }
        guard let (data, _) = result else {
            // Rate limiter swallowed the request (cooldown, throttle,
            // network error, non-2xx). Its own log already captured why.
            sonosDiagLog(.warning, tag: "ART",
                         "iTunes \(entity) request returned nil for query=\(query) — rate limiter denied or HTTP failure")
            return nil
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            sonosDiagLog(.warning, tag: "ART",
                         "iTunes \(entity) JSON parse failed for query=\(query)")
            return nil
        }
        let results = (json["results"] as? [[String: Any]]) ?? []
        guard let first = results.first else {
            // Demoted to debug — most tracks the background prewarmer
            // queries don't have iTunes-indexed art; this is normal
            // miss noise that was saturating the diagnostics ring
            // buffer (1000-entry cap evicted in minutes during heavy
            // playback) and burying real warnings.
            sonosDiagLog(.debug, tag: "ART",
                         "iTunes \(entity) returned 0 results for query=\(query)")
            return nil
        }

        let artURL = first["artworkUrl100"] as? String ??
                     first["artworkUrl60"] as? String ??
                     first["artworkUrl30"] as? String
        guard let art = artURL else {
            let artistName = first["artistName"] as? String ?? "<nil>"
            // Demoted to debug — same noise reason as the 0-results
            // case above. The outer `searchArtistArt` cascade already
            // emits a single warning when ALL entity types miss.
            sonosDiagLog(.debug, tag: "ART",
                         "iTunes \(entity) result for \(query) has no artworkUrl (artistName=\(artistName), totalResults=\(results.count))")
            return nil
        }

        let upscaled = art.replacingOccurrences(of: "100x100", with: "600x600")
                          .replacingOccurrences(of: "60x60", with: "600x600")
                          .replacingOccurrences(of: "30x30", with: "600x600")

        return (
            artURL: upscaled,
            artistName: first["artistName"] as? String ?? "",
            collectionName: first["collectionName"] as? String ?? "",
            trackName: first["trackName"] as? String ?? ""
        )
    }

    // MARK: - Text Cleaning for Search

    /// Cleans a track title for search: strips source suffixes (e.g. " - Musicfire.in"),
    /// normalizes special characters, removes non-alphanumeric noise.
    private func cleanForSearch(_ text: String) -> String {
        var cleaned = text

        // Strip " - <source>" suffix (text after last " - ")
        if let dashRange = cleaned.range(of: " - ", options: .backwards) {
            let suffix = String(cleaned[dashRange.upperBound...])
            // Only strip if suffix looks like a source (contains dot or is short)
            if suffix.contains(".") || suffix.count < 20 {
                cleaned = String(cleaned[..<dashRange.lowerBound])
            }
        }

        // Normalize curly quotes/apostrophes to ASCII
        cleaned = cleaned
            .replacingOccurrences(of: "\u{2018}", with: "'")  // '
            .replacingOccurrences(of: "\u{2019}", with: "'")  // '
            .replacingOccurrences(of: "\u{201C}", with: "\"") // "
            .replacingOccurrences(of: "\u{201D}", with: "\"") // "

        // Strip non-alphanumeric except spaces and basic apostrophe
        cleaned = cleaned.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "'" }
            .map { String($0) }
            .joined()

        // Collapse whitespace
        cleaned = cleaned.components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return cleaned.lowercased().trimmingCharacters(in: .whitespaces)
    }

    /// Cleans an artist string: takes first artist from slash-separated lists,
    /// strips source names (containing dots), normalizes characters.
    private func cleanArtist(_ text: String) -> String {
        // Split on "/" and filter out source-like entries (contain dots like "Musicfire.in")
        let parts = text.components(separatedBy: "/")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains(".") }

        let artist = parts.first ?? text
        return cleanForSearch(artist)
    }

    /// Verified song search — scans results for best track/album name match.
    /// Requires at least 30% of significant words to match (track or album name).
    /// Filters out common words to focus on distinguishing terms.
    private static let commonWords: Set<String> = [
        "the", "and", "for", "from", "with", "feat", "remix", "version",
        "original", "motion", "picture", "soundtrack", "remaster", "remastered",
        "edit", "mix", "live", "album", "single", "deluxe", "edition"
    ]

    private func verifiedSongSearch(query: String, expectedTitle: String, unthrottled: Bool = false) async -> String? {
        guard let results = await iTunesSearchAll(query: query, entity: "song", limit: 10, unthrottled: unthrottled) else { return nil }
        let expected = expectedTitle.lowercased()
        // Filter to significant words: > 2 chars and not common filler
        let expectedWords = expected.components(separatedBy: .whitespaces)
            .filter { $0.count > 2 && !Self.commonWords.contains($0) }
        guard !expectedWords.isEmpty else {
            return results.first?.artURL
        }
        // Require at least 30% of significant words to match
        let threshold = max(1, (expectedWords.count * 3 + 9) / 10) // ceiling of count * 0.3
        var bestURL: String?
        var bestScore = 0
        for result in results {
            let trackWords = expectedWords.filter { result.trackName.lowercased().contains($0) }.count
            let albumWords = expectedWords.filter { result.collectionName.lowercased().contains($0) }.count
            let score = max(trackWords, albumWords)
            if score > bestScore {
                bestScore = score
                bestURL = result.artURL
            }
        }
        return bestScore >= threshold ? bestURL : nil
    }

    /// iTunes search returning all results for scoring
    private func iTunesSearchAll(query: String, entity: String, limit: Int, unthrottled: Bool = false) async -> [(artURL: String, trackName: String, collectionName: String)]? {
        // Explicit `country=US` so the US iTunes catalog is searched
        // regardless of the caller's IP geolocation. Maximises chance
        // of finding artists who may not have storefronts in every region.
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?term=\(encoded)&media=music&entity=\(entity)&limit=\(limit)&country=US") else {
            return nil
        }
        let result: (Data, URLResponse)?
        if unthrottled {
            result = await ITunesRateLimiter.shared.performUnthrottled(url: url, session: session)
        } else {
            result = await ITunesRateLimiter.shared.perform(url: url, session: session)
        }
        guard let (data, _) = result else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["results"] as? [[String: Any]] else { return nil }
        return items.compactMap { item in
            guard let art = item["artworkUrl100"] as? String else { return nil }
            let upscaled = art.replacingOccurrences(of: "100x100", with: "600x600")
                              .replacingOccurrences(of: "60x60", with: "600x600")
                              .replacingOccurrences(of: "30x30", with: "600x600")
            return (artURL: upscaled,
                    trackName: item["trackName"] as? String ?? "",
                    collectionName: item["collectionName"] as? String ?? "")
        }
    }
}
