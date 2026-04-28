/// LyricsService.swift — Free, no-key lyrics from LRCLIB.
///
/// LRCLIB (`lrclib.net`) is a community lyrics database aimed
/// specifically at offline music players. Single anonymous GET,
/// returns both `plainLyrics` and `syncedLyrics` (LRC format with
/// `[mm:ss.xx]` timestamps per line) when synced data is available.
///
/// Caching is permanent — lyrics don't change. The
/// `MetadataCacheRepository` handles persistence; on cache hit we
/// don't make any network call.
import Foundation

public struct Lyrics: Codable, Equatable, Sendable {
    public let plainText: String?
    /// LRC-format synced lyrics. Each line carries one or more
    /// `[mm:ss.xx]` timestamps at its head. Parse via
    /// `Lyrics.parseSynced(_:)` to get `[(seconds, line)]`.
    public let synced: String?
    public let isInstrumental: Bool

    public init(plainText: String?, synced: String?, isInstrumental: Bool) {
        self.plainText = plainText
        self.synced = synced
        self.isInstrumental = isInstrumental
    }

    /// Parses LRC into `(secondsFromStart, line)` pairs in time order.
    /// Lines without timestamps are dropped. Used by the lyrics UI to
    /// pick the line whose timestamp is the largest one not exceeding
    /// the current track position.
    public static func parseSynced(_ lrc: String) -> [(time: Double, line: String)] {
        var out: [(Double, String)] = []
        // Time-tag prefix shape: `[mm:ss.xx]`. A line can carry
        // multiple prefixes when the same line repeats; emit one row
        // per timestamp so the seek-to-line lookup stays a flat array.
        let pattern = #/\[(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?\]/#
        for rawLine in lrc.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let matches = line.matches(of: pattern)
            guard !matches.isEmpty else { continue }
            // The text portion is whatever comes after the LAST tag.
            let lastTagEnd = matches.last!.range.upperBound
            let text = String(line[lastTagEnd...]).trimmingCharacters(in: .whitespaces)
            if text.isEmpty { continue }
            for match in matches {
                let mins = Int(match.output.1) ?? 0
                let secs = Int(match.output.2) ?? 0
                let frac: Double = match.output.3.flatMap { Double($0) } ?? 0
                let fracSeconds = frac > 0 ? frac / pow(10, Double(String(match.output.3 ?? "").count)) : 0
                let total = Double(mins * 60 + secs) + fracSeconds
                out.append((total, text))
            }
        }
        return out.sorted { $0.0 < $1.0 }
    }
}

public final class LyricsService: Sendable {

    private let session: URLSession
    private let cache: MetadataCacheRepository

