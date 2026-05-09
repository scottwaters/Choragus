/// ClubVisWindow.swift — Fullscreen-capable "club" visualisation popout.
///
/// Designed around the back wall of a live music venue: a tiled
/// poster wall under warm bar lighting, with the current track in
/// the foreground.
///
/// Tile-pool selection rules:
///   1. If queue is the active playback source, queue items'
///      artwork is the seed pool.
///   2. Plus history rows whose `genre` matches any genre attached
///      to a queue item (case-insensitive; partial / full match
///      governed by `VisGenreMatchMode.current`).
///   3. Plus a sprinkle of pure-random history art whose size is
///      `UDKey.visRandomSprinklePercent` of the cell count — fires
///      every refresh, including queue mode.
///   4. Radio-stream URIs are excluded at every step — only real
///      album art enters the wall.
///   5. Pool is deduplicated. If the pool is shorter than the slot
///      count, the deficit slots stay blank — never duplicate a URL
///      across cells.
///
/// The lighting layer uses a fixed warm bar palette (amber / magenta
/// / indigo). v2 will sample dominant colours from the now-playing
/// artwork so the lighting also encodes album mood; flagged in
/// `ClubVisLightingView` below.
///
/// The whole stage is laid out at logical 1920×1080 inside a
/// `GeometryReader` scaler, so the same code fullscreens cleanly to
/// native 4K and any 16:9 size in between.
import SwiftUI
import SonosKit

/// Gated wrapper around `sonosDebugLog` for [VIS] lines. Read each
/// call from the debug-state singleton so the toggle flips live.
@MainActor
fileprivate func visLog(_ msg: String) {
    if BackOfTheClubDebugState.shared.visLoggingEnabled {
        sonosDebugLog("[VIS] \(msg)")
    }
}

struct ClubVisWindow: View {
    @EnvironmentObject var sonosManager: SonosManager
    @EnvironmentObject var playHistoryManager: PlayHistoryManager
    @EnvironmentObject var metadataServicesHolder: MusicMetadataServiceHolder
    /// Live-tunable lighting parameters surfaced from the debug
    /// companion window. Read in the stage to drive the black
    /// multiply opacity and propagated into ClubVisLightingView via
    /// its own ObservedObject reference.
    @ObservedObject private var debugState = BackOfTheClubDebugState.shared

    /// Re-read on each refresh so a settings change applies at the
    /// next track-change tick (the next pool rebuild).
    @AppStorage(UDKey.visRandomSprinklePercent) private var visRandomSprinklePercent: Double = 5.0
    /// Toggle for the bottom-right About panel — defaults to on.
    @AppStorage(UDKey.visShowAboutPanel) private var visShowAboutPanel: Bool = true

    let groupID: String

    /// Lazily constructed once the group is in hand. Held in a tiny
    /// `ObservableObject` wrapper so we can build it from `.task`
    /// without colliding with `@StateObject`'s default-init phase.
    @StateObject private var queueHolder = ClubVisQueueHolder()

    /// Image bytes resolved up-front from `ImageCache.shared`. The
    /// Canvas draw closure runs every frame; doing 96 disk reads per
    /// frame would tank scrolling and waste CPU. Pre-resolved here
    /// when the tile set changes.
    @State private var preloaded: [URL: NSImage] = [:]

    /// Tiered tile pool — preferred URLs (queue / current artist /
    /// similar artists) take large slots first; fallback URLs (genre
    /// matches + random sprinkle) take small slots and overflow.
    @State private var pool: TilePool = .empty
    /// Bumped on every track change so `ClubVisWallView` can run a
    /// few extra "seed" fade-swaps using the new track's primary
    /// genre — the wall reacts visibly to the track change beyond
    /// just the diff path.
    @State private var trackChangeSwapTrigger: Int = 0
    /// Bumped when `settledArtURL` changes (track-key change OR a
    /// later iTunes resolution landing). The WallView listens and
    /// fades the anchor 4×4 to the new hero — bypassing the
    /// settle window so a station-logo→real-art transition lands
    /// even when the rebuild has just finished.
    @State private var heroUpdateTrigger: Int = 0

    /// Identity for the WallView — when this changes, SwiftUI tears
    /// down the old WallView and creates a new one (which runs
    /// wholesaleFill on its empty state). Only updated when we WANT
    /// a fresh layout (natural end-of-track via pre-fade). Manual
    /// track changes leave wallId alone so the existing WallView's
    /// diff path handles per-tile content changes — no full reset.
    @State private var wallId: UInt32 = 0
    /// Seed driving `slots` (the layout). Same lifecycle as wallId —
    /// only refreshes on natural end-of-track. Holding it as @State
    /// (rather than as a computed property of trackURI) means manual
    /// track changes don't reshuffle the geometry.
    @State private var layoutSeed: UInt32 = 0
    /// Opacity binding driving the fade-to-black / fade-back-in
    /// sequence applied to the wall layer (and the lighting layer
    /// behind it). Lets the .black background of ClubVisWindow show
    /// through during the swap.
    /// Opacity of the rebuild "black cover" layered on top of the
    /// wall + lighting. 0 = wall visible, 1 = solid black covering
    /// everything below the now-playing card. Animated during a
    /// rebuild instead of fading the wall view itself — fading the
    /// wall meant the `.id(wallId)` change happened during the
    /// opacity tween and SwiftUI's view-recreation could briefly
    /// render the new wall at full opacity (the user-visible
    /// "off → on → fade-in" flicker on source change). With the
    /// cover approach, the wall stays at opacity 1 and the seed
    /// swap happens behind a fully-opaque black layer.
    /// Black cover overlaid on the wall — opaque on first appearance,
    /// then faded out by the initial-cover-fade task once wholesaleFill
    /// has had a chance to populate slotURLs. Without this default the
    /// wall materialised instantly on launch (wholesaleFill commits
    /// slotURLs directly, no fade animation), which the user reported
    /// as "no fade in".
    @State private var wallCoverOpacity: Double = 1.0
    @State private var hasInitialCoverFaded: Bool = false

    /// Guards against overlapping `performRebuildSequence` calls. A
    /// source change typically fires BOTH `.queueChanged` (which
    /// does the full reload + `forceWallRebuild`) AND
    /// `.task(id: trackMetadata.trackURI)` (which detects the mode
    /// change and runs the cadence rebuild). Without this flag the
    /// two sequences interleave and the user sees a triple
    /// fade-out / fade-in / fade-out / fade-in pattern.
    @State private var rebuildInProgress: Bool = false
    /// Tracks since the last full wall rebuild. The rule is "rebuild
    /// every 3 track changes AND at least 60 s elapsed since the
    /// last rebuild" — both conditions must hold. Counter resets on
    /// rebuild.
    @State private var tracksSinceRebuild: Int = 0
    @State private var lastWallRebuildAt: Date = Date()
    /// Stamp used by the cooldown gate inside performRebuildSequence.
    /// Distinct from `lastWallRebuildAt` (which seeds the 60-s
    /// cadence warmup at view creation). Cooldown should NOT block
    /// the first rebuild after open, so this defaults to
    /// `.distantPast`. Set at performRebuildSequence END.
    @State private var lastRebuildEndAt: Date = .distantPast

    /// Debounce holder for `rebuildTiles`. Multiple cascading
    /// callers (track URI change → similarArtists fetch →
    /// settledArtURL set → iTunes resolve → another settledArtURL
    /// set → downloadNowPlayingArt → its internal rebuildTiles)
    /// were each triggering a fresh chooseTiles + pool publish in
    /// quick succession (7+ in 2 s in the captured log). Each pool
    /// publish triggered diffFill, which created 30+ fades, which
    /// stacked up to 110+ in-flight tile fades. Debouncing
    /// collapses bursts into a single rebuild.
    @State private var rebuildTilesDebounceTask: Task<Void, Never>?

    /// Cancellable task for the settledArtURL → download → heroBump
    /// chain. settledArtURL can flip 3 × per track (DIDL → history
    /// art → iTunes resolve), and the previous code spawned a fresh
    /// Task each time → 3 concurrent downloads + rebuildTiles + hero
    /// bumps. Cancelling the prior task collapses the burst into one.
    @State private var settledArtTask: Task<Void, Never>?

    /// Pinned ambient URL sample. `chooseTiles` used to re-shuffle
    /// `entries` on every call, producing a different ambient set
    /// every rebuildTiles. With 5,000+ history entries and 800
    /// sampled, ~84 % of the previous sample wasn't in the new one;
    /// diffFill flagged those URLs as "evicted" and faded them out
    /// — every track change re-shuffled the wall. Pinned for the
    /// lifetime of the current `wallId`; cleared when `wallId`
    /// changes via the `pinnedAmbientForWallId` mismatch.
    @State private var pinnedAmbientSample: [URL] = []
    @State private var pinnedAmbientForWallId: UInt32 = 0
    /// Last-seen playback mode signature (radio / queue / service
    /// id). When this changes between tracks (queue → radio, radio →
    /// queue, Spotify → Apple Music, etc.), the wall force-rebuilds
    /// regardless of the track-count + time gating, because the new
    /// source is a meaningful enough context shift to warrant fresh
    /// layout.
    @State private var lastPlaybackModeKey: String = ""
    /// Sonos metadata churn during a track change can briefly flip
    /// `playbackModeKey` (e.g. service:204 → queue → service:204 in 2s)
    /// because the trackURI loses its sid query parameter momentarily.
    /// Without a settle window each flip would fire its own rebuild.
    @State private var modeChangeDebounceTask: Task<Void, Never>?

    /// Memorial overlay visibility. See `maybeShowMemorialOverlay`
    /// for the rate-limited random gating.
    @State private var memorialOverlayVisible: Bool = false
    @State private var memorialOverlayOpacity: Double = 0.0

    /// Vis-card art held over until the new track has SETTLED
    /// metadata. Prevents the card from briefly showing a station
    /// logo / generic placeholder during the gap between track-end
    /// and the new track's title+artist arriving (or during ad
    /// breaks, station-ID frames, etc.). See `settledTrackKey` for
    /// the unsettled detection criteria.
    @State private var settledArtURL: URL? = nil

    /// iTunes-resolved track art for the current settled track.
    /// Mirrors the `ArtResolver.radioTrackArtURL` flow from
    /// `NowPlayingView` so the Vis doesn't end up showing a station
    /// logo while the regular now-playing card has already
    /// resolved the actual album cover. Re-fetched per track-key
    /// change; only adopted into `settledArtURL` when the resolved
    /// key still matches the current settled track.
    @State private var iTunesResolvedArtURL: URL? = nil
    @State private var iTunesResolvedKey: String = ""

    /// Resolved slot rects — cached. The packer is non-trivial
    /// (cluster check is O(N²) over already-placed large rects) and
    /// running it on every body re-eval was a major source of
    /// fade-in stutter: any `@Published` change on `debugState` —
    /// e.g. `publishDebugState` updating poolRows on rebuildTiles —
    /// would re-evaluate `ClubVisWindow.body`, recompute the entire
    /// layout, hand a fresh `[WallSlot]` to `ClubVisWallView`, and
    /// thrash the canvas. Now we recompute only when `layoutSeed`
    /// actually changes (debug "Rebuild wall", forceWallRebuild,
    /// cadence rebuild).
    @State private var resolvedSlots: [WallSlot] = []

    private func recomputeSlots() {
        var config = WallSlotPacker.Config.default
        #if DEBUG
        let s = BackOfTheClubDebugState.shared
        config.count4x4 = s.packerCount4x4
        config.count3x3 = s.packerCount3x3
        config.count2x2 = s.packerCount2x2
        config.maxLargeNeighbours = s.packerMaxLargeNeighbours
        config.maxLargeComponent = s.packerMaxLargeComponent
        #endif
        resolvedSlots = WallSlotPacker.pack(seed: layoutSeed,
                                            cols: ClubVisWallView.cols,
                                            rows: ClubVisWallView.rows,
                                            cellSize: ClubVisWallView.cellSize,
                                            originX: ClubVisWallView.originX,
                                            originY: ClubVisWallView.originY,
                                            config: config)
    }

    /// Lower-cased artist names returned by `MusicMetadataService.artistInfo`
    /// for the now-playing track. Powers the streaming-mode "similar
    /// artists go on smaller large tiles" tier. Cleared when the track
    /// changes; re-fetched async.
    @State private var nowPlayingSimilarArtists: Set<String> = []

    /// Full `ArtistInfo` for the now-playing artist — bio + tags drive
    /// the scrolling About panel in the bottom-right of the stage.
    @State private var nowPlayingArtistInfo: ArtistInfo? = nil

    private var trackMetadata: TrackMetadata {
        sonosManager.groupTrackMetadata[groupID] ?? TrackMetadata()
    }

    private var group: SonosGroup? {
        sonosManager.groups.first(where: { $0.coordinatorID == groupID })
    }

    /// Per-track seed — derived from the current track URI / title
    /// (or groupID on the very first frame before metadata is set).
    /// Mixing `trackChangeSwapTrigger` here was tempting but causes
    /// a double-recreate (one when trackURI changes, one when the
    /// trigger increments inside .task). URI hash alone changes per
    /// track and is sufficient to vary the seed.
    private var packerSeed: UInt32 {
        let trackKey = trackMetadata.trackURI ?? trackMetadata.title
        let base = trackKey.isEmpty
            ? (groupID.isEmpty ? "club-vis" : groupID)
            : trackKey
        return UInt32(truncatingIfNeeded: UInt64(bitPattern: Int64(base.hashValue)))
    }

    /// Resolved now-playing art. Prefers a play-history entry's URL
    /// (populated by NowPlayingView's `ArtResolver` after iTunes
    /// search resolves) over `trackMetadata.albumArtURI` — which on
    /// radio is the station logo, not the actual track art. The
    /// history-resolved URL may take a second or two to land after
    /// a track change; the now-playing card's `.transition(.opacity)`
    /// fades from station logo to resolved art when it appears.
    /// Speaker `/getaa?` proxy URLs are skipped — they're ephemeral
    /// and frequently return placeholder for direct streams.
    private var nowPlayingArtURL: URL? {
        let title = trackMetadata.title.lowercased()
        let artist = trackMetadata.artist.lowercased()
        if !title.isEmpty {
            for entry in playHistoryManager.entries.reversed() {
                guard entry.title.lowercased() == title,
                      entry.artist.lowercased() == artist else { continue }
                if let raw = entry.albumArtURI, !raw.isEmpty,
                   !raw.contains("/getaa?"),
                   let url = URL(string: raw) {
                    return url
                }
                break
            }
        }
        if let raw = trackMetadata.albumArtURI, !raw.isEmpty,
           let url = URL(string: raw) {
            return url
        }
        return nil
    }

    /// True when the current playback is a radio stream — used to
    /// hide the Up Next list (not relevant for radio) and to label
    /// the source on the now-playing card.
    private var isRadioPlayback: Bool {
        trackMetadata.isRadioStream || !trackMetadata.stationName.isEmpty
    }

    /// Per-track key that ONLY changes when the track has settled
    /// metadata. Returns "unsettled" during ad breaks, empty title
    /// frames, station-ID frames (title equals stationName), or any
    /// frame where artist is empty (still loading). The vis card's
    /// art only updates when this transitions from one settled key
    /// to a different settled key — never during the unsettled
    /// transition, so the card holds the previous art across the
    /// gap instead of flashing the station logo.
    private var settledTrackKey: String {
        if trackMetadata.isAdBreak { return "unsettled" }
        guard !trackMetadata.title.isEmpty,
              !trackMetadata.artist.isEmpty else { return "unsettled" }
        if !trackMetadata.stationName.isEmpty,
           trackMetadata.title.caseInsensitiveCompare(trackMetadata.stationName) == .orderedSame {
            return "unsettled"
        }
        return "\(trackMetadata.title)|\(trackMetadata.artist)"
    }

    /// Compact signature for the current playback source — used by
    /// the wall-rebuild rule to detect mode/service shifts. Returns
    /// "radio" for any radio stream (incl. Sonos Radio / TuneIn /
    /// HLS), "service:NN" with the sid for SMAPI services, "local"
    /// for library files, "queue" for plain queue playback.
    private var playbackModeKey: String {
        if isRadioPlayback { return "radio" }
        if let uri = trackMetadata.trackURI {
            let lower = (uri.removingPercentEncoding ?? uri).lowercased()
            if let range = lower.range(of: "sid=") {
                let numStr = String(lower[range.upperBound...].prefix(while: { $0.isNumber }))
                if !numStr.isEmpty { return "service:\(numStr)" }
            }
            if URIPrefix.isLocal(uri) { return "local" }
        }
        return "queue"
    }

    /// Short source label for the now-playing card's bottom strip.
    /// Examples: "Sonos Radio", "TuneIn", "Spotify", "Local Library",
    /// "Queue".
    private var sourceLabel: String {
        if !trackMetadata.stationName.isEmpty {
            return trackMetadata.stationName
        }
        if let uri = trackMetadata.trackURI {
            if URIPrefix.isLocal(uri) { return ServiceName.musicLibrary }
            if URIPrefix.isRadio(uri) { return ServiceName.radio }
            let lower = (uri.removingPercentEncoding ?? uri).lowercased()
            if lower.contains("spotify") { return ServiceName.spotify }
            if lower.contains("apple") { return ServiceName.appleMusic }
            if lower.contains("amazon") || lower.contains("amzn") { return ServiceName.amazonMusic }
            if let range = lower.range(of: "sid=") {
                let numStr = String(lower[range.upperBound...].prefix(while: { $0.isNumber }))
                if let sid = Int(numStr), let name = ServiceID.knownNames[sid] { return name }
            }
        }
        if trackMetadata.isQueueSource { return "Queue" }
        return ""
    }

