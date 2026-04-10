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
        let cacheKey = "art:\(artist.lowercased())|\(album.lowercased())"
        cacheLock.lock()
        if let cached = cache[cacheKey] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        // Strategy 1: Combined artist + album search
        if !artist.isEmpty && !album.isEmpty {
            if let url = await iTunesSearch(query: "\(artist) \(album)", entity: "album") {
                cacheSet(cacheKey, url)
                return url
            }
        }

        // Strategy 2: Album-only search
        if !album.isEmpty {
            if let url = await iTunesSearch(query: album, entity: "album") {
                cacheSet(cacheKey, url)
                return url
            }
        }

        // Strategy 3: Artist search (returns artist image)
        let artistQuery = !artist.isEmpty ? artist : album
        if !artistQuery.isEmpty {
            if let url = await iTunesSearch(query: artistQuery, entity: "musicArtist") {
                cacheSet(cacheKey, url)
                return url
            }
        }

        // Strategy 4: Broad song search (might find artwork from a popular track)
        if !album.isEmpty {
            if let url = await iTunesSearch(query: album, entity: "song") {
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
    private func iTunesSearch(query: String, entity: String, limit: Int = 1) async -> String? {
        let result = await iTunesSearchFull(query: query, entity: entity, limit: limit)
        return result?.artURL
    }

    /// iTunes search that also returns metadata for verification
    private func iTunesSearchFull(query: String, entity: String, limit: Int = 3) async -> (artURL: String, artistName: String, collectionName: String, trackName: String)? {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?term=\(encoded)&media=music&entity=\(entity)&limit=\(limit)") else {
            return nil
        }

        do {
            let (data, response) = try await session.data(for: URLRequest(url: url))

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return nil
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
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
        } catch {
            return nil
        }
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

    /// Verified song search — scans results for best track/album name match
    private func verifiedSongSearch(query: String, expectedTitle: String) async -> String? {
        guard let results = await iTunesSearchAll(query: query, entity: "song", limit: 10) else { return nil }
        let expected = expectedTitle.lowercased()
        let expectedWords = expected.components(separatedBy: .whitespaces).filter { $0.count > 2 }
        guard !expectedWords.isEmpty else {
            return results.first?.artURL
        }
        // Low threshold — radio titles often contain multi-language text
        // so only a few words may match the English iTunes result
        let threshold = max(1, expectedWords.count / 4)
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
        do {
            let (data, response) = try await session.data(for: URLRequest(url: url))
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
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
        } catch { return nil }
    }
}
