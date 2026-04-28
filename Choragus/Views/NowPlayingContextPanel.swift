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
    /// Live track position in seconds, fed in from the parent view's
    /// progress timer. Drives the synced-lyrics highlight.
    let positionSeconds: Double
    /// True while transport is `.playing`. The lyrics view uses this
    /// to decide whether to keep scrolling forward in real time
    /// between Sonos updates (playing) or hold the current position
    /// (paused).
    let isPlaying: Bool

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

    /// Initialises the VM eagerly so body's first render — which fires
    /// before any `.task` modifier — already has the real instance. The
    /// previous `@State var vm: VM?` + `assertionFailure`-guarded getter
    /// crashed because SwiftUI evaluated body before the lazy `.task`
    /// could populate it.
    init(
        trackMetadata: TrackMetadata,
        group: SonosGroup,
        positionSeconds: Double,
        isPlaying: Bool,
        lyricsService: LyricsService,
        metadataService: MusicMetadataService
    ) {
        self.trackMetadata = trackMetadata
        self.group = group
        self.positionSeconds = positionSeconds
        self.isPlaying = isPlaying
        _ctxVM = State(wrappedValue: NowPlayingContextPanelViewModel(
            lyricsService: lyricsService,
            metadataService: metadataService
        ))
    }

    /// Stable per-track identifier. `trackURI` is the canonical
    /// per-track string and stays the same across speaker polls;
    /// `title|artist` is a fallback for the rare cases where the
    /// speaker reports a track without a URI. Album is intentionally
    /// excluded because some services blank it momentarily during
    /// track transitions, which used to flip this key and re-fire
    /// the lyrics-loading task — clearing the cached `lyrics` to
    /// nil for a frame and making the panel appear to flash empty
    /// half-way through every long track.
    private var trackKey: String {
        // Radio URIs identify the *station*, not the song — the same URI plays
        // dozens of different tracks back-to-back. For radio, song change is
        // signalled by title/artist updating, so include those in the key.
        // For library/streaming tracks the URI is unique per song and stays
        // stable across the transient empty-metadata flashes some services
        // emit during the transition, so we keep using URI alone.
        //
        // During a metadata fill-in (title arrives but artist hasn't yet),
        // we hold the key at bare URI to avoid double-firing the task.
        if let uri = trackMetadata.trackURI, !uri.isEmpty {
            if Self.isRadioURI(uri) {
                guard !trackMetadata.title.isEmpty, !trackMetadata.artist.isEmpty else {
                    return uri
                }
                return "\(uri)|\(trackMetadata.title)|\(trackMetadata.artist)"
            }
            return uri
        }
        return "\(trackMetadata.title)|\(trackMetadata.artist)"
    }

    private static func isRadioURI(_ uri: String) -> Bool {
        uri.hasPrefix("x-rincon-mp3radio:")
            || uri.hasPrefix("x-sonosapi-stream:")
            || uri.hasPrefix("x-sonosapi-radio:")
            || uri.hasPrefix("x-sonosapi-hls:")
            || uri.hasPrefix("x-sonosapi-hls-static:")
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
        .onChange(of: ctxVM.lyricsOffset) { _, newValue in
            // Debounced save so a tap-tap-tap of `+1 +1 +1` writes once
            // at the final +3 instead of three times. 500 ms is short
            // enough to feel persistent ("I tapped, it stuck") but long
            // enough to coalesce a flurry of taps.
            ctxVM.scheduleOffsetSave(newValue, metadata: trackMetadata)
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
            switch ctxVM.lyricsState {
            case .idle, .loading:
                loadingPlaceholder(text: L10n.lookingUpLyrics)
            case .loaded:
                if let lyrics = ctxVM.lyrics {
                    renderedLyrics(lyrics)
                } else {
                    emptyPlaceholder(icon: "text.alignleft",
                                     text: L10n.noLyricsFound)
                }
            case .missing:
                emptyPlaceholder(icon: "text.alignleft",
                                 text: L10n.noLyricsFound)
            case .error(let msg):
                emptyPlaceholder(icon: "exclamationmark.triangle",
                                 text: L10n.couldNotLoadLyricsFormat(msg))
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
        } else if let synced = lyrics.synced {
            VStack(spacing: 6) {
                SlidingLyricsView(
                    lines: Lyrics.parseSynced(synced),
                    position: positionSeconds + ctxVM.lyricsOffset,
                    isPlaying: isPlaying
                )
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
                .onTapGesture { ctxVM.lyricsOffset = 0 }
                .help(L10n.tapToResetOffset)
            offsetButton(label: "+1", delta: 1)
            offsetButton(label: "+5", delta: 5)
            offsetButton(label: "+10", delta: 10)
        }
        .padding(.bottom, 4)
    }

    private func offsetButton(label: String, delta: Double) -> some View {
        Button(label) { ctxVM.lyricsOffset += delta }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .font(.caption.monospacedDigit())
    }

    private var offsetDisplayString: String {
        let value = ctxVM.lyricsOffset
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .contextMenu {
                Button {
                    Task { await ctxVM.refreshAbout(trackMetadata) }
                } label: {
                    Label(L10n.refreshMetadata, systemImage: "arrow.clockwise")
                }
                .disabled(trackMetadata.title.isEmpty)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                let entries = matchingHistory()
                if entries.isEmpty {
                    emptyPlaceholder(icon: "clock",
                                     text: L10n.noPreviousPlaysInHistory)
                } else {
                    historySummary(entries)
                    Divider().padding(.vertical, 4)
                    Text(L10n.recentPlays).font(.body.weight(.semibold))
                    ForEach(Array(entries.prefix(20))) { entry in
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

// MARK: - SlidingLyricsView

/// Karaoke-style synced lyrics. Shows a fixed window of seven rows,
/// active line locked in the middle, lines fade as they move further
/// from centre, smooth slide as the track plays. The fixed-window
/// approach reads better than free-scroll auto-centering — your eye
/// always knows where the next line will appear.
private struct SlidingLyricsView: View {
    let lines: [(time: Double, line: String)]
    /// Authoritative position from Sonos. Updated in 0.5s steps from
    /// the parent's progress timer; the `TimelineView` below keeps
    /// the visual offset advancing continuously between updates.
    let position: Double
    let isPlaying: Bool

    private let visibleRows = 5
    private let rowHeight: CGFloat = 34
    private var centreRow: Int { visibleRows / 2 }

    /// Anchor point: the position Sonos reported, plus the wall-clock
    /// time when we received that report. Between Sonos updates we
    /// project forward as `anchorPosition + (now - anchorTime)`,
    /// which gives frame-perfect continuous scrolling. New Sonos
    /// updates rebase the anchor — for small drifts that's invisible
    /// (the new estimate matches the projected one); for big jumps
    /// (seek / track skip) the offset snaps.
    @State private var anchorPosition: Double = 0
    @State private var anchorTime: Date = .distantPast

    var body: some View {
        let windowHeight = CGFloat(visibleRows) * rowHeight
        // TimelineView drives a re-render every animation frame
        // (~30 fps default). Each frame, we estimate the current
        // playhead from the anchor and recompute the offset and
        // per-line scale. The Sonos position updates only ever touch
        // the anchor; they never drive the visible motion directly.
        // No `minimumInterval` — let SwiftUI run at the display's
        // native refresh rate (60Hz / 120Hz on ProMotion). Capping
        // at 30Hz produced visible stepping on standard displays.
        TimelineView(.animation) { context in
            let liveFractional = fractionalIndex(for: estimatedPosition(at: context.date))
            let offset = CGFloat(Double(centreRow) - liveFractional) * rowHeight
            VStack(spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, entry in
                    lyricLine(
                        entry.line,
                        distance: abs(Double(index) - liveFractional)
                    )
                    .frame(height: rowHeight)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .offset(y: offset)
            .frame(maxWidth: .infinity, minHeight: windowHeight,
                   maxHeight: windowHeight, alignment: .top)
            .clipped()
            .mask(centreFocusMask)
        }
        .onAppear {
            anchorPosition = position
            anchorTime = Date()
        }
        // Drift-tolerant rebasing. Most Sonos position updates arrive
        // at almost exactly the value we'd project from wall-clock
        // elapsed time, so re-anchoring on every update introduced
        // sub-millisecond offset jumps that the eye picked up as
        // flicker.
        //
        // Now we ignore small drifts (<0.5s — the natural noise
        // floor of Sonos's polling cadence) and only rebase when the
        // projection has genuinely fallen out of sync. Big jumps
        // (>5s — a seek, scrub, or track change) still snap.
        .onChange(of: position) { _, newValue in
            let now = Date()
            let estimated = estimatedPosition(at: now)
            let drift = newValue - estimated
            if abs(drift) > 5.0 {
                // Seek / track change — snap.
                anchorPosition = newValue
                anchorTime = now
            } else if abs(drift) > 0.5 {
                // Real drift between Sonos's authoritative time and
                // our wall-clock projection. Rebase smoothly.
                anchorPosition = newValue
                anchorTime = now
            }
            // Drift ≤ 0.5s: ignore. Let the TimelineView keep
            // projecting from the existing anchor — that's the
            // continuous-flow path and the smoothest visual.
        }
        // Pause: freeze the anchor at the current estimated position
        // so projection halts. Resume: rebase to whatever the parent
        // reports right now.
        .onChange(of: isPlaying) { _, nowPlaying in
            let now = Date()
            if !nowPlaying {
                anchorPosition = estimatedPosition(at: now)
                anchorTime = now
            } else {
                anchorPosition = position
                anchorTime = now
            }
        }
    }

    /// Continuously-projected playhead. While playing, equals the
    /// anchored position plus elapsed wall-clock time since anchor.
    /// While paused, equals the anchored position exactly (frozen).
    private func estimatedPosition(at now: Date) -> Double {
        guard isPlaying, anchorTime != .distantPast else {
            return anchorPosition
        }
        return anchorPosition + now.timeIntervalSince(anchorTime)
    }

    /// Continuous fractional position of `pos` within the line list.
    /// Whole numbers = a line is dead-centre; halves = between two
    /// lines. Negative = pre-roll, scaled so the first line glides
    /// in from below as the song approaches its first lyric stamp.
    private func fractionalIndex(for pos: Double) -> Double {
        guard !lines.isEmpty else { return 0 }
        var prevIdx = -1
        var nextIdx = -1
        for (i, entry) in lines.enumerated() {
            if entry.time <= pos {
                prevIdx = i
            } else {
                nextIdx = i
                break
            }
        }
        if prevIdx < 0 {
            guard let firstTime = lines.first?.time, firstTime > 0 else { return 0 }
            return (pos / firstTime) - 1.0
        }
        if nextIdx < 0 {
            return Double(prevIdx)
        }
        let prevTime = lines[prevIdx].time
        let nextTime = lines[nextIdx].time
        let span = nextTime - prevTime
        if span <= 0 { return Double(prevIdx) }
        let progress = (pos - prevTime) / span
        return Double(prevIdx) + min(max(progress, 0), 1)
    }

    /// Lyric line with distance-based font scaling. The closer a
    /// line is to the centre (distance ≈ 0), the larger and bolder
    /// it renders; lines further away shrink toward `.body` size.
    /// Combined with the alpha gradient mask, this produces a
    /// karaoke-style pull toward the active lyric without painting
    /// any single line specially.
    @ViewBuilder
    private func lyricLine(_ text: String, distance: Double) -> some View {
        // Smooth size scaling: full size at centre, tapering to
        // baseline by distance == 2. Beyond that it stays at the
        // baseline (these lines are mostly faded out by the mask
        // anyway).
        let clamped = min(max(distance, 0), 2.0)
        let baseSize: CGFloat = 13   // ~.body
        let peakSize: CGFloat = 19   // bigger than .title3 for impact
        let t = 1.0 - (clamped / 2.0) // 1 at centre, 0 at edges
        let size = baseSize + (peakSize - baseSize) * CGFloat(t)
        // Weight ramps similarly: bold near centre, regular far away.
        let weight: Font.Weight = t > 0.65 ? .bold
                                : t > 0.30 ? .semibold
                                            : .regular
        Text(text)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(Color.primary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .padding(.horizontal, 16)
            // No `.textSelection` here — the lines are moving
            // continuously via the TimelineView, which makes SwiftUI's
            // hit-testing flaky for siblings (the About / History tab
            // buttons above were sometimes unclickable). Plain
            // (un-synced) lyrics keep selection enabled.
            .allowsHitTesting(false)
    }

    private var centreFocusMask: some View {
        LinearGradient(
            stops: [
                .init(color: Color.black.opacity(0.12), location: 0.00),
                .init(color: Color.black.opacity(0.55), location: 0.30),
                .init(color: Color.black.opacity(1.00), location: 0.50),
                .init(color: Color.black.opacity(0.55), location: 0.70),
                .init(color: Color.black.opacity(0.12), location: 1.00),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

