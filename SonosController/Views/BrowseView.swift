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

    /// True when drilled into a service view that has its own search
    private var isInServiceView: Bool {
        guard let current = breadcrumbs.last else { return false }
        let id = current.objectID
        return id == "APPLEMUSICPROMPT:" || id == "TUNEINPROMPT:" ||
               id == "CALMRADIOPROMPT:" || id == "SONOSRADIOPROMPT:" ||
               id == "RECENT:" || id.hasPrefix("SMAPISEARCHPROMPT:") ||
               id.hasPrefix("SMAPI:") || id.hasPrefix("SERVICESEARCH:")
    }

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

                // Local library search — hidden when inside a service view with its own search
                if !isInServiceView {
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
                } else if current.objectID == "CALMRADIOPROMPT:" {
                    CalmRadioBrowseView(group: group)
                } else if current.objectID == "SONOSRADIOPROMPT:" {
                    SonosRadioSearchView(group: group)
                } else if current.objectID.hasPrefix("PLEXDIRECT:") {
                    PlexDirectBrowseView(group: group)
                } else if current.objectID == "LINEIN:" {
                    LineInBrowseView(group: group)
                } else if current.objectID.hasPrefix("SMAPISEARCHPROMPT:") {
                    let sidStr = current.objectID.replacingOccurrences(of: "SMAPISEARCHPROMPT:", with: "")
                    let sid = Int(sidStr) ?? 0
                    let name = ServiceID.knownNames[sid] ?? "Music Service"
                    SMAPIServiceSearchView(group: group, serviceID: sid, serviceName: name)
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

enum SearchSortOrder: String, CaseIterable {
    case relevance = "Relevance"
    case newest = "Newest"
    case oldest = "Oldest"
    case title = "Title"
    case artist = "Artist"
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

// MARK: - Collapsible Section Header

private struct CollapsibleSectionHeader: View {
    let title: String
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack {
                Text(title)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Service Search Ordering

private struct ServiceSearchEntry: Identifiable {
    let key: String       // Unique key for persistence (e.g. "applemusic", "tunein", "smapi:12")
    let title: String
    let objectID: String
    let icon: String
    var id: String { key }
}

private enum ServiceSearchOrder {
    private static let udKey = "serviceSearchOrder"

    static func save(_ keys: [String]) {
        UserDefaults.standard.set(keys, forKey: udKey)
    }

    static func ordered(_ entries: [ServiceSearchEntry]) -> [ServiceSearchEntry] {
        guard let savedKeys = UserDefaults.standard.stringArray(forKey: udKey) else { return entries }
        var result: [ServiceSearchEntry] = []
        // Add entries in saved order
        for key in savedKeys {
            if let entry = entries.first(where: { $0.key == key }) {
                result.append(entry)
            }
        }
        // Append any new entries not in saved order
        for entry in entries where !savedKeys.contains(entry.key) {
            result.append(entry)
        }
        return result
    }
}

struct BrowseSectionsView: View {
    @EnvironmentObject var sonosManager: SonosManager
    @EnvironmentObject var playHistoryManager: PlayHistoryManager
    @EnvironmentObject var smapiManager: SMAPIAuthManager
    @EnvironmentObject var plexAuth: PlexAuthManager
    let group: SonosGroup?
    let onNavigate: (BrowseDestination) -> Void

    @State private var isLoading = true
    @AppStorage("browse_serviceSearch_expanded") private var serviceSearchExpanded = true
    @AppStorage("browse_musicServices_expanded") private var musicServicesExpanded = true
    @AppStorage(UDKey.tuneInSearchEnabled) private var tuneInEnabled = false
    @AppStorage(UDKey.calmRadioEnabled) private var calmRadioEnabled = false
    @AppStorage(UDKey.appleMusicSearchEnabled) private var appleMusicEnabled = false
    @AppStorage(UDKey.sonosRadioEnabled) private var sonosRadioEnabled = false
    @AppStorage("browse_favorites_expanded") private var favoritesExpanded = true
    @AppStorage("browse_library_expanded") private var libraryExpanded = true

    /// Authenticated SMAPI services that support search (excludes services with dedicated views)
    private var smapiSearchableServices: [SMAPIServiceDescriptor] {
        guard smapiManager.isEnabled else { return [] }
        return smapiManager.authenticatedServiceList.filter { svc in
            svc.id != ServiceID.appleMusic && svc.id != ServiceID.tuneIn &&
            svc.id != ServiceID.tuneInNew && svc.id != ServiceID.calmRadio
        }
    }

    // Note: `smapiSearchableServices` now covers *both* Browse and Search —
    // the view opened by the sidebar entry has a `Browse | Search` tab
    // picker at the top (Browse default), so we don't need a separate
    // "Music Services" list for hierarchical-browse services like Plex.
    // One sidebar entry per service, one view with both flows inside.

    /// All service search entries in user-defined order — only includes enabled services
    private var orderedServiceEntries: [ServiceSearchEntry] {
        var entries: [ServiceSearchEntry] = []
        if appleMusicEnabled {
            entries.append(ServiceSearchEntry(key: "applemusic", title: "Apple Music", objectID: "APPLEMUSICPROMPT:", icon: "magnifyingglass"))
        }
        if tuneInEnabled {
            entries.append(ServiceSearchEntry(key: "tunein", title: "TuneIn", objectID: "TUNEINPROMPT:", icon: "radio"))
        }
        if calmRadioEnabled {
            entries.append(ServiceSearchEntry(key: "calmradio", title: "Calm Radio", objectID: "CALMRADIOPROMPT:", icon: "leaf"))
        }
        if sonosRadioEnabled {
            entries.append(ServiceSearchEntry(key: "sonosradio", title: "Sonos Radio", objectID: "SONOSRADIOPROMPT:", icon: "antenna.radiowaves.left.and.right"))
        }
        // Plex's two flavors are wholly independent — Local (direct PMS
        // via PlexAuthManager PIN flow) and Cloud (SMAPI relay). Show
        // each in the sidebar only when its own auth is in place.
        // User can connect 0, 1, or 2 of them.
        let hasDirectPlex = plexAuth.isAuthenticated
        let hasSMAPIPlex = smapiSearchableServices.contains { $0.id == ServiceID.plex }

        for service in smapiSearchableServices {
            // Plex SMAPI is added separately below as "Plex – Cloud" so
            // we don't double-list it as plain "Plex" + a flavored one.
            if service.id == ServiceID.plex { continue }
            entries.append(ServiceSearchEntry(
                key: "smapi:\(service.id)",
                title: service.name,
                objectID: "SMAPISEARCHPROMPT:\(service.id)",
                icon: "magnifyingglass"
            ))
        }
        if hasDirectPlex {
            entries.append(ServiceSearchEntry(
                key: "plex.local",
                title: "Plex – Local",
                objectID: "PLEXDIRECT:",
                icon: "magnifyingglass"
            ))
        }
        if hasSMAPIPlex {
            entries.append(ServiceSearchEntry(
                key: "plex.cloud",
                title: "Plex – Cloud",
                objectID: "SMAPISEARCHPROMPT:\(ServiceID.plex)",
                icon: "magnifyingglass"
            ))
        }
        // Line-In: shown whenever the household has any speaker with
        // analog or TV input capability. We iterate `devices` (all
        // discovered SSDP devices) rather than `groups.members` —
        // model names live on the `_MR` MediaRenderer entries which
        // aren't represented in group membership, so a group-only
        // scan misses them and the entry never appeared.
        let anyInputCapable = sonosManager.devices.values.contains {
            LineInBrowseView.isInputCapable(modelName: $0.modelName)
        }
        if anyInputCapable {
            entries.append(ServiceSearchEntry(
                key: "linein",
                title: "Line-In",
                objectID: "LINEIN:",
                icon: "cable.connector.horizontal"
            ))
        }
        return ServiceSearchOrder.ordered(entries)
    }

    private func moveServiceEntry(from index: Int, by offset: Int) {
        var entries = orderedServiceEntries
        let dest = index + offset
        guard dest >= 0, dest < entries.count else { return }
        entries.swapAt(index, dest)
        ServiceSearchOrder.save(entries.map(\.key))
    }

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

            // Service Search — ordered, reorderable — only shown if services are enabled
            if !orderedServiceEntries.isEmpty {
                Section {
                    CollapsibleSectionHeader(title: "Service Search", isExpanded: $serviceSearchExpanded)
                    if serviceSearchExpanded {
                        ForEach(Array(orderedServiceEntries.enumerated()), id: \.element.id) { index, entry in
                            Button {
                                onNavigate(BrowseDestination(title: entry.title, objectID: entry.objectID))
                            } label: {
                                Label(entry.title, systemImage: entry.icon)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                if index > 0 {
                                    Button(L10n.moveUp) { moveServiceEntry(from: index, by: -1) }
                                }
                                if index < orderedServiceEntries.count - 1 {
                                    Button(L10n.moveDown) { moveServiceEntry(from: index, by: 1) }
                                }
                            }
                        }
                    }
                }
            }

            // Connected Music Services — only services not already shown in Service Search
            // SMAPI services (Plex, Spotify, etc.) appear once under
            // "Service Search" above. The detail view has a Browse/Search
            // tab picker — no need for a second sidebar entry per service.

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
                    Section {
                        CollapsibleSectionHeader(title: L10n.favorites, isExpanded: $favoritesExpanded)
                        if favoritesExpanded {
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
                }

                if !library.isEmpty {
                    Section {
                        CollapsibleSectionHeader(title: L10n.localLibrary, isExpanded: $libraryExpanded)
                        if libraryExpanded {
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

    /// True when the (filtered) result list contains anything that can
    /// be played as-is — gates the bulk-action bar visibility. Albums
    /// with a `cpcontainer:` URI count too, since the speaker can
    /// expand them server-side.
    private var hasPlayableTracks: Bool {
        vm.filteredItems.contains { item in
            (item.resourceURI != nil && !item.isContainer) ||
            item.itemClass == .musicAlbum
        }
    }

    /// Top-of-list bulk actions — Play All / Add All to Queue /
    /// Play Next. Same shape and copy as the other browse views so
    /// the behaviour is consistent across local library, favourites,
    /// SMAPI service search, and Plex Direct.
    private var bulkActionBar: some View {
        HStack(spacing: 6) {
            // TODO: localize (English-only for now)
            Button { Task { await playAllNow() } } label: {
                Label("Play All", systemImage: "play.fill")
            }
            .controlSize(.small)
            Button { Task { await addAllToQueue(playNext: false) } } label: {
                Label("Add All to Queue", systemImage: "text.append")
            }
            .controlSize(.small)
            Button { Task { await addAllToQueue(playNext: true) } } label: {
                Label("Play Next", systemImage: "text.insert")
            }
            .controlSize(.small)
            Spacer()
            Text("\(vm.filteredItems.count) item\(vm.filteredItems.count == 1 ? "" : "s")")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// Collects a flat playable list from the current filtered items.
    /// Containers with a `cpcontainer:` URI (Spotify/Apple Music
    /// albums/playlists from SMAPI search results) pass straight
    /// through — `addBrowseItemsToQueue` lets the speaker expand them
    /// server-side. Bare containers (local library albums browsed via
    /// UPnP) need a child fetch first; for now we send those as-is and
    /// let `playBrowseItem`'s container path handle the queue switch.
    private func collectPlayable() -> [BrowseItem] {
        vm.filteredItems.filter { item in
            (item.resourceURI != nil && !item.isContainer) ||
            item.itemClass == .musicAlbum
        }
    }

    private func playAllNow() async {
        guard let group = vm.group else { return }
        let items = collectPlayable()
        guard !items.isEmpty else { return }
        do {
            try await sonosManager.playItemsReplacingQueue(items, in: group)
        } catch {
            sonosDebugLog("[BROWSE] playAllNow failed: \(error)")
            vm.playbackError = "Couldn't play all: \(error.localizedDescription)"
        }
    }

    private func addAllToQueue(playNext: Bool) async {
        guard let group = vm.group else { return }
        let items = collectPlayable()
        guard !items.isEmpty else { return }
        do {
            _ = try await sonosManager.addBrowseItemsToQueue(items, in: group, playNext: playNext)
        } catch {
            sonosDebugLog("[BROWSE] addAllToQueue failed: \(error)")
            vm.playbackError = "Couldn't add all: \(error.localizedDescription)"
        }
    }

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
                                    .font(.footnote)
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

                    // Bulk-action bar — Play All / Add All / Play Next.
                    // Same shape and copy as PlexDirectBrowseView and
                    // SMAPIServiceSearchView so behaviour reads the same
                    // across every browse surface (local library, Sonos
                    // Favorites, service results — wherever lots of
                    // tracks land in one view).
                    if hasPlayableTracks {
                        bulkActionBar
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
                                            .font(.footnote)
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
        .alert(L10n.renamePlaylist, isPresented: Binding(get: { vm.showRenameAlert }, set: { vm.showRenameAlert = $0 })) {
            TextField(L10n.name, text: Binding(get: { vm.renameText }, set: { vm.renameText = $0 }))
            Button(L10n.cancel, role: .cancel) {}
            Button(L10n.rename) { Task { await vm.renamePlaylist() } }
        }
        .alert(L10n.deletePlaylist, isPresented: Binding(get: { vm.showDeleteConfirm }, set: { vm.showDeleteConfirm = $0 })) {
            Button(L10n.cancel, role: .cancel) {}
            Button(L10n.delete, role: .destructive) { Task { await vm.deletePlaylist() } }
        } message: {
            Text(L10n.confirmDeleteItem(vm.deleteItem?.title ?? ""))
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
                        Menu(L10n.addToPlaylistMenu) {
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
                Button(L10n.renamePlaylist) {
                    vm.renameItem = item
                    vm.renameText = item.title
                    vm.showRenameAlert = true
                }
                Button(L10n.deletePlaylist, role: .destructive) {
                    vm.deleteItem = item
                    vm.showDeleteConfirm = true
                }
            }
        }
    }

    private func smapiDestination(title: String, objectID: String) -> BrowseDestination {
        if vm.isSMAPI, let sid = smapiServiceID, let uri = smapiServiceURI {
            // Child objectIDs coming from `smapiItemToBrowseItem` already
            // carry a `smapi:<sid>:` stamp. If we blindly concatenate our
            // canonical `SMAPI:<sid>:` we end up double-prefixing, which
            // `BrowseViewModel.smapiItemID` then fails to unwrap — Plex
            // receives a container id like `smapi:212:library:section:17`
            // and rejects it with `Client.ItemNotFound`. Strip whatever
            // prefix the child already has before re-wrapping.
            let stripped = SMAPIPrefix.strip(objectID, serviceID: sid)
            let smapiObjID = "\(SMAPIPrefix.upper)\(sid):\(stripped)"
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
        // Service search results (Apple Music, Spotify) have authoritative art — use it directly
        if let direct = item.albumArtURI.flatMap({ URL(string: $0) }) {
            return direct
        }
        // For items without art (local library), use cached/resolved art
        if let resolved = resolvedArtURL {
            return resolved
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
                    if !item.artist.isEmpty || !item.album.isEmpty || item.releaseYear != nil {
                        let parts = [item.artist, item.album].filter { !$0.isEmpty }
                        let meta = parts.joined(separator: " — ")
                        let yearStr = item.releaseYear.map { " (\($0))" } ?? ""
                        Text(meta + yearStr)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if item.isContainer && item.objectID.hasPrefix("SQ:"), let services = playlistScanner.playlistServices[item.objectID] {
                        playlistServiceTags(services: services)
                    } else if let source = sourceLabel {
                        Text(source)
                            .font(.footnote)
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
            // Only resolve art for items that don't already have service-provided art
            guard item.albumArtURI == nil else { return }
            checkArtCache()
            if resolvedArtURL == nil, !didAttemptArtLoad {
                didAttemptArtLoad = true
                Task { await loadMissingArt() }
            }
        }
        .onReceive(sonosManager.artCache.$discoveredArtURLs) { _ in
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
                .font(.footnote)
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(sourceColor(service), in: Capsule())
        }

        if overflow > 0 {
            Text("+\(overflow)")
                .font(.footnote)
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
                .font(.footnote)
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
    @State private var itemsCache: [Int: [BrowseItem]] = [:]
    @State private var sortOrder: SearchSortOrder = .relevance
    @State private var throttleSnapshot: ITunesRateLimiter.Snapshot?
    @State private var bulkActionInFlight = false

    private static let cooldownTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    private var currentLevel: AMLevel { navStack.last ?? .search }

    private var sortedItems: [BrowseItem] {
        switch sortOrder {
        case .relevance:
            return items
        case .newest:
            return items.sorted { ($0.releaseDate ?? .distantPast) > ($1.releaseDate ?? .distantPast) }
        case .oldest:
            return items.sorted { ($0.releaseDate ?? .distantFuture) < ($1.releaseDate ?? .distantFuture) }
        case .title:
            return items.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist:
            return items.sorted { $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending }
        }
    }

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

                    HStack(spacing: 8) {
                        HStack(spacing: 4) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                            TextField(L10n.searchAppleMusicPlaceholder, text: $searchText)
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
                            Text(L10n.search)
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(searchText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    if hasSearched && !items.isEmpty {
                        HStack(spacing: 4) {
                            Text(L10n.sortLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Picker("", selection: $sortOrder) {
                                ForEach(SearchSortOrder.allCases, id: \.self) { order in
                                    Text(order.rawValue).tag(order)
                                }
                            }
                            .labelsHidden()
                            .controlSize(.small)
                            .frame(maxWidth: 120)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)

                Divider()
            }

            // Content
            if let snap = throttleSnapshot, !snap.isAvailable, let until = snap.cooldownUntil {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(.orange)
                    Text(L10n.appleMusicSearchUnavailable)
                        .font(.headline)
                    Text(L10n.appleMusicResumesAt(Self.cooldownTimeFormatter.string(from: until)))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isLoading {
                ProgressView(navStack.isEmpty ? "Searching Apple Music..." : "Loading...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty && (hasSearched || !navStack.isEmpty) {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text(L10n.noResultsFound)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "music.note.list")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text(L10n.searchForSongsAlbumsArtists)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if hasPlayableContent {
                    appleMusicBulkActionBar
                    Divider()
                }
                List(sortedItems) { item in
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
        .task {
            // Refresh the rate-limiter snapshot every 5s while the panel
            // is visible. .task auto-cancels on disappear.
            while !Task.isCancelled {
                throttleSnapshot = await ITunesRateLimiter.shared.snapshot()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        .onChange(of: navStack) {
            let depth = navStack.count
            if let cached = itemsCache[depth] {
                items = cached
            } else if let level = navStack.last {
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

    /// Tracks that the bulk action bar can play directly. Tracks we keep
    /// as-is. Albums get expanded to their tracks via iTunes /lookup
    /// when the user actually presses Play All / Add All — we don't
    /// pre-fetch on view appear because most users don't bulk-act and
    /// each lookup costs a rate-limiter slot.
    private var hasPlayableContent: Bool {
        items.contains {
            ($0.itemClass == .musicTrack || $0.itemClass == .musicAlbum)
                && $0.resourceURI != nil
        } || items.contains { $0.itemClass == .musicAlbum }
    }

    private var bulkContentLabel: String {
        let trackCount = items.filter { $0.itemClass == .musicTrack }.count
        let albumCount = items.filter { $0.itemClass == .musicAlbum }.count
        if albumCount > 0 && trackCount == 0 {
            return "\(albumCount) album\(albumCount == 1 ? "" : "s")"
        }
        return "\(trackCount) track\(trackCount == 1 ? "" : "s")"
    }

    /// Top-of-list bulk actions. Mirrors the SMAPI search bar — Play All
    /// replaces the queue and starts playback; Add All / Play Next append
    /// without disturbing playback.
    /// Buttons are disabled while a bulk action is in flight to prevent
    /// double-firing — large enqueues take a few seconds and rapid second
    /// clicks would otherwise re-add every track.
    private var appleMusicBulkActionBar: some View {
        HStack(spacing: 6) {
            Button { Task { await appleMusicPlayAllNow() } } label: {
                Label(L10n.playAll, systemImage: "play.fill").font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(bulkActionInFlight)
            Button { Task { await appleMusicAddAll(playNext: false) } } label: {
                Label(L10n.addAllToQueue, systemImage: "text.append").font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(bulkActionInFlight)
            Button { Task { await appleMusicAddAll(playNext: true) } } label: {
                Label(L10n.playNext, systemImage: "text.insert").font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(bulkActionInFlight)
            Spacer()
            if bulkActionInFlight {
                ProgressView().controlSize(.small)
                    .padding(.trailing, 4)
            }
            Text(bulkContentLabel)
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// Expands the current `items` into a flat list of playable tracks.
    /// Tracks pass through unchanged; albums are fanned out via
    /// `lookupAlbumTracks` and concatenated in display order.
    private func expandedPlayableTracks() async -> [BrowseItem] {
        var out: [BrowseItem] = []
        for item in items {
            if item.itemClass == .musicTrack, item.resourceURI != nil {
                out.append(item)
            } else if item.itemClass == .musicAlbum {
                if let collectionId = Int(item.objectID.replacingOccurrences(of: "apple:album:", with: "")) {
                    let tracks = await ServiceSearchProvider.shared.lookupAlbumTracks(
                        collectionId: collectionId, sn: sn
                    )
                    out.append(contentsOf: tracks.filter { $0.resourceURI != nil })
                }
            }
        }
        return out
    }

    private func appleMusicPlayAllNow() async {
        guard !bulkActionInFlight, let group = group else { return }
        bulkActionInFlight = true
        defer { bulkActionInFlight = false }
        let tracks = await expandedPlayableTracks()
        guard !tracks.isEmpty else { return }
        // Audio-first: clears + queues + plays the first track in one
        // SOAP round-trip, the rest fills in the background. QueueView's
        // `isAddingToQueue` spinner reflects the background work.
        try? await sonosManager.playItemsReplacingQueue(tracks, in: group)
    }

    private func appleMusicAddAll(playNext: Bool) async {
        guard !bulkActionInFlight, let group = group else { return }
        bulkActionInFlight = true
        defer { bulkActionInFlight = false }
        let tracks = await expandedPlayableTracks()
        guard !tracks.isEmpty else { return }
        _ = try? await sonosManager.addBrowseItemsToQueue(tracks, in: group, playNext: playNext)
    }

    // MARK: - Tap handling

    private func handleTap(_ item: BrowseItem) {
        switch item.itemClass {
        case .musicArtist:
            if let artistId = Int(item.objectID.replacingOccurrences(of: "apple:artist:", with: "")) {
                itemsCache[navStack.count] = items
                navStack.append(.artistAlbums(artistId: artistId, artistName: item.title))
            }
        case .musicAlbum:
            if let collectionId = Int(item.objectID.replacingOccurrences(of: "apple:album:", with: "")) {
                itemsCache[navStack.count] = items
                navStack.append(.albumTracks(collectionId: collectionId, albumTitle: item.title))
            }
        default:
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
                Button(L10n.playNow) {
                    Task { await playAlbumTracks(item, in: group, replace: true) }
                }
                Button(L10n.playNext) {
                    Task { await enqueueAlbumTracks(item, in: group, playNext: true) }
                }
                Button(L10n.addToQueue) {
                    Task { await enqueueAlbumTracks(item, in: group, playNext: false) }
                }
                Divider()
                Button(L10n.replaceQueue) {
                    Task { await playAlbumTracks(item, in: group, replace: true) }
                }
                Divider()
                Button(L10n.showTracks) {
                    handleTap(item)
                }
            } else if isPlayable {
                Button(L10n.playNow) {
                    Task { try? await sonosManager.playBrowseItem(item, in: group) }
                }
                Button(L10n.playNext) {
                    Task { try? await sonosManager.addBrowseItemToQueue(item, in: group, playNext: true) }
                }
                Button(L10n.addToQueue) {
                    Task { try? await sonosManager.addBrowseItemToQueue(item, in: group) }
                }
                if isTrack {
                    Divider()
                    Button(L10n.replaceQueue) {
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

    /// Resolve album tracks via iTunes API, then add them all to queue in a
    /// single SOAP round-trip via AddMultipleURIsToQueue.
    private func enqueueAlbumTracks(_ album: BrowseItem, in group: SonosGroup, playNext: Bool) async {
        guard let collectionId = Int(album.objectID.replacingOccurrences(of: "apple:album:", with: "")) else { return }
        let tracks = await ServiceSearchProvider.shared.lookupAlbumTracks(collectionId: collectionId, sn: sn)
        guard !tracks.isEmpty else { return }
        try? await sonosManager.addBrowseItemsToQueue(tracks, in: group, playNext: playNext)
    }

    /// Clear queue, add album tracks in order, play from track 1.
    private func playAlbumTracks(_ album: BrowseItem, in group: SonosGroup, replace: Bool) async {
        guard let collectionId = Int(album.objectID.replacingOccurrences(of: "apple:album:", with: "")) else { return }
        let tracks = await ServiceSearchProvider.shared.lookupAlbumTracks(collectionId: collectionId, sn: sn)
        guard !tracks.isEmpty else { return }
        if replace {
            try? await sonosManager.playItemsReplacingQueue(tracks, in: group)
        } else {
            _ = try? await sonosManager.addBrowseItemsToQueue(tracks, in: group, playNext: false)
            try? await sonosManager.play(group: group)
        }
    }

    // MARK: - Data loading

    private func performSearch() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        navStack.removeAll()
        itemsCache.removeAll()
        isLoading = true
        hasSearched = true
        Task {
            items = await ServiceSearchProvider.shared.searchAppleMusic(query: query, entity: entity, sn: sn)
            isLoading = false
            // Refresh the rate-limiter snapshot so a 403 triggered by *this*
            // search shows the cooldown banner immediately, not 5 s later.
            throttleSnapshot = await ITunesRateLimiter.shared.snapshot()
            // Resolve missing artist artwork in background (iTunes API doesn't return art for artists)
            if items.contains(where: { $0.itemClass == .musicArtist && $0.albumArtURI == nil }) {
                items = await ServiceSearchProvider.shared.resolveArtistArtwork(for: items)
            }
            itemsCache[0] = items
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
    @State private var itemsCache: [Int: [BrowseItem]] = [:] // depth → items

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
                                TextField(L10n.searchStationsPlaceholder, text: $searchText)
                                    .textFieldStyle(.plain)
                                    .font(.callout)
                                    .onSubmit { performSearch() }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color(nsColor: .quaternaryLabelColor).opacity(0.3), in: RoundedRectangle(cornerRadius: 6))

                            Button { performSearch() } label: {
                                Text(L10n.search).font(.caption)
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
                    Text(L10n.noStationsFound)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty && tab == .search {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text(L10n.searchForRadioStations)
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
                                Button(L10n.playNow) {
                                    Task { try? await sonosManager.playBrowseItem(item, in: group) }
                                }
                            }
                            if item.isContainer {
                                Button(L10n.browse) { handleTap(item) }
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
            let depth = navStack.count
            if let cached = itemsCache[depth] {
                // Popped back — restore cached items for this level
                items = cached
            } else if let level = navStack.last {
                // Drilled forward — load new content
                loadCategory(url: level.url)
            } else if tab == .browse {
                loadBrowse()
            }
        }
    }

    private func handleTap(_ item: BrowseItem) {
        // Stations with a resource URI should play, not drill down
        if let uri = item.resourceURI, !uri.isEmpty, let group = group {
            Task { try? await sonosManager.playBrowseItem(item, in: group) }
        } else if item.isContainer {
            // Cache current items before drilling in
            itemsCache[navStack.count] = items
            let browseURL = item.album.isEmpty ? nil : item.album
            navStack.append(TuneInLevel(title: item.title, url: browseURL))
        }
    }

    private func loadBrowse() {
        isLoading = true
        Task {
            items = await ServiceSearchProvider.shared.browseTuneIn()
            itemsCache[0] = items  // Cache root browse
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
        itemsCache.removeAll()
        Task {
            items = await ServiceSearchProvider.shared.searchTuneIn(query: query)
            itemsCache[0] = items  // Cache root search results
            isLoading = false
        }
    }
}

// MARK: - Calm Radio Browse

struct CalmRadioBrowseView: View {
    @EnvironmentObject var sonosManager: SonosManager
    @EnvironmentObject var smapiManager: SMAPIAuthManager
    let group: SonosGroup?

    @State private var categories: [ServiceSearchProvider.CalmRadioCategory] = []
    @State private var isLoading = true
    @State private var selectedCategory: ServiceSearchProvider.CalmRadioCategory?

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                ProgressView("Loading Calm Radio...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if categories.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "leaf")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text(L10n.noChannelsAvailable)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Category picker — wrapping flow layout
                ScrollView {
                    FlowLayout(spacing: 6) {
                        ForEach(categories) { cat in
                            Button {
                                selectedCategory = cat
                            } label: {
                                Text(cat.name)
                                    .font(.caption)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(selectedCategory?.id == cat.id
                                        ? Color.accentColor.opacity(0.2)
                                        : Color(nsColor: .quaternaryLabelColor).opacity(0.3),
                                        in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: 120)

                Divider()

                // Channel list
                if let cat = selectedCategory {
                    List(cat.channels.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }) { item in
                        BrowseItemRow(item: item)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if let group = group {
                                    Task { try? await sonosManager.playBrowseItem(item, in: group) }
                                }
                            }
                            .contextMenu {
                                if let group = group, item.resourceURI != nil {
                                    Button(L10n.playNow) {
                                        Task { try? await sonosManager.playBrowseItem(item, in: group) }
                                    }
                                    Button(L10n.playNext) {
                                        Task { try? await sonosManager.addBrowseItemToQueue(item, in: group, playNext: true) }
                                    }
                                    Button(L10n.addToQueue) {
                                        Task { try? await sonosManager.addBrowseItemToQueue(item, in: group) }
                                    }
                                }
                            }
                    }
                    .listStyle(.plain)
                }
            }
        }
        .onAppear {
            Task {
                let sn = smapiManager.serialNumber(for: ServiceID.calmRadio)
                categories = await ServiceSearchProvider.shared.browseCalmRadio(sn: sn)
                selectedCategory = categories.first
                isLoading = false
            }
        }
    }
}

// MARK: - SMAPI Service Search (Spotify, Amazon Music, etc.)

private struct SMAPISearchCategoryItem: Identifiable, Hashable {
    let id: String   // SMAPI search ID (e.g., "tracks", "artists")
    let title: String // Display name (e.g., "Tracks", "Artists")
}

private struct SMAPISearchLevel: Equatable {
    let title: String
    let containerID: String
}

private enum SMAPIServiceTab: String, CaseIterable {
    case browse = "Browse"
    case search = "Search"
}

struct SMAPIServiceSearchView: View {
    @EnvironmentObject var sonosManager: SonosManager
    @EnvironmentObject var smapiManager: SMAPIAuthManager
    let group: SonosGroup?
    let serviceID: Int
    let serviceName: String

    @State private var tab: SMAPIServiceTab = .browse
    @State private var searchText = ""
    @State private var categories: [SMAPISearchCategoryItem] = []
    @State private var selectedCategory: SMAPISearchCategoryItem?
    @State private var items: [BrowseItem] = []
    @State private var isLoading = false
    @State private var hasSearched = false
    @State private var navStack: [SMAPISearchLevel] = []
    @State private var categoriesLoaded = false
    @State private var itemsCache: [Int: [BrowseItem]] = [:]
    /// Transient playback-failure banner. Clears itself after 4 s so the
    /// user sees the reason (e.g. Plex SMAPI rejection) without needing
    /// to open the log.
    @State private var playError: String?

    var body: some View {
        VStack(spacing: 0) {
            if let err = playError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.85))
            }

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

            // Tab picker + search controls (only at root level). Browse is
            // the default, matching TuneIn — takes the user straight to
            // the service's root menu (Discover / Playlists / By Artist /
            // By Album / etc. in Plex).
            if navStack.isEmpty {
                VStack(spacing: 8) {
                    Picker("", selection: $tab) {
                        ForEach(SMAPIServiceTab.allCases, id: \.self) { t in
                            Text(t.rawValue).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .onChange(of: tab) {
                        switch tab {
                        case .browse:
                            // Restore browse-tab items from cache (root
                            // or deepest drill level), or load root if
                            // we haven't yet.
                            if let cached = itemsCache[navStack.count] {
                                items = cached
                            }
                            loadBrowseRootIfNeeded()
                        case .search:
                            // Show cached search results, or empty until
                            // the user hits Search.
                            items = hasSearched ? items : []
                        }
                    }

                    if tab == .search {
                        if categories.count > 1 {
                            Picker("", selection: $selectedCategory) {
                                ForEach(categories) { cat in
                                    Text(cat.title).tag(Optional(cat))
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .controlSize(.small)
                            .onChange(of: selectedCategory) {
                                if hasSearched { performSearch() }
                            }
                        }

                        HStack(spacing: 8) {
                            HStack(spacing: 4) {
                                Image(systemName: "magnifyingglass")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                                TextField(L10n.searchServicePlaceholder(serviceName), text: $searchText)
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
                                Text(L10n.search)
                                    .font(.caption)
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
                let label: String = {
                    if !navStack.isEmpty { return "Loading..." }
                    return tab == .search ? "Searching \(serviceName)..." : "Loading \(serviceName)..."
                }()
                ProgressView(label)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty && (hasSearched || !navStack.isEmpty) {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text(L10n.noResultsFound)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text(L10n.searchForSongsAlbumsArtists)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if smapiHasPlayableTracks {
                    smapiBulkActionBar
                    Divider()
                }
                List(items) { item in
                    BrowseItemRow(item: item)
                        .contentShape(Rectangle())
                        .onTapGesture { handleTap(item) }
                        .contextMenu { contextMenuItems(for: item) }
                }
                .listStyle(.plain)
            }
        }
        .onChange(of: navStack) {
            let depth = navStack.count
            if let cached = itemsCache[depth] {
                items = cached
            } else if let level = navStack.last {
                isLoading = true
                items = []
                Task {
                    guard let (token, uri, sn) = serviceCredentials() else {
                        isLoading = false
                        return
                    }
                    items = await ServiceSearchProvider.shared.browseSMAPI(
                        id: level.containerID, serviceID: serviceID,
                        serviceURI: uri, token: token, sn: sn)
                    isLoading = false
                }
            }
        }
        .onAppear {
            loadBrowseRootIfNeeded()
            guard !categoriesLoaded else { return }
            categoriesLoaded = true
            // Load cached categories immediately for instant UI
            let cacheKey = "smapiSearchCategories_\(serviceID)"
            if let cached = UserDefaults.standard.array(forKey: cacheKey) as? [[String: String]], !cached.isEmpty {
                categories = [SMAPISearchCategoryItem(id: "all", title: "All")]
                    + cached.compactMap { d in
                        guard let id = d["id"], let title = d["title"] else { return nil }
                        return SMAPISearchCategoryItem(id: id, title: title)
                    }
                selectedCategory = categories.first
            } else {
                setDefaultCategories()
            }
            // Refresh from service in background
            Task {
                guard let (token, uri, _) = serviceCredentials() else { return }
                let client = SMAPIClient.shared
                if let discovered = try? await client.getSearchCategories(serviceURI: uri, token: token),
                   !discovered.isEmpty {
                    let newCats = [SMAPISearchCategoryItem(id: "all", title: "All")]
                        + discovered.map { SMAPISearchCategoryItem(id: $0.id, title: $0.title) }
                    if newCats.map(\.id) != categories.map(\.id) {
                        categories = newCats
                        if selectedCategory == nil || !newCats.contains(where: { $0.id == selectedCategory?.id }) {
                            selectedCategory = newCats.first
                        }
                    }
                    // Cache for next time
                    let toCache = discovered.map { ["id": $0.id, "title": $0.title] }
                    UserDefaults.standard.set(toCache, forKey: cacheKey)
                }
            }
        }
    }

    /// Loads the Browse tab's root on first Browse-tab use, or on retry
    /// if an earlier attempt found no credentials. Browse content is
    /// otherwise driven by the same `navStack` / `itemsCache` structure
    /// the Search tab uses — drill pushes onto `navStack`, back pops,
    /// and itemsCache[depth] restores from memory without a re-fetch.
    private func loadBrowseRootIfNeeded() {
        guard tab == .browse, navStack.isEmpty, items.isEmpty, !isLoading else { return }
        isLoading = true
        Task {
            guard let (token, uri, sn) = serviceCredentials() else {
                isLoading = false
                return
            }
            let loaded = await ServiceSearchProvider.shared.browseSMAPI(
                id: BrowseID.smapiRoot, serviceID: serviceID,
                serviceURI: uri, token: token, sn: sn)
            items = loaded
            itemsCache[0] = loaded
            isLoading = false
        }
    }

    private func setDefaultCategories() {
        categories = [
            SMAPISearchCategoryItem(id: "all", title: "All"),
            SMAPISearchCategoryItem(id: "track", title: "Tracks"),
            SMAPISearchCategoryItem(id: "artist", title: "Artists"),
            SMAPISearchCategoryItem(id: "album", title: "Albums"),
        ]
        selectedCategory = categories.first
    }

    // MARK: - Tap handling

    private func showPlayError(_ message: String) {
        playError = message
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if playError == message { playError = nil }
        }
    }

    private func handleTap(_ item: BrowseItem) {
        if let uri = item.resourceURI, !uri.isEmpty, !item.isContainer {
            if let group = group {
                Task {
                    do {
                        try await sonosManager.playBrowseItem(item, in: group)
                    } catch {
                        sonosDebugLog("[SMAPI_SEARCH] Play failed for \(item.title): \(error). uri=\(uri)")
                        showPlayError("Couldn't play \(item.title): \(error.localizedDescription)")
                    }
                }
            }
        } else if item.isContainer {
            itemsCache[navStack.count] = items
            let containerID = SMAPIPrefix.strip(item.objectID, serviceID: serviceID)
            navStack.append(SMAPISearchLevel(title: item.title, containerID: containerID))
        }
    }

    // MARK: - Context menus

    /// True when at least one item in the current list is a directly
    /// playable track. Albums whose URI is a `cpcontainer` count too —
    /// they're effectively single-action playables.
    private var smapiHasPlayableTracks: Bool {
        items.contains { item in
            (item.resourceURI != nil && !item.isContainer) ||
            item.itemClass == .musicAlbum
        }
    }

    /// Top-of-list bulk actions, mirroring PlexDirectBrowseView and
    /// the rest of the app — same shape and copy so behavior reads
    /// the same regardless of which service the user is in.
    private var smapiBulkActionBar: some View {
        HStack(spacing: 6) {
            // TODO: localize (English-only for now)
            Button { Task { await smapiPlayAllNow() } } label: {
                Label("Play All", systemImage: "play.fill")
            }
            .controlSize(.small)
            Button { Task { await smapiAddAllToQueue(playNext: false) } } label: {
                Label("Add All to Queue", systemImage: "text.append")
            }
            .controlSize(.small)
            Button { Task { await smapiAddAllToQueue(playNext: true) } } label: {
                Label("Play Next", systemImage: "text.insert")
            }
            .controlSize(.small)
            Spacer()
            Text("\(items.count) item\(items.count == 1 ? "" : "s")")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// Bulk action helpers — operate on the entire current items list.
    /// Containers expand to their child tracks before queueing.
    private func smapiCollectTracks() async -> [BrowseItem] {
        var out: [BrowseItem] = []
        for item in items {
            if item.isContainer {
                if let uri = item.resourceURI, !uri.isEmpty {
                    // Container has a `cpcontainer` URI — Sonos can
                    // expand it server-side in a single SOAP call.
                    out.append(item)
                } else if let (token, uri, sn) = serviceCredentials() {
                    let id = SMAPIPrefix.strip(item.objectID, serviceID: serviceID)
                    let kids = await ServiceSearchProvider.shared.browseSMAPI(
                        id: id, serviceID: serviceID,
                        serviceURI: uri, token: token, sn: sn)
                    out.append(contentsOf: kids.filter { $0.resourceURI != nil && !$0.isContainer })
                }
            } else if item.resourceURI != nil {
                out.append(item)
            }
        }
        return out
    }

    private func smapiPlayAllNow() async {
        guard let group = group else { return }
        let tracks = await smapiCollectTracks()
        guard !tracks.isEmpty else { showPlayError("Nothing to play."); return }
        do {
            try await sonosManager.playItemsReplacingQueue(tracks, in: group)
        } catch {
            showPlayError("Couldn't play all: \(error.localizedDescription)")
        }
    }

    private func smapiAddAllToQueue(playNext: Bool) async {
        guard let group = group else { return }
        let tracks = await smapiCollectTracks()
        guard !tracks.isEmpty else { showPlayError("Nothing to add."); return }
        do {
            _ = try await sonosManager.addBrowseItemsToQueue(tracks, in: group, playNext: playNext)
        } catch {
            showPlayError("Couldn't add: \(error.localizedDescription)")
        }
    }

    @ViewBuilder
    private func contextMenuItems(for item: BrowseItem) -> some View {
        if let group = group {
            let isAlbum = item.itemClass == .musicAlbum || (item.isContainer && item.objectID.contains("album"))
            let isPlayable = item.resourceURI != nil

            if isAlbum {
                Button(L10n.playNow) {
                    Task { await playContainer(item, in: group) }
                }
                Button(L10n.playNext) {
                    Task { await enqueueContainer(item, in: group, playNext: true) }
                }
                Button(L10n.addToQueue) {
                    Task { await enqueueContainer(item, in: group, playNext: false) }
                }
                Divider()
                Button(L10n.replaceQueue) {
                    Task { await playContainer(item, in: group) }
                }
                Divider()
                Button(L10n.showTracks) {
                    handleTap(item)
                }
            } else if item.isContainer {
                Button(L10n.browse) { handleTap(item) }
                Divider()
                Button(L10n.playAll) {
                    Task { await playContainer(item, in: group) }
                }
                Button(L10n.addAllToQueue) {
                    Task { await enqueueContainer(item, in: group, playNext: false) }
                }
            } else if isPlayable {
                Button(L10n.playNow) {
                    Task { try? await sonosManager.playBrowseItem(item, in: group) }
                }
                Button(L10n.playNext) {
                    Task { try? await sonosManager.addBrowseItemToQueue(item, in: group, playNext: true) }
                }
                Button(L10n.addToQueue) {
                    Task { try? await sonosManager.addBrowseItemToQueue(item, in: group) }
                }
                Divider()
                Button(L10n.replaceQueue) {
                    Task {
                        try? await sonosManager.clearQueue(group: group)
                        try? await sonosManager.addBrowseItemToQueue(item, in: group)
                        try? await sonosManager.play(group: group)
                    }
                }
            }
        }
    }

    private func enqueueContainer(_ container: BrowseItem, in group: SonosGroup, playNext: Bool) async {
        // If the container has its own resourceURI (Spotify / Apple Music
        // / Plex playlists all come back as `x-rincon-cpcontainer:` URIs
        // from SMAPI), let `addBrowseItemToQueue` handle it — the
        // speaker expands the container into tracks server-side in a
        // single SOAP call, which is fast AND uses the correct DIDL
        // format for the service. Falls back to the browse-then-add-each
        // path only when the container lacks a usable URI.
        if let uri = container.resourceURI, !uri.isEmpty {
            do {
                _ = try await sonosManager.addBrowseItemToQueue(
                    container, in: group, playNext: playNext
                )
                return
            } catch {
                sonosDebugLog("[SMAPI_SEARCH] enqueueContainer (container URI) failed: \(error). uri=\(uri). Falling back.")
            }
        }

        let containerID = SMAPIPrefix.strip(container.objectID, serviceID: serviceID)
        guard let (token, uri, sn) = serviceCredentials() else { return }
        let tracks = await ServiceSearchProvider.shared.browseSMAPI(
            id: containerID, serviceID: serviceID, serviceURI: uri, token: token, sn: sn)
        let playable = tracks.filter { $0.resourceURI != nil && !$0.isContainer }
        guard !playable.isEmpty else {
            showPlayError("No playable tracks in \(container.title)")
            return
        }
        do {
            try await sonosManager.addBrowseItemsToQueue(playable, in: group, playNext: playNext)
        } catch {
            sonosDebugLog("[SMAPI_SEARCH] enqueueContainer (track-by-track) failed: \(error). first URI=\(playable.first?.resourceURI ?? "nil")")
            showPlayError("Couldn't enqueue \(container.title): \(error.localizedDescription)")
        }
    }

    private func playContainer(_ container: BrowseItem, in group: SonosGroup) async {
        // Prefer the container URI path — same reasoning as `enqueueContainer`.
        // `playBrowseItem` already special-cases `x-rincon-cpcontainer:` URIs
        // (clears queue, adds container, plays).
        if let uri = container.resourceURI, !uri.isEmpty {
            do {
                try await sonosManager.playBrowseItem(container, in: group)
                return
            } catch {
                sonosDebugLog("[SMAPI_SEARCH] playContainer (container URI) failed: \(error). uri=\(uri). Falling back.")
            }
        }

        let containerID = SMAPIPrefix.strip(container.objectID, serviceID: serviceID)
        guard let (token, uri, sn) = serviceCredentials() else { return }
        let tracks = await ServiceSearchProvider.shared.browseSMAPI(
            id: containerID, serviceID: serviceID, serviceURI: uri, token: token, sn: sn)
        let playable = tracks.filter { $0.resourceURI != nil && !$0.isContainer }
        guard !playable.isEmpty else {
            showPlayError("No playable tracks in \(container.title)")
            return
        }
        do {
            try await sonosManager.playItemsReplacingQueue(playable, in: group)
        } catch {
            sonosDebugLog("[SMAPI_SEARCH] playContainer (track-by-track) failed: \(error). first URI=\(playable.first?.resourceURI ?? "nil")")
            showPlayError("Couldn't play \(container.title): \(error.localizedDescription)")
            return
        }
    }

    // MARK: - Data loading

    private func performSearch() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        let searchID = selectedCategory?.id ?? "all"
        navStack.removeAll()
        itemsCache.removeAll()
        isLoading = true
        hasSearched = true
        Task {
            guard let (token, uri, sn) = serviceCredentials() else {
                isLoading = false
                return
            }
            if searchID == "all" {
                let realCategories = categories.filter { $0.id != "all" && $0.id != "playlist" }
                let categoriesToSearch = realCategories.isEmpty
                    ? [("track", 20), ("album", 10), ("artist", 5)]
                    : realCategories.map { ($0.id, $0.id == "track" ? 20 : ($0.id == "album" ? 10 : 5)) }

                items = await withTaskGroup(of: [BrowseItem].self) { group in
                    for (catID, limit) in categoriesToSearch {
                        group.addTask {
                            await ServiceSearchProvider.shared.searchSMAPI(
                                term: query, searchID: catID, serviceID: self.serviceID,
                                serviceURI: uri, token: token, sn: sn, count: limit)
                        }
                    }
                    var all: [BrowseItem] = []
                    for await batch in group {
                        all.append(contentsOf: batch)
                    }
                    return all
                }
            } else {
                items = await ServiceSearchProvider.shared.searchSMAPI(
                    term: query, searchID: searchID, serviceID: serviceID,
                    serviceURI: uri, token: token, sn: sn)
            }
            itemsCache[0] = items
            isLoading = false
            // TODO: Enrich SMAPI results with release dates from iTunes
            // Commented out — only Apple Music has dates for now
            // Task {
            //     let enriched = await ServiceSearchProvider.shared.enrichWithReleaseDates(items)
            //     if enriched.contains(where: { $0.releaseDate != nil }) {
            //         self.items = enriched
            //         self.itemsCache[0] = enriched
            //     }
            // }
        }
    }

    private func serviceCredentials() -> (SMAPIToken, String, Int)? {
        guard let token = smapiManager.tokenStore.getToken(for: serviceID),
              let service = smapiManager.availableServices.first(where: { $0.id == serviceID }) else {
            return nil
        }
        let sn = smapiManager.serialNumber(for: serviceID)
        return (token, service.secureUri, sn)
    }
}

