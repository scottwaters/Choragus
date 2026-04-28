/// BrowseViewModel.swift — Business logic for the Browse list view.
///
/// Handles content loading, pagination, filtering, playlist management,
/// playback, and service detection. The view binds to published state.
import SwiftUI
import SonosKit

@MainActor
@Observable
final class BrowseViewModel {
    let sonosManager: any BrowsingServices
    let objectID: String
    let title: String
    let group: SonosGroup?

    // MARK: - State

    var items: [BrowseItem] = []
    var totalItems = 0
    var isLoading = true
    var loadedCount = 0
    var errorMessage: String?
    var selectedFilter: String?
    var playbackError: String?
    var playlists: [BrowseItem] = []

    // Playlist management
    var showRenameAlert = false
    var renameItem: BrowseItem?
    var renameText = ""
    var showDeleteConfirm = false
    var deleteItem: BrowseItem?

    private let pageSize = 100

    // SMAPI service info (nil for standard UPnP browsing)
    var smapiServiceID: Int?
    var smapiServiceURI: String?
    var smapiAuthType: String?
    var smapiClient: SMAPIClient?
    var smapiToken: SMAPIToken?
    var smapiDeviceID: String = ""
    var smapiSerialNumber: Int = 0

    // Service Search (direct API search — Apple Music via iTunes API)
    var serviceSearchSN: Int = 0

    var isSMAPI: Bool { smapiServiceURI != nil }
    var isSearch: Bool { objectID.hasPrefix("SEARCH:") }
    var isServiceSearch: Bool { objectID.hasPrefix("SERVICESEARCH:") }
    var serviceSearchEntity: ServiceSearchEntity = .all

    /// The SMAPI item ID to browse (extracted from "SMAPI:sid:itemID" format or just the raw objectID)
    var smapiItemID: String {
        if objectID.hasPrefix("SMAPI:") {
            let parts = objectID.components(separatedBy: ":")
            return parts.count >= 3 ? parts.dropFirst(2).joined(separator: ":") : "root"
        }
        return objectID
    }

    init(sonosManager: any BrowsingServices, objectID: String, title: String, group: SonosGroup?) {
        self.sonosManager = sonosManager
        self.objectID = objectID
        self.title = title
        self.group = group
    }

    // MARK: - Filters

    var showsFilters: Bool {
        objectID == "FV:2" || objectID.hasPrefix("SQ:") || objectID == "SQ:"
    }

    var availableFilters: [String] {
        var seen = Set<String>()
        var filters: [String] = []
        for item in items {
            if let label = serviceLabel(for: item), !seen.contains(label) {
                seen.insert(label)
                filters.append(label)
            }
        }
        return filters.sorted()
    }

    var filteredItems: [BrowseItem] {
        guard let filter = selectedFilter else { return items }
        return items.filter { serviceLabel(for: $0) == filter }
    }

    func serviceLabel(for item: BrowseItem) -> String? {
        sonosManager.serviceLabel(for: item)
    }

    // MARK: - Data Loading

