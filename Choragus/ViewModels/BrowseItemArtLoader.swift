/// BrowseItemArtLoader.swift — Art resolution for browse items.
///
/// Resolves album art from cache, DIDL metadata, /getaa, BrowseMetadata,
/// container browsing, and iTunes search. Extracted from BrowseItemRow
/// to keep the view focused on layout.
import Foundation
import SonosKit

@MainActor
final class BrowseItemArtLoader {
    private let sonosManager: any (BrowsingServiceProtocol & ArtCacheProtocol & TransportStateProviding)

    /// Process-lifetime negative cache. An `objectID` lands here once
    /// every art-resolve strategy has failed for it; subsequent
    /// `loadArt` calls short-circuit instead of re-running the full
    /// SOAP cascade (BrowseMetadata, container-first-track, iTunes
    /// search). Lifted to a `static` because each row in the browse
    /// list constructs a fresh `BrowseItemArtLoader` per `.onAppear`,
    /// so an instance-level cache would never see a hit.
    private static var negativeArt: Set<String> = []

    init(sonosManager: any (BrowsingServiceProtocol & ArtCacheProtocol & TransportStateProviding)) {
        self.sonosManager = sonosManager
    }

    /// Checks the discovered art cache for this item
    func checkCache(item: BrowseItem) -> URL? {
        if let cached = sonosManager.discoveredArtURLs[item.objectID] {
            return URL(string: cached)
        }
        if let cached = sonosManager.lookupCachedArt(uri: item.resourceURI, title: item.title) {
            return URL(string: cached)
        }
        return nil
    }

    /// Main art resolution — tries multiple strategies in priority order
    func loadArt(for item: BrowseItem) async -> URL? {
        // 0. Check cache
        if let cachedArt = sonosManager.discoveredArtURLs[item.objectID] {
            return URL(string: cachedArt)
        }

        // 0b. Negative cache — every strategy already failed for this
        // item in this session. Skip the SOAP / iTunes cascade.
        if Self.negativeArt.contains(item.objectID) { return nil }

        // Local library items get special handling
        if isLocalLibraryItem(item) {
            if let url = await loadLocalLibraryArt(item: item) { return url }
            // Only remember the miss when iTunes actually answered. While a
            // large library is browsed the limiter goes into cooldown — a
            // skip then is deferred, not a real miss, so it retries once
            // budget returns rather than staying blank forever (issue #64).
            if await ITunesRateLimiter.shared.snapshot().isAvailable {
                Self.negativeArt.insert(item.objectID)
            }
            return nil
        }

        // 1. Try DIDL metadata
        if let meta = item.resourceMetadata, !meta.isEmpty,
           let device = sonosManager.groups.first?.coordinator {
            var probe = TrackMetadata()
            probe.enrichFromDIDL(meta, device: device)
            if let artURI = probe.albumArtURI, !artURI.isEmpty {
                sonosManager.cacheArtURL(artURI, forURI: item.resourceURI ?? "", title: item.title, itemID: item.objectID)
                return URL(string: artURI)
            }
        }

        // 2. Try BrowseMetadata
        if let url = await tryBrowseMetadata(item: item) { return url }

        // 3. Try /getaa for non-radio items
        if let url = tryGetaa(item: item) { return url }

        // 4. Try first track in container
        if let url = await tryContainerFirstTrack(item: item) { return url }

        // 5. Fallback: iTunes search (not for radio). Skip while the limiter
        // is cooling down so a big browse doesn't pile on (issue #64); a
        // deferred skip isn't negative-cached so it retries later.
        let isRadio = item.resourceURI.map { URIPrefix.isRadio($0) } ?? false
        if !isRadio {
            guard await ITunesRateLimiter.shared.snapshot().isAvailable else { return nil }
            let artist = item.artist.isEmpty ? "" : item.artist
            if let artURL = await sonosManager.albumArtSearch.searchArtwork(artist: artist, album: item.title) {
                return URL(string: artURL)
            }
        }

        Self.negativeArt.insert(item.objectID)
        return nil
    }

    // MARK: - Helpers

    func isLocalLibraryItem(_ item: BrowseItem) -> Bool {
        item.objectID.hasPrefix("S:") ||
        (item.objectID.hasPrefix("A:") && !item.objectID.hasPrefix("A:GENRE")) ||
        item.resourceURI?.hasPrefix(URIPrefix.fileCifs) == true ||
        item.resourceURI?.hasPrefix(URIPrefix.smb) == true
    }

    private func tryBrowseMetadata(item: BrowseItem) async -> URL? {
        do {
            if let metaItem = try await sonosManager.browseMetadata(objectID: item.objectID),
               let artURI = metaItem.albumArtURI {
                sonosManager.cacheArtURL(artURI, forURI: item.resourceURI ?? item.objectID, title: item.title, itemID: item.objectID)
                return URL(string: artURI)
            }
        } catch {
            // Failure is expected for many service-side containers
            // (Sonos returns 701/UPnPError for objects that don't
            // expose metadata). The negative cache in `loadArt`
            // prevents repeats; no log needed.
        }
        return nil
    }

