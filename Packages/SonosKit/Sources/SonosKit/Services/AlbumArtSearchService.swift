/// AlbumArtSearchService.swift — Fetches album art from iTunes Search API.
///
/// Used as a fallback when Sonos doesn't provide album art.
/// Supports album searches, artist searches, and combined searches.
/// No API key required. Results are cached in memory to avoid repeat lookups.
import Foundation

public final class AlbumArtSearchService: AlbumArtSearchProtocol {
    public static let shared = AlbumArtSearchService()

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
    public func searchArtwork(artist: String, album: String) async -> String? {
        await searchArtwork(artist: artist, album: album, maxWait: 0)
    }

    public func searchArtwork(artist: String, album: String, maxWait: TimeInterval) async -> String? {
        let cacheKey = "art:\(artist.lowercased())|\(album.lowercased())"
        cacheLock.lock()
        if let cached = cache[cacheKey] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        // Strategy 1: Combined artist + album search
        if !artist.isEmpty && !album.isEmpty {
            if let url = await iTunesSearch(query: "\(artist) \(album)", entity: "album", maxWait: maxWait) {
                cacheSet(cacheKey, url)
                return url
            }
        }

        // Strategy 2: Album-only search
        if !album.isEmpty {
            if let url = await iTunesSearch(query: album, entity: "album", maxWait: maxWait) {
                cacheSet(cacheKey, url)
                return url
            }
        }

        // Strategy 3: Artist search (returns artist image)
        let artistQuery = !artist.isEmpty ? artist : album
        if !artistQuery.isEmpty {
            if let url = await iTunesSearch(query: artistQuery, entity: "musicArtist", maxWait: maxWait) {
                cacheSet(cacheKey, url)
                return url
            }
        }

        // Strategy 4: Broad song search (might find artwork from a popular track)
        if !album.isEmpty {
            if let url = await iTunesSearch(query: album, entity: "song", maxWait: maxWait) {
                cacheSet(cacheKey, url)
                return url
            }
        }

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

        // Strategy 0a: Soundtrack-track shape via title ("X End Titles",
        // "Theme From X", etc.) — see `extractMovieName`.
        if Self.titleHasSoundtrackShape(title),
           let movie = Self.extractMovieName(from: title), !movie.isEmpty {
            if let url = await iTunesSearch(query: "\(movie) soundtrack", entity: "album") {
                sonosDebugLog("[ART/RADIO] OST hit (title) movie=\(movie) artist=\(artist)")
                cacheSet(cacheKey, url)
                return url
            }
        }

        // Strategy 0b: Soundtrack stations frequently put the *movie name*
        // in the artist field instead of the actual composer/performer
        // (e.g. 1.FM Movie Soundtracks Hits sends artist="Beauty and the
        // Beast" for "Battle on the Tower"). When Strategy 0a missed,
        // try treating the artist string as the movie name and search
        // its OST. Constrained to non-trivial multi-character strings
        // so we don't fire for empty / one-word artists.
        if !artist.isEmpty, artist.count >= 3 {
            if let url = await iTunesSearch(query: "\(artist) soundtrack", entity: "album") {
                sonosDebugLog("[ART/RADIO] OST hit (artist-as-movie) movie=\(artist)")
                cacheSet(cacheKey, url)
                return url
            }
        }

        // Strategy 1: Verified song search with artist + title
        if !artist.isEmpty {
            if let url = await verifiedSongSearch(query: "\(artist) \(title)", expectedTitle: title) {
                cacheSet(cacheKey, url)
                return url
            }
        }

        // Strategy 2: Verified song search with just title
        if let url = await verifiedSongSearch(query: title, expectedTitle: title) {
            cacheSet(cacheKey, url)
            return url
        }

        // Strategy 3: Album search with title only (for soundtrack albums)
        // Use title without artist — the artist (orchestra) is too generic for soundtrack matching
        if let url = await iTunesSearch(query: "\(title) soundtrack", entity: "album") {
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
                if let url = await verifiedSongSearch(query: "\(cleanedArtist) \(cleanedTitle)", expectedTitle: cleanedTitle) {
                    cacheSet(cacheKey, url)
                    return url
                }
            }
            if !cleanedTitle.isEmpty {
                if let url = await verifiedSongSearch(query: cleanedTitle, expectedTitle: cleanedTitle) {
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

    /// Low-level iTunes Search API call
    private func iTunesSearch(query: String, entity: String, limit: Int = 1, maxWait: TimeInterval = 0) async -> String? {
        let result = await iTunesSearchFull(query: query, entity: entity, limit: limit, maxWait: maxWait)
        return result?.artURL
    }

    /// iTunes search that also returns metadata for verification
    private func iTunesSearchFull(query: String, entity: String, limit: Int = 3, maxWait: TimeInterval = 0) async -> (artURL: String, artistName: String, collectionName: String, trackName: String)? {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?term=\(encoded)&media=music&entity=\(entity)&limit=\(limit)") else {
            return nil
        }

        guard let (data, _) = await ITunesRateLimiter.shared.perform(url: url, session: session, maxWait: maxWait) else {
            return nil
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]],
              let first = results.first else {
            return nil
        }

        let artURL = first["artworkUrl100"] as? String ??
                     first["artworkUrl60"] as? String ??
                     first["artworkUrl30"] as? String
        guard let art = artURL else { return nil }

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

    private func verifiedSongSearch(query: String, expectedTitle: String) async -> String? {
        guard let results = await iTunesSearchAll(query: query, entity: "song", limit: 10) else { return nil }
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
    private func iTunesSearchAll(query: String, entity: String, limit: Int) async -> [(artURL: String, trackName: String, collectionName: String)]? {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?term=\(encoded)&media=music&entity=\(entity)&limit=\(limit)") else {
            return nil
        }
        guard let (data, _) = await ITunesRateLimiter.shared.perform(url: url, session: session) else {
            return nil
        }
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
