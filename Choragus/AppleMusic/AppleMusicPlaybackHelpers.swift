/// AppleMusicPlaybackHelpers.swift — Centralises the SMAPI URI / DIDL
/// construction and the single-vs-bulk play routes used by every
/// MusicKit detail view. Mirrors the right-click pattern of the rest
/// of the browse UI (`BrowseView` etc): tap plays now, context menu
/// offers Play Next / Add to Queue / Play All / Add All.
import SwiftUI
import SonosKit

/// Surfaces "a bulk Apple Music action is running" to the root view
/// so the user sees an overlay + the rest of the contextual buttons
/// disable until the operation finishes. Without this, fetching tracks
/// for a 50-track playlist + resolving each catalog id can take several
/// seconds with no visual feedback, and the user can re-trigger the
/// same action multiple times concurrently.
@MainActor
final class AppleMusicBulkActionTracker: ObservableObject {
    @Published var inFlightLabel: String? = nil
    var isInFlight: Bool { inFlightLabel != nil }

    func run(_ label: String, _ work: @escaping () async -> Void) {
        guard !isInFlight else { return }
        inFlightLabel = label
        Task {
            await work()
            inFlightLabel = nil
        }
    }
}

@MainActor
struct AppleMusicPlayHelper {
    let sonosManager: SonosManager
    let smapiManager: SMAPIAuthManager
    let provider: AppleMusicProvider
    let group: SonosGroup?
    let tracker: AppleMusicBulkActionTracker

    var canPlay: Bool { group != nil }

    // MARK: - Bulk fetch + play (album / playlist / artist top songs)

    func playAllInAlbum(_ albumID: String) async {
        let tracks = await provider.albumTracks(albumID: albumID)
        await playAll(tracks)
    }
    func addAllInAlbumToQueue(_ albumID: String, playNext: Bool) async {
        let tracks = await provider.albumTracks(albumID: albumID)
        await addAllToQueue(tracks, playNext: playNext)
    }
    func playAllInPlaylist(_ playlistID: String) async {
        let tracks = await provider.playlistTracks(playlistID: playlistID)
        await playAll(tracks)
    }
    func addAllInPlaylistToQueue(_ playlistID: String, playNext: Bool) async {
        let tracks = await provider.playlistTracks(playlistID: playlistID)
        await addAllToQueue(tracks, playNext: playNext)
    }
    func playTopSongsOf(_ artistID: String) async {
        let tracks = await provider.artistTopSongs(artistID: artistID, limit: 25)
        await playAll(tracks)
    }
    func addTopSongsToQueue(_ artistID: String, playNext: Bool) async {
        let tracks = await provider.artistTopSongs(artistID: artistID, limit: 25)
        await addAllToQueue(tracks, playNext: playNext)
    }

