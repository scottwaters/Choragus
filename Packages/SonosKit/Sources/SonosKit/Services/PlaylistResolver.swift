/// PlaylistResolver.swift — resolves a list of (title, artist) song
/// specifications into playable QueueItems via the Apple Music search
/// path, for saving as a Choragus playlist.
///
/// One implementation shared by the in-app Playlist Builder and the
/// maintainer CLI tool. Two behaviours are load-bearing:
///  - Pacing: `searchAppleMusic` uses the unthrottled iTunes path, and
///    Apple 403s a fast serial burst after a few dozen requests. Each
///    lookup is spaced, and an empty result gets one retry after a
///    cooldown.
///  - Artist match is mandatory: a title-only fallback returns cover
///    versions. A visible miss beats a wrong track.
import Foundation

public struct SongSpec: Codable, Sendable, Identifiable, Equatable {
    public var id: String { "\(title)|\(artist)" }
    public let title: String
    public let artist: String

    public init(title: String, artist: String) {
        self.title = title
        self.artist = artist
    }

    public var query: String { "\(title) \(artist)" }
    public var label: String { "\(title) — \(artist)" }

    /// Parses pasted text: one song per line, "Title - Artist" (hyphen,
    /// en or em dash). Lines with no separator are skipped.
    public static func parseList(_ text: String) -> [SongSpec] {
        text.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            for sep in [" — ", " – ", " - "] {
                if let range = trimmed.range(of: sep) {
                    let title = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                    let artist = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if !title.isEmpty && !artist.isEmpty { return SongSpec(title: title, artist: artist) }
                }
            }
            return nil
        }
    }
}

public struct PlaylistResolution: Sendable {
    public let resolved: [QueueItem]
    public let misses: [SongSpec]
}

/// Which catalog the resolver searches. Apple Music goes through the
/// iTunes Search API (no auth); SMAPI services through their
/// authenticated search endpoint; the Sonos-indexed local library and
/// DLNA media servers through caller-supplied searchers (they need the
/// live manager/topology, which this value type deliberately does not
/// hold).
public enum PlaylistResolveService {
    case appleMusic(sn: Int)
    case smapi(serviceID: Int, serviceURI: String, token: SMAPIToken, sn: Int)
    case localLibrary(search: @Sendable (String) async -> [BrowseItem])
    case mediaServer(search: @Sendable (String) async -> [BrowseItem])

    /// LAN searches need no anti-throttle pacing; the hosted APIs do.
    public var defaultPacing: Duration {
        switch self {
        case .appleMusic, .smapi: return .seconds(2)
        case .localLibrary, .mediaServer: return .milliseconds(150)
        }
    }

    /// Wait before retrying an empty result. Only the iTunes path answers
    /// a throttled burst with an empty body, so only it waits; `.zero`
    /// means an empty result is final.
    public var defaultRetryCooldown: Duration {
        switch self {
        case .appleMusic: return .seconds(60)
        case .smapi, .localLibrary, .mediaServer: return .zero
        }
    }
}

public enum PlaylistResolver {

    /// Resolves each spec in order. `progress` is called after every
    /// spec with (completed count, total, the spec, and the resolved
    /// track — nil on a miss) so callers can render per-row status and
    /// artwork as lookups land.
    public static func resolve(_ specs: [SongSpec],
                               via service: PlaylistResolveService,
                               pacing: Duration = .seconds(2),
                               retryCooldown: Duration? = nil,
                               progress: (@Sendable (Int, Int, SongSpec, QueueItem?) async -> Void)? = nil
    ) async -> PlaylistResolution {
        let cooldown = retryCooldown ?? service.defaultRetryCooldown
        var resolved: [QueueItem] = []
        var misses: [SongSpec] = []
        for (index, spec) in specs.enumerated() {
            if Task.isCancelled { break }
            var items = await search(spec, via: service)
            if items.isEmpty, cooldown > .zero {
                try? await Task.sleep(for: cooldown)
                if Task.isCancelled { break }
                items = await search(spec, via: service)
            }
            if let best = pickBest(items, for: spec) {
                let item = QueueItem(
                    id: resolved.count + 1,
                    title: best.title,
                    artist: best.artist ?? spec.artist,
                    album: best.album ?? "",
                    albumArtURI: best.albumArtURI,
                    duration: "",
                    uri: best.resourceURI,
                    metadata: best.resourceMetadata
                )
                resolved.append(item)
                await progress?(index + 1, specs.count, spec, item)
            } else {
                misses.append(spec)
                await progress?(index + 1, specs.count, spec, nil)
            }
            if index < specs.count - 1 {
                try? await Task.sleep(for: pacing)
            }
        }
        return PlaylistResolution(resolved: resolved, misses: misses)
    }

    private static func search(_ spec: SongSpec, via service: PlaylistResolveService) async -> [BrowseItem] {
        switch service {
        case .appleMusic(let sn):
            return await ServiceSearchProvider.shared.searchAppleMusic(
                query: spec.query, entity: .song, sn: sn, limit: 10)
        case .smapi(let serviceID, let serviceURI, let token, let sn):
            return await ServiceSearchProvider.shared.searchSMAPI(
                term: spec.query, searchID: "track", serviceID: serviceID,
                serviceURI: serviceURI, token: token, sn: sn, count: 10)
        case .localLibrary(let search), .mediaServer(let search):
            // Title-only query: these searchers match on title; the
            // artist requirement is enforced by pickBest, and titles
            // alone give the search engine the best recall.
            return await search(spec.title)
        }
    }

    /// Words that carry no artist identity on their own, in the
    /// normalised (lowercase, alphanumeric) form `pickBest` compares.
    static let artistStopWords: Set<String> = [
        "the", "and", "feat", "with", "los", "las", "les", "der", "die", "das"
    ]

    /// Title+artist match preferred, then any result by the right
    /// artist, then miss. Never falls back to a title-only match.
    static func pickBest(_ items: [BrowseItem], for spec: SongSpec) -> BrowseItem? {
        func norm(_ s: String) -> String {
            s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
                .components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        }
        func artistMatches(_ item: BrowseItem) -> Bool {
            let got = norm(item.artist ?? "")
            guard !got.isEmpty else { return false }
            let want = norm(spec.artist)
            if got.contains(want) || want.contains(got) { return true }
            // Multi-artist spec strings ("Santana Rob Thomas") match when
            // any single spec word of 3+ characters appears in the result.
            // Articles and joiners are not evidence ("The Knack" must not
            // match "The Beatles"), and a spec left with no usable word
            // does not match on that basis at all.
            let words = spec.artist.components(separatedBy: " ")
                .map(norm)
                .filter { $0.count >= 3 && !artistStopWords.contains($0) }
            return words.contains { got.contains($0) }
        }
        let wantTitle = norm(spec.title)
        let byArtist = items.filter(artistMatches)
        if let exact = byArtist.first(where: { norm($0.title).contains(wantTitle) || wantTitle.contains(norm($0.title)) }) {
            return exact
        }
        return byArtist.first
    }
}