    public init(cache: MetadataCacheRepository) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        self.session = URLSession(configuration: config)
        self.cache = cache
    }

    /// Fetches lyrics for `(artist, title, album, duration)`. Cache
    /// hit returns immediately. Cache miss fires a single GET against
    /// LRCLIB; result (or a "no lyrics" sentinel) is written back so
    /// repeated plays of the same track are free.
    public func fetch(artist: String, title: String,
                      album: String? = nil, durationSeconds: Int? = nil) async -> Lyrics? {
        let key = MetadataCacheRepository.Kind.lyrics.key(artist, title, album ?? "")
        let summary = "[\(artist)|\(title)|\(album ?? "")|d=\(durationSeconds.map(String.init) ?? "-")]"

        // Cache lookup. We accept a cached *hit* unconditionally, but cached
        // *misses* are only authoritative if they came from the v2 fallback
        // chain (`fallbackVersion >= 2`). Older misses pre-date the
        // search-fallback strategy and may have been false negatives caused
        // by a wrong album_name (compilations are the common case), so we
        // re-resolve them through the new chain.
        if let cached = cache.get(key),
           let data = cached.data(using: .utf8),
           let stored = try? JSONDecoder().decode(LRCLIBResponse.self, from: data) {
            if stored._miss == true {
                if (stored.fallbackVersion ?? 0) >= currentFallbackVersion {
                    sonosDebugLog("[LYRICS] cache miss (v2 authoritative) \(summary)")
                    return nil
                }
                sonosDebugLog("[LYRICS] cache miss v1 — retrying \(summary)")
            } else {
                sonosDebugLog("[LYRICS] cache hit \(summary) synced=\(stored.syncedLyrics?.isEmpty == false) plain=\(stored.plainLyrics?.isEmpty == false)")
                return stored.toLyrics()
            }
        }

        sonosDebugLog("[LYRICS] fetch start \(summary)")

        // Resolution chain:
        // 1. /api/get with full args (artist + title + album + duration)
        // 2. /api/get without album         — defeats compilation-album misses
        // 3. /api/search?artist_name&track_name and pick the best result
        //    (prefer one with synced lyrics, then any with lyrics)
        // Each step short-circuits as soon as it returns a usable Lyrics.
        let exact = await getEndpoint(artist: artist, title: title,
                                      album: album, duration: durationSeconds)
        if let exact {
            sonosDebugLog("[LYRICS] resolved via /api/get (full) \(summary)")
            return persist(exact, for: key)
        }

        if let album, !album.isEmpty {
            let albumless = await getEndpoint(artist: artist, title: title,
                                              album: nil, duration: durationSeconds)
            if let albumless {
                sonosDebugLog("[LYRICS] resolved via /api/get (no album) \(summary)")
                return persist(albumless, for: key)
            }
        }

        if let searched = await searchEndpoint(artist: artist, title: title) {
            sonosDebugLog("[LYRICS] resolved via /api/search \(summary)")
            return persist(searched, for: key)
        }
        // If we got here because the task was cancelled (e.g. trackKey
        // changed mid-fetch when the artist-enrichment landed), do *not*
        // cache a miss — every endpoint call would have returned nil
        // for transport reasons, not because LRCLIB doesn't have the
        // song. Caching the miss in this state poisons the next play.
        if Task.isCancelled {
            sonosDebugLog("[LYRICS] task cancelled mid-fetch — skipping miss cache \(summary)")
            return nil
        }
        sonosDebugLog("[LYRICS] all strategies failed \(summary)")

        // All strategies exhausted — cache the miss with the current chain
        // version so we don't keep retrying every play.
        let miss = LRCLIBResponse(plainLyrics: nil, syncedLyrics: nil,
                                  instrumental: false, _miss: true,
                                  fallbackVersion: currentFallbackVersion)
        if let encoded = try? JSONEncoder().encode(miss),
           let str = String(data: encoded, encoding: .utf8) {
            cache.set(key, payload: str)
        }
        return nil
    }

    /// Bumps when the resolution strategy meaningfully changes; older cached
    /// misses with a lower version are retried with the new strategy.
    /// v3: skip miss-caching when the task was cancelled mid-fetch.
    /// Existing v2 misses may have been false negatives caused by the
    /// trackKey-change cancellation race, so we re-resolve them.
    private let currentFallbackVersion = 3

    // MARK: - User offset persistence

    /// Persists the user-chosen lyrics timing offset for a track. The
    /// offset survives app relaunch and track switches because it's
    /// stored in the same SQLite metadata cache as lyrics content.
    /// `seconds` may be negative (lyrics arrived too late), positive
    /// (too early), or zero (which clears the entry).
    public func saveOffset(artist: String, title: String, album: String?, seconds: Double) {
        let key = MetadataCacheRepository.Kind.lyricsOffset.key(artist, title, album ?? "")
        if seconds == 0 {
            cache.clear(key)
            return
        }
        let payload = LyricsOffsetEntry(seconds: seconds)
        guard let encoded = try? JSONEncoder().encode(payload),
              let str = String(data: encoded, encoding: .utf8) else { return }
        // No TTL — the offset is the user's choice and shouldn't expire.
        cache.set(key, payload: str)
    }

    /// Returns the stored offset for a track, or `nil` if none.
    public func loadOffset(artist: String, title: String, album: String?) -> Double? {
        let key = MetadataCacheRepository.Kind.lyricsOffset.key(artist, title, album ?? "")
        guard let str = cache.get(key),
              let data = str.data(using: .utf8),
              let entry = try? JSONDecoder().decode(LyricsOffsetEntry.self, from: data) else {
            return nil
        }
        return entry.seconds
    }

    private struct LyricsOffsetEntry: Codable {
        let seconds: Double
    }

    /// Single hit against `/api/get`. Returns the decoded response on 200,
    /// nil on 404 or any other failure.
    private func getEndpoint(artist: String, title: String,
                             album: String?, duration: Int?) async -> LRCLIBResponse? {
        guard let url = buildGetURL(artist: artist, title: title,
                                    album: album, duration: duration) else {
            return nil
        }
        var request = URLRequest(url: url)
        request.setValue("Choragus/1.0 (https://github.com/scottwaters/Choragus)",
                         forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { return nil }
            return try? JSONDecoder().decode(LRCLIBResponse.self, from: data)
        } catch {
            sonosDebugLog("[LYRICS] /api/get failed for \(artist) – \(title): \(error)")
            return nil
        }
    }

    /// Falls back to `/api/search` and returns the best candidate. Prefers
    /// results with synced lyrics; otherwise the first non-instrumental hit
    /// with plain text. LRCLIB ranks by relevance so the first result is
    /// usually the original release.
    ///
    /// When `artist` is empty (some Sonos favorites omit the field) we
    /// switch to the freeform `q` parameter on the title alone; LRCLIB's
    /// search ranks reasonably well by title popularity and we accept the
    /// top hit.
    private func searchEndpoint(artist: String, title: String) async -> LRCLIBResponse? {
        var components = URLComponents(string: "https://lrclib.net/api/search")
        if artist.isEmpty {
            components?.queryItems = [
                URLQueryItem(name: "q", value: title)
            ]
        } else {
            components?.queryItems = [
                URLQueryItem(name: "artist_name", value: artist),
                URLQueryItem(name: "track_name", value: title)
            ]
        }
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Choragus/1.0 (https://github.com/scottwaters/Choragus)",
                         forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200,
                  let results = try? JSONDecoder().decode([LRCLIBResponse].self, from: data),
                  !results.isEmpty else {
                return nil
            }
            if let synced = results.first(where: { ($0.syncedLyrics?.isEmpty == false) }) {
                return synced
            }
            if let plain = results.first(where: { ($0.plainLyrics?.isEmpty == false) }) {
                return plain
            }
            return results.first
        } catch {
            sonosDebugLog("[LYRICS] /api/search failed for \(artist) – \(title): \(error)")
            return nil
        }
    }

    /// Persists a successful resolution to the cache and returns the
    /// caller-facing Lyrics value (or nil if the response decoded to no
    /// content, in which case the miss-cache path takes over).
    private func persist(_ response: LRCLIBResponse, for key: String) -> Lyrics? {
        if let encoded = try? JSONEncoder().encode(response),
           let str = String(data: encoded, encoding: .utf8) {
            cache.set(key, payload: str)
        }
        return response.toLyrics()
    }

    private func buildGetURL(artist: String, title: String,
                             album: String?, duration: Int?) -> URL? {
        var components = URLComponents(string: "https://lrclib.net/api/get")
        var items: [URLQueryItem] = [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name", value: title),
        ]
        if let album, !album.isEmpty {
            items.append(URLQueryItem(name: "album_name", value: album))
        }
        if let duration, duration > 0 {
            items.append(URLQueryItem(name: "duration", value: "\(duration)"))
        }
        components?.queryItems = items
        return components?.url
    }
}

