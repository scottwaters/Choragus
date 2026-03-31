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
                } else if current.objectID == "APPLEMUSICPROMPT:" {
                    AppleMusicSearchView(group: group, onNavigate: { dest in
                        breadcrumbs.append(dest)
                    })
                } else if current.objectID == "TUNEINPROMPT:" {
                    TuneInSearchView(group: group)
                } else {
                    BrowseListView(
                        title: current.title,
                        objectID: current.objectID,
                        group: group,
                        sonosManager: sonosManager,
                        smapiServiceID: current.smapiServiceID,
                        smapiServiceURI: current.smapiServiceURI,
                        smapiAuthType: current.smapiAuthType,
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
    var smapiServiceID: Int? = nil
    var smapiServiceURI: String? = nil
    var smapiAuthType: String? = nil

    init(title: String, objectID: String, smapiService: SMAPIServiceDescriptor? = nil) {
        self.title = title
        self.objectID = objectID
        self.smapiServiceID = smapiService?.id
        self.smapiServiceURI = smapiService?.secureUri
        self.smapiAuthType = smapiService?.authType
    }
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

            // Service Search
            Section("Service Search") {
                Button {
                    onNavigate(BrowseDestination(title: "Search Apple Music", objectID: "APPLEMUSICPROMPT:"))
                } label: {
                    Label("Search Apple Music", systemImage: "magnifyingglass")
                }
                .buttonStyle(.plain)

                Button {
                    onNavigate(BrowseDestination(title: "Search TuneIn Radio", objectID: "TUNEINPROMPT:"))
                } label: {
                    Label("Search TuneIn Radio", systemImage: "radio")
                }
                .buttonStyle(.plain)
            }

            // Connected Music Services (only user-authenticated services)
            if smapiManager.isEnabled {
                let connected = smapiManager.authenticatedServiceList
                if !connected.isEmpty {
                    Section("Music Services") {
                        ForEach(connected, id: \.id) { service in
                            Button {
                                onNavigate(BrowseDestination(
                                    title: service.name,
                                    objectID: "SMAPI:\(service.id):root",
                                    smapiService: service
                                ))
                            } label: {
                                Label(service.name, systemImage: "music.note.house")
                            }
                            .buttonStyle(.plain)
                        }
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
                if smapiManager.isEnabled {
                    if smapiManager.availableServices.isEmpty,
                       let speaker = sonosManager.groups.first?.coordinator {
                        await smapiManager.loadServices(speakerIP: speaker.ip, musicServicesList: sonosManager.musicServicesList)
                    }
                    // Discover account serial numbers from favorites for correct playback auth
                    if smapiManager.serviceSerialNumbers.isEmpty {
                        await smapiManager.discoverSerialNumbers(using: sonosManager)
                    }
                }
            }
        }
    }
}

/// Displays items for a single level of the browse tree, with pagination and context menus
struct BrowseListView: View {
    @EnvironmentObject var sonosManager: SonosManager
    @EnvironmentObject var playlistScanner: PlaylistServiceScanner
    @EnvironmentObject var smapiManager: SMAPIAuthManager
    @State private var vm: BrowseViewModel
    let onNavigate: (BrowseDestination) -> Void

    private let smapiServiceID: Int?
    private let smapiServiceURI: String?
    private let smapiAuthType: String?

    init(title: String, objectID: String, group: SonosGroup?, sonosManager: SonosManager,
         smapiServiceID: Int? = nil, smapiServiceURI: String? = nil, smapiAuthType: String? = nil,
         onNavigate: @escaping (BrowseDestination) -> Void) {
        self.onNavigate = onNavigate
        self.smapiServiceID = smapiServiceID
        self.smapiServiceURI = smapiServiceURI
        self.smapiAuthType = smapiAuthType
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

                    // Service filter bar — wrapping layout so all tags are visible
                    if vm.showsFilters && vm.availableFilters.count > 1 {
                        FlowLayout(spacing: 6) {
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
            // Configure service search serial number for Apple Music
            if vm.isServiceSearch {
                if smapiManager.serviceSerialNumbers.isEmpty {
                    Task {
                        await smapiManager.discoverSerialNumbers(using: sonosManager)
                        vm.serviceSearchSN = smapiManager.serialNumber(for: ServiceID.appleMusic)
                    }
                } else {
                    vm.serviceSearchSN = smapiManager.serialNumber(for: ServiceID.appleMusic)
                }
            }

            // Configure SMAPI if this is a service browse
            if let sid = smapiServiceID, let uri = smapiServiceURI {
                vm.smapiServiceID = sid
                vm.smapiServiceURI = uri
                vm.smapiAuthType = smapiAuthType
                vm.smapiClient = smapiManager.client
                vm.smapiToken = smapiManager.tokenStore.getToken(for: sid)
                vm.smapiDeviceID = smapiManager.tokenStore.authenticatedServices.values.first?.deviceID ?? ""
                // Ensure serial numbers are discovered before browsing
                if smapiManager.serviceSerialNumbers.isEmpty {
                    Task {
                        await smapiManager.discoverSerialNumbers(using: sonosManager)
                        vm.smapiSerialNumber = smapiManager.serialNumber(for: sid)
                    }
                } else {
                    vm.smapiSerialNumber = smapiManager.serialNumber(for: sid)
                }
            }
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
            let isRadio = item.resourceURI.map(URIPrefix.isRadio) ?? false ||
                          item.itemClass == .radioStation || item.itemClass == .radioShow
            if item.isPlayable {
                Button(L10n.playNow) {
                    let capturedItem = item
                    let capturedVM = vm
                    Task { await capturedVM.play(capturedItem) }
                }
                if !isRadio {
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
            }
            if item.isContainer {
                Divider()
                Button(L10n.browse) {
                    onNavigate(smapiDestination(title: item.title, objectID: item.objectID))
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

    private func smapiDestination(title: String, objectID: String) -> BrowseDestination {
        if vm.isSMAPI, let sid = smapiServiceID, let uri = smapiServiceURI {
            // Carry SMAPI context for drill-down
            let smapiObjID = "SMAPI:\(sid):\(objectID)"
            var dest = BrowseDestination(title: title, objectID: smapiObjID)
            dest.smapiServiceID = sid
            dest.smapiServiceURI = uri
            dest.smapiAuthType = smapiAuthType
            return dest
        }
        return BrowseDestination(title: title, objectID: objectID)
    }

    private func handleTap(_ item: BrowseItem) {
        if item.isContainer {
            if item.objectID.hasPrefix("SQ:") {
                Task { await playlistScanner.scanPlaylist(objectID: item.objectID, using: sonosManager, force: true) }
            }
            onNavigate(smapiDestination(title: item.title, objectID: item.objectID))
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
        sonosManager.serviceLabel(for: item)
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
            // Only check cache if we don't already have art — prevents flash from URL identity change
            if resolvedArtURL == nil && item.albumArtURI == nil {
                checkArtCache()
            }
        }
    }

    private func checkArtCache() {
        let loader = BrowseItemArtLoader(sonosManager: sonosManager)
        resolvedArtURL = loader.checkCache(item: item)
    }

    private func loadMissingArt() async {
        let loader = BrowseItemArtLoader(sonosManager: sonosManager)
        resolvedArtURL = await loader.loadArt(for: item)
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

// MARK: - Flow Layout (wrapping horizontal layout)

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }

        return CGSize(width: maxWidth, height: currentY + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX: CGFloat = bounds.minX
        var currentY: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX && currentX > bounds.minX {
                currentX = bounds.minX
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: .unspecified)
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - Apple Music Search

// MARK: - Apple Music Search with Drill-Down

/// Navigation level within the Apple Music search view
private enum AMLevel: Hashable {
    case search
    case artistAlbums(artistId: Int, artistName: String)
    case albumTracks(collectionId: Int, albumTitle: String)
}

struct AppleMusicSearchView: View {
    @EnvironmentObject var sonosManager: SonosManager
    @EnvironmentObject var smapiManager: SMAPIAuthManager
    let group: SonosGroup?
    let onNavigate: (BrowseDestination) -> Void

    @State private var searchText = ""
    @State private var entity: ServiceSearchEntity = .all
    @State private var items: [BrowseItem] = []
    @State private var isLoading = false
    @State private var hasSearched = false
    @State private var sn = 0
    @State private var navStack: [AMLevel] = []

    private var currentLevel: AMLevel { navStack.last ?? .search }

    var body: some View {
        VStack(spacing: 0) {
            // Header with back button for drill-down levels
            if !navStack.isEmpty {
                HStack(spacing: 6) {
                    Button {
                        navStack.removeLast()
                    } label: {
                        Image(systemName: "chevron.backward")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .buttonStyle(.plain)

                    Text(levelTitle)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

                Divider()
            }

            // Search controls (only at search level)
            if navStack.isEmpty {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        HStack(spacing: 4) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                            TextField("Search Apple Music...", text: $searchText)
                                .textFieldStyle(.plain)
                                .font(.callout)
                                .onSubmit { performSearch() }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.3), in: RoundedRectangle(cornerRadius: 6))

                        Button {
                            performSearch()
                        } label: {
                            Text("Search")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(searchText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    Picker("", selection: $entity) {
                        ForEach(ServiceSearchEntity.allCases, id: \.self) { e in
                            Text(e.rawValue).tag(e)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .onChange(of: entity) {
                        if hasSearched { performSearch() }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)

                Divider()
            }

            // Content
            if isLoading {
                ProgressView(navStack.isEmpty ? "Searching Apple Music..." : "Loading...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty && (hasSearched || !navStack.isEmpty) {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("No results found")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "music.note.list")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("Search for songs, albums, or artists")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(items) { item in
                    BrowseItemRow(item: item)
                        .contentShape(Rectangle())
                        .onTapGesture { handleTap(item) }
                        .contextMenu { contextMenuItems(for: item) }
                }
                .listStyle(.plain)
            }
        }
        .onAppear {
            if smapiManager.serviceSerialNumbers.isEmpty {
                Task {
                    await smapiManager.discoverSerialNumbers(using: sonosManager)
                    sn = smapiManager.serialNumber(for: ServiceID.appleMusic)
                }
            } else {
                sn = smapiManager.serialNumber(for: ServiceID.appleMusic)
            }
        }
        .onChange(of: navStack) {
            if let level = navStack.last {
                loadLevel(level)
            }
        }
    }

    // MARK: - Level title

    private var levelTitle: String {
        switch currentLevel {
        case .search: return "Search"
        case .artistAlbums(_, let name): return name
        case .albumTracks(_, let title): return title
        }
    }

    // MARK: - Tap handling

    private func handleTap(_ item: BrowseItem) {
        switch item.itemClass {
        case .musicArtist:
            // Drill into artist's albums
            if let artistId = Int(item.objectID.replacingOccurrences(of: "apple:artist:", with: "")) {
                navStack.append(.artistAlbums(artistId: artistId, artistName: item.title))
            }
        case .musicAlbum:
            // Drill into album's tracks
            if let collectionId = Int(item.objectID.replacingOccurrences(of: "apple:album:", with: "")) {
                navStack.append(.albumTracks(collectionId: collectionId, albumTitle: item.title))
            }
        default:
            // Track — play it
            if let group = group {
                Task { try? await sonosManager.playBrowseItem(item, in: group) }
            }
        }
    }

    // MARK: - Context menus

    @ViewBuilder
    private func contextMenuItems(for item: BrowseItem) -> some View {
        if let group = group {
            let isAlbum = item.itemClass == .musicAlbum
            let isTrack = item.itemClass == .musicTrack
            let isPlayable = item.resourceURI != nil

            if isAlbum {
                Button("Play Now") {
                    Task { await playAlbumTracks(item, in: group, replace: true) }
                }
                Button("Play Next") {
                    Task { await enqueueAlbumTracks(item, in: group, playNext: true) }
                }
                Button("Add to Queue") {
                    Task { await enqueueAlbumTracks(item, in: group, playNext: false) }
                }
                Divider()
                Button("Replace Queue") {
                    Task { await playAlbumTracks(item, in: group, replace: true) }
                }
                Divider()
                Button("Show Tracks") {
                    handleTap(item)
                }
            } else if isPlayable {
                Button("Play Now") {
                    Task { try? await sonosManager.playBrowseItem(item, in: group) }
                }
                Button("Play Next") {
                    Task { try? await sonosManager.addBrowseItemToQueue(item, in: group, playNext: true) }
                }
                Button("Add to Queue") {
                    Task { try? await sonosManager.addBrowseItemToQueue(item, in: group) }
                }
                if isTrack {
                    Divider()
                    Button("Replace Queue") {
                        Task {
                            try? await sonosManager.clearQueue(group: group)
                            try? await sonosManager.addBrowseItemToQueue(item, in: group)
                            try? await sonosManager.play(group: group)
                        }
                    }
                }
            }
        }
    }

    /// Resolve album tracks via iTunes API, then add each to queue.
    private func enqueueAlbumTracks(_ album: BrowseItem, in group: SonosGroup, playNext: Bool) async {
        guard let collectionId = Int(album.objectID.replacingOccurrences(of: "apple:album:", with: "")) else { return }
        let tracks = await ServiceSearchProvider.shared.lookupAlbumTracks(collectionId: collectionId, sn: sn)
        guard !tracks.isEmpty else { return }

        if playNext {
            // Insert in reverse so they end up in correct order after current track
            for track in tracks.reversed() {
                try? await sonosManager.addBrowseItemToQueue(track, in: group, playNext: true)
            }
        } else {
            for track in tracks {
                try? await sonosManager.addBrowseItemToQueue(track, in: group)
            }
        }
    }

    /// Clear queue, add album tracks in order, play from track 1.
    private func playAlbumTracks(_ album: BrowseItem, in group: SonosGroup, replace: Bool) async {
        guard let collectionId = Int(album.objectID.replacingOccurrences(of: "apple:album:", with: "")) else { return }
        let tracks = await ServiceSearchProvider.shared.lookupAlbumTracks(collectionId: collectionId, sn: sn)
        guard !tracks.isEmpty else { return }
        if replace {
            try? await sonosManager.clearQueue(group: group)
        }
        for track in tracks {
            try? await sonosManager.addBrowseItemToQueue(track, in: group)
        }
        try? await sonosManager.play(group: group)
    }

    // MARK: - Data loading

    private func performSearch() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        navStack.removeAll()
        isLoading = true
        hasSearched = true
        Task {
            items = await ServiceSearchProvider.shared.searchAppleMusic(query: query, entity: entity, sn: sn)
            isLoading = false
        }
    }

    private func loadLevel(_ level: AMLevel) {
        isLoading = true
        items = []
        Task {
            switch level {
            case .search:
                break
            case .artistAlbums(let artistId, _):
                items = await ServiceSearchProvider.shared.lookupArtistAlbums(artistId: artistId, sn: sn)
            case .albumTracks(let collectionId, _):
                items = await ServiceSearchProvider.shared.lookupAlbumTracks(collectionId: collectionId, sn: sn)
            }
            isLoading = false
        }
    }
}

// MARK: - TuneIn Radio Search

// MARK: - TuneIn Radio

private enum TuneInTab: String, CaseIterable {
    case browse = "Browse"
    case search = "Search"
}

private struct TuneInLevel: Equatable {
    let title: String
    let url: String?
}

struct TuneInSearchView: View {
    @EnvironmentObject var sonosManager: SonosManager
    let group: SonosGroup?

    @State private var tab: TuneInTab = .browse
    @State private var searchText = ""
    @State private var items: [BrowseItem] = []
    @State private var isLoading = false
    @State private var hasSearched = false
    @State private var navStack: [TuneInLevel] = []

    var body: some View {
        VStack(spacing: 0) {
            // Back button for drill-down
            if !navStack.isEmpty {
                HStack(spacing: 6) {
                    Button {
                        navStack.removeLast()
                    } label: {
                        Image(systemName: "chevron.backward")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .buttonStyle(.plain)

                    Text(navStack.last?.title ?? "")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

                Divider()
            }

            // Tab picker + search (only at root level)
            if navStack.isEmpty {
                VStack(spacing: 8) {
                    Picker("", selection: $tab) {
                        ForEach(TuneInTab.allCases, id: \.self) { t in
                            Text(t.rawValue).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)

                    if tab == .search {
                        HStack(spacing: 8) {
                            HStack(spacing: 4) {
                                Image(systemName: "magnifyingglass")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                                TextField("Search stations...", text: $searchText)
                                    .textFieldStyle(.plain)
                                    .font(.callout)
                                    .onSubmit { performSearch() }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color(nsColor: .quaternaryLabelColor).opacity(0.3), in: RoundedRectangle(cornerRadius: 6))

                            Button { performSearch() } label: {
                                Text("Search").font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(searchText.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)

                Divider()
            }

            // Content
            if isLoading {
                ProgressView(tab == .search ? "Searching..." : "Loading...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty && (hasSearched || !navStack.isEmpty) {
                VStack(spacing: 8) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("No stations found")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty && tab == .search {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("Search for radio stations")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(items) { item in
                    BrowseItemRow(item: item)
                        .contentShape(Rectangle())
                        .onTapGesture { handleTap(item) }
                        .contextMenu {
                            if let group = group, item.isPlayable {
                                Button("Play Now") {
                                    Task { try? await sonosManager.playBrowseItem(item, in: group) }
                                }
                            }
                            if item.isContainer {
                                Button("Browse") { handleTap(item) }
                            }
                        }
                }
                .listStyle(.plain)
            }
        }
        .onAppear { loadBrowse() }
        .onChange(of: tab) {
            items = []
            hasSearched = false
            navStack.removeAll()
            if tab == .browse { loadBrowse() }
        }
        .onChange(of: navStack) {
            if let level = navStack.last {
                loadCategory(url: level.url)
            } else if tab == .browse {
                loadBrowse()
            }
        }
    }

    private func handleTap(_ item: BrowseItem) {
        if item.isContainer {
            // album field stores the browse URL for categories
            let browseURL = item.album.isEmpty ? nil : item.album
            navStack.append(TuneInLevel(title: item.title, url: browseURL))
        } else if let group = group, item.isPlayable {
            Task { try? await sonosManager.playBrowseItem(item, in: group) }
        }
    }

    private func loadBrowse() {
        isLoading = true
        Task {
            items = await ServiceSearchProvider.shared.browseTuneIn()
            isLoading = false
        }
    }

    private func loadCategory(url: String?) {
        isLoading = true
        items = []
        Task {
            items = await ServiceSearchProvider.shared.browseTuneIn(url: url)
            isLoading = false
        }
    }

    private func performSearch() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        isLoading = true
        hasSearched = true
        navStack.removeAll()
        Task {
            items = await ServiceSearchProvider.shared.searchTuneIn(query: query)
            isLoading = false
        }
    }
}