    var body: some View {
        GeometryReader { geo in
            // Logical canvas is 1920×1080; scale uniformly to whatever
            // size AppKit hands us. The content aspect ratio is locked
            // to 16:9 at the window level (see `WindowManager.openClubVis`),
            // so width-derived scale matches height-derived scale.
            let scale = geo.size.width / Self.logicalWidth
            stage
                .frame(width: Self.logicalWidth, height: Self.logicalHeight,
                       alignment: .topLeading)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: geo.size.width, height: geo.size.height,
                       alignment: .topLeading)
        }
        .background(.black)
        .preferredColorScheme(.dark)
        .task {
            // Build the queue VM once the group is alive.
            if let g = group, queueHolder.vm == nil {
                let vm = QueueViewModel(sonosManager: sonosManager, group: g)
                queueHolder.vm = vm
                await vm.loadQueue()
                vm.updateCurrentTrack()
            }
            // Initialise settled art if track is already settled at
            // open. Otherwise leave nil and let the .onChange land it
            // when metadata stabilises.
            if settledTrackKey != "unsettled" {
                settledArtURL = nowPlayingArtURL
                // iTunes radio-track-art lookup is only for radio: the
                // DIDL art on radio is the station logo, not the song.
                // For service streams (Apple Music, Spotify, etc.) the
                // DIDL already carries the correct album cover, and an
                // iTunes search by title+artist returns hits ordered
                // by popularity rather than the actually-playing
                // album — so a track that exists on both an album and
                // a compilation/soundtrack would resolve to the wrong
                // cover (e.g. "Like a Surgeon" on Dare to Be Stupid
                // resolved to a different Weird Al album cover).
                let title = trackMetadata.title
                let artist = trackMetadata.artist
                if isRadioPlayback, !title.isEmpty, !artist.isEmpty {
                    Task { @MainActor in
                        guard let raw = await AlbumArtSearchService.shared.searchRadioTrackArt(
                            artist: artist, title: title),
                              let url = URL(string: raw) else { return }
                        if settledTrackKey == "\(title)|\(artist)" {
                            iTunesResolvedKey = "\(title)|\(artist)"
                            iTunesResolvedArtURL = url
                            settledArtURL = url
                        }
                    }
                }
            }
            maybeShowMemorialOverlay()
            // Kick off genre backfill so genre-matching has fresh data
            // to chew on; the rebuild loop below picks up new tags
            // when `playHistoryManager.genreVersion` republishes.
            // Run rebuild immediately on open — the wall populates
            // from whatever is already known about the running track,
            // then refines as backfill resolves. Earlier explicit
            // blanking ran the wall empty for an excess time.
            Task { @MainActor in
                // On Vis open, run a heavier first-pass backfill (300
                // artists vs 100 default) and seed the priority list
                // with the queue's distinct artists so the wall's
                // genre context locks in fast even on a 5,000-entry
                // history.
                let priority = queueHolder.vm?.queueItems.map(\.artist) ?? []
                await playHistoryManager.backfillMissingGenres(
                    using: metadataServicesHolder.service,
                    maxArtists: 300,
                    priorityArtists: priority)
            }
            await rebuildTiles()
        }
        .task(id: trackMetadata.trackURI) {
            // Track changed (or initial load). Backfill is small (5
            // artists) but prioritises the new track's artist + the
            // queue items so genre matching tracks the playback.
            queueHolder.vm?.updateCurrentTrack()
            Task { @MainActor in
                var priority = [trackMetadata.artist]
                if trackMetadata.isQueueSource,
                   let qi = queueHolder.vm?.queueItems {
                    priority.append(contentsOf: qi.map(\.artist))
                }
                await playHistoryManager.backfillMissingGenres(
                    using: metadataServicesHolder.service,
                    maxArtists: 5,
                    priorityArtists: priority)
            }
            let artist = trackMetadata.artist
            if !artist.isEmpty {
                let fetchStart = Date()
                visLog("about — artistInfo fetch START artist=\(artist)")
                Task { @MainActor in
                    let info = await metadataServicesHolder.service.artistInfo(name: artist)
                    // Detached Task — `.task(id:)` cancellation
                    // doesn't reach here. Guard against landing a
                    // stale prior-artist's bio AFTER the user has
                    // moved on to a new track. Previously this
                    // produced "Blondie playing, Killers bio shown"
                    // when fetch latencies overlapped track changes.
                    guard trackMetadata.artist == artist else {
                        visLog("about — artistInfo DISCARDED artist=\(artist) (now=\(trackMetadata.artist)) — late arrival")
                        return
                    }
                    if let info {
                        let ms = Int(Date().timeIntervalSince(fetchStart) * 1000)
                        let bioLen = info.bio?.count ?? 0
                        visLog("about — artistInfo fetch END artist=\(artist) ms=\(ms) bioLen=\(bioLen) similar=\(info.similarArtists.count) tags=\(info.tags.count) wiki=\(info.wikipediaURL != nil)")
                        nowPlayingArtistInfo = info
                        nowPlayingSimilarArtists = Set(info.similarArtists.map { $0.lowercased() })
                    } else {
                        let ms = Int(Date().timeIntervalSince(fetchStart) * 1000)
                        visLog("about — artistInfo fetch END artist=\(artist) ms=\(ms) result=nil")
                        nowPlayingArtistInfo = nil
                        nowPlayingSimilarArtists = []
                    }
                }
            } else {
                visLog("about — artistInfo SKIP (empty artist)")
                nowPlayingArtistInfo = nil
                nowPlayingSimilarArtists = []
            }
            await rebuildTiles()
            trackChangeSwapTrigger &+= 1

            // Wall-rebuild rule. Two trigger paths:
            //   1. Cadence: every 3rd track change AND ≥60 s elapsed
            //      since the last rebuild. Both must hold.
            //   2. Source/mode change: queue → radio, radio → queue,
            //      or service-id swap (Spotify → Apple Music etc.).
            //      Forces an immediate rebuild regardless of cadence
            //      because the new context is a meaningful shift.
            tracksSinceRebuild += 1
            let elapsed = Date().timeIntervalSince(lastWallRebuildAt)
            let currentMode = playbackModeKey
            let previousMode = lastPlaybackModeKey
            let modeChanged = !previousMode.isEmpty
                && currentMode != previousMode

            let cadenceTrigger = tracksSinceRebuild >= 3 && elapsed >= 60
            visLog("track tick — tracksSince=\(tracksSinceRebuild) elapsed=\(Int(elapsed))s mode=\(previousMode)→\(currentMode) modeChanged=\(modeChanged) cadenceTrigger=\(cadenceTrigger)")

            if cadenceTrigger {
                lastPlaybackModeKey = currentMode
                let reason = "cadence(tracks=\(tracksSinceRebuild),elapsed=\(Int(elapsed))s)"
                visLog("rebuild call — site=trackURI-task reason=\(reason)")
                // Detach so a subsequent trackURI change (which
                // cancels this `.task` closure) doesn't cut the
                // in-flight rebuild's 6.5 s sequence short.
                Task { @MainActor in
                    await performRebuildSequence(source: "trackURI-task[\(reason)]")
                }
            } else if modeChanged {
                // Debounce: defer 2s, then re-read playbackModeKey.
                // If mode reverted to baseline (Sonos metadata churn:
                // service:N → queue → service:N within 2s), drop it.
                let baseline = previousMode
                let observed = currentMode
                visLog("mode-change DEFERRED — \(baseline)→\(observed) waiting 2s to confirm")
                modeChangeDebounceTask?.cancel()
                modeChangeDebounceTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard !Task.isCancelled else { return }
                    let settled = playbackModeKey
                    if settled == baseline {
                        visLog("mode-change DEBOUNCED — \(baseline)→\(observed)→\(settled) reverted, no rebuild")
                        return
                    }
                    visLog("mode-change CONFIRMED — \(baseline)→\(settled) firing rebuild")
                    lastPlaybackModeKey = settled
                    await performRebuildSequence(source: "trackURI-task[mode-change(\(baseline)→\(settled))]")
                }
            } else {
                // Stable — keep the baseline current so the next change
                // compares against the latest known-good state.
                lastPlaybackModeKey = currentMode
            }
        }
        .onChange(of: playHistoryManager.entries.count) {
            scheduleRebuildTiles("entries.count")
        }
        .onChange(of: playHistoryManager.genreVersion) {
            scheduleRebuildTiles("genreVersion")
        }
        .onChange(of: nowPlayingSimilarArtists) {
            scheduleRebuildTiles("similarArtists")
        }
        .onChange(of: settledTrackKey) { _, newKey in
            // Track became settled (or transitioned to a different
            // settled track) — refresh the vis card art. Skip when
            // newKey is "unsettled" so the card holds the previous
            // settled art across the gap.
            guard newKey != "unsettled" else { return }
            // Drop any stale iTunes-resolved URL from the previous
            // track so we don't briefly display the wrong cover.
            if iTunesResolvedKey != newKey {
                iTunesResolvedArtURL = nil
            }
            settledArtURL = nowPlayingArtURL
            // Radio-only iTunes lookup — see the matching block in
            // `.task { … }` above for why we don't run this for
            // service streams (DIDL is already correct, iTunes
            // search returns wrong-album hits).
            let title = trackMetadata.title
            let artist = trackMetadata.artist
            guard isRadioPlayback, !title.isEmpty, !artist.isEmpty else { return }
            Task { @MainActor in
                guard let raw = await AlbumArtSearchService.shared.searchRadioTrackArt(
                    artist: artist, title: title),
                      let url = URL(string: raw) else { return }
                // Adopt only if the user is still on the same track.
                if settledTrackKey == "\(title)|\(artist)" {
                    iTunesResolvedKey = "\(title)|\(artist)"
                    iTunesResolvedArtURL = url
                    settledArtURL = url
                }
            }
        }
        .onChange(of: nowPlayingArtURL) { _, newArt in
            // History got an updated art URL for the current track
            // (e.g., the same iTunes URL just hit ImageCache via the
            // Now Playing card's ArtResolver). Apply only if settled
            // AND we don't already have a higher-quality
            // iTunes-resolved URL pinned for this track.
            guard settledTrackKey != "unsettled" else { return }
            if iTunesResolvedArtURL == nil {
                settledArtURL = newArt
            }
        }
        .onChange(of: settledArtURL) { _, newArt in
            visLog("settledArtURL changed → \(newArt?.absoluteString.suffix(60).description ?? "nil")")
            // Cancel any previous in-flight download/heroBump chain.
            // Multiple rapid settledArtURL changes (DIDL → history
            // art → iTunes resolve) used to fire 3 concurrent tasks,
            // each with its own download + rebuildTiles + hero bump.
            settledArtTask?.cancel()
            settledArtTask = Task { @MainActor in
                await downloadNowPlayingArt()
                guard !Task.isCancelled else { return }
                heroUpdateTrigger &+= 1
                visLog("heroUpdateTrigger bumped to \(heroUpdateTrigger)")
            }
            Task { @MainActor in await downloadNowPlayingArt() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .queueChanged)) { note in
            // The Sonos coordinator signalled a queue mutation. Two
            // shapes:
            //   1. Optimistic-append: items inline → fast-path; just
            //      append + diff-update tiles.
            //   2. Full-reload: queue was replaced. Reload the queue
            //      view-model + diff-update tiles. Earlier this path
            //      also forced a full wall rebuild (cover fade-IN +
            //      wallId swap + 6-second fade-OUT cycle) every time
            //      a queue mutation arrived, which was visually
            //      disruptive. Queue-only changes update the Up Next
            //      list and refresh the tile pool in place; rebuilds
            //      stay reserved for actual track changes / mode
            //      flips driven by `.task(id: trackURI)`.
            guard let vm = queueHolder.vm else { return }
            if let items = note.userInfo?[QueueChangeKey.optimisticItems] as? [QueueItem] {
                visLog("queueChanged — optimistic append (\(items.count) items), no rebuild")
                vm.optimisticallyAppend(items)
                Task { @MainActor in await rebuildTiles() }
            } else {
                visLog("queueChanged — full reload (queue + tiles diff, no wall rebuild)")
                Task { @MainActor in
                    await vm.loadQueue()
                    vm.updateCurrentTrack()
                    await rebuildTiles()
                }
            }
        }
        #if DEBUG
        .onChange(of: BackOfTheClubDebugState.shared.rebuildTrigger) {
            visLog("debug rebuildTrigger bumped → forceWallRebuild")
            Task { @MainActor in await forceWallRebuild(source: "debug-button") }
        }
        #endif
    }

    @ViewBuilder
    private var stage: some View {
        ZStack(alignment: .topLeading) {
            // Wrapping the wall in an animated ZStack keyed off the
            // packer seed gives a smooth cross-fade between wall states
            // when the track changes (the new wall slides into existence
            // with a new shuffle while the old one fades out).
            ZStack {
                // Gate on `wallId != 0`. Without the gate, the parent's
                // first body render uses the @State default `wallId = 0`,
                // SwiftUI instantiates a ClubVisWallView with `.id(0)`,
                // then `.onAppear` immediately reassigns wallId to
                // `packerSeed` and the second body render replaces it
                // with `.id(packerSeed)`. The transient `.id(0)` instance
                // spawned its own swap loop (visible as parallel `swap
                // loop started — id=1` and `id=2` lines on launch).
                if wallId != 0 {
                    ClubVisWallView(
                        pool: pool,
                        slots: resolvedSlots,
                        preloaded: preloaded,
                        seedSwapTrigger: trackChangeSwapTrigger,
                        heroUpdateTrigger: heroUpdateTrigger,
                        nowPlayingHeroURL: settledArtURL,
                        rebuildInProgress: rebuildInProgress,
                        coverOpacity: wallCoverOpacity
                    )
                    .id(wallId)
                }
            }
            .onAppear {
                // Initialise both seeds at view appear — `wallId == 0`
                // gates the WallView so it doesn't render with the
                // default seed for one frame.
                layoutSeed = packerSeed
                wallId = packerSeed
                recomputeSlots()

                // Initial cover fade-out: cover defaults to opaque so
                // the wall doesn't pop in instantly. Wait for
                // wholesaleFill to populate, then fade. Guarded so
                // subsequent .onAppear (re-entry from window
                // hide/show) doesn't replay the fade.
                if !hasInitialCoverFaded {
                    hasInitialCoverFaded = true
                    Task { @MainActor in
                        // Give wholesaleFill + initial pool population
                        // ~1.5s so the wall has art to reveal.
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        visLog("initial cover fade-OUT start (2.5s)")
                        withAnimation(.easeInOut(duration: 2.5)) {
                            wallCoverOpacity = 0.0
                        }
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        visLog("initial cover fade-OUT END coverOpacity=\(String(format: "%.2f", wallCoverOpacity))")
                    }
                }
            }
            .onChange(of: layoutSeed) { recomputeSlots() }
            // Wall saturation pinned at 0.10 — chosen base for the
            // venue-back-wall look. Lighting (`ClubVisLightingView`)
            // is the colour source. Do NOT raise this to make the
            // wall less dark — adjust the black multiply opacity
            // below or the lighting opacities instead.
            .saturation(0.10)

            // Lighting view applies its own per-layer blend modes
            // internally — outer wrapper just composites normally.
            // See `ClubVisLightingView.body`: ambient layer uses
            // `.color` blend (uniform hue replacement), spotlight
            // layer uses `.overlay` blend (focused accents). Earlier
            // outer `.softLight` blend produced near-zero tint on
            // the desaturated wall.
            // Lighting fades with the wall during track-change
            // resets so the screen genuinely goes black rather than
            // showing colored ambient ovals during the hold.
            ClubVisLightingView()

            // Darkening pass — opacity controlled by the debug
            // window's Lighting > Black multiply slider so it can
            // be tuned live. Default 0.45 is the venue-back-wall
            // brightness target.
            Color.black
                .blendMode(.multiply)
                .opacity(debugState.lighting.blackMultiplyOpacity)
                .allowsHitTesting(false)

            // Rebuild cover — opaque black during the seed-swap
            // window so the wall's `.id()` recreation happens
            // behind a solid layer with no visible flicker.
            Color.black
                .opacity(wallCoverOpacity)
                .allowsHitTesting(false)

            // Foreground readability scrim: lifts the now-playing card
            // and up-next list off the wall without obscuring the
            // middle band where the largest posters tend to sit.
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.65), location: 0.00),
                    .init(color: .black.opacity(0.05), location: 0.45),
                    .init(color: .black.opacity(0.00), location: 0.65),
                    .init(color: .black.opacity(0.55), location: 1.00),
                ],
                startPoint: .bottom, endPoint: .top
            )
            .allowsHitTesting(false)

            ClubVisNowPlayingCard(
                trackMetadata: trackMetadata,
                albumArtURL: settledArtURL,
                sourceLabel: sourceLabel,
                positionAnchor: sonosManager.groupPositionAnchors[groupID] ?? .zero
            )
            .frame(width: 820, height: 320, alignment: .leading)
            .position(x: 60 + 410, y: 1080 - 60 - 160)

            // Right column: 100 pt margin from the top edge AND the
            // right edge. When About is visible the queue sits in
            // the top half (40 pt gap separates them); when About
            // is hidden the queue drops to the bottom of the screen.
            // Show the Up Next list whenever there's an actual queue,
            // regardless of what `isRadioPlayback` says. Sonos populates
            // `stationName` for Spotify Radio / Apple Music DJ even
            // though the queue is still meaningful — gating on the
            // radio predicate hid the list across those tracks ("The
            // Riddle" via Spotify Radio was the trigger). Empty queue
            // (true radio) renders nothing → list naturally hidden.
            if let vm = queueHolder.vm, !vm.queueItems.isEmpty {
                let queueY: CGFloat = visShowAboutPanel
                    ? (100 + 210)              // top: 100..520
                    : (1080 - 100 - 210)       // bottom: 560..980
                ClubVisUpNextList(
                    queueItems: vm.queueItems,
                    currentTrack: vm.currentTrack
                )
                .frame(width: 380, height: 420)
                .position(x: 1920 - 100 - 190, y: queueY)
            }

            if visShowAboutPanel {
                ClubVisAboutPanel(artistInfo: nowPlayingArtistInfo)
                    .frame(width: 380, height: 420)
                    .position(x: 1920 - 100 - 190, y: 1080 - 100 - 210)
            }

            ClubVisLogoView()
                .frame(width: 320, height: 64)
                .position(x: 1920 / 2, y: 1080 - 40)

            // Memorial overlay — rate-limited random "in memory of"
            // splash (see `maybeShowMemorialOverlay`). Topmost layer
            // so it covers everything else when shown.
            if memorialOverlayVisible {
                ClubVisMemorialOverlay()
                    .opacity(memorialOverlayOpacity)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Tile build

    /// Builds the tile list and (on first call) the slot packing,
    /// then warms the in-memory image dictionary so the Canvas draw
    /// closure never blocks on disk. Subsequent calls — including
    /// every track change — reuse the existing slot layout. Track
    /// changes propagate through `pool` only, not slots, so
    /// `ClubVisWallView` can diff-and-fade rather than redrawing.
    /// Debounced wrapper — coalesce multiple rapid callers into a
    /// single rebuildTiles invocation 250 ms later. Replaces direct
    /// `await rebuildTiles()` calls from .onChange handlers.
    @MainActor
    private func scheduleRebuildTiles(_ callerHint: String) {
        rebuildTilesDebounceTask?.cancel()
        rebuildTilesDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await rebuildTiles(callerHint: callerHint)
        }
    }

    private func rebuildTiles(callerHint: String = #function) async {
        visLog("rebuildTiles ENTER — caller=\(callerHint) rebuilding=\(BackOfTheClubDebugState.shared.isWallRebuilding)")
        let chosen = chooseTiles()
        visLog("pool — preferred=\(chosen.preferred.count) t1=\(chosen.genreTier1.count) t2=\(chosen.genreTier2.count) t3=\(chosen.genreTier3.count) random=\(chosen.random.count) ambient=\(chosen.ambient.count) | isQueueMode=\(trackMetadata.isQueueSource) queueItems=\(queueHolder.vm?.queueItems.count ?? -1)")
        // `slots` is a computed property keyed on `packerSeed`, so it
        // refreshes automatically when the track changes — no need
        // to assign here.

        // Resolve pool images on a background queue. All tiers feed
        // the same image dict; size-aware assignment in the wall view
        // picks which URL each slot draws.
        let allURLs = chosen.preferred + chosen.similarArtists + chosen.genreTier1 + chosen.genreTier2 + chosen.genreTier3 + chosen.random + chosen.ambient + chosen.cacheBackfill
        let resolvedNew: [URL: NSImage] = await Task.detached(priority: .userInitiated) {
            var dict: [URL: NSImage] = [:]
            for url in allURLs {
                if let img = ImageCache.shared.image(for: url) {
                    dict[url] = img
                }
            }
            return dict
        }.value

        pool = chosen
        // Merge new resolutions on top of the existing dict — never
        // evict URLs we may still be fading out of, otherwise a
        // mid-fade slot loses its `oldImg` and pops to blank.
        preloaded.merge(resolvedNew) { _, new in new }

        #if DEBUG
        publishDebugState(pool: chosen)
        #endif

        // Background download of queue items' art that isn't yet in
        // ImageCache. Fire-and-forget so it doesn't block this
        // rebuild. Once the download completes the next rebuildTiles
        // call (track change, queue change, genre backfill, etc.)
        // picks up the now-cached URLs into `preferred`.
        if trackMetadata.isQueueSource {
            Task { @MainActor in await downloadQueueArtwork() }
        }
        // Backfill any pool URL that isn't yet in `preloaded`. The
        // chooseTiles cache gate is gone, so the pool now includes
        // history URLs the user has never visited; this downloader
        // fetches them so blank tiles fill in instead of sitting
        // black forever.
        Task { @MainActor in await downloadMissingPoolArt(allURLs: allURLs) }
    }

    /// Single download primitive used by every art-fetching path.
    /// Returns true if `preloaded[url]` is populated when the call
    /// completes — either because the bytes were already in
    /// ImageCache (we just copied the reference) or because the
    /// download succeeded. Returns false on network / decode error.
    /// URLSession with bounded per-request and per-resource timeouts.
    /// `URLSession.shared` defaults to 60 s, which let a single stuck
    /// Sonos `getaa` proxy URL block a fetch for ~48 s — long enough
    /// to stall pool warming on every track change. 8 s per request
    /// is plenty for legitimate 100 KB album art over LAN; anything
    /// slower is a stuck request that should be abandoned.
    private static let artFetchSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8.0
        config.timeoutIntervalForResource = 12.0
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    @MainActor
    private func fetchAndStore(_ url: URL) async -> Bool {
        let tag = url.lastPathComponent.suffix(40)
        if let cached = ImageCache.shared.image(for: url) {
            preloaded[url] = cached
            return true
        }
        let start = Date()
        do {
            let (data, _) = try await Self.artFetchSession.data(from: url)
            let netMs = Int(Date().timeIntervalSince(start) * 1000)
            guard let img = NSImage(data: data) else {
                visLog("art DECODE-FAIL — \(tag) bytes=\(data.count) netMs=\(netMs)")
                return false
            }
            ImageCache.shared.store(img, for: url)
            preloaded[url] = img
            if netMs > 500 {
                visLog("art SLOW — \(tag) netMs=\(netMs) bytes=\(data.count)")
            }
            return true
        } catch {
            let netMs = Int(Date().timeIntervalSince(start) * 1000)
            visLog("art FETCH-FAIL — \(tag) netMs=\(netMs) error=\(error.localizedDescription)")
            return false
        }
    }

    /// Concurrent background fetch (cap 6 in flight) of every URL
    /// not yet in `preloaded`. Wraps `fetchAndStore` with throttled
    /// concurrency for the bulk pool-warming case.
    @MainActor
    private func downloadMissingPoolArt(allURLs: [URL]) async {
        let unique = Array(Set(allURLs).filter { preloaded[$0] == nil })
        guard !unique.isEmpty else { return }
        visLog("downloadMissingPoolArt — \(unique.count) URLs to fetch")
        let maxConcurrent = 6
        var iter = unique.makeIterator()
        var fetched = 0
        var failed = 0

        await withTaskGroup(of: Bool.self) { group in
            var inflight = 0
            while inflight < maxConcurrent, let url = iter.next() {
                group.addTask { @MainActor in await self.fetchAndStore(url) }
                inflight += 1
            }
            for await ok in group {
                if ok { fetched += 1 } else { failed += 1 }
                if let next = iter.next() {
                    group.addTask { @MainActor in await self.fetchAndStore(next) }
                }
            }
        }
        visLog("downloadMissingPoolArt done — fetched=\(fetched) failed=\(failed) preloaded=\(preloaded.count)")
    }

    /// Pre-fetches each queue item's `albumArtURI` so chooseTiles
    /// can include them in `preferred` on the next rebuild.
    @MainActor
    private func downloadQueueArtwork() async {
        guard let queueItems = queueHolder.vm?.queueItems, !queueItems.isEmpty else { return }
        let urls: [URL] = queueItems.compactMap {
            guard let raw = $0.albumArtURI, !raw.isEmpty else { return nil }
            return URL(string: raw)
        }.filter { preloaded[$0] == nil }
        guard !urls.isEmpty else { return }
        var fetched = 0
        for url in urls where await fetchAndStore(url) { fetched += 1 }
        visLog("downloadQueueArtwork — needed=\(urls.count) fetched=\(fetched)")
        if fetched > 0 { await rebuildTiles() }
    }

    /// Pre-fetches the now-playing hero art and refreshes the pool
    /// so `pool.preferred.first` reflects the latest settledArtURL.
    /// Always calls `rebuildTiles()` even when the URL is already
    /// cached — chooseTiles reads `settledArtURL` for the hero, so
    /// a settledArtURL change without a corresponding rebuildTiles
    /// would leave `pool.preferred` stale and the WallView's
    /// anchor swap would no-op (it compares against the stale
    /// pool.preferred.first).
    @MainActor
    private func downloadNowPlayingArt() async {
        guard let url = settledArtURL else { return }
        if preloaded[url] == nil {
            if await fetchAndStore(url) {
                visLog("downloadNowPlayingArt — cached hero art")
            }
        }
        await rebuildTiles()
    }

    #if DEBUG
    private func publishDebugState(pool: TilePool) {
        let entries = playHistoryManager.entries
        var entryByURL: [String: (title: String, artist: String, album: String)] = [:]
        var entryByURLFull: [String: (title: String, artist: String, album: String, genre: String)] = [:]
        for entry in entries {
            guard let raw = entry.albumArtURI, !raw.isEmpty else { continue }
            if entryByURL[raw] == nil {
                entryByURL[raw] = (entry.title, entry.artist, entry.album)
                entryByURLFull[raw] = (entry.title, entry.artist, entry.album, entry.genre)
            }
        }
        var genreByArtist: [String: String] = [:]
        for entry in entries where !entry.genre.isEmpty {
            let key = entry.artist.lowercased()
            if genreByArtist[key] == nil { genreByArtist[key] = entry.genre }
        }
        let queueItems = queueHolder.vm?.queueItems ?? []
        let queueRows = queueItems.enumerated().map { idx, item in
            BackOfTheClubDebugState.QueueRow(
                position: idx + 1,
                title: item.title,
                artist: item.artist,
                album: item.album,
                genre: genreByArtist[item.artist.lowercased()] ?? "—"
            )
        }
        var poolRows: [BackOfTheClubDebugState.PoolRow] = []
        func appendRows(_ urls: [URL], tier: String) {
            for url in urls {
                let meta = entryByURLFull[url.absoluteString]
                poolRows.append(.init(
                    tier: tier,
                    url: url.lastPathComponent,
                    title: meta?.title ?? "—",
                    artist: meta?.artist ?? "—",
                    album: meta?.album ?? "—",
                    genre: meta?.genre ?? "—"
                ))
            }
        }
        appendRows(pool.preferred, tier: "preferred")
        appendRows(pool.genreTier1, tier: "genre1")
        appendRows(pool.genreTier2, tier: "genre2")
        appendRows(pool.genreTier3, tier: "genre3")
        appendRows(pool.random, tier: "random")
        appendRows(pool.ambient, tier: "ambient")
        // Mirror the chooseTiles() logic: queue mode → top 3 by
        // count across queue items; streaming → current song's tokens.
        var queueGenreTokens: Set<String> = []
        if trackMetadata.isQueueSource {
            var counts: [String: Int] = [:]
            for item in queueItems {
                guard let genre = genreByArtist[item.artist.lowercased()] else { continue }
                for tok in genre.split(separator: ",") {
                    let t = tok.trimmingCharacters(in: .whitespaces).lowercased()
                    if !t.isEmpty { counts[t, default: 0] += 1 }
                }
            }
            queueGenreTokens = Set(counts.sorted { $0.value > $1.value }.prefix(3).map(\.key))
        } else {
            for tok in trackMetadata.genre.split(separator: ",") {
                let t = tok.trimmingCharacters(in: .whitespaces).lowercased()
                if !t.isEmpty { queueGenreTokens.insert(t) }
            }
            if let genre = genreByArtist[trackMetadata.artist.lowercased()] {
                for tok in genre.split(separator: ",") {
                    let t = tok.trimmingCharacters(in: .whitespaces).lowercased()
                    if !t.isEmpty { queueGenreTokens.insert(t) }
                }
            }
        }
        let state = BackOfTheClubDebugState.shared
        state.queueRows = queueRows
        state.poolRows = poolRows
        state.entryByURL = entryByURL
        state.nowPlayingArtist = trackMetadata.artist
        state.nowPlayingTitle = trackMetadata.title
        state.nowPlayingGenre = trackMetadata.genre
        state.isQueueMode = trackMetadata.isQueueSource
        state.matchMode = VisGenreMatchMode.current.rawValue
        state.sprinklePercent = visRandomSprinklePercent
        state.similarArtists = Array(nowPlayingSimilarArtists).sorted()
        state.queueGenreTokens = Array(queueGenreTokens).sorted()
        state.nowPlayingBio = nowPlayingArtistInfo?.bio ?? ""
    }
    #endif

    /// Builds the tiered tile pool per the user spec.
    ///
    /// Queue mode:
    ///   - preferred = queue items' art in queue order. Fills large
    ///     tiles (4×4 → 3×3) until exhausted.
    ///   - fallback = genre-matched history + random sprinkle.
    ///
    /// Streaming / no-queue mode:
    ///   - preferred = current artist's art (4×4 priority) + similar
    ///     artists' art from `nowPlayingSimilarArtists` (3×3 priority).
    ///   - fallback = genre-matched history + random sprinkle.
    ///
    /// Radio URI schemes are excluded at every step. URLs are
    /// deduplicated across both tiers — if the pool ends up shorter
    /// than the slot count, the deficit slots stay blank.
    private func chooseTiles() -> TilePool {
        // Per `UDKey.visHistorySource`: ".group" (default) restricts
        // history to plays whose `groupName` includes ANY room
        // currently in the active group — not the exact group-name
        // string. PlayHistoryEntry.groupName is the " + "-joined
        // name at log time (e.g. "Office + Float Play 5"), so we
        // tokenise it and intersect with the current group's member
        // room names. ".all" pools across every group.
        //
        // Auto-fallback: if the room-match filter still yields too
        // few entries to feed a wall (< minGroupEntries), bump up
        // to all-history rather than starve.
        let allEntries = playHistoryManager.entries
        let minGroupEntries = 200
        let entries: [PlayHistoryEntry] = {
            switch VisHistorySource.current {
            case .all: return allEntries
            case .group:
                let memberRoomNames = Set(
                    (group?.members ?? [])
                        .map { $0.roomName }
                        .filter { !$0.isEmpty }
                )
                guard !memberRoomNames.isEmpty else { return allEntries }
                let filtered = allEntries.filter { entry in
                    guard !entry.groupName.isEmpty else { return false }
                    let entryRooms = entry.groupName
                        .split(separator: "+")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                    for r in entryRooms where memberRoomNames.contains(r) {
                        return true
                    }
                    return false
                }
                if filtered.count < minGroupEntries {
                    visLog("group filter rooms=\(memberRoomNames) yielded \(filtered.count) entries (< \(minGroupEntries)) — falling back to all (\(allEntries.count))")
                    return allEntries
                }
                return filtered
            }
        }()
        let queueItems = queueHolder.vm?.queueItems ?? []
        let isQueueMode = trackMetadata.isQueueSource
        let mode = VisGenreMatchMode.current

        func usableArt(_ raw: String?, sourceURI: String?) -> URL? {
            guard let raw, !raw.isEmpty,
                  let url = URL(string: raw) else { return nil }
            if let s = sourceURI, URIPrefix.isRadio(s) { return nil }
            // No cache gate — pool now includes any valid art URL,
            // and `downloadMissingPoolArt()` (post-rebuildTiles)
            // backfills `preloaded` for anything not yet cached.
            return url
        }

        // Artist → genre lookup (keyed on artist; per-track granularity
        // would miss queue items whose specific track isn't in history).
        var genreByArtist: [String: String] = [:]
        for entry in entries where !entry.genre.isEmpty {
            let key = entry.artist.lowercased()
            if genreByArtist[key] == nil { genreByArtist[key] = entry.genre }
        }

        // Artist → ordered, deduped art URLs from history.
        var artByArtist: [String: [URL]] = [:]
        for entry in entries {
            guard let url = usableArt(entry.albumArtURI, sourceURI: entry.sourceURI) else { continue }
            let key = entry.artist.lowercased()
            if artByArtist[key]?.contains(url) == true { continue }
            artByArtist[key, default: []].append(url)
        }

        // Top genres ORDERED — index 0 is the dominant genre, used
        // for tier 1 (large-tile fallback). Queue mode counts across
        // queue items AND the current track's own DIDL genre (so a
        // queue full of artists not yet in history still produces
        // meaningful topGenres from at least the playing track);
        // streaming uses current track tokens in order (DIDL first,
        // then artist-info backfill).
        var topGenres: [String] = []
        if isQueueMode {
            var counts: [String: Int] = [:]
            // Count the current track's DIDL genre tokens with a
            // small extra weight so they reliably make the top 3
            // even when the queue's other artists have no history.
            for tok in trackMetadata.genre.split(separator: ",") {
                let t = tok.trimmingCharacters(in: .whitespaces).lowercased()
                if !t.isEmpty { counts[t, default: 0] += 2 }
            }
            for item in queueItems {
                guard let genre = genreByArtist[item.artist.lowercased()] else { continue }
                for tok in genre.split(separator: ",") {
                    let t = tok.trimmingCharacters(in: .whitespaces).lowercased()
                    if !t.isEmpty { counts[t, default: 0] += 1 }
                }
            }
            topGenres = counts.sorted { $0.value > $1.value }.prefix(3).map(\.key)
        } else {
            var seenTok = Set<String>()
            for tok in trackMetadata.genre.split(separator: ",") {
                let t = tok.trimmingCharacters(in: .whitespaces).lowercased()
                if !t.isEmpty, seenTok.insert(t).inserted { topGenres.append(t) }
                if topGenres.count >= 3 { break }
            }
            if topGenres.count < 3, let genre = genreByArtist[trackMetadata.artist.lowercased()] {
                for tok in genre.split(separator: ",") {
                    let t = tok.trimmingCharacters(in: .whitespaces).lowercased()
                    if !t.isEmpty, seenTok.insert(t).inserted { topGenres.append(t) }
                    if topGenres.count >= 3 { break }
                }
            }
        }

        func entryMatches(_ entryTokens: [String], topGenre: String) -> Bool {
            switch mode {
            case .partial:
                for et in entryTokens {
                    if et.contains(topGenre) || topGenre.contains(et) { return true }
                }
                return false
            case .full:
                return entryTokens.contains(topGenre)
            }
        }

        /// Returns the lowest-index top-genre this entry matches, or
        /// nil if it matches none. Lowest index = highest priority.
        func bestTier(_ entry: PlayHistoryEntry) -> Int? {
            guard !entry.genre.isEmpty else { return nil }
            let entryTokens = entry.genre.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
            for (idx, top) in topGenres.enumerated() {
                if entryMatches(entryTokens, topGenre: top) { return idx }
            }
            return nil
        }

        var seen = Set<URL>()
        var preferred: [URL] = []
        var tier1: [URL] = []
        var tier2: [URL] = []
        var tier3: [URL] = []
        var random: [URL] = []

        func addTo(_ list: inout [URL], _ url: URL) {
            if seen.insert(url).inserted { list.append(url) }
        }

        // Now-playing hero — first slot in `preferred` (any mode).
        // Source priority: settledArtURL (parent-resolved via the
        // now-playing card's ArtResolver — gives the real track art
        // for Spotify playlist plays where DIDL points at the
        // playlist cover, and for radio plays where DIDL points at
        // the station logo). Falls back to trackMetadata.albumArtURI
        // when the parent hasn't resolved yet. Bypasses the cache
        // gate — `downloadNowPlayingArt()` ensures `preloaded` has
        // it before the next rebuild.
        var heroURL: URL? = nil
        if let s = settledArtURL { heroURL = s }
        else if let raw = trackMetadata.albumArtURI, !raw.isEmpty,
                let u = URL(string: raw),
                !URIPrefix.isRadio(trackMetadata.trackURI ?? "") {
            heroURL = u
        }
        if let url = heroURL { addTo(&preferred, url) }

        var similarArtists: [URL] = []
        if isQueueMode {
            // Queue items go in `preferred` so the anchor 4×4 + the
            // first 3×3 (pinned in wholesaleFill) always show real
            // queue covers. Dedup'd — same album appearing on N
            // queue tracks contributes ONE preferred URL.
            for item in queueItems {
                guard let url = usableArt(item.albumArtURI, sourceURI: nil) else { continue }
                addTo(&preferred, url)
            }
            // Queue-artist history goes into `similarArtists`, NOT
            // preferred. When a focused queue collapses to 1–2
            // unique album covers, preferred runs out fast; the
            // `similarArtists` fallback keeps the wall on-artist
            // without repeating the same one or two queue covers
            // across every large tile.
            let queueArtistKeys = Set(queueItems.map { $0.artist.lowercased() })
            for artistKey in queueArtistKeys {
                guard let arts = artByArtist[artistKey] else { continue }
                for url in arts {
                    if seen.insert(url).inserted { similarArtists.append(url) }
                }
            }
        }
        // Radio / streaming mode: nothing extra in preferred —
        // 4×4 = hero → genres → random/ambient
        // 3×3 = genres → random/ambient
        // 1×1 = genres + random factor

        // Genre tiers: each entry goes into the tier matching its
        // BEST (lowest-index) top-genre. URLs already in `preferred`
        // are skipped via the `seen` set.
        for entry in entries {
            guard let url = usableArt(entry.albumArtURI, sourceURI: entry.sourceURI) else { continue }
            guard !seen.contains(url) else { continue }
            guard let tier = bestTier(entry) else { continue }
            switch tier {
            case 0: addTo(&tier1, url)
            case 1: addTo(&tier2, url)
            case 2: addTo(&tier3, url)
            default: break
            }
        }

        // Random sprinkle: entries with no genre match. Sized as a
        // percentage of the total cell count.
        let totalSlots = ClubVisWallView.cols * ClubVisWallView.rows
        let sprinkleTarget = max(0, Int((Double(totalSlots) * visRandomSprinklePercent / 100.0).rounded()))
        if sprinkleTarget > 0 {
            var candidates: [URL] = []
            for entry in entries {
                guard let url = usableArt(entry.albumArtURI, sourceURI: entry.sourceURI) else { continue }
                guard !seen.contains(url) else { continue }
                candidates.append(url)
            }
            for url in candidates.shuffled().prefix(sprinkleTarget) {
                addTo(&random, url)
            }
        }

        // Ambient fillback — uniform random sample across history.
        // PINNED across rebuildTiles calls within the same wallId
        // so the wall doesn't churn on every track change just
        // because chooseTiles ran again with a different shuffle.
        var ambient: [URL] = []
        if pinnedAmbientForWallId == wallId, !pinnedAmbientSample.isEmpty {
            for url in pinnedAmbientSample {
                if seen.insert(url).inserted { ambient.append(url) }
            }
            visLog("ambient REUSED — pinned=\(pinnedAmbientSample.count) usable=\(ambient.count) wallId=\(wallId)")
        } else {
            var ambientCandidates: [URL] = []
            for entry in entries {
                guard let url = usableArt(entry.albumArtURI, sourceURI: entry.sourceURI) else { continue }
                guard !seen.contains(url) else { continue }
                ambientCandidates.append(url)
            }
            for url in ambientCandidates.shuffled().prefix(800) {
                if seen.insert(url).inserted {
                    ambient.append(url)
                }
            }
            pinnedAmbientSample = ambient
            pinnedAmbientForWallId = wallId
            visLog("ambient FRESH — generated=\(ambient.count) wallId=\(wallId) (prev pinId=\(pinnedAmbientForWallId))")
        }

        // Cache-fallback tier — enumerate URLs in ImageCache that
        // aren't already represented elsewhere in the pool, sampled
        // evenly across cache age. Caps at 400 URLs so the pool
        // doesn't balloon. Excludes URLs already in `seen` (the
        // dedup set built up during the tier passes above).
        var cacheBackfill: [URL] = []
        let candidates = ImageCache.shared.sampledCachedURLs(count: 1200)
        for url in candidates {
            if seen.insert(url).inserted {
                cacheBackfill.append(url)
                if cacheBackfill.count >= 400 { break }
            }
        }

        return TilePool(
            preferred: preferred,
            similarArtists: similarArtists,
            genreTier1: tier1,
            genreTier2: tier2,
            genreTier3: tier3,
            random: random,
            ambient: ambient,
            cacheBackfill: cacheBackfill,
            isQueueMode: isQueueMode
        )
    }

    /// Imperative wall rebuild — fade out, swap layoutSeed/wallId,
    /// fade in. Called when an event needs to refresh layout
    /// regardless of the cadence rule (queue replaced via
    /// `.queueChanged` reload path; future hooks can call this too).
    /// Resets the cadence counter + timestamp so the cadence rule
    /// timer effectively restarts from this point.
    @MainActor
    private func forceWallRebuild(source: String = "forceWallRebuild") async {
        await performRebuildSequence(source: source)
    }

    /// Shared 3 s out → preload → 0.5 s black → 3 s in rebuild
    /// pipeline used by both the debug Rebuild button and the cadence
    /// rebuild. Pre-loads the URLs likely to appear on the new wall
    /// during the fade-out window so the wall fades in already
    /// populated — no piecewise piecemeal load after the fade.
    /// `source` is logged so we can see which trigger fired (and
    /// which got dropped by the in-progress guard).
    /// Cooldown — any rebuild request whose call site fires within
    /// `rebuildCooldown` seconds of the previous rebuild's END is
    /// dropped. Catches the common pattern where a single source
    /// change fires `.task(id: trackURI)` and `.queueChanged` in
    /// sequence (the second arriving just after the first finishes,
    /// outside the in-progress window).
    private static let rebuildCooldown: TimeInterval = 5.0

    @MainActor private static var rebuildSeqCounter: Int = 0
    @MainActor private static func nextRebuildSeqId() -> Int {
        rebuildSeqCounter += 1
        return rebuildSeqCounter
    }

    @MainActor
    private func performRebuildSequence(source: String = "unknown") async {
        let seqId = Self.nextRebuildSeqId()
        guard !rebuildInProgress else {
            visLog("rebuild DROPPED — seq=\(seqId) reason=already-in-progress source=\(source)")
            return
        }
        let elapsedSinceLast = Date().timeIntervalSince(lastRebuildEndAt)
        if elapsedSinceLast < Self.rebuildCooldown {
            visLog("rebuild DROPPED — seq=\(seqId) reason=cooldown remaining=\(String(format: "%.1f", Self.rebuildCooldown - elapsedSinceLast))s source=\(source)")
            return
        }
        visLog("rebuild START — seq=\(seqId) source=\(source) coverOpacity=\(String(format: "%.2f", wallCoverOpacity))")
        rebuildInProgress = true
        BackOfTheClubDebugState.shared.isWallRebuilding = true
        defer {
            rebuildInProgress = false
            BackOfTheClubDebugState.shared.isWallRebuilding = false
        }
        let oldSeed = layoutSeed
        let newSeed = UInt32.random(in: 0...UInt32.max)

        // Pre-compute the new wall's slots so we know roughly how
        // many URLs we need to have cached before fade-in.
        var config = WallSlotPacker.Config.default
        #if DEBUG
        let s = BackOfTheClubDebugState.shared
        config.count4x4 = s.packerCount4x4
        config.count3x3 = s.packerCount3x3
        config.count2x2 = s.packerCount2x2
        config.maxLargeNeighbours = s.packerMaxLargeNeighbours
        config.maxLargeComponent = s.packerMaxLargeComponent
        #endif
        let newSlots = WallSlotPacker.pack(seed: newSeed,
                                            cols: ClubVisWallView.cols,
                                            rows: ClubVisWallView.rows,
                                            cellSize: ClubVisWallView.cellSize,
                                            originX: ClubVisWallView.originX,
                                            originY: ClubVisWallView.originY,
                                            config: config)

        // Priority URLs = front of the pool's display order. The
        // wholesaleFill walks slots largest-first and pulls from
        // preferred → tier1 → tier2 → tier3 → random → ambient →
        // cacheBackfill, so the front N URLs of that concatenation
        // approximates what will land on screen. Slot count + small
        // margin so we cover everything that might be assigned.
        let priorityURLs = Array(
            (pool.preferred + pool.genreTier1 + pool.genreTier2 + pool.genreTier3
             + pool.random + pool.ambient + pool.cacheBackfill)
                .prefix(newSlots.count + 50)
        )

        // Begin fade-out (cover fades IN to opaque black) and
        // pre-load in parallel.
        let coverInStart = Date()
        visLog("rebuild step — seq=\(seqId) cover fade-IN start (3s) fromOpacity=\(String(format: "%.2f", wallCoverOpacity))")
        withAnimation(.easeInOut(duration: 3.0)) { wallCoverOpacity = 1.0 }
        let downloadTask = Task { @MainActor in
            await self.downloadMissingPoolArt(allURLs: priorityURLs)
        }
        let rebuildStart = Date()

        // Wait the full fade-out duration first.
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        visLog("rebuild step — seq=\(seqId) cover fade-IN END (elapsedMs=\(Int(Date().timeIntervalSince(coverInStart)*1000)) coverOpacity=\(String(format: "%.2f", wallCoverOpacity)))")

        // Cap the download wait. The earlier withTaskGroup{ await
        // downloadTask.value, sleep(cap) }.next + cancelAll variant
        // looked like it bounded the wait at `cap`, but withTaskGroup
        // only returns once *all* child tasks finish — and the
        // `await downloadTask.value` child waits for downloadTask
        // itself, which is unbounded (single getaa fetch was logged
        // taking 48 s). So the rebuild stalled at black for the full
        // download duration. Plain Task.sleep is the bounded form;
        // downloadTask continues in the background and its results
        // are picked up by subsequent rebuildTiles calls.
        let totalCapSeconds: TimeInterval = 8.0
        let remainingCap = max(0, totalCapSeconds - Date().timeIntervalSince(rebuildStart))
        if remainingCap > 0 {
            try? await Task.sleep(nanoseconds: UInt64(remainingCap * 1_000_000_000))
        }
        visLog("rebuild step — seq=\(seqId) download wait END (capMs=\(Int(remainingCap*1000)) downloadStillRunning=\(downloadTask.isCancelled == false))")

        // Commit the new seed (this swaps the entire wallView via
        // .id(wallId)) and run the black hold + fade-in.
        visLog("rebuild step — seq=\(seqId) wallId swap (oldSeed=\(oldSeed) newSeed=\(newSeed))")
        layoutSeed = newSeed
        // Recompute slots SYNCHRONOUSLY before flipping wallId.
        // .onChange(of: layoutSeed) { recomputeSlots() } runs only
        // after the body re-eval, which means the fresh WallView
        // gets constructed with stale resolvedSlots and its .task
        // calls wholesaleFill with slots=0. Calling recomputeSlots
        // here ensures the new WallView opens with up-to-date slots.
        recomputeSlots()
        wallId = newSeed
        try? await Task.sleep(nanoseconds: 500_000_000)
        // Cover fades OUT, revealing the freshly-rebuilt wall.
        let coverOutStart = Date()
        visLog("rebuild step — seq=\(seqId) cover fade-OUT start (3s) fromOpacity=\(String(format: "%.2f", wallCoverOpacity))")
        withAnimation(.easeInOut(duration: 3.0)) { wallCoverOpacity = 0.0 }
        // Hold rebuildInProgress for the full fade-in duration so
        // back-to-back triggers (queueChanged arriving mid-fade-in)
        // can't slip past the guard. Without this await the function
        // returned at ~3.5 s while the visual sequence ran another
        // 3 s, allowing a second rebuild to interrupt the fade-in.
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        visLog("rebuild step — seq=\(seqId) cover fade-OUT END (elapsedMs=\(Int(Date().timeIntervalSince(coverOutStart)*1000)) coverOpacity=\(String(format: "%.2f", wallCoverOpacity)))")
        tracksSinceRebuild = 0
        lastWallRebuildAt = Date()
        lastRebuildEndAt = Date()
        visLog("rebuild END — seq=\(seqId) oldSeed=\(oldSeed) newSeed=\(newSeed) preloaded=\(preloaded.count)")
    }

    static let logicalWidth: CGFloat = 1920
    static let logicalHeight: CGFloat = 1080

    // MARK: - Memorial overlay

    /// Persistent counters keyed in UserDefaults. Open count tracks
    /// total Vis opens across launches; "last shown at" caps the
    /// overlay frequency at no more than one show per 9 opens.
    private static let openCountKey = "vis.clubVisOpenCount"
    private static let memorialLastShownKey = "vis.clubVisEasterLastShownAt"

    /// Rate-limited memorial overlay:
    ///   - Skip on opens 1-2 (need at least 3 opens before any
    ///     possibility).
    ///   - From open 3 onward: roll 9% chance per open.
    ///   - Hard cap: never more than 1 in 9 opens (block the roll
    ///     until 9 opens have passed since the last show).
    /// On show: 1 s fade-in, ~4 s hold, 1.5 s fade-out.
    private func maybeShowMemorialOverlay() {
        let defaults = UserDefaults.standard
        let openCount = defaults.integer(forKey: Self.openCountKey) + 1
        defaults.set(openCount, forKey: Self.openCountKey)

        guard openCount >= 3 else { return }
        let lastShown = defaults.integer(forKey: Self.memorialLastShownKey)
        guard openCount - lastShown >= 9 else { return }
        guard Double.random(in: 0..<1) < 0.09 else { return }

        defaults.set(openCount, forKey: Self.memorialLastShownKey)
        memorialOverlayVisible = true
        Task { @MainActor in
            visLog("memorial overlay fade-IN start (1.0s)")
            withAnimation(.easeIn(duration: 1.0)) { memorialOverlayOpacity = 1.0 }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            visLog("memorial overlay fade-OUT start (1.5s)")
            withAnimation(.easeOut(duration: 1.5)) { memorialOverlayOpacity = 0.0 }
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            visLog("memorial overlay END")
            memorialOverlayVisible = false
        }
    }
}