    private func tryGetaa(item: BrowseItem) -> URL? {
        guard let uri = item.resourceURI, !uri.isEmpty,
              !uri.hasPrefix(URIPrefix.sonosApiStream),
              !uri.hasPrefix(URIPrefix.sonosApiRadio),
              !uri.hasPrefix(URIPrefix.rinconMP3Radio),
              !uri.hasPrefix(URIPrefix.rinconPlaylist),
              let device = sonosManager.groups.first?.coordinator else { return nil }
        let artURL = AlbumArtSearchService.getaaURL(speakerIP: device.ip, port: device.port, trackURI: uri)
        sonosManager.cacheArtURL(artURL, forURI: uri, title: item.title, itemID: item.objectID)
        return URL(string: artURL)
    }

    private func tryContainerFirstTrack(item: BrowseItem) async -> URL? {
        guard item.isContainer else { return nil }
        do {
            let (items, _) = try await sonosManager.browse(objectID: item.objectID, start: 0, count: 1)
            if let firstItem = items.first, let artURI = firstItem.albumArtURI {
                sonosManager.cacheArtURL(artURI, forURI: item.resourceURI ?? item.objectID, title: item.title, itemID: item.objectID)
                return URL(string: artURI)
            }
        } catch {
            // Same expected-failure path as `tryBrowseMetadata`.
        }
        return nil
    }

    // MARK: - Local Library Art

    private func loadLocalLibraryArt(item: BrowseItem) async -> URL? {
        guard let device = sonosManager.groups.first?.coordinator else { return nil }

        // Track with direct file URI — use /getaa
        if let uri = item.resourceURI, !uri.isEmpty,
           (uri.hasPrefix(URIPrefix.fileCifs) || uri.hasPrefix(URIPrefix.smb)) {
            let artURL = AlbumArtSearchService.getaaURL(speakerIP: device.ip, port: device.port, trackURI: uri)
            sonosManager.cacheArtURL(artURL, forURI: uri, title: item.title, itemID: item.objectID)
            return URL(string: artURL)
        }

        // Container: try iTunes based on container type
        if item.isContainer {
            if let url = await searchContainerArt(item: item) { return url }

            // Inherit from child
            if let artURL = await findArtInContainer(objectID: item.objectID, device: device, depth: 0) {
                sonosManager.cacheArtURL(artURL.absoluteString, forURI: item.objectID, title: item.title, itemID: "")
                return artURL
            }
        }

        return nil
    }

    private func searchContainerArt(item: BrowseItem) async -> URL? {
        let isArtist = item.objectID.hasPrefix("A:ALBUMARTIST/") || item.objectID.hasPrefix("A:ARTIST/")
        let isAlbum = item.objectID.hasPrefix("A:ALBUM/")

        let artist: String
        let album: String
        if isArtist {
            artist = item.title; album = ""
        } else if isAlbum {
            artist = item.artist.isEmpty ? "" : item.artist; album = item.title
        } else {
            artist = item.artist.isEmpty ? "" : item.artist; album = item.title
        }

        // Route through the disk-persisted resolver: a cache hit returns
        // instantly (even mid-cooldown), and a miss only hits iTunes when the
        // limiter has budget — so each album resolves once and survives
        // relaunches instead of re-flooding the limiter every browse (#64).
        if let artURL = await sonosManager.resolveLocalAlbumArt(artist: artist, album: album) {
            sonosManager.cacheArtURL(artURL, forURI: item.objectID, title: item.title, itemID: "")
            return URL(string: artURL)
        }

        // For generic containers, try guessing artist/album from path.
        if !isArtist && !isAlbum {
            if let (guessedArtist, guessedAlbum) = guessArtistAlbum(from: item.objectID, title: item.title) {
                if let artURL = await sonosManager.resolveLocalAlbumArt(artist: guessedArtist, album: guessedAlbum) {
                    sonosManager.cacheArtURL(artURL, forURI: item.objectID, title: item.title, itemID: "")
                    return URL(string: artURL)
                }
            }
        }

        return nil
    }

    /// Guesses artist and album from folder path structure
    func guessArtistAlbum(from objectID: String, title: String) -> (String, String)? {
        let decoded = objectID.removingPercentEncoding ?? objectID
        let parts = decoded.components(separatedBy: "/").filter { !$0.isEmpty }
        guard parts.count >= 2 else { return nil }

        let folder = parts[parts.count - 1]
        let parent = parts[parts.count - 2]

        let skipParents = ["music", "media", "audio", "share", "shares", "nas", "volume1"]
        if skipParents.contains(parent.lowercased()) { return nil }

        if parent.lowercased() != title.lowercased() {
            return (parent, folder)
        }

        if parts.count >= 3 {
            let grandparent = parts[parts.count - 3]
            if !skipParents.contains(grandparent.lowercased()) {
                return (grandparent, title)
            }
        }

        return nil
    }

    /// Recursively browses into a container to find a track with art
    func findArtInContainer(objectID: String, device: SonosDevice, depth: Int) async -> URL? {
        guard depth < 3 else { return nil }
        do {
            let (items, _) = try await sonosManager.browse(objectID: objectID, start: 0, count: 5)
            for browseItem in items {
                if let artURI = browseItem.albumArtURI {
                    return URL(string: artURI)
                }
                if !browseItem.isContainer, let uri = browseItem.resourceURI, !uri.isEmpty {
                    return URL(string: AlbumArtSearchService.getaaURL(speakerIP: device.ip, port: device.port, trackURI: uri))
                }
                if browseItem.isContainer {
                    if let art = await findArtInContainer(objectID: browseItem.objectID, device: device, depth: depth + 1) {
                        return art
                    }
                }
            }
        } catch {
            // Recursion bottoms out silently — negative cache handles
            // repeat suppression at the entry point.
        }
        return nil
    }
}
