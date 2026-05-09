/// NowPlayingContextPanel.swift — Tabbed lower panel under Now Playing.
///
/// Three tabs:
///   • Lyrics — synced + plain from LRCLIB.
///   • About — artist bio, tags, similar artists, album tracklist
///     from Last.fm.
///   • History — purely local; how often this track has played in
///     Choragus, when, and in which rooms. Reads `playHistoryRepo`.
///
/// Lyrics + About are populated lazily on track change. Both
/// services cache permanently (lyrics) or for ~30 days (Last.fm) in
/// the same SQLite file as play history, so repeat plays of the same
/// track are free.
import SwiftUI
import SonosKit

struct NowPlayingContextPanel: View {
    let trackMetadata: TrackMetadata
    let group: SonosGroup
    /// Authoritative playhead anchor sourced from `NowPlayingViewModel`.
    /// The synced-lyrics view wraps `positionAnchor.projected(at:)` in
    /// a `TimelineView` so the highlight slides at display refresh
    /// rate (60/120 Hz) regardless of how often the speaker reports
    /// new positions. Carries `isPlaying` internally so projection
    /// freezes during pause without a separate parameter.
    let positionAnchor: PositionAnchor

    @EnvironmentObject var playHistoryManager: PlayHistoryManager

    /// All metadata-fetch state + orchestration lives in the VM
    /// (lyrics + offsets, artist + album info, lazy-load gating,
    /// background pre-warm, refresh, debounced offset persistence).
    /// The View just renders state and dispatches events.
    @State private var ctxVM: NowPlayingContextPanelViewModel

    @State private var tab: NowPlayingContextPanelTab = .about
    /// Drives the click-to-expand sheet for the artist photo in the
    /// About card (mirrors the album-art expand behaviour in
    /// `NowPlayingView`). Carries the URL so the same `ExpandedArtView`
    /// can render it.
    @State private var expandedArtistPhotoURL: URL?

    /// Cached result of `matchingHistory()` for the current track.
    /// Recomputed only when the track changes or the history store
    /// grows — `matchingHistory()` filters thousands of entries on the
    /// main thread, so calling it inside the History tab `body` made
    /// every parent invalidation (transport tick, topology event,
    /// volume change) re-scan the whole store.
    @State private var historyEntries: [PlayHistoryEntry] = []

    /// Cached result of `matchingArtistHistory()` for the current
    /// artist. Drives the right-hand "By this artist" column added
    /// alongside the per-track history. Same caching rationale as
    /// `historyEntries`.
    @State private var artistHistoryEntries: [PlayHistoryEntry] = []

    /// Initialises the VM eagerly so body's first render — which fires
    /// before any `.task` modifier — already has the real instance. The
    /// previous `@State var vm: VM?` + `assertionFailure`-guarded getter
    /// crashed because SwiftUI evaluated body before the lazy `.task`
    /// could populate it.
    init(
        trackMetadata: TrackMetadata,
        group: SonosGroup,
        positionAnchor: PositionAnchor,
        lyricsCoordinator: LyricsCoordinator,
        metadataService: MusicMetadataService
    ) {
        self.trackMetadata = trackMetadata
        self.group = group
        self.positionAnchor = positionAnchor
        _ctxVM = State(wrappedValue: NowPlayingContextPanelViewModel(
            lyricsCoordinator: lyricsCoordinator,
            metadataService: metadataService
        ))
    }

    @EnvironmentObject var lyricsCoordinator: LyricsCoordinator

    /// Global lyrics timing offset from Settings. Added on top of the
    /// per-track manual offset (the `±` toolbar) before being passed
    /// to `SlidingLyricsView`. Default `−2.0 s` empirically.
    @AppStorage(UDKey.lyricsGlobalOffset) private var lyricsGlobalOffset: Double = -2.0

    private var lyricsResolved: LyricsCoordinator.Resolved {
        lyricsCoordinator.resolved(for: trackMetadata)
    }
    private var lyricsOffset: Double {
        lyricsCoordinator.offset(for: trackMetadata)
    }

    /// Per-tab cache invalidation key. For non-radio playback the
    /// shared `stableKey` is fine (URI changes per song). For radio
    /// the URI is constant across an HLS stream's whole session and
    /// `stableKey` falls back to just the URI when the artist field
    /// is empty — meaning per-song About / History refreshes never
    /// fire. Use title+artist directly on radio so any change to
    /// either field re-runs `loadActiveTab`.
    private var trackKey: String {
        if trackMetadata.isRadioStream || !trackMetadata.stationName.isEmpty {
            return "radio|\(trackMetadata.title)|\(trackMetadata.artist)"
        }
        return trackMetadata.stableKey
    }