// MARK: - Tiny holders

/// `@StateObject`-friendly wrapper so `QueueViewModel` can be built
/// lazily once `SonosGroup` is in hand. Building inline at
/// `@StateObject` init would race against environment injection.
@MainActor
final class ClubVisQueueHolder: ObservableObject {
    @Published var vm: QueueViewModel?
}

/// Six-tier tile pool. URL appears in at most one tier — buckets
/// are mutually deduplicated.
///
///   - `preferred`  — queue items (queue mode) or current artist +
///     similar artists (streaming). Always takes priority for large
///     tiles, regardless of genre.
///   - `genreTier1` — history rows whose genre matches the active
///     #1 genre. Top-tier fallback for large tiles.
///   - `genreTier2` — matches #2 genre (and not #1). Eligible for
///     3×3 medium fallback.
///   - `genreTier3` — matches #3 genre (and not #1 or #2). Eligible
///     for 1×1 small fallback only.
///   - `random`     — uniform sample of remaining history with no
///     genre criterion, sized by `visRandomSprinklePercent`. Fills
///     1×1 sprinkle.
///   - `ambient`    — every other unused history URL. Last-resort
///     fillback so the wall always fully populates even when the
///     curated tiers can't supply enough URLs (short queue, sparse
///     genre matches). Appended to every size's fallback chain so
///     no cell stays blank.
///
/// Slot assignment priority by size class:
///   - 4×4: preferred → tier1                          → ambient
///   - 3×3: preferred → tier1 → tier2                  → ambient
///   - 1×1: preferred → tier1 → tier2 → tier3 → random → ambient
///
/// Large slots still avoid the middle/random tiers so off-genre art
/// doesn't dominate the prominent tiles, but the ambient fillback
/// guarantees full coverage when the curated tiers run dry.
private struct TilePool: Equatable {
    /// Hero (now-playing) art only. Anchor 4×4 always pulls from
    /// here. In queue mode this also holds the dedup'd queue
    /// album-art URLs so a second large slot can show the queue's
    /// own cover; queue-artist history lives in `similarArtists`
    /// instead so the wall doesn't fill with a single repeated
    /// album cover when the queue collapses to one URL.
    let preferred: [URL]
    /// Queue-artist history covers (queue mode only) — used as
    /// fallback for large slots after preferred is consumed and
    /// for mid/small tiles that should still feel "on-artist"
    /// without repeating the literal queue album cover.
    let similarArtists: [URL]
    let genreTier1: [URL]
    let genreTier2: [URL]
    let genreTier3: [URL]
    let random: [URL]
    let ambient: [URL]
    /// Tier-of-last-resort sourced from `ImageCache.sampledCachedURLs`
    /// — fills the wall when genre tiers + ambient don't have enough
    /// art to cover every slot.
    let cacheBackfill: [URL]
    let isQueueMode: Bool

    static let empty = TilePool(
        preferred: [], similarArtists: [],
        genreTier1: [], genreTier2: [], genreTier3: [],
        random: [], ambient: [], cacheBackfill: [], isQueueMode: false)
}

// MARK: - Wall

