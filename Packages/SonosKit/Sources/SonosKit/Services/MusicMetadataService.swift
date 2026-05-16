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
public final class MusicMetadataService: ArtistInfoProvider {

    /// Optional Apple Music catalog enrichment hooks. Set by the host
    /// app when MusicKit is authorised. Returning `nil` falls through to
    /// the existing Wikipedia / MusicBrainz / Last.fm merge, so this is
    /// purely additive — fork builds without MusicKit see no change.
    /// Tuple shape: `(imageURL: String?, genres: [String])` — Apple
    /// Music doesn't expose artist bios, only artwork + genre tags.
    public nonisolated(unsafe) static var appleMusicArtistEnrichment: ((_ artist: String) async -> (imageURL: String?, genres: [String])?)?
    public nonisolated(unsafe) static var appleMusicAlbumEnrichment: ((_ artist: String, _ album: String) async -> (imageURL: String?, genres: [String])?)?

    private let tokenStore: LastFMTokenStore
    private let cache: MetadataCacheRepository
    private let session: URLSession
    /// User-Agent header — required by MusicBrainz, polite for the
    /// rest. Identifies us so source operators can spot a misbehaving
    /// client and reach the maintainer.
    private let userAgent = "Choragus/1.0 (https://github.com/scottwaters/Choragus)"

    // MARK: - Locale helpers

    /// Maps the user's app language to the Wikipedia subdomain prefix.
    /// Wikipedia hosts a separate site per language at `<lang>.wikipedia.org`;
    /// we hit the localised one first, then fall back to English on 404
    /// since not every article has a translation. Simplified Chinese
    /// uses the shared `zh.wikipedia.org` (variants are negotiated via
    /// the `Accept-Language` header rather than separate subdomains).
    nonisolated private func wikipediaLanguageCode() -> String {
        let lang = UserDefaults.standard.string(forKey: UDKey.appLanguage) ?? "en"
        if lang.hasPrefix("zh") { return "zh" }
        return lang
    }

