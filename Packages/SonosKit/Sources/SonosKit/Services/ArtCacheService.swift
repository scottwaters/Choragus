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
    public func cacheArtURL(_ artURL: String, forURI uri: String, title: String = "", itemID: String = "") {
        if !uri.isEmpty {
            discoveredArtURLs[uri] = artURL
        }
        if !title.isEmpty {
            discoveredArtURLs["title:\(title.lowercased())"] = artURL
            let normalized = Self.normalizeForCache(title)
            if !normalized.isEmpty {
                discoveredArtURLs["norm:\(normalized)"] = artURL
            }
        }
        if !itemID.isEmpty {
            discoveredArtURLs[itemID] = artURL
        }
        scheduleSave()
    }

    /// Looks up cached art by URI, exact-case-insensitive title, or normalized title.
    public func lookupCachedArt(uri: String?, title: String) -> String? {
        if let uri = uri, let art = discoveredArtURLs[uri] { return art }
        if let art = discoveredArtURLs["title:\(title.lowercased())"] { return art }
        let normalized = Self.normalizeForCache(title)
        if !normalized.isEmpty, let art = discoveredArtURLs["norm:\(normalized)"] { return art }
        return nil
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