/// Tiled poster wall. Renders into a single Canvas so the hundreds
/// of album textures rasterise to one layer instead of one SwiftUI
/// view per tile.
///
/// The wall manages two animations internally:
///   1. A per-slot occasional fade — every 4–8 s a random small slot
///      cross-fades from its current art to a fresh one drawn from
///      `pool` (a wider reservoir than the on-screen slots, so the
///      wall slowly rotates through the user's library).
///   2. The TimelineView ticks at 24 fps so cross-fades are smooth.
///
/// Track-change cross-fade is owned by the parent — wrapping this
/// view in `.id(seed) + .transition(.opacity)` swaps the whole wall
/// when the song changes.
private struct ClubVisWallView: View {
    let pool: TilePool
    let slots: [WallSlot]
    let preloaded: [URL: NSImage]
    /// Bumped by the parent on every track change. When this changes,
    /// `triggerGenreSeedSwaps` runs a few 1×1 fade swaps from
    /// `pool.genreTier1` (the new track's top-genre matches) so the
    /// wall reacts visibly to the track change beyond the diff path.
    let seedSwapTrigger: Int
    /// Bumped by parent on `settledArtURL` change. Drives the
    /// anchor-only hero fade WITHOUT settle-window suppression so
    /// a delayed iTunes resolve replaces the station logo on the
    /// anchor regardless of the rebuild settle.
    let heroUpdateTrigger: Int
    /// Canonical now-playing art URL — same source the now-playing
    /// card on the main view uses. Hero anchor binds to this so
    /// the wall's largest tile always matches what the user sees in
    /// the now-playing card. Falls back to `pool.preferred.first`
    /// when nil. Without this, queue mode set `preferred[0]` to the
    /// queue's first item (not the now-playing track), so the hero
    /// drifted from now-playing whenever the playing track wasn't
    /// queue position 0.
    let nowPlayingHeroURL: URL?
    /// True while `performRebuildSequence` is running. Wall pauses
    /// its swap loop, suppresses .onChange handlers, and clears
    /// in-flight fades so tile animations don't leak through the
    /// cover transitions.
    let rebuildInProgress: Bool
    /// Black cover opacity. Wall short-circuits hero swaps to a
    /// direct slotURL write (no fade) when the cover is opaque —
    /// the user can't see a fade behind a solid black cover, and
    /// running one creates a visible mid-fade-reveal artifact when
    /// the cover lifts.
    let coverOpacity: Double

    /// 25 cols × 14 rows of 80 pt cells. 1080 / 14 ≈ 77 → cellSize 80
    /// with a non-uniform negative origin offset so the grid total
    /// (2000 × 1120) overflows the 1920 × 1080 canvas at every edge.
    /// Albums get clipped at the edges, so the wall stops looking
    /// like a grid that fits the window and starts looking like a
    /// venue back-wall seen through a doorway.
    static let cols = 25
    static let rows = 14
    static let cellSize: CGFloat = 80
    static let originX: CGFloat = -34
    static let originY: CGFloat = -22

    @State private var slotURLs: [Int: URL] = [:]
    @State private var fades: [Int: FadeState] = [:]
    /// First-fill marker. The original wholesale-vs-diff branch used
    /// `slotURLs.isEmpty && fades.isEmpty`, but a hero swap fired from
    /// the parent before `.task` runs would put one entry in `fades`,
    /// causing the branch to pick `diffFill` on first appearance. The
    /// diffFill bulk-commit path then filled all blank slots without
    /// fades — visible as the "blink" the user reported on launch.
    @State private var hasInitialFilled: Bool = false
    /// Hero URL deferred while the anchor was mid-fade. Drained by
    /// the anchor fade-commit handler when its fade ends.
    @State private var pendingHeroURL: URL? = nil
    @State private var swapTask: Task<Void, Never>?
    /// Stamp set at the end of every wholesaleFill. The pool-change
    /// and seed-swap handlers below check this; if elapsed is below
    /// `settleSeconds`, they no-op. Stops the post-rebuild churn
    /// where a freshly-faded-in wall would immediately diff-fade
    /// dozens of small tiles because trackChange / genreVersion /
    /// downloadMissingPoolArt all fire rebuildTiles() in quick
    /// succession after the wall lands.
    @State private var lastWholesaleAt: Date = .distantPast
    private static let settleSeconds: TimeInterval = 15

    /// Debounce holder for `diffFill` triggered by `.onChange(of: pool)`.
    /// `pool` mutates multiple times per second during track changes
    /// (rebuildTiles fires from .task block, downloadNowPlayingArt
    /// chain, settledArtURL cascade, similarArtists fetch — each
    /// publishes a new pool). Without debouncing, each pool change
    /// runs a full diffFill which creates 20–40 new tile fades; the
    /// fades pile up to 100+ in-flight ones (visible in the log as
    /// fades=98, fades=110, fades=116). Coalescing the diff to a
    /// single run 500 ms after the last pool change collapses the
    /// burst into one fade pass.
    @State private var diffFillDebounceTask: Task<Void, Never>?
    /// Cancellable task for the 2-second-delayed seed-swap that
    /// fires on `seedSwapTrigger` change. Multiple track-change
    /// bumps in quick succession used to schedule independent
    /// Tasks, each firing its own seed-swap → multiple tile fades
    /// per track change. Cancelling collapses to one.
    @State private var seedSwapDebounceTask: Task<Void, Never>?

    private struct FadeState {
        let oldURL: URL?
        let newURL: URL?
        let startTime: TimeInterval
        let duration: TimeInterval
        let style: FadeStyle
        let source: String

        /// Ease-in-out curve: smoothstep approximation. 0 → 0, 1 → 1,
        /// derivative is 0 at both ends so the fade ramp doesn't have
        /// a visible kink at the start/finish.
        static func eased(_ x: Double) -> Double {
            let t = max(0, min(1, x))
            return t * t * (3 - 2 * t)
        }

        /// Returns (oldOpacity, newOpacity) for the given elapsed
        /// fraction `frac` (0 → 1 over the fade's duration).
        ///
        /// `.crossfade`: smoothstep blend — old 1→0, new 0→1 in
        /// lockstep with brief overlap mid-fade.
        ///
        /// `.blackHold`: sequential — old fades to 0 over `out`
        /// seconds, holds black for `hold` seconds, then new
        /// fades to 1 over `fadeIn`. The Canvas backdrop is black
        /// so omitting both images during the hold reads as a
        /// black tile.
        func opacities(at frac: Double) -> (old: Double, new: Double) {
            let elapsed = max(0, min(1, frac)) * duration
            switch style {
            case .crossfade:
                let p = FadeState.eased(frac)
                return (1.0 - p, p)
            case .blackHold(let out, let hold, let fadeIn):
                if out > 0, elapsed <= out {
                    return (1.0 - elapsed / out, 0)
                }
                if elapsed <= out + hold {
                    return (0, 0)
                }
                let inElapsed = elapsed - out - hold
                return fadeIn > 0
                    ? (0, min(1.0, inElapsed / fadeIn))
                    : (0, 1)
            }
        }
    }

    private enum FadeStyle {
        case crossfade
        case blackHold(out: TimeInterval, hold: TimeInterval, fadeIn: TimeInterval)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, _ in
                #if DEBUG
                BackOfTheClubDebugState.shared.recordWallFrame()
                #endif
                for (i, slot) in slots.enumerated() {
                    // 1 pt inset — the back wall packs posters tightly
                    // with hairline gaps. Larger insets (the previous
                    // 4 pt) read as a moodboard, not a back wall.
                    let rect = slot.rect.insetBy(dx: 1, dy: 1)
                    if let fade = fades[i] {
                        let frac = (t - fade.startTime) / fade.duration
                        let (oldOp, newOp) = fade.opacities(at: frac)
                        if oldOp > 0, let oldURL = fade.oldURL, let oldImg = preloaded[oldURL] {
                            var oldCtx = ctx
                            oldCtx.opacity = oldOp
                            oldCtx.draw(Image(nsImage: oldImg), in: rect)
                        }
                        if newOp > 0, let newURL = fade.newURL, let newImg = preloaded[newURL] {
                            var newCtx = ctx
                            newCtx.opacity = newOp
                            newCtx.draw(Image(nsImage: newImg), in: rect)
                        }
                    } else if let url = slotURLs[i], let img = preloaded[url] {
                        ctx.draw(Image(nsImage: img), in: rect)
                    }
                }
            }
            .frame(width: ClubVisWindow.logicalWidth, height: ClubVisWindow.logicalHeight)
        }
        .clipped()
        .task {
            assignInitialSlots()
            startSwapLoop()
        }
        .onChange(of: pool) {
            // Skip when a rebuild is in flight — the cover fade
            // would otherwise reveal tile fades happening behind it.
            // Settle window covers post-rebuild churn the same way.
            if rebuildInProgress { return }
            if Date().timeIntervalSince(lastWholesaleAt) < Self.settleSeconds {
                return
            }
            // Debounce diffFill — pool mutates many times per
            // second during transitions, and each diff creates
            // tile fades that pile up. Coalesce to one diff per
            // burst.
            diffFillDebounceTask?.cancel()
            diffFillDebounceTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                assignInitialSlots()
            }
        }
        .onChange(of: seedSwapTrigger) {
            if rebuildInProgress { return }
            if Date().timeIntervalSince(lastWholesaleAt) < Self.settleSeconds {
                return
            }
            // Cancel any prior pending seed-swap task. Multiple
            // rapid track-change bumps used to fan out into
            // independent 2-s-delayed Tasks, each firing a
            // separate seed-swap and adding a tile fade.
            seedSwapDebounceTask?.cancel()
            seedSwapDebounceTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                triggerGenreSeedSwaps(count: BackOfTheClubDebugState.shared.trackChangeSeedSwapCount)
            }
        }
        .onChange(of: heroUpdateTrigger) {
            // Hero URL changed (settledArtURL update — initial track
            // load OR a delayed iTunes resolve replacing the station
            // logo). Always fade the anchor, regardless of settle
            // window or in-flight rebuild — the anchor must reflect
            // the current track at all times. During a rebuild this
            // hits the OLD wallView; the wallId swap will replace
            // the wallView shortly after with a fresh wholesaleFill
            // that respects the new pool.preferred[0].
            if rebuildInProgress { return }
            triggerNowPlayingHeroSwap()
        }
        .onChange(of: rebuildInProgress) { _, nowRebuilding in
            // Rebuild started — clear in-flight tile fades so they
            // don't keep animating behind the cover. The swap loop
            // pauses naturally via its per-tick `rebuildInProgress`
            // check.
            if nowRebuilding {
                let n = fades.count
                fades.removeAll()
                visLog("wallView — rebuild=true, cleared \(n) in-flight fades")
            } else {
                visLog("wallView — rebuild=false, swap loop resumes")
            }
        }
        .onAppear {
            visLog("wallView APPEAR — slots=\(slots.count) inFlight=\(fades.count)")
        }
        .onDisappear {
            visLog("wallView DISAPPEAR — cancelling swap loop")
            swapTask?.cancel()
        }
    }

    /// Tier-aware slot assignment — single entry point for both first
    /// appearance (wholesale fill) and every subsequent pool change
    /// (per-slot diff with size-aware replacement rules).
    ///
    /// Wholesale: slots in size-decreasing order; large slots draw
    /// `preferred` first, falling back to `fallback`; small slots
    /// draw `fallback` first, falling back to `preferred` overflow.
    ///
    /// Diff (track change): per-slot replacement honours the user's
    /// rule that large tiles only swap into preferred art, never into
    /// random/fallback. If a large slot's current URL is evicted
    /// (e.g. queue advanced past it) AND there's no unused preferred
    /// URL to replace it with, the slot is left untouched. 1×1 slots
    /// swap freely from either tier.
    ///
    /// Deficit slots stay blank — URLs are never duplicated.
    private func assignInitialSlots() {
        // Drop any state pointing past the current slots.count.
        // During a wall rebuild, `layoutSeed` (which feeds the
        // packer) and `wallId` (which gates view re-creation) are
        // updated back-to-back on the parent. SwiftUI can re-evaluate
        // the body and pass the NEW (potentially shorter) slots
        // array into the OLD WallView instance before .id(wallId)
        // tears it down. If `.onChange(of: pool)` fires in that
        // window (e.g. a track change), diffFill() would index
        // slots[stale-idx] and crash. Filtering both maps here is
        // the belt-and-suspenders fix that survives the race.
        let validRange = 0..<slots.count
        slotURLs = slotURLs.filter { validRange.contains($0.key) }
        fades = fades.filter { validRange.contains($0.key) }

        if !hasInitialFilled {
            wholesaleFill()
            // Only mark filled when wholesaleFill actually populated
            // slots. The first .task call often runs before the pool
            // is hydrated (initial pool=empty) — wholesaleFill no-ops,
            // and if we set the flag anyway the next assignInitialSlots
            // routes to diffFill which bulk-commits blanks without
            // fades. Defer the flag until the wholesale produced art.
            if !slotURLs.isEmpty {
                hasInitialFilled = true
            }
        } else {
            diffFill()
        }
    }

    private func wholesaleFill() {
        defer { publishSlotDebug() }
        visLog("wholesaleFill ENTER — slots=\(slots.count) rebuilding=\(BackOfTheClubDebugState.shared.isWallRebuilding)")
        var preferredQ = pool.preferred
        var similarArtistsQ = pool.similarArtists
        var t1Q = pool.genreTier1
        var t2Q = pool.genreTier2
        var t3Q = pool.genreTier3
        var randomQ = pool.random
        var ambientQ = pool.ambient
        var cacheBackfillQ = pool.cacheBackfill
        var smallCounter = 0

        let sortedIdx = slots.indices.sorted { slots[$0].sizeClass > slots[$1].sizeClass }

        // Queue-mode pinning: guarantee at least one 4×4 AND one 3×3
        // slot show queue art, even when preferred has only 1 unique
        // URL (queue collapses to a single album cover). Without
        // this, the size-largest-first walk could hand all preferred
        // URLs to 4×4 slots and leave no queue art on any 3×3.
        var pinned: [Int: URL] = [:]
        // Pin the 4×4 anchor to `nowPlayingHeroURL` when set so the
        // wall is fully baked-correct under the cover. Without this,
        // wholesaleFill assigned the anchor whatever was at
        // `preferred[0]` (in queue mode that's the queue's first
        // item, not the now-playing track), then a follow-up hero
        // fade crossfaded the anchor to the correct URL — visible as
        // an in-progress fade when the initial cover lifted.
        if let first4x4 = sortedIdx.first(where: { slots[$0].sizeClass == 4 }) {
            if let heroURL = nowPlayingHeroURL {
                pinned[first4x4] = heroURL
                // De-dup: if the hero URL is in preferred, remove it
                // so a smaller slot doesn't pick it up too.
                if let idx = preferredQ.firstIndex(of: heroURL) {
                    preferredQ.remove(at: idx)
                }
            } else if pool.isQueueMode, !preferredQ.isEmpty {
                pinned[first4x4] = preferredQ.removeFirst()
            }
        }
        if pool.isQueueMode, !preferredQ.isEmpty,
           let first3x3 = sortedIdx.first(where: { slots[$0].sizeClass == 3 }) {
            pinned[first3x3] = preferredQ.removeFirst()
        }

        for idx in sortedIdx {
            let size = slots[idx].sizeClass
            if let pinnedURL = pinned[idx] {
                slotURLs[idx] = pinnedURL
                // Pinning is a synchronous truth-write. If a hero
                // crossfade was already running for this slot (e.g.
                // settledArtURL fired before wholesaleFill ran), the
                // FadeState would keep animating opacity even though
                // slotURLs is already correct — visible as a fade
                // still running after the cover lifts. Clear it.
                if fades[idx] != nil {
                    fades.removeValue(forKey: idx)
                    visLog("wholesaleFill — cleared in-flight fade on pinned slot=\(idx) source=hero-pin")
                }
                continue
            }
            let injectRandom = !pool.isQueueMode && size == 1 && (smallCounter % 5 == 0)
            if size == 1 { smallCounter += 1 }
            let pickedURL = pickURL(forSize: size,
                                    isQueueMode: pool.isQueueMode,
                                    injectRandom: injectRandom,
                                    preferred: &preferredQ,
                                    similarArtists: &similarArtistsQ,
                                    t1: &t1Q, t2: &t2Q, t3: &t3Q,
                                    random: &randomQ, ambient: &ambientQ,
                                    cacheBackfill: &cacheBackfillQ)
            if let url = pickedURL {
                slotURLs[idx] = url
            }
        }
        // Stamp the settle window ONLY when wholesaleFill actually
        // populated tiles. The view's initial `pool` is `.empty`,
        // and the first .task call fires before the parent's
        // rebuildTiles has produced a real pool — so wholesaleFill
        // runs with nothing to assign. Stamping anyway suppressed
        // the very next pool-change handler (which carries the real
        // pool) for 15 s, leaving a permanently blank wall until
        // the user happened to change tracks again. Empty fills
        // leave the stamp at .distantPast so the next legitimate
        // pool change runs assignInitialSlots normally.
        if !slotURLs.isEmpty {
            lastWholesaleAt = Date()
        }
    }

    /// Per-size fallback chain. Branches on queue vs radio mode:
    ///
    /// **Queue mode** — preferred (queue items) feeds 4×4 and 3×3;
    /// 1×1 walks the full tier chain.
    ///
    /// **Radio mode** — preferred holds only the now-playing art
    /// (one URL) and is reserved for 4×4. 3×3 skips preferred and
    /// goes genres → random → ambient. 1×1 also skips preferred and
    /// pulls from genres mostly, with periodic random injection
    /// (~20% of small slots) for visual variety so the wall doesn't
    /// monotone in one genre.
    ///
    /// Ambient at the end of every chain guarantees the wall fully
    /// populates when curated tiers run dry.
    private func pickURL(forSize size: Int,
                         isQueueMode: Bool,
                         injectRandom: Bool,
                         preferred: inout [URL],
                         similarArtists: inout [URL],
                         t1: inout [URL], t2: inout [URL], t3: inout [URL],
                         random: inout [URL], ambient: inout [URL],
                         cacheBackfill: inout [URL]) -> URL? {
        // `cacheBackfill` is the universal tier-of-last-resort.
        if isQueueMode {
            // Queue mode chain — queue art (preferred) only on the
            // two pinned slots (anchor 4×4 + first 3×3). Everything
            // else goes: genres → random → ambient → similarArtists
            // → cacheBackfill. similarArtists (queue-artists' full
            // history) is LAST because for focused queues like a
            // single-artist soundtrack the user has dozens of that
            // artist's covers in history, and putting it ahead of
            // genres caused the wall to look entirely on-artist —
            // exactly the "queue art overwhelming" symptom.
            switch size {
            case 4, 3, 2:
                return takeFront(&t1) ?? takeFront(&t2) ?? takeFront(&t3)
                    ?? takeFront(&random) ?? takeFront(&ambient)
                    ?? takeFront(&similarArtists)
                    ?? takeFront(&cacheBackfill)
            default:
                if injectRandom {
                    return takeFront(&random) ?? takeFront(&ambient)
                        ?? takeFront(&t1) ?? takeFront(&t2) ?? takeFront(&t3)
                        ?? takeFront(&similarArtists)
                        ?? takeFront(&cacheBackfill)
                }
                return takeFront(&t1) ?? takeFront(&t2) ?? takeFront(&t3)
                    ?? takeFront(&random) ?? takeFront(&ambient)
                    ?? takeFront(&similarArtists)
                    ?? takeFront(&cacheBackfill)
            }
        }
        // Radio mode (similarArtists empty in radio mode; harmless).
        switch size {
        case 4:
            return takeFront(&preferred)
                ?? takeFront(&t1) ?? takeFront(&t2) ?? takeFront(&t3)
                ?? takeFront(&random) ?? takeFront(&ambient)
                ?? takeFront(&cacheBackfill)
        case 3, 2:
            return takeFront(&t1) ?? takeFront(&t2) ?? takeFront(&t3)
                ?? takeFront(&random) ?? takeFront(&ambient)
                ?? takeFront(&cacheBackfill)
        default:
            if injectRandom {
                return takeFront(&random) ?? takeFront(&ambient)
                    ?? takeFront(&t1) ?? takeFront(&t2) ?? takeFront(&t3)
                    ?? takeFront(&cacheBackfill)
            }
            return takeFront(&t1) ?? takeFront(&t2) ?? takeFront(&t3)
                ?? takeFront(&random) ?? takeFront(&ambient)
                ?? takeFront(&cacheBackfill)
        }
    }

    private func diffFill() {
        defer { publishSlotDebug() }
        let fadesAtEntry = fades.count
        visLog("diffFill ENTER — slots=\(slots.count) slotURLs=\(slotURLs.count) fades=\(fadesAtEntry) rebuilding=\(BackOfTheClubDebugState.shared.isWallRebuilding)")
        let allNew = Set(pool.preferred)
            .union(pool.similarArtists)
            .union(pool.genreTier1)
            .union(pool.genreTier2)
            .union(pool.genreTier3)
            .union(pool.random)
            .union(pool.ambient)
            .union(pool.cacheBackfill)
        var currentlyShown = Set(slotURLs.values)
        for fade in fades.values {
            if let url = fade.newURL { currentlyShown.insert(url) }
        }
        // Only evict URLs that are GONE from both the current pool
        // AND the preloaded image cache. The previous policy
        // (subtract from allNew alone) flagged 28+ URLs per
        // diffFill on every track change because `topGenres`
        // recomputes per track, shuffling the t1/t2/t3 membership;
        // any slot URL that was assigned from the previous t1
        // would suddenly be "evicted" even though its image is
        // perfectly fine in `preloaded`. Keeping cached-image URLs
        // means pool churn no longer drives mass tile replacement.
        let evicted = currentlyShown.filter { url in
            !allNew.contains(url) && preloaded[url] == nil
        }
        visLog("diffFill — allNew=\(allNew.count) currentlyShown=\(currentlyShown.count) evicted=\(evicted.count)")

        var availPreferred = pool.preferred.filter { !currentlyShown.contains($0) }
        availPreferred.shuffle()
        var availSimilar = pool.similarArtists.filter { !currentlyShown.contains($0) }
        availSimilar.shuffle()
        var availT1 = pool.genreTier1.filter { !currentlyShown.contains($0) }
        availT1.shuffle()
        var availT2 = pool.genreTier2.filter { !currentlyShown.contains($0) }
        availT2.shuffle()
        var availT3 = pool.genreTier3.filter { !currentlyShown.contains($0) }
        availT3.shuffle()
        var availRandom = pool.random.filter { !currentlyShown.contains($0) }
        availRandom.shuffle()
        var availAmbient = pool.ambient.filter { !currentlyShown.contains($0) }
        availAmbient.shuffle()
        var availCacheBackfill = pool.cacheBackfill.filter { !currentlyShown.contains($0) }
        availCacheBackfill.shuffle()

        let now = Date().timeIntervalSinceReferenceDate

        var smallCounter = 0
        let validRange = 0..<slots.count
        for (slotIdx, currentURL) in slotURLs where evicted.contains(currentURL) {
            guard validRange.contains(slotIdx) else { continue }
            let size = slots[slotIdx].sizeClass
            let injectRandom = !pool.isQueueMode && size == 1 && (smallCounter % 5 == 0)
            if size == 1 { smallCounter += 1 }
            let replacement = pickURL(forSize: size,
                                      isQueueMode: pool.isQueueMode,
                                      injectRandom: injectRandom,
                                      preferred: &availPreferred,
                                      similarArtists: &availSimilar,
                                      t1: &availT1, t2: &availT2, t3: &availT3,
                                      random: &availRandom, ambient: &availAmbient,
                                      cacheBackfill: &availCacheBackfill)
            if size >= 2 && replacement == nil {
                continue
            }
            startFade(slotIdx: slotIdx, oldURL: currentURL, newURL: replacement, startTime: now)
        }

        let sortedBlank = slots.indices
            .filter { slotURLs[$0] == nil && fades[$0] == nil }
            .sorted { slots[$0].sizeClass > slots[$1].sizeClass }
        // If the wall is mostly empty (e.g. a race where wallView
        // re-creation left slotURLs cleared while pool change
        // triggered diffFill), commit URLs directly — same as
        // wholesaleFill — instead of creating N tile fades. The
        // mass-fade approach was visible to the user as "blank
        // through fade-IN, then 200 tiles pop in at once".
        let bulkCommit = sortedBlank.count > 20
        if bulkCommit {
            visLog("diffFill — bulk-commit \(sortedBlank.count) blank slots (no fades)")
        }
        for slotIdx in sortedBlank {
            let size = slots[slotIdx].sizeClass
            let injectRandom = !pool.isQueueMode && size == 1 && (smallCounter % 5 == 0)
            if size == 1 { smallCounter += 1 }
            guard let url = pickURL(forSize: size,
                                    isQueueMode: pool.isQueueMode,
                                    injectRandom: injectRandom,
                                    preferred: &availPreferred,
                                    similarArtists: &availSimilar,
                                    t1: &availT1, t2: &availT2, t3: &availT3,
                                    random: &availRandom, ambient: &availAmbient,
                                    cacheBackfill: &availCacheBackfill) else { continue }
            if bulkCommit {
                slotURLs[slotIdx] = url
            } else {
                startFade(slotIdx: slotIdx, oldURL: nil, newURL: url, startTime: now)
            }
        }
        visLog("diffFill EXIT — fadesCreated=\(fades.count - fadesAtEntry) totalFades=\(fades.count) bulkCommit=\(bulkCommit)")
    }

    private func takeFront(_ array: inout [URL]) -> URL? {
        guard !array.isEmpty else { return nil }
        return array.removeFirst()
    }

    /// Snapshots current slot assignments into the shared debug
    /// state for the companion window. No-op in release.
    private func publishSlotDebug() {
        #if DEBUG
        let state = BackOfTheClubDebugState.shared
        let entryByURL = state.entryByURL
        var rows: [BackOfTheClubDebugState.SlotRow] = []
        for (idx, slot) in slots.enumerated() {
            // Prefer in-flight fade newURL over committed URL — the
            // wall is showing the fade target, not the previous
            // slotURL value.
            let url: URL? = fades[idx]?.newURL ?? slotURLs[idx]
            let key = url?.absoluteString ?? ""
            let meta = entryByURL[key]
            rows.append(.init(
                slotIdx: idx,
                sizeClass: slot.sizeClass,
                url: url?.lastPathComponent ?? "—",
                title: meta?.title ?? "—",
                artist: meta?.artist ?? "—",
                album: meta?.album ?? "—"
            ))
        }
        state.slotRows = rows
        #endif
    }

    /// Commits the post-fade slot URL after the crossfade completes.
    /// `startTime` is the fade's nominal start (which may be slightly
    /// in the past by the time this fires) — used both to compute
    /// the correct sleep duration and to verify, before committing,
    /// that the in-flight fade for this slot is still the one we
    /// scheduled. Without that guard, a track-change diff that fires
    /// mid-fade-in would race: both commits would land and the wrong
    /// URL could win.
    /// Builds and stores a FadeState for a slot, sourcing per-phase
    /// durations from the live debug-state values. Mid/large tiles
    /// (size ≥ 2) use a smoothstep crossfade over `largeFadeMs`;
    /// 1×1 tiles use a sequential black-hold (`smallFadeOutMs` →
    /// `smallFadeHoldMs` black → `smallFadeInMs`).
    private func startFade(slotIdx: Int, oldURL: URL?, newURL: URL?, startTime: Double, source: String = #function) {
        visLog("fade START — slot=\(slotIdx) size=\(slots[slotIdx].sizeClass) source=\(source) inFlight=\(fades.count)")
        let size = slots[slotIdx].sizeClass
        let s = BackOfTheClubDebugState.shared
        let style: FadeStyle
        let duration: TimeInterval
        if size >= 2 {
            duration = max(0.05, TimeInterval(s.largeFadeMs) / 1000)
            style = .crossfade
        } else {
            let out = max(0, TimeInterval(s.smallFadeOutMs) / 1000)
            let hold = max(0, TimeInterval(s.smallFadeHoldMs) / 1000)
            let fadeIn = max(0, TimeInterval(s.smallFadeInMs) / 1000)
            duration = max(0.05, out + hold + fadeIn)
            style = .blackHold(out: out, hold: hold, fadeIn: fadeIn)
        }
        fades[slotIdx] = FadeState(oldURL: oldURL, newURL: newURL,
                                   startTime: startTime, duration: duration,
                                   style: style, source: source)
        scheduleFadeCommit(slotIdx: slotIdx, newURL: newURL,
                           startTime: startTime, duration: duration,
                           source: source)
    }

    private func scheduleFadeCommit(slotIdx: Int, newURL: URL?, startTime: Double, duration: TimeInterval, source: String) {
        Task { @MainActor in
            let elapsed = Date().timeIntervalSinceReferenceDate - startTime
            let remaining = duration - elapsed + 0.05  // 50 ms grace
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
            // Race guard — only commit if this is still the active
            // fade for this slot.
            guard let active = fades[slotIdx] else {
                visLog("fade LOST — slot=\(slotIdx) source=\(source) durationMs=\(Int(duration*1000)) (entry cleared mid-fade — likely wallView rebuild)")
                return
            }
            guard active.startTime == startTime else {
                visLog("fade SUPERSEDED — slot=\(slotIdx) source=\(source) by=\(active.source) durationMs=\(Int(duration*1000))")
                return
            }
            if let newURL {
                slotURLs[slotIdx] = newURL
            } else {
                slotURLs.removeValue(forKey: slotIdx)
            }
            fades.removeValue(forKey: slotIdx)
            let actualMs = Int((Date().timeIntervalSinceReferenceDate - startTime) * 1000)
            visLog("fade END — slot=\(slotIdx) source=\(source) expectedMs=\(Int(duration*1000)) actualMs=\(actualMs) inFlight=\(fades.count)")

            // Anchor fade just completed — if a hero URL was queued
            // mid-fade, drain it now so the user sees the latest art.
            let anchorIdx = slots.firstIndex(where: { $0.sizeClass == 4 })
                ?? slots.firstIndex(where: { $0.sizeClass == 3 })
            if slotIdx == anchorIdx, pendingHeroURL != nil {
                visLog("triggerNowPlayingHeroSwap RE-FIRE — draining pendingHeroURL")
                triggerNowPlayingHeroSwap()
            }
        }
    }

    /// Spawns a background task that occasionally picks a small slot
    /// and queues a fade-swap. Lifetime: until the WallView vanishes
    /// (track change rebuilds the view → `.onDisappear` cancels).
    private func startSwapLoop() {
        if swapTask != nil {
            visLog("swap loop CANCELLED-PRIOR — replacing existing task before starting new")
        }
        swapTask?.cancel()
        let loopId = Self.nextSwapLoopId()
        swapTask = Task { @MainActor in
            visLog("swap loop started — id=\(loopId)")
            // Initial settle — let the fresh wall show its first
            // shuffle for a beat before rotation begins.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            var tick = 0
            while !Task.isCancelled {
                let s = BackOfTheClubDebugState.shared
                let lo = max(50, s.swapIntervalMinMs)
                let hi = max(lo, s.swapIntervalMaxMs)
                let waitMs = Int.random(in: lo...hi)
                try? await Task.sleep(nanoseconds: UInt64(waitMs) * 1_000_000)
                guard !Task.isCancelled else {
                    visLog("swap loop EXIT (cancelled) — id=\(loopId) tick=\(tick)")
                    return
                }
                // Read the singleton flag (NOT the let parameter — the
                // let was captured at task-start and goes stale).
                if BackOfTheClubDebugState.shared.isWallRebuilding {
                    visLog("swap tick SKIPPED — id=\(loopId) (rebuilding)")
                    continue
                }
                tick += 1
                let startedFades = fades.count
                let count = max(1, s.swapsPerTick)
                for _ in 0..<count { queueOneSwap() }
                visLog("swap tick — id=\(loopId) tick=\(tick) n=\(count) waitMs=\(waitMs) fadesBefore=\(startedFades) fadesAfter=\(fades.count)")
            }
            visLog("swap loop EXIT (loop end) — id=\(loopId) tick=\(tick)")
        }
    }

    @MainActor private static var swapLoopCounter: Int = 0
    @MainActor private static func nextSwapLoopId() -> Int {
        swapLoopCounter += 1
        return swapLoopCounter
    }

    /// One small-tile fade per call. Two phases interleaved:
    ///
    /// 1. **Blank → real** — if there are any blanks on the wall,
    ///    half the time pick one and fade it to real art. Sets
    ///    `nextSwapShouldBlank` so the next call rebalances.
    /// Picks a non-fading slot and crossfades to a fresh URL.
    /// Slot size is sampled per call:
    ///   - 1×1 most of the time (default 80%)
    ///   - 2×2 occasionally (default 15%)
    ///   - 3×3 rarely (default 5%)
    /// 4×4 is never auto-rotated — the hero anchor stays put. If
    /// the chosen size has no eligible slots, falls through to
    /// 1×1. Source pool depends on size: 1×1 prefers random/ambient
    /// for variety; 2×2/3×3 prefer genre tiers for context.
    private func queueOneSwap() {
        guard !slots.isEmpty else { return }
        let now = Date().timeIntervalSinceReferenceDate
        let visible = Set(slotURLs.values)
        let s = BackOfTheClubDebugState.shared

        // Size pick.
        let p3 = max(0, min(100, s.swap3x3Percent))
        let p2 = max(0, min(100, s.swap2x2Percent))
        let roll = Int.random(in: 0..<100)
        let targetSize: Int = {
            if roll < p3 { return 3 }
            if roll < p3 + p2 { return 2 }
            return 1
        }()

        // Try the target size, then fall back to 1×1 if none free.
        var slotIdx: Int? = slots.indices.filter {
            slots[$0].sizeClass == targetSize && fades[$0] == nil
        }.randomElement()
        if slotIdx == nil, targetSize != 1 {
            slotIdx = slots.indices.filter {
                slots[$0].sizeClass == 1 && fades[$0] == nil
            }.randomElement()
        }
        guard let chosenIdx = slotIdx else { return }
        let actualSize = slots[chosenIdx].sizeClass

        let candidatesByPreference: [[URL]]
        if actualSize == 1 {
            // Variety-first chain — keeps small-tile rotation feeling
            // diverse rather than monotone-genre.
            candidatesByPreference = [
                pool.random.filter { !visible.contains($0) },
                pool.ambient.filter { !visible.contains($0) },
                pool.genreTier3.filter { !visible.contains($0) },
                pool.genreTier2.filter { !visible.contains($0) },
                pool.genreTier1.filter { !visible.contains($0) },
            ]
        } else {
            // Genres-first for 2×2/3×3 so larger rotations stay
            // contextually tied to the playing track.
            candidatesByPreference = [
                pool.genreTier1.filter { !visible.contains($0) },
                pool.genreTier2.filter { !visible.contains($0) },
                pool.genreTier3.filter { !visible.contains($0) },
                pool.random.filter { !visible.contains($0) },
                pool.ambient.filter { !visible.contains($0) },
            ]
        }
        guard let newURL = candidatesByPreference.first(where: { !$0.isEmpty })?.randomElement() else { return }
        let oldURL = slotURLs[chosenIdx]
        startFade(slotIdx: chosenIdx, oldURL: oldURL, newURL: newURL, startTime: now)
    }

    /// Track-change hero swap — fades the ANCHOR 4×4 (always the
    /// first 4×4 in `slots`, geometrically the centre tile) to the
    /// new now-playing art. The anchor is the single canonical
    /// "now playing" tile, so on every track change we update it
    /// in place — never spread the hero across multiple large
    /// tiles. Any other slot that happens to be showing the new
    /// hero URL (e.g. coincidental queue-art overlap in queue
    /// mode) is simultaneously demoted to a fresh URL so we never
    /// end up with duplicate art after the swap.
    private func triggerNowPlayingHeroSwap() {
        if BackOfTheClubDebugState.shared.isWallRebuilding {
            visLog("triggerNowPlayingHeroSwap NOOP — rebuild in progress")
            return
        }
        // Prefer the canonical now-playing URL (same one the now-
        // playing card on the main view uses). Falls back to the
        // pool's preferred[0] when the parent hasn't resolved a URL
        // yet (e.g. very first frame before settledArtURL settles).
        guard let heroURL = nowPlayingHeroURL ?? pool.preferred.first else {
            visLog("triggerNowPlayingHeroSwap NOOP — heroURL empty (settled=\(nowPlayingHeroURL != nil) preferred=\(pool.preferred.count))")
            return
        }
        guard let anchorIdx = slots.firstIndex(where: { $0.sizeClass == 4 })
                ?? slots.firstIndex(where: { $0.sizeClass == 3 }) else {
            visLog("triggerNowPlayingHeroSwap NOOP — no anchor slot")
            return
        }
        if slotURLs[anchorIdx] == heroURL {
            visLog("triggerNowPlayingHeroSwap NOOP — anchor already shows hero")
            pendingHeroURL = nil
            return
        }
        // If the cover is opaque, the user can't see a fade. Commit
        // the URL directly so we don't have a fade still running
        // when the cover lifts. Threshold 0.5: anything ≥ this
        // hides the wall enough that a fade is invisible (and any
        // residual reveal during cover fade-OUT is brief enough to
        // not register).
        if coverOpacity >= 0.5 {
            slotURLs[anchorIdx] = heroURL
            if fades[anchorIdx] != nil {
                fades.removeValue(forKey: anchorIdx)
            }
            pendingHeroURL = nil
            visLog("triggerNowPlayingHeroSwap COMMIT-DIRECT — cover opaque (\(String(format: "%.2f", coverOpacity))), no fade")
            return
        }
        if fades[anchorIdx] != nil {
            // Anchor is mid-fade. Don't drop the new URL on the floor
            // — queue it. The fade-commit handler re-fires
            // triggerNowPlayingHeroSwap when the in-flight fade ends.
            pendingHeroURL = heroURL
            visLog("triggerNowPlayingHeroSwap QUEUED — anchor mid-fade pendingURL=...\(heroURL.absoluteString.suffix(50))")
            return
        }
        // About to fire — clear the pending slot so the post-fade
        // re-trigger doesn't double-fire on the same URL.
        pendingHeroURL = nil
        visLog("triggerNowPlayingHeroSwap FIRE — anchor=\(anchorIdx) heroURL=...\(heroURL.absoluteString.suffix(50))")
        let now = Date().timeIntervalSinceReferenceDate

        // Pre-pick replacements for any other tiles currently
        // showing heroURL (so each demote gets a distinct URL).
        let dupSlots = slots.indices.filter {
            $0 != anchorIdx
                && slotURLs[$0] == heroURL
                && fades[$0] == nil
        }
        var reserved = Set(slotURLs.values)
        reserved.insert(heroURL)
        var replacements: [(Int, URL)] = []
        for dupIdx in dupSlots {
            let candidatesByPreference: [[URL]] = [
                pool.random.filter { !reserved.contains($0) },
                pool.ambient.filter { !reserved.contains($0) },
                pool.genreTier3.filter { !reserved.contains($0) },
                pool.genreTier2.filter { !reserved.contains($0) },
                pool.genreTier1.filter { !reserved.contains($0) },
            ]
            guard let newURL = candidatesByPreference
                .first(where: { !$0.isEmpty })?.randomElement() else { continue }
            reserved.insert(newURL)
            replacements.append((dupIdx, newURL))
        }

        // Fade the anchor to the new hero, demote any duplicates.
        let oldHeroURL = slotURLs[anchorIdx]
        startFade(slotIdx: anchorIdx, oldURL: oldHeroURL, newURL: heroURL, startTime: now)
        for (dupIdx, newURL) in replacements {
            startFade(slotIdx: dupIdx, oldURL: heroURL, newURL: newURL, startTime: now)
        }
    }

    /// Track-change seed swap — picks `count` random 1×1 slots
    /// (skipping ones already mid-fade) and fades each to a fresh
    /// URL from `pool.genreTier1` (the new track's top-genre matches).
    /// Skipped if the new track has no genre tier1 art available.
    private func triggerGenreSeedSwaps(count: Int) {
        visLog("triggerGenreSeedSwaps ENTER — count=\(count) rebuilding=\(BackOfTheClubDebugState.shared.isWallRebuilding)")
        // Re-check at fire-time. The handler that scheduled this
        // 2-s-delayed task may have evaluated rebuildInProgress
        // BEFORE the rebuild started; without re-checking, the
        // delayed seed swap lands mid-rebuild (visible as tile
        // fade through a partially-opaque cover).
        if BackOfTheClubDebugState.shared.isWallRebuilding { return }
        guard count > 0, !slots.isEmpty else { return }
        let visible = Set(slotURLs.values)
        let candidates = pool.genreTier1.filter { !visible.contains($0) }
        guard !candidates.isEmpty else { return }
        let smallIndices = slots.indices.filter {
            slots[$0].sizeClass == 1 && fades[$0] == nil
        }
        guard !smallIndices.isEmpty else { return }
        let pickedSlots = smallIndices.shuffled().prefix(count)
        let pickedURLs = candidates.shuffled().prefix(pickedSlots.count)
        let now = Date().timeIntervalSinceReferenceDate
        for (slotIdx, newURL) in zip(pickedSlots, pickedURLs) {
            let oldURL = slotURLs[slotIdx]
            startFade(slotIdx: slotIdx, oldURL: oldURL, newURL: newURL, startTime: now)
        }
    }
}

