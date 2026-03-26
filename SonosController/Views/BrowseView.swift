/// BrowseView.swift — Content browsing panel (library, favorites, playlists, radio).
///
/// Uses a manual breadcrumb stack instead of NavigationStack to avoid macOS
/// SwiftUI bugs with NavigationLink re-selection. Each drill-down pushes a
/// BrowseDestination onto the stack, back pops it.
import SwiftUI
import Combine
import SonosKit

struct BrowseView: View {
    @EnvironmentObject var sonosManager: SonosManager
    @EnvironmentObject var smapiManager: SMAPIAuthManager
    let group: SonosGroup?

    @State private var searchText = ""
    @State private var breadcrumbs: [BrowseDestination] = []

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack(spacing: 6) {
                // Navigation buttons
                if !breadcrumbs.isEmpty {
                    Button {
                        breadcrumbs.removeAll()
                    } label: {
                        Image(systemName: "house.fill")
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.plain)
                    .help(L10n.browseHome)
                }

                if breadcrumbs.count > 1 {
                    Button {
                        breadcrumbs.removeLast()
                    } label: {
                        Image(systemName: "chevron.backward")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .help(L10n.back)
                }

                if let current = breadcrumbs.last {
                    Text(current.title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text(L10n.browse)
                        .font(.subheadline)
                        .fontWeight(.medium)
                }

                Spacer()

                // Search field
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    TextField(L10n.localSearch, text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.caption)
                        .onSubmit {
                            submitSearch()
                        }
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .opacity(searchText.isEmpty ? 0 : 1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(nsColor: .quaternaryLabelColor).opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                .frame(maxWidth: 180)
                .animation(nil, value: searchText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)

            Divider()

            // Content — either sections view or drill-down list
            if breadcrumbs.isEmpty {
                BrowseSectionsView(group: group, onNavigate: { dest in
                    breadcrumbs.append(dest)
                })
            } else {
                let current = breadcrumbs.last ?? BrowseDestination(title: "", objectID: "")
                if current.objectID == "RECENT:" {
                    RecentlyPlayedView(group: group)
                } else if current.objectID.hasPrefix("SMAPI:"),
                          let sidStr = current.objectID.components(separatedBy: ":").last,
                          let sid = Int(sidStr),
                          let service = smapiManager.availableServices.first(where: { $0.id == sid }) {
                    ServiceBrowseView(service: service, group: group)
                        .environmentObject(smapiManager)
                } else {
                    BrowseListView(
                        title: current.title,
                        objectID: current.objectID,
                        group: group,
                        sonosManager: sonosManager,
                        onNavigate: { dest in
                            breadcrumbs.append(dest)
                        }
                    )
                    .id(current.objectID)
                    .environmentObject(sonosManager)
                }
            }
        }
    }

    private func submitSearch() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        breadcrumbs.append(BrowseDestination(
            title: "Search: \(query)",
            objectID: "SEARCH:\(query)"
        ))
    }
}

struct BrowseDestination: Hashable {
    let title: String
    let objectID: String
}

struct BrowseSectionsView: View {
    @EnvironmentObject var sonosManager: SonosManager
    @EnvironmentObject var playHistoryManager: PlayHistoryManager
    @EnvironmentObject var smapiManager: SMAPIAuthManager
    let group: SonosGroup?
    let onNavigate: (BrowseDestination) -> Void

    @State private var isLoading = true