    /// Constructs the Sonos `BrowseItem` envelope for an Apple Music
    /// track. The `x-sonos-http:song:<id>.mp4` URI hands cleanly to
    /// `SonosManager.playBrowseItem` once paired with the per-household
    /// SMAPI session number (`sn`) on Apple Music.
    ///
    /// Library tracks arrive with a library-scoped id (`i.<uuid>` /
    /// `l.<uuid>`) that Sonos rejects. We resolve to a catalog id via
    /// the provider's `resolveCatalogID(forLibraryTrack:)` — a
    /// title-+-artist catalog search behind the scenes. Returns nil
    /// when the library track has no catalog equivalent (typically
    /// user uploads).
    func buildBrowseItem(_ track: AppleMusicTrack) async -> BrowseItem? {
        let sn = smapiManager.serialNumber(for: ServiceID.appleMusic)
        guard sn != 0 else {
            sonosDiagLog(.warning, tag: "APPLE_MUSICKIT",
                         "buildBrowseItem aborted: no SMAPI session for Apple Music",
                         context: ["title": track.title, "id": track.id])
            return nil
        }
        // Catalog ids are positive integers (mostly 9-10 digits, but
        // legacy entries can be much smaller). Library-scoped ids are
        // either letter-prefixed (`i.…`, `l.…`) OR 64-bit hash integers
        // (large negatives, or 13+ digit positives). Anything outside
        // the catalog window goes through title+artist resolve so
        // playback actually reaches a track Sonos can stream.
        let resolvedID: String?
        if let n = Int64(track.id), n > 0, n <= 1_000_000_000_000 {
            resolvedID = track.id
        } else {
            resolvedID = await provider.resolveCatalogID(forLibraryTrack: track)
        }
        guard let catalogID = resolvedID else {
            sonosDiagLog(.warning, tag: "APPLE_MUSICKIT",
                         "buildBrowseItem aborted: no catalog id for library track",
                         context: ["title": track.title, "raw_id": track.id])
            return nil
        }
        // Resolve the album catalog id for the DIDL parentID. Placeholder
        // (`0`) parents cause Sonos to silently accept queue ops and then
        // refuse to start playback — observed 2026-05-14 with multiple
        // Apple Music tracks queueing without ever firing a transport event.
        let albumID: String
        if let supplied = track.albumID, !supplied.isEmpty {
            albumID = supplied
        } else if let resolved = await provider.lookupAlbumID(forSongCatalogID: catalogID) {
            albumID = resolved
        } else {
            albumID = "0"
        }
        let sid = ServiceID.appleMusic
        // cdudn requires the RINCON service type, not the raw sid. For
        // sid=204 the type is `(204 << 8) + 7 = 52231` per
        // `MusicServiceCatalog.rinconServiceType`. Legacy SMAPI search
        // routes through the same lookup; using `sid` here produced a
        // valid-looking DIDL that Sonos accepted into the queue but
        // refused to play (silent transport-no-op observed 2026-05-14).
        let serviceType = MusicServiceCatalog.shared.rinconServiceType(forSid: sid)
        let uri = "x-sonos-http:song%3a\(catalogID).mp4?sid=\(sid)&flags=8224&sn=\(sn)"
        let metadata = buildDIDL(catalogID: catalogID, albumID: albumID, track: track, serviceType: serviceType)
        sonosDiagLog(.info, tag: "APPLE_MUSICKIT",
                     "buildBrowseItem: \(track.title)",
                     context: [
                        "uri": uri,
                        "didl": metadata,
                        "catalogID": catalogID,
                        "albumID": albumID,
                        "sn": String(sn),
                        "title": track.title,
                        "artist": track.artist
                     ])
        return BrowseItem(
            id: "apple:song:\(catalogID)",
            title: track.title,
            artist: track.artist,
            album: track.album,
            albumArtURI: track.artworkURL?.absoluteString,
            itemClass: .musicTrack,
            resourceURI: uri,
            resourceMetadata: metadata
        )
    }

    func playNow(_ track: AppleMusicTrack) async {
        guard let group, let item = await buildBrowseItem(track) else { return }
        try? await sonosManager.playBrowseItem(item, in: group)
    }

    func playNext(_ track: AppleMusicTrack) async {
        guard let group, let item = await buildBrowseItem(track) else { return }
        _ = try? await sonosManager.addBrowseItemToQueue(item, in: group, playNext: true)
    }

    func addToQueue(_ track: AppleMusicTrack) async {
        guard let group, let item = await buildBrowseItem(track) else { return }
        _ = try? await sonosManager.addBrowseItemToQueue(item, in: group)
    }

    func playAll(_ tracks: [AppleMusicTrack]) async {
        guard let group else { return }
        var items: [BrowseItem] = []
        for track in tracks {
            if let item = await buildBrowseItem(track) {
                items.append(item)
            }
        }
        guard !items.isEmpty else { return }
        try? await sonosManager.playItemsReplacingQueue(items, in: group)
    }

    func addAllToQueue(_ tracks: [AppleMusicTrack], playNext: Bool) async {
        guard let group else { return }
        var items: [BrowseItem] = []
        for track in tracks {
            if let item = await buildBrowseItem(track) {
                items.append(item)
            }
        }
        guard !items.isEmpty else { return }
        _ = try? await sonosManager.addBrowseItemsToQueue(items, in: group, playNext: playNext)
    }

