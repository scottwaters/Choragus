/// BrowseView.swift — Content browsing panel (library, favorites, playlists, radio).
///
/// Uses a manual breadcrumb stack instead of NavigationStack to avoid macOS
/// SwiftUI bugs with NavigationLink re-selection. Each drill-down pushes a
/// BrowseDestination onto the stack, back pops it.
import SwiftUI
import Combine
import SonosKit

struct BrowseView: View {
    @Environment(SonosManager.self) private var sonosManager
    @EnvironmentObject var smapiManager: SMAPIAuthManager
    let group: SonosGroup?

    @State private var searchText = ""
    @State private var breadcrumbs: [BrowseDestination] = []
    /// A-Z fast-scroll (issue #58): the button lives in this header next to
    /// the search field; `azLetter` signals the child list to jump, `azCount`
    /// lets the header show the button only for long lists.
    @State private var azLetter: String?
    @State private var azCount: Int = 0

    /// True when drilled into a service view that has its own search
    private var isInServiceView: Bool {
        guard let current = breadcrumbs.last else { return false }
        let id = current.objectID
        return id == "APPLEMUSICPROMPT:" || id == "APPLEMUSICKIT:" ||
               id == "TUNEINPROMPT:" ||
               id == "CALMRADIOPROMPT:" || id == "SONOSRADIOPROMPT:" ||
               id == "SUNOPROMPT:" || id.hasPrefix("SOMAFMPROMPT:") ||
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
                        if breadcrumbs.count > 1 { breadcrumbs.removeLast() }
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

                // A-Z fast-scroll — left of the search, only for long lists.
                if !isInServiceView && azCount > 40 {
                    AZIndexBar { azLetter = $0 }
                }

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
                } else if current.objectID == "APPLEMUSICKIT:" {
                    MusicKitAppleMusicView(group: group)
                } else if current.objectID == "TUNEINPROMPT:" {
                    TuneInSearchView(group: group)
                } else if current.objectID == "CALMRADIOPROMPT:" {
                    CalmRadioBrowseView(group: group)
                } else if current.objectID == "SONOSRADIOPROMPT:" {
                    SonosRadioSearchView(group: group)
                } else if current.objectID == "SUNOPROMPT:" {
                    SunoSearchView(group: group)
                } else if current.objectID.hasPrefix("PLEXDIRECT:") {
                    PlexDirectBrowseView(group: group)
                } else if current.objectID == "LINEIN:" {
                    LineInBrowseView(group: group)
                } else if current.objectID.hasPrefix("SOMAFMPROMPT:") {
                    // SomaFM is Auth="Anonymous" — browse via the generic
                    // BrowseListView, which uses the anonymous SMAPI path
                    // (no token). The token-only SMAPIServiceSearchView can't
                    // serve it.
                    BrowseListView(
                        title: "SomaFM",
                        objectID: BrowseID.smapiRoot,
                        group: group,
                        sonosManager: sonosManager,
                        smapiServiceID: ServiceID.somaFM,
                        smapiServiceURI: smapiManager.availableServices.first(where: { $0.id == ServiceID.somaFM })?.secureUri,
                        smapiAuthType: "Anonymous",
                        azLetter: $azLetter,
                        azCount: $azCount,
                        onNavigate: { dest in breadcrumbs.append(dest) }
                    )
                    .id(current.objectID)
                    .choragusServices(sonosManager)
                } else if current.objectID.hasPrefix("SMAPISEARCHPROMPT:") {
                    let sidStr = current.objectID.replacingOccurrences(of: "SMAPISEARCHPROMPT:", with: "")
                    let sid = Int(sidStr) ?? 0
                    let name = ServiceID.knownNames[sid] ?? L10n.musicService
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
                        azLetter: $azLetter,
                        azCount: $azCount,
                        onNavigate: { dest in
                            breadcrumbs.append(dest)
                        }
                    )
                    .id(current.objectID)
                    .choragusServices(sonosManager)
                }
            }
        }
    }

    private func submitSearch() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        breadcrumbs.append(BrowseDestination(
            title: L10n.searchResultsTitleFormat(query),
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

// MARK: - Collapsible Section Header

private struct CollapsibleSectionHeader: View {
    let title: String
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title)
                        .font(.headline)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                if isExpanded {
                    Divider()
                }
            }
            .padding(.bottom, isExpanded ? 2 : 0)
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



/// Live-reorders the browse section cards while a drag is in flight;
/// the drop finalizes and the caller persists the order.
private struct BrowseSectionDropDelegate: DropDelegate {
    let item: BrowseSectionsView.BrowseCategory
    @Binding var order: [BrowseSectionsView.BrowseCategory]
    @Binding var dragging: BrowseSectionsView.BrowseCategory?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != item,
              let from = order.firstIndex(of: dragging),
              let to = order.firstIndex(of: item) else { return }
        withAnimation {
            order.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

/// Full-width sidebar row with a hover highlight in the theme accent, so
/// card rows keep a row-sized click target and read as interactive.
private struct BrowseRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Row(configuration: configuration) }

    private struct Row: View {
        @Environment(SonosManager.self) private var sonosManager
        let configuration: Configuration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(configuration.isPressed ? sonosManager.themeAccent.opacity(0.28)
                              : hovering ? sonosManager.themeAccent.opacity(0.16) : Color.clear))
                .onHover { hovering = $0 }
        }
    }
}

struct BrowseSectionsView: View {
    @Environment(SonosManager.self) private var sonosManager
    @EnvironmentObject var playHistoryManager: PlayHistoryManager
    @EnvironmentObject var smapiManager: SMAPIAuthManager
    @EnvironmentObject var plexAuth: PlexAuthManager
    let group: SonosGroup?
    let onNavigate: (BrowseDestination) -> Void

    @State private var isLoading = true
    @AppStorage(UDKey.playlistAIEnabled) private var playlistAIEnabled = false
    /// Bumped on reorder. The persisted service order lives in plain
    /// UserDefaults (outside SwiftUI's observation), so the body must depend on
    /// this to re-render — otherwise Move Up/Down saves but the list doesn't move.
    @State private var orderRevision = 0
    @AppStorage("browse_serviceSearch_expanded") private var serviceSearchExpanded = false
    @AppStorage("browse_musicServices_expanded") private var musicServicesExpanded = false
    @AppStorage(UDKey.tuneInSearchEnabled) private var tuneInEnabled = false
    @AppStorage(UDKey.calmRadioEnabled) private var calmRadioEnabled = false
    @AppStorage(UDKey.somaFMEnabled) private var somaFMEnabled = false
    @AppStorage(UDKey.sunoEnabled) private var sunoEnabled = false
    @AppStorage(UDKey.appleMusicSearchEnabled) private var appleMusicEnabled = false
    @AppStorage(UDKey.appleMusicKitConnected) private var appleMusicKitConnected = false
    @AppStorage(UDKey.sonosRadioEnabled) private var sonosRadioEnabled = false
    @AppStorage("browse_favorites_expanded") private var favoritesExpanded = false
    @AppStorage("browse_choragusSources_expanded") private var choragusSourcesExpanded = false
    @AppStorage("browse_library_expanded") private var libraryExpanded = false

