/// PlexDirectBrowseView.swift — Direct-to-PMS browse for Plex.
///
/// Sidebar "Plex" routes here when the user has authenticated via the
/// PIN flow (PlexAuthManager). Talks straight to their PMS over HTTP,
/// bypassing the Sonos SMAPI relay that's prone to "empty list when
/// PMS is asleep" surprises.
///
/// Hierarchy:
///   root  → libraries (Music, Audiobooks, …)
///   section:N → artists in section N
///   children:<ratingKey> → albums under an artist, or tracks under an album
///
/// Search is a flat hub query (`/search?query=…`) over the whole server.
///
/// On first load: tries direct, falls back to a banner offering to open
/// the SMAPI-based browser if the PMS isn't reachable.
import SwiftUI
import SonosKit
import AppKit

/// Single level in the drill-down stack.
private struct PlexNavLevel: Identifiable {
    let id = UUID()
    let title: String
    /// One of: "root", "section:<id>", "children:<ratingKey>"
    let path: String
}

struct PlexDirectBrowseView: View {
    @EnvironmentObject var sonosManager: SonosManager
    @EnvironmentObject var smapiManager: SMAPIAuthManager
    @EnvironmentObject var plexAuth: PlexAuthManager
    let group: SonosGroup?

    @State private var stack: [PlexNavLevel] = [PlexNavLevel(title: "Plex", path: "root")]
    @State private var items: [PlexMediaItem] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var searchText = ""
    @State private var hasSearched = false
    @State private var tab: ServiceTab = .browse
    @State private var fellBackToSMAPI = false

    private let client = PlexDirectClient.shared

