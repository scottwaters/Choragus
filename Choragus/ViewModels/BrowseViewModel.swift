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
    /// True while a `loadMore` round-trip is in flight. Prevents the
    /// infinite-scroll trigger on the bottom sentinel from firing
    /// repeatedly while the previous page is still arriving — without
    /// this guard, a quick scroll past the threshold sends N concurrent
    /// requests and produces duplicate rows when they all return.
    var isLoadingMore = false
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

    /// Mid-expansion prompt state. Set when the recursive walk has
    /// collected `largeAddThreshold` leaf tracks and is paused waiting
    /// for the user to OK or Cancel. Live `expansionCount` continues
    /// to update both before the prompt and (if user OKs) after, so
    /// the queue panel shows progress throughout.
    var expansionPromptVisible: Bool = false
    var expansionCount: Int = 0
    /// True while the recursive walk is still running. The sheet
    /// disables "Add All" until this flips to false so the user
    /// can't confirm before the count has settled.
    var expansionInProgress: Bool = false
    /// Set once the recursion crosses the threshold and the sheet
    /// has been requested — guards against the sheet flickering
    /// open/closed if the count fluctuates around the threshold.
    private var expansionPromptShown: Bool = false
    private var expansionContinuation: CheckedContinuation<Bool, Never>?
    private var expansionCancelled: Bool = false
    private var expansionUserConfirmed: Bool = false

    /// Trigger threshold. Crossing this during recursion pauses the
    /// walk and prompts the user. Sized so a typical full-album add
    /// (12-25 tracks) and even moderate artist adds (a few hundred)
    /// go straight through, while right-clicking a top-level container
    /// pops the warning before the user has spent time waiting on a
    /// 20k-track expansion they did not want.
    private static let largeAddThreshold = 1_000

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
            errorMessage = L10n.serviceNotConfigured
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

    /// Fetches the next page and appends to `items`. Idempotent on
    /// concurrent calls (guarded by `isLoadingMore`) so the
    /// infinite-scroll bottom sentinel can fire freely.
    ///
    /// Dispatches by source type:
    /// - **SMAPI** (Spotify, Plex cloud, Audible, …) → calls the SMAPI
    ///   client with `index = loadedCount`. The previous version
    ///   incorrectly routed SMAPI pagination through the speaker's
    ///   `browse(...)` SOAP, which doesn't know SMAPI item IDs and
    ///   silently returned empty results — meaning Load More was a
    ///   no-op for every SMAPI service.
    /// - **Local-library / radio search** (`isSearch`,
    ///   `isServiceSearch`) — full result set was returned in the
    ///   initial load, no pagination concept; bails early.
    /// - **Default UPnP browse** → speaker `browse(start: loadedCount)`.
    func loadMore() async {
        guard !isLoadingMore else { return }
        guard loadedCount < totalItems else { return }
        guard !isSearch, !isServiceSearch else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            if isSMAPI {
                guard let uri = smapiServiceURI, let client = smapiClient else { return }
                let result: (items: [SMAPIMediaItem], total: Int)
                if let token = smapiToken {
                    result = try await client.getMetadata(serviceURI: uri, token: token,
                                                          id: smapiItemID,
                                                          index: loadedCount, count: pageSize)
                } else {
                    result = try await client.getMetadataAnonymous(serviceURI: uri,
                                                                    deviceID: smapiDeviceID,
                                                                    id: smapiItemID,
                                                                    index: loadedCount,
                                                                    count: pageSize)
                }
                let sid = smapiServiceID ?? 0
                let sn = smapiSerialNumber
                let mapped = result.items.map {
                    ServiceSearchProvider.shared.smapiItemToBrowseItem($0, serviceID: sid, sn: sn)
                }
                items.append(contentsOf: mapped)
                loadedCount = items.count
                if result.total > totalItems { totalItems = result.total }
            } else {
                let (result, total) = try await sonosManager.browse(objectID: objectID, start: loadedCount, count: pageSize)
                items.append(contentsOf: result)
                loadedCount += result.count
                if total > totalItems { totalItems = total }
            }
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

    /// View calls this when the user taps "Add All". If the recursion
    /// is still running, this just sets the confirmation flag and
    /// dismisses the alert; the queue add will start when the walk
    /// finishes naturally. If the walk has already completed and is
    /// awaiting a decision via `awaitExpansionDecision`, the
    /// continuation resumes here.
    func confirmExpansion() {
        expansionUserConfirmed = true
        expansionPromptVisible = false
        expansionContinuation?.resume(returning: true)
        expansionContinuation = nil
    }

    /// View calls this when the user taps "Cancel". Sets the flag
    /// `collectLeaves` checks every iteration, so the recursion bails
    /// on its next loop pass. Any continuation already awaiting a
    /// decision is resolved with `false`.
    func cancelExpansion() {
        sonosDiagLog(.info, tag: "QUEUE",
                     "Large-add cancelled by user at \(expansionCount) tracks")
        expansionCancelled = true
        expansionPromptVisible = false
        expansionContinuation?.resume(returning: false)
        expansionContinuation = nil
    }

    /// Suspends the calling task until the user dismisses the alert.
    /// Only invoked AFTER the recursion has finished — the alert is
    /// non-blocking during recursion, but if the user hasn't decided
    /// by the time the walk ends we wait here for them.
    private func awaitExpansionDecision() async -> Bool {
        // Already decided? Don't bother with a continuation.
        if expansionUserConfirmed { return true }
        if expansionCancelled { return false }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            expansionContinuation = cont
        }
    }

    func addToQueue(_ item: BrowseItem, playNext: Bool = false) async {
        guard let group = group else {
            sonosDiagLog(.warning, tag: "QUEUE",
                         "addToQueue called with no group selected",
                         context: ["title": item.title, "objectID": item.objectID])
            return
        }
        // Capture entry-point context — every right-click should land
        // a row regardless of which branch fires below. Silent no-ops
        // were the source of issue #8's "no logs visible" follow-up.
        sonosDiagLog(.info, tag: "QUEUE",
                     "addToQueue: \(item.title) playNext=\(playNext)",
                     context: [
                        "objectID": item.objectID,
                        "isContainer": String(item.isContainer),
                        "isPlayable": String(item.isPlayable),
                        "resourceURI": item.resourceURI ?? "<nil>",
                        "itemClass": "\(item.itemClass)"
                     ])

        // Engage the queue spinner immediately at right-click. Without
        // this, the inner `addBrowseItemsToQueue` is the first to set
        // `isAddingToQueue` — but its expansion-then-add sequence
        // means the user sees nothing happening for the seconds it
        // takes to walk the container. SonosManager owns the published
        // flag; QueueView observes it.
        if let manager = sonosManager as? SonosManager {
            manager.isAddingToQueue = true
        }
        defer {
            if let manager = sonosManager as? SonosManager {
                manager.isAddingToQueue = false
            }
        }

        do {
            // Client-side expansion is now the default for any
            // container that lacks a SMAPI cpcontainer URI. Issue #8
            // root cause: passing the container URI to Sonos via
            // `addURIToQueue` works for append but mis-displays in the
            // local queue UI (only the container row is reflected
            // in the post-add reload — the speaker stored individual
            // tracks but the queue browse round-trip races the commit
            // and our view shows the stale state). Expanding to leaf
            // tracks here mirrors what the toolbar "Add All to Queue"
            // button does, which the user has confirmed works.
            //
            // SMAPI cpcontainer URIs (Spotify/Apple Music/Plex
            // album/playlist containers) keep the single-item
            // server-expansion path — those services do expand
            // cleanly and the queue view shows them correctly.
            let resourceURI = item.resourceURI ?? ""
            let isCpContainer = resourceURI.hasPrefix(URIPrefix.rinconContainer)
            let needsClientExpansion = item.isContainer && !isCpContainer
            if needsClientExpansion {
                // Reset all per-walk state.
                expansionCount = 0
                expansionCancelled = false
                expansionUserConfirmed = false
                expansionPromptShown = false
                expansionPromptVisible = false
                expansionInProgress = true
                if let manager = sonosManager as? SonosManager {
                    manager.addingToQueueProgress = 0
                }

                // Run the walk. If it crosses the 1 000-leaf
                // threshold, the sheet appears in parallel — the walk
                // does NOT pause for it, so the count keeps climbing
                // while the user reads it. Cancel sets the flag the
                // recursion checks every iteration.
                let expanded = await expandLocalLibraryContainer(item)
                expansionInProgress = false
                if let manager = sonosManager as? SonosManager {
                    manager.addingToQueueProgress = 0
                }

                if expansionCancelled {
                    sonosDiagLog(.info, tag: "QUEUE",
                                 "Expansion cancelled — discarding \(expanded.count) collected leaves",
                                 context: ["objectID": item.objectID])
                    expansionPromptVisible = false
                    return
                }
                sonosDiagLog(.info, tag: "QUEUE",
                             "Expanded local-library container: \(expanded.count) leaf tracks",
                             context: ["objectID": item.objectID])

                // If the alert went up, wait for the user to decide.
                // (If they confirmed before the walk finished, this
                // returns immediately; if they cancelled, the
                // `expansionCancelled` branch above already handled
                // it.) If the alert never went up (count stayed below
                // threshold), no decision needed.
                if expansionPromptShown && !expansionUserConfirmed {
                    let proceed = await awaitExpansionDecision()
                    if !proceed { return }
                }

                if !expanded.isEmpty {
                    let added = try await sonosManager.addBrowseItemsToQueue(expanded, in: group, playNext: playNext)
                    sonosDiagLog(.info, tag: "QUEUE",
                                 "Bulk add complete: \(added) items",
                                 context: ["objectID": item.objectID])
                    return
                }
                sonosDiagLog(.warning, tag: "QUEUE",
                             "Container expansion returned 0 leaves — falling back to single-item add",
                             context: ["objectID": item.objectID])
            }
            let result = try await sonosManager.addBrowseItemToQueue(item, in: group, playNext: playNext, atPosition: 0)
            sonosDiagLog(.info, tag: "QUEUE",
                         "Single-item add complete: trackNumber=\(result)",
                         context: ["objectID": item.objectID])
        } catch {
            sonosDiagLog(.error, tag: "QUEUE",
                         "addToQueue threw: \(error.localizedDescription)",
                         context: [
                            "objectID": item.objectID,
                            "playNext": String(playNext)
                         ])
            ErrorHandler.shared.handle(error, context: "QUEUE", userFacing: true)
        }
    }

    /// Sonos's hard queue ceiling. The speaker rejects (or silently
    /// truncates) AddURIToQueue calls past this; bulk submissions must
    /// be capped client-side.
    public static let sonosQueueLimit = 40_000

    /// Bulk equivalent of `addToQueue` for the top-of-list buttons.
    /// Walks any container items in `items` to their leaf tracks
    /// (mirroring right-click client-side expansion), flattens, and
    /// calls the bulk `addBrowseItemsToQueue`. Capped at the Sonos
    /// queue limit; surfaces a user-visible message via
    /// `playbackError` when the cap is hit.
    func bulkAddToQueue(_ items: [BrowseItem], playNext: Bool) async {
        guard let group = group else { return }
        playbackError = nil
        let (leaves, capped) = await collectAllLeaves(items)
        guard !leaves.isEmpty else { return }
        do {
            _ = try await sonosManager.addBrowseItemsToQueue(leaves, in: group, playNext: playNext)
            if capped {
                playbackError = L10n.queueLimitReachedSomeNotAdded(Self.sonosQueueLimit)
            }
        } catch {
            sonosDebugLog("[BROWSE] bulkAddToQueue failed: \(error)")
            playbackError = "\(L10n.couldNotPlay): \(error.localizedDescription)"
        }
    }

    /// Bulk equivalent of `play` for the top-of-list "Play All". Same
    /// expansion as `bulkAddToQueue`, then replaces the queue and
    /// starts playback.
    func bulkPlayAll(_ items: [BrowseItem]) async {
        guard let group = group else { return }
        playbackError = nil
        let (leaves, capped) = await collectAllLeaves(items)
        guard !leaves.isEmpty else { return }
        do {
            try await sonosManager.playItemsReplacingQueue(leaves, in: group)
            if capped {
                playbackError = L10n.queueLimitReachedRemainderNotAdded(Self.sonosQueueLimit)
            }
        } catch {
            sonosDebugLog("[BROWSE] bulkPlayAll failed: \(error)")
            playbackError = "\(L10n.couldNotPlay): \(error.localizedDescription)"
        }
    }

    /// Expands container items via the same recursion as the right-click
    /// path; passes leaf items through unchanged. Stops walking once the
    /// global Sonos queue limit is reached and signals truncation in
    /// the second tuple element.
    private func collectAllLeaves(_ items: [BrowseItem]) async -> (leaves: [BrowseItem], capped: Bool) {
        var out: [BrowseItem] = []
        var capped = false
        for item in items {
            if out.count >= Self.sonosQueueLimit {
                capped = true
                break
            }
            let resourceURI = item.resourceURI ?? ""
            let isCpContainer = resourceURI.hasPrefix(URIPrefix.rinconContainer)
            if item.isContainer && !isCpContainer {
                let leaves = await expandLocalLibraryContainer(item)
                let remaining = Self.sonosQueueLimit - out.count
                if leaves.count > remaining {
                    out.append(contentsOf: leaves.prefix(remaining))
                    capped = true
                    break
                } else {
                    out.append(contentsOf: leaves)
                }
            } else {
                out.append(item)
            }
        }
        if capped {
            sonosDiagLog(.warning, tag: "QUEUE",
                         "Bulk add truncated at Sonos queue limit (\(Self.sonosQueueLimit))",
                         context: ["leafCount": String(out.count)])
        }
        return (out, capped)
    }

    /// Walks a local-library container (album, artist, genre, top-level
    /// `A:TRACKS`, etc.) down to its leaf tracks. Recurses until each
    /// branch reaches non-container items so deeply-nested structures
    /// (CDs → artist → album → track, three levels under the user's
    /// click) are fully drained.
    ///
    /// Verified against the user's library: top-level "CDs" returns 317
    /// artist folders; each artist holds album sub-folders (e.g. Queen
    /// → 22 album containers); each album holds the individual track
    /// items. A one-level recursion missed all album-organised
    /// artists and capped the queue at ~433 tracks. True multi-level
    /// recursion captures everything up to the 40 000-track queue cap.
    ///
    /// Children at every level are sorted alphabetically by title so
    /// the resulting queue lands in the order the user expects (Sonos's
    /// empty-criteria browse returns catalogue-insertion order).
    private func expandLocalLibraryContainer(_ item: BrowseItem) async -> [BrowseItem] {
        let maxLeaves = Self.sonosQueueLimit
        var leaves: [BrowseItem] = []
        await collectLeaves(into: &leaves,
                            from: item.objectID,
                            depth: 0,
                            maxLeaves: maxLeaves,
                            rootObjectID: item.objectID)
        if leaves.count >= maxLeaves {
            sonosDiagLog(.warning, tag: "QUEUE",
                         "Container expansion truncated at Sonos queue maximum (\(maxLeaves))",
                         context: ["objectID": item.objectID])
        }
        sonosDiagLog(.info, tag: "QUEUE",
                     "expandLocalLibraryContainer leaves=\(leaves.count)",
                     context: ["objectID": item.objectID])
        return leaves
    }

    /// Depth-first recursion. Capped at 6 levels — far past anything
    /// Sonos's local-library hierarchies use (CDs/Artist/Album/Track =
    /// 3) but a safety against pathological / cyclic structures.
    private func collectLeaves(into leaves: inout [BrowseItem],
                               from objectID: String,
                               depth: Int,
                               maxLeaves: Int,
                               rootObjectID: String) async {
        if expansionCancelled { return }
        if leaves.count >= maxLeaves { return }
        if depth > 6 {
            sonosDiagLog(.warning, tag: "QUEUE",
                         "collectLeaves depth limit hit",
                         context: ["objectID": objectID])
            return
        }
        let children = await pagedBrowse(objectID: objectID, ceiling: maxLeaves - leaves.count)
        let sorted = children.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        for child in sorted {
            if expansionCancelled { return }
            if leaves.count >= maxLeaves { break }
            if child.isContainer {
                if isPlaylistFileContainer(child) { continue }
                await collectLeaves(into: &leaves,
                                    from: child.objectID,
                                    depth: depth + 1,
                                    maxLeaves: maxLeaves,
                                    rootObjectID: rootObjectID)
            } else if child.resourceURI?.isEmpty == false {
                leaves.append(child)
                // Publish the live count for the queue spinner and
                // alert label.
                expansionCount = leaves.count
                if let manager = sonosManager as? SonosManager {
                    manager.addingToQueueProgress = leaves.count
                }
                // Cross the threshold once: surface the alert so the
                // user can cancel or pre-confirm. The recursion does
                // NOT suspend — it keeps walking the library in the
                // background, and the alert message updates live as
                // `expansionCount` grows. Cancel sets the flag the
                // recursion checks every iteration; Add All flips
                // `expansionUserConfirmed` so the queue add will
                // start as soon as the walk completes.
                if !expansionPromptShown && leaves.count >= Self.largeAddThreshold {
                    expansionPromptShown = true
                    expansionPromptVisible = true
                }
            }
        }
    }

    private func isPlaylistFileContainer(_ item: BrowseItem) -> Bool {
        let lowered = item.title.lowercased()
        return lowered.hasSuffix(".m3u") || lowered.hasSuffix(".m3u8")
            || lowered.hasSuffix(".pls") || lowered.hasSuffix(".cue")
    }

    /// Pages through `Browse(BrowseDirectChildren)` until an empty
    /// page is returned or the per-call ceiling is reached.
    ///
    /// Speaker-reported `total` is NOT trusted as a terminator —
    /// composite local-library containers (`A:CD`, some genre-derived
    /// virtual folders) return a `total` that reflects only the first
    /// page rather than the true child count, so honouring it caps
    /// expansion at a single page (the 433-track ceiling that
    /// blocked queue-everything-from-CDs reports). Empty page is the
    /// authoritative terminator; the ceiling is the safety bound.
    private func pagedBrowse(objectID: String, ceiling: Int) async -> [BrowseItem] {
        guard ceiling > 0 else { return [] }
        let pageSize = 500
        var collected: [BrowseItem] = []
        var index = 0
        while collected.count < ceiling {
            let want = min(pageSize, ceiling - collected.count)
            guard let page = try? await sonosManager.browse(objectID: objectID, start: index, count: want) else {
                sonosDiagLog(.warning, tag: "QUEUE",
                             "pagedBrowse threw at index \(index)",
                             context: ["objectID": objectID])
                break
            }
            sonosDiagLog(.info, tag: "QUEUE",
                         "pagedBrowse page: index=\(index) returned=\(page.items.count) total=\(page.total)",
                         context: ["objectID": objectID])
            if page.items.isEmpty { break }
            collected.append(contentsOf: page.items)
            index += page.items.count
        }
        return collected
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
