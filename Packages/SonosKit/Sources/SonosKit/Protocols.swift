/// Protocols.swift — Service protocols for dependency injection and testability.
///
/// Services conform to these protocols, enabling mock implementations for testing
/// and swappable backends. SonosManager depends on protocols, not concrete types.
import Foundation
import AppKit

// MARK: - SOAP Client

public protocol SOAPClientProtocol {
    func send(
        to baseURL: URL,
        path: String,
        service: String,
        action: String,
        arguments: [(String, String)]
    ) async throws -> [String: String]
}

// MARK: - Image Cache

public protocol ImageCacheProtocol {
    var maxSizeMB: Int { get set }
    var maxAgeDays: Int { get set }
    var diskUsage: Int { get }
    var diskUsageString: String { get }
    var fileCount: Int { get }

    func image(for url: URL) -> NSImage?
    func store(_ image: NSImage, for url: URL)
    func clearDisk()
    func clearMemory()
}

// MARK: - Topology Cache

public protocol SonosCacheProtocol {
    func save(groups: [SonosGroup], devices: [String: SonosDevice], browseSections: [BrowseSection])
    func load() -> CachedTopology?
    func clear()
    func restoreDevices(from cached: CachedTopology) -> [String: SonosDevice]
    func restoreGroups(from cached: CachedTopology, devices: [String: SonosDevice]) -> [SonosGroup]
    func restoreBrowseSections(from cached: CachedTopology) -> [BrowseSection]
    func saveArtURLs(_ urls: [String: String])
    func loadArtURLs() -> [String: String]
}

// MARK: - Album Art Search

public protocol AlbumArtSearchProtocol {
    func searchArtwork(artist: String, album: String) async -> String?
    func searchRadioTrackArt(artist: String, title: String) async -> String?
}
