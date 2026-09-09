/// ArtCacheService.swift — Persistent art URL cache.
///
/// Owns the disk-backed `discoveredArtURLs` dictionary mapping various
/// track identifiers (URI, lowercase title, normalized title, itemID) to
/// resolved art URLs. Used by browse-list rendering and as a fast-path
/// during track playback so iTunes lookups don't repeat across sessions.
///
/// Extracted from `SonosManager` so the cache state has a single owner
/// and SonosManager itself stays focused on transport/topology orchestration.
import Foundation
import Combine

@MainActor
public final class ArtCacheService: ObservableObject, ArtCacheProtocol {
    /// Cached art URLs discovered during playback / browse / search.
    /// Observers (e.g. browse list rows) re-render when this changes.
    @Published public private(set) var discoveredArtURLs: [String: String] = [:]

    private let cache: SonosCache
    private var saveTask: Task<Void, Never>?

    public init(cache: SonosCache) {
        self.cache = cache
    }

    /// Restores the persisted cache from disk. Call once during startup.
    public func loadFromDisk() {
        let saved = cache.loadArtURLs()
        if !saved.isEmpty {
            discoveredArtURLs = saved
        }
    }

    /// Stores an art URL with multiple cache keys for flexible lookup.
    /// Persistence is debounced via `Timing.rescanDebounce` so a burst of
    /// browse-list updates collapses into a single disk write.
    ///
    /// Radio URIs are NOT stored as a key — those URIs identify the
    /// *station*, not the song, and re-using the same URI across the
    /// dozens of different tracks the station plays would cross-
    /// contaminate every lookup (the menubar would show the previous
    /// song's cover on every transition). Only title-based keys are
    /// safe for radio.
    public func cacheArtURL(_ artURL: String, forURI uri: String, title: String = "", itemID: String = "") {
        // Equality gates: @Published fires on every assignment. Without
        // these guards, repeated cacheArtURL calls for the same already-
        // cached art (browse-row reappearance, art-resolver retries,
        // metadata prewarm) burst-fire `objectWillChange` and forward
        // through `SonosManager.artCacheSubscription` into every
        // `@EnvironmentObject sonosManager` observer.
        var didChange = false
        if !uri.isEmpty && !URIPrefix.isRadio(uri),
           discoveredArtURLs[uri] != artURL {
            discoveredArtURLs[uri] = artURL
            didChange = true
        }
        if !title.isEmpty {
            let titleKey = "title:\(title.lowercased())"
            if discoveredArtURLs[titleKey] != artURL {
                discoveredArtURLs[titleKey] = artURL
                didChange = true
            }
            let normalized = Self.normalizeForCache(title)
            if !normalized.isEmpty {
                let normKey = "norm:\(normalized)"
                if discoveredArtURLs[normKey] != artURL {
                    discoveredArtURLs[normKey] = artURL
                    didChange = true
                }
            }
        }
        if !itemID.isEmpty, discoveredArtURLs[itemID] != artURL {
            discoveredArtURLs[itemID] = artURL
            didChange = true
        }
        if didChange { scheduleSave() }
    }

    /// Looks up cached art by URI, exact-case-insensitive title, or normalized title.
    /// For radio URIs the URI lookup is skipped — see `cacheArtURL` for
    /// why. Stored radio-URI entries are also bypassed at read time, so a
    /// stale one cannot surface the previous song's art.
    ///
    /// Title-key cache hits are validated against the requesting track's
    /// URI source-family. Title is a coarse key — different sources
    /// (Apple Music, Spotify, local SMB library) can ship the same
    /// nominal track ("Bohemian Rhapsody"), and the title-keyed cache
    /// entry written by the first play of a name will otherwise be
    /// returned for every subsequent same-title play regardless of
    /// source. The cached value is typically a Sonos `/getaa?u=<src>`
    /// proxy URL whose `u=` parameter binds it to a specific source —
    /// returning a local-file proxy URL for an Apple Music track makes
    /// the speaker serve a 404 (wrong source URL on possibly the wrong
    /// speaker), which renders as blank art in the consumer.
    public func lookupCachedArt(uri: String?, title: String) -> String? {
        if let uri = uri, !URIPrefix.isRadio(uri), let art = discoveredArtURLs[uri] { return art }
        let titleKey = "title:\(title.lowercased())"
        if let art = discoveredArtURLs[titleKey],
           !Self.isStaleCrossSource(cachedArt: art, currentURI: uri) {
            return art
        }
        let normalized = Self.normalizeForCache(title)
        if !normalized.isEmpty,
           let art = discoveredArtURLs["norm:\(normalized)"],
           !Self.isStaleCrossSource(cachedArt: art, currentURI: uri) {
            return art
        }
        return nil
    }

