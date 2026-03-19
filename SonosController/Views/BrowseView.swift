/// BrowseView.swift — Content browsing panel (library, favorites, playlists, radio).
///
/// Uses a NavigationStack with BrowseDestination values for drill-down into the
/// Sonos content tree. Search works by appending a SEARCH: prefixed destination
/// that triggers parallel artist/album/track searches in BrowseListView.
import SwiftUI
import SonosKit

struct BrowseView: View {
    @EnvironmentObject var sonosManager: SonosManager
    let group: SonosGroup?

    @State private var searchText = ""
    @State private var navigationPath: [BrowseDestination] = []

    var body: some View {
        VStack(spacing: 0) {
            // Search bar — always visible at top
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search library...", text: $searchText)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        submitSearch()
                    }
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            NavigationStack(path: $navigationPath) {
                BrowseSectionsView(group: group, navigationPath: $navigationPath)
                    .navigationDestination(for: BrowseDestination.self) { destination in
                        BrowseListView(
                            title: destination.title,
                            objectID: destination.objectID,
                            group: group,
                            navigationPath: $navigationPath
                        )
                        .environmentObject(sonosManager)
                    }
            }
        }
    }

    private func submitSearch() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        navigationPath.append(BrowseDestination(
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
    let group: SonosGroup?
    @Binding var navigationPath: [BrowseDestination]

    @State private var isLoading = true

    var body: some View {
        List {
            if isLoading && sonosManager.browseSections.isEmpty {
                Section {
                    ProgressView("Discovering content...")
                }
            }

            if !sonosManager.browseSections.isEmpty {
                Section("Library & Favorites") {
                    ForEach(sonosManager.browseSections) { section in
                        Button {
                            navigationPath.append(BrowseDestination(title: section.title, objectID: section.objectID))
                        } label: {
                            Label(section.title, systemImage: section.icon)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

        }
        .listStyle(.plain)
        .navigationTitle("Browse")
        .onAppear {
            Task {
                await sonosManager.loadBrowseSections()
                isLoading = false
            }
        }
    }
}

/// Displays items for a single level of the browse tree, with pagination and context menus
struct BrowseListView: View {
    @EnvironmentObject var sonosManager: SonosManager
    let title: String
    let objectID: String
    let group: SonosGroup?
    @Binding var navigationPath: [BrowseDestination]

    @State private var items: [BrowseItem] = []
    @State private var totalItems = 0
    @State private var isLoading = true
    @State private var loadedCount = 0
    @State private var errorMessage: String?

    private let pageSize = 100
    private var isSearch: Bool { objectID.hasPrefix("SEARCH:") }

    var body: some View {
        Group {
            if isLoading && items.isEmpty {
                ProgressView("Loading...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage, items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("Empty")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(items) { item in
                        if item.isContainer {
                            NavigationLink(value: BrowseDestination(title: item.title, objectID: item.id)) {
                                BrowseItemRow(item: item)
                            }
                            .contextMenu {
                                contextMenuItems(for: item)
                            }
                        } else if item.requiresService {
                            BrowseItemRow(item: item)
                                .opacity(0.5)
                                .overlay(alignment: .trailing) {
                                    Text("Requires Sonos app")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                        .padding(.trailing, 8)
                                }
                        } else {
                            BrowseItemRow(item: item)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    handleTap(item)
                                }
                                .contextMenu {
                                    contextMenuItems(for: item)
                                }
                        }
                    }

                    if loadedCount < totalItems {
                        Button("Load more (\(loadedCount) of \(totalItems))...") {
                            Task { await loadMore() }
                        }
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(.secondary)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(title)
        .toolbar {
            if let group = group {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Play All") {
                            Task { await playContainer(in: group) }
                        }
                        Button("Add All to Queue") {
                            Task { await addContainerToQueue(in: group) }
                        }
                        Divider()
                        Button("Refresh") {
                            Task { await loadItems() }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .onAppear {
            Task { await loadItems() }
        }
    }

    @ViewBuilder
    private func contextMenuItems(for item: BrowseItem) -> some View {
        if let group = group {
            if item.isPlayable {
                Button("Play Now") {
                    Task { await play(item, in: group) }
                }
                Button("Play Next") {
                    Task { await addToQueue(item, in: group, playNext: true) }
                }
                Button("Add to Queue") {
                    Task { await addToQueue(item, in: group) }
                }
            }
            if item.isContainer {
                Divider()
                Button("Browse") {
                    navigationPath.append(BrowseDestination(title: item.title, objectID: item.id))
                }
            }
        }
    }

    private func handleTap(_ item: BrowseItem) {
        if item.isContainer {
            navigationPath.append(BrowseDestination(title: item.title, objectID: item.id))
        } else if let group = group {
            Task { await play(item, in: group) }
        }
    }

    private func loadItems() async {
        isLoading = true
        errorMessage = nil
        do {
            if isSearch {
                let query = String(objectID.dropFirst("SEARCH:".count))
                async let artistResults = sonosManager.search(query: query, in: "A:ALBUMARTIST", count: 20)
                async let albumResults = sonosManager.search(query: query, in: "A:ALBUM", count: 20)
                async let trackResults = sonosManager.search(query: query, in: "A:TRACKS", count: 30)

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

    private func loadMore() async {
        guard !isSearch else { return }
        do {
            let (result, _) = try await sonosManager.browse(objectID: objectID, start: loadedCount, count: pageSize)
            items.append(contentsOf: result)
            loadedCount += result.count
        } catch {
        }
    }

    private func play(_ item: BrowseItem, in group: SonosGroup) async {
        do {
            try await sonosManager.playBrowseItem(item, in: group)
        } catch {
        }
    }

    private func addToQueue(_ item: BrowseItem, in group: SonosGroup, playNext: Bool = false) async {
        do {
            try await sonosManager.addBrowseItemToQueue(item, in: group, playNext: playNext)
        } catch {
        }
    }

    private func playContainer(in group: SonosGroup) async {
        let containerItem = BrowseItem(id: objectID, title: title, itemClass: .container)
        do {
            try await sonosManager.playBrowseItem(containerItem, in: group)
        } catch {
        }
    }

    private func addContainerToQueue(in group: SonosGroup) async {
        let containerItem = BrowseItem(id: objectID, title: title, itemClass: .container)
        do {
            try await sonosManager.addBrowseItemToQueue(containerItem, in: group)
        } catch {
        }
    }
}

struct BrowseItemRow: View {
    let item: BrowseItem

    var body: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: item.albumArtURI.flatMap { URL(string: $0) })
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.body)
                    .lineLimit(1)

                if !item.artist.isEmpty || !item.album.isEmpty {
                    Text([item.artist, item.album].filter { !$0.isEmpty }.joined(separator: " — "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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
    }

}
