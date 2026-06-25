/// MusicKitAppleMusicView.swift — Apple Music browse / search surface
/// backed by the on-device MusicKit framework, replacing (or running
/// alongside) the legacy SMAPI-based AppleMusicSearchView depending on
/// the build's compilation flags.
///
/// Auth model: MusicKit grants catalog read access via the user's
/// signed-in Apple Music account — independent of Sonos's own SMAPI
/// auth which the existing SonosKit MusicServicesView already manages.
/// Playback DELIVERY to the speaker still rides on SMAPI's
/// `x-sonos-http:song:<id>.mp4` URI scheme; MusicKit only contributes
/// discovery / metadata. The MusicKit catalog ID is byte-identical to
/// the numeric ID in the SMAPI URI, so a MusicKit-discovered track
/// hands cleanly to `SonosManager.playBrowseItem`.
import SwiftUI
import SonosKit

private enum AppleMusicTab: String, CaseIterable {
    case browse = "Browse"
    case search = "Search"

    // Localized label for display; rawValue stays the stable identity.
    var displayName: String {
        switch self {
        case .browse: return L10n.amBrowse
        case .search: return L10n.search
        }
    }
}

private enum AppleMusicSearchCategory: String, CaseIterable, Hashable {
    case all = "All"
    case artists = "Artists"
    case albums = "Albums"
    case tracks = "Tracks"
    case playlists = "Playlists"

    // Localized label for display; rawValue stays the stable identity.
    var displayName: String {
        switch self {
        case .all: return L10n.all
        case .artists: return L10n.amArtists
        case .albums: return L10n.amAlbums
        case .tracks: return L10n.tracks
        case .playlists: return L10n.amPlaylists
        }
    }
}

enum AppleMusicDestination: Hashable {
    case album(id: String, title: String, artist: String, artworkURL: URL?)
    case artist(id: String, name: String, artworkURL: URL?)
    case playlist(id: String, name: String, curator: String?, artworkURL: URL?)
    case libraryList(LibraryListKind)
    case recommendation(title: String, albums: [AppleMusicAlbum], playlists: [AppleMusicPlaylist], stations: [AppleMusicStation])
    case trackList(title: String, tracks: [AppleMusicTrack])
    case albumList(title: String, albums: [AppleMusicAlbum])
    case artistList(title: String, artists: [AppleMusicArtist])
    case playlistList(title: String, playlists: [AppleMusicPlaylist])
    case genreList(genres: [AppleMusicGenre])
    case genreCharts(genreID: String, genreName: String)
    case stationSearch
    case stationList(title: String, stations: [AppleMusicStation])
    /// Paged catalog-search drill-down — pages 25 at a time by offset
    /// instead of carrying a fixed 25-item snapshot.
    case searchList(kind: AppleMusicSearchListKind, term: String, title: String)

    enum LibraryListKind: Hashable { case songs, albums, artists, playlists }
}

struct MusicKitAppleMusicView: View {
    @EnvironmentObject var sonosManager: SonosManager
    @EnvironmentObject var smapiManager: SMAPIAuthManager

    let group: SonosGroup?

    @State private var provider: AppleMusicProvider = AppleMusicProviderFactory.makeCurrent()
    @State private var authorisation: AppleMusicAuthorisation = .notDetermined
    @State private var storefront: String?
    @State private var query: String = ""
    @State private var results: AppleMusicSearchResults = .empty
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?

    @State private var browse: AppleMusicBrowse = .empty
    @State private var library: AppleMusicLibrary = .empty
    @State private var recentlyPlayed: AppleMusicRecentlyPlayed = .empty
    @State private var recommendations: [AppleMusicRecommendation] = []
    @State private var genresList: [AppleMusicGenre] = []
    @State private var spatialAudio: [AppleMusicAlbum] = []
    @State private var defaultStations: [AppleMusicStation] = []
    @State private var personalStations: [AppleMusicStation] = []
    @State private var isLoadingBrowse = false
    @State private var browseLoaded = false
    @State private var path: [AppleMusicDestination] = []
    @State private var tab: AppleMusicTab = .browse
    @State private var searchCategory: AppleMusicSearchCategory = .all
    @StateObject private var bulkTracker = AppleMusicBulkActionTracker()