    /// Working DIDL structure per `ServiceSearchProvider.buildTrackDIDL`
    /// — `00032020song%3a<id>` (NOT `10032020`) with
    /// `parentID="0004206calbum%3a<collectionId>"` (NOT empty / "0").
    /// The 10032020 + empty-parent variant is documented in
    /// `ServiceSearchProvider.swift` as causing "item no longer
    /// available" rejections during queue-advance. When we don't have
    /// the collection id (most cases — MusicKit doesn't surface the
    /// album catalog id without an extra request), `0` is used as a
    /// placeholder; queue-advance still works because Sonos only uses
    /// the parent reference to walk the *album* track list, not to
    /// validate the track itself.
    private func buildDIDL(catalogID: String, albumID: String, track: AppleMusicTrack, serviceType: Int) -> String {
        let id = catalogID
        return """
        <DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"><item id="00032020song%3a\(id)" parentID="0004206calbum%3a\(albumID)" restricted="true"><dc:title>\(escape(track.title))</dc:title><dc:creator>\(escape(track.artist))</dc:creator><upnp:album>\(escape(track.album))</upnp:album><upnp:class>object.item.audioItem.musicTrack</upnp:class><desc id="cdudn" nameSpace="urn:schemas-rinconnetworks-com:metadata-1-0/">SA_RINCON\(serviceType)_X_#Svc\(serviceType)-0-Token</desc></item></DIDL-Lite>
        """
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - Sort

enum AppleMusicTrackSort: String, CaseIterable, Identifiable {
    case original = "Default"
    case title = "Title"
    case artist = "Artist"
    case album = "Album"
    case duration = "Duration"
    case releaseNewest = "Newest"
    case releaseOldest = "Oldest"
    case addedNewest = "Recently Added"
    case addedOldest = "First Added"
    var id: String { rawValue }

    func sort(_ tracks: [AppleMusicTrack]) -> [AppleMusicTrack] {
        switch self {
        case .original: return tracks
        case .title:    return tracks.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist:   return tracks.sorted { $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending }
        case .album:    return tracks.sorted { $0.album.localizedCaseInsensitiveCompare($1.album) == .orderedAscending }
        case .duration: return tracks.sorted { ($0.durationSec ?? 0) < ($1.durationSec ?? 0) }
        case .releaseNewest: return tracks.sorted { ($0.releaseDate ?? .distantPast) > ($1.releaseDate ?? .distantPast) }
        case .releaseOldest: return tracks.sorted { ($0.releaseDate ?? .distantFuture) < ($1.releaseDate ?? .distantFuture) }
        case .addedNewest:   return tracks.sorted { ($0.dateAdded ?? .distantPast) > ($1.dateAdded ?? .distantPast) }
        case .addedOldest:   return tracks.sorted { ($0.dateAdded ?? .distantFuture) < ($1.dateAdded ?? .distantFuture) }
        }
    }
}

enum AppleMusicAlbumSort: String, CaseIterable, Identifiable {
    case original = "Default"
    case title = "Title"
    case artist = "Artist"
    case releaseNewest = "Newest"
    case releaseOldest = "Oldest"
    case addedNewest = "Recently Added"
    case addedOldest = "First Added"
    var id: String { rawValue }

    func sort(_ albums: [AppleMusicAlbum]) -> [AppleMusicAlbum] {
        switch self {
        case .original: return albums
        case .title:    return albums.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist:   return albums.sorted { $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending }
        case .releaseNewest: return albums.sorted { ($0.releaseDate ?? .distantPast) > ($1.releaseDate ?? .distantPast) }
        case .releaseOldest: return albums.sorted { ($0.releaseDate ?? .distantFuture) < ($1.releaseDate ?? .distantFuture) }
        case .addedNewest:   return albums.sorted { ($0.dateAdded ?? .distantPast) > ($1.dateAdded ?? .distantPast) }
        case .addedOldest:   return albums.sorted { ($0.dateAdded ?? .distantFuture) < ($1.dateAdded ?? .distantFuture) }
        }
    }
}

enum AppleMusicArtistSort: String, CaseIterable, Identifiable {
    case original = "Default"
    case name = "Name"
    var id: String { rawValue }

    func sort(_ artists: [AppleMusicArtist]) -> [AppleMusicArtist] {
        switch self {
        case .original: return artists
        case .name:     return artists.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }
}

enum AppleMusicStationSort: String, CaseIterable, Identifiable {
    case original = "Default"
    case name = "Name"
    case liveFirst = "Live First"
    var id: String { rawValue }

    func sort(_ stations: [AppleMusicStation]) -> [AppleMusicStation] {
        switch self {
        case .original: return stations
        case .name:     return stations.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .liveFirst:
            return stations.sorted { a, b in
                if a.isLive != b.isLive { return a.isLive && !b.isLive }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
    }
}

enum AppleMusicPlaylistSort: String, CaseIterable, Identifiable {
    case original = "Default"
    case name = "Name"
    var id: String { rawValue }

    func sort(_ playlists: [AppleMusicPlaylist]) -> [AppleMusicPlaylist] {
        switch self {
        case .original: return playlists
        case .name:     return playlists.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }
}

/// Compact `Sort: <key>` picker dropped into each list view. Generic
/// over the sort enum so all four content types share the same UI.
struct AppleMusicSortPicker<Sort: CaseIterable & Hashable & RawRepresentable>: View where Sort.RawValue == String, Sort.AllCases: RandomAccessCollection {
    @Binding var selection: Sort

    var body: some View {
        Menu {
            Picker("Sort", selection: $selection) {
                ForEach(Array(Sort.allCases), id: \.self) { value in
                    Text(value.rawValue).tag(value)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Sort: \(selection.rawValue)", systemImage: "arrow.up.arrow.down")
                .labelStyle(.titleAndIcon)
                .font(.callout)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

// MARK: - Shared row + bar views

struct AppleMusicTrackRow: View {
    let track: AppleMusicTrack
    let helper: AppleMusicPlayHelper
    var indexNumber: Int? = nil
    /// When true, the subtitle line is hidden (e.g. inside an album
    /// detail view where the artist + album already appear in the
    /// header and would be redundant per-row).
    var hideSubtitle: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            if let indexNumber {
                Text("\(indexNumber)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 24, alignment: .trailing)
            } else {
                AppleMusicArtworkSquare(url: track.artworkURL)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(.body).lineLimit(1)
                if !hideSubtitle {
                    Text("\(track.artist) — \(track.album)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if let d = track.durationSec {
                Text(formatTrackDuration(d))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { Task { await helper.playNow(track) } }
        .contextMenu {
            Button("Play Now") { Task { await helper.playNow(track) } }
            Button("Play Next") { Task { await helper.playNext(track) } }
            Button("Add to Queue") { Task { await helper.addToQueue(track) } }
        }
    }
}

struct AppleMusicBulkActionBar: View {
    let tracks: [AppleMusicTrack]
    let helper: AppleMusicPlayHelper
    @ObservedObject private var tracker: AppleMusicBulkActionTracker

    init(tracks: [AppleMusicTrack], helper: AppleMusicPlayHelper) {
        self.tracks = tracks
        self.helper = helper
        self.tracker = helper.tracker
    }

    private var disabled: Bool { tracks.isEmpty || !helper.canPlay || tracker.isInFlight }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                tracker.run("Playing \(tracks.count) track\(tracks.count == 1 ? "" : "s")…") {
                    await helper.playAll(tracks)
                }
            } label: {
                Label("Play All", systemImage: "play.fill")
            }
            .controlSize(.small)
            .disabled(disabled)
            Button {
                tracker.run("Adding \(tracks.count) track\(tracks.count == 1 ? "" : "s") to queue…") {
                    await helper.addAllToQueue(tracks, playNext: false)
                }
            } label: {
                Label("Add All to Queue", systemImage: "text.append")
            }
            .controlSize(.small)
            .disabled(disabled)
            Button {
                tracker.run("Queueing \(tracks.count) track\(tracks.count == 1 ? "" : "s") next…") {
                    await helper.addAllToQueue(tracks, playNext: true)
                }
            } label: {
                Label("Play Next", systemImage: "text.insert")
            }
            .controlSize(.small)
            .disabled(disabled)
            Spacer()
            if !tracks.isEmpty {
                Text("\(tracks.count) item\(tracks.count == 1 ? "" : "s")")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - Context-menu builders

@MainActor
@ViewBuilder
func albumContextMenu(album: AppleMusicAlbum, helper: AppleMusicPlayHelper) -> some View {
    if helper.tracker.isInFlight {
        inFlightMenuItem(label: helper.tracker.inFlightLabel ?? "Action in progress…")
    } else {
        Button("Play Now") {
            helper.tracker.run("Playing \(album.title)…") { await helper.playAllInAlbum(album.id) }
        }
        .disabled(!helper.canPlay)
        Button("Play Next") {
            helper.tracker.run("Queueing \(album.title) next…") { await helper.addAllInAlbumToQueue(album.id, playNext: true) }
        }
        .disabled(!helper.canPlay)
        Button("Add to Queue") {
            helper.tracker.run("Adding \(album.title) to queue…") { await helper.addAllInAlbumToQueue(album.id, playNext: false) }
        }
        .disabled(!helper.canPlay)
    }
}

@MainActor
@ViewBuilder
func playlistContextMenu(playlist: AppleMusicPlaylist, helper: AppleMusicPlayHelper) -> some View {
    if helper.tracker.isInFlight {
        inFlightMenuItem(label: helper.tracker.inFlightLabel ?? "Action in progress…")
    } else {
        Button("Play Now") {
            helper.tracker.run("Playing \(playlist.name)…") { await helper.playAllInPlaylist(playlist.id) }
        }
        .disabled(!helper.canPlay)
        Button("Play Next") {
            helper.tracker.run("Queueing \(playlist.name) next…") { await helper.addAllInPlaylistToQueue(playlist.id, playNext: true) }
        }
        .disabled(!helper.canPlay)
        Button("Add to Queue") {
            helper.tracker.run("Adding \(playlist.name) to queue…") { await helper.addAllInPlaylistToQueue(playlist.id, playNext: false) }
        }
        .disabled(!helper.canPlay)
    }
}

@MainActor
@ViewBuilder
func artistContextMenu(artist: AppleMusicArtist, helper: AppleMusicPlayHelper) -> some View {
    if helper.tracker.isInFlight {
        inFlightMenuItem(label: helper.tracker.inFlightLabel ?? "Action in progress…")
    } else {
        Button("Play Top Songs") {
            helper.tracker.run("Playing \(artist.name) top songs…") { await helper.playTopSongsOf(artist.id) }
        }
        .disabled(!helper.canPlay)
        Button("Queue Top Songs Next") {
            helper.tracker.run("Queueing \(artist.name) top songs next…") { await helper.addTopSongsToQueue(artist.id, playNext: true) }
        }
        .disabled(!helper.canPlay)
        Button("Add Top Songs to Queue") {
            helper.tracker.run("Adding \(artist.name) top songs to queue…") { await helper.addTopSongsToQueue(artist.id, playNext: false) }
        }
        .disabled(!helper.canPlay)
    }
}

/// Solo item shown in place of a context menu's action list while an
/// async action is in flight. Visually flags that the right-click was
/// received but the previous action hasn't finished — the AppKit
/// context-menu peer doesn't render `.disabled` Button states the way
/// in-line buttons do, so swapping the contents is what actually
/// communicates the in-flight state to the user.
@MainActor
@ViewBuilder
private func inFlightMenuItem(label: String) -> some View {
    Button(label) { /* no-op while in flight */ }
        .disabled(true)
}

enum AppleMusicYearFormatter {
    private static let cal = Calendar(identifier: .gregorian)
    static func year(_ date: Date?) -> String? {
        guard let date else { return nil }
        let year = cal.component(.year, from: date)
        return year > 0 ? String(year) : nil
    }
    static func full(_ date: Date?) -> String? {
        guard let date else { return nil }
        let f = DateFormatter()
        f.dateStyle = .medium
        return f.string(from: date)
    }
}

fileprivate func formatTrackDuration(_ seconds: Int) -> String {
    let m = seconds / 60
    let s = seconds % 60
    return String(format: "%d:%02d", m, s)
}
