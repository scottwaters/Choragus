/// AlbumArtSearchService.swift — Fetches album art from iTunes Search API.
///
/// Used as a fallback when Sonos doesn't provide album art.
/// Supports album searches, artist searches, and combined searches.
/// No API key required. Results are cached in memory to avoid repeat lookups.
import Foundation

public final class AlbumArtSearchService {
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

        // Strategy 3: Album search with artist + title (for soundtrack albums)
        if !artist.isEmpty {
            if let url = await iTunesSearch(query: "\(artist) \(title) soundtrack", entity: "album") {
                cacheSet(cacheKey, url)
                return url
            }
        }

        cacheSet(cacheKey, nil)
        return nil
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

    /// Verified song search — checks that the result's track name loosely matches the search title
    private func verifiedSongSearch(query: String, expectedTitle: String) async -> String? {
        guard let result = await iTunesSearchFull(query: query, entity: "song", limit: 5) else { return nil }
        let resultTrack = result.trackName.lowercased()
        let expected = expectedTitle.lowercased()
        // Accept if the result track name contains a significant portion of the expected title
        let expectedWords = expected.components(separatedBy: .whitespaces).filter { $0.count > 2 }
        let matchCount = expectedWords.filter { resultTrack.contains($0) }.count
        if expectedWords.isEmpty || matchCount >= max(1, expectedWords.count / 2) {
            return result.artURL
        }
        return nil
    }
}
