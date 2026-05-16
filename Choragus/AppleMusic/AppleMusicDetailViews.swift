/// AppleMusicDetailViews.swift — Drilldown screens for the MusicKit
/// Apple Music UI. Every track-list view follows the project-wide
/// pattern (BrowseView etc.): tap a row to Play Now, right-click for
/// Play Next / Add to Queue, with a Play All / Add All / Play Next
/// bulk-action bar above the list.
///
/// Navigation uses the parent `MusicKitAppleMusicView`'s manual
/// breadcrumb stack via `onNavigate(_:)` — NOT SwiftUI's
/// `NavigationStack` / `NavigationLink`, which on macOS treats the
/// MusicKit view's drill-ins as a top-level navigation context and
/// hides the rest of the browse pane.
import SwiftUI
import SonosKit
#if ENABLE_MUSICKIT && canImport(MusicKit)
import MusicKit
#endif

// MARK: - Album

struct AppleMusicAlbumDetailView: View {
    let provider: AppleMusicProvider
    let helper: AppleMusicPlayHelper
    let albumID: String
    let title: String
    let artist: String
    let artworkURL: URL?
    let onNavigate: (AppleMusicDestination) -> Void

    @State private var tracks: [AppleMusicTrack] = []
    @State private var isLoading = true
    @State private var sort: AppleMusicTrackSort = .original

    private var sortedTracks: [AppleMusicTrack] { sort.sort(tracks) }