    var body: some View {
        VStack(spacing: 0) {
            tabPicker
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: trackKey) {
            ctxVM.resetForNewTrack(trackMetadata)
            await ctxVM.loadActiveTab(tab, metadata: trackMetadata)
        }
        .onChange(of: tab) { _, _ in
            Task { await ctxVM.loadActiveTab(tab, metadata: trackMetadata) }
        }
    }

    // MARK: - Tabs

    private var tabPicker: some View {
        Picker("", selection: $tab) {
            ForEach(NowPlayingContextPanelTab.allCases) { Text($0.displayName).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .languageReactive()
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .lyrics:  lyricsTab
        case .about:   aboutTab
        case .history: historyTab
        }
    }

    // MARK: - Lyrics

    private var lyricsTab: some View {
        // Synced lyrics use a fixed-height sliding view; plain lyrics
        // use a scrollable text view. Branch up here so the synced
        // path doesn't get wrapped in a ScrollView (which would let
        // its fixed window get clipped or grow unpredictably).
        Group {
            switch lyricsResolved.status {
            case .idle, .loading:
                loadingPlaceholder(text: L10n.lookingUpLyrics)
            case .loaded:
                if let lyrics = lyricsResolved.lyrics {
                    renderedLyrics(lyrics)
                } else {
                    emptyPlaceholder(icon: "text.alignleft",
                                     text: L10n.noLyricsFound)
                }
            case .missing:
                emptyPlaceholder(icon: "text.alignleft",
                                 text: L10n.noLyricsFound)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func renderedLyrics(_ lyrics: Lyrics) -> some View {
        if lyrics.isInstrumental {
            VStack(alignment: .center, spacing: 8) {
                Image(systemName: "music.note").font(.title)
                    .foregroundStyle(.secondary)
                Text(L10n.instrumental).font(.body).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if lyrics.synced != nil {
            VStack(spacing: 6) {
                SlidingLyricsView(
                    lines: lyricsCoordinator.parsedLines(for: trackMetadata),
                    anchor: positionAnchor,
                    offset: lyricsOffset + lyricsGlobalOffset
                )
                .equatable()
                .frame(maxWidth: .infinity)
                lyricsOffsetToolbar
            }
        } else if let plain = lyrics.plainText {
            // Plain (un-synced) lyrics — centred, larger text, normal
            // scroll bar. Line spacing matches the breathing room of
            // `SlidingLyricsView`'s 34pt row height.
            let plainLines = plain
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
            ScrollView {
                VStack(spacing: 14) {
                    ForEach(Array(plainLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.title3)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .textSelection(.enabled)
        }
    }

    /// Six-button nudge bar for synced lyrics: −10, −5, −1, current offset, +1, +5, +10.
    /// Resets to 0 on every track change. Visible only when synced lyrics
    /// are showing (the only case where an offset is meaningful).
    private var lyricsOffsetToolbar: some View {
        HStack(spacing: 4) {
            offsetButton(label: "−10", delta: -10)
            offsetButton(label: "−5", delta: -5)
            offsetButton(label: "−1", delta: -1)
            Text(offsetDisplayString)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 56)
                .contentShape(Rectangle())
                .onTapGesture {
                    lyricsCoordinator.setOffset(0, for: trackMetadata)
                }
                .help(L10n.tapToResetOffset)
            offsetButton(label: "+1", delta: 1)
            offsetButton(label: "+5", delta: 5)
            offsetButton(label: "+10", delta: 10)
        }
        .padding(.bottom, 4)
    }

    private func offsetButton(label: String, delta: Double) -> some View {
        Button(label) {
            lyricsCoordinator.setOffset(lyricsOffset + delta, for: trackMetadata)
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
        .font(.caption.monospacedDigit())
    }

    private var offsetDisplayString: String {
        let value = lyricsOffset
        if value == 0 { return "0.0s" }
        let sign = value > 0 ? "+" : ""
        return String(format: "%@%.1fs", sign, value)
    }

    // Offset persistence + tab orchestration live on
    // `NowPlayingContextPanelViewModel` now — see `scheduleOffsetSave`,
    // `loadActiveTab`, `refreshAbout` in that file.

    // MARK: - About

    private var aboutTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch ctxVM.aboutState {
                case .idle, .loading:
                    loadingPlaceholder(text: L10n.loadingInfo)
                case .loaded, .missing, .error:
                    if let info = ctxVM.artistInfo {
                        artistSection(info)
                    }
                    if let album = ctxVM.albumInfo {
                        albumSection(album)
                    }
                    if ctxVM.artistInfo == nil && ctxVM.albumInfo == nil {
                        emptyPlaceholder(
                            icon: "info.circle",
                            text: L10n.noInfoFound
                        )
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            // `contentShape` makes the WHOLE VStack frame accept the
            // right-click — without it, the VStack collapses to the
            // small empty-placeholder bounds when no info has loaded
            // yet, so the user can't right-click "Refresh metadata"
            // anywhere in the empty area.
            .contentShape(Rectangle())
            .contextMenu {
                Button {
                    Task { await ctxVM.refreshAbout(trackMetadata) }
                } label: {
                    Label(L10n.refreshMetadata, systemImage: "arrow.clockwise")
                }
                .disabled(trackMetadata.artist.isEmpty && trackMetadata.title.isEmpty)
            }
            // Whole tab contents selectable so the user can copy any
            // bio paragraph, tag, or track name and paste into a
            // search elsewhere. Buttons / Pickers inside the subtree
            // continue to work normally — `.textSelection` only
            // affects `Text` views.
            .textSelection(.enabled)
        }
        .sheet(item: Binding(
            get: { expandedArtistPhotoURL.map(IdentifiableURL.init) },
            set: { expandedArtistPhotoURL = $0?.url }
        )) { wrapper in
            ExpandedArtView(
                artURL: wrapper.url,
                title: ctxVM.artistInfo?.name ?? trackMetadata.artist,
                artist: ctxVM.artistInfo?.name ?? trackMetadata.artist,
                album: "",
                stationName: ""
            )
        }
    }

    /// Identifiable URL wrapper so we can use `.sheet(item:)` with a
    /// nilable URL state. SwiftUI's `.sheet(item:)` requires Identifiable
    /// content; URL itself isn't.
    private struct IdentifiableURL: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

    private func artistSection(_ info: ArtistInfo) -> some View {
        aboutCard {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader(
                    icon: "person.fill", title: info.name,
                    subtitle: artistSubtitle(info),
                    imageURL: info.imageURL,
                    onImageTap: {
                        if let s = info.imageURL, let url = URL(string: s) {
                            expandedArtistPhotoURL = url
                        }
                    }
                )
                if !info.tags.isEmpty {
                    tagRow(info.tags)
                }
                if let bio = info.bio, !bio.isEmpty {
                    Text(bio)
                        .font(.body)
                        .foregroundStyle(.primary.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let wiki = info.wikipediaURL,
                   let url = URL(string: wiki) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right.square")
                            .imageScale(.small)
                        Link(L10n.readOnWikipedia, destination: url)
                            .font(.callout)
                    }
                    .foregroundStyle(.tint)
                    .padding(.top, 2)
                }
                if !info.similarArtists.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        labelHeader(L10n.similarArtists)
                        similarArtistsRow(info.similarArtists)
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    private func artistSubtitle(_ info: ArtistInfo) -> String? {
        guard let listeners = info.listeners else { return nil }
        return "\(formatCount(listeners)) listeners on Last.fm"
    }

    /// Renders similar-artist names as inline tappable Wikipedia links.
    /// Uses a single Markdown-formatted Text so the row wraps naturally
    /// instead of clipping. Each link points at Wikipedia's search-go
    /// endpoint, which auto-redirects to the article when one matches
    /// the name and falls back to the search results page otherwise —
    /// so we never show a 404 even when the artist's article lives at
    /// a slightly different title.
    @ViewBuilder
    private func similarArtistsRow(_ names: [String]) -> some View {
        var combined = Text("")
        for (i, name) in names.enumerated() {
            if i > 0 {
                combined = combined + Text("  ·  ").foregroundStyle(.tertiary)
            }
            let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
            let urlString = "https://en.wikipedia.org/wiki/Special:Search?search=\(encoded)&go=Go"
            combined = combined + Text(.init("[\(name)](\(urlString))"))
        }
        return combined
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func albumSection(_ info: AlbumInfo) -> some View {
        aboutCard {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader(
                    icon: "square.stack.fill",
                    title: info.title,
                    subtitle: albumSubtitle(info)
                )
                if !info.tags.isEmpty { tagRow(info.tags) }
                if let summary = info.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.body)
                        .foregroundStyle(.primary.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !info.tracks.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        labelHeader(L10n.tracks)
                        VStack(spacing: 0) {
                            ForEach(Array(info.tracks.enumerated()), id: \.offset) { index, track in
                                trackRow(track: track, index: index)
                            }
                        }
                        .padding(.top, 2)
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    /// Card wrapper used by both artist and album sections. Subtle
    /// material fill with a soft outline reads as "modern macOS" without
    /// shouting — distinguishes the section as a unit but doesn't compete
    /// with the bio text or tags.
    @ViewBuilder
    private func aboutCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.quaternary.opacity(0.35))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.quaternary.opacity(0.5), lineWidth: 0.5)
            )
    }

    /// Header used for each card: a small accent-coloured icon, the title,
    /// an optional secondary subtitle line, and an optional trailing
    /// image (artist photo from Wikipedia / Last.fm). The image renders
    /// with rounded corners and a tint-coloured outline so it reads as
    /// part of the card rather than a floating thumbnail.
    @ViewBuilder
    private func sectionHeader(icon: String, title: String,
                               subtitle: String?,
                               imageURL: String? = nil,
                               onImageTap: (() -> Void)? = nil) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(.tint)
                .imageScale(.medium)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            if let imageURL, let url = URL(string: imageURL) {
                CachedAsyncImage(url: url, cornerRadius: 8, priority: .interactive)
                    .frame(width: 64, height: 64)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(.tint.opacity(0.25), lineWidth: 0.5)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { onImageTap?() }
                    .help(L10n.clickToEnlarge)
                    .accessibilityLabel("\(title) photo")
            }
        }
    }

    /// Small uppercase tracking-style label used for "Similar artists" and
    /// "Tracks" sub-headers within each card.
    @ViewBuilder
    private func labelHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }

    private func albumSubtitle(_ info: AlbumInfo) -> String? {
        var parts: [String] = []
        if !info.artist.isEmpty { parts.append(info.artist) }
        if let d = info.releaseDate, !d.isEmpty { parts.append(d) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Row in the album tracklist. The current track is rendered with a
    /// small accent dot and emphasis weight; others stay quiet.
    @ViewBuilder
    private func trackRow(track: AlbumInfo.Track, index: Int) -> some View {
        let isCurrent = track.title.compare(trackMetadata.title,
                                            options: .caseInsensitive) == .orderedSame
        HStack(spacing: 10) {
            ZStack {
                Text("\(track.position ?? index + 1)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .opacity(isCurrent ? 0 : 1)
                if isCurrent {
                    Circle()
                        .fill(.tint)
                        .frame(width: 6, height: 6)
                }
            }
            .frame(width: 22, alignment: .trailing)
            Text(track.title)
                .font(.body)
                .fontWeight(isCurrent ? .semibold : .regular)
                .foregroundStyle(isCurrent ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            Spacer()
            if let dur = track.durationSeconds {
                Text(formatDuration(dur))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
    }

    private func tagRow(_ tags: [String]) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.callout)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(.tint.opacity(0.12),
                                in: Capsule(style: .continuous))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(.tint.opacity(0.25), lineWidth: 0.5)
                    )
                    .foregroundStyle(.primary.opacity(0.85))
            }
        }
    }

    // MARK: - History

    private var historyTab: some View {
        HStack(alignment: .top, spacing: 0) {
            trackHistoryColumn
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            artistHistoryColumn
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: HistoryCacheKey(trackKey: trackKey,
                                  entriesCount: playHistoryManager.entries.count)) {
            historyEntries = matchingHistory()
            artistHistoryEntries = matchingArtistHistory()
        }
    }

    private var trackHistoryColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("This Track")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                if historyEntries.isEmpty {
                    emptyPlaceholder(icon: "clock",
                                     text: L10n.noPreviousPlaysInHistory)
                } else {
                    historySummary(historyEntries)
                    Divider().padding(.vertical, 4)
                    Text(L10n.recentPlays).font(.body.weight(.semibold))
                    ForEach(Array(historyEntries.prefix(20))) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Text(formatRelativeDate(entry.timestamp))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 110, alignment: .leading)
                            Text(entry.groupName.isEmpty ? "—" : entry.groupName)
                                .font(.callout)
                            Spacer()
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var artistHistoryColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("By This Artist")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                if artistHistoryEntries.isEmpty {
                    emptyPlaceholder(icon: "music.mic",
                                     text: L10n.noPreviousPlaysInHistory)
                } else {
                    artistSummary(artistHistoryEntries)
                    Divider().padding(.vertical, 4)
                    Text(L10n.topTracks).font(.body.weight(.semibold))
                    let top = topTracksByArtist(artistHistoryEntries, limit: 12)
                    ForEach(top, id: \.title) { row in
                        HStack(alignment: .top, spacing: 8) {
                            Text(row.title)
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer()
                            Text("\(row.count)")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private struct HistoryCacheKey: Hashable {
        let trackKey: String
        let entriesCount: Int
    }

    private func matchingHistory() -> [PlayHistoryEntry] {
        // Match by title + artist (case-insensitive). Most history
        // queries are interactive — 5k entries scanned in memory is
        // fine without an index. If history grows past tens of
        // thousands we'd add a `(title, artist)` index on the SQLite
        // side.
        let needleTitle = trackMetadata.title.lowercased()
        let needleArtist = trackMetadata.artist.lowercased()
        let filtered: [PlayHistoryEntry] = playHistoryManager.entries.filter { entry in
            entry.title.lowercased() == needleTitle
                && entry.artist.lowercased() == needleArtist
        }
        return filtered.sorted { (lhs: PlayHistoryEntry, rhs: PlayHistoryEntry) in
            lhs.timestamp > rhs.timestamp
        }
    }

    /// All plays of any track by the current artist, newest first.
    private func matchingArtistHistory() -> [PlayHistoryEntry] {
        let needleArtist = trackMetadata.artist.lowercased()
        guard !needleArtist.isEmpty else { return [] }
        let filtered: [PlayHistoryEntry] = playHistoryManager.entries.filter { entry in
            entry.artist.lowercased() == needleArtist
        }
        return filtered.sorted { (lhs: PlayHistoryEntry, rhs: PlayHistoryEntry) in
            lhs.timestamp > rhs.timestamp
        }
    }

    private struct ArtistTopTrack {
        let title: String
        let count: Int
    }

    /// Counts plays per (title) for the artist's history and returns
    /// the top `limit` by play count.
    private func topTracksByArtist(_ entries: [PlayHistoryEntry], limit: Int) -> [ArtistTopTrack] {
        var counts: [String: Int] = [:]
        for entry in entries where !entry.title.isEmpty {
            counts[entry.title, default: 0] += 1
        }
        return counts
            .map { ArtistTopTrack(title: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
            .prefix(limit)
            .map { $0 }
    }

    private func historySummary(_ entries: [PlayHistoryEntry]) -> some View {
        let rooms = Set(entries.map(\.groupName).filter { !$0.isEmpty })
        return VStack(alignment: .leading, spacing: 4) {
            Text(L10n.playsCountFormat(entries.count))
                .font(.title3.weight(.semibold))
            if !rooms.isEmpty {
                Text(L10n.acrossRoomsFormat(count: rooms.count,
                                             list: rooms.sorted().joined(separator: ", ")))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let last = entries.first {
                Text(L10n.lastPlayedFormat(formatRelativeDate(last.timestamp)))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func artistSummary(_ entries: [PlayHistoryEntry]) -> some View {
        let uniqueTracks = Set(entries.map(\.title).filter { !$0.isEmpty }).count
        return VStack(alignment: .leading, spacing: 4) {
            Text(L10n.playsCountFormat(entries.count))
                .font(.title3.weight(.semibold))
            Text("\(uniqueTracks) unique track\(uniqueTracks == 1 ? "" : "s")")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let last = entries.first {
                Text(L10n.lastPlayedFormat(formatRelativeDate(last.timestamp)))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Helpers

    private func loadingPlaceholder(text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text).font(.body).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyPlaceholder(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.title2).foregroundStyle(.tertiary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private func formatCount(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private func formatDuration(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }

    private func formatRelativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Service holders (env-injectable wrappers)

/// SwiftUI's `@EnvironmentObject` requires `ObservableObject`, but our
/// services are intentionally not — they're stateless. These thin
/// wrappers let the app inject them once and have views observe the
/// holder reference rather than the bare struct.

@MainActor
public final class LyricsServiceHolder: ObservableObject {
    public let service: LyricsService
    public init(service: LyricsService) { self.service = service }
}

@MainActor
public final class MusicMetadataServiceHolder: ObservableObject {
    public let service: MusicMetadataService
    public init(service: MusicMetadataService) { self.service = service }
}