/// One packed cell on the 16×9 grid. `sizeClass` is 1, 2, or 3 (the
/// cell side count), mirroring the play-count rank that earned the
/// slot. Currently used only for tile placement, but kept on the
/// struct so future overlays (e.g. play-count badges) can read it
/// without re-deriving from `rect.width`.
private struct WallSlot: Equatable {
    let rect: CGRect
    let sizeClass: Int
}

private enum WallSlotPacker {
    /// Layout: 3 large 4×4 super-cells, ≥28 medium 3×3, fill rest
    /// with 1×1. Largest cells placed first so they reliably find
    /// space in the unoccupied grid. The wall layout caps any 1×1
    /// run at length 2 in any row or column — that requires roughly
    /// 28+ × 3×3 tiles to break up
    /// the 25×14 grid; the original 12 left ~5-cell 1×1 stretches
    /// visible in the rendered wall. After greedy random placement,
    /// `breakLong1x1Runs` does a constraint-driven sweep and force-
    /// places extra 3×3s on any remaining run of length ≥ 3.
    ///
    /// `originX/originY` shift the whole grid by a fixed (typically
    /// negative, fractional) offset. With cellSize 80 and a 25×14
    /// grid (2000 × 1120), an offset of ~(-34, -22) makes the wall
    /// extend past every edge of the 1920 × 1080 logical canvas, so
    /// the eye reads it as a wall continuing past the window frame
    /// rather than a moodboard sized to fit.
    /// Bounding rect of a placed medium/large super-cell, used by
    /// the cluster check below.
    fileprivate struct LargeRect: Equatable {
        let c: Int
        let r: Int
        let side: Int
    }

    /// Tunable packer config. Defaults are the dialed-in production
    /// values; the debug window threads its own values in via
    /// `BackOfTheClubDebugState`.
    struct Config {
        var count4x4: Int = 2   // includes the anchor
        var count3x3: Int = 4
        var count2x2: Int = 8
        var maxLargeNeighbours: Int = 2
        var maxLargeComponent: Int = 3
        static let `default` = Config()
    }

    static func pack(seed: UInt32, cols: Int, rows: Int, cellSize: CGFloat,
                     originX: CGFloat = 0, originY: CGFloat = 0,
                     config: Config = .default) -> [WallSlot] {
        var rng = SeededRNG(seed: seed)
        var occupied = Array(repeating: Array(repeating: false, count: rows), count: cols)
        var slots: [WallSlot] = []
        var largeRects: [LargeRect] = []

        // Anchor 4×4 — always placed first at one of four diagonal
        // off-centre positions chosen via the seed. Visible window
        // centre sits at grid ~(12.4, 7.0); each candidate leaves
        // at least a 2-cell gap between the anchor's nearest edge
        // and the centre point so the centre always reads as open.
        // Skipped entirely if the user dials count4x4 to 0.
        if config.count4x4 >= 1 {
            let anchorCandidates: [(c: Int, r: Int)] = [
                (8, 3),   // above-left of centre
                (12, 3),  // above-right
                (8, 9),   // below-left
                (12, 9),  // below-right
            ]
            let anchor = anchorCandidates[Int(rng.next()) % anchorCandidates.count]
            _ = tryPlaceSuperCell(at: anchor.c, r: anchor.r, side: 4,
                                  cols: cols, rows: rows, cellSize: cellSize,
                                  originX: originX, originY: originY,
                                  occupied: &occupied, slots: &slots,
                                  largeRects: &largeRects, config: config)
        }

        let extra4x4 = max(0, config.count4x4 - 1)
        placeSuperCells(count: extra4x4, side: 4, rng: &rng,
                        cols: cols, rows: rows, cellSize: cellSize,
                        originX: originX, originY: originY,
                        occupied: &occupied, slots: &slots,
                        largeRects: &largeRects, config: config)
        placeSuperCells(count: max(0, config.count3x3), side: 3, rng: &rng,
                        cols: cols, rows: rows, cellSize: cellSize,
                        originX: originX, originY: originY,
                        occupied: &occupied, slots: &slots,
                        largeRects: &largeRects, config: config)
        placeSuperCells(count: max(0, config.count2x2), side: 2, rng: &rng,
                        cols: cols, rows: rows, cellSize: cellSize,
                        originX: originX, originY: originY,
                        occupied: &occupied, slots: &slots,
                        largeRects: &largeRects, config: config)

        breakLong1x1Runs(rng: &rng, cols: cols, rows: rows, cellSize: cellSize,
                         originX: originX, originY: originY,
                         occupied: &occupied, slots: &slots,
                         largeRects: &largeRects, config: config)

        for c in 0..<cols {
            for r in 0..<rows where !occupied[c][r] {
                let rect = CGRect(x: originX + CGFloat(c) * cellSize,
                                  y: originY + CGFloat(r) * cellSize,
                                  width: cellSize, height: cellSize)
                slots.append(WallSlot(rect: rect, sizeClass: 1))
                occupied[c][r] = true
            }
        }
        return slots
    }

    /// Two rects are "touching" iff they share any portion of an
    /// edge OR meet at a single corner point. Used by
    /// `wouldOversizeCluster` to enforce the user's "no more than
    /// 2 large touching" rule, including diagonal corner contact.
    fileprivate static func areEdgeAdjacent(_ a: LargeRect, _ b: LargeRect) -> Bool {
        let aRight = a.c + a.side
        let aBottom = a.r + a.side
        let bRight = b.c + b.side
        let bBottom = b.r + b.side
        // Vertical edge contact (one's right edge meets the other's
        // left) with overlapping row span.
        if aRight == b.c && a.r < bBottom && b.r < aBottom { return true }
        if bRight == a.c && b.r < aBottom && a.r < bBottom { return true }
        // Horizontal edge contact (one's bottom meets the other's
        // top) with overlapping column span.
        if aBottom == b.r && a.c < bRight && b.c < aRight { return true }
        if bBottom == a.r && b.c < aRight && a.c < bRight { return true }
        // Corner contact — four diagonal cases where exactly one
        // grid point is shared between the two rects.
        if aRight == b.c && aBottom == b.r { return true }  // A bottom-right ↔ B top-left
        if bRight == a.c && bBottom == a.r { return true }  // B bottom-right ↔ A top-left
        if aRight == b.c && a.r == bBottom { return true }  // A top-right ↔ B bottom-left
        if bRight == a.c && b.r == aBottom { return true }  // B top-right ↔ A bottom-left
        return false
    }