    var body: some View {
        VStack(spacing: 0) {
            detailHeader(title: title, subtitle: artist, artwork: artworkURL,
                         circular: false, badge: "Album")
            Divider()
            HStack {
                AppleMusicBulkActionBar(tracks: sortedTracks, helper: helper)
                Spacer()
                AppleMusicSortPicker(selection: $sort)
                    .padding(.trailing, 12)
            }
            Divider()
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tracks.isEmpty {
                ContentUnavailableView("No tracks", systemImage: "music.note.list")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(sortedTracks.enumerated()), id: \.element.id) { index, track in
                            AppleMusicTrackRow(
                                track: track, helper: helper,
                                indexNumber: sort == .original ? index + 1 : nil,
                                hideSubtitle: true
                            )
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .task {
            tracks = await provider.albumTracks(albumID: albumID)
            isLoading = false
        }
    }
}

// MARK: - Artist

struct AppleMusicArtistDetailView: View {
    let provider: AppleMusicProvider
    let helper: AppleMusicPlayHelper
    let artistID: String
    let name: String
    let artworkURL: URL?
    let onNavigate: (AppleMusicDestination) -> Void

    @State private var topSongs: [AppleMusicTrack] = []
    @State private var albums: [AppleMusicAlbum] = []
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            detailHeader(title: name, subtitle: nil, artwork: artworkURL,
                         circular: true, badge: "Artist")
            Divider()
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if topSongs.isEmpty && albums.isEmpty {
                ContentUnavailableView("Nothing to show", systemImage: "music.mic")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if !topSongs.isEmpty {
                            drilldownRow(
                                title: "Top Songs", icon: "music.note",
                                count: topSongs.count,
                                preview: topSongs.first?.artworkURL,
                                destination: .trackList(title: "Top Songs", tracks: topSongs)
                            )
                        }
                        if !albums.isEmpty {
                            drilldownRow(
                                title: "Albums", icon: "square.stack",
                                count: albums.count,
                                preview: albums.first?.artworkURL,
                                destination: .albumList(title: "Albums", albums: albums)
                            )
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .task {
            async let songs = provider.artistTopSongs(artistID: artistID, limit: 50)
            async let alb = provider.artistAlbums(artistID: artistID)
            topSongs = await songs
            albums = await alb
            isLoading = false
        }
    }

    @ViewBuilder
    private func drilldownRow(title: String, icon: String, count: Int,
                              preview: URL?, destination: AppleMusicDestination) -> some View {
        Button { onNavigate(destination) } label: {
            HStack(spacing: 10) {
                if let preview {
                    AppleMusicArtworkSquare(url: preview)
                } else {
                    Image(systemName: icon)
                        .frame(width: 38, height: 38)
                        .background(Color.secondary.opacity(0.12))
                        .cornerRadius(4)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body).foregroundStyle(.primary)
                    Text("^[\(count) item](inflect: true)")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Playlist

struct AppleMusicPlaylistDetailView: View {
    let provider: AppleMusicProvider
    let helper: AppleMusicPlayHelper
    let playlistID: String
    let name: String
    let curator: String?
    let artworkURL: URL?
    let onNavigate: (AppleMusicDestination) -> Void

    @State private var tracks: [AppleMusicTrack] = []
    @State private var isLoading = true
    @State private var sort: AppleMusicTrackSort = .original

    private var sortedTracks: [AppleMusicTrack] { sort.sort(tracks) }

    var body: some View {
        VStack(spacing: 0) {
            detailHeader(title: name, subtitle: curator, artwork: artworkURL,
                         circular: false, badge: "Playlist")
            Divider()
            HStack {
                AppleMusicBulkActionBar(tracks: sortedTracks, helper: helper)
                Spacer()
                AppleMusicSortPicker(selection: $sort)
                    .padding(.trailing, 12)
            }
            Divider()
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tracks.isEmpty {
                ContentUnavailableView("Empty playlist", systemImage: "music.note.list")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(sortedTracks) { track in
                            AppleMusicTrackRow(track: track, helper: helper)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .task {
            tracks = await provider.playlistTracks(playlistID: playlistID)
            isLoading = false
        }
    }
}

// MARK: - Library list

struct AppleMusicLibraryListView: View {
    let provider: AppleMusicProvider
    let helper: AppleMusicPlayHelper
    let kind: AppleMusicDestination.LibraryListKind
    let onNavigate: (AppleMusicDestination) -> Void

    @State private var songs: [AppleMusicTrack] = []
    @State private var albums: [AppleMusicAlbum] = []
    @State private var artists: [AppleMusicArtist] = []
    @State private var playlists: [AppleMusicPlaylist] = []
    @State private var isLoading = true
    @State private var trackSort: AppleMusicTrackSort = .title
    @State private var albumSort: AppleMusicAlbumSort = .releaseOldest
    @State private var artistSort: AppleMusicArtistSort = .name
    @State private var playlistSort: AppleMusicPlaylistSort = .name

    private var sortedSongs: [AppleMusicTrack] { trackSort.sort(songs) }
    private var sortedAlbums: [AppleMusicAlbum] { albumSort.sort(albums) }
    private var sortedArtists: [AppleMusicArtist] { artistSort.sort(artists) }
    private var sortedPlaylists: [AppleMusicPlaylist] { playlistSort.sort(playlists) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if kind == .songs {
                    AppleMusicBulkActionBar(tracks: sortedSongs, helper: helper)
                } else {
                    Spacer().frame(height: 28)
                }
                Spacer()
                sortPicker.padding(.trailing, 12)
            }
            Divider()
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        switch kind {
                        case .songs:
                            ForEach(sortedSongs) { track in
                                AppleMusicTrackRow(track: track, helper: helper)
                            }
                        case .albums:
                            ForEach(sortedAlbums) { album in
                                Button {
                                    onNavigate(.album(id: album.id, title: album.title, artist: album.artist, artworkURL: album.artworkURL))
                                } label: {
                                    albumLikeRow(title: album.title, subtitle: album.artist, artwork: album.artworkURL)
                                }
                                .buttonStyle(.plain)
                                .contextMenu { albumContextMenu(album: album, helper: helper) }
                            }
                        case .artists:
                            ForEach(sortedArtists) { artist in
                                Button {
                                    onNavigate(.artist(id: artist.id, name: artist.name, artworkURL: artist.artworkURL))
                                } label: {
                                    artistLikeRow(name: artist.name, artwork: artist.artworkURL)
                                }
                                .buttonStyle(.plain)
                            }
                        case .playlists:
                            ForEach(sortedPlaylists) { playlist in
                                Button {
                                    onNavigate(.playlist(id: playlist.id, name: playlist.name,
                                                          curator: playlist.curatorName, artworkURL: playlist.artworkURL))
                                } label: {
                                    albumLikeRow(title: playlist.name, subtitle: playlist.curatorName ?? "", artwork: playlist.artworkURL)
                                }
                                .buttonStyle(.plain)
                                .contextMenu { playlistContextMenu(playlist: playlist, helper: helper) }
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .task {
            switch kind {
            case .songs: songs = await provider.librarySongs(limit: 2000)
            case .albums: albums = await provider.libraryAlbums(limit: 2000)
            case .artists: artists = await provider.libraryArtists(limit: 2000)
            case .playlists: playlists = await provider.libraryPlaylists(limit: 2000)
            }
            isLoading = false
        }
    }

    @ViewBuilder
    private var sortPicker: some View {
        switch kind {
        case .songs:     AppleMusicSortPicker(selection: $trackSort)
        case .albums:    AppleMusicSortPicker(selection: $albumSort)
        case .artists:   AppleMusicSortPicker(selection: $artistSort)
        case .playlists: AppleMusicSortPicker(selection: $playlistSort)
        }
    }

    @ViewBuilder
    private func albumLikeRow(title: String, subtitle: String, artwork: URL?) -> some View {
        HStack(spacing: 10) {
            AppleMusicArtworkSquare(url: artwork)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func artistLikeRow(name: String, artwork: URL?) -> some View {
        HStack(spacing: 10) {
            AppleMusicArtworkCircle(url: artwork)
            Text(name).font(.body).lineLimit(1)
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

// MARK: - Top-chart list views

struct AppleMusicTrackListView: View {
    let tracks: [AppleMusicTrack]
    let helper: AppleMusicPlayHelper
    @State private var sort: AppleMusicTrackSort = .title
    private var sortedTracks: [AppleMusicTrack] { sort.sort(tracks) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                AppleMusicBulkActionBar(tracks: sortedTracks, helper: helper)
                Spacer()
                AppleMusicSortPicker(selection: $sort).padding(.trailing, 12)
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(sortedTracks) { track in
                        AppleMusicTrackRow(track: track, helper: helper)
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }
}

struct AppleMusicAlbumListView: View {
    let albums: [AppleMusicAlbum]
    let helper: AppleMusicPlayHelper
    let onNavigate: (AppleMusicDestination) -> Void
    @State private var sort: AppleMusicAlbumSort = .releaseOldest
    private var sortedAlbums: [AppleMusicAlbum] { sort.sort(albums) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                AppleMusicSortPicker(selection: $sort).padding(.trailing, 12).padding(.vertical, 6)
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(sortedAlbums) { album in
                        Button {
                            onNavigate(.album(id: album.id, title: album.title, artist: album.artist, artworkURL: album.artworkURL))
                        } label: {
                            HStack(spacing: 10) {
                                AppleMusicArtworkSquare(url: album.artworkURL)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(album.title).font(.body).lineLimit(1)
                                    Text(formatAlbumSubtitle(album)).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu { albumContextMenu(album: album, helper: helper) }
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }
}

struct AppleMusicArtistListView: View {
    let artists: [AppleMusicArtist]
    let onNavigate: (AppleMusicDestination) -> Void
    @State private var sort: AppleMusicArtistSort = .name
    private var sortedArtists: [AppleMusicArtist] { sort.sort(artists) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                AppleMusicSortPicker(selection: $sort).padding(.trailing, 12).padding(.vertical, 6)
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(sortedArtists) { artist in
                        Button {
                            onNavigate(.artist(id: artist.id, name: artist.name, artworkURL: artist.artworkURL))
                        } label: {
                            HStack(spacing: 10) {
                                AppleMusicArtworkCircle(url: artist.artworkURL)
                                Text(artist.name).font(.body).lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }
}

struct AppleMusicPlaylistListView: View {
    let playlists: [AppleMusicPlaylist]
    let helper: AppleMusicPlayHelper
    let onNavigate: (AppleMusicDestination) -> Void
    @State private var sort: AppleMusicPlaylistSort = .name
    private var sortedPlaylists: [AppleMusicPlaylist] { sort.sort(playlists) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                AppleMusicSortPicker(selection: $sort).padding(.trailing, 12).padding(.vertical, 6)
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(sortedPlaylists) { playlist in
                        Button {
                            onNavigate(.playlist(id: playlist.id, name: playlist.name,
                                                  curator: playlist.curatorName, artworkURL: playlist.artworkURL))
                        } label: {
                            HStack(spacing: 10) {
                                AppleMusicArtworkSquare(url: playlist.artworkURL)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(playlist.name).font(.body).lineLimit(1)
                                    if let curator = playlist.curatorName, !curator.isEmpty {
                                        Text(curator).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu { playlistContextMenu(playlist: playlist, helper: helper) }
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }
}

// MARK: - Genre browsing

struct AppleMusicGenreListView: View {
    let genres: [AppleMusicGenre]
    let onNavigate: (AppleMusicDestination) -> Void

    @State private var query: String = ""
    @State private var sort: AppleMusicArtistSort = .name

    private var filtered: [AppleMusicGenre] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let list = q.isEmpty ? genres : genres.filter { $0.name.lowercased().contains(q) }
        // Reuse name sort.
        switch sort {
        case .original: return list
        case .name: return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter genres", text: $query)
                    .textFieldStyle(.plain)
                Spacer()
                AppleMusicSortPicker(selection: $sort).padding(.trailing, 12)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(filtered) { genre in
                        Button {
                            onNavigate(.genreCharts(genreID: genre.id, genreName: genre.name))
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "guitars")
                                    .frame(width: 38, height: 38)
                                    .background(Color.secondary.opacity(0.12))
                                    .cornerRadius(4)
                                Text(genre.name).font(.body)
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }
}

struct AppleMusicGenreChartsView: View {
    let provider: AppleMusicProvider
    let helper: AppleMusicPlayHelper
    let genreID: String
    let onNavigate: (AppleMusicDestination) -> Void

    @State private var browse: AppleMusicBrowse = .empty
    @State private var loading = true

    var body: some View {
        Group {
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if browse == .empty {
                ContentUnavailableView("No charts for this genre", systemImage: "guitars")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if !browse.topSongs.isEmpty {
                            sectionHeader("Top Songs")
                            AppleMusicBulkActionBar(tracks: browse.topSongs, helper: helper)
                            ForEach(browse.topSongs) { track in
                                AppleMusicTrackRow(track: track, helper: helper)
                            }
                        }
                        if !browse.topAlbums.isEmpty {
                            sectionHeader("Top Albums")
                            ForEach(browse.topAlbums) { album in
                                Button {
                                    onNavigate(.album(id: album.id, title: album.title, artist: album.artist, artworkURL: album.artworkURL))
                                } label: {
                                    HStack(spacing: 10) {
                                        AppleMusicArtworkSquare(url: album.artworkURL)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(album.title).font(.body).lineLimit(1)
                                            Text(formatAlbumSubtitle(album)).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 6)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .contextMenu { albumContextMenu(album: album, helper: helper) }
                            }
                        }
                        if !browse.topPlaylists.isEmpty {
                            sectionHeader("Top Playlists")
                            ForEach(browse.topPlaylists) { playlist in
                                Button {
                                    onNavigate(.playlist(id: playlist.id, name: playlist.name,
                                                          curator: playlist.curatorName, artworkURL: playlist.artworkURL))
                                } label: {
                                    HStack(spacing: 10) {
                                        AppleMusicArtworkSquare(url: playlist.artworkURL)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(playlist.name).font(.body).lineLimit(1)
                                            if let curator = playlist.curatorName, !curator.isEmpty {
                                                Text(curator).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                                            }
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 6)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .contextMenu { playlistContextMenu(playlist: playlist, helper: helper) }
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .task {
            browse = await provider.charts(forGenreID: genreID, limit: 25)
            loading = false
        }
    }
}

// MARK: - Stations

struct AppleMusicStationSearchView: View {
    let provider: AppleMusicProvider

    @State private var query: String = ""
    @State private var stations: [AppleMusicStation] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var isSearching = false
    @State private var didInitialLoad = false
    @State private var sort: AppleMusicStationSort = .liveFirst

    private var sortedStations: [AppleMusicStation] { sort.sort(stations) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search stations (artist, genre, mood)", text: $query)
                    .textFieldStyle(.plain)
                    .onChange(of: query) { _, newValue in scheduleSearch(newValue) }
                AppleMusicSortPicker(selection: $sort)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()
            if isSearching && stations.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if stations.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? "Search Apple Music stations" : "No stations found",
                    systemImage: "antenna.radiowaves.left.and.right",
                    description: query.isEmpty
                        ? Text("Try \"jazz\", \"pop\", \"rock\", \"chill\" or an artist name.")
                        : nil
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(sortedStations) { station in
                            HStack(spacing: 10) {
                                AppleMusicArtworkSquare(url: station.artworkURL)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(station.name).font(.body).lineLimit(1)
                                    if let curator = station.curatorName, !curator.isEmpty {
                                        Text(curator).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                if station.isLive {
                                    Text("LIVE")
                                        .font(.caption.weight(.bold))
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Color.red.opacity(0.85), in: Capsule())
                                        .foregroundStyle(.white)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .task {
            // Auto-load a default station set so the user lands on
            // something instead of an empty pane. "Apple Music"
            // matches the network's flagship stations (Music 1, Hits,
            // Country, etc.) which is a reasonable default.
            guard !didInitialLoad else { return }
            didInitialLoad = true
            isSearching = true
            stations = await provider.searchStations(query: "Apple Music", limit: 25)
            isSearching = false
        }
    }

    private func scheduleSearch(_ value: String) {
        searchTask?.cancel()
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            stations = []
            isSearching = false
            return
        }
        searchTask = Task { [provider] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            await MainActor.run { isSearching = true }
            let result = await provider.searchStations(query: trimmed, limit: 20)
            if Task.isCancelled { return }
            await MainActor.run {
                stations = result
                isSearching = false
            }
        }
    }
}

struct AppleMusicStationListView: View {
    let stations: [AppleMusicStation]

    @State private var sort: AppleMusicStationSort = .liveFirst

    private var sortedStations: [AppleMusicStation] { sort.sort(stations) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                AppleMusicSortPicker(selection: $sort).padding(.trailing, 12).padding(.vertical, 6)
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(sortedStations) { station in
                        HStack(spacing: 10) {
                            AppleMusicArtworkSquare(url: station.artworkURL)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(station.name).font(.body).lineLimit(1)
                                if let curator = station.curatorName, !curator.isEmpty {
                                    Text(curator).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            if station.isLive {
                                Text("LIVE")
                                    .font(.caption.weight(.bold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.red.opacity(0.85), in: Capsule())
                                    .foregroundStyle(.white)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }
}

// MARK: - Recommendation detail

struct AppleMusicRecommendationDetailView: View {
    let albums: [AppleMusicAlbum]
    let playlists: [AppleMusicPlaylist]
    let stations: [AppleMusicStation]
    let helper: AppleMusicPlayHelper
    let onNavigate: (AppleMusicDestination) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if !stations.isEmpty {
                    sectionHeader("Stations")
                    ForEach(stations) { station in stationRow(station) }
                }
                if !albums.isEmpty {
                    sectionHeader("Albums")
                    ForEach(albums) { album in albumNavRow(album) }
                }
                if !playlists.isEmpty {
                    sectionHeader("Playlists")
                    ForEach(playlists) { p in playlistNavRow(p) }
                }
            }
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func stationRow(_ station: AppleMusicStation) -> some View {
        HStack(spacing: 10) {
            AppleMusicArtworkSquare(url: station.artworkURL)
            VStack(alignment: .leading, spacing: 2) {
                Text(station.name).font(.body).lineLimit(1)
                if let curator = station.curatorName, !curator.isEmpty {
                    Text(curator).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if station.isLive {
                Text("LIVE")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.red.opacity(0.85), in: Capsule())
                    .foregroundStyle(.white)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func albumNavRow(_ album: AppleMusicAlbum) -> some View {
        Button {
            onNavigate(.album(id: album.id, title: album.title, artist: album.artist, artworkURL: album.artworkURL))
        } label: {
            HStack(spacing: 10) {
                AppleMusicArtworkSquare(url: album.artworkURL)
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.title).font(.body).lineLimit(1)
                    Text(formatAlbumSubtitle(album)).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { albumContextMenu(album: album, helper: helper) }
    }

    @ViewBuilder
    private func playlistNavRow(_ playlist: AppleMusicPlaylist) -> some View {
        Button {
            onNavigate(.playlist(id: playlist.id, name: playlist.name,
                                  curator: playlist.curatorName, artworkURL: playlist.artworkURL))
        } label: {
            HStack(spacing: 10) {
                AppleMusicArtworkSquare(url: playlist.artworkURL)
                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.name).font(.body).lineLimit(1)
                    if let curator = playlist.curatorName, !curator.isEmpty {
                        Text(curator).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { playlistContextMenu(playlist: playlist, helper: helper) }
    }
}

// MARK: - Shared helpers

@ViewBuilder
fileprivate func detailHeader(title: String, subtitle: String?, artwork: URL?,
                              circular: Bool, badge: String?) -> some View {
    HStack(spacing: 12) {
        if circular {
            AppleMusicArtworkCircle(url: artwork, size: 64)
        } else {
            AppleMusicArtworkSquare(url: artwork, size: 64)
        }
        VStack(alignment: .leading, spacing: 4) {
            if let badge {
                Text(badge.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(.title3.weight(.semibold))
                .lineLimit(2)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        Spacer()
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
}

fileprivate func formatAlbumSubtitle(_ album: AppleMusicAlbum) -> String {
    var parts: [String] = []
    if !album.artist.isEmpty { parts.append(album.artist) }
    if let year = AppleMusicYearFormatter.year(album.releaseDate) {
        parts.append(year)
    }
    return parts.joined(separator: " • ")
}

@ViewBuilder
fileprivate func sectionHeader(_ text: String) -> some View {
    Text(text.uppercased())
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 4)
}

struct AppleMusicArtworkSquare: View {
    let url: URL?
    var size: CGFloat = 38

    var body: some View {
        #if ENABLE_MUSICKIT && canImport(MusicKit)
        if let url, let art = MusicKitArtworkRegistry.shared.artwork(for: url) {
            ArtworkImage(art, width: size * 2)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            CachedAsyncImage(url: url, cornerRadius: 4)
                .frame(width: size, height: size)
        }
        #else
        CachedAsyncImage(url: url, cornerRadius: 4)
            .frame(width: size, height: size)
        #endif
    }
}

struct AppleMusicArtworkCircle: View {
    let url: URL?
    var size: CGFloat = 38

    var body: some View {
        #if ENABLE_MUSICKIT && canImport(MusicKit)
        if let url, let art = MusicKitArtworkRegistry.shared.artwork(for: url) {
            ArtworkImage(art, width: size * 2)
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else {
            CachedAsyncImage(url: url, cornerRadius: size / 2)
                .frame(width: size, height: size)
        }
        #else
        CachedAsyncImage(url: url, cornerRadius: size / 2)
            .frame(width: size, height: size)
        #endif
    }
}