    /// Authenticated SMAPI services that support search (excludes services with dedicated views)
    private var smapiSearchableServices: [SMAPIServiceDescriptor] {
        guard smapiManager.isEnabled else { return [] }
        return smapiManager.authenticatedServiceList.filter { svc in
            svc.id != ServiceID.appleMusic && svc.id != ServiceID.tuneIn &&
            svc.id != ServiceID.calmRadio
        }
    }

    // `smapiSearchableServices` covers both Browse and Search: the view the
    // sidebar entry opens has a `Browse | Search` tab picker (Browse default),
    // so hierarchical-browse services like Plex need no separate list.

    /// All service search entries in user-defined order — only includes enabled services
    private var orderedServiceEntries: [ServiceSearchEntry] {
        var entries: [ServiceSearchEntry] = []
        // MusicKit-driven Apple Music entry — only present when the
        // build compiled with `ENABLE_MUSICKIT`. Surfaces a native
        // catalog search backed by the user's Apple Music account,
        // independent of Sonos's SMAPI search.
        // Show only when the user has actually authorised MusicKit —
        // mirrors the other services (Spotify / Plex / TuneIn) which
        // only surface a sidebar entry once connected. The
        // `appleMusicKitConnected` flag is written by
        // `AppleMusicKitConnectRow` whenever it polls the provider.
        if AppleMusicProviderFactory.hasMusicKitSupport, appleMusicKitConnected {
            // Dev builds (legacy still visible) distinguish the two
            // entries by suffix; release builds (legacy hidden) drop
            // the suffix since there's no ambiguity.
            let title = AppleMusicProviderFactory.showLegacyAppleMusic
                ? "Apple Music (MusicKit)"
                : "Apple Music"
            entries.append(ServiceSearchEntry(key: "applemusickit", title: title, objectID: "APPLEMUSICKIT:", icon: "music.note"))
        }
        // Legacy SMAPI Apple Music — kept visible for fork builds and
        // alongside the MusicKit entry in dev builds for side-by-side
        // comparison; hidden in signed release builds where MusicKit
        // is the sole Apple Music surface.
        if appleMusicEnabled && AppleMusicProviderFactory.showLegacyAppleMusic {
            let title = AppleMusicProviderFactory.hasMusicKitSupport
                ? "Apple Music (Sonos)"
                : "Apple Music"
            entries.append(ServiceSearchEntry(key: "applemusic", title: title, objectID: "APPLEMUSICPROMPT:", icon: "magnifyingglass"))
        }
        if calmRadioEnabled {
            entries.append(ServiceSearchEntry(key: "calmradio", title: "Calm Radio", objectID: "CALMRADIOPROMPT:", icon: "leaf"))
        }
        if somaFMEnabled {
            entries.append(ServiceSearchEntry(key: "somafm", title: "SomaFM", objectID: "SOMAFMPROMPT:", icon: "radio"))
        }
        if sonosRadioEnabled {
            entries.append(ServiceSearchEntry(key: "sonosradio", title: "Sonos Radio", objectID: "SONOSRADIOPROMPT:", icon: "antenna.radiowaves.left.and.right"))
        }
        // Plex's two flavors are wholly independent — Local (direct PMS
        // via PlexAuthManager PIN flow) and Cloud (SMAPI relay). Show
        // each in the sidebar only when its own auth is in place.
        // User can connect 0, 1, or 2 of them.
        // Cache `smapiSearchableServices` — reaching it traverses the
        // SMAPI token store + sorts. Used twice below.
        let smapiServices = smapiSearchableServices
        let hasDirectPlex = plexAuth.isAuthenticated
        let hasSMAPIPlex = smapiServices.contains { $0.id == ServiceID.plex }

        for service in smapiServices {
            // Plex SMAPI is added separately below as "Plex – Remote";
            // skipping it here avoids a second plain "Plex" row.
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
                title: "Plex – Remote",
                objectID: "SMAPISEARCHPROMPT:\(ServiceID.plex)",
                icon: "magnifyingglass"
            ))
        }
        // Line-In: shown whenever any speaker has analog or TV input.
        // Iterates `devices` (all SSDP devices) rather than `groups.members`:
        // model names live on the `_MR` MediaRenderer entries, which group
        // membership does not carry.
        let anyInputCapable = sonosManager.devices.values.contains {
            PhysicalInput.isInputCapable(modelName: $0.modelName)
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
        orderRevision += 1
    }



    /// A draggable, persistable browse category. Raw values are the
    /// storage format for the saved order.
    enum BrowseCategory: String, CaseIterable, Identifiable {
        case recent, services, sources, favorites, library
        var id: String { rawValue }
    }

    @AppStorage("browse_sectionOrder") private var sectionOrderRaw = ""
    @State private var sectionOrder: [BrowseCategory] = []
    @State private var draggingCategory: BrowseCategory?

    /// Saved order plus any categories added since it was saved.
    private var restoredSectionOrder: [BrowseCategory] {
        let saved = sectionOrderRaw.split(separator: ",").compactMap { BrowseCategory(rawValue: String($0)) }
        return saved + BrowseCategory.allCases.filter { !saved.contains($0) }
    }

    @ViewBuilder
    private func sectionBody(for category: BrowseCategory, serviceEntries: [ServiceSearchEntry]) -> some View {
        switch category {
        case .recent:    recentCard
        case .services:  servicesCard(serviceEntries)
        case .sources:   sourcesCard
        case .favorites: favoritesCard
        case .library:   libraryCard
        }
    }

    @ViewBuilder
    private var recentCard: some View {
        if !playHistoryManager.entries.isEmpty {
            sectionCard {
                Button {
                    onNavigate(BrowseDestination(title: L10n.recentlyPlayed, objectID: "RECENT:"))
                } label: {
                    Label(L10n.recentlyPlayed, systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(BrowseRowButtonStyle())
            }
        }
    }

    @ViewBuilder
    private func servicesCard(_ serviceEntries: [ServiceSearchEntry]) -> some View {
        if !serviceEntries.isEmpty {
            sectionCard {
                CollapsibleSectionHeader(title: L10n.sonosMusicServices, isExpanded: $serviceSearchExpanded)
                if serviceSearchExpanded {
                    ForEach(Array(serviceEntries.enumerated()), id: \.element.id) { index, entry in
                        Button {
                            onNavigate(BrowseDestination(title: entry.title, objectID: entry.objectID))
                        } label: {
                            Label(entry.title, systemImage: entry.icon)
                        }
                        .buttonStyle(BrowseRowButtonStyle())
                        .contextMenu {
                            if index > 0 {
                                Button(L10n.moveUp) { moveServiceEntry(from: index, by: -1) }
                            }
                            if index < serviceEntries.count - 1 {
                                Button(L10n.moveDown) { moveServiceEntry(from: index, by: 1) }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var sourcesCard: some View {
        let mediaServerSections = sonosManager.browseSections.filter { $0.objectID.hasPrefix("MS:") }
        sectionCard {
            CollapsibleSectionHeader(title: L10n.choragusSources, isExpanded: $choragusSourcesExpanded)
            if choragusSourcesExpanded {
                Button {
                    _ = WindowManager.shared.openQueueLibraryForActiveGroup()
                } label: {
                    Label(L10n.playlistManager, systemImage: "music.note.list")
                }
                .buttonStyle(BrowseRowButtonStyle())
                // The AI builder is opt-in: Settings → AI enables the
                // feature; disabled = the row disappears entirely.
                if playlistAIEnabled {
                    Button {
                        WindowManager.shared.openPlaylistBuilder()
                    } label: {
                        Label(L10n.playlistBuilderTitle, systemImage: "text.badge.plus")
                    }
                    .buttonStyle(BrowseRowButtonStyle())
                }
                ForEach(mediaServerSections) { section in
                    Button {
                        onNavigate(BrowseDestination(title: section.title, objectID: section.objectID))
                    } label: {
                        HStack(spacing: 6) {
                            Label(section.title, systemImage: section.icon)
                            if let note = section.availabilityNote {
                                Text(note).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(BrowseRowButtonStyle())
                }
                if tuneInEnabled {
                    Button {
                        onNavigate(BrowseDestination(title: "TuneIn", objectID: "TUNEINPROMPT:"))
                    } label: {
                        Label("TuneIn", systemImage: "radio")
                    }
                    .buttonStyle(BrowseRowButtonStyle())
                }
                if sunoEnabled {
                    Button {
                        // Suno opens the embedded browser popup, not an in-panel view.
                        WindowManager.shared.openSunoExploreForActiveGroup()
                    } label: {
                        Label("suno.ai", systemImage: "waveform")
                    }
                    .buttonStyle(BrowseRowButtonStyle())
                }
            }
        }
    }

    @ViewBuilder
    private var favoritesCard: some View {
        let nonLibrary = sonosManager.browseSections.filter {
            !$0.objectID.hasPrefix("A:") && !$0.objectID.hasPrefix("S:")
                && !$0.objectID.hasPrefix("MS:")   // shown under Choragus Sources
        }
        if !nonLibrary.isEmpty {
            sectionCard {
                CollapsibleSectionHeader(title: L10n.favorites, isExpanded: $favoritesExpanded)
                if favoritesExpanded {
                    ForEach(nonLibrary) { section in
                        Button {
                            onNavigate(BrowseDestination(title: section.title, objectID: section.objectID))
                        } label: {
                            HStack(spacing: 6) {
                                Label(section.title, systemImage: section.icon)
                                if let note = section.availabilityNote {
                                    Text(note).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(BrowseRowButtonStyle())
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var libraryCard: some View {
        let library = sonosManager.browseSections.filter {
            $0.objectID.hasPrefix("A:") || $0.objectID.hasPrefix("S:")
        }.sorted { a, _ in a.objectID.hasPrefix("S:") }
        if !library.isEmpty {
            sectionCard {
                CollapsibleSectionHeader(title: L10n.localLibrary, isExpanded: $libraryExpanded)
                if libraryExpanded {
                    ForEach(library) { section in
                        Button {
                            onNavigate(BrowseDestination(title: section.title, objectID: section.objectID))
                        } label: {
                            HStack(spacing: 6) {
                                Label(section.title, systemImage: section.icon)
                                if let note = section.availabilityNote {
                                    Text(note).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(BrowseRowButtonStyle())
                    }
                }
            }
        }
    }

    /// One shaded, rounded card per browse category — the section
    /// container for the sidebar's collapsible groups.
    @ViewBuilder
    private func sectionCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    var body: some View {
        // Compute once per body — `orderedServiceEntries` walks SMAPI
        // tokens and devices and runs a sort.
        let _ = orderRevision   // establish a body dependency on the saved order
        let serviceEntries = orderedServiceEntries
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                // Sections render in the user's saved order; drag a card
                // to reorder. Categories with nothing to show are skipped
                // but keep their place in the order.
                ForEach(sectionOrder) { category in
                    sectionBody(for: category, serviceEntries: serviceEntries)
                        .onDrag {
                            draggingCategory = category
                            return NSItemProvider(object: category.rawValue as NSString)
                        }
                        .onDrop(of: [.text], delegate: BrowseSectionDropDelegate(
                            item: category, order: $sectionOrder, dragging: $draggingCategory))
                }

                if isLoading && sonosManager.browseSections.isEmpty {
                    sectionCard {
                        ProgressView(L10n.discoveringContent)
                    }
                }
            }
            .padding(10)
        }
        .onChange(of: sectionOrder) { _, order in
            sectionOrderRaw = order.map(\.rawValue).joined(separator: ",")
        }
        .onAppear {
            if sectionOrder.isEmpty { sectionOrder = restoredSectionOrder }
            Task {
                await sonosManager.loadBrowseSections()
                isLoading = false
                // Media servers are optional and often absent, so the search
                // runs after the speaker's own sections are on screen rather
                // than delaying them by its collection window.
                Task { await sonosManager.discoverMediaServers() }
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
    @Environment(SonosManager.self) private var sonosManager
    @EnvironmentObject var playlistScanner: PlaylistServiceScanner
    @EnvironmentObject var smapiManager: SMAPIAuthManager
    @State private var vm: BrowseViewModel
    let onNavigate: (BrowseDestination) -> Void

    /// Live parent-passed group. The struct is recreated by SwiftUI on
    /// every parent body re-eval — so this property tracks the current
    /// sidebar selection even while this list is in a navigation stack.
    /// `body` syncs it into `vm.group` via `.onChange` so play / queue
    /// actions on this list always target the currently-selected group,
    /// not the one selected when the list was first navigated to.
    let parentGroup: SonosGroup?

    private let smapiServiceID: Int?
    private let smapiServiceURI: String?
    private let smapiAuthType: String?
    /// A-Z fast-scroll bridge to the parent header's index button (issue #58).
    @Binding private var azLetter: String?
    @Binding private var azCount: Int

    init(title: String, objectID: String, group: SonosGroup?, sonosManager: SonosManager,
         smapiServiceID: Int? = nil, smapiServiceURI: String? = nil, smapiAuthType: String? = nil,
         azLetter: Binding<String?> = .constant(nil), azCount: Binding<Int> = .constant(0),
         onNavigate: @escaping (BrowseDestination) -> Void) {
        self.onNavigate = onNavigate
        self.smapiServiceID = smapiServiceID
        self.smapiServiceURI = smapiServiceURI
        self.smapiAuthType = smapiAuthType
        self.parentGroup = group
        _azLetter = azLetter
        _azCount = azCount
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
    @State private var sortOrder: BrowseSortOption = .relevance
    private var filteredItems: [BrowseItem] { vm.filteredItems }
    private var sortedItems: [BrowseItem] { sortOrder.apply(vm.filteredItems) }
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

    /// Top-of-list bulk actions — Play All / Add All to Queue / Play Next,
    /// with the same layout and copy as the other browse views.
    private var bulkActionBar: some View {
        BrowseBulkActionBar(count: vm.filteredItems.count,
                            playAll: { Task { await playAllNow() } },
                            addAll: { Task { await addAllToQueue(playNext: false) } },
                            playNext: { Task { await addAllToQueue(playNext: true) } })
    }

    /// Collects a flat playable list from the current filtered items.
    /// Containers with a `cpcontainer:` URI (Spotify/Apple Music
    /// albums/playlists from SMAPI search results) pass straight
    /// through — `addBrowseItemsToQueue` lets the speaker expand them
    /// server-side. Bare containers (local library albums browsed via
    /// UPnP) need a child fetch first; those go as-is and
    /// `playBrowseItem`'s container path handles the queue switch.
    private func collectPlayable() -> [BrowseItem] {
        vm.filteredItems.filter { item in
            (item.resourceURI != nil && !item.isContainer) ||
            item.itemClass == .musicAlbum
        }
    }

    private func playAllNow() async {
        let items = collectPlayable()
        guard !items.isEmpty else { return }
        // Route through the VM so containers (local-library albums, etc.)
        // are client-side-expanded to leaf tracks the same way the
        // right-click "Play Now" path does; bypassing it enqueues the
        // bare container row instead of the album's tracks.
        await vm.bulkPlayAll(items)
    }

    private func addAllToQueue(playNext: Bool) async {
        let items = collectPlayable()
        guard !items.isEmpty else { return }
        await vm.bulkAddToQueue(items, playNext: playNext)
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

                    // Bulk-action bar — Play All / Add All / Play Next, same
                    // layout and copy as PlexDirectBrowseView and
                    // SMAPIServiceSearchView.
                    if hasPlayableTracks {
                        bulkActionBar
                        Divider()
                    }
                    if !vm.filteredItems.isEmpty {
                        BrowseSortPicker(items: vm.filteredItems, selection: $sortOrder)
                        Divider()
                    }

                    ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(sortedItems.enumerated()), id: \.element.id) { index, item in
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
                                .onAppear {
                                    // Infinite-scroll trigger. Fires when one
                                    // of the last 10 currently-rendered rows
                                    // appears, so the next page begins
                                    // loading before the user reaches the
                                    // bottom. `vm.loadMore` is concurrency-
                                    // guarded by `isLoadingMore`, so this
                                    // can fire multiple times safely.
                                    if index >= vm.filteredItems.count - 10 {
                                        Task { await vm.loadMore() }
                                    }
                                }
                                Divider().padding(.leading, 64)
                        }

                        if !vm.reachedEnd {
                            // Bottom sentinel — surfaces a spinner while
                            // the next page is in flight AND re-arms
                            // `loadMore` on its own appearance for the
                            // case where the row-level trigger didn't
                            // fire. Gated on `reachedEnd` not
                            // `loadedCount < totalItems` because SMAPI
                            // services like Spotify lie about `total`
                            // (matches first-page count), which would
                            // hide the sentinel and freeze the list at
                            // 50 items.
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("\(vm.loadedCount) — \(L10n.loading)")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .onAppear {
                                Task { await vm.loadMore() }
                            }
                        }
                    }
                    // A-Z fast-scroll (issue #58): the index button lives in
                    // the parent header; it sets `azLetter`, observed here to
                    // scroll. `azCount` lets the header show the button only
                    // for long lists.
                    .onChange(of: vm.filteredItems.count) { _, newCount in azCount = newCount }
                    .onAppear { azCount = vm.filteredItems.count }
                    .onDisappear { azCount = 0 }
                    .onChange(of: azLetter) { _, letter in
                        guard let letter else { return }
                        scrollToLetter(letter, proxy: proxy)
                        azLetter = nil
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
        .alert(L10n.rename, isPresented: Binding(get: { vm.showRenameAlert }, set: { vm.showRenameAlert = $0 })) {
            TextField(L10n.name, text: Binding(get: { vm.renameText }, set: { vm.renameText = $0 }))
            Button(L10n.cancel, role: .cancel) {}
            Button(L10n.rename) { Task { await vm.renameSelectedItem() } }
        }
        .alert(L10n.deletePlaylist, isPresented: Binding(get: { vm.showDeleteConfirm }, set: { vm.showDeleteConfirm = $0 })) {
            Button(L10n.cancel, role: .cancel) {}
            Button(L10n.delete, role: .destructive) { Task { await vm.deletePlaylist() } }
        } message: {
            Text(L10n.confirmDeleteItem(vm.deleteItem?.title ?? ""))
        }
        // Sheet (not .alert): SwiftUI's macOS .alert is AppKit-backed
        // and renders title/message exactly once at present time, so
        // a live-updating count would not show. A custom sheet view
        // observes `vm.expansionCount` directly and re-renders as
        // recursion progresses.
        .sheet(isPresented: Binding(
            get: { vm.expansionPromptVisible },
            set: { _ in }
        )) {
            LargeAddPromptSheet(vm: vm)
        }
        // Keep `vm.group` in sync with the sidebar selection. When the
        // user changes selectedGroupID in the sidebar while a drilled-in
        // list is still on the navigation stack, SwiftUI recreates this
        // struct with the new `parentGroup` value but does NOT re-run
        // `State(wrappedValue:)`, so `vm.group` would otherwise stay
        // frozen to the group selected when the list was first pushed
        // and Play Now would send SetAVTransportURI to the wrong
        // coordinator.
        .onChange(of: parentGroup) { _, newGroup in
            vm.group = newGroup
        }
    }

    /// First-letter bucket for a title: a letter A-Z, or "#" for digits/symbols.
    private func initial(of title: String) -> String {
        guard let c = title.trimmingCharacters(in: .whitespaces).uppercased().first else { return "#" }
        return c.isLetter ? String(c) : "#"
    }

    /// Scrolls to the first item starting with `letter`, eagerly paging the
    /// list in if that letter hasn't loaded yet (bounded so a missing letter
    /// can't loop forever).
    private func scrollToLetter(_ letter: String, proxy: ScrollViewProxy) {
        Task { @MainActor in
            var guardCount = 0
            while vm.filteredItems.first(where: { initial(of: $0.title) == letter }) == nil
                    && !vm.reachedEnd && guardCount < 60 {
                await vm.loadMore()
                guardCount += 1
            }
            guard let id = vm.filteredItems.first(where: { initial(of: $0.title) == letter })?.id else { return }
            // The first scrollTo right after the list appears (or right after
            // paging) can no-op because the LazyVStack hasn't registered the
            // target row's id yet — that's the "first click does nothing,
            // second works" symptom. Retry across a few runloop ticks so the
            // jump lands on the first interaction too.
            for attempt in 0..<3 {
                if attempt == 0 {
                    proxy.scrollTo(id, anchor: .top)
                } else {
                    withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .top) }
                }
                try? await Task.sleep(nanoseconds: 60_000_000)
            }
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
                        AddToPlaylistMenu(playlists: vm.playlists, item: item) { playlistID, target in
                            Task { await vm.addToPlaylist(playlistID: playlistID, item: target) }
                        }
                    }
                }
            }
            // Add to Choragus Queue — for any addable item (a playable URI or
            // a browsable container), across every service incl. radio.
            if (item.resourceURI?.isEmpty == false) || item.isContainer {
                Divider()
                AddToChoragusQueueMenu(item: item, manager: sonosManager)
            }
            if item.isContainer {
                Divider()
                Button(L10n.browse) {
                    onNavigate(smapiDestination(title: item.title, objectID: item.objectID))
                }
            }
            // Favourites rename in place via the same `UpdateObject`
            // title swap the playlist rename uses (#75). Gated to rows
            // inside the favourites container so the action can't be
            // offered for a service row that only looks like one.
            if objectID == BrowseID.favorites && item.objectID.hasPrefix("FV:2/") {
                Divider()
                Button(L10n.rename) {
                    vm.renameItem = item
                    vm.renameText = item.title
                    vm.showRenameAlert = true
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
        #if DEBUG
        AddToTestFixturesMenuItem(item: item)
        #endif
    }

    private func smapiDestination(title: String, objectID: String) -> BrowseDestination {
        if vm.isSMAPI, let sid = smapiServiceID, let uri = smapiServiceURI {
            // Child objectIDs from `smapiItemToBrowseItem` already carry a
            // `smapi:<sid>:` stamp. Prepending the canonical `SMAPI:<sid>:`
            // double-prefixes, `BrowseViewModel.smapiItemID` fails to unwrap,
            // and Plex rejects ids like `smapi:212:library:section:17` with
            // `Client.ItemNotFound`. Strip the existing prefix first.
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
    @Environment(SonosManager.self) private var sonosManager
    @EnvironmentObject var playlistScanner: PlaylistServiceScanner
    let item: BrowseItem
    @State private var resolvedArtURL: URL?
    @State private var didAttemptArtLoad = false

    private var sourceLabel: String? {
        sonosManager.serviceLabel(for: item)
    }

    /// "(S1)" / "(S2)" / "(S1/S2)" for a library share root, shown only when
    /// more than one Sonos system is on the network. nil for everything else.
    private var shareAvailabilityNote: String? {
        guard item.objectID.hasPrefix("S:") else { return nil }
        return sonosManager.availabilityNote(forShareObjectID: item.objectID)
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
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.body)
                        .lineLimit(1)
                    if let note = shareAvailabilityNote {
                        Text(note)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

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

            if item.isContainer && !item.isStation {
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
        let loader = BrowseItemArtLoader(sonosManager: sonosManager, localArt: sonosManager.enricher)
        resolvedArtURL = loader.checkCache(item: item)
    }

    private func loadMissingArt() async {
        let loader = BrowseItemArtLoader(sonosManager: sonosManager, localArt: sonosManager.enricher)
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
    @Environment(SonosManager.self) private var sonosManager
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
                .background(isSelected ? sonosManager.themeAccent : Color.secondary.opacity(0.15), in: Capsule())
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
    @Environment(SonosManager.self) private var sonosManager
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
    @State private var sortOrder: BrowseSortOption = .relevance
    @State private var throttleSnapshot: ITunesRateLimiter.Snapshot?
    @State private var bulkActionInFlight = false

    private static let cooldownTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    private var currentLevel: AMLevel { navStack.last ?? .search }

    private var sortedItems: [BrowseItem] { sortOrder.apply(items) }

    var body: some View {
        VStack(spacing: 0) {
            // Header with back button for drill-down levels
            if !navStack.isEmpty {
                BrowseBackBar(title: levelTitle) {
                    // The render-time emptiness check above does not cover
                    // the action: a double-tap delivers the second press to a
                    // button from the previous frame after the first pop
                    // already emptied the stack — removeLast() then traps.
                    if !navStack.isEmpty { navStack.removeLast() }
                }

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

                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)

                Divider()
            }

            // Sort picker — shown at the search level once results exist
            // and on every drill-down level (artist's albums, album's
            // tracks), so the sort order survives drill-down.
            if !items.isEmpty {
                BrowseSortPicker(items: items, selection: $sortOrder)
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
                ProgressView(navStack.isEmpty ? L10n.searchingAppleMusic : L10n.loading)
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

    /// Tracks that the bulk action bar can play directly. Tracks pass
    /// as-is; albums expand to their tracks via iTunes /lookup only when
    /// Play All / Add All is pressed, since each lookup costs a
    /// rate-limiter slot.
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
        BrowseBulkActionBar(count: items.count, inFlight: bulkActionInFlight,
                            playAll: { Task { await appleMusicPlayAllNow() } },
                            addAll: { Task { await appleMusicAddAll(playNext: false) } },
                            playNext: { Task { await appleMusicAddAll(playNext: true) } })
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
                for k in itemsCache.keys where k > navStack.count { itemsCache.removeValue(forKey: k) }
                navStack.append(.artistAlbums(artistId: artistId, artistName: item.title))
                // Sensible default for an artist's discography: newest
                // first. "Relevance" has no meaning for albums under
                // a single artist; users typically want the most
                // recent release at the top.
                sortOrder = .newest
            }
        case .musicAlbum:
            if let collectionId = Int(item.objectID.replacingOccurrences(of: "apple:album:", with: "")) {
                itemsCache[navStack.count] = items
                for k in itemsCache.keys where k > navStack.count { itemsCache.removeValue(forKey: k) }
                navStack.append(.albumTracks(collectionId: collectionId, albumTitle: item.title))
                // Tracks within an album: leave at relevance — the
                // iTunes API returns them in track-number order
                // already, which is what the user expects.
                sortOrder = .relevance
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
                Button(L10n.browse) {
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
        #if DEBUG
        AddToTestFixturesMenuItem(item: item)
        #endif
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
    @Environment(SonosManager.self) private var sonosManager
    let group: SonosGroup?

    @State private var tab: TuneInTab = .browse
    @State private var searchText = ""
    @State private var sortOrder: BrowseSortOption = .relevance
    @State private var items: [BrowseItem] = []
    @State private var isLoading = false
    @State private var hasSearched = false
    @State private var navStack: [TuneInLevel] = []
    @State private var itemsCache: [Int: [BrowseItem]] = [:] // depth → items

    var body: some View {
        VStack(spacing: 0) {
            // Back button for drill-down
            if !navStack.isEmpty {
                BrowseBackBar(title: navStack.last?.title ?? "") {
                    if !navStack.isEmpty { navStack.removeLast() }
                }

                Divider()
            }

            // Tab picker + search (only at root level)
            if navStack.isEmpty {
                VStack(spacing: 8) {
                    Picker("", selection: $tab) {
                        ForEach(TuneInTab.allCases, id: \.self) { t in
                            Text(t == .browse ? L10n.browse : L10n.search).tag(t)
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
                ProgressView(tab == .search ? L10n.searching : L10n.loading)
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
                BrowseSortPicker(items: items, selection: $sortOrder)
                Divider()
                List(sortOrder.apply(items)) { item in
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
                            #if DEBUG
                            AddToTestFixturesMenuItem(item: item)
                            #endif
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
            // Invalidate cached deeper levels — they belong to a sibling
            // path the user previously drilled into, and reusing them now
            // would show the wrong sub-folder (and SMAPI Browse on stale
            // objectIDs returns 701 No Such Object).
            for k in itemsCache.keys where k > navStack.count {
                itemsCache.removeValue(forKey: k)
            }
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
    @Environment(SonosManager.self) private var sonosManager
    @EnvironmentObject var smapiManager: SMAPIAuthManager
    let group: SonosGroup?

    private enum Tab: CaseIterable { case browse, search
        var label: String { self == .browse ? L10n.browse : L10n.search }
    }

    @State private var categories: [ServiceSearchProvider.CalmRadioCategory] = []
    @State private var isLoading = true
    @State private var tab: Tab = .browse
    @State private var openGenre: ServiceSearchProvider.CalmRadioCategory?
    @State private var searchText = ""
    @State private var searchResults: [BrowseItem] = []
    @State private var hasSearched = false
    @State private var sortOrder: BrowseSortOption = .relevance

    /// Genres as rows: one level above the channels, same chrome as any
    /// other service's root menu. Built once per fetch: `BrowseItem`
    /// mints a fresh identity per instance, so rebuilding per body
    /// evaluation would re-identify every row.
    @State private var genreRows: [BrowseItem] = []

    private var allChannels: [BrowseItem] { categories.flatMap(\.channels) }

    private var visibleItems: [BrowseItem] {
        if let openGenre { return openGenre.channels }
        return tab == .search ? searchResults : genreRows
    }

    var body: some View {
        VStack(spacing: 0) {
            if let openGenre {
                BrowseBackBar(title: openGenre.name) { self.openGenre = nil }
                Divider()
            } else {
                VStack(spacing: 8) {
                    Picker("", selection: $tab) {
                        ForEach(Tab.allCases, id: \.self) { t in
                            Text(t.label).tag(t)
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
                                TextField(L10n.searchServicePlaceholder("Calm Radio"), text: $searchText)
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

            if isLoading {
                ProgressView(L10n.loadingCalmRadio)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if categories.isEmpty {
                emptyState("leaf", L10n.noChannelsAvailable)
            } else if tab == .search, openGenre == nil, !hasSearched {
                emptyState("magnifyingglass", L10n.searchForRadioStations)
            } else if visibleItems.isEmpty {
                emptyState("magnifyingglass", L10n.noResultsFound)
            } else {
                BrowseSortPicker(items: visibleItems, selection: $sortOrder)
                Divider()
                List(sortOrder.apply(visibleItems)) { item in
                    BrowseItemRow(item: item)
                        .contentShape(Rectangle())
                        .onTapGesture { handleTap(item) }
                        .contextMenu { contextMenuItems(for: item) }
                }
                .listStyle(.plain)
            }
        }
        .onAppear {
            Task {
                let sn = smapiManager.serialNumber(for: ServiceID.calmRadio)
                categories = await ServiceSearchProvider.shared.browseCalmRadio(sn: sn)
                genreRows = categories.map {
                    BrowseItem(id: "calm:genre:\($0.id)", title: $0.name, itemClass: .container)
                }
                isLoading = false
            }
        }
    }

    private func emptyState(_ symbol: String, _ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.title).foregroundStyle(.secondary)
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Search runs over every channel of every genre; the API returns
    /// the whole catalogue in one call, so it is a local match on title
    /// and genre name.
    private func performSearch() {
        let needle = searchText.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return }
        hasSearched = true
        searchResults = categories.flatMap { cat in
            cat.channels.filter {
                $0.title.localizedCaseInsensitiveContains(needle)
                    || cat.name.localizedCaseInsensitiveContains(needle)
            }
        }
    }

    private func handleTap(_ item: BrowseItem) {
        // A channel row is classed as a station, which counts as a
        // container; its stream URI is what marks it playable.
        if let uri = item.resourceURI, !uri.isEmpty {
            if let group = group {
                Task { try? await sonosManager.playBrowseItem(item, in: group) }
            }
        } else if let genre = categories.first(where: { "calm:genre:\($0.id)" == item.objectID }) {
            openGenre = genre
        }
    }

    @ViewBuilder
    private func contextMenuItems(for item: BrowseItem) -> some View {
        if let group = group, let uri = item.resourceURI, !uri.isEmpty {
            Button(L10n.playNow) {
                Task { try? await sonosManager.playBrowseItem(item, in: group) }
            }
            // A radio stream plays on the transport; it cannot sit in
            // the queue, so no queue actions — the same rule the local
            // library list applies to radio rows.
            if !URIPrefix.isRadio(uri) {
                Button(L10n.playNext) {
                    Task { try? await sonosManager.addBrowseItemToQueue(item, in: group, playNext: true) }
                }
                Button(L10n.addToQueue) {
                    Task { try? await sonosManager.addBrowseItemToQueue(item, in: group) }
                }
            }
            #if DEBUG
            AddToTestFixturesMenuItem(item: item)
            #endif
        } else if item.isContainer {
            Button(L10n.browse) { handleTap(item) }
        }
    }
}

// MARK: - Suno (public AI-song links)

/// Paste a public suno.com link (share `…/s/<code>` or song `…/song/<uuid>`)
/// and play it on the selected group. Suno isn't a Sonos service — the link
/// resolves to a direct CDN MP3 that plays via the queue-based HTTP-get path
/// (`BrowsePlaybackStrategy.directHTTPSQueue`). Public songs only; no sign-in.
struct SunoSearchView: View {
    @Environment(SonosManager.self) private var sonosManager
    let group: SonosGroup?

    @State private var linkText = ""
    @State private var isResolving = false
    @State private var resolved: BrowseItem?
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "link")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                TextField(L10n.pasteSunoLink, text: $linkText)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .onSubmit { submit() }
                if !linkText.isEmpty {
                    Button {
                        linkText = ""
                        errorText = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Button(action: submit) {
                    if isResolving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(L10n.play)
                    }
                }
                .disabled(linkText.trimmingCharacters(in: .whitespaces).isEmpty || isResolving || group == nil)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }

            Divider()

            if let item = resolved {
                List {
                    BrowseItemRow(item: item)
                        .contentShape(Rectangle())
                        .onTapGesture { play(item) }
                        .contextMenu {
                            if let group = group {
                                Button(L10n.playNow) { play(item) }
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
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text(L10n.pasteSunoLinkHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            }
        }
    }

    private func submit() {
        let input = linkText.trimmingCharacters(in: .whitespaces)
        guard !input.isEmpty, let group = group, !isResolving else { return }
        errorText = nil
        isResolving = true
        Task {
            do {
                let item = try await SunoResolver.resolve(input)
                await MainActor.run {
                    resolved = item
                    isResolving = false
                }
                try? await sonosManager.playBrowseItem(item, in: group)
            } catch {
                await MainActor.run {
                    errorText = L10n.sunoLinkUnreadable
                    isResolving = false
                }
            }
        }
    }

    private func play(_ item: BrowseItem) {
        guard let group = group else { return }
        Task { try? await sonosManager.playBrowseItem(item, in: group) }
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
    @Environment(SonosManager.self) private var sonosManager
    @EnvironmentObject var smapiManager: SMAPIAuthManager
    let group: SonosGroup?
    let serviceID: Int
    let serviceName: String

    @State private var tab: SMAPIServiceTab = .browse
    @State private var searchText = ""
    @State private var categories: [SMAPISearchCategoryItem] = []
    @State private var selectedCategory: SMAPISearchCategoryItem?
    /// Categories the service lists but has been observed not to answer
    /// (`SMAPISearchCategories.recordFanOut`); kept out of the chips only.
    @State private var hiddenCategoryIDs: Set<String> = []
    @State private var items: [BrowseItem] = []
    @State private var isLoading = false
    @State private var hasSearched = false
    @State private var navStack: [SMAPISearchLevel] = []
    @State private var categoriesLoaded = false
    @State private var itemsCache: [Int: [BrowseItem]] = [:]
    // Browse and search share navStack/itemsCache (search clears them), so the
    // root content of each tab is kept separately — otherwise switching back to
    // Browse after a search shows the stale search results.
    @State private var browseRootItems: [BrowseItem] = []
    @State private var searchRootItems: [BrowseItem] = []
    @State private var sortOrder: BrowseSortOption = .relevance
    /// Transient playback-failure banner. Clears itself after 4 s so the
    /// user sees the reason (e.g. Plex SMAPI rejection) without needing
    /// to open the log.
    @State private var playError: String?

    private var sortedItems: [BrowseItem] { sortOrder.apply(items) }

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
                BrowseBackBar(title: navStack.last?.title ?? "") {
                    if !navStack.isEmpty { navStack.removeLast() }
                }

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
                            Text(t == .browse ? L10n.browse : L10n.search).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .onChange(of: tab) {
                        // Each tab returns to its own root on switch; drill-down
                        // is per-visit (browse & search share navStack/itemsCache).
                        // The cache must go too: `onChange(of: navStack)` fires
                        // AFTER this closure, and a surviving itemsCache[0] from
                        // the other tab would be restored over the root set below.
                        navStack.removeAll()
                        itemsCache.removeAll()
                        switch tab {
                        case .browse:
                            items = browseRootItems
                            loadBrowseRootIfNeeded()
                        case .search:
                            items = searchRootItems
                        }
                    }

                    if tab == .search {
                        // Chips that wrap: a segmented control overflows the
                        // panel at seven or more categories.
                        if visibleCategories.count > 1 {
                            FlowLayout(spacing: 6) {
                                ForEach(visibleCategories) { cat in
                                    FilterChip(label: cat.title, isSelected: selectedCategory == cat) {
                                        selectedCategory = cat
                                    }
                                }
                            }
                            .padding(.horizontal, 12)
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
                    if !navStack.isEmpty { return L10n.loading }
                    return tab == .search ? L10n.searchingServiceFormat(serviceName) : L10n.loadingServiceFormat(serviceName)
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
                BrowseSortPicker(items: items, selection: $sortOrder)
                Divider()

                List(sortedItems) { item in
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
                    items = await ServiceSearchProvider.shared.pagedBrowseSMAPI(
                        id: level.containerID, serviceID: serviceID,
                        serviceURI: uri, token: token, sn: sn,
                        generation: group?.systemVersion ?? .unknown)
                    isLoading = false
                }
            }
        }
        .onAppear {
            loadBrowseRootIfNeeded()
            guard !categoriesLoaded else { return }
            categoriesLoaded = true
            // Load cached categories immediately for instant UI. The
            // cache is shared with the agent server, which needs the same
            // per-service ids to search at all.
            hiddenCategoryIDs = SMAPISearchCategories.emptySearchIDs(serviceID: serviceID)
            let cached = SMAPISearchCategories.cached(serviceID: serviceID)
            if !cached.isEmpty {
                categories = [SMAPISearchCategoryItem(id: "all", title: L10n.all)]
                    + cached.map { SMAPISearchCategoryItem(id: $0.id, title: $0.title) }
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
                    let newCats = [SMAPISearchCategoryItem(id: "all", title: L10n.all)]
                        + discovered.map { SMAPISearchCategoryItem(id: $0.id, title: $0.title) }
                    if newCats.map(\.id) != categories.map(\.id) {
                        categories = newCats
                        if selectedCategory == nil || !newCats.contains(where: { $0.id == selectedCategory?.id }) {
                            selectedCategory = newCats.first
                        }
                    }
                    // Cache for next time
                    SMAPISearchCategories.store(discovered, serviceID: serviceID)
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
        guard tab == .browse, navStack.isEmpty, browseRootItems.isEmpty, !isLoading else { return }
        isLoading = true
        Task {
            guard let (token, uri, sn) = serviceCredentials() else {
                isLoading = false
                return
            }
            let loaded = await ServiceSearchProvider.shared.browseSMAPI(
                id: BrowseID.smapiRoot, serviceID: serviceID,
                serviceURI: uri, token: token, sn: sn,
                generation: group?.systemVersion ?? .unknown)
            browseRootItems = loaded
            // Paint only if the Browse root is still on screen — the user may
            // have switched tab or drilled down while the fetch ran.
            if tab == .browse, navStack.isEmpty {
                items = loaded
                itemsCache[0] = loaded
            }
            isLoading = false
        }
    }

    /// The chips: every listed category except those observed empty.
    /// The "All" fan-out still queries the hidden ones so they can return.
    private var visibleCategories: [SMAPISearchCategoryItem] {
        categories.filter { !hiddenCategoryIDs.contains($0.id) }
    }

    private func setDefaultCategories() {
        categories = [
            SMAPISearchCategoryItem(id: "all", title: L10n.all),
            SMAPISearchCategoryItem(id: "track", title: L10n.tracksTitle),
            SMAPISearchCategoryItem(id: "artist", title: L10n.artists),
            SMAPISearchCategoryItem(id: "album", title: L10n.albumsTitle),
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
        // A station row plays whole; drilling into it shows only the
        // station's current track, which cannot be played on its own.
        if let uri = item.resourceURI, !uri.isEmpty, !item.isContainer || item.isStation {
            if let group = group {
                Task {
                    do {
                        try await sonosManager.playBrowseItem(item, in: group)
                    } catch {
                        sonosDebugLog("[SMAPI_SEARCH] Play failed for \(item.title): \(error). uri=\(uri)")
                        showPlayError(L10n.couldNotStartPlaybackFormat(error.localizedDescription))
                    }
                }
            }
        } else if item.isContainer {
            drillInto(item)
        }
    }

    /// Opens a container's level. Unclassed station rows play on tap but
    /// stay browsable from their menu, so what the service returns inside
    /// them is inspectable.
    private func drillInto(_ item: BrowseItem) {
        itemsCache[navStack.count] = items
        for k in itemsCache.keys where k > navStack.count { itemsCache.removeValue(forKey: k) }
        let containerID = SMAPIPrefix.strip(item.objectID, serviceID: serviceID)
        navStack.append(SMAPISearchLevel(title: item.title, containerID: containerID))
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

    /// Top-of-list bulk actions, same layout and copy as
    /// PlexDirectBrowseView and the other browse views.
    private var smapiBulkActionBar: some View {
        BrowseBulkActionBar(count: items.count,
                            playAll: { Task { await smapiPlayAllNow() } },
                            addAll: { Task { await smapiAddAllToQueue(playNext: false) } },
                            playNext: { Task { await smapiAddAllToQueue(playNext: true) } })
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
                    let kids = await ServiceSearchProvider.shared.pagedBrowseSMAPI(
                        id: id, serviceID: serviceID,
                        serviceURI: uri, token: token, sn: sn,
                        generation: group?.systemVersion ?? .unknown)
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
        guard !tracks.isEmpty else { showPlayError(L10n.nothingToPlayInThisList); return }
        do {
            try await sonosManager.playItemsReplacingQueue(tracks, in: group)
        } catch {
            showPlayError(L10n.couldNotPlayAllFormat(error.localizedDescription))
        }
    }

    private func smapiAddAllToQueue(playNext: Bool) async {
        guard let group = group else { return }
        let tracks = await smapiCollectTracks()
        guard !tracks.isEmpty else { showPlayError(L10n.nothingToAdd); return }
        do {
            _ = try await sonosManager.addBrowseItemsToQueue(tracks, in: group, playNext: playNext)
        } catch {
            showPlayError(L10n.couldNotAddAllFormat(error.localizedDescription))
        }
    }

    @ViewBuilder
    private func contextMenuItems(for item: BrowseItem) -> some View {
        if let group = group {
            let isAlbum = item.itemClass == .musicAlbum || (item.isContainer && item.objectID.contains("album"))
            let isPlayable = item.resourceURI != nil
            // A station (Amazon album / playlist / artist station, or a
            // classed station on any radio scheme): plays whole on the
            // transport, cannot be queued row by row.
            let playsAsStation = item.isStation
                || (item.resourceURI?.hasPrefix(URIPrefix.sonosApiRadio) ?? false)

            if playsAsStation {
                Button(L10n.playNow) {
                    Task { await playContainer(item, in: group) }
                }
                // A classed station has no level beneath it.
                if item.isContainer && !item.isStation {
                    Divider()
                    Button(L10n.browse) { drillInto(item) }
                }
            } else if isAlbum {
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
                Button(L10n.browse) {
                    handleTap(item)
                }
            } else if item.isContainer {
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
                Button(L10n.browse) { handleTap(item) }
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
        #if DEBUG
        AddToTestFixturesMenuItem(item: item)
        #endif
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
        let tracks = await ServiceSearchProvider.shared.pagedBrowseSMAPI(
            id: containerID, serviceID: serviceID, serviceURI: uri, token: token, sn: sn,
            maxItems: 10_000, generation: group.systemVersion)
        let playable = tracks.filter { $0.resourceURI != nil && !$0.isContainer }
        guard !playable.isEmpty else {
            showPlayError(L10n.noPlayableTracksInFormat(container.title))
            return
        }
        do {
            try await sonosManager.addBrowseItemsToQueue(playable, in: group, playNext: playNext)
        } catch {
            sonosDebugLog("[SMAPI_SEARCH] enqueueContainer (track-by-track) failed: \(error). first URI=\(playable.first?.resourceURI ?? "nil")")
            showPlayError(L10n.couldNotAddAllFormat(error.localizedDescription))
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
        let tracks = await ServiceSearchProvider.shared.pagedBrowseSMAPI(
            id: containerID, serviceID: serviceID, serviceURI: uri, token: token, sn: sn,
            maxItems: 10_000, generation: group.systemVersion)
        let playable = tracks.filter { $0.resourceURI != nil && !$0.isContainer }
        guard !playable.isEmpty else {
            showPlayError(L10n.noPlayableTracksInFormat(container.title))
            return
        }
        do {
            try await sonosManager.playItemsReplacingQueue(playable, in: group)
        } catch {
            sonosDebugLog("[SMAPI_SEARCH] playContainer (track-by-track) failed: \(error). first URI=\(playable.first?.resourceURI ?? "nil")")
            showPlayError(L10n.couldNotStartPlaybackFormat(error.localizedDescription))
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
            let results: [BrowseItem]
            if searchID == "all" {
                let realCategories = categories.filter { $0.id != "all" && $0.id != "playlist" }
                let categoriesToSearch = realCategories.isEmpty
                    ? [("track", 20), ("album", 10), ("artist", 5)]
                    : realCategories.map { ($0.id, $0.id == "track" ? 20 : ($0.id == "album" ? 10 : 5)) }

                var counts: [String: Int] = [:]
                results = await withTaskGroup(of: (String, [BrowseItem]).self) { group in
                    for (catID, limit) in categoriesToSearch {
                        group.addTask {
                            (catID, await ServiceSearchProvider.shared.searchSMAPI(
                                term: query, searchID: catID, serviceID: self.serviceID,
                                serviceURI: uri, token: token, sn: sn, count: limit,
                                generation: self.group?.systemVersion ?? .unknown))
                        }
                    }
                    var all: [BrowseItem] = []
                    for await (catID, batch) in group {
                        counts[catID] = batch.count
                        all.append(contentsOf: batch)
                    }
                    return all
                }
                // Every category answered the same term: record which
                // ones the service lists but leaves empty, and drop
                // them from the chips.
                SMAPISearchCategories.recordFanOut(serviceID: serviceID, counts: counts)
                hiddenCategoryIDs = SMAPISearchCategories.emptySearchIDs(serviceID: serviceID)
            } else {
                results = await ServiceSearchProvider.shared.searchSMAPI(
                    term: query, searchID: searchID, serviceID: serviceID,
                    serviceURI: uri, token: token, sn: sn,
                    generation: group?.systemVersion ?? .unknown)
            }
            searchRootItems = results
            // Paint only if the Search tab is still on screen — the user may
            // have switched to Browse while the search ran.
            if tab == .search, navStack.isEmpty {
                items = results
                itemsCache[0] = results
            }
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


// MARK: - Large-Add Prompt Sheet

/// Modal sheet that pops up once a recursive container expansion
/// crosses the large-add threshold. Recursion continues in the
/// background while this sheet is visible — the count label re-renders
/// every time `vm.expansionCount` changes (driven by `@Observable`).
/// "Add All" is disabled until the walk completes, so the user can
/// only confirm against a final count, not a moving target. Cancel is
/// always enabled so the user can short-circuit a runaway expansion.
private struct LargeAddPromptSheet: View {
    @Bindable var vm: BrowseViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                if vm.expansionInProgress {
                    ProgressView().scaleEffect(0.7)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                Text(headerText)
                    .font(.headline)
            }

            Text(bodyText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(L10n.cancel, role: .cancel) {
                    vm.cancelExpansion()
                }
                .keyboardShortcut(.cancelAction)
                Button(L10n.addAll) {
                    vm.confirmExpansion()
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.expansionInProgress)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var headerText: String {
        if vm.expansionInProgress {
            return L10n.largeAddBuildingTitle(vm.expansionCount)
        }
        return L10n.largeAddReadyTitle(vm.expansionCount)
    }

    private var bodyText: String {
        if vm.expansionInProgress {
            return L10n.largeAddBuildingBody
        }
        return L10n.largeAddReadyBody
    }
}

/// Isolated submenu so a hover/scroll-driven re-render of the parent
/// `BrowseListView` doesn't rebuild the open playlist submenu (visible
/// as flicker on hover). Only this body re-runs when `playlists` or
/// `item` changes, and neither changes during hover.
/// Vertical A-Z fast-scroll index (issue #58). Tapping or dragging over a
/// letter calls `onSelect`. Kept compact so it overlays the list edge like
/// the native Sonos app's index.
/// A-Z fast-scroll (issue #58): a compact button that opens a grid of index
/// letters in a popover; picking one jumps to that section and dismisses.
private struct AZIndexBar: View {
    @Environment(SonosManager.self) private var sonosManager
    let onSelect: (String) -> Void
    @State private var showGrid = false
    private let letters: [String] = ["#"] + (65...90).map { String(UnicodeScalar($0)!) }
    private let columns = Array(repeating: GridItem(.fixed(38), spacing: 6), count: 5)

    var body: some View {
        Button { showGrid = true } label: {
            Text("A–Z")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(.separator, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(L10n.jumpToLetter)
        .popover(isPresented: $showGrid, arrowEdge: .trailing) {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(letters, id: \.self) { letter in
                    Button {
                        onSelect(letter)
                        showGrid = false
                    } label: {
                        Text(letter)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .frame(width: 38, height: 38)
                            .background(sonosManager.themeAccent.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
                            .foregroundStyle(sonosManager.themeAccent)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
        }
    }
}

private struct AddToPlaylistMenu: View {
    let playlists: [BrowseItem]
    let item: BrowseItem
    let onSelect: (String, BrowseItem) -> Void

    var body: some View {
        Menu(L10n.addToPlaylistMenu) {
            ForEach(playlists) { playlist in
                Button(playlist.title) {
                    onSelect(playlist.objectID, item)
                }
            }
        }
    }
}