// MARK: - LRCLIB response shape

/// Minimal mirror of LRCLIB's `/api/get` response. Field names match
/// the API exactly so JSONDecoder doesn't need `CodingKeys`.
private struct LRCLIBResponse: Codable {
    let plainLyrics: String?
    let syncedLyrics: String?
    let instrumental: Bool?
    /// Internal flag used to cache "no lyrics found" without confusing
    /// real responses. Not present in the actual API.
    let _miss: Bool?
    /// Resolution-strategy version used when this miss was cached. Older
    /// values mean the miss pre-dates a meaningful improvement to the
    /// chain (e.g. v2 added /api/search fallback) and should be retried.
    let fallbackVersion: Int?

    init(plainLyrics: String?, syncedLyrics: String?, instrumental: Bool?,
         _miss: Bool? = nil, fallbackVersion: Int? = nil) {
        self.plainLyrics = plainLyrics
        self.syncedLyrics = syncedLyrics
        self.instrumental = instrumental
        self._miss = _miss
        self.fallbackVersion = fallbackVersion
    }

    func toLyrics() -> Lyrics? {
        if _miss == true { return nil }
        let plain = plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines)
        let synced = syncedLyrics?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Treat empty strings as nil so callers can branch on
        // `lyrics?.plainText != nil` cleanly.
        let plainOK = (plain?.isEmpty == false) ? plain : nil
        let syncedOK = (synced?.isEmpty == false) ? synced : nil
        if plainOK == nil && syncedOK == nil && !(instrumental ?? false) {
            return nil
        }
        return Lyrics(plainText: plainOK, synced: syncedOK,
                      isInstrumental: instrumental ?? false)
    }
}