    var body: some View {
        // Manual in-place stack — matches `BrowseView`'s breadcrumb
        // approach. Using `NavigationStack` here pushed detail views as
        // a top-level navigation context that took over the whole app
        // instead of staying inside the parent browse pane.
        VStack(spacing: 0) {
            if path.isEmpty {
                header
                Divider()
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let dest = path.last {
                detailBar(for: dest)
                Divider()
                destinationView(for: dest)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await refreshAuth() }
        .overlay(alignment: .bottom) { bulkProgressOverlay }
    }

    @ViewBuilder
    private var bulkProgressOverlay: some View {
        if let label = bulkTracker.inFlightLabel {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(label).font(.callout)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.secondary.opacity(0.20), lineWidth: 0.5)
            )
            .padding(.bottom, 14)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    @ViewBuilder
    private func detailBar(for dest: AppleMusicDestination) -> some View {
        Button {
            if !path.isEmpty { path.removeLast() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.medium))
                Text(destinationTitle(dest))
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func destinationTitle(_ dest: AppleMusicDestination) -> String {
        switch dest {
        case .album(_, let title, _, _): return title
        case .artist(_, let name, _): return name
        case .playlist(_, let name, _, _): return name
        case .libraryList(let kind):
            switch kind {
            case .songs: return L10n.amLibrarySongs
            case .albums: return L10n.amLibraryAlbums
            case .artists: return L10n.amLibraryArtists
            case .playlists: return L10n.amLibraryPlaylists
            }
        case .recommendation(let title, _, _, _): return title
        case .trackList(let title, _): return title
        case .albumList(let title, _): return title
        case .artistList(let title, _): return title
        case .playlistList(let title, _): return title
        case .genreList: return L10n.amGenres
        case .genreCharts(_, let name): return name
        case .stationSearch: return L10n.amRadioStations
        case .stationList(let title, _): return title
        case .searchList(_, _, let title): return title
        }
    }

    private var playHelper: AppleMusicPlayHelper {
        AppleMusicPlayHelper(
            sonosManager: sonosManager,
            smapiManager: smapiManager,
            provider: provider,
            group: group,
            tracker: bulkTracker
        )
    }

    @ViewBuilder
    private func destinationView(for dest: AppleMusicDestination) -> some View {
        let navigate: (AppleMusicDestination) -> Void = { d in path.append(d) }
        switch dest {
        case .album(let id, let title, let artist, let artwork):
            AppleMusicAlbumDetailView(
                provider: provider, helper: playHelper,
                albumID: id, title: title, artist: artist, artworkURL: artwork,
                onNavigate: navigate
            )
        case .artist(let id, let name, let artwork):
            AppleMusicArtistDetailView(
                provider: provider, helper: playHelper,
                artistID: id, name: name, artworkURL: artwork,
                onNavigate: navigate
            )
        case .playlist(let id, let name, let curator, let artwork):
            AppleMusicPlaylistDetailView(
                provider: provider, helper: playHelper,
                playlistID: id, name: name, curator: curator, artworkURL: artwork,
                onNavigate: navigate
            )
        case .libraryList(let kind):
            AppleMusicLibraryListView(
                provider: provider, helper: playHelper, kind: kind,
                onNavigate: navigate
            )
        case .recommendation(_, let albums, let playlists, let stations):
            AppleMusicRecommendationDetailView(
                albums: albums, playlists: playlists, stations: stations,
                helper: playHelper,
                onNavigate: navigate
            )
        case .trackList(_, let tracks):
            AppleMusicTrackListView(tracks: tracks, helper: playHelper)
        case .albumList(_, let albums):
            AppleMusicAlbumListView(albums: albums, helper: playHelper, onNavigate: navigate)
        case .artistList(_, let artists):
            AppleMusicArtistListView(artists: artists, onNavigate: navigate)
        case .playlistList(_, let playlists):
            AppleMusicPlaylistListView(playlists: playlists, helper: playHelper, onNavigate: navigate)
        case .genreList(let genres):
            AppleMusicGenreListView(genres: genres, onNavigate: navigate)
        case .genreCharts(let genreID, _):
            AppleMusicGenreChartsView(provider: provider, helper: playHelper,
                                      genreID: genreID, onNavigate: navigate)
        case .stationSearch:
            AppleMusicStationSearchView(provider: provider)
        case .stationList(_, let stations):
            AppleMusicStationListView(stations: stations)
        case .searchList(let kind, let term, _):
            AppleMusicSearchListView(provider: provider, helper: playHelper,
                                     kind: kind, term: term, onNavigate: navigate)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Label("Apple Music", systemImage: "music.note")
                .font(.title3.weight(.semibold))
            if let storefront, !storefront.isEmpty {
                Text("(\(storefront.uppercased()))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            authStatusBadge
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var authStatusBadge: some View {
        switch authorisation {
        case .authorised:
            Label(L10n.amConnected, systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
        case .notDetermined:
            EmptyView()
        case .denied:
            Label(L10n.amPermissionDenied, systemImage: "exclamationmark.circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.red)
        case .noSubscription:
            Label(L10n.amNoActiveSubscription, systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
        case .notApplicable:
            Label(L10n.amNotAvailableInBuild, systemImage: "xmark.circle")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch authorisation {
        case .authorised:
            authorisedContent
        case .notDetermined:
            authPrompt(.notDetermined)
        case .denied:
            authPrompt(.denied)
        case .noSubscription:
            authPrompt(.noSubscription)
        case .notApplicable:
            authPrompt(.notApplicable)
        }
    }

    @ViewBuilder
    private func authPrompt(_ state: AppleMusicAuthorisation) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "music.note.house")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text(promptTitle(state))
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(promptBody(state))
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            if state == .notDetermined {
                Button(L10n.amConnectAppleMusic) {
                    Task {
                        let result = await provider.requestAuthorisation()
                        authorisation = result
                        if result == .authorised {
                            storefront = await provider.currentStorefront()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func promptTitle(_ state: AppleMusicAuthorisation) -> String {
        switch state {
        case .notDetermined: return L10n.amConnectAppleMusic
        case .denied:        return L10n.amAccessDeniedTitle
        case .noSubscription: return L10n.amSubscriptionRequiredTitle
        case .notApplicable: return L10n.amNotAvailableTitle
        case .authorised:    return ""
        }
    }

    private func promptBody(_ state: AppleMusicAuthorisation) -> String {
        switch state {
        case .notDetermined:
            return L10n.amPromptBodyNotDetermined
        case .denied:
            return L10n.amPromptBodyDenied
        case .noSubscription:
            return L10n.amPromptBodyNoSubscription
        case .notApplicable:
            return L10n.amPromptBodyNotApplicable
        case .authorised:
            return ""
        }
    }

    // MARK: - Authorised content

    @ViewBuilder
    private var authorisedContent: some View {
        VStack(spacing: 0) {
            tabPicker
            Divider()
            switch tab {
            case .browse:
                browseContent
            case .search:
                searchContent
            }
        }
        .task(id: authorisation) {
            if authorisation == .authorised, !browseLoaded {
                await loadBrowse()
            }
        }
    }

    private var tabPicker: some View {
        Picker("", selection: $tab) {
            ForEach(AppleMusicTab.allCases, id: \.self) { t in
                Text(t.displayName).tag(t)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var searchContent: some View {
        VStack(spacing: 0) {
            searchCategoryPicker
            Divider()
            searchBar
            Divider()
            if isSearching && resultsEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if query.isEmpty {
                emptyState(L10n.amSearchAppleMusic,
                           subtitle: L10n.amSearchPrompt)
            } else if resultsEmpty {
                emptyState(L10n.amNoResults,
                           subtitle: L10n.amTryDifferentQuery)
            } else {
                resultsList
            }
        }
    }

    private var resultsEmpty: Bool {
        results.tracks.isEmpty && results.albums.isEmpty &&
        results.artists.isEmpty && results.playlists.isEmpty
    }

    private var searchCategoryPicker: some View {
        Picker("", selection: $searchCategory) {
            ForEach(AppleMusicSearchCategory.allCases, id: \.self) { c in
                Text(c.displayName).tag(c)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var browseContent: some View {
        if isLoadingBrowse && browse == .empty && library == .empty && recommendations.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    // Library — saved by the user
                    if !library.songs.isEmpty || !library.albums.isEmpty || !library.playlists.isEmpty || !library.artists.isEmpty {
                        sectionHeader(L10n.amYourLibrary)
                        libraryRow(L10n.amSongs, icon: "music.note",
                                   preview: library.songs.first?.artworkURL, kind: .songs)
                        libraryRow(L10n.amAlbums, icon: "square.stack",
                                   preview: library.albums.first?.artworkURL, kind: .albums)
                        libraryRow(L10n.amArtists, icon: "music.mic",
                                   preview: library.artists.first?.artworkURL, kind: .artists)
                        libraryRow(L10n.amPlaylists, icon: "music.note.list",
                                   preview: library.playlists.first?.artworkURL, kind: .playlists)
                    }
                    // Recently played
                    if !recentlyPlayed.albums.isEmpty || !recentlyPlayed.playlists.isEmpty {
                        sectionHeader(L10n.amRecentlyPlayed)
                        ForEach(recentlyPlayed.albums) { album in albumRow(album) }
                        ForEach(recentlyPlayed.playlists) { p in playlistRow(p) }
                    }
                    // Personal recommendations — each row drills into a
                    // dedicated detail view rather than flattening every
                    // item inline (which was producing the unscrollably
                    // long "Made for You / New Releases / etc." stack).
                    let visibleRecs = recommendations.filter { !$0.albums.isEmpty || !$0.playlists.isEmpty || !$0.stations.isEmpty }
                    if !visibleRecs.isEmpty {
                        sectionHeader(L10n.amMadeForYou)
                        ForEach(visibleRecs) { rec in
                            recommendationRow(rec)
                        }
                    }
                    // Top charts — drilldown rows so the root browse stays
                    // skimmable. Tapping each pushes a detail list view.
                    if !browse.topSongs.isEmpty || !browse.topAlbums.isEmpty || !browse.topPlaylists.isEmpty {
                        sectionHeader(L10n.amCharts)
                        if !browse.topSongs.isEmpty {
                            chartsRow(L10n.amTopSongs, icon: "music.note",
                                      preview: browse.topSongs.first?.artworkURL,
                                      destination: .trackList(title: L10n.amTopSongs, tracks: browse.topSongs))
                        }
                        if !browse.topAlbums.isEmpty {
                            chartsRow(L10n.amTopAlbums, icon: "square.stack",
                                      preview: browse.topAlbums.first?.artworkURL,
                                      destination: .albumList(title: L10n.amTopAlbums, albums: browse.topAlbums))
                        }
                        if !browse.topPlaylists.isEmpty {
                            chartsRow(L10n.amTopPlaylists, icon: "music.note.list",
                                      preview: browse.topPlaylists.first?.artworkURL,
                                      destination: .playlistList(title: L10n.amTopPlaylists, playlists: browse.topPlaylists))
                        }
                    }
                    // Browse extras — genres + radio + spatial audio.
                    sectionHeader(L10n.amBrowse)
                    if !genresList.isEmpty {
                        chartsRow(L10n.amGenres, icon: "guitars",
                                  preview: browse.topAlbums.first?.artworkURL,
                                  destination: .genreList(genres: genresList))
                    }
                    if !personalStations.isEmpty {
                        chartsRow(L10n.amStationsForYou, icon: "antenna.radiowaves.left.and.right",
                                  preview: personalStations.first?.artworkURL,
                                  destination: .stationList(title: L10n.amStationsForYou, stations: personalStations))
                    }
                    chartsRow(L10n.amRadioStations, icon: "antenna.radiowaves.left.and.right",
                              preview: defaultStations.first?.artworkURL,
                              destination: .stationSearch)
                    if !spatialAudio.isEmpty {
                        chartsRow(L10n.amNowInSpatialAudio, icon: "hifispeaker.2.fill",
                                  preview: spatialAudio.first?.artworkURL,
                                  destination: .albumList(title: L10n.amSpatialAudio, albums: spatialAudio))
                    }
                    // Empty fallback if absolutely nothing came back
                    if browse == .empty && library == .empty && recentlyPlayed == .empty && recommendations.isEmpty {
                        emptyState(L10n.amSearchAppleMusic,
                                   subtitle: L10n.amSearchCatalogPrompt)
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder
    private func chartsRow(_ title: String, icon: String,
                            preview: URL?, destination: AppleMusicDestination) -> some View {
        Button { path.append(destination) } label: {
            HStack(spacing: 10) {
                if let preview {
                    AppleMusicArtworkSquare(url: preview)
                } else {
                    Image(systemName: icon)
                        .frame(width: 38, height: 38)
                        .background(Color.secondary.opacity(0.12))
                        .cornerRadius(4)
                }
                // No item count: every browse fetch is capped, so any number
                // here would state the cap, not the catalog total.
                Text(title).font(.body).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func recommendationRow(_ rec: AppleMusicRecommendation) -> some View {
        let preview = (rec.albums.first?.artworkURL)
            ?? (rec.playlists.first?.artworkURL)
            ?? (rec.stations.first?.artworkURL)
        Button {
            path.append(AppleMusicDestination.recommendation(
                title: rec.title, albums: rec.albums, playlists: rec.playlists, stations: rec.stations
            ))
        } label: {
            HStack(spacing: 10) {
                AppleMusicArtworkSquare(url: preview)
                Text(rec.title).font(.body).lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func libraryRow(_ title: String, icon: String,
                            preview: URL?, kind: AppleMusicDestination.LibraryListKind) -> some View {
        Button { path.append(AppleMusicDestination.libraryList(kind)) } label: {
            HStack(spacing: 10) {
                if let preview {
                    if kind == .artists {
                        AppleMusicArtworkCircle(url: preview)
                    } else {
                        AppleMusicArtworkSquare(url: preview)
                    }
                } else {
                    Image(systemName: icon)
                        .frame(width: 38, height: 38)
                        .background(Color.secondary.opacity(0.12))
                        .cornerRadius(4)
                }
                // No count subtitle on library rows: the overview loads only
                // a capped preview window, not the full library, so any number
                // here would be inaccurate. The full list lives behind the row.
                Text(title).font(.body).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func loadBrowse() async {
        isLoadingBrowse = true
        async let charts = provider.topCharts(limit: 15)
        async let songs = provider.librarySongs(limit: 50)
        async let albums = provider.libraryAlbums(limit: 50)
        async let artists = provider.libraryArtists(limit: 50)
        async let playlists = provider.libraryPlaylists(limit: 50)
        async let recent = provider.recentlyPlayed(limit: 12)
        async let recs = provider.recommendations()
        async let genres = provider.genres()
        async let spatial = provider.spatialAudioAlbums(limit: 25)
        async let stations = provider.searchStations(query: "Apple Music", limit: 25)
        async let userStat = provider.userStations(limit: 25)
        let result = await (charts, songs, albums, artists, playlists, recent, recs)
        let extras = await (genres, spatial, stations, userStat)
        await MainActor.run {
            browse = result.0
            library = AppleMusicLibrary(songs: result.1, albums: result.2, artists: result.3, playlists: result.4)
            recentlyPlayed = result.5
            recommendations = result.6
            genresList = extras.0
            spatialAudio = extras.1
            defaultStations = extras.2
            personalStations = extras.3
            browseLoaded = true
            isLoadingBrowse = false
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(L10n.amSearchAppleMusic, text: $query)
                .textFieldStyle(.plain)
                .onChange(of: query) { _, newValue in
                    scheduleSearch(for: newValue)
                }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func emptyState(_ title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var resultsList: some View {
        // Category tabs page the catalog by offset (25/page) rather than
        // showing the fixed 25-item search snapshot. The snapshot still
        // drives the empty-state check so "no results" stays instant.
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        switch searchCategory {
        case .all: allResultsList
        case .tracks:
            if results.tracks.isEmpty {
                emptyState(L10n.amNoTracks, subtitle: L10n.amNoTracksMatched)
            } else {
                AppleMusicSearchListView(provider: provider, helper: playHelper,
                                         kind: .tracks, term: term) { path.append($0) }
            }
        case .albums:
            if results.albums.isEmpty {
                emptyState(L10n.amNoAlbums, subtitle: L10n.amNoAlbumsMatched)
            } else {
                AppleMusicSearchListView(provider: provider, helper: playHelper,
                                         kind: .albums, term: term) { path.append($0) }
            }
        case .artists:
            if results.artists.isEmpty {
                emptyState(L10n.amNoArtists, subtitle: L10n.amNoArtistsMatched)
            } else {
                AppleMusicSearchListView(provider: provider, helper: playHelper,
                                         kind: .artists, term: term) { path.append($0) }
            }
        case .playlists:
            if results.playlists.isEmpty {
                emptyState(L10n.amNoPlaylists, subtitle: L10n.amNoPlaylistsMatched)
            } else {
                AppleMusicSearchListView(provider: provider, helper: playHelper,
                                         kind: .playlists, term: term) { path.append($0) }
            }
        }
    }

    private var allResultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                // See All routes to the PAGED search list. A count is shown
                // only when the snapshot is provably complete (below the
                // 20-item search fetch) — a full snapshot means "more exist",
                // and stating its size as the total would be wrong.
                let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
                if !results.tracks.isEmpty {
                    sectionHeader(L10n.amSongs)
                    ForEach(results.tracks.prefix(5)) { track in trackRow(track) }
                    if results.tracks.count > 5 {
                        seeAllRow(L10n.amSeeAllSongs,
                                  destination: .searchList(kind: .tracks, term: term, title: L10n.amSongs))
                    }
                }
                if !results.albums.isEmpty {
                    sectionHeader(L10n.amAlbums)
                    ForEach(results.albums.prefix(5)) { album in albumRow(album) }
                    if results.albums.count > 5 {
                        seeAllRow(L10n.amSeeAllAlbums,
                                  destination: .searchList(kind: .albums, term: term, title: L10n.amAlbums))
                    }
                }
                if !results.artists.isEmpty {
                    sectionHeader(L10n.amArtists)
                    ForEach(results.artists.prefix(5)) { artist in artistRow(artist) }
                    if results.artists.count > 5 {
                        seeAllRow(L10n.amSeeAllArtists,
                                  destination: .searchList(kind: .artists, term: term, title: L10n.amArtists))
                    }
                }
                if !results.playlists.isEmpty {
                    sectionHeader(L10n.amPlaylists)
                    ForEach(results.playlists.prefix(5)) { playlist in playlistRow(playlist) }
                    if results.playlists.count > 5 {
                        seeAllRow(L10n.amSeeAllPlaylists,
                                  destination: .searchList(kind: .playlists, term: term, title: L10n.amPlaylists))
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func seeAllRow(_ title: String, destination: AppleMusicDestination) -> some View {
        Button { path.append(destination) } label: {
            HStack(spacing: 10) {
                Spacer().frame(width: 38)
                Text(title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.tint)
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    @ViewBuilder
    private func trackRow(_ track: AppleMusicTrack) -> some View {
        AppleMusicTrackRow(track: track, helper: playHelper)
    }

    @ViewBuilder
    private func albumRow(_ album: AppleMusicAlbum) -> some View {
        Button {
            path.append(AppleMusicDestination.album(
                id: album.id, title: album.title, artist: album.artist, artworkURL: album.artworkURL
            ))
        } label: {
            HStack(spacing: 10) {
                artwork(url: album.artworkURL)
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.title).font(.body).lineLimit(1)
                    Text(albumSubtitle(album))
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            albumContextMenu(album: album, helper: playHelper)
        }
    }

    private func albumSubtitle(_ album: AppleMusicAlbum) -> String {
        var parts: [String] = []
        if !album.artist.isEmpty { parts.append(album.artist) }
        if let year = AppleMusicYearFormatter.year(album.releaseDate) {
            parts.append(year)
        }
        return parts.joined(separator: " • ")
    }

    @ViewBuilder
    private func playlistRow(_ playlist: AppleMusicPlaylist) -> some View {
        Button {
            path.append(AppleMusicDestination.playlist(
                id: playlist.id, name: playlist.name,
                curator: playlist.curatorName, artworkURL: playlist.artworkURL
            ))
        } label: {
            HStack(spacing: 10) {
                artwork(url: playlist.artworkURL)
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
        .contextMenu {
            playlistContextMenu(playlist: playlist, helper: playHelper)
        }
    }

    @ViewBuilder
    private func artistRow(_ artist: AppleMusicArtist) -> some View {
        Button {
            path.append(AppleMusicDestination.artist(
                id: artist.id, name: artist.name, artworkURL: artist.artworkURL
            ))
        } label: {
            HStack(spacing: 10) {
                circularArtwork(url: artist.artworkURL)
                Text(artist.name).font(.body).lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            artistContextMenu(artist: artist, helper: playHelper)
        }
    }

    @ViewBuilder
    func artwork(url: URL?) -> some View {
        AppleMusicArtworkSquare(url: url)
    }

    @ViewBuilder
    func circularArtwork(url: URL?) -> some View {
        AppleMusicArtworkCircle(url: url)
    }

    // MARK: - Search debouncing

    /// Coalesces rapid keystrokes into a single search after the user
    /// pauses. 350 ms balances responsiveness against MusicKit's rate
    /// limits — the framework throttles aggressive bursts.
    private func scheduleSearch(for value: String) {
        searchTask?.cancel()
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            results = .empty
            isSearching = false
            return
        }
        searchTask = Task { [provider] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            await MainActor.run { isSearching = true }
            let r = await provider.search(query: trimmed, limit: 20)
            if Task.isCancelled { return }
            await MainActor.run {
                results = r
                isSearching = false
            }
        }
    }

    // MARK: - Auth refresh

    private func refreshAuth() async {
        authorisation = await provider.authorisation
        if authorisation == .authorised {
            storefront = await provider.currentStorefront()
        }
    }
}