    /// Returns true if placing `candidate` violates the placement
    /// rules. Two specific rules enforced (replaced the older
    /// generic "≤2 cluster" check):
    ///   1. A 4×4 may never be edge-adjacent to another 4×4.
    ///   2. A 3×3 may be edge-adjacent to AT MOST 2 large tiles
    ///      (4×4 or 3×3 — they all count as "large").
    /// Bidirectional check: also verifies that adding `candidate`
    /// next to an existing 3×3 doesn't push THAT 3×3's own large-
    /// neighbour count over 2.
    fileprivate static func wouldOversizeCluster(_ candidate: LargeRect,
                                                 in largeRects: [LargeRect],
                                                 config: Config) -> Bool {
        // Rules (all three must hold):
        //   1. No tile > 1×1 may be adjacent to more than
        //      `maxLargeNeighbours` other tiles > 1×1 (edge or
        //      corner contact).
        //   2. Bidirectional version of rule 1 — placing the
        //      candidate must not push any existing neighbour over
        //      its own cap.
        //   3. The connected component of > 1×1 tiles formed by
        //      placing the candidate may not exceed
        //      `maxLargeComponent` tiles.
        let larges = largeRects.filter { $0.side >= 2 }
        let neighbours = larges.filter { areEdgeAdjacent($0, candidate) }
        if neighbours.count > config.maxLargeNeighbours { return true }

        for n in neighbours {
            let existingNCount = larges.filter {
                $0 != n && areEdgeAdjacent($0, n)
            }.count
            if existingNCount + 1 > config.maxLargeNeighbours { return true }
        }

        var visited: Set<Int> = []
        var queue: [Int] = []
        for (i, r) in larges.enumerated() where areEdgeAdjacent(r, candidate) {
            if visited.insert(i).inserted { queue.append(i) }
        }
        while !queue.isEmpty {
            let idx = queue.removeFirst()
            let r = larges[idx]
            for (i, other) in larges.enumerated()
                where !visited.contains(i) && areEdgeAdjacent(r, other) {
                visited.insert(i)
                queue.append(i)
            }
        }
        if 1 + visited.count > config.maxLargeComponent { return true }

        return false
    }

    /// Goal-directed greedy run-breaker.
    ///
    /// Replaces the older "find a run, try one position above/left
    /// of it" heuristic which fails when local geometry is tight or
    /// the cluster rule blocks the only obvious placement.
    ///
    /// Algorithm (a 2D bin-packing variant — best-first search with
    /// a global cost function, as used in polyomino tiling):
    ///
    ///   1. Compute the global violation cost: count every cell that
    ///      is the 3rd-or-later in a run of empties along any row or
    ///      column. Zero cost = no rule-3 violation anywhere.
    ///   2. Enumerate every legal 2×2 and 3×3 placement on the grid
    ///      (clear cells + adjacency-rule compliant).
    ///   3. For each, simulate the placement and recompute cost.
    ///   4. Pick the candidate with the largest cost reduction; place
    ///      it. Ties broken by smaller side (prefer 2×2).
    ///   5. Repeat until no candidate improves the score, or up to a
    ///      hard pass cap.
    ///
    /// Trade-off: if the adjacency rules and "no 3-runs" rule are
    /// genuinely in conflict for a given seed, the algorithm halts
    /// with residual violations rather than relaxing rules. The
    /// global view typically resolves what the old single-position
    /// run-breaker could not.
    private static func breakLong1x1Runs(rng: inout SeededRNG, cols: Int, rows: Int,
                                         cellSize: CGFloat,
                                         originX: CGFloat, originY: CGFloat,
                                         occupied: inout [[Bool]],
                                         slots: inout [WallSlot],
                                         largeRects: inout [LargeRect],
                                         config: Config) {
        for _ in 0..<20 {
            let currentCost = runViolationCost(occupied: occupied, cols: cols, rows: rows)
            if currentCost == 0 { return }

            var bestC = 0, bestR = 0, bestSide = 0, bestReduction = 0
            for side in [2, 3] {
                guard side <= cols, side <= rows else { continue }
                for c in 0...(cols - side) {
                    for r in 0...(rows - side) {
                        // Clear-area check.
                        var clear = true
                        scan: for x in c..<(c + side) {
                            for y in r..<(r + side) where occupied[x][y] {
                                clear = false; break scan
                            }
                        }
                        if !clear { continue }

                        let candidate = LargeRect(c: c, r: r, side: side)
                        if wouldOversizeCluster(candidate, in: largeRects, config: config) { continue }

                        // Simulate and re-score.
                        for x in c..<(c + side) {
                            for y in r..<(r + side) { occupied[x][y] = true }
                        }
                        let newCost = runViolationCost(occupied: occupied, cols: cols, rows: rows)
                        for x in c..<(c + side) {
                            for y in r..<(r + side) { occupied[x][y] = false }
                        }

                        let reduction = currentCost - newCost
                        // Prefer larger reduction; ties → smaller tile.
                        if reduction > bestReduction
                            || (reduction == bestReduction && reduction > 0 && side < bestSide) {
                            bestReduction = reduction
                            bestC = c; bestR = r; bestSide = side
                        }
                    }
                }
            }

            if bestReduction == 0 { return }  // no rule-compliant improvement available

            // Commit the winning placement.
            for x in bestC..<(bestC + bestSide) {
                for y in bestR..<(bestR + bestSide) { occupied[x][y] = true }
            }
            let rect = CGRect(x: originX + CGFloat(bestC) * cellSize,
                              y: originY + CGFloat(bestR) * cellSize,
                              width: CGFloat(bestSide) * cellSize,
                              height: CGFloat(bestSide) * cellSize)
            slots.append(WallSlot(rect: rect, sizeClass: bestSide))
            largeRects.append(LargeRect(c: bestC, r: bestR, side: bestSide))
            _ = rng.next()  // keep stream deterministic per pass
        }
    }

    /// Sum, over every row and column, of the count of unoccupied
    /// cells that are the 3rd-or-later in a contiguous empty run.
    /// 0 means no row/col has any run of length ≥ 3. A run of length
    /// L contributes max(0, L − 2) to the score, so longer runs are
    /// proportionally more "expensive" and the greedy picks the
    /// placement that buys the most reduction.
    private static func runViolationCost(occupied: [[Bool]], cols: Int, rows: Int) -> Int {
        var total = 0
        for r in 0..<rows {
            var run = 0
            for c in 0..<cols {
                if !occupied[c][r] {
                    run += 1
                    if run >= 3 { total += 1 }
                } else { run = 0 }
            }
        }
        for c in 0..<cols {
            var run = 0
            for r in 0..<rows {
                if !occupied[c][r] {
                    run += 1
                    if run >= 3 { total += 1 }
                } else { run = 0 }
            }
        }
        return total
    }

    /// Tries to place a `side × side` super-cell with top-left at
    /// (c, r), nudging by ±1 in each direction if the requested
    /// origin is out of bounds or overlaps. Returns true on success.
    /// NOW enforces the adjacency rules (`wouldOversizeCluster`) —
    /// previously did not, which let the run-breaker drop 3×3s next
    /// to existing 4×4s/3×3s and produce visible clusters of 3+
    /// large tiles. Trade-off: some 1×1 runs longer than 2 will
    /// remain when the geometry can't accommodate a rule-compliant
    /// breaker tile. Adjacency rules now win over the 1×1-run cap.
    private static func tryPlaceSuperCell(at c: Int, r: Int, side: Int,
                                          cols: Int, rows: Int, cellSize: CGFloat,
                                          originX: CGFloat, originY: CGFloat,
                                          occupied: inout [[Bool]],
                                          slots: inout [WallSlot],
                                          largeRects: inout [LargeRect],
                                          config: Config) -> Bool {
        for dc in -1...1 {
            for dr in -1...1 {
                let cc = c + dc
                let rr = r + dr
                guard cc >= 0, rr >= 0, cc + side <= cols, rr + side <= rows else { continue }
                var clear = true
                check: for x in cc..<(cc + side) {
                    for y in rr..<(rr + side) where occupied[x][y] {
                        clear = false; break check
                    }
                }
                guard clear else { continue }
                let candidate = LargeRect(c: cc, r: rr, side: side)
                if wouldOversizeCluster(candidate, in: largeRects, config: config) { continue }
                for x in cc..<(cc + side) {
                    for y in rr..<(rr + side) {
                        occupied[x][y] = true
                    }
                }
                let rect = CGRect(x: originX + CGFloat(cc) * cellSize,
                                  y: originY + CGFloat(rr) * cellSize,
                                  width: CGFloat(side) * cellSize,
                                  height: CGFloat(side) * cellSize)
                slots.append(WallSlot(rect: rect, sizeClass: side))
                largeRects.append(candidate)
                return true
            }
        }
        return false
    }

    private static func placeSuperCells(count: Int, side: Int,
                                        rng: inout SeededRNG,
                                        cols: Int, rows: Int, cellSize: CGFloat,
                                        originX: CGFloat, originY: CGFloat,
                                        occupied: inout [[Bool]],
                                        slots: inout [WallSlot],
                                        largeRects: inout [LargeRect],
                                        config: Config) {
        var placed = 0
        var attempts = 0
        let maxC = cols - side + 1
        let maxR = rows - side + 1
        guard maxC > 0, maxR > 0 else { return }
        while placed < count && attempts < 2000 {
            attempts += 1
            let c = Int(rng.next() % UInt32(maxC))
            let r = Int(rng.next() % UInt32(maxR))
            var clear = true
            outer: for cc in c..<(c + side) {
                for rr in r..<(r + side) where occupied[cc][rr] {
                    clear = false
                    break outer
                }
            }
            guard clear else { continue }
            let candidate = LargeRect(c: c, r: r, side: side)
            if wouldOversizeCluster(candidate, in: largeRects, config: config) { continue }
            for cc in c..<(c + side) {
                for rr in r..<(r + side) {
                    occupied[cc][rr] = true
                }
            }
            let rect = CGRect(x: originX + CGFloat(c) * cellSize,
                              y: originY + CGFloat(r) * cellSize,
                              width: CGFloat(side) * cellSize,
                              height: CGFloat(side) * cellSize)
            slots.append(WallSlot(rect: rect, sizeClass: side))
            largeRects.append(candidate)
            placed += 1
        }
    }
}

/// Mulberry32 — small, fast, deterministic. Same seed → identical
/// stream, so the wall is stable per-track-URI but reshuffles when
/// the URI changes.
private struct SeededRNG {
    private var state: UInt32
    init(seed: UInt32) { state = seed == 0 ? 1 : seed }
    mutating func next() -> UInt32 {
        state &+= 0x6D2B79F5
        var z = state
        z = (z ^ (z >> 15)) &* (z | 1)
        z ^= z &+ ((z ^ (z >> 7)) &* (z | 61))
        return z ^ (z >> 14)
    }
}

// MARK: - Lighting

/// Slow drifting stage-light wash. Renders as a handful of soft,
/// blurred ovals anchored toward the corners/edges of the wall —
/// the impression is of background reflected lighting from a live
/// performance whose actual stage lights are happening elsewhere
/// in the venue. Each oval has its own size, rotation, drift
/// orbit, and colour role, so neighbouring ovals never share the
/// same hue (the user spec: "always different base gradient
/// colours such as one red and one green").
///
/// The cue system underneath (`StageCue` triples + 90s hold / 36s
/// fade cycle through 7 named cues) drives the colour palette —
/// each oval's `colorRoleIndex` picks one of the active cue's
/// three colours, so the wall settles into a coherent mood (rock
/// show, cool wash, warm ballad, etc.) before transitioning.
///
/// 15 fps timeline — the motion is intentionally slow and 15 fps
/// halves the render cost on 4K fullscreen vs. the previous 30 fps.
/// All time math uses `timeIntervalSinceReferenceDate` so phase is
/// stable across re-renders.
private struct ClubVisLightingView: View {
    /// One coherent stage-light state — three colours that read as
    /// a single venue cue (rock show, cool wash, etc.). Layers and
    /// spots all draw from the active cue so the wall reads as one
    /// lighting design rather than randomly-coloured spots.
    fileprivate struct StageCue {
        let name: String
        let primary: RGB
        let secondary: RGB
        let tertiary: RGB
    }
    fileprivate typealias RGB = (r: Double, g: Double, b: Double)

    /// Named cues curated to match the reference image's range —
    /// each triple is a typical live-music venue lighting state.
    /// `fileprivate` so the debug companion window can render the
    /// stage picker with names + colour swatches.
    fileprivate static let cues: [StageCue] = [
        .init(name: "Rock show",
              primary: (0.85, 0.10, 0.20),
              secondary: (0.95, 0.20, 0.55),
              tertiary: (0.50, 0.10, 0.85)),
        .init(name: "Cool wash",
              primary: (0.10, 0.30, 0.95),
              secondary: (0.00, 0.65, 0.85),
              tertiary: (0.30, 0.85, 0.95)),
        .init(name: "Warm ballad",
              primary: (0.95, 0.55, 0.10),
              secondary: (0.95, 0.30, 0.10),
              tertiary: (0.85, 0.10, 0.20)),
        .init(name: "Synthwave",
              primary: (0.95, 0.20, 0.55),
              secondary: (0.50, 0.10, 0.85),
              tertiary: (0.20, 0.10, 0.65)),
        .init(name: "Atmospheric",
              primary: (0.05, 0.75, 0.40),
              secondary: (0.00, 0.65, 0.85),
              tertiary: (0.65, 0.85, 0.20)),
        .init(name: "Pop bright",
              primary: (0.95, 0.40, 0.65),
              secondary: (0.95, 0.55, 0.30),
              tertiary: (0.85, 0.10, 0.20)),
        .init(name: "Dark moody",
              primary: (0.30, 0.10, 0.55),
              secondary: (0.20, 0.10, 0.65),
              tertiary: (0.05, 0.05, 0.20)),
    ]

    /// SwiftUI Color exposed for the debug window's swatches.
    fileprivate static func swatchColor(_ rgb: RGB) -> Color {
        Color(red: rgb.r, green: rgb.g, blue: rgb.b)
    }

    @ObservedObject private var debugState = BackOfTheClubDebugState.shared

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let ctrl = debugState.lighting
            let cue = Self.activeCue(at: t,
                                     period: ctrl.cuePeriod,
                                     fadeFraction: ctrl.cueFadeFraction,
                                     override: ctrl.stageOverride)

            ZStack {
                ambientLayer(t: t, cue: cue, ctrl: ctrl)
                    .compositingGroup()
                    .blendMode(ctrl.ambientBlendMode.blend)

                spotlightLayer(t: t, cue: cue, ctrl: ctrl)
                    .compositingGroup()
                    .blendMode(ctrl.spotlightBlendMode.blend)
            }
            .frame(width: ClubVisWindow.logicalWidth,
                   height: ClubVisWindow.logicalHeight)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func ambientLayer(t: Double, cue: StageCue,
                              ctrl: BackOfTheClubDebugState.LightingControls) -> some View {
        ZStack {
            if ctrl.ambientLEnabled {
                ambientCircle(t: t, period: ctrl.ambientLPeriod, phase: 0,
                              anchorX: ctrl.ambientLAnchorX, anchorY: ctrl.ambientLAnchorY,
                              driftX: ctrl.ambientLDriftX, driftY: ctrl.ambientLDriftY,
                              sizeMul: ctrl.ambientLSize, blur: ctrl.ambientLBlur,
                              centreOpacity: ctrl.ambientLOpacity,
                              intensity: ctrl.ambientLIntensity,
                              brightness: ctrl.ambientLBrightness,
                              saturation: ctrl.ambientLSaturation,
                              blend: ctrl.ambientLBlend.blend,
                              color: cue.primary)
            }
            if ctrl.ambientREnabled {
                ambientCircle(t: t, period: ctrl.ambientRPeriod, phase: .pi,
                              anchorX: ctrl.ambientRAnchorX, anchorY: ctrl.ambientRAnchorY,
                              driftX: ctrl.ambientRDriftX, driftY: ctrl.ambientRDriftY,
                              sizeMul: ctrl.ambientRSize, blur: ctrl.ambientRBlur,
                              centreOpacity: ctrl.ambientROpacity,
                              intensity: ctrl.ambientRIntensity,
                              brightness: ctrl.ambientRBrightness,
                              saturation: ctrl.ambientRSaturation,
                              blend: ctrl.ambientRBlend.blend,
                              color: cue.secondary)
            }
        }
    }

    @ViewBuilder
    private func spotlightLayer(t: Double, cue: StageCue,
                                ctrl: BackOfTheClubDebugState.LightingControls) -> some View {
        ZStack {
            if ctrl.spotlightTLEnabled {
                spotlightOval(t: t, period: ctrl.spotlightTLPeriod, phase: 0.7,
                              anchorX: ctrl.spotlightTLAnchorX, anchorY: ctrl.spotlightTLAnchorY,
                              driftX: ctrl.spotlightTLDriftX, driftY: ctrl.spotlightTLDriftY,
                              widthFrac: ctrl.spotlightTLWidth, heightFrac: ctrl.spotlightTLHeight,
                              rotationDeg: ctrl.spotlightTLRotation, blur: ctrl.spotlightTLBlur,
                              centreOpacity: ctrl.spotlightTLOpacity,
                              intensity: ctrl.spotlightTLIntensity,
                              brightness: ctrl.spotlightTLBrightness,
                              saturation: ctrl.spotlightTLSaturation,
                              blend: ctrl.spotlightTLBlend.blend,
                              color: cue.tertiary)
            }
            if ctrl.spotlightBREnabled {
                spotlightOval(t: t, period: ctrl.spotlightBRPeriod, phase: 2.4,
                              anchorX: ctrl.spotlightBRAnchorX, anchorY: ctrl.spotlightBRAnchorY,
                              driftX: ctrl.spotlightBRDriftX, driftY: ctrl.spotlightBRDriftY,
                              widthFrac: ctrl.spotlightBRWidth, heightFrac: ctrl.spotlightBRHeight,
                              rotationDeg: ctrl.spotlightBRRotation, blur: ctrl.spotlightBRBlur,
                              centreOpacity: ctrl.spotlightBROpacity,
                              intensity: ctrl.spotlightBRIntensity,
                              brightness: ctrl.spotlightBRBrightness,
                              saturation: ctrl.spotlightBRSaturation,
                              blend: ctrl.spotlightBRBlend.blend,
                              color: cue.primary)
            }
        }
    }

    @ViewBuilder
    private func ambientCircle(t: Double, period: Double, phase: Double,
                                anchorX: Double, anchorY: Double,
                                driftX: Double, driftY: Double,
                                sizeMul: Double, blur: Double,
                                centreOpacity: Double, intensity: Double,
                                brightness: Double, saturation: Double,
                                blend: BlendMode, color: RGB) -> some View {
        let omega = 2.0 * .pi / max(0.001, period)
        let angle = t * omega + phase
        let dx = cos(angle) * driftX
        let dy = sin(angle * 0.7) * driftY
        let logicalW = ClubVisWindow.logicalWidth
        let logicalH = ClubVisWindow.logicalHeight
        let cx = logicalW * (anchorX + dx)
        let cy = logicalH * (anchorY + dy)
        let diameter = max(logicalW, logicalH) * sizeMul
        let c = Self.color(color)
        // Intensity multiplies centre alpha; brightness/saturation
        // are SwiftUI shader modifiers on the rendered shape.
        let alpha = max(0, min(1, centreOpacity * intensity))
        Circle()
            .fill(
                RadialGradient(
                    gradient: Gradient(colors: [
                        c.opacity(alpha),
                        c.opacity(alpha * 0.6),
                        c.opacity(0.0),
                    ]),
                    center: .center,
                    startRadius: 0,
                    endRadius: diameter / 2
                )
            )
            .frame(width: diameter, height: diameter)
            .position(x: cx, y: cy)
            .blur(radius: blur)
            .saturation(saturation)
            .brightness(brightness)
            .blendMode(blend)
    }

    @ViewBuilder
    private func spotlightOval(t: Double, period: Double, phase: Double,
                                anchorX: Double, anchorY: Double,
                                driftX: Double, driftY: Double,
                                widthFrac: Double, heightFrac: Double,
                                rotationDeg: Double, blur: Double,
                                centreOpacity: Double, intensity: Double,
                                brightness: Double, saturation: Double,
                                blend: BlendMode, color: RGB) -> some View {
        let omega = 2.0 * .pi / max(0.001, period)
        let angle = t * omega + phase
        let dx = cos(angle) * driftX
        let dy = sin(angle * 0.6) * driftY
        let logicalW = ClubVisWindow.logicalWidth
        let logicalH = ClubVisWindow.logicalHeight
        let cx = logicalW * (anchorX + dx)
        let cy = logicalH * (anchorY + dy)
        let w = logicalW * widthFrac
        let h = logicalH * heightFrac
        let c = Self.color(color)
        let alpha = max(0, min(1, centreOpacity * intensity))
        Ellipse()
            .fill(
                RadialGradient(
                    gradient: Gradient(colors: [
                        c.opacity(alpha),
                        c.opacity(0.0),
                    ]),
                    center: .center,
                    startRadius: 0,
                    endRadius: max(w, h) / 2
                )
            )
            .frame(width: w, height: h)
            .rotationEffect(.degrees(rotationDeg))
            .position(x: cx, y: cy)
            .blur(radius: blur)
            .saturation(saturation)
            .brightness(brightness)
            .blendMode(blend)
    }

    /// Picks the active cue. If `override >= 0` and within bounds,
    /// returns that specific cue verbatim (stage pinned). Otherwise
    /// each cycle slot picks a deterministic-but-shuffled cue index
    /// via `cueIndexForCycle`, so the wall doesn't march through
    /// `cues` in array order — but two adjacent cycles never land
    /// on the same cue (no immediate repeat).
    fileprivate static func activeCue(at t: Double,
                                      period: Double = 120,
                                      fadeFraction: Double = 0.30,
                                      override: Int = -1) -> StageCue {
        if override >= 0 && override < cues.count {
            return cues[override]
        }
        let p = max(1.0, period)
        let cycle = t / p
        let lo = Int(cycle.rounded(.down))
        let frac = cycle - Double(lo)
        let ff = max(0.001, min(0.99, fadeFraction))
        let holdEnd = 1.0 - ff
        let blend: Double
        if frac < holdEnd {
            blend = 0
        } else {
            let phase = (frac - holdEnd) / ff
            blend = phase * phase * (3 - 2 * phase)
        }
        let aIdx = cueIndexForCycle(lo)
        let bIdx = cueIndexForCycle(lo + 1)
        return interpolate(cues[aIdx], cues[bIdx], t: blend)
    }

    /// Deterministic shuffled cue picker: each cycle slot maps to a
    /// pseudo-random cue index, with the constraint that consecutive
    /// cycles never share an index. The pick for cycle `n` is the
    /// raw hash of `n`, shifted forward by 1 if it would equal the
    /// pick chosen for cycle `n − 1`. Iterating forward from a
    /// negative seed slot ensures the no-repeat rule propagates
    /// correctly past any chain of hash collisions.
    private static func cueIndexForCycle(_ n: Int) -> Int {
        let count = cues.count
        guard count > 1 else { return 0 }
        func raw(_ i: Int) -> Int {
            // Knuth-multiplicative + xorshift folding so adjacent
            // integers diffuse into very different bucket indices.
            var h = UInt64(bitPattern: Int64(i)) &* 2_654_435_761
            h ^= (h >> 33)
            return Int(h % UInt64(count))
        }
        // Walk forward from a fixed origin so the shifted-on-collision
        // chain is consistent across calls (otherwise `cueIndexForCycle(5)`
        // and `cueIndexForCycle(6)` could disagree about what slot 5
        // resolved to).
        let origin = max(0, n - 32)  // 32-cycle window is plenty in practice
        var prev = raw(origin)
        if origin >= n { return prev }
        for i in (origin + 1)...n {
            var pick = raw(i)
            if pick == prev { pick = (pick + 1) % count }
            prev = pick
        }
        return prev
    }

    private static func interpolate(_ a: StageCue, _ b: StageCue, t: Double) -> StageCue {
        StageCue(name: t < 0.5 ? a.name : b.name,
                 primary: lerp(a.primary, b.primary, t: t),
                 secondary: lerp(a.secondary, b.secondary, t: t),
                 tertiary: lerp(a.tertiary, b.tertiary, t: t))
    }

    private static func lerp(_ x: RGB, _ y: RGB, t: Double) -> RGB {
        (x.r + (y.r - x.r) * t, x.g + (y.g - x.g) * t, x.b + (y.b - x.b) * t)
    }

    private static func color(_ c: RGB) -> Color {
        Color(red: c.r, green: c.g, blue: c.b)
    }

}

// MARK: - Now Playing card

private struct ClubVisNowPlayingCard: View {
    let trackMetadata: TrackMetadata
    let albumArtURL: URL?
    let sourceLabel: String
    let positionAnchor: PositionAnchor