    enum ServiceTab: String, CaseIterable, Identifiable {
        case browse = "Browse"
        case search = "Search"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            // Browse/Search picker matches the SMAPI service-search
            // standard so the user gets the same shape across services.
            // Search field only renders on the Search tab.
            if stack.count <= 1 {
                tabPicker
            }
            if tab == .search && stack.count <= 1 {
                searchBar
            }
            Divider()
            if hasPlayableTracks {
                bulkActionBar
                Divider()
            }
            content
        }
        .task(id: stack.last?.path) { await loadCurrent() }
    }

    private var tabPicker: some View {
        Picker("", selection: $tab) {
            ForEach(ServiceTab.allCases) {
                Text($0 == .browse ? L10n.browse : L10n.search).tag($0)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .languageReactive()
        .onChange(of: tab) { _, new in
            if new == .browse {
                searchText = ""
                hasSearched = false
                Task { await loadCurrent() }
            } else {
                items = hasSearched ? items : []
            }
        }
    }

    /// Header strip shown when the current list contains tracks (album
    /// view, search results that include tracks, etc.). Lets the user
    /// queue the whole list in one click instead of right-clicking each
    /// row.
    private var bulkActionBar: some View {
        HStack(spacing: 6) {
            Button {
                Task { await playAllNow() }
            } label: {
                Label(L10n.playAll, systemImage: "play.fill")
            }
            .controlSize(.small)
            Button {
                Task { await addAllToQueue(playNext: false) }
            } label: {
                Label(L10n.addAllToQueue, systemImage: "text.append")
            }
            .controlSize(.small)
            Button {
                Task { await addAllToQueue(playNext: true) }
            } label: {
                Label(L10n.playNext, systemImage: "text.insert")
            }
            .controlSize(.small)
            Spacer()
            // Item count — left as a numeric-only label to avoid the
            // pluralisation gymnastics the existing L10n flat-dictionary
            // doesn't support cleanly. The number itself is universal.
            Text("\(items.count)")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Header & search

    /// Header strip — back button (when drilled in), title, server label.
    /// No search toggle here; the search bar lives below the header as a
    /// permanent fixture, matching the rest of the app's search views
    /// (SMAPI, Apple Music, TuneIn).
    private var header: some View {
        HStack(spacing: 0) {
            if stack.count > 1 {
                Button { stack.removeLast() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.backward")
                            .font(.system(size: 14, weight: .semibold))
                        Text(stack.last?.title ?? "Plex")
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Text(stack.last?.title ?? "Plex")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer()
            }
            if !plexAuth.serverName.isEmpty {
                Text(plexAuth.serverName)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// Always-visible search bar. Submitting runs a flat hub search;
    /// clearing the field reloads whatever was being browsed.
    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                TextField(L10n.searchYourPlexLibraryPlaceholder, text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .onSubmit { Task { await runSearch() } }
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        Task { await loadCurrent() }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(nsColor: .quaternaryLabelColor).opacity(0.3),
                        in: RoundedRectangle(cornerRadius: 6))

            Button {
                Task { await runSearch() }
            } label: {
                Text(L10n.search).font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(searchText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Content

    private var content: some View {
        Group {
            if isLoading && items.isEmpty {
                ProgressView(L10n.loadingPlex)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = loadError {
                errorBanner(err)
            } else if items.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(items, id: \.ratingKey) { item in
                        Button {
                            handleTap(item)
                        } label: {
                            row(for: item)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { contextMenu(for: item) }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private func row(for item: PlexMediaItem) -> some View {
        HStack(spacing: 10) {
            // Plex thumb URL: <base><thumb>?X-Plex-Token=<token>. Loaded
            // straight from PMS — no need to round-trip through Sonos.
            CachedAsyncImage(url: thumbURL(for: item))
                .frame(width: 40, height: 40)
                .background(Color.secondary.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.body).lineLimit(1)
                if let sub = subtitle(for: item) {
                    Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if item.isContainer {
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    /// Right-click menu for any row. Tracks get the standard
    /// Play / Queue / Play Next set; containers (artist/album)
    /// get the same actions but operate on all expanded children.
    @ViewBuilder
    private func contextMenu(for item: PlexMediaItem) -> some View {
        if item.isContainer {
            Button(L10n.playAllNow) {
                Task { await playAllChildren(of: item) }
            }
            Button(L10n.addAllToQueue) {
                Task { await addToQueue(item, playNext: false) }
            }
            Button(L10n.playAllNext) {
                Task { await addToQueue(item, playNext: true) }
            }
            Divider()
            Button(L10n.open) {
                handleTap(item)
            }
        } else {
            Button(L10n.playNow) {
                Task { await play(track: item) }
            }
            Button(L10n.playNext) {
                Task { await addToQueue(item, playNext: true) }
            }
            Button(L10n.addToQueue) {
                Task { await addToQueue(item, playNext: false) }
            }
        }
    }

    /// "Play All Now" on a container — wipes the queue, queues all
    /// expanded children, plays from track 1.
    private func playAllChildren(of item: PlexMediaItem) async {
        guard let group = group else { return }
        do {
            let (base, token) = try await authParams()
            let bulk = (try? await expandTracks(from: item, baseURI: base, token: token)) ?? []
            guard !bulk.isEmpty else {
                loadError = "Nothing to play in \(item.title)."
                return
            }
            try await sonosManager.playItemsReplacingQueue(bulk, in: group)
        } catch {
            sonosDebugLog("[PLEX] playAllChildren failed: \(error)")
            loadError = "Couldn't play all: \(error.localizedDescription)"
        }
    }

    private func subtitle(for item: PlexMediaItem) -> String? {
        switch item.type {
        case "track":  return [item.grandparentTitle, item.parentTitle].compactMap { $0 }.joined(separator: " — ")
        case "album":  return item.parentTitle
        case "artist": return nil
        default:       return item.parentTitle ?? item.grandparentTitle
        }
    }

    private func thumbURL(for item: PlexMediaItem) -> URL? {
        guard let thumb = item.thumb,
              !plexAuth.baseURI.isEmpty,
              !plexAuth.authToken.isEmpty else { return nil }
        return URL(string: "\(plexAuth.baseURI)\(thumb)?X-Plex-Token=\(plexAuth.authToken)")
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray").font(.title2).foregroundStyle(.tertiary)
            Text(L10n.nothingHere).font(.subheadline).foregroundStyle(.secondary)
            if fellBackToSMAPI {
                Text(L10n.plexRelayReturnedNoItems)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(L10n.couldNotReachPlexServer)
                    .font(.subheadline.weight(.semibold))
            }
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(L10n.retry) { Task { await loadCurrent() } }
                    .controlSize(.small)
                if smapiManager.tokenStore.authenticatedServices[ServiceID.plex] != nil {
                    Button(L10n.usePlexViaSonosRelay) { Task { await fallbackToSMAPI() } }
                        .controlSize(.small)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Loading

    private func loadCurrent() async {
        guard let level = stack.last else { return }
        isLoading = true
        loadError = nil
        fellBackToSMAPI = false
        defer { isLoading = false }

        // Make sure we have a base URI before any browse call —
        // discovery may not have completed since the PIN auth landed.
        let base: String
        do {
            base = try await plexAuth.ensureBaseURI()
        } catch {
            loadError = "Plex server discovery failed: \(error.localizedDescription)"
            sonosDebugLog("[PLEX] discovery failed at level=\(level.path): \(error)")
            return
        }

        do {
            switch level.path {
            case "root":
                let libs = try await client.listLibraries(baseURI: base, authToken: plexAuth.authToken)
                items = libs.map { lib in
                    PlexMediaItem(
                        ratingKey: "section:\(lib.id)",
                        title: lib.title,
                        type: "section",
                        parentTitle: lib.type.capitalized,
                        grandparentTitle: nil,
                        thumb: nil,
                        isContainer: true,
                        partKey: nil,
                        durationMs: nil
                    )
                }
            case let p where p.hasPrefix("section:"):
                let sectionID = String(p.dropFirst("section:".count))
                // Music libraries default to artists at the top level —
                // matches what the Plex web UI shows.
                let result = try await client.browse(
                    baseURI: base,
                    authToken: plexAuth.authToken,
                    sectionID: sectionID,
                    kind: .artists,
                    offset: 0,
                    limit: 100
                )
                items = result.items
            case let p where p.hasPrefix("children:"):
                let ratingKey = String(p.dropFirst("children:".count))
                let result = try await client.browse(
                    baseURI: base,
                    authToken: plexAuth.authToken,
                    sectionID: "",
                    kind: .childrenOf(ratingKey: ratingKey),
                    offset: 0,
                    limit: 200
                )
                items = result.items
            default:
                items = []
            }
        } catch {
            sonosDebugLog("[PLEX] browse failed at \(level.path): \(error)")
            // If the cached base URI's gone bad, try one rediscovery
            // before declaring defeat.
            if let _ = try? await plexAuth.refreshServer() {
                sonosDebugLog("[PLEX] rediscovered server, no auto-retry to avoid loops")
            }
            loadError = error.localizedDescription
        }
    }

    private func runSearch() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        isLoading = true
        loadError = nil
        hasSearched = true
        defer { isLoading = false }
        do {
            let base = try await plexAuth.ensureBaseURI()
            items = try await client.search(baseURI: base, authToken: plexAuth.authToken, query: query, limit: 50)
        } catch {
            sonosDebugLog("[PLEX] search failed: \(error)")
            loadError = error.localizedDescription
        }
    }

    /// User-driven fallback: hand them off to the SMAPI Plex flow if
    /// direct refuses to load. We don't auto-fallback because the
    /// failure modes are quite different — SMAPI may be having its
    /// own issues, and silently switching channels would be confusing.
    private func fallbackToSMAPI() async {
        fellBackToSMAPI = true
        // The simplest "fallback" is to just open the SMAPI search
        // entry programmatically. Instead of routing through the
        // sidebar, surface a banner pointing the user there for now.
        loadError = "Direct browse unavailable. Use the Music Services SMAPI Plex entry from the sidebar to browse via Sonos's relay."
    }

    // MARK: - Tap handling

    private func handleTap(_ item: PlexMediaItem) {
        if item.isContainer {
            let nextPath: String
            if item.type == "section" {
                nextPath = item.ratingKey  // already "section:N"
            } else {
                nextPath = "children:\(item.ratingKey)"
            }
            stack.append(PlexNavLevel(title: item.title, path: nextPath))
        } else {
            Task { await play(track: item) }
        }
    }

    // MARK: - Item → BrowseItem conversion

    /// Converts a Plex track to a Sonos-shaped BrowseItem with playback
    /// URI + DIDL metadata. Containers (artist/album) get a passthrough
    /// BrowseItem with no `resourceURI` — they're not directly playable
    /// from this view; bulk actions on a container expand the
    /// container's children first.
    private func makeBrowseItem(_ track: PlexMediaItem, baseURI: String, token: String) -> BrowseItem? {
        guard let partKey = track.partKey, !partKey.isEmpty else { return nil }
        let separator = partKey.contains("?") ? "&" : "?"
        let uri = "\(baseURI)\(partKey)\(separator)X-Plex-Token=\(token)"
        let artURL: String? = track.thumb.flatMap { thumb in
            "\(baseURI)\(thumb)?X-Plex-Token=\(token)"
        }
        let didl = Self.buildDIDL(
            title: track.title,
            artist: track.grandparentTitle ?? "",
            album: track.parentTitle ?? "",
            artURL: artURL,
            streamURI: uri,
            durationMs: track.durationMs
        )
        return BrowseItem(
            id: "plexd:track:\(track.ratingKey)",
            title: track.title,
            artist: track.grandparentTitle ?? "",
            album: track.parentTitle ?? "",
            albumArtURI: artURL,
            itemClass: .musicTrack,
            resourceURI: uri,
            resourceMetadata: didl
        )
    }

    /// Resolves baseURI + a fresh transient token, used by every
    /// playback / queue action.
    private func authParams() async throws -> (base: String, token: String) {
        let base = try await plexAuth.ensureBaseURI()
        let token = try await client.transientToken(baseURI: base, authToken: plexAuth.authToken)
        return (base, token)
    }

    /// Recursively expands a container (artist or album) into its
    /// playable track items. One level of recursion handles
    /// album → tracks; two handles artist → albums → tracks.
    private func expandTracks(from item: PlexMediaItem, baseURI: String, token: String) async throws -> [BrowseItem] {
        if item.isContainer {
            let result = try await client.browse(
                baseURI: baseURI, authToken: plexAuth.authToken,
                sectionID: "", kind: .childrenOf(ratingKey: item.ratingKey),
                offset: 0, limit: 500
            )
            var out: [BrowseItem] = []
            for child in result.items {
                if child.isContainer {
                    out.append(contentsOf: (try? await expandTracks(from: child, baseURI: baseURI, token: token)) ?? [])
                } else if let bi = makeBrowseItem(child, baseURI: baseURI, token: token) {
                    out.append(bi)
                }
            }
            return out
        } else if let bi = makeBrowseItem(item, baseURI: baseURI, token: token) {
            return [bi]
        }
        return []
    }

    // MARK: - Per-item actions

    private func play(track: PlexMediaItem) async {
        guard let group = group else {
            loadError = "No speaker group selected to play to."
            return
        }
        do {
            let (base, token) = try await authParams()
            guard let item = makeBrowseItem(track, baseURI: base, token: token) else {
                loadError = "This track has no playable media — Plex may still be importing it."
                return
            }
            sonosDebugLog("[PLEX] Playing \(track.title)")
            try await sonosManager.playBrowseItem(item, in: group)
        } catch {
            sonosDebugLog("[PLEX] play failed: \(error)")
            loadError = "Couldn't start playback: \(error.localizedDescription)"
        }
    }

    private func addToQueue(_ item: PlexMediaItem, playNext: Bool) async {
        guard let group = group else {
            loadError = "No speaker group selected to play to."
            return
        }
        do {
            let (base, token) = try await authParams()
            let items = try await expandTracks(from: item, baseURI: base, token: token)
            guard !items.isEmpty else {
                loadError = "Nothing to queue — \(item.title) has no playable tracks."
                return
            }
            _ = try await sonosManager.addBrowseItemsToQueue(items, in: group, playNext: playNext)
        } catch {
            sonosDebugLog("[PLEX] addToQueue failed: \(error)")
            loadError = "Couldn't add to queue: \(error.localizedDescription)"
        }
    }

    // MARK: - Bulk actions (whole list)

    private var hasPlayableTracks: Bool {
        items.contains { !$0.isContainer && $0.partKey != nil }
    }

    private func playAllNow() async {
        guard let group = group else { return }
        do {
            let (base, token) = try await authParams()
            var bulk: [BrowseItem] = []
            for it in items {
                bulk.append(contentsOf: (try? await expandTracks(from: it, baseURI: base, token: token)) ?? [])
            }
            guard !bulk.isEmpty else {
                loadError = "Nothing to play in this list."
                return
            }
            // Audio-first replace-and-play: first track plays in one
            // round-trip, the rest fills the queue in the background.
            try await sonosManager.playItemsReplacingQueue(bulk, in: group)
        } catch {
            sonosDebugLog("[PLEX] playAllNow failed: \(error)")
            loadError = "Couldn't play all: \(error.localizedDescription)"
        }
    }

    private func addAllToQueue(playNext: Bool) async {
        guard let group = group else { return }
        do {
            let (base, token) = try await authParams()
            var bulk: [BrowseItem] = []
            for it in items {
                bulk.append(contentsOf: (try? await expandTracks(from: it, baseURI: base, token: token)) ?? [])
            }
            guard !bulk.isEmpty else {
                loadError = "Nothing to add."
                return
            }
            _ = try await sonosManager.addBrowseItemsToQueue(bulk, in: group, playNext: playNext)
        } catch {
            sonosDebugLog("[PLEX] addAllToQueue failed: \(error)")
            loadError = "Couldn't add all: \(error.localizedDescription)"
        }
    }

    /// Builds a DIDL-Lite envelope for `SetAVTransportURI`. Sonos uses
    /// the metadata in the envelope as the authoritative source for
    /// title / artist / album / art when polling back during playback;
    /// without it, GetPositionInfo returns empty fields and the
    /// manager's metadata-merge logic eventually overwrites cached art.
    /// Keeping it minimal — Sonos accepts loosely-formed DIDL as long as
    /// the namespaces and `<upnp:class>` are present.
    ///
    /// `duration` on the `<res>` element is what makes the Now Playing
    /// seek bar appear with a proper track length. Without it, Sonos's
    /// GetPositionInfo returns 00:00:00 for `TrackDuration` and the
    /// player UI falls back to the "Live" label as if it were a radio
    /// stream. Plex always knows the track length (`durationMs` from
    /// the library API), so emit it whenever it's present.
    private static func buildDIDL(title: String, artist: String, album: String,
                                  artURL: String?, streamURI: String,
                                  durationMs: Int?) -> String {
        let id = "plex-direct"
        let escTitle = xmlEscape(title)
        let escArtist = xmlEscape(artist)
        let escAlbum = xmlEscape(album)
        let escStream = xmlEscape(streamURI)
        let artElement: String = artURL.map { "<upnp:albumArtURI>\(xmlEscape($0))</upnp:albumArtURI>" } ?? ""
        let durationAttr: String = durationMs
            .map { " duration=\"\(formatDIDLDuration(milliseconds: $0))\"" } ?? ""
        return """
        <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" \
        xmlns:dc="http://purl.org/dc/elements/1.1/" \
        xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">\
        <item id="\(id)" parentID="-1" restricted="1">\
        <dc:title>\(escTitle)</dc:title>\
        <upnp:artist>\(escArtist)</upnp:artist>\
        <upnp:album>\(escAlbum)</upnp:album>\
        \(artElement)\
        <upnp:class>object.item.audioItem.musicTrack</upnp:class>\
        <res protocolInfo="http-get:*:*:*"\(durationAttr)>\(escStream)</res>\
        </item></DIDL-Lite>
        """
    }

    /// `H:MM:SS.fff` per UPnP `<res>` `duration` attribute spec. Hours
    /// are unpadded (Sonos accepts both forms), minutes and seconds are
    /// always two digits, milliseconds always three.
    private static func formatDIDLDuration(milliseconds ms: Int) -> String {
        let totalMs = max(0, ms)
        let hours = totalMs / 3_600_000
        let minutes = (totalMs % 3_600_000) / 60_000
        let seconds = (totalMs % 60_000) / 1000
        let millis = totalMs % 1000
        return String(format: "%d:%02d:%02d.%03d", hours, minutes, seconds, millis)
    }

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
         .replacingOccurrences(of: "'", with: "&apos;")
    }
}