    /// True when the cached art URL is a `/getaa?u=<src>` proxy whose
    /// embedded source URI belongs to a different source family than
    /// the requesting track's URI. Returns false (i.e. trust the cache)
    /// when either side can't be classified, so an unprovable negative
    /// never breaks a working lookup.
    private static func isStaleCrossSource(cachedArt: String, currentURI: String?) -> Bool {
        guard let currentURI, !currentURI.isEmpty else { return false }
        guard let comps = URLComponents(string: cachedArt) else { return false }
        // /getaa?u=<encoded source URI>
        guard let cachedSourceURI = comps.queryItems?.first(where: { $0.name == "u" })?.value,
              !cachedSourceURI.isEmpty
        else { return false }
        let cachedFamily = sourceFamily(of: cachedSourceURI)
        let currentFamily = sourceFamily(of: currentURI)
        guard cachedFamily != .unknown, currentFamily != .unknown else { return false }
        return cachedFamily != currentFamily
    }

    /// Coarse source-family classification of a Sonos resource URI.
    /// Used by the cross-source cache validator above. Distinct
    /// services map to distinct families so a title-keyed cache entry
    /// written for one source is rejected when the cache is queried
    /// for another.
    private enum SourceFamily {
        case localFile, appleMusic, amazon, spotify, http, radio, queue, container, unknown
    }

    private static func sourceFamily(of uri: String) -> SourceFamily {
        if uri.hasPrefix(URIPrefix.fileCifs) || uri.hasPrefix(URIPrefix.smb) { return .localFile }
        // Amazon shares the hls-static scheme with Apple Music; its
        // `/getaa?u=` proxy URLs are bound to the Amazon source, so a
        // title-keyed entry must not cross over.
        if URIPrefix.isAmazonTrack(uri) { return .amazon }
        if uri.hasPrefix(URIPrefix.sonosApiHLSStatic) || uri.hasPrefix(URIPrefix.sonosApiHLS) { return .appleMusic }
        if uri.hasPrefix("x-sonos-spotify:") { return .spotify }
        if uri.hasPrefix(URIPrefix.sonosApiStream) || uri.hasPrefix(URIPrefix.sonosApiRadio) || uri.hasPrefix(URIPrefix.rinconMP3Radio) { return .radio }
        if uri.hasPrefix("x-sonos-http:") { return .http }
        if uri.hasPrefix(URIPrefix.rinconQueue) { return .queue }
        if uri.hasPrefix(URIPrefix.rinconContainer) { return .container }
        return .unknown
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Timing.rescanDebounce)
            guard !Task.isCancelled, let self else { return }
            self.cache.saveArtURLs(self.discoveredArtURLs)
        }
    }

    /// Normalizes title text for cache lookup: lowercases, strips
    /// dashes / "radio" / "station" / non-alphanumeric noise. Used so a
    /// "TripleM Sydney" cache entry matches "TripleM Sydney Radio Station".
    private static func normalizeForCache(_ title: String) -> String {
        title.lowercased()
            .replacingOccurrences(of: " - ", with: " ")
            .replacingOccurrences(of: "radio", with: "")
            .replacingOccurrences(of: "station", with: "")
            .components(separatedBy: .alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