    /// Average luminance of the current album art in [0, 1]. Updated
    /// asynchronously when `albumArtURL` changes; used to darken
    /// bright covers so a white-on-white sleeve doesn't blow out the
    /// club lighting effect on the wall behind it.
    @State private var artLuma: Double = 0.5

    /// Black-overlay opacity applied to the now-playing art. Zero
    /// for any cover at or below mid-tone; ramps to a maximum of
    /// ~0.25 for the brightest possible cover. The threshold and
    /// max are tuned so dark/colourful covers stay untouched and
    /// only the genuinely bright/white sleeves get pulled down.
    private var artDarkenOpacity: Double {
        let threshold = 0.55
        guard artLuma > threshold else { return 0 }
        let normalized = (artLuma - threshold) / (1.0 - threshold)
        return min(0.25, max(0, normalized * 0.25))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 32) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    CachedAsyncImage(url: albumArtURL, cornerRadius: 8, priority: .interactive)
                        .id(albumArtURL)
                        .transition(.opacity)
                        .overlay(
                            Color.black
                                .opacity(artDarkenOpacity)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .allowsHitTesting(false)
                        )
                        .animation(.easeInOut(duration: 0.4), value: artDarkenOpacity)
                }
                // 2.0 s ease-in-out — earlier 0.8 s read as a quick
                // wipe; this stretches the crossfade so the previous
                // track's art fades through ~50% as the new one
                // climbs from the same midpoint, producing a gentler
                // dissolve.
                .animation(.easeInOut(duration: 2.0), value: albumArtURL)
                .frame(width: 224, height: 224)
                .shadow(color: .black.opacity(0.6), radius: 22, y: 6)
                .task(id: albumArtURL) {
                    // Sample average luminance once the URL's image
                    // is in ImageCache. CachedAsyncImage stores into
                    // the cache after downloading, so we poll for up
                    // to 5 s; defaults to 0.5 (no darkening) if the
                    // image never lands.
                    guard let url = albumArtURL else { artLuma = 0.5; return }
                    for _ in 0..<10 {
                        if let img = ImageCache.shared.image(for: url) {
                            artLuma = img.averagePerceivedLuminance()
                            return
                        }
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                    artLuma = 0.5
                }

                // Always reserve the progress-bar's vertical space —
                // toggling between visible/hidden as duration moves
                // between 0 and >0 (e.g. radio→track) caused the
                // VStack above to reflow and the album art to shift
                // by ~21 pt. .opacity keeps the layout stable.
                progressBar
                    .frame(width: 224)
                    .opacity(trackMetadata.duration > 0 ? 1 : 0)
                    .allowsHitTesting(trackMetadata.duration > 0)
            }

            // Right column: text content top-aligned, source label
            // bottom-aligned to the artwork height. Frame height
            // matches the artwork so the Spacer can push the source
            // label down to sit on the same baseline as the bottom
            // of the album art.
            VStack(alignment: .leading, spacing: 12) {
                if !trackMetadata.artist.isEmpty {
                    Text(trackMetadata.artist.uppercased())
                        .font(.system(size: 30, weight: .heavy))
                        .tracking(2)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                if !trackMetadata.album.isEmpty {
                    Text(trackMetadata.album.uppercased())
                        .font(.system(size: 22, weight: .semibold))
                        .tracking(1.5)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
                if !trackMetadata.title.isEmpty {
                    Text(trackMetadata.title)
                        .font(.system(size: 22, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.95))
                        .lineLimit(2)
                        .padding(.top, 4)
                }
                Spacer(minLength: 0)
                if !sourceLabel.isEmpty {
                    Text(sourceLabel.uppercased())
                        .font(.system(size: 13, weight: .semibold))
                        .tracking(1.5)
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }
            }
            // Symmetric vertical padding — 8 pt at the top (artist
            // line gap) AND 8 pt at the bottom (source label gap)
            // so the right column reads as evenly inset against the
            // 224 pt artwork height.
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, maxHeight: 224, alignment: .topLeading)
        }
        .padding(.trailing, 40)
    }

    /// Slim progress bar + current/total time labels under the
    /// artwork. 10 Hz `TimelineView` projects the position anchor so
    /// the bar advances smoothly between speaker reports — same
    /// pattern the main Now Playing view uses.
    private var progressBar: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            let position = max(0, positionAnchor.projected(at: context.date))
            let dur = trackMetadata.duration
            let progress = dur > 0 ? max(0, min(1, position / dur)) : 0
            VStack(alignment: .leading, spacing: 4) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.18))
                        Capsule()
                            .fill(Color.white.opacity(0.85))
                            .frame(width: geo.size.width * progress)
                    }
                }
                .frame(height: 3)
                HStack {
                    Text(formatTime(position))
                    Spacer()
                    Text(formatTime(dur))
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let s = Int(max(0, t))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

}

// MARK: - Up Next

private struct ClubVisUpNextList: View {
    let queueItems: [QueueItem]
    let currentTrack: Int

    private var upcoming: [QueueItem] {
        guard !queueItems.isEmpty else { return [] }
        let startIdx = queueItems.firstIndex(where: { $0.id == currentTrack }) ?? 0
        let endIdx = min(queueItems.count, startIdx + 7)
        return Array(queueItems[startIdx..<endIdx])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(upcoming, id: \.id) { item in
                let isCurrent = item.id == currentTrack
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: isCurrent ? 21 : 18,
                                      weight: isCurrent ? .semibold : .regular))
                        .foregroundStyle(isCurrent ? .white : .white.opacity(0.85))
                        .lineLimit(1)
                    if !item.artist.isEmpty {
                        Text(item.artist.uppercased())
                            .font(.system(size: 12, weight: .medium))
                            .tracking(1)
                            .foregroundStyle(.white.opacity(isCurrent ? 0.8 : 0.55))
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isCurrent ? Color.white.opacity(0.18) : .clear)
                )
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.black.opacity(0.55))
        )
    }
}

// MARK: - About panel (scrolling bio + tags)

/// Slow-scrolling artist About panel slotted in the bottom-right of
/// the stage, beneath the Up Next list. Bio scrolls vertically like
/// credits — the text starts below the visible area, drifts upward
/// at ~10 pt/s, and loops once it has fully cleared the top. Tags
/// pin to the bottom of the panel so they stay readable regardless
/// of the bio scroll position. Background and corner radius match
/// `ClubVisUpNextList` so the right column reads as one column of
/// two stacked panels.
private struct ClubVisAboutPanel: View {
    let artistInfo: ArtistInfo?

    /// Pixels per second of upward bio scroll. Halved from earlier
    /// 10 pt/s — user feedback was the scroll was too fast to read.
    private static let scrollSpeed: Double = 5.0

    /// Pause held at the end of one full scroll cycle (text fully
    /// off-screen at top) before restarting from the bottom.
    private static let endPause: Double = 3.0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.aboutSectionLabel)
                .font(.system(size: 11, weight: .medium))
                .tracking(2)
                .foregroundStyle(.white.opacity(0.55))

            if let info = artistInfo {
                Text(info.name.uppercased())
                    .font(.system(size: 18, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if let bio = info.bio, !bio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    scrollingBio(text: bio)
                } else {
                    Spacer(minLength: 0)
                }

                if !info.tags.isEmpty {
                    Text(info.tags.prefix(5).joined(separator: " · "))
                        .font(.system(size: 11, weight: .medium))
                        .tracking(0.5)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            } else {
                Spacer(minLength: 0)
                Text("—")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.4))
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.black.opacity(0.55))
        )
    }

    @ViewBuilder
    private func scrollingBio(text: String) -> some View {
        // Measure the rendered text height with GeometryReader inside
        // a `.background` preference so the scroll cycle uses the
        // ACTUAL height instead of a chars-per-line estimate. The
        // estimate truncated the cycle prematurely on long bios so
        // only the first paragraph was visible before looping.
        ScrollingBioBody(text: text,
                         scrollSpeed: Self.scrollSpeed,
                         endPause: Self.endPause)
    }
}

/// Extracted scrolling-bio renderer. Lives outside the parent so the
/// `.background(GeometryReader { ... })` measurement closure has a
/// stable identity across TimelineView ticks.
///
/// Smoothness optimisations mirror `SlidingLyricsView`:
/// - `Equatable` short-circuit so parent re-renders don't tear down
///   and rebuild the TimelineView for unrelated state changes
///   (track metadata, queue, lighting cycles).
/// - `.compositingGroup()` on the moving Text so SwiftUI flattens
///   it to a single CALayer; per-frame `.offset(y:)` then becomes a
///   pure GPU translate instead of re-rasterising the text body.
/// - `.transaction { $0.animation = nil }` strips inherited implicit
///   animations so the per-frame offset can't pick up SwiftUI's
///   ~0.25 s default interpolation and fight the TimelineView motion.
/// - Display-refresh `TimelineView(.animation)` (was 30 fps).
/// - The previous `.mask(LinearGradient)` is replaced with two
///   stationary `.blendMode(.destinationOut)` gradients inside a
///   `.compositingGroup()` parent. Functionally identical edge fade
///   without the per-frame offscreen mask pass.
private struct ScrollingBioBody: View {
    let text: String
    let scrollSpeed: Double
    let endPause: Double

    /// Pre-rendered bio text as a Core Graphics image. Drawn each
    /// frame into a SwiftUI `Canvas` at the current offset — Canvas
    /// honours sub-pixel positioning, while the previous
    /// `Image().offset(y:)` path snapped to pixel boundaries and
    /// produced a visible stair-step jump at the bio's slow
    /// 5 pt/s scroll.
    @State private var bioCGImage: CGImage? = nil
    @State private var textHeight: Double = 0
    /// Backing scale the bitmap was rendered at — used to draw it
    /// into the Canvas at the right point-size.
    @State private var renderScale: CGFloat = 2.0
    /// Width the current bitmap was rendered at. Re-render if the
    /// available width changes (window resize).
    @State private var renderedWidth: CGFloat = 0
    /// Captured at view appear and on every text change — the cycle
    /// is computed against (now - startTime) so the scroll always
    /// begins from the bottom of the viewport on a fresh render
    /// (or when the artist changes), instead of landing at a random
    /// position derived from the absolute reference date.
    @State private var startTime: Double = Date().timeIntervalSinceReferenceDate
    /// Crossfade opacity for artist transitions. On text change,
    /// the existing bitmap fades to 0, the new bitmap renders, and
    /// the opacity fades back to 1. Avoids the "title updates,
    /// bitmap takes 1 s to catch up" snap the user reported.
    @State private var bioOpacity: Double = 1.0
    /// Track the last text we rendered so the .task(id:) closure
    /// can know whether to play the cross-fade or just do a fresh
    /// render (no fade on first appear with empty prior state).
    @State private var lastRenderedText: String = ""
    /// Monotonically incrementing version stamp bumped on every
    /// successful renderBio call. Passed into `BioCanvasContent`
    /// alongside the bitmap so SwiftUI's struct-property diff sees
    /// an Int change (which it tracks reliably) and forces the
    /// sub-view to re-evaluate. CGImage is a CoreFoundation type
    /// without Hashable/Equatable conformance, and SwiftUI's
    /// invalidation can treat a new CGImage with the same identity
    /// as "no change" — which left the Canvas drawing the previous
    /// track's bitmap.
    @State private var bitmapVersion: Int = 0

    var body: some View {
        GeometryReader { geo in
            let viewport = geo.size.height
            let width = geo.size.width
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let elapsed = max(0, t - startTime)
                let yOffset = computeOffset(elapsed: elapsed, viewport: viewport)
                // Wrap the Canvas in a separate value-type sub-view
                // that takes `cg`, `textHeight`, `opacity`, `scale`
                // as `let` constructor parameters. SwiftUI compares
                // struct properties for invalidation — so when
                // bioCGImage changes, the parent body re-evaluates,
                // a new sub-view struct is built with the new cg
                // pointer, and the inner Canvas closure is forced
                // to re-evaluate with the new bitmap. Captured-
                // locals-inside-Canvas-closure didn't reliably
                // propagate the @State change in some SwiftUI
                // builds — explicit struct identity does.
                BioCanvasContent(
                    cg: bioCGImage,
                    bitmapVersion: bitmapVersion,
                    textHeight: textHeight,
                    opacity: bioOpacity,
                    scale: renderScale,
                    yOffset: yOffset,
                    width: width,
                    viewport: viewport
                )
                .frame(width: width, height: viewport)
                .transaction { $0.animation = nil }
            }
            // `.task(id:)` is more reliable than `.onChange(of:)`
            // when the parent view's identity churns on parent
            // re-evaluations — SwiftUI re-runs the closure on every
            // id change, including the implicit initial-fire.
            // `.onChange` was missing some text changes after the
            // Equatable shortcut started skipping body re-evals on
            // unrelated state changes.
            .task(id: text) {
                // Synchronous render — no `await Task.sleep` or
                // `withAnimation` between the @State writes. The
                // earlier fade choreography (await + withAnimation
                // bracketing the bioCGImage write) caused SwiftUI
                // to skip propagating the new `cg` parameter into
                // the inner `BioCanvasContent` sub-view, so the
                // Canvas kept drawing the previous bitmap. Cross-
                // fade dropped — correctness over polish.
                startTime = Date().timeIntervalSinceReferenceDate
                renderBioIfNeeded(width: width, force: true)
                bioOpacity = 1.0
                lastRenderedText = text
            }
            .task(id: width) {
                renderBioIfNeeded(width: width, force: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Renders the bio Text into a `CGImage` via `ImageRenderer` at
    /// the current display backing scale. Cached in `bioCGImage`
    /// and only rebuilt when the text or available width changes.
    @MainActor
    private func renderBioIfNeeded(width: CGFloat, force: Bool = false) {
        guard width > 0 else { return }
        if !force, bioCGImage != nil, renderedWidth == width { return }

        let content = Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.white.opacity(0.85))
            .lineSpacing(3)
            .frame(width: width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)

        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        renderer.isOpaque = false

        if let cg = renderer.cgImage {
            bioCGImage = cg
            renderScale = scale
            textHeight = CGFloat(cg.height) / scale
            renderedWidth = width
            startTime = Date().timeIntervalSinceReferenceDate
            bitmapVersion &+= 1
        }
    }

    /// Returns the y-offset to apply to the text view inside the
    /// viewport. Cycle:
    ///   1. Text begins below the viewport (offset = viewport).
    ///   2. Scrolls upward at `scrollSpeed` pt/s until it has fully
    ///      cleared the top (offset = -textHeight).
    ///   3. Holds at the off-screen position for `endPause` seconds.
    ///   4. Loops back to step 1.
    /// While `textHeight` is still 0 (pre-measurement), the text is
    /// pinned at the bottom of the viewport so the user sees it
    /// poised to scroll, not flashed at the top.
    private func computeOffset(elapsed: Double, viewport: Double) -> Double {
        guard textHeight > 0, viewport > 0 else { return viewport }
        let scrollDistance = viewport + textHeight
        let scrollTime = scrollDistance / scrollSpeed
        let cycleTime = scrollTime + endPause
        let cyclePos = elapsed.truncatingRemainder(dividingBy: cycleTime)
        if cyclePos < scrollTime {
            return viewport - cyclePos * scrollSpeed
        } else {
            return -textHeight
        }
    }

}

// MARK: - Bio Canvas content (sub-view of ScrollingBioBody)
//
// Pulled out of `ScrollingBioBody.body` so the Canvas re-evaluates
// reliably when the bitmap changes. SwiftUI's body-skip optimisation
// can hold onto a stale Canvas closure when the only thing that
// changed is the parent's @State (bioCGImage). Wrapping the Canvas
// in a value-type sub-view with the bitmap as a `let` constructor
// parameter forces SwiftUI to invalidate the sub-view on every new
// CGImage — guaranteed propagation.
private struct BioCanvasContent: View {
    let cg: CGImage?
    /// Monotonic version stamp bumped each render. Forces SwiftUI's
    /// struct-property diff to see this view as "changed" whenever
    /// the parent re-renders the bitmap — CGImage alone wasn't
    /// reliable because it's a CoreFoundation type and SwiftUI's
    /// invalidation can skip it.
    let bitmapVersion: Int
    let textHeight: Double
    let opacity: Double
    let scale: CGFloat
    let yOffset: Double
    let width: CGFloat
    let viewport: CGFloat

    var body: some View {
        Canvas { ctx, size in
            guard let cg, textHeight > 0 else { return }
            ctx.opacity = opacity
            let drawRect = CGRect(
                x: 0,
                y: yOffset,
                width: size.width,
                height: textHeight
            )
            ctx.draw(Image(cg, scale: scale, label: Text("")), in: drawRect)
            let topFadeH = size.height * 0.10
            ctx.blendMode = .destinationOut
            ctx.fill(
                Path(CGRect(x: 0, y: 0,
                            width: size.width, height: topFadeH)),
                with: .linearGradient(
                    Gradient(colors: [.black, .clear]),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: 0, y: topFadeH)
                )
            )
            let botFadeH = size.height * 0.10
            ctx.fill(
                Path(CGRect(x: 0, y: size.height - botFadeH,
                            width: size.width, height: botFadeH)),
                with: .linearGradient(
                    Gradient(colors: [.clear, .black]),
                    startPoint: CGPoint(x: 0, y: size.height - botFadeH),
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )
        }
    }
}

// MARK: - Memorial overlay

private struct ClubVisMemorialOverlay: View {
    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 18) {
                Text(L10n.memorialOverlayTitle)
                    .font(.system(size: 36, weight: .light, design: .serif))
                    .foregroundStyle(.white.opacity(0.92))
                    .multilineTextAlignment(.center)
                Text(L10n.memorialOverlayIYKYK)
                    .font(.system(size: 26, weight: .light, design: .serif).italic())
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .frame(width: ClubVisWindow.logicalWidth,
               height: ClubVisWindow.logicalHeight)
    }
}

// MARK: - Logo

private struct ClubVisLogoView: View {
    var body: some View {
        Image("ChoragusTextLogo")
            .resizable()
            .scaledToFit()
            .opacity(0.55)
            .accessibilityLabel("Choragus")
    }
}

// MARK: - Debug companion window state

/// Snapshot state shared between `ClubVisWindow`/`ClubVisWallView`
/// and the Debug-only `BackOfTheClubDebugWindow`. Each rebuild and
/// each slot assignment writes into the singleton; the debug window
/// observes via `@StateObject`. Singleton because the lighting +
/// pool + slot data is owned across two SwiftUI views in the same
/// hierarchy and threading it through env objects would be churn
/// for a debug feature.
@MainActor
final class BackOfTheClubDebugState: ObservableObject {
    static let shared = BackOfTheClubDebugState()
    private init() {}

    struct QueueRow: Identifiable {
        let id = UUID()
        let position: Int
        let title: String
        let artist: String
        let album: String
        let genre: String
    }
    struct PoolRow: Identifiable {
        let id = UUID()
        let tier: String  // "preferred" | "fallback"
        let url: String
        let title: String
        let artist: String
        let album: String
        let genre: String
    }
    struct SlotRow: Identifiable {
        let id = UUID()
        let slotIdx: Int
        let sizeClass: Int
        let url: String
        let title: String
        let artist: String
        let album: String
    }

    @Published var queueRows: [QueueRow] = []
    @Published var poolRows: [PoolRow] = []
    @Published var slotRows: [SlotRow] = []
    @Published var nowPlayingArtist: String = ""
    @Published var nowPlayingTitle: String = ""
    @Published var nowPlayingGenre: String = ""
    @Published var isQueueMode: Bool = false
    @Published var matchMode: String = "partial"
    @Published var sprinklePercent: Double = 5
    @Published var similarArtists: [String] = []
    @Published var queueGenreTokens: [String] = []
    /// Full artist bio currently displayed (or available for display)
    /// in the Back of the Club About panel. Surfaced so we can
    /// compare against what the Now Playing About tab shows and
    /// confirm both views are reading the same cached string.
    @Published var nowPlayingBio: String = ""
    /// Live-tunable lighting parameters — `ClubVisLightingView` reads
    /// from here every body eval, so adjusting any control in the
    /// debug window applies immediately without rebuild.
    @Published var lighting: LightingControls = LightingControls()

    /// Live-tunable packer config — `WallSlotPacker.pack` reads from
    /// here when called from `ClubVisWindow.slots`. Debug UI lets us
    /// iterate on counts and rule caps without recompiles.
    @Published var packerCount4x4: Int = 2
    @Published var packerCount3x3: Int = 4
    @Published var packerCount2x2: Int = 8
    /// Cap on adjacent (edge or corner) > 1×1 tiles per > 1×1 tile.
    @Published var packerMaxLargeNeighbours: Int = 2
    /// Cap on connected-component size for > 1×1 tiles.
    @Published var packerMaxLargeComponent: Int = 3
    /// Bumped by the "Rebuild wall" debug button. ClubVisWindow
    /// observes via `.onChange` and calls `forceWallRebuild()`.
    @Published var rebuildTrigger: Int = 0

    /// Wall canvas frame rate, sampled in 1-second windows.
    /// Updated by `recordWallFrame()`, called from the WallView
    /// Canvas closure each redraw. Read by the debug window.
    @Published var wallFps: Double = 0
    private var wallFrameCount: Int = 0
    private var wallFrameSampleStart: Date = Date()

    /// Cheap per-frame call — increments a counter and republishes
    /// `wallFps` once per second. The 1 Hz cap avoids triggering
    /// observer-driven body re-evals on every draw.
    func recordWallFrame() {
        wallFrameCount += 1
        let elapsed = Date().timeIntervalSince(wallFrameSampleStart)
        if elapsed >= 1.0 {
            wallFps = Double(wallFrameCount) / elapsed
            wallFrameCount = 0
            wallFrameSampleStart = Date()
        }
    }

    // MARK: - Live-tunable swap-loop / fade timings
    //
    // Read by ClubVisWallView at the moment each fade is constructed
    // and by the swap loop at each tick. Changes apply to the next
    // fade / next tick — in-flight fades keep their original timings.

    /// True while a wall rebuild is in flight. Read by WallView's
    /// swap loop each tick to skip swaps during the cover
    /// transitions. NOT @Published — we don't want UI re-renders
    /// every time it flips, only the swap loop's per-tick read.
    /// The let-parameter rebuildInProgress on WallView is captured
    /// by the Task closure at start time and doesn't update; this
    /// singleton field gives the loop a live read instead.
    var isWallRebuilding: Bool = false

    /// Master gate for [VIS] log lines. Toggleable from the debug
    /// window so the verbose per-fade / per-rebuild logging can
    /// be silenced when not actively debugging the wall.
    @Published var visLoggingEnabled: Bool = true

    /// Number of small-tile swaps fired simultaneously per tick of
    /// the background swap loop.
    @Published var swapsPerTick: Int = 2
    /// Min/max ms between swap-loop ticks. Each tick samples a
    /// uniform random in [min, max] for that interval.
    @Published var swapIntervalMinMs: Int = 4000
    @Published var swapIntervalMaxMs: Int = 7000
    /// On track change, this many random 1×1 slots fade to fresh
    /// URLs from the new track's genreTier1.
    @Published var trackChangeSeedSwapCount: Int = 1
    /// 1×1 small-tile fade phase durations (sequential black-hold).
    /// Total small fade = out + hold + in.
    @Published var smallFadeOutMs: Int = 1500
    @Published var smallFadeHoldMs: Int = 200
    @Published var smallFadeInMs: Int = 1500
    /// Mid/large tile fade duration (smoothstep crossfade).
    @Published var largeFadeMs: Int = 5000
    /// Per-tick chance (0–100) that a swap-loop pick targets a 2×2
    /// instead of a 1×1. Smaller mid-tile rotations.
    @Published var swap2x2Percent: Int = 15
    /// Per-tick chance (0–100) that a swap-loop pick targets a 3×3.
    /// Rare on purpose — large tiles changing draw the eye.
    @Published var swap3x3Percent: Int = 5

