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
    /// Target group for play / queue actions. Seeded at init;
    /// `BrowseListView` updates it via `.onChange(of: parentGroup)` so a
    /// pushed list follows the current sidebar selection.
    var group: SonosGroup?

    // MARK: - State

    var items: [BrowseItem] = []
    var totalItems = 0
    var isLoading = true
    var loadedCount = 0
    /// Rows fetched but hidden (legacy queue-history snapshots). Keeps
    /// `totalItems` aligned with what's shown while `loadedCount` stays the
    /// raw speaker-side paging offset.
    private var hiddenCount = 0
    /// True while a `loadMore` round-trip is in flight. Stops the
    /// infinite-scroll sentinel sending N concurrent requests (and
    /// duplicate rows) on a quick scroll past the threshold.
    var isLoadingMore = false
    /// Set once a page returns zero items — the only authoritative
    /// terminator. SMAPI's reported `total` is unreliable for Spotify
    /// (often matches the first-page count even when the playlist has
    /// hundreds of tracks), so gating loadMore on `loadedCount < total`
    /// silently truncates the list. Reset on every fresh load.
    var reachedEnd = false
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

    /// Prompt shown once the recursive walk has collected
    /// `largeAddThreshold` leaf tracks. `expansionCount` keeps updating
    /// while the prompt is up so the queue panel shows progress.
    var expansionPromptVisible: Bool = false
    var expansionCount: Int = 0
    /// True while the recursive walk is running; the sheet disables
    /// "Add All" until the count has settled.
    var expansionInProgress: Bool = false
    /// Latched once the sheet has been requested so it doesn't flicker
    /// if the count fluctuates around the threshold.
    private var expansionPromptShown: Bool = false
    private var expansionContinuation: CheckedContinuation<Bool, Never>?
    private var expansionCancelled: Bool = false
    private var expansionUserConfirmed: Bool = false

    /// Prompt threshold. Album and moderate artist adds go straight
    /// through; a top-level container pops the warning before a
    /// 20k-track expansion runs.
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

    /// Load generation, bumped by every `loadItems` and re-checked after
    /// each await so a stale page from a superseded fetch never resets or
    /// appends over a newer load's results.
    private var loadGuard = GenerationGuard()

    func loadItems() async {
        let generation = loadGuard.begin()
        isLoading = true
        errorMessage = nil
        reachedEnd = false
        do {
            if isSMAPI {
                try await loadSMAPIItems(generation: generation)
            } else if isServiceSearch {
                let query = String(objectID.dropFirst("SERVICESEARCH:".count))
                let result = await ServiceSearchProvider.shared.searchAppleMusic(query: query, entity: serviceSearchEntity, sn: serviceSearchSN)
                guard loadGuard.isCurrent(generation) else { return }
                items = result
                totalItems = items.count
                loadedCount = items.count
            } else if isSearch {
                let query = String(objectID.dropFirst("SEARCH:".count))
                async let artistResults = sonosManager.search(query: query, in: BrowseID.albumArtist, householdID: group?.householdID, start: 0, count: PageSize.searchArtist)
                async let albumResults = sonosManager.search(query: query, in: BrowseID.album, householdID: group?.householdID, start: 0, count: PageSize.searchAlbum)
                async let trackResults = sonosManager.search(query: query, in: BrowseID.tracks, householdID: group?.householdID, start: 0, count: PageSize.searchTrack)
                let (artists, albums, tracks) = try await (artistResults, albumResults, trackResults)
                guard loadGuard.isCurrent(generation) else { return }
                items = artists.items + albums.items + tracks.items
                totalItems = items.count
                loadedCount = items.count
            } else {
                let (result, total) = try await sonosManager.browse(objectID: objectID, householdID: group?.householdID, start: 0, count: pageSize)
                guard loadGuard.isCurrent(generation) else { return }
                // Hide queue-history snapshots (an undo buffer, not user
                // content). `loadedCount` stays the raw count: it is the
                // speaker-side paging offset, so filtered rows still
                // advance it.
                let visible = result.filter { !QueueHistoryStore.isHistoryTitle($0.title) }
                hiddenCount = result.count - visible.count
                items = visible
                totalItems = total - hiddenCount
                loadedCount = result.count
            }
        } catch {
            guard loadGuard.isCurrent(generation) else { return }
            errorMessage = error.localizedDescription
        }
        if loadGuard.isCurrent(generation) { isLoading = false }
    }

    private func loadSMAPIItems(generation: Int) async throws {
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
        guard loadGuard.isCurrent(generation) else { return }
        let sid = smapiServiceID ?? 0
        let sn = smapiSerialNumber
        let generation = group?.systemVersion ?? .unknown
        items = result.items.map { ServiceSearchProvider.shared.smapiItemToBrowseItem($0, serviceID: sid, sn: sn, generation: generation) }
        totalItems = result.total
        loadedCount = items.count
    }

    /// Fetches the next page and appends to `items`. Guarded by
    /// `isLoadingMore` so the infinite-scroll sentinel can fire freely.
    ///
    /// SMAPI sources page through the SMAPI client (the speaker's
    /// `browse(...)` SOAP doesn't know SMAPI item IDs); searches return
    /// the full set on initial load; UPnP browse pages via the speaker.
    func loadMore() async {
        if isLoadingMore { return }
        if reachedEnd { return }
        if isSearch || isServiceSearch { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        // Capture the generation at page start — a `loadItems` reset that
        // lands while this page is in flight makes the page stale; it must
        // not append onto the freshly-reset list.
        let generation = loadGuard.latest

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
                guard loadGuard.isCurrent(generation) else { return }
                let sid = smapiServiceID ?? 0
                let sn = smapiSerialNumber
                let mapped = result.items.map {
                    ServiceSearchProvider.shared.smapiItemToBrowseItem($0, serviceID: sid, sn: sn,
                                                                       generation: group?.systemVersion ?? .unknown)
                }
                if mapped.isEmpty {
                    reachedEnd = true
                } else {
                    items.append(contentsOf: mapped)
                    loadedCount = items.count
                    if result.total > totalItems { totalItems = result.total }
                }
            } else {
                let (result, total) = try await sonosManager.browse(objectID: objectID, householdID: group?.householdID, start: loadedCount, count: pageSize)
                guard loadGuard.isCurrent(generation) else { return }
                if result.isEmpty {
                    reachedEnd = true
                } else {
                    // Same snapshot filter as the initial page — without it,
                    // pages past the first surface the hidden rows.
                    let visible = result.filter { !QueueHistoryStore.isHistoryTitle($0.title) }
                    hiddenCount += result.count - visible.count
                    items.append(contentsOf: visible)
                    loadedCount += result.count
                    if total - hiddenCount > totalItems { totalItems = total - hiddenCount }
                }
            }
        } catch {
            sonosDebugLog("[BROWSE] loadMore threw: \(error)")
            ErrorHandler.shared.handle(error, context: "BROWSE")
        }
    }

    func loadPlaylists() async {
        do {
            let (result, _) = try await sonosManager.browse(objectID: BrowseID.playlists, householdID: group?.householdID, start: 0, count: PageSize.browse)
            // Exclude internal queue-history snapshots — they're saved
            // queues too, but they're an undo buffer, not user playlists.
            playlists = result.filter { $0.isContainer && !QueueHistoryStore.isHistoryTitle($0.title) }
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
                    // Sonos can return 714/402/800 on the direct play of a
                    // YouTube Music favorite yet still load and play it (issue
                    // #69). The fault is not terminal — confirm the speaker's
                    // actual transport state before surfacing a failure, and
                    // suppress the banner when it is in fact playing.
                    if await isGroupPlayingAfterGrace(group) {
                        playbackError = nil
                    } else {
                        let serviceName = item.resourceURI.flatMap { sonosManager.detectServiceName(fromURI: $0) } ?? "the streaming service"
                        playbackError = "\(L10n.couldNotPlay) \"\(item.title)\" — \(serviceName) \(L10n.mayRequireSignIn)"
                    }
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

    /// Issue #69: some services (notably YouTube Music) return a SOAP fault on
    /// the direct play of a favorite yet still load and play it. After such a
    /// fault, confirm the speaker's real transport state before reporting a
    /// failure — the observed state is authoritative, the fault is not.
    private func isGroupPlayingAfterGrace(_ group: SonosGroup) async -> Bool {
        try? await Task.sleep(nanoseconds: 1_500_000_000)  // let the speaker settle
        let state = try? await sonosManager.getTransportState(group: group)
        return state == .playing || state == .transitioning
    }

    /// "Add All" tapped. Sets the confirmation flag; if the walk is already
    /// awaiting a decision, resumes its continuation.
    func confirmExpansion() {
        expansionUserConfirmed = true
        expansionPromptVisible = false
        expansionContinuation?.resume(returning: true)
        expansionContinuation = nil
    }

    /// "Cancel" tapped. Sets the flag `collectLeaves` checks every
    /// iteration; any awaiting continuation resolves `false`.
    func cancelExpansion() {
        sonosDiagLog(.info, tag: "QUEUE",
                     "Large-add cancelled by user at \(expansionCount) tracks")
        expansionCancelled = true
        expansionPromptVisible = false
        expansionContinuation?.resume(returning: false)
        expansionContinuation = nil
    }

    /// Suspends until the user dismisses the alert. Only invoked after the
    /// recursion has finished with no decision made yet.
    private func awaitExpansionDecision() async -> Bool {
        if expansionUserConfirmed { return true }
        if expansionCancelled { return false }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            // Overlapping bulk operations share this single slot — an
            // overwritten continuation would suspend its operation
            // forever. Resolve the earlier one as cancelled first.
            expansionContinuation?.resume(returning: false)
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
        // Every right-click lands a diagnostics row regardless of which
        // branch fires below.
        sonosDiagLog(.info, tag: "QUEUE",
                     "addToQueue: \(item.title) playNext=\(playNext)",
                     context: [
                        "objectID": item.objectID,
                        "isContainer": String(item.isContainer),
                        "isPlayable": String(item.isPlayable),
                        "resourceURI": item.resourceURI ?? "<nil>",
                        "itemClass": "\(item.itemClass)"
                     ])

        // Engage the queue spinner now, not when `addBrowseItemsToQueue`
        // sets it — container expansion can take seconds first.
        if let manager = sonosManager as? SonosManager {
            manager.beginAddingToQueue()
        }
        defer {
            if let manager = sonosManager as? SonosManager {
                manager.endAddingToQueue()
            }
        }

        do {
            // Containers without a SMAPI cpcontainer URI are expanded
            // client-side: passing the container URI to `addURIToQueue`
            // appends correctly but the post-add queue browse races the
            // speaker's commit and shows stale state (issue #8). SMAPI
            // cpcontainer URIs expand cleanly server-side.
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
                    manager.queue.addingToQueueProgress = 0
                }

                // The walk does not pause for the threshold sheet; the
                // count keeps climbing while the user reads it.
                let expanded = await expandLocalLibraryContainer(item)
                expansionInProgress = false
                if let manager = sonosManager as? SonosManager {
                    manager.queue.addingToQueueProgress = 0
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

                // Wait for a decision only if the alert went up and the
                // user hasn't already confirmed.
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
        // Per-operation flag: a Cancel on a previous large-container
        // prompt must not silently disable every later bulk action.
        expansionCancelled = false
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
        // Per-operation flag — see bulkAddToQueue.
        expansionCancelled = false
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

    /// Walks a local-library container (album, artist, genre, `A:TRACKS`,
    /// etc.) down to its leaf tracks, recursing through nested structures
    /// (CDs → artist → album → track).
    ///
    /// Ordering: containers and leaves are sorted alphabetically at every
    /// level, except inside an album or playlist where the browse-returned
    /// order is the track order and must be preserved (issue #59). Sonos's
    /// empty-criteria browse returns catalogue-insertion order for flat
    /// lists like `A:TRACKS`.
    private func expandLocalLibraryContainer(_ item: BrowseItem) async -> [BrowseItem] {
        let maxLeaves = Self.sonosQueueLimit
        var leaves: [BrowseItem] = []
        await collectLeaves(into: &leaves,
                            from: item.objectID,
                            depth: 0,
                            maxLeaves: maxLeaves,
                            rootObjectID: item.objectID,
                            preserveLeafOrder: BrowseExpansionOrder.preservesLeafOrder(item))
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

    /// Depth-first recursion. Depth cap is a safety against pathological /
    /// cyclic structures (Sonos local-library hierarchies are 3 deep).
    private func collectLeaves(into leaves: inout [BrowseItem],
                               from objectID: String,
                               depth: Int,
                               maxLeaves: Int,
                               rootObjectID: String,
                               preserveLeafOrder: Bool) async {
        if BrowseExpansionOrder.shouldStop(collected: leaves.count,
                                           maxLeaves: maxLeaves,
                                           cancelled: expansionCancelled) { return }
        if !BrowseExpansionOrder.canDescend(to: depth) {
            sonosDiagLog(.warning, tag: "QUEUE",
                         "collectLeaves depth limit hit",
                         context: ["objectID": objectID])
            return
        }
        let children = await pagedBrowse(objectID: objectID, ceiling: maxLeaves - leaves.count)
        // Ordering rules (containers first, alphabetical, album / playlist
        // order preserved — #59) live in BrowseExpansionOrder.
        let sorted = BrowseExpansionOrder.walkOrder(children: children,
                                                    preserveLeafOrder: preserveLeafOrder)
        for child in sorted {
            if expansionCancelled { return }
            if leaves.count >= maxLeaves { break }
            if child.isContainer {
                if BrowseExpansionOrder.isPlaylistFileContainer(child) { continue }
                await collectLeaves(into: &leaves,
                                    from: child.objectID,
                                    depth: depth + 1,
                                    maxLeaves: maxLeaves,
                                    rootObjectID: rootObjectID,
                                    preserveLeafOrder: BrowseExpansionOrder.preservesLeafOrder(child))
            } else if child.resourceURI?.isEmpty == false {
                leaves.append(child)
                // Publish the live count for the queue spinner and
                // alert label.
                expansionCount = leaves.count
                if let manager = sonosManager as? SonosManager {
                    manager.queue.addingToQueueProgress = leaves.count
                }
                // Surface the alert once at the threshold; the recursion
                // keeps walking and the alert count updates live.
                if !expansionPromptShown && leaves.count >= Self.largeAddThreshold {
                    expansionPromptShown = true
                    expansionPromptVisible = true
                }
            }
        }
    }

    /// Pages through `Browse(BrowseDirectChildren)` until an empty
    /// page is returned or the per-call ceiling is reached.
    ///
    /// Speaker-reported `total` is not trusted as a terminator: composite
    /// local-library containers (`A:CD`, some genre-derived virtual
    /// folders) report a `total` that reflects only the first page. An
    /// empty page is the authoritative terminator; the ceiling is the
    /// safety bound.
    private func pagedBrowse(objectID: String, ceiling: Int) async -> [BrowseItem] {
        guard ceiling > 0 else { return [] }
        let pageSize = 500
        var collected: [BrowseItem] = []
        var index = 0
        while collected.count < ceiling {
            let want = min(pageSize, ceiling - collected.count)
            guard let page = try? await sonosManager.browse(objectID: objectID, householdID: group?.householdID, start: index, count: want) else {
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

    /// Renames the pending `renameItem` in place. Works for any
    /// speaker-side object the ContentDirectory accepts `UpdateObject`
    /// for — Sonos playlists (`SQ:`) and favourites (`FV:2/`), which
    /// share the same `<dc:title>` swap on the wire (#75).
    func renameSelectedItem() async {
        guard let item = renameItem else { return }
        let newName = renameText.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty, newName != item.title else { return }
        await ErrorHandler.shared.handleAsync("BROWSE", userFacing: true) {
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
