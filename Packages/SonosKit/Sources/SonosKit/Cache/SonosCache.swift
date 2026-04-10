/// SonosCache.swift — Persists speaker topology and art URL mappings to disk.
///
/// Serializes groups, devices, and browse sections to a JSON file in Application Support.
/// On next launch, the cache is restored to populate the UI immediately while live
/// SSDP discovery runs in the background. The cache has no TTL — staleness is handled
/// by SonosManager.withStaleHandling() when a SOAP call fails.
///
/// Also persists art URL mappings (art_url_cache.json) so favorites retain artwork
/// across restarts. Art URLs are stored under multiple keys (item ID, resource URI,
/// title) for flexible lookup.
import Foundation

public struct CachedTopology: Codable {
    public var groups: [CachedGroup]
    public var devices: [CachedDevice]
    public var browseSections: [CachedBrowseSection]
    public var timestamp: Date

    public var age: TimeInterval { Date().timeIntervalSince(timestamp) }
    public var ageDescription: String {
        let seconds = Int(age)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
    }
}

public struct CachedDevice: Codable {
    public var id: String
    public var ip: String
    public var port: Int
    public var roomName: String
    public var modelName: String
    public var modelNumber: String
    public var isCoordinator: Bool
    public var groupID: String?
}

public struct CachedGroup: Codable {
    public var id: String
    public var coordinatorID: String
    public var memberIDs: [String]
}

public struct CachedBrowseSection: Codable {
    public var id: String
    public var title: String
    public var objectID: String
    public var icon: String
}

public final class SonosCache: SonosCacheProtocol {
    private let fileURL: URL
    private let artCacheURL: URL

    public init() {
        let dir = AppPaths.appSupportDirectory
        self.fileURL = dir.appendingPathComponent("topology_cache.json")
        self.artCacheURL = dir.appendingPathComponent("art_url_cache.json")
    }

    public func save(groups: [SonosGroup], devices: [String: SonosDevice], browseSections: [BrowseSection]) {
        let cached = CachedTopology(
            groups: groups.map { g in
                CachedGroup(id: g.id, coordinatorID: g.coordinatorID, memberIDs: g.members.map(\.id))
            },
            devices: devices.values.map { d in
                CachedDevice(id: d.id, ip: d.ip, port: d.port, roomName: d.roomName,
                             modelName: d.modelName, modelNumber: d.modelNumber,
                             isCoordinator: d.isCoordinator, groupID: d.groupID)
            },
            browseSections: browseSections.map { s in
                CachedBrowseSection(id: s.id, title: s.title, objectID: s.objectID, icon: s.icon)
            },
            timestamp: Date()
        )

        do {
            let data = try JSONEncoder().encode(cached)
            try data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            sonosDebugLog("[CACHE] Topology save failed: \(error)")
        }
    }

    public func load() -> CachedTopology? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(CachedTopology.self, from: data)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Restore cached data into live model objects
    public func restoreDevices(from cached: CachedTopology) -> [String: SonosDevice] {
        var devices: [String: SonosDevice] = [:]
        for cd in cached.devices {
            devices[cd.id] = SonosDevice(
                id: cd.id, ip: cd.ip, port: cd.port,
                roomName: cd.roomName, modelName: cd.modelName,
                modelNumber: cd.modelNumber, isCoordinator: cd.isCoordinator,
                groupID: cd.groupID
            )
        }
        return devices
    }

    public func restoreGroups(from cached: CachedTopology, devices: [String: SonosDevice]) -> [SonosGroup] {
        cached.groups.compactMap { cg in
            let members = cg.memberIDs.compactMap { devices[$0] }
            guard !members.isEmpty else { return nil }
            return SonosGroup(id: cg.id, coordinatorID: cg.coordinatorID, members: members)
        }.sorted { $0.name < $1.name }
    }

    public func restoreBrowseSections(from cached: CachedTopology) -> [BrowseSection] {
        cached.browseSections.map { cs in
            BrowseSection(id: cs.id, title: cs.title, objectID: cs.objectID, icon: cs.icon)
        }
    }

    // MARK: - Art URL Cache

    public func saveArtURLs(_ urls: [String: String]) {
        do {
            let data = try JSONEncoder().encode(urls)
            try data.write(to: artCacheURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: artCacheURL.path)
        } catch {
            sonosDebugLog("[CACHE] Art URL save failed: \(error)")
        }
    }

    public func loadArtURLs() -> [String: String] {
        guard let data = try? Data(contentsOf: artCacheURL) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }
}