    func loadItems() async {
        isLoading = true
        errorMessage = nil
        do {
            if isSMAPI {
                try await loadSMAPIItems()
            } else if isServiceSearch {
                let query = String(objectID.dropFirst("SERVICESEARCH:".count))
                items = await ServiceSearchProvider.shared.searchAppleMusic(query: query, entity: serviceSearchEntity, sn: serviceSearchSN)
                totalItems = items.count
                loadedCount = items.count
            } else if isSearch {
                let query = String(objectID.dropFirst("SEARCH:".count))
                async let artistResults = sonosManager.search(query: query, in: BrowseID.albumArtist, start: 0, count: PageSize.searchArtist)
                async let albumResults = sonosManager.search(query: query, in: BrowseID.album, start: 0, count: PageSize.searchAlbum)
                async let trackResults = sonosManager.search(query: query, in: BrowseID.tracks, start: 0, count: PageSize.searchTrack)
                let (artists, albums, tracks) = try await (artistResults, albumResults, trackResults)
                items = artists.items + albums.items + tracks.items
                totalItems = items.count
                loadedCount = items.count
            } else {
                let (result, total) = try await sonosManager.browse(objectID: objectID, start: 0, count: pageSize)
                items = result
                totalItems = total
                loadedCount = result.count
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func loadSMAPIItems() async throws {
        guard let uri = smapiServiceURI, let client = smapiClient else {
            errorMessage = "Service not configured"
            return
        }
        let browseID = smapiItemID
        let result: (items: [SMAPIMediaItem], total: Int)
        if let token = smapiToken {
            result = try await client.getMetadata(serviceURI: uri, token: token, id: browseID, index: 0, count: pageSize)
        } else {
            result = try await client.getMetadataAnonymous(serviceURI: uri, deviceID: smapiDeviceID, id: browseID, index: 0, count: pageSize)
        }
        let sid = smapiServiceID ?? 0
        let sn = smapiSerialNumber
        items = result.items.map { ServiceSearchProvider.shared.smapiItemToBrowseItem($0, serviceID: sid, sn: sn) }
        totalItems = result.total
        loadedCount = items.count
    }

    func loadMore() async {
        guard !isSearch else { return }
        do {
            let (result, _) = try await sonosManager.browse(objectID: objectID, start: loadedCount, count: pageSize)
            items.append(contentsOf: result)
            loadedCount += result.count
        } catch {
            ErrorHandler.shared.handle(error, context: "BROWSE")
        }
    }

    func loadPlaylists() async {
        do {
            let (result, _) = try await sonosManager.browse(objectID: BrowseID.playlists, start: 0, count: PageSize.browse)
            playlists = result.filter { $0.isContainer }
        } catch {
            ErrorHandler.shared.handle(error, context: "BROWSE")
        }
    }

    // MARK: - Playback

    func play(_ item: BrowseItem) async {
        guard let group = group else { return }
        playbackError = nil
        do {
            try await sonosManager.playBrowseItem(item, in: group)
        } catch let error as SOAPError {
            switch error {
            case .soapFault(let code, _):
                if code == "402" || code == "714" || code == "800" {
                    let serviceName = item.resourceURI.flatMap { sonosManager.detectServiceName(fromURI: $0) } ?? "the streaming service"
                    playbackError = "\(L10n.couldNotPlay) \"\(item.title)\" — \(serviceName) \(L10n.mayRequireSignIn)"
                } else {
                    let appErr = AppError.from(error)
                    playbackError = "\(L10n.couldNotPlay) \"\(item.title)\": \(appErr.errorDescription ?? "")"
                }
            default:
                let appErr = AppError.from(error)
                playbackError = "\(L10n.couldNotPlay) \"\(item.title)\": \(appErr.errorDescription ?? "")"
            }
        } catch {
            let appErr = AppError.unknown(error)
            playbackError = "\(L10n.couldNotPlay) \"\(item.title)\": \(appErr.errorDescription ?? "")"
        }
    }

    func addToQueue(_ item: BrowseItem, playNext: Bool = false) async {
        guard let group = group else {
            sonosDebugLog("[QUEUE] addToQueue: no group selected")
            return
        }
        do {
            try await sonosManager.addBrowseItemToQueue(item, in: group, playNext: playNext, atPosition: 0)
        } catch {
            ErrorHandler.shared.handle(error, context: "QUEUE", userFacing: true)
        }
    }

    // MARK: - Playlist Management

    func renamePlaylist() async {
        guard let item = renameItem else { return }
        let newName = renameText.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty, newName != item.title else { return }
        await ErrorHandler.shared.handleAsync("PLAYLIST", userFacing: true) {
            try await sonosManager.renamePlaylist(playlistID: item.objectID, oldTitle: item.title, newTitle: newName)
        }
        await loadItems()
    }

    func deletePlaylist() async {
        guard let item = deleteItem else { return }
        await ErrorHandler.shared.handleAsync("PLAYLIST", userFacing: true) {
            try await sonosManager.deletePlaylist(playlistID: item.objectID)
        }
        await loadItems()
    }

    func addToPlaylist(playlistID: String, item: BrowseItem) async {
        await ErrorHandler.shared.handleAsync("PLAYLIST", userFacing: true) {
            try await sonosManager.addToPlaylist(playlistID: playlistID, item: item)
        }
    }

}
