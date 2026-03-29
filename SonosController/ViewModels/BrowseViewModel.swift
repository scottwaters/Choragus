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
                items = await ServiceSearchProvider.shared.searchAppleMusic(query: query, sn: serviceSearchSN)
                totalItems = items.count
                loadedCount = items.count
            } else if isSearch {
                let query = String(objectID.dropFirst("SEARCH:".count))
                async let artistResults = sonosManager.search(query: query, in: "A:ALBUMARTIST", start: 0, count: 20)
                async let albumResults = sonosManager.search(query: query, in: "A:ALBUM", start: 0, count: 20)
                async let trackResults = sonosManager.search(query: query, in: "A:TRACKS", start: 0, count: 30)
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
        // Convert SMAPIMediaItem to BrowseItem for display
        let sid = smapiServiceID ?? 0
        let sn = smapiSerialNumber
        items = result.items.map { smapi in
            // Build Sonos playback URI from SMAPI item ID + service ID
            let playURI: String?
            if !smapi.canBrowse && !smapi.id.isEmpty {
                if smapi.itemType == "stream" || smapi.itemType == "program" {
                    playURI = "x-sonosapi-stream:\(smapi.id)?sid=\(sid)&flags=8224&sn=\(sn)"
                } else if smapi.itemType == "track" {
                    playURI = "x-sonos-http:\(smapi.id)?sid=\(sid)&flags=8224&sn=\(sn)"
                } else {
                    playURI = smapi.uri.isEmpty ? "x-sonosapi-stream:\(smapi.id)?sid=\(sid)&flags=8224&sn=\(sn)" : smapi.uri
                }
            } else {
                playURI = smapi.uri.isEmpty ? nil : smapi.uri
            }

            // Build DIDL metadata for playback
            let didlMeta: String?
            if let uri = playURI, !smapi.canBrowse {
                let escapedID = xmlEscape(smapi.id)
                didlMeta = """
                <DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"><item id="\(escapedID)" parentID="-1" restricted="true"><dc:title>\(xmlEscape(smapi.title))</dc:title><upnp:class>object.item.audioItem.audioBroadcast</upnp:class><desc id="cdudn" nameSpace="urn:schemas-rinconnetworks-com:metadata-1-0/">SA_RINCON\(sid * 256 + 7)_X_#Svc\(sid * 256 + 7)-0-Token</desc></item></DIDL-Lite>
                """
            } else {
                didlMeta = nil
            }

            return BrowseItem(
                id: smapi.id,
                title: smapi.title,
                artist: smapi.artist,
                album: smapi.album,
                albumArtURI: smapi.albumArtURI.isEmpty ? nil : smapi.albumArtURI,
                itemClass: smapi.canBrowse ? .container : .musicTrack,
                resourceURI: playURI,
                resourceMetadata: didlMeta
            )
        }
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
            let (result, _) = try await sonosManager.browse(objectID: "SQ:", start: 0, count: 100)
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

    private func xmlEscape(_ str: String) -> String {
        str.replacingOccurrences(of: "&", with: "&amp;")
           .replacingOccurrences(of: "<", with: "&lt;")
           .replacingOccurrences(of: ">", with: "&gt;")
           .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
