/// PlaylistServiceScanner.swift — Background scanner that detects which services
/// are used in Sonos playlists. Caches results to disk.
import Foundation

@MainActor
public final class PlaylistServiceScanner: ObservableObject {
    /// Maps playlist objectID (e.g. "SQ:3") to set of detected service names
    @Published public var playlistServices: [String: Set<String>] = [:]

    /// Playlists currently being scanned
    @Published public var scanning: Set<String> = []

    private let fileURL: URL

    public init() {
        self.fileURL = AppPaths.appSupportDirectory.appendingPathComponent("playlist_services_cache.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) else { return }
        playlistServices = decoded.mapValues { Set($0) }
    }

    private func save() {
        // Save immediately — playlist scans are infrequent and data is small
        do {
            let encodable = playlistServices.mapValues { Array($0) }
            let data = try JSONEncoder().encode(encodable)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            sonosDebugLog("[PLAYLIST-SCAN] Save failed: \(error)")
        }
    }

    /// Scans a playlist's tracks to detect services. Uses cache if available.
    public func scanPlaylist(objectID: String, using manager: SonosManager, force: Bool = false) async {
        // Use cache unless forced
        if !force && playlistServices[objectID] != nil { return }
        guard !scanning.contains(objectID) else { return }

        scanning.insert(objectID)

        // Do the network work on a background task to avoid blocking UI
        let services = await Task.detached(priority: .utility) { [weak manager] () -> Set<String> in
            guard let manager else { return [] }
            var services = Set<String>()
            var start = 0
            let batchSize = PageSize.browse

            repeat {
                guard let result = try? await manager.browse(objectID: objectID, start: start, count: batchSize) else { break }

                for item in result.items {
                    if let service = await self.detectService(from: item, using: manager) {
                        services.insert(service)
                    }
                }

                start += result.items.count
                if result.items.count < batchSize || start >= result.total { break }

                // Yield to let other tasks run
                await Task.yield()
            } while true

            return services
        }.value

        // Update published state on main actor
        playlistServices[objectID] = services.isEmpty ? [ServiceName.unknown] : services
        scanning.remove(objectID)
        save()
    }

    /// Background scan of all playlists in a list — only scans uncached playlists
    public func backgroundScan(playlists: [BrowseItem], using manager: SonosManager) {
        let uncached = playlists.filter {
            $0.objectID.hasPrefix("SQ:") && playlistServices[$0.objectID] == nil
        }
        guard !uncached.isEmpty else { return }

        Task.detached(priority: .utility) { [weak self] in
            for playlist in uncached {
                guard let self else { return }
                await self.scanPlaylist(objectID: playlist.objectID, using: manager)
                try? await Task.sleep(nanoseconds: Timing.reloadDebounce)
            }
        }
    }

    /// Detects the service from a track item's URI, using SonosManager's service detection
    private func detectService(from item: BrowseItem, using manager: SonosManager) -> String? {
        // Use SonosManager's existing service detection first (most reliable)
        if let uri = item.resourceURI, let name = manager.detectServiceName(fromURI: uri) {
            return name
        }

        // Check service descriptor
        if let desc = item.serviceDescriptor, let name = manager.musicServiceName(fromDescriptor: desc) {
            return name
        }

        // Check resourceMetadata for service patterns
        if let meta = item.resourceMetadata, let name = manager.musicServiceName(fromDescriptor: meta) {
            return name
        }

        // Direct URI pattern matching as fallback
        if let uri = item.resourceURI {
            if URIPrefix.isLocal(uri) { return ServiceName.musicLibrary }
            if URIPrefix.isRadio(uri) { return ServiceName.radio }

            // Detect service by SID in URI (e.g. sid=202) — may be disconnected
            if let sidRange = uri.range(of: "sid=") {
                let afterSid = uri[sidRange.upperBound...]
                let endIdx = afterSid.rangeOfCharacter(from: CharacterSet(charactersIn: "&"))?.lowerBound ?? afterSid.endIndex
                let sidStr = String(afterSid[afterSid.startIndex..<endIdx])
                if let sid = Int(sidStr), let name = manager.musicServiceName(for: sid) {
                    // Check if sn=0 (no account connected)
                    if uri.contains("sn=0") {
                        return "\(name) (\(ServiceName.unavailable))"
                    }
                    return name
                }
            }

            // x-sonos-http with unknown SID
            if uri.contains(URIPrefix.sonosHTTP) {
                if uri.contains("sn=0") { return ServiceName.unavailable }
                return ServiceName.streaming
            }
        }

        // Track exists but has no playable URI — likely from a disconnected service
        if item.resourceURI == nil || item.resourceURI?.isEmpty == true {
            return ServiceName.unavailable
        }

        return nil
    }
}