    struct LightingControls {
        // Per-shape enable
        var ambientLEnabled: Bool = true
        var ambientREnabled: Bool = true
        var spotlightTLEnabled: Bool = true
        var spotlightBREnabled: Bool = true
        // Ambient L
        var ambientLAnchorX: Double = 0.30
        var ambientLAnchorY: Double = 0.50
        var ambientLPeriod: Double = 200
        var ambientLDriftX: Double = 0.10
        var ambientLDriftY: Double = 0.08
        var ambientLSize: Double = 1.40
        var ambientLBlur: Double = 180
        var ambientLOpacity: Double = 0.90
        var ambientLIntensity: Double = 1.0
        var ambientLBrightness: Double = 0.0
        var ambientLSaturation: Double = 1.0
        var ambientLBlend: BlendModeChoice = .normal
        // Ambient R
        var ambientRAnchorX: Double = 0.70
        var ambientRAnchorY: Double = 0.50
        var ambientRPeriod: Double = 240
        var ambientRDriftX: Double = 0.10
        var ambientRDriftY: Double = 0.08
        var ambientRSize: Double = 1.40
        var ambientRBlur: Double = 180
        var ambientROpacity: Double = 0.90
        var ambientRIntensity: Double = 1.0
        var ambientRBrightness: Double = 0.0
        var ambientRSaturation: Double = 1.0
        var ambientRBlend: BlendModeChoice = .normal
        // Spotlight TL
        var spotlightTLAnchorX: Double = 0.30
        var spotlightTLAnchorY: Double = 0.30
        var spotlightTLPeriod: Double = 130
        var spotlightTLDriftX: Double = 0.20
        var spotlightTLDriftY: Double = 0.15
        var spotlightTLWidth: Double = 0.40
        var spotlightTLHeight: Double = 0.30
        var spotlightTLRotation: Double = 25
        var spotlightTLBlur: Double = 60
        var spotlightTLOpacity: Double = 0.95
        var spotlightTLIntensity: Double = 1.0
        var spotlightTLBrightness: Double = 0.0
        var spotlightTLSaturation: Double = 1.0
        var spotlightTLBlend: BlendModeChoice = .normal
        // Spotlight BR
        var spotlightBRAnchorX: Double = 0.70
        var spotlightBRAnchorY: Double = 0.70
        var spotlightBRPeriod: Double = 165
        var spotlightBRDriftX: Double = 0.18
        var spotlightBRDriftY: Double = 0.14
        var spotlightBRWidth: Double = 0.45
        var spotlightBRHeight: Double = 0.32
        var spotlightBRRotation: Double = -35
        var spotlightBRBlur: Double = 60
        var spotlightBROpacity: Double = 0.95
        var spotlightBRIntensity: Double = 1.0
        var spotlightBRBrightness: Double = 0.0
        var spotlightBRSaturation: Double = 1.0
        var spotlightBRBlend: BlendModeChoice = .normal
        // (wall saturation is pinned at 0.10 — not exposed here.)
        // Global
        var blackMultiplyOpacity: Double = 0.45
        var ambientBlendMode: BlendModeChoice = .color
        var spotlightBlendMode: BlendModeChoice = .overlay
        // Cue
        var cuePeriod: Double = 120
        var cueFadeFraction: Double = 0.30
        /// -1 = auto cycle through cues (default behaviour);
        /// 0..6 = pin the active cue to a specific stage.
        var stageOverride: Int = -1

        enum BlendModeChoice: String, CaseIterable, Identifiable {
            case color, softLight, overlay, screen, multiply, plusLighter, normal, plusDarker, sourceAtop
            var id: String { rawValue }
            var blend: BlendMode {
                switch self {
                case .color: return .color
                case .softLight: return .softLight
                case .overlay: return .overlay
                case .screen: return .screen
                case .multiply: return .multiply
                case .plusLighter: return .plusLighter
                case .normal: return .normal
                case .plusDarker: return .plusDarker
                case .sourceAtop: return .sourceAtop
                }
            }
        }
    }
    /// URL → metadata snapshot used by the wall view to enrich
    /// slot rows. Updated alongside `poolRows` so the wall doesn't
    /// need access to `playHistoryManager.entries` directly.
    var entryByURL: [String: (title: String, artist: String, album: String)] = [:]
}

// MARK: - Debug companion window UI

struct BackOfTheClubDebugWindow: View {
    @StateObject private var state = BackOfTheClubDebugState.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                contextSection
                packerSection
                swapAndFadeSection
                lightingSection
                lightingControlsSection
                queueSection
                poolSection
                slotSection
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 760, minHeight: 600)
    }

    // MARK: - Swap loop & fade timings

    private var swapAndFadeSection: some View {
        GroupBox("Swap loop & fade timings (live)") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Wall canvas FPS").frame(width: 220, alignment: .leading)
                    Text(String(format: "%.1f fps", state.wallFps))
                        .monospacedDigit()
                        .foregroundStyle(state.wallFps < 20 ? .red : .secondary)
                    Spacer()
                }
                Toggle("[VIS] log lines (debug log file)",
                       isOn: $state.visLoggingEnabled)
                Divider()
                packerStepper("Simultaneous swaps per tick",
                              value: $state.swapsPerTick, range: 1...20)
                packerStepper("Swap interval min (ms)",
                              value: $state.swapIntervalMinMs, range: 100...10000, step: 100)
                packerStepper("Swap interval max (ms)",
                              value: $state.swapIntervalMaxMs, range: 100...15000, step: 100)
                Divider()
                packerStepper("2×2 swap chance (%)",
                              value: $state.swap2x2Percent, range: 0...100)
                packerStepper("3×3 swap chance (%)",
                              value: $state.swap3x3Percent, range: 0...100)
                Text("1×1 chance = 100 − 2×2% − 3×3% = \(max(0, 100 - state.swap2x2Percent - state.swap3x3Percent))%")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                packerStepper("Track-change small-tile swaps",
                              value: $state.trackChangeSeedSwapCount, range: 0...30)
                Divider()
                packerStepper("Small fade-out (ms)",
                              value: $state.smallFadeOutMs, range: 0...8000, step: 100)
                packerStepper("Small black hold (ms)",
                              value: $state.smallFadeHoldMs, range: 0...4000, step: 100)
                packerStepper("Small fade-in (ms)",
                              value: $state.smallFadeInMs, range: 0...8000, step: 100)
                let total = state.smallFadeOutMs + state.smallFadeHoldMs + state.smallFadeInMs
                Text("Small total: \(total) ms")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                packerStepper("Large/mid fade total (ms)",
                              value: $state.largeFadeMs, range: 200...30000, step: 200)
                Divider()
                Button("Reset to defaults") {
                    state.swapsPerTick = 2
                    state.swapIntervalMinMs = 4000
                    state.swapIntervalMaxMs = 7000
                    state.swap2x2Percent = 15
                    state.swap3x3Percent = 5
                    state.trackChangeSeedSwapCount = 1
                    state.smallFadeOutMs = 1500
                    state.smallFadeHoldMs = 200
                    state.smallFadeInMs = 1500
                    state.largeFadeMs = 5000
                }
                Text("Timing changes apply to the next swap; in-flight fades keep their original timing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Packer controls

    private var packerSection: some View {
        GroupBox("Wall packer (live)") {
            VStack(alignment: .leading, spacing: 10) {
                packerStepper("# of 4×4", value: $state.packerCount4x4, range: 0...10)
                packerStepper("# of 3×3", value: $state.packerCount3x3, range: 0...40)
                packerStepper("# of 2×2", value: $state.packerCount2x2, range: 0...60)
                Divider()
                packerStepper("Max # large touching", value: $state.packerMaxLargeNeighbours, range: 0...8)
                packerStepper("Max contiguous line of large", value: $state.packerMaxLargeComponent, range: 1...20)
                Divider()
                HStack {
                    Button("Rebuild wall") {
                        state.rebuildTrigger &+= 1
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Reset to defaults") {
                        let d = WallSlotPacker.Config.default
                        state.packerCount4x4 = d.count4x4
                        state.packerCount3x3 = d.count3x3
                        state.packerCount2x2 = d.count2x2
                        state.packerMaxLargeNeighbours = d.maxLargeNeighbours
                        state.packerMaxLargeComponent = d.maxLargeComponent
                        state.rebuildTrigger &+= 1
                    }
                }
                Text("Rule changes take effect on next Rebuild wall press (or natural cadence rebuild).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    private func packerStepper(_ label: String, value: Binding<Int>,
                               range: ClosedRange<Int>, step: Int = 1) -> some View {
        HStack {
            Text(label).frame(width: 220, alignment: .leading)
            Stepper(value: value, in: range, step: step) {
                Text("\(value.wrappedValue)").monospacedDigit().frame(width: 56, alignment: .trailing)
            }
        }
    }

    private var contextSection: some View {
        GroupBox("Context") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Now playing: \(state.nowPlayingArtist) — \(state.nowPlayingTitle)")
                Text("Genre: \(state.nowPlayingGenre.isEmpty ? "—" : state.nowPlayingGenre)")
                Text("Mode: \(state.isQueueMode ? "queue" : "streaming/single track")")
                Text("Match mode: \(state.matchMode)   |   Sprinkle %: \(Int(state.sprinklePercent))")
                Text("Queue genre tokens: \(state.queueGenreTokens.isEmpty ? "—" : state.queueGenreTokens.joined(separator: ", "))")
                Text("Similar artists (\(state.similarArtists.count)): \(state.similarArtists.prefix(8).joined(separator: ", "))")
                    .lineLimit(3)
                Divider()
                Text("Bio length: \(state.nowPlayingBio.count) chars")
                ScrollView {
                    Text(state.nowPlayingBio.isEmpty ? "—" : state.nowPlayingBio)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 200)
                .background(Color.gray.opacity(0.08))
            }
            .font(.system(.body, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var lightingSection: some View {
        GroupBox("Active stage cue (live, 1 fps sample)") {
            TimelineView(.periodic(from: .now, by: 1.0)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let cue = ClubVisLightingView.activeCue(at: t)
                HStack(spacing: 14) {
                    cueSwatch(label: "primary", color: cue.primary)
                    cueSwatch(label: "secondary", color: cue.secondary)
                    cueSwatch(label: "tertiary", color: cue.tertiary)
                    Spacer()
                }
            }
        }
    }

    private func cueSwatch(label: String, color: ClubVisLightingView.RGB) -> some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(red: color.r, green: color.g, blue: color.b))
                .frame(width: 96, height: 48)
            Text(label).font(.caption2)
            Text(String(format: "RGB %.2f %.2f %.2f", color.r, color.g, color.b))
                .font(.system(.caption2, design: .monospaced))
        }
    }

    private var queueSection: some View {
        GroupBox("Queue tracks (\(state.queueRows.count))") {
            if state.queueRows.isEmpty {
                Text("— empty —").font(.caption).foregroundStyle(.secondary)
            } else {
                Table(state.queueRows) {
                    TableColumn("#") { Text("\($0.position)").monospacedDigit() }
                        .width(min: 28, ideal: 28, max: 36)
                    TableColumn("Artist", value: \.artist).width(min: 120, ideal: 160)
                    TableColumn("Album", value: \.album).width(min: 120, ideal: 160)
                    TableColumn("Title", value: \.title).width(min: 160, ideal: 220)
                    TableColumn("Genre", value: \.genre).width(min: 120, ideal: 180)
                }
                .frame(minHeight: 120, idealHeight: 180, maxHeight: 240)
            }
        }
    }

    private var poolSection: some View {
        GroupBox("Pool (\(state.poolRows.count) — preferred + fallback)") {
            if state.poolRows.isEmpty {
                Text("— empty —").font(.caption).foregroundStyle(.secondary)
            } else {
                Table(state.poolRows) {
                    TableColumn("Tier", value: \.tier).width(min: 60, ideal: 70, max: 90)
                    TableColumn("Artist", value: \.artist).width(min: 120, ideal: 160)
                    TableColumn("Album", value: \.album).width(min: 120, ideal: 160)
                    TableColumn("Genre", value: \.genre).width(min: 100, ideal: 150)
                    TableColumn("URL", value: \.url).width(min: 150, ideal: 220)
                }
                .frame(minHeight: 200, idealHeight: 260, maxHeight: 320)
            }
        }
    }

    // MARK: - Lighting controls

    private var lightingControlsSection: some View {
        GroupBox("Lighting controls (live)") {
            VStack(alignment: .leading, spacing: 8) {
                globalLightingControls
                Divider()
                ambientLControls
                Divider()
                ambientRControls
                Divider()
                spotlightTLControls
                Divider()
                spotlightBRControls
                Divider()
                Button("Reset all to defaults") {
                    state.lighting = BackOfTheClubDebugState.LightingControls()
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var globalLightingControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Global").font(.caption.bold()).foregroundStyle(.secondary)
            slider("Black multiply", $state.lighting.blackMultiplyOpacity, range: 0...0.95, step: 0.01) { String(format: "%.2f", $0) }
            slider("Cue period (s)", $state.lighting.cuePeriod, range: 5...600, step: 1) { "\(Int($0))" }
            slider("Cue fade frac", $state.lighting.cueFadeFraction, range: 0.05...0.95, step: 0.01) { String(format: "%.2f", $0) }
            stagePicker
            HStack {
                Text("Ambient blend").frame(width: 110, alignment: .leading)
                Picker("", selection: $state.lighting.ambientBlendMode) {
                    ForEach(BackOfTheClubDebugState.LightingControls.BlendModeChoice.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 180)
            }
            HStack {
                Text("Spotlight blend").frame(width: 110, alignment: .leading)
                Picker("", selection: $state.lighting.spotlightBlendMode) {
                    ForEach(BackOfTheClubDebugState.LightingControls.BlendModeChoice.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 180)
            }
        }
    }

    /// Stage cue picker — "Auto cycle" plus one row per named cue.
    /// Each cue shows its primary/secondary/tertiary swatches inline
    /// for quick visual identification.
    private var stagePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Active stage").frame(width: 110, alignment: .leading).font(.caption)
                Picker("", selection: $state.lighting.stageOverride) {
                    Text("Auto cycle").tag(-1)
                    ForEach(Array(ClubVisLightingView.cues.enumerated()), id: \.offset) { idx, cue in
                        Text(cue.name).tag(idx)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
            }
            // Cue swatches grid for quick reference.
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(ClubVisLightingView.cues.enumerated()), id: \.offset) { idx, cue in
                    HStack(spacing: 6) {
                        Text("\(idx + 1).")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, alignment: .trailing)
                        Text(cue.name)
                            .font(.system(size: 10))
                            .frame(width: 90, alignment: .leading)
                        cueSwatch(cue.primary, size: 14)
                        cueSwatch(cue.secondary, size: 14)
                        cueSwatch(cue.tertiary, size: 14)
                        if state.lighting.stageOverride == idx {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.tint)
                        }
                        Spacer()
                    }
                }
            }
            .padding(.leading, 110)
        }
    }

    private func cueSwatch(_ rgb: ClubVisLightingView.RGB, size: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(ClubVisLightingView.swatchColor(rgb))
            .frame(width: size, height: size)
    }

    private var ambientLControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Ambient L (left circle, primary)", isOn: $state.lighting.ambientLEnabled).font(.caption.bold())
            slider("Anchor X", $state.lighting.ambientLAnchorX, range: 0...1, step: 0.01) { String(format: "%.2f", $0) }
            slider("Anchor Y", $state.lighting.ambientLAnchorY, range: 0...1, step: 0.01) { String(format: "%.2f", $0) }
            slider("Period (s)", $state.lighting.ambientLPeriod, range: 5...600, step: 1) { "\(Int($0))" }
            slider("Drift X", $state.lighting.ambientLDriftX, range: 0...0.5, step: 0.01) { String(format: "%.2f", $0) }
            slider("Drift Y", $state.lighting.ambientLDriftY, range: 0...0.5, step: 0.01) { String(format: "%.2f", $0) }
            slider("Size ×", $state.lighting.ambientLSize, range: 0.2...3.0, step: 0.05) { String(format: "%.2f", $0) }
            slider("Blur (pt)", $state.lighting.ambientLBlur, range: 0...300, step: 1) { "\(Int($0))" }
            slider("Centre α", $state.lighting.ambientLOpacity, range: 0...1, step: 0.01) { String(format: "%.2f", $0) }
            slider("Intensity ×", $state.lighting.ambientLIntensity, range: 0...2, step: 0.05) { String(format: "%.2f", $0) }
            slider("Brightness", $state.lighting.ambientLBrightness, range: -1...1, step: 0.05) { String(format: "%+.2f", $0) }
            slider("Saturation", $state.lighting.ambientLSaturation, range: 0...2, step: 0.05) { String(format: "%.2f", $0) }
            blendPicker("Element blend", $state.lighting.ambientLBlend)
        }
    }

    private var ambientRControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Ambient R (right circle, secondary)", isOn: $state.lighting.ambientREnabled).font(.caption.bold())
            slider("Anchor X", $state.lighting.ambientRAnchorX, range: 0...1, step: 0.01) { String(format: "%.2f", $0) }
            slider("Anchor Y", $state.lighting.ambientRAnchorY, range: 0...1, step: 0.01) { String(format: "%.2f", $0) }
            slider("Period (s)", $state.lighting.ambientRPeriod, range: 5...600, step: 1) { "\(Int($0))" }
            slider("Drift X", $state.lighting.ambientRDriftX, range: 0...0.5, step: 0.01) { String(format: "%.2f", $0) }
            slider("Drift Y", $state.lighting.ambientRDriftY, range: 0...0.5, step: 0.01) { String(format: "%.2f", $0) }
            slider("Size ×", $state.lighting.ambientRSize, range: 0.2...3.0, step: 0.05) { String(format: "%.2f", $0) }
            slider("Blur (pt)", $state.lighting.ambientRBlur, range: 0...300, step: 1) { "\(Int($0))" }
            slider("Centre α", $state.lighting.ambientROpacity, range: 0...1, step: 0.01) { String(format: "%.2f", $0) }
            slider("Intensity ×", $state.lighting.ambientRIntensity, range: 0...2, step: 0.05) { String(format: "%.2f", $0) }
            slider("Brightness", $state.lighting.ambientRBrightness, range: -1...1, step: 0.05) { String(format: "%+.2f", $0) }
            slider("Saturation", $state.lighting.ambientRSaturation, range: 0...2, step: 0.05) { String(format: "%.2f", $0) }
            blendPicker("Element blend", $state.lighting.ambientRBlend)
        }
    }

    private var spotlightTLControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Spotlight TL (top-left, tertiary)", isOn: $state.lighting.spotlightTLEnabled).font(.caption.bold())
            slider("Anchor X", $state.lighting.spotlightTLAnchorX, range: 0...1, step: 0.01) { String(format: "%.2f", $0) }
            slider("Anchor Y", $state.lighting.spotlightTLAnchorY, range: 0...1, step: 0.01) { String(format: "%.2f", $0) }
            slider("Period (s)", $state.lighting.spotlightTLPeriod, range: 5...600, step: 1) { "\(Int($0))" }
            slider("Drift X", $state.lighting.spotlightTLDriftX, range: 0...0.5, step: 0.01) { String(format: "%.2f", $0) }
            slider("Drift Y", $state.lighting.spotlightTLDriftY, range: 0...0.5, step: 0.01) { String(format: "%.2f", $0) }
            slider("Width frac", $state.lighting.spotlightTLWidth, range: 0.05...2.0, step: 0.01) { String(format: "%.2f", $0) }
            slider("Height frac", $state.lighting.spotlightTLHeight, range: 0.05...2.0, step: 0.01) { String(format: "%.2f", $0) }
            slider("Rotation°", $state.lighting.spotlightTLRotation, range: -90...90, step: 1) { "\(Int($0))°" }
            slider("Blur (pt)", $state.lighting.spotlightTLBlur, range: 0...200, step: 1) { "\(Int($0))" }
            slider("Centre α", $state.lighting.spotlightTLOpacity, range: 0...1, step: 0.01) { String(format: "%.2f", $0) }
            slider("Intensity ×", $state.lighting.spotlightTLIntensity, range: 0...2, step: 0.05) { String(format: "%.2f", $0) }
            slider("Brightness", $state.lighting.spotlightTLBrightness, range: -1...1, step: 0.05) { String(format: "%+.2f", $0) }
            slider("Saturation", $state.lighting.spotlightTLSaturation, range: 0...2, step: 0.05) { String(format: "%.2f", $0) }
            blendPicker("Element blend", $state.lighting.spotlightTLBlend)
        }
    }

    private var spotlightBRControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Spotlight BR (bottom-right, primary)", isOn: $state.lighting.spotlightBREnabled).font(.caption.bold())
            slider("Anchor X", $state.lighting.spotlightBRAnchorX, range: 0...1, step: 0.01) { String(format: "%.2f", $0) }
            slider("Anchor Y", $state.lighting.spotlightBRAnchorY, range: 0...1, step: 0.01) { String(format: "%.2f", $0) }
            slider("Period (s)", $state.lighting.spotlightBRPeriod, range: 5...600, step: 1) { "\(Int($0))" }
            slider("Drift X", $state.lighting.spotlightBRDriftX, range: 0...0.5, step: 0.01) { String(format: "%.2f", $0) }
            slider("Drift Y", $state.lighting.spotlightBRDriftY, range: 0...0.5, step: 0.01) { String(format: "%.2f", $0) }
            slider("Width frac", $state.lighting.spotlightBRWidth, range: 0.05...2.0, step: 0.01) { String(format: "%.2f", $0) }
            slider("Height frac", $state.lighting.spotlightBRHeight, range: 0.05...2.0, step: 0.01) { String(format: "%.2f", $0) }
            slider("Rotation°", $state.lighting.spotlightBRRotation, range: -90...90, step: 1) { "\(Int($0))°" }
            slider("Blur (pt)", $state.lighting.spotlightBRBlur, range: 0...200, step: 1) { "\(Int($0))" }
            slider("Centre α", $state.lighting.spotlightBROpacity, range: 0...1, step: 0.01) { String(format: "%.2f", $0) }
            slider("Intensity ×", $state.lighting.spotlightBRIntensity, range: 0...2, step: 0.05) { String(format: "%.2f", $0) }
            slider("Brightness", $state.lighting.spotlightBRBrightness, range: -1...1, step: 0.05) { String(format: "%+.2f", $0) }
            slider("Saturation", $state.lighting.spotlightBRSaturation, range: 0...2, step: 0.05) { String(format: "%.2f", $0) }
            blendPicker("Element blend", $state.lighting.spotlightBRBlend)
        }
    }

    private func blendPicker(_ label: String,
                             _ binding: Binding<BackOfTheClubDebugState.LightingControls.BlendModeChoice>) -> some View {
        HStack {
            Text(label).frame(width: 100, alignment: .leading).font(.caption)
            Picker("", selection: binding) {
                ForEach(BackOfTheClubDebugState.LightingControls.BlendModeChoice.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 180)
        }
    }

    private func slider(_ label: String, _ binding: Binding<Double>,
                        range: ClosedRange<Double>, step: Double,
                        format: @escaping (Double) -> String) -> some View {
        HStack {
            Text(label).frame(width: 100, alignment: .leading).font(.caption)
            Slider(value: binding, in: range, step: step)
            Text(format(binding.wrappedValue))
                .frame(width: 60, alignment: .trailing)
                .font(.system(.caption, design: .monospaced))
        }
    }

    private var slotSection: some View {
        GroupBox("Slots (\(state.slotRows.count) — current wall assignments)") {
            if state.slotRows.isEmpty {
                Text("— empty —").font(.caption).foregroundStyle(.secondary)
            } else {
                Table(state.slotRows) {
                    TableColumn("#") { Text("\($0.slotIdx)").monospacedDigit() }
                        .width(min: 36, ideal: 40, max: 50)
                    TableColumn("Size") { Text("\($0.sizeClass)×\($0.sizeClass)").monospacedDigit() }
                        .width(min: 50, ideal: 60, max: 70)
                    TableColumn("Artist", value: \.artist).width(min: 120, ideal: 160)
                    TableColumn("Album", value: \.album).width(min: 120, ideal: 160)
                    TableColumn("URL", value: \.url).width(min: 150, ideal: 220)
                }
                .frame(minHeight: 240, idealHeight: 320, maxHeight: 480)
            }
        }
    }
}