    var body: some View {
        List {
            // Recently Played
            if !playHistoryManager.entries.isEmpty {
                Section {
                    Button {
                        onNavigate(BrowseDestination(title: "Recently Played", objectID: "RECENT:"))
                    } label: {
                        Label("Recently Played", systemImage: "clock.arrow.circlepath")
                    }
                    .buttonStyle(.plain)
                }
            }

            // Connected music services (SMAPI)
            if smapiManager.isEnabled && !smapiManager.authenticatedServiceList.isEmpty {
                Section("Music Services") {
                    ForEach(smapiManager.authenticatedServiceList, id: \.id) { service in
                        Button {
                            onNavigate(BrowseDestination(title: service.name, objectID: "SMAPI:\(service.id)"))
                        } label: {
                            Label(service.name, systemImage: "music.note.tv")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if isLoading && sonosManager.browseSections.isEmpty {
                Section {
                    ProgressView(L10n.discoveringContent)
                }
            }

            if !sonosManager.browseSections.isEmpty {
                let nonLibrary = sonosManager.browseSections.filter {
                    !$0.objectID.hasPrefix("A:") && !$0.objectID.hasPrefix("S:")
                }
                let library = sonosManager.browseSections.filter {
                    $0.objectID.hasPrefix("A:") || $0.objectID.hasPrefix("S:")
                }.sorted { a, _ in a.objectID.hasPrefix("S:") }

                if !nonLibrary.isEmpty {
                    Section("Favorites & Services") {
                        ForEach(nonLibrary) { section in
                            Button {
                                onNavigate(BrowseDestination(title: section.title, objectID: section.objectID))
                            } label: {
                                Label(section.title, systemImage: section.icon)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if !library.isEmpty {
                    Section("Local Library") {
                        ForEach(library) { section in
                            Button {
                                onNavigate(BrowseDestination(title: section.title, objectID: section.objectID))
                            } label: {
                                Label(section.title, systemImage: section.icon)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .onAppear {
            Task {
                await sonosManager.loadBrowseSections()
                isLoading = false
                // Load SMAPI services if enabled and not already loaded
                if smapiManager.isEnabled && smapiManager.availableServices.isEmpty,
                   let speaker = sonosManager.groups.first?.coordinator {
                    await smapiManager.loadServices(speakerIP: speaker.ip, musicServicesList: sonosManager.musicServicesList)
                    await smapiManager.discoverSerialNumbers(using: sonosManager)
                }
            }
        }
    }
}

/// Displays items for a single level of the browse tree, with pagination and context menus
struct BrowseListView: View {
    @EnvironmentObject var sonosManager: SonosManager
    @EnvironmentObject var playlistScanner: PlaylistServiceScanner
    @State private var vm: BrowseViewModel
    let onNavigate: (BrowseDestination) -> Void

    init(title: String, objectID: String, group: SonosGroup?, sonosManager: SonosManager, onNavigate: @escaping (BrowseDestination) -> Void) {
        self.onNavigate = onNavigate
        _vm = State(wrappedValue: BrowseViewModel(sonosManager: sonosManager, objectID: objectID, title: title, group: group))
    }

    // Accessors — keep body code unchanged
    private var objectID: String { vm.objectID }
    private var group: SonosGroup? { vm.group }
    private var items: [BrowseItem] { vm.items }
    private var totalItems: Int { vm.totalItems }
    private var isLoading: Bool { vm.isLoading }
    private var loadedCount: Int { vm.loadedCount }
    private var errorMessage: String? { vm.errorMessage }
    private var selectedFilter: String? { vm.selectedFilter }
    private var playbackError: String? { vm.playbackError }
    private var playlists: [BrowseItem] { vm.playlists }
    private var showsFilters: Bool { vm.showsFilters }
    private var availableFilters: [String] { vm.availableFilters }
    private var filteredItems: [BrowseItem] { vm.filteredItems }
    private func serviceLabel(for item: BrowseItem) -> String? { vm.serviceLabel(for: item) }

    var body: some View {
        Group {
            if vm.isLoading && vm.items.isEmpty {
                ProgressView(L10n.loading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = vm.errorMessage, vm.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text(L10n.empty)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    // Playback error banner
                    if let error = vm.playbackError {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.caption)
                            Text(error)
                                .font(.caption)
                                .lineLimit(2)
                            Spacer()
                            Button {
                                vm.playbackError = nil
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.orange.opacity(0.1))
                    }

                    // Service filter bar
                    if vm.showsFilters && vm.availableFilters.count > 1 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                FilterChip(label: L10n.all, isSelected: vm.selectedFilter == nil) {
                                    vm.selectedFilter = nil
                                }
                                ForEach(vm.availableFilters, id: \.self) { filter in
                                    FilterChip(label: filter, isSelected: vm.selectedFilter == filter) {
                                        vm.selectedFilter = vm.selectedFilter == filter ? nil : filter
                                    }
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                        }
                        .background(.bar)
                        Divider()
                    }

                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(vm.filteredItems) { item in
                                Button {
                                    handleTap(item)
                                } label: {
                                    BrowseItemRow(item: item)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .onDrag {
                                    sonosManager.draggedBrowseItem = item
                                    return NSItemProvider(object: item.objectID as NSString)
                                }
                                .contextMenu {
                                    contextMenuItems(for: item)
                                }
                                .overlay(alignment: .trailing) {
                                    if item.requiresService {
                                        Text(L10n.requiresSonosApp)
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                            .padding(.trailing, 12)
                                    }
                                }
                                Divider().padding(.leading, 64)
                        }

                        if vm.loadedCount < vm.totalItems {
                            Button("\(L10n.loadMore) (\(vm.loadedCount) \(L10n.of) \(vm.totalItems))...") {
                                Task { await vm.loadMore() }
                            }
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                        }
                    }
                }
                }
            }
        }
        .onAppear {
            Task {
                await vm.loadItems()
                let sqItems = vm.items.filter { $0.objectID.hasPrefix("SQ:") }
                if !sqItems.isEmpty {
                    playlistScanner.backgroundScan(playlists: sqItems, using: sonosManager)
                }
            }
            Task { await vm.loadPlaylists() }
        }
        .alert("Rename Playlist", isPresented: Binding(get: { vm.showRenameAlert }, set: { vm.showRenameAlert = $0 })) {
            TextField("Name", text: Binding(get: { vm.renameText }, set: { vm.renameText = $0 }))
            Button("Cancel", role: .cancel) {}
            Button("Rename") { Task { await vm.renamePlaylist() } }
        }
        .alert("Delete Playlist?", isPresented: Binding(get: { vm.showDeleteConfirm }, set: { vm.showDeleteConfirm = $0 })) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { Task { await vm.deletePlaylist() } }
        } message: {
            Text("Are you sure you want to delete \"\(vm.deleteItem?.title ?? "")\"?")
        }
    }

    @ViewBuilder
    private func contextMenuItems(for item: BrowseItem) -> some View {
        if let group = group {
            if item.isPlayable {
                Button(L10n.playNow) {
                    let capturedItem = item
                    let capturedVM = vm
                    Task { await capturedVM.play(capturedItem) }
                }
                Button(L10n.playNext) {
                    let capturedItem = item
                    let capturedVM = vm
                    Task { await capturedVM.addToQueue(capturedItem, playNext: true) }
                }
                Button(L10n.addToQueue) {
                    let capturedItem = item
                    let capturedVM = vm
                    Task { await capturedVM.addToQueue(capturedItem) }
                }
                if !vm.playlists.isEmpty {
                    Divider()
                    Menu("Add to Playlist") {
                        ForEach(vm.playlists) { playlist in
                            Button(playlist.title) {
                                Task { await vm.addToPlaylist(playlistID: playlist.objectID, item: item) }
                            }
                        }
                    }
                }
            }
            if item.isContainer {
                Divider()
                Button(L10n.browse) {
                    onNavigate(BrowseDestination(title: item.title, objectID: item.objectID))
                }
            }
            if item.objectID.hasPrefix("SQ:") && item.isContainer && objectID == "SQ:" {
                Divider()
                Button("Rename Playlist") {
                    vm.renameItem = item
                    vm.renameText = item.title
                    vm.showRenameAlert = true
                }
                Button("Delete Playlist", role: .destructive) {
                    vm.deleteItem = item
                    vm.showDeleteConfirm = true
                }
            }
        }
    }

    private func handleTap(_ item: BrowseItem) {
        if item.isContainer {
            if item.objectID.hasPrefix("SQ:") {
                Task { await playlistScanner.scanPlaylist(objectID: item.objectID, using: sonosManager, force: true) }
            }
            onNavigate(BrowseDestination(title: item.title, objectID: item.objectID))
        } else if let group = group {
            Task { await vm.play(item) }
        }
    }
}

struct BrowseItemRow: View {
    @EnvironmentObject var sonosManager: SonosManager
    @EnvironmentObject var playlistScanner: PlaylistServiceScanner
    let item: BrowseItem
    @State private var resolvedArtURL: URL?
    @State private var didAttemptArtLoad = false

    private var sourceLabel: String? {
        // 1. Check URI content first — most reliable for identifying the actual service
        //    (SA_RINCON/sid numbers can map to wrong services)
        if let uri = item.resourceURI,
           let name = sonosManager.detectServiceName(fromURI: uri) {
            return name
        }

        // 2. Check serviceDescriptor (SA_RINCON from desc element)
        if let desc = item.serviceDescriptor {
            if let name = sonosManager.musicServiceName(fromDescriptor: desc) {
                return name
            }
        }

        // 3. Check resourceMetadata for SA_RINCON references
        if let meta = item.resourceMetadata {
            if let name = sonosManager.musicServiceName(fromDescriptor: meta) {
                return name
            }
        }

        // 4. Check objectID for known container types
        if item.objectID.hasPrefix("SQ:") { return ServiceName.sonosPlaylist }
        if item.objectID.hasPrefix("A:") || item.objectID.hasPrefix("S:") { return ServiceName.musicLibrary }
        if item.objectID.hasPrefix("R:") { return ServiceName.radio }

        return nil
    }

    private var artURL: URL? {
        // Prefer cached art (discovered during playback) over item's original URL
        // because the original URL may be stale/dead (404)
        if let resolved = resolvedArtURL {
            return resolved
        }
        if let direct = item.albumArtURI.flatMap({ URL(string: $0) }) {
            return direct
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: artURL)
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.body)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if !item.artist.isEmpty || !item.album.isEmpty {
                        Text([item.artist, item.album].filter { !$0.isEmpty }.joined(separator: " — "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if item.isContainer && item.objectID.hasPrefix("SQ:"), let services = playlistScanner.playlistServices[item.objectID] {
                        playlistServiceTags(services: services)
                    } else if let source = sourceLabel {
                        Text(source)
                            .font(.caption2)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(sourceColor(source), in: Capsule())
                    } else if item.isContainer && item.objectID.hasPrefix("SQ:"), playlistScanner.scanning.contains(item.objectID) {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
            }

            Spacer()

            if item.isContainer {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .onAppear {
            checkArtCache()
            // Only attempt art loading if we have no resolved URL AND no DIDL art
            if resolvedArtURL == nil, item.albumArtURI == nil, !didAttemptArtLoad {
                didAttemptArtLoad = true
                Task { await loadMissingArt() }
            }
        }
        .onReceive(sonosManager.$discoveredArtURLs) { _ in
            checkArtCache()
        }
    }

    /// Checks the discovered art cache for this item using multi-key lookup
    private func checkArtCache() {
        // Try exact ID first (favorites use FV:2/xxx as key)
        if let cached = sonosManager.discoveredArtURLs[item.objectID] {
            resolvedArtURL = URL(string: cached)
            return
        }
        // Fall back to URI / title / normalized-title lookup
        if let cached = sonosManager.lookupCachedArt(uri: item.resourceURI, title: item.title) {
            resolvedArtURL = URL(string: cached)
        }
    }

    /// Whether this item is from the local Music Library (S: shares or A: library)
    private var isLocalLibraryItem: Bool {
        item.objectID.hasPrefix("S:") ||
        (item.objectID.hasPrefix("A:") && !item.objectID.hasPrefix("A:GENRE")) ||
        item.resourceURI?.hasPrefix(URIPrefix.fileCifs) == true ||
        item.resourceURI?.hasPrefix(URIPrefix.smb) == true
    }

    /// Loads art for items without albumArtURI.
    private func loadMissingArt() async {
        // 0. Check if playback previously discovered art for this exact item
        if let cachedArt = sonosManager.discoveredArtURLs[item.objectID] {
            resolvedArtURL = URL(string: cachedArt)
            return
        }

        // Local Music Library items: use embedded art, folder art, then iTunes
        if isLocalLibraryItem {
            await loadLocalLibraryArt()
            return
        }

        // 1. Try extracting art from the item's resourceMetadata DIDL
        if let meta = item.resourceMetadata, !meta.isEmpty {
            let didl = meta.contains("&lt;") ? XMLResponseParser.xmlUnescape(meta) : meta
            if let parsed = XMLResponseParser.parseDIDLMetadata(didl), !parsed.albumArtURI.isEmpty {
                var artURI = parsed.albumArtURI
                if artURI.hasPrefix("/"), let device = sonosManager.groups.first?.coordinator {
                    artURI = "http://\(device.ip):\(device.port)\(artURI)"
                }
                resolvedArtURL = URL(string: artURI)
                sonosManager.cacheArtURL(artURI, forURI: item.resourceURI ?? "", title: item.title, itemID: item.objectID)
                return
            }
        }

        // 2. Try BrowseMetadata — asks the speaker for the item's full metadata
        //    including albumArtURI (works for radio stations, favorites, etc.)
        do {
            if let metaItem = try await sonosManager.browseMetadata(objectID: item.objectID),
               let artURI = metaItem.albumArtURI {
                resolvedArtURL = URL(string: artURI)
                sonosManager.cacheArtURL(artURI, forURI: item.resourceURI ?? item.objectID, title: item.title, itemID: item.objectID)
                return
            }
        } catch { sonosDebugLog("[BROWSE] Container art browse failed: \(error)")
            sonosDebugLog("[BROWSE] BrowseMetadata art lookup failed: \(error)")
        }

        // 3. For non-radio items, try the Sonos speaker's /getaa endpoint
        if let uri = item.resourceURI, !uri.isEmpty,
           !uri.hasPrefix(URIPrefix.sonosApiStream),
           !uri.hasPrefix(URIPrefix.sonosApiRadio),
           !uri.hasPrefix(URIPrefix.rinconMP3Radio),
           !uri.hasPrefix(URIPrefix.rinconPlaylist),
           let device = sonosManager.groups.first?.coordinator {
            let encoded = uri.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? uri
            let artURL = "http://\(device.ip):\(device.port)/getaa?s=1&u=\(encoded)"
            resolvedArtURL = URL(string: artURL)
            sonosManager.cacheArtURL(artURL, forURI: uri, title: item.title, itemID: item.objectID)
            return
        }

        // 3. Try browsing first track (containers only)
        if item.isContainer {
            do {
                let (items, _) = try await sonosManager.browse(objectID: item.objectID, start: 0, count: 1)
                if let firstItem = items.first, let artURI = firstItem.albumArtURI {
                    resolvedArtURL = URL(string: artURI)
                    sonosManager.cacheArtURL(artURI, forURI: item.resourceURI ?? item.objectID, title: item.title, itemID: item.objectID)
                    return
                }
            } catch { sonosDebugLog("[BROWSE] Container art browse failed: \(error)")
            }
        }

        // 4. Fallback: search iTunes for art (not for radio)
        let isRadio = item.resourceURI?.contains("x-sonosapi-stream:") == true ||
                      item.resourceURI?.contains("x-sonosapi-radio:") == true ||
                      item.resourceURI?.contains("x-rincon-mp3radio:") == true
        if !isRadio {
            let artist = item.artist.isEmpty ? "" : item.artist
            if let artURL = await AlbumArtSearchService.shared.searchArtwork(artist: artist, album: item.title) {
                resolvedArtURL = URL(string: artURL)
            }
        }
    }

    /// Art loading for local Music Library items.
    /// Tracks: embedded art via /getaa
    /// Albums/leaf folders: embedded art from first track, then iTunes
    /// Parent folders (artists, genres): iTunes first, then inherit from child
    private func loadLocalLibraryArt() async {
        guard let device = sonosManager.groups.first?.coordinator else { return }

        // 1. If the item has a direct file URI (not a playlist/container URI),
        //    try /getaa which extracts embedded art from the file
        if let uri = item.resourceURI, !uri.isEmpty,
           (uri.hasPrefix(URIPrefix.fileCifs) || uri.hasPrefix(URIPrefix.smb)) {
            let encoded = uri.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? uri
            let artURL = "http://\(device.ip):\(device.port)/getaa?s=1&u=\(encoded)"
            resolvedArtURL = URL(string: artURL)
            sonosManager.cacheArtURL(artURL, forURI: uri, title: item.title, itemID: item.objectID)
            return
        }

        // 2. For containers (folders/albums/artists)
        if item.isContainer {
            // Determine the best search terms based on the item type
            let isArtistContainer = item.objectID.hasPrefix("A:ALBUMARTIST/") || item.objectID.hasPrefix("A:ARTIST/")
            let isAlbumContainer = item.objectID.hasPrefix("A:ALBUM/")

            if isArtistContainer {
                // Artist container: title IS the artist name
                if let artURL = await AlbumArtSearchService.shared.searchArtwork(artist: item.title, album: "") {
                    resolvedArtURL = URL(string: artURL)
                    sonosManager.cacheArtURL(artURL, forURI: item.objectID, title: item.title)
                    return
                }
            } else if isAlbumContainer {
                // Album container: title is album, artist might be in item.artist
                let artist = item.artist.isEmpty ? "" : item.artist
                if let artURL = await AlbumArtSearchService.shared.searchArtwork(artist: artist, album: item.title) {
                    resolvedArtURL = URL(string: artURL)
                    sonosManager.cacheArtURL(artURL, forURI: item.objectID, title: item.title)
                    return
                }
            } else {
                // Share folder or other container — try title as album/artist
                let artist = item.artist.isEmpty ? "" : item.artist
                if let artURL = await AlbumArtSearchService.shared.searchArtwork(artist: artist, album: item.title) {
                    resolvedArtURL = URL(string: artURL)
                    sonosManager.cacheArtURL(artURL, forURI: item.objectID, title: item.title)
                    return
                }

                // Try guessing from path: parent folder = artist, current = album
                if let (guessedArtist, guessedAlbum) = guessArtistAlbum(from: item.objectID, title: item.title) {
                    if let artURL = await AlbumArtSearchService.shared.searchArtwork(artist: guessedArtist, album: guessedAlbum) {
                        resolvedArtURL = URL(string: artURL)
                        sonosManager.cacheArtURL(artURL, forURI: item.objectID, title: item.title)
                        return
                    }
                }
            }

            // Inherit from child: browse to find a track with embedded art
            if let artURL = await findArtInContainer(objectID: item.objectID, device: device, depth: 0) {
                resolvedArtURL = artURL
                sonosManager.cacheArtURL(artURL.absoluteString, forURI: item.objectID, title: item.title)
                return
            }
        }
    }

    /// Guesses artist and album from the objectID path or folder structure.
    /// e.g. "S://NAS/Music/Pink Floyd/The Wall" → ("Pink Floyd", "The Wall")
    /// e.g. "A:ALBUMARTIST/Beatles/Abbey Road" → ("Beatles", "Abbey Road")
    private func guessArtistAlbum(from objectID: String, title: String) -> (String, String)? {
        // Decode percent-encoded path
        let decoded = objectID.removingPercentEncoding ?? objectID

        // Split by / and get the last meaningful segments
        let parts = decoded.components(separatedBy: "/").filter { !$0.isEmpty }

        // Need at least 2 path segments beyond the root
        guard parts.count >= 2 else { return nil }

        let folder = parts[parts.count - 1]
        let parent = parts[parts.count - 2]

        // Skip if parent looks like a root/share name (short or generic)
        let skipParents = ["music", "media", "audio", "share", "shares", "nas", "volume1"]
        if skipParents.contains(parent.lowercased()) { return nil }

        // The current folder is the album, parent is the artist
        // Only if they're different from what we already searched
        if parent.lowercased() != title.lowercased() {
            return (parent, folder)
        }

        // Try parent as artist, title as album
        if parts.count >= 3 {
            let grandparent = parts[parts.count - 3]
            if !skipParents.contains(grandparent.lowercased()) {
                return (grandparent, title)
            }
        }

        return nil
    }

    /// Recursively browses into a container to find a track with album art.
    /// Checks up to 2 levels deep (folder → subfolder → track).
    private func findArtInContainer(objectID: String, device: SonosDevice, depth: Int) async -> URL? {
        guard depth < 3 else { return nil }
        do {
            let (items, _) = try await sonosManager.browse(objectID: objectID, start: 0, count: 5)
            for browseItem in items {
                // Found a track with art
                if let artURI = browseItem.albumArtURI {
                    return URL(string: artURI)
                }
                // Track without art in DIDL — try /getaa with its resource URI
                if !browseItem.isContainer, let uri = browseItem.resourceURI, !uri.isEmpty {
                    let encoded = uri.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? uri
                    return URL(string: "http://\(device.ip):\(device.port)/getaa?s=1&u=\(encoded)")
                }
                // Subfolder — browse into it
                if browseItem.isContainer {
                    if let art = await findArtInContainer(objectID: browseItem.objectID, device: device, depth: depth + 1) {
                        return art
                    }
                }
            }
        } catch { sonosDebugLog("[BROWSE] Load playlists failed: \(error)") }
        return nil
    }

    @ViewBuilder
    private func playlistServiceTags(services: Set<String>) -> some View {
        let sorted = services.sorted()
        let maxVisible = 3
        let visible = Array(sorted.prefix(maxVisible))
        let overflow = sorted.count - maxVisible

        ForEach(visible, id: \.self) { service in
            Text(service)
                .font(.caption2)
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(sourceColor(service), in: Capsule())
        }

        if overflow > 0 {
            Text("+\(overflow)")
                .font(.caption2)
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.gray.opacity(0.6), in: Capsule())
                .help(sorted.dropFirst(maxVisible).joined(separator: ", "))
        }
    }

    private func sourceColor(_ source: String) -> Color {
        ServiceColor.color(for: source)
    }
}

// MARK: - Filter Chip

private struct FilterChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption2)
                .fontWeight(isSelected ? .semibold : .regular)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.15), in: Capsule())
                .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}