    /// ISO 639-1 code that Last.fm's `artist.getInfo` / `album.getInfo`
    /// `lang` parameter accepts. Same mapping as Wikipedia for the
    /// languages Choragus ships, except Last.fm doesn't take regional
    /// qualifiers, so `zh-Hans` collapses to `zh`.
    nonisolated private func lastFMLanguageCode() -> String {
        let lang = UserDefaults.standard.string(forKey: UDKey.appLanguage) ?? "en"
        if lang.hasPrefix("zh") { return "zh" }
        return lang
    }

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
        cache.clear(MetadataCacheRepository.Kind.artist.key(Self.metadataSchemaVersion, lastFMLanguageCode(), trimmed))
    }

    /// Drops the cached `albumInfo` entry. Mirrors `invalidateArtist`.
    public func invalidateAlbum(artist: String, album: String) {
        guard !album.isEmpty else { return }
        cache.clear(MetadataCacheRepository.Kind.album.key(Self.metadataSchemaVersion, lastFMLanguageCode(), artist, album))
    }

    /// Cache schema version for `ArtistInfo` / `AlbumInfo` payloads.
    /// Bump this when a fix changes how empty/placeholder values are
    /// produced so existing entries from the previous version are
    /// silently ignored (they remain in the DB until natural TTL
    /// expiry but never match the new key shape). Avoids stranding
    /// users on stale "no image" cache hits for famous artists when
    /// the underlying lookup logic improves.
    private static let metadataSchemaVersion = "v2"

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

        // Cache key includes the user's app language so a German bio and
        // a French bio for the same artist don't fight for the same
        // entry. Switching language re-resolves rather than serving the
        // previously-cached translation. Schema version prefix lets us
        // invalidate the entire cache when fix logic changes (see
        // `metadataSchemaVersion`).
        let key = MetadataCacheRepository.Kind.artist.key(Self.metadataSchemaVersion, lastFMLanguageCode(), trimmed)
        if let cached = cache.get(key),
           let data = cached.data(using: .utf8),
           let info = try? JSONDecoder().decode(ArtistInfo.self, from: data) {
            // Treat cached placeholder/garbage entries as a miss and
            // re-resolve. Catches results that were stored under a
            // legitimate-looking name before the source-side filter
            // was added — also catches the "all-empty" entries written
            // when the Wikipedia bare-name candidate was temporarily
            // disabled, so users don't wait out the 30-day TTL for
            // famous artists (Madonna, U2, Radiohead, …) to recover.
            if !Self.looksLikePlaceholderArtist(info)
                && !Self.looksLikeEmptyArtist(info) {
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
        var merged = mergeArtist(name: trimmed, parts: parts.compactMap { $0 })
        guard let unwrapped = merged else { return nil }

        // Image fallback: Last.fm withdrew real artist images post-2019
        // (we filter the placeholder), and Wikipedia thumbnails are only
        // present when the article has a lead image. For artists missing
        // both, fall back to iTunes Search's artist endpoint — typically
        // returns a 100×100 photo, small but better than blank.
        if (unwrapped.imageURL?.isEmpty ?? true),
           let itunesArt = await AlbumArtSearchService.shared.searchArtistArt(artist: trimmed) {
            merged = ArtistInfo(
                name: unwrapped.name,
                bio: unwrapped.bio,
                tags: unwrapped.tags,
                similarArtists: unwrapped.similarArtists,
                listeners: unwrapped.listeners,
                imageURL: itunesArt,
                wikipediaURL: unwrapped.wikipediaURL
            )
        }

        // Apple Music catalog enrichment, when authorised. Adds Apple's
        // editorial genre tags to the top of `tags` (kept de-duplicated)
        // and replaces `imageURL` with the catalog artist photo when
        // the upstream sources came back empty/placeholder. Last.fm /
        // Wikipedia stay as the bio source — Apple's catalog doesn't
        // expose artist bios via MusicKit.
        if let enrich = Self.appleMusicArtistEnrichment,
           let amDetails = await enrich(trimmed),
           let current = merged {
            var newTags = amDetails.genres
            for tag in current.tags where !newTags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
                newTags.append(tag)
            }
            let newImage: String?
            if let amImage = amDetails.imageURL, !amImage.isEmpty {
                newImage = amImage
            } else {
                newImage = current.imageURL
            }
            merged = ArtistInfo(
                name: current.name,
                bio: current.bio,
                tags: newTags,
                similarArtists: current.similarArtists,
                listeners: current.listeners,
                imageURL: newImage,
                wikipediaURL: current.wikipediaURL
            )
        }

        if let final = merged,
           let encoded = try? JSONEncoder().encode(final),
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

    /// True for cached entries that resolved to "nothing useful" — no
    /// bio, no image, no tags, no listeners. A cache hit on one of
    /// these gives the user the same blank About card that prompted
    /// the original lookup, so we treat it as a miss and re-resolve.
    /// Catches both the disabled-candidate hangover and any source
    /// that is back online after a previous outage.
    nonisolated private static func looksLikeEmptyArtist(_ info: ArtistInfo) -> Bool {
        let hasBio = !(info.bio?.isEmpty ?? true)
        let hasImage = !(info.imageURL?.isEmpty ?? true)
        let hasTags = !info.tags.isEmpty
        let hasListeners = info.listeners != nil
        return !(hasBio || hasImage || hasTags || hasListeners)
    }

    /// Album equivalent of `looksLikeEmptyArtist` — same rationale.
    nonisolated private static func looksLikeEmptyAlbum(_ info: AlbumInfo) -> Bool {
        let hasSummary = !(info.summary?.isEmpty ?? true)
        let hasImage = !(info.imageURL?.isEmpty ?? true)
        let hasTags = !info.tags.isEmpty
        let hasTracks = !info.tracks.isEmpty
        let hasReleaseDate = !(info.releaseDate?.isEmpty ?? true)
        return !(hasSummary || hasImage || hasTags || hasTracks || hasReleaseDate)
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
        // Language-prefixed key — same rationale as `artistInfo`: the
        // cache stores per-locale results so flipping the app language
        // serves a fresh translation instead of the cached one. Schema
        // version prefix invalidates pre-fix cached entries on first
        // access; see `metadataSchemaVersion`.
        let key = MetadataCacheRepository.Kind.album.key(Self.metadataSchemaVersion, lastFMLanguageCode(), artist, album)
        if let cached = cache.get(key),
           let data = cached.data(using: .utf8),
           let info = try? JSONDecoder().decode(AlbumInfo.self, from: data),
           !Self.looksLikeEmptyAlbum(info) {
            return info
        }

        async let wiki = wikipediaAlbum(artist: artist, album: album)
        async let mb = musicBrainzAlbum(artist: artist, album: album)
        async let lfm = lastFMAlbum(artist: artist, album: album)

        let parts: [AlbumInfo?] = await [wiki, mb, lfm]
        var merged = mergeAlbum(title: album, artist: artist,
                                parts: parts.compactMap { $0 })
        guard let unwrapped = merged else { return nil }

        // Apple Music catalog enrichment — same shape as the artist
        // path. Adds Apple's genre tags + replaces image when empty.
        // No-op when the host app hasn't installed the callback (fork
        // builds without MusicKit).
        if let enrich = Self.appleMusicAlbumEnrichment,
           let amDetails = await enrich(artist, album) {
            var newTags = amDetails.genres
            for tag in unwrapped.tags where !newTags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
                newTags.append(tag)
            }
            let newImage: String?
            if let amImage = amDetails.imageURL, !amImage.isEmpty {
                newImage = amImage
            } else {
                newImage = unwrapped.imageURL
            }
            merged = AlbumInfo(
                title: unwrapped.title,
                artist: unwrapped.artist,
                releaseDate: unwrapped.releaseDate,
                summary: unwrapped.summary,
                tags: newTags,
                tracks: unwrapped.tracks,
                imageURL: newImage
            )
        }

        guard let finalMerged = merged else { return nil }
        if let encoded = try? JSONEncoder().encode(finalMerged),
           let str = String(data: encoded, encoding: .utf8) {
            cache.set(key, payload: str, ttlSeconds: 30 * 24 * 60 * 60)
        }
        return finalMerged
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
        // Try music-disambiguated forms first, then fall back to the
        // bare name. Many famous artists (Madonna, U2, Radiohead,
        // Coldplay, Pink Floyd, Lorde, …) have plain-title articles
        // with no `(band)` / `(musician)` disambiguator, so dropping
        // the bare candidate eliminates the most common case. The
        // description guard below (`descriptionLooksLikeArtist`)
        // catches non-music articles that the fuzzy OpenSearch lookup
        // can otherwise return for a bare query — e.g. "Animal House"
        // → 1978 film (description: "1978 American comedy film"
        // → no music token → rejected); "Air" → chemical element
        // (description: "mixture of gases…" → rejected). Any article
        // whose description names the subject as a musician/band/etc.
        // is accepted.
        let candidates = [
            "\(name) (band)",
            "\(name) (musician)",
            name,
        ]
        for candidate in candidates {
            guard let summary = await fetchLocalisedWikipediaSummary(query: candidate),
                  summary.type != "disambiguation",
                  let extract = summary.extract, !extract.isEmpty,
                  Self.resolvedTitleMatchesQuery(candidate: candidate,
                                                 resolvedTitle: summary.resolvedTitle),
                  Self.descriptionLooksLikeArtist(summary.description)
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

    /// True when the OpenSearch-resolved title is plausibly the article
    /// the candidate query was asking about. OpenSearch is fuzzy and will
    /// happily return "Animal husbandry" for "Animal House (band)" — we
    /// reject those by requiring the candidate's core (everything before
    /// any disambiguator) to appear as a substring of the resolved title.
    /// Resolution is case-insensitive and ignores diacritics.
    nonisolated private static func resolvedTitleMatchesQuery(candidate: String,
                                                              resolvedTitle: String?) -> Bool {
        guard let resolved = resolvedTitle, !resolved.isEmpty else {
            // No resolved title returned — direct-title lookup, accept.
            return true
        }
        // Strip the trailing "(...)" disambiguator from the candidate so
        // "Animal House (band)" compares as "Animal House".
        let core = candidate
            .replacingOccurrences(of: "\\s*\\([^)]*\\)\\s*$",
                                  with: "",
                                  options: .regularExpression)
            .folding(options: .diacriticInsensitive, locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespaces)
        guard !core.isEmpty else { return true }
        let resolvedFolded = resolved
            .folding(options: .diacriticInsensitive, locale: .current)
            .lowercased()
        return resolvedFolded.contains(core)
    }

    /// True when the Wikipedia summary's `description` field reads as a
    /// musician or musical group. Used as a final guard — even when the
    /// title matches, the article can be about a place, film, or species
    /// (e.g. "Air" the village in France). Wikipedia's short_description
    /// almost always names the subject's category in one short phrase.
    /// Empty/missing descriptions pass through; treating "no description"
    /// as a fail would over-prune (smaller articles legitimately omit it).
    nonisolated private static func descriptionLooksLikeArtist(_ description: String?) -> Bool {
        guard let desc = description?.lowercased(), !desc.isEmpty else { return true }
        let musicTokens = [
            "musician", "band", "singer", "rapper", "vocalist", "songwriter",
            "composer", "producer", "guitarist", "pianist", "drummer", "bassist",
            "violinist", "saxophonist", "trumpeter", "cellist", "percussionist",
            "dj", " mc ", "duo", "trio", "quartet", "quintet", "ensemble",
            "orchestra", "choir", "music group", "musical group", "rock group",
            "pop group", "boy band", "girl group", "hip hop group",
            "music project", "recording artist"
        ]
        for token in musicTokens where desc.contains(token) { return true }
        return false
    }

    private func wikipediaAlbum(artist: String, album: String) async -> AlbumInfo? {
        // Try music-disambiguated forms first, then fall back to the
        // bare title. Many albums (Random Access Memories, Abbey Road,
        // OK Computer, …) live at plain-title URLs with no `(album)`
        // qualifier. The description guard below
        // (`descriptionLooksLikeRelease`) catches non-album articles
        // a bare match could land on — descriptions naming the subject
        // as an album / EP / single / soundtrack pass; everything else
        // is rejected.
        let candidates = [
            "\(album) (\(artist) album)",
            "\(album) (album)",
            "\(album) (soundtrack)",
            "\(album) (EP)",
            album,
        ]
        for title in candidates {
            if let summary = await fetchLocalisedWikipediaSummary(directTitle: title),
               summary.type != "disambiguation",
               let extract = summary.extract, !extract.isEmpty,
               Self.descriptionLooksLikeRelease(summary.description) {
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

    /// True when the Wikipedia summary's description reads as a release
    /// (album, EP, single, soundtrack). Mirror of
    /// `descriptionLooksLikeArtist` for the album branch. Empty/missing
    /// descriptions pass through.
    nonisolated private static func descriptionLooksLikeRelease(_ description: String?) -> Bool {
        guard let desc = description?.lowercased(), !desc.isEmpty else { return true }
        let releaseTokens = [
            "album", "ep ", " ep,", "single by", "soundtrack",
            "compilation", "studio album", "live album", "remix album",
            "mixtape", "boxed set", "box set", "song by",
            "extended play"
        ]
        for token in releaseTokens where desc.contains(token) { return true }
        return false
    }

    /// Resolves a Wikipedia article in the user's app language, falling
    /// back to English on miss. The returned `pageURL` points at
    /// whichever Wikipedia served the article — when you tap "Read on
    /// Wikipedia" it lands in the same language.
    ///
    /// Two entry points: `query` runs OpenSearch first to find a title
    /// (used for artist names where Wikipedia uses disambiguators we
    /// can't predict), `directTitle` skips OpenSearch and goes straight
    /// to the summary endpoint (used for album titles where the
    /// candidate strings are already canonical).
    ///
    /// `resolvedTitle` is propagated on the result so callers can apply
    /// a fuzzy-mismatch guard (OpenSearch silently substitutes
    /// edit-distance matches when no exact article exists).
    private nonisolated func fetchLocalisedWikipediaSummary(query: String) async -> WikipediaSummary? {
        let primary = wikipediaLanguageCode()
        if let title = await wikipediaResolveTitle(query: query, lang: primary),
           let summary = await wikipediaSummary(title: title, lang: primary, resolvedTitle: title) {
            return summary
        }
        // Fallback chain: not every article has a translation, so on a
        // miss we retry on en.wikipedia.org. Skipped when the user is
        // already on English.
        guard primary != "en" else { return nil }
        if let title = await wikipediaResolveTitle(query: query, lang: "en") {
            return await wikipediaSummary(title: title, lang: "en", resolvedTitle: title)
        }
        return nil
    }

    private nonisolated func fetchLocalisedWikipediaSummary(directTitle: String) async -> WikipediaSummary? {
        let primary = wikipediaLanguageCode()
        if let summary = await wikipediaSummary(title: directTitle, lang: primary, resolvedTitle: nil) {
            return summary
        }
        guard primary != "en" else { return nil }
        return await wikipediaSummary(title: directTitle, lang: "en", resolvedTitle: nil)
    }

    /// Resolves the best matching Wikipedia article title using the
    /// OpenSearch endpoint, which returns "the most likely article"
    /// for an arbitrary query. Returns nil if Wikipedia has no match.
    /// `lang` selects the wiki subdomain (`en`, `de`, etc.).
    private nonisolated func wikipediaResolveTitle(query: String, lang: String) async -> String? {
        guard let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://\(lang).wikipedia.org/w/api.php?action=opensearch&search=\(q)&limit=1&format=json")
        else { return nil }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        // Simplified Chinese variant negotiation lives in the
        // Accept-Language header — `zh.wikipedia.org` serves either
        // Hans or Hant based on what the client asks for.
        if lang == "zh" {
            request.setValue("zh-Hans", forHTTPHeaderField: "Accept-Language")
        }
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
        /// One-line plain-language category from `description` (e.g.
        /// "American rock band", "1978 American comedy film"). Used as
        /// a category guard so non-music articles can be rejected even
        /// when the title check passes.
        let description: String?
        /// Title returned by OpenSearch (when this summary came from a
        /// query lookup), so callers can verify the fuzzy match wasn't
        /// substantially different from what they asked for. Nil for
        /// direct-title lookups where no resolution step happened.
        let resolvedTitle: String?
    }

    private nonisolated func wikipediaSummary(title: String, lang: String, resolvedTitle: String?) async -> WikipediaSummary? {
        let path = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title
        guard let url = URL(string: "https://\(lang).wikipedia.org/api/rest_v1/page/summary/\(path)")
        else { return nil }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if lang == "zh" {
            request.setValue("zh-Hans", forHTTPHeaderField: "Accept-Language")
        }
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
            let description = json["description"] as? String
            // `content_urls.desktop.page` is the canonical web URL for the
            // article — what users get when they "Open in Browser".
            let page = ((json["content_urls"] as? [String: Any])?["desktop"] as? [String: Any])?["page"] as? String
            return WikipediaSummary(extract: extract, thumbnailURL: thumb,
                                    type: type, pageURL: page,
                                    description: description,
                                    resolvedTitle: resolvedTitle)
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
        // Last.fm returns a localised bio when `lang` is set on the
        // info methods. The English version is always available as a
        // baseline, so we silently fall through to it when the user's
        // locale has no translation.
        if method == "artist.getinfo" || method == "album.getinfo" {
            items.append(URLQueryItem(name: "lang", value: lastFMLanguageCode()))
        }
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
        // Prefer `bio.content` (full text) over `bio.summary` (intentionally
        // truncated to ~1–2 paragraphs by Last.fm). Both end with the same
        // "Read more on Last.fm" trailer that `stripLastFMTrailer` removes.
        let bioDict = artist["bio"] as? [String: Any]
        let bio = ((bioDict?["content"] as? String) ?? (bioDict?["summary"] as? String))
            .flatMap(stripLastFMTrailer)
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
        // Same `content` over `summary` preference as the artist path —
        // Last.fm's summary is a hard-truncated 1–2 paragraph snippet.
        let wiki = album["wiki"] as? [String: Any]
        let summary = ((wiki?["content"] as? String) ?? (wiki?["summary"] as? String))
            .flatMap(stripLastFMTrailer)
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
               let url = entry["#text"] as? String, !url.isEmpty,
               !Self.isLastFMPlaceholderImage(url) {
                return url
            }
        }
        return nil
    }

    /// Last.fm withdrew real artist images from its API around 2019
    /// and now serves a single well-known placeholder graphic (a
    /// generic vinyl-and-star shape) for every artist whose image
    /// hasn't been re-uploaded by the community. The placeholder URL
    /// always contains the same hash; suppressing it here lets the
    /// merge step fall through to the Wikipedia thumbnail (or render
    /// no image at all) instead of every Last.fm-only result showing
    /// the same stock graphic.
    nonisolated private static func isLastFMPlaceholderImage(_ url: String) -> Bool {
        // The 32-char hash is stable across all sizes and CDNs —
        // matching by substring beats hard-coding the host because
        // Last.fm has rotated CDNs (`last.fm`,
        // `lastfm.freetls.fastly.net`, etc.) and would do so again.
        return url.contains("2a96cbd8b46e442fc41c2b86b821562f")
    }
}
