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
/// Lighting: the now-playing artwork's detected hues (SonosKit's
/// `StageSetMatcher` histogram + peaks, once per art change)
/// generate a "Cover shades" stage set — shade ladders of those
/// hues only, via `ClubStageSets.coverShadesSet` — so the lighting
/// encodes album hue without adding hues the cover lacks. Tone
/// changes crossfade over `ClubVisLightingView.setFadeDuration` —
/// never a hard cut. Achromatic art / no art / the debug-window
/// toggle resolve to catalogue set #0 ("Zune house").
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
    @EnvironmentObject var anchorTracker: AnchorTracker
    @EnvironmentObject var playHistoryManager: PlayHistoryManager
    @EnvironmentObject var metadataServicesHolder: MusicMetadataServiceHolder
    @EnvironmentObject var artCoordinator: ArtCoordinator
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
    /// Live set of URLs the wall is currently drawing (slot
    /// assignments + both ends of in-flight fades), reported UP by
    /// the wall view. The `preloaded` trim must never evict a
    /// displayed image — the canvas draws from `preloaded`, so an
    /// evicted-while-displayed URL blanks its tile and the next
    /// diffFill mass-repairs (observed: 39 fades in one diff, wall
    /// fps collapsed to ~7).
    @State private var wallDisplayBox = WallDisplayBox()
    /// Staged reveal: the lighting layer fades in AFTER the wall is
    /// up — room first, then the rig comes on. 0 while hidden/behind
    /// a reveal; ramped by the initial-open and rebuild pipelines.
    @State private var lightingOpacity: Double = 0
    /// Live key index of `preloaded` for the wall view's task-context
    /// cache gates (see PreloadedIndex).
    @State private var preloadedIndex = PreloadedIndex()
    /// Live pool reference for the wall view's task contexts (see
    /// TilePoolBox).
    @State private var poolBox = TilePoolBox()
    /// Periodic off-main sample of ImageCache URLs for the
    /// cache-backfill tier. Sampling live inside the pool compute
    /// held the ImageCache disk queue for over a second per rebuild;
    /// a queued barrier write then parked every main-side art read
    /// behind it (observed: 1.0 s stall + tile fades running 680 ms
    /// long during the second rebuild of a track change).
    @State private var cacheBackfillSample: [URL] = []
    /// Consecutive fetch/decode failures per art URL this session.
    /// URLs at the cap are skipped by `downloadMissingPoolArt` —
    /// observed: the same ~10 dead URLs (unreachable speaker's getaa,
    /// zero-byte CDN jpegs) re-fetched on every rebuild, forever.
    @State private var artFetchFailures: [URL: Int] = [:]
    private static let artFetchFailureCap = 3
    /// URL sets of the current and previous pools — the retention
    /// set for trimming `preloaded` (a mid-fade slot may still draw
    /// a previous pool's image; anything older is unreachable).
    @State private var recentPoolURLSets: [Set<URL>] = []

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
    /// Last artwork URL a stage-set match ran for — gates
    /// `matchStageSet` to one match per art change.
    @State private var lastMatchedArtURL: URL?
    /// Latest hero art requested for a stage match — the settle
    /// debounce in `matchStageSet` matches only when a request is
    /// still the newest 1.5 s later.
    @State private var pendingStageMatchURL: URL?
    /// Delayed no-art fallback — see `downloadNowPlayingArt`.
    @State private var noArtFallbackTask: Task<Void, Never>?

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
    /// Fire time of the pending debounced rebuild — earliest wins.
    @State private var rebuildTilesDeadline: Date?
    /// When the last rebuildTiles actually ran — scheduler enforces
    /// a 3 s spacing floor from this.
    @State private var lastRebuildTilesAt: Date = .distantPast

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
        // Publish the wall seed for the lighting layer. Every wall
        // start funnels through recomputeSlots (.onAppear, .onChange
        // of layoutSeed, forceWallRebuild's synchronous call), so
        // this is the single point where the lights learn a new wall
        // is on screen. `ClubVisLightingView` derives per-emitter
        // anchor/phase variation from it — same seed, same lights.
        BackOfTheClubDebugState.shared.wallLightSeed = UInt64(layoutSeed)
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

    private var nowPlayingArtURL: URL? {
        // Use the same canonical accessor as Now Playing — it prefers the
        // resolved per-song cover (`radioTrackArtURL`) over the station logo
        // for radio. Reading raw `displayedArtURL` left the hero stuck on the
        // station art after the song's art resolved.
        artCoordinator.resolver(for: groupID).artURLForDisplay(trackMetadata: trackMetadata)
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
        // Direct-URL service tracks (Suno / TIDAL) carry a deterministic cover
        // keyed on the URI even when the speaker reports no artist. Settle on
        // the URI so the hero adopts that art instead of holding "unsettled"
        // forever (the artist gate below would otherwise never pass).
        if let uri = trackMetadata.trackURI,
           SunoCatalog.uuid(fromURI: uri) != nil || TidalCatalog.key(fromURI: uri) != nil {
            return "svc:\(uri)"
        }
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

    /// Format line for the now-playing card — the same evidence the
    /// main window's pills show: Atmos (capability-gated like the
    /// main badge), the TV input format for HDMI sources, or the
    /// stream details (container / lossless / bit depth-sample rate).
    private var formatDetailsLabel: String? {
        var parts: [String] = []
        if trackMetadata.audioFormat == .atmos,
           let g = group, g.isAtmosCapable(devices: sonosManager.devices) {
            parts.append(L10n.audioFormatAtmos)
        }
        if let uri = trackMetadata.trackURI,
           uri.contains("x-sonos-htastream:") || uri.contains("x-rincon-stream:") {
            if let tv = trackMetadata.tvAudioFormat.displayLabel {
                parts.append(tv)
            }
        } else if let details = trackMetadata.streamDetailsLabel {
            parts.append(details)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
            if settledTrackKey != "unsettled" {
                settledArtURL = nowPlayingArtURL
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
            scheduleRebuildTiles("initialLoad")
        }
        .task {
            // Cache-backfill sampler: refresh the URL sample off-main
            // once a minute (and once immediately) so pool builds
            // never enumerate the disk cache themselves.
            while !Task.isCancelled {
                let sample = await Task.detached(priority: .utility) {
                    ImageCache.shared.sampledCachedURLs(count: 1200)
                }.value
                cacheBackfillSample = sample
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
        .task(id: "\(trackMetadata.trackURI ?? "")|\(trackMetadata.artist)") {
            // Keyed on (trackURI, artist) — not URI alone — because
            // service streams (Apple Music HLS-static, Spotify, etc.)
            // land the URI first and the DIDL with artist arrives a
            // few hundred ms later. If we only watched the URI, an
            // empty-artist first event would take the SKIP branch
            // below and the About panel would never populate until
            // the next track. Composite key re-fires when the artist
            // settles, restoring the fetch.
            queueHolder.vm?.updateCurrentTrack()
            // Wall-rebuild rule — decided FIRST, before the artist
            // fetch and rebuildTiles, so a scheduled rebuild starts
            // its fade-out immediately at the track change instead
            // of seconds into the song. The rebuild sequence runs
            // detached; pool construction proceeds in parallel and
            // lands during the fade-out window.
            // Two trigger paths:
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
            let sunoUUID = trackMetadata.trackURI.flatMap { SunoCatalog.uuid(fromURI: $0) }
            let artist = trackMetadata.artist
            if let uuid = sunoUUID {
                // Suno tracks: creator profile (avatar/bio/style tags) instead
                // of the Last.fm lookup, which has no AI creators.
                let guardURI = trackMetadata.trackURI
                visLog("about — Suno creator profile fetch START")
                Task { @MainActor in
                    let info = await SunoResolver.artistProfile(forUUID: uuid)
                    guard trackMetadata.trackURI == guardURI else { return }
                    nowPlayingArtistInfo = info
                    nowPlayingSimilarArtists = []
                }
            } else if !artist.isEmpty {
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
            scheduleRebuildTiles("trackChange")
            trackChangeSwapTrigger &+= 1

        }
        .onChange(of: playHistoryManager.entries.count) {
            scheduleRebuildTiles("entries.count")
        }
        .onChange(of: playHistoryManager.genreVersion) {
            // Genre-tier placement is cosmetic; the backfill bumps
            // this once per artist it writes. Long delay collapses a
            // whole pass into one rebuild (see scheduleRebuildTiles).
            scheduleRebuildTiles("genreVersion", delay: .seconds(20))
        }
        .onChange(of: nowPlayingSimilarArtists) {
            scheduleRebuildTiles("similarArtists")
        }
        .onChange(of: settledTrackKey) { _, newKey in
            // "unsettled" holds the previous art across ad-break / blip.
            guard newKey != "unsettled" else { return }
            settledArtURL = nowPlayingArtURL
        }
        .onChange(of: nowPlayingArtURL) { _, newArt in
            // Catches async iTunes-resolve landing after the initial
            // DIDL render.
            guard settledTrackKey != "unsettled" else { return }
            settledArtURL = newArt
        }
        .onChange(of: settledArtURL) { _, newArt in
            visLog("settledArtURL changed → \(newArt?.absoluteString.suffix(60).description ?? "nil")")
            // Coalesce rapid DIDL → history → iTunes flips to one task.
            settledArtTask?.cancel()
            settledArtTask = Task { @MainActor in
                await downloadNowPlayingArt()
                guard !Task.isCancelled else { return }
                heroUpdateTrigger &+= 1
                visLog("heroUpdateTrigger bumped to \(heroUpdateTrigger)")
            }
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
                scheduleRebuildTiles("queueOptimisticAppend")
            } else {
                visLog("queueChanged — full reload (queue + tiles diff, no wall rebuild)")
                Task { @MainActor in
                    await vm.loadQueue()
                    vm.updateCurrentTrack()
                    scheduleRebuildTiles("queueChanged")
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
                        coverOpacity: wallCoverOpacity,
                        displayBox: wallDisplayBox,
                        preloadedIndex: preloadedIndex,
                        poolBox: poolBox
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
                        // Wall is up — bring the lights on.
                        visLog("lighting fade-IN start (2.5s)")
                        withAnimation(.easeInOut(duration: 2.5)) {
                            lightingOpacity = 1.0
                        }
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

            // Darkening pass BELOW the lights — the wall is dimmed to
            // venue darkness first and light is added on top. With this
            // multiply above the lighting layer it multiplied the lit
            // result toward grey and no blob survived (verified via
            // screenshot pair 2026-08-07). Opacity via the debug
            // window's Lighting > Black multiply slider.
            Color.black
                .blendMode(.multiply)
                .opacity(debugState.lighting.blackMultiplyOpacity)
                .allowsHitTesting(false)

            // Lighting view applies its own per-layer blend modes
            // internally — one Canvas of drifting radial washes +
            // highlight blooms on `.plusLighter`, then its static
            // vignette on `.multiply`. Must stay ABOVE the darkening
            // pass so added light is not multiplied away.
            ClubVisLightingView()
                .opacity(lightingOpacity)

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
                formatDetails: formatDetailsLabel,
                positionAnchor: anchorTracker.groupPositionAnchors[groupID] ?? .zero
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
    /// `delay` coalesces bursts. The 250 ms default suits user-visible
    /// causes (track change, queue edit). Background metadata churn
    /// passes a long delay: the genre backfill bumps `genreVersion`
    /// once per ARTIST it writes, and a 100-artist pass at 250 ms
    /// produced a rebuild every ~3.5 s for minutes — each costing a
    /// >1 s main-thread stall (observed 2026-08-08: 221 rebuilds,
    /// caller=genreVersion, MAIN-STALL ~1.1 s each — the wall stutter
    /// and hitched fades).
    private func scheduleRebuildTiles(_ callerHint: String,
                                      delay: Duration = .milliseconds(250)) {
        // Earliest requested fire time wins: a slow (genre) request
        // must not push back a pending fast (track-change) rebuild,
        // and a fast request supersedes a pending slow one.
        var candidate = Date().addingTimeInterval(Double(delay.components.seconds)
            + Double(delay.components.attoseconds) / 1e18)
        // Spacing floor: chooseTiles costs >1 s on the main thread,
        // and launch fires half a dozen triggers back-to-back (body,
        // similarArtists, queue/hero art, entries.count — observed
        // 12 rebuilds in 25 s stacking into 3-5 s stalls). Rebuilds
        // run at most once per 3 s; a burst collapses into one.
        let floor = lastRebuildTilesAt.addingTimeInterval(3.0)
        if floor > candidate { candidate = floor }
        if rebuildTilesDebounceTask != nil,
           let pending = rebuildTilesDeadline, pending <= candidate {
            return
        }
        rebuildTilesDeadline = candidate
        rebuildTilesDebounceTask?.cancel()
        let wait = max(0, candidate.timeIntervalSinceNow)
        rebuildTilesDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            rebuildTilesDeadline = nil
            await rebuildTiles(callerHint: callerHint)
        }
    }

    private func rebuildTiles(callerHint: String = #function) async {
        lastRebuildTilesAt = Date()
        visLog("rebuildTiles ENTER — caller=\(callerHint) rebuilding=\(BackOfTheClubDebugState.shared.isWallRebuilding)")
        let inputStart = Date()
        let input = makeChooseTilesInput()
        let inputMs = Int(Date().timeIntervalSince(inputStart) * 1000)
        let computeStart = Date()
        let result = await Task.detached(priority: .userInitiated) {
            Self.computeTilePool(input)
        }.value
        if let fresh = result.freshAmbient {
            pinnedAmbientSample = fresh
            pinnedAmbientForWallId = wallId
        }
        let chosen = result.pool
        visLog("chooseTiles OFF-MAIN — ms=\(Int(Date().timeIntervalSince(computeStart)*1000)) inputMs=\(inputMs)")
        visLog("pool — preferred=\(chosen.preferred.count) photos=\(chosen.artistPhotos.count) t1=\(chosen.genreTier1.count) t2=\(chosen.genreTier2.count) t3=\(chosen.genreTier3.count) random=\(chosen.random.count) ambient=\(chosen.ambient.count) | isQueueMode=\(trackMetadata.isQueueSource) queueItems=\(queueHolder.vm?.queueItems.count ?? -1)")
        // `slots` is a computed property keyed on `packerSeed`, so it
        // refreshes automatically when the track changes — no need
        // to assign here.

        // Resolve pool images on a background queue. All tiers feed
        // the same image dict; size-aware assignment in the wall view
        // picks which URL each slot draws.
        let allURLs = chosen.preferred + chosen.similarArtists + chosen.artistPhotos + chosen.genreTier1 + chosen.genreTier2 + chosen.genreTier3 + chosen.random + chosen.ambient + chosen.cacheBackfill
        let resolvedNew: [URL: NSImage] = await Task.detached(priority: .userInitiated) {
            var dict: [URL: NSImage] = [:]
            for url in allURLs {
                if let img = ImageCache.shared.image(for: url) {
                    dict[url] = img
                }
            }
            return dict
        }.value

        let commitStart = Date()
        pool = chosen
        poolBox.pool = chosen
        // Merge new resolutions on top of the existing dict — never
        // evict URLs we may still be fading out of, otherwise a
        // mid-fade slot loses its `oldImg` and pops to blank.
        preloaded.merge(resolvedNew) { _, new in new }

        // Trim `preloaded` to the last two pools' URLs. The
        // merge-only policy grew it monotonically (observed: 17k
        // NSImages after a long session); a mid-fade slot can still
        // reference the PREVIOUS pool's image, anything older is
        // unreachable.
        let poolSet = Set(allURLs)
        recentPoolURLSets = [poolSet] + recentPoolURLSets.prefix(1)
        var retained = recentPoolURLSets.reduce(into: Set<URL>()) { $0.formUnion($1) }
        // Never evict what the wall is drawing right now.
        retained.formUnion(wallDisplayBox.urls)
        if preloaded.count > retained.count {
            let before = preloaded.count
            preloaded = preloaded.filter { retained.contains($0.key) }
            visLog("preloaded TRIM — \(before) → \(preloaded.count)")
        }
        preloadedIndex.keys = Set(preloaded.keys)
        visLog("rebuild main-side commit — ms=\(Int(Date().timeIntervalSince(commitStart) * 1000)) preloaded=\(preloaded.count)")

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
        // Disk read + decode off the main actor — only the @State
        // writes hop back.
        if let cached = await Task.detached(priority: .utility,
                                            operation: { ImageCache.shared.image(for: url) }).value {
            preloaded[url] = cached
            preloadedIndex.keys.insert(url)
            return true
        }
        let start = Date()
        do {
            let (data, _) = try await Self.artFetchSession.data(from: url)
            let netMs = Int(Date().timeIntervalSince(start) * 1000)
            // Decode + cache transcode off-main: NSImage(data:) plus
            // ImageCache.store's TIFF→JPEG encode cost tens of ms per
            // image ON MAIN — a post-rebuild warm burst of dozens
            // stacked into the observed periodic ~1.5 s stalls.
            let decoded = await Task.detached(priority: .utility,
                                              operation: { () -> NSImage? in
                guard let img = NSImage(data: data) else { return nil }
                ImageCache.shared.store(img, for: url)
                return img
            }).value
            guard let img = decoded else {
                visLog("art DECODE-FAIL — \(tag) bytes=\(data.count) netMs=\(netMs)")
                recordArtFailure(url)
                return false
            }
            preloaded[url] = img
            preloadedIndex.keys.insert(url)
            artFetchFailures[url] = nil
            if netMs > 500 {
                visLog("art SLOW — \(tag) netMs=\(netMs) bytes=\(data.count)")
            }
            return true
        } catch {
            let netMs = Int(Date().timeIntervalSince(start) * 1000)
            visLog("art FETCH-FAIL — \(tag) netMs=\(netMs) error=\(error.localizedDescription)")
            recordArtFailure(url)
            return false
        }
    }

    /// True when the URL has exhausted its fetch attempts this
    /// session — excluded from the pool so no slot sits blank
    /// waiting on art that will never arrive.
    private func isArtBenched(_ url: URL) -> Bool {
        artFetchFailures[url, default: 0] >= Self.artFetchFailureCap
    }

    /// Failure bookkeeping. Crossing the cap benches the URL: any
    /// stale cached image is purged (so it can't resurface with wrong
    /// content later) and a coalesced rebuild reassigns the slots
    /// that were holding the now-benched URL — previously they sat
    /// as blank tiles for the rest of the session.
    private func recordArtFailure(_ url: URL) {
        let count = artFetchFailures[url, default: 0] + 1
        artFetchFailures[url] = count
        guard count == Self.artFetchFailureCap else { return }
        visLog("art BENCHED — \(url.lastPathComponent.suffix(40)) after \(count) failures")
        ImageCache.shared.remove(for: url)
        // Guarded write: a benched URL whose fetch failed was never
        // IN `preloaded`, and a no-op @State dictionary write still
        // invalidates the wall canvas — a 14-URL bench burst produced
        // 14 back-to-back full redraws (observed 1.57 s stall).
        if preloaded[url] != nil {
            preloaded[url] = nil
        }
        preloadedIndex.keys.remove(url)
        // Rebuild only when the benched URL is actually on screen —
        // benching an off-screen candidate needs no reassignment.
        // (At launch a burst of dead URLs benched back-to-back and
        // each scheduled a rebuild: repeated >1 s chooseTiles stalls.)
        if wallDisplayBox.urls.contains(url) {
            scheduleRebuildTiles("artBenched", delay: .seconds(2))
        }
    }

    /// Concurrent background fetch (cap 6 in flight) of every URL
    /// not yet in `preloaded`. Wraps `fetchAndStore` with throttled
    /// concurrency for the bulk pool-warming case.
    @MainActor
    private func downloadMissingPoolArt(allURLs: [URL]) async {
        let unique = Array(Set(allURLs).filter { url in
            preloaded[url] == nil
                && artFetchFailures[url, default: 0] < Self.artFetchFailureCap
        })
        guard !unique.isEmpty else { return }
        visLog("downloadMissingPoolArt — \(unique.count) URLs to fetch")
        // Fetch + decode + cache-store run entirely off the main
        // actor, and the results commit to `preloaded` ONCE. The
        // previous per-image commits invalidated the wall canvas per
        // landed download — a warm burst re-rendered all ~200 tiles
        // dozens of times (observed as back-to-back ~1.4 s
        // MAIN-STALLs for the duration of the burst).
        let results = await Self.fetchArtBatch(urls: unique)
        var landed: [URL: NSImage] = [:]
        var failedURLs: [URL] = []
        for (url, image) in results {
            if let image { landed[url] = image } else { failedURLs.append(url) }
        }
        if !landed.isEmpty {
            preloaded.merge(landed) { _, new in new }
            preloadedIndex.keys.formUnion(landed.keys)
        }
        for url in failedURLs {
            recordArtFailure(url)
        }
        // Successes reset their failure counters.
        for url in landed.keys where artFetchFailures[url] != nil {
            artFetchFailures[url] = nil
        }
        visLog("downloadMissingPoolArt done — fetched=\(landed.count) failed=\(failedURLs.count) preloaded=\(preloaded.count)")
    }

    /// Off-main batch fetch: cap-6 concurrency, per-URL disk-cache
    /// check, network fetch, decode, and ImageCache store — no
    /// actor-isolated state touched.
    nonisolated private static func fetchArtBatch(urls: [URL]) async -> [(URL, NSImage?)] {
        await withTaskGroup(of: (URL, NSImage?).self) { group in
            var results: [(URL, NSImage?)] = []
            var iter = urls.makeIterator()
            func addNext() {
                guard let url = iter.next() else { return }
                group.addTask(priority: .utility) {
                    if let cached = ImageCache.shared.image(for: url) {
                        return (url, cached)
                    }
                    let start = Date()
                    do {
                        let (data, _) = try await Self.artFetchSession.data(from: url)
                        guard let img = NSImage(data: data) else {
                            sonosDebugLog("[VIS] art DECODE-FAIL — \(url.lastPathComponent.suffix(40)) bytes=\(data.count) netMs=\(Int(Date().timeIntervalSince(start) * 1000))")
                            return (url, nil)
                        }
                        ImageCache.shared.store(img, for: url)
                        return (url, img)
                    } catch {
                        sonosDebugLog("[VIS] art FETCH-FAIL — \(url.lastPathComponent.suffix(40)) netMs=\(Int(Date().timeIntervalSince(start) * 1000)) error=\(error.localizedDescription)")
                        return (url, nil)
                    }
                }
            }
            for _ in 0..<6 { addNext() }
            for await result in group {
                results.append(result)
                addNext()
            }
            return results
        }
    }

    /// Pre-fetches each queue item's `albumArtURI` so chooseTiles
    /// can include them in `preferred` on the next rebuild.
    @MainActor
    private func downloadQueueArtwork() async {
        guard let queueItems = queueHolder.vm?.queueItems, !queueItems.isEmpty else { return }
        let urls: [URL] = queueItems.compactMap {
            guard let raw = $0.albumArtURI, !raw.isEmpty else { return nil }
            return URL(string: raw)
        }.filter {
            preloaded[$0] == nil
                && artFetchFailures[$0, default: 0] < Self.artFetchFailureCap
        }
        guard !urls.isEmpty else { return }
        // Batch, off-main, ONE preloaded commit — the previous
        // sequential per-URL loop performed one @State write (and so
        // one wall-canvas invalidation) per queue item; a 222-item
        // queue of cache hits stalled main ~1.4 s behind the rebuild
        // cover.
        let results = await Self.fetchArtBatch(urls: urls)
        var landed: [URL: NSImage] = [:]
        var failedURLs: [URL] = []
        for (url, image) in results {
            if let image { landed[url] = image } else { failedURLs.append(url) }
        }
        if !landed.isEmpty {
            preloaded.merge(landed) { _, new in new }
            preloadedIndex.keys.formUnion(landed.keys)
        }
        for url in failedURLs { recordArtFailure(url) }
        visLog("downloadQueueArtwork — needed=\(urls.count) fetched=\(landed.count)")
        if !landed.isEmpty { scheduleRebuildTiles("downloadQueueArtwork") }
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
        guard let url = settledArtURL else {
            // Track transitions clear the art for a moment. Keep the
            // previous set through that window so the NEXT match
            // crossfades old set → new set directly — the immediate
            // fallback here made every song change detour through
            // amber (old → fallback → new, two fades). Only a
            // SUSTAINED no-art state (radio source, art genuinely
            // absent) resolves to the fallback.
            if lastMatchedArtURL != nil {
                lastMatchedArtURL = nil
                noArtFallbackTask?.cancel()
                noArtFallbackTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    guard !Task.isCancelled, settledArtURL == nil else { return }
                    BackOfTheClubDebugState.shared.setMatchedSet(ClubStageSets.fallbackIndex)
                }
            }
            return
        }
        noArtFallbackTask?.cancel()
        if preloaded[url] == nil {
            if await fetchAndStore(url) {
                visLog("downloadNowPlayingArt — cached hero art")
            }
        }
        // Disk fallback reads detached — a main-actor ImageCache read
        // here blocked ~1.2 s on the disk queue while the pool build's
        // detached enumeration + resolution reads held it.
        var heroImage = preloaded[url]
        if heroImage == nil {
            heroImage = await Task.detached(priority: .utility) {
                ImageCache.shared.image(for: url)
            }.value
        }
        if let image = heroImage {
            await matchStageSet(url: url, image: image)
        }
        scheduleRebuildTiles("downloadNowPlayingArt")
    }

    /// Derives the stage set from the hero art: chromatic covers
    /// yield a generated "Cover shades" set (tones use only the
    /// detected hues); achromatic art resolves to the catalogue
    /// fallback. Gated to one match per art URL; histogram + peak
    /// extraction are CPU-bound and run off-main.
    @MainActor
    private func matchStageSet(url: URL, image: NSImage) async {
        guard lastMatchedArtURL != url else { return }
        // Settle debounce. During a track transition the hero art
        // flip-flaps (new track's cover, then a stale flip-back,
        // then the settled cover — observed twice in one second),
        // and every flip re-lit the room: the lighting appeared to
        // jump between states. Match only the art that is still the
        // hero 1.5 s later; superseded requests drop out here.
        pendingStageMatchURL = url
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        guard pendingStageMatchURL == url else {
            visLog("stage-set match SUPERSEDED — art=\(url.lastPathComponent.suffix(40))")
            return
        }
        guard lastMatchedArtURL != url else { return }
        lastMatchedArtURL = url
        let result = await Task.detached(priority: .utility) {
            ClubStageSets.match(for: image)
        }.value
        // A newer art change may have superseded this match while it
        // ran — publish only when still current.
        guard lastMatchedArtURL == url else { return }
        // Between-songs dip: for a real scheme change outside a
        // rebuild, the rig fades to dark, the new scheme commits
        // while dark (crossfade snapped — nothing half-blended when
        // the lights return), then fades back up. Rebuilds keep
        // their own black-point path; same-tone matches skip the
        // theatre and stay lit.
        let state = BackOfTheClubDebugState.shared
        let dip = !state.isWallRebuilding
            && lightingOpacity > 0.5
            && state.tonesWouldChange(result.index, generated: result.generated)
        if dip {
            visLog("lighting DIP — out (1.2s)")
            withAnimation(.easeInOut(duration: 1.2)) { lightingOpacity = 0.0 }
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            guard lastMatchedArtURL == url else { return }
        }
        state.setMatchedSet(
            result.index,
            generated: result.generated,
            dominantHue: result.dominantHue,
            topHues: result.topHues,
            chromaticFraction: result.chromaticFraction,
            meanSaturation: result.meanChromaticSaturation,
            meanBrightness: result.meanChromaticBrightness)
        if dip {
            state.snapFadeToTarget()
            visLog("lighting DIP — up (2.0s)")
            withAnimation(.easeInOut(duration: 2.0)) { lightingOpacity = 1.0 }
        }
        let set = result.generated ?? ClubStageSets.sets[result.index]
        let toneHues = result.topHues
            .map { String(format: "%.0f", $0) }.joined(separator: ",")
        visLog("stage-set match — set=\(set.name) toneHues=[\(toneHues)]° chromatic=\(String(format: "%.3f", result.chromaticFraction)) art=\(url.lastPathComponent.suffix(40))")
    }

    #if DEBUG
    private func publishDebugState(pool: TilePool) {
        let debugStart = Date()
        defer {
            let ms = Int(Date().timeIntervalSince(debugStart) * 1000)
            if ms > 50 { visLog("publishDebugState — ms=\(ms)") }
        }
        let entries = playHistoryManager.entries
        var entryByURL: [String: (title: String, artist: String, album: String)] = [:]
        var entryByURLFull: [String: (title: String, artist: String, album: String, genre: String)] = [:]
        for entry in entries {
            // Index by the raw stored URI AND the recovered
            // Suno/TIDAL cover URL — the pool carries the recovered
            // form for direct-URL tracks (stripped DIDL), which
            // previously matched nothing here and rendered pool rows
            // with a URL but "—" for every metadata column.
            var keys: [String] = []
            if let raw = entry.albumArtURI, !raw.isEmpty { keys.append(raw) }
            if let source = entry.sourceURI {
                if let uuid = SunoCatalog.uuid(fromURI: source) {
                    keys.append(SunoCatalog.coverURL(forUUID: uuid))
                } else if let art = TidalCatalog.art(forURI: source) {
                    keys.append(art)
                }
            }
            for key in keys where entryByURL[key] == nil {
                entryByURL[key] = (entry.title, entry.artist, entry.album)
                entryByURLFull[key] = (entry.title, entry.artist, entry.album, entry.genre)
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
        appendRows(pool.artistPhotos, tier: "artistPhoto")
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
    /// Snapshot of everything `computeTilePool` needs — captured on
    /// the main actor, consumed off it. Pool computation walks the
    /// full ~10k-entry history several times (>1 s); running it
    /// detached keeps rebuilds off the render loop.
    private struct ChooseTilesInput {
        let entries: [PlayHistoryEntry]
        let historySource: VisHistorySource
        let memberRoomNames: Set<String>
        let queueItems: [QueueItem]
        let trackMetadata: TrackMetadata
        let matchMode: VisGenreMatchMode
        let benched: Set<URL>
        let artistInfo: ArtistInfo?
        let sprinklePercent: Double
        let settledArtURL: URL?
        let pinnedAmbientValid: Bool
        let pinnedAmbientSample: [URL]
        /// Periodic ImageCache URL sample (see cacheBackfillSample).
        let cacheBackfillSample: [URL]
        /// One-shot TIDAL blob→art snapshot — per-entry
        /// TidalCatalog.art(forURI:) calls copy the whole
        /// UserDefaults dict each time and contend the preferences
        /// lock main's @AppStorage reads take.
        let tidalArtByBlob: [String: String]
    }

    /// Builds the off-main input snapshot. Main-actor: reads @State
    /// and observed objects.
    private func makeChooseTilesInput() -> ChooseTilesInput {
        ChooseTilesInput(
            entries: playHistoryManager.entries,
            historySource: VisHistorySource.current,
            memberRoomNames: Set(
                (group?.members ?? [])
                    .map { $0.roomName }
                    .filter { !$0.isEmpty }
            ),
            queueItems: queueHolder.vm?.queueItems ?? [],
            trackMetadata: trackMetadata,
            matchMode: VisGenreMatchMode.current,
            benched: Set(artFetchFailures.filter { $0.value >= Self.artFetchFailureCap }.keys),
            artistInfo: nowPlayingArtistInfo,
            sprinklePercent: visRandomSprinklePercent,
            settledArtURL: settledArtURL,
            pinnedAmbientValid: pinnedAmbientForWallId == wallId,
            pinnedAmbientSample: pinnedAmbientSample,
            cacheBackfillSample: cacheBackfillSample,
            tidalArtByBlob: TidalCatalog.artByBlobSnapshot()
        )
    }

    /// Pure pool computation — no @State access; safe off-main.
    /// Returns the pool plus a fresh ambient sample when one was
    /// generated (caller commits it to the pinned @State on main).
    /// `nonisolated` is LOAD-BEARING: the View struct's MainActor
    /// inference otherwise isolates this static too, and the
    /// Task.detached wrapper hops straight back to the main actor —
    /// the "off-main" compute ran ON main (observed: 1.7-1.9 s
    /// MAIN-STALLs exactly spanning each chooseTiles OFF-MAIN log).
    nonisolated private static func computeTilePool(_ input: ChooseTilesInput) -> (pool: TilePool, freshAmbient: [URL]?) {
        let trackMetadata = input.trackMetadata
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
        let allEntries = input.entries
        let minGroupEntries = 200
        let entries: [PlayHistoryEntry] = {
            switch input.historySource {
            case .all: return allEntries
            case .group:
                let memberRoomNames = input.memberRoomNames
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
                    sonosDebugLog("[VIS] group filter rooms=\(memberRoomNames) yielded \(filtered.count) entries (< \(minGroupEntries)) — falling back to all (\(allEntries.count))")
                    return allEntries
                }
                return filtered
            }
        }()
        let queueItems = input.queueItems
        let isQueueMode = trackMetadata.isQueueSource
        let mode = input.matchMode

        func usableArt(_ raw: String?, sourceURI: String?) -> URL? {
            if let s = sourceURI, URIPrefix.isRadio(s) { return nil }
            // Direct-URL service tracks (Suno, TIDAL) play with stripped DIDL,
            // so the history entry's stored art is blank/`getaa`. Recover the
            // real cover from the same catalogs the queue / now-playing use:
            // Suno derives it from the clip UUID, TIDAL from the persisted
            // browse art keyed on the play URL.
            var effective = raw
            if let s = sourceURI {
                if let uuid = SunoCatalog.uuid(fromURI: s) {
                    effective = SunoCatalog.coverURL(forUUID: uuid)
                } else if let blob = TidalCatalog.key(fromURI: s),
                          let art = input.tidalArtByBlob[blob] {
                    effective = art
                }
            }
            guard let effective, !effective.isEmpty,
                  let url = URL(string: effective) else { return nil }
            // No cache gate — pool now includes any valid art URL,
            // and `downloadMissingPoolArt()` (post-rebuildTiles)
            // backfills `preloaded` for anything not yet cached.
            // Benched URLs (fetch attempts exhausted) are the one
            // exclusion — a slot assigned one renders blank forever.
            guard !input.benched.contains(url) else { return nil }
            return url
        }

        // Artist → genre lookup (keyed on artist; per-track granularity
        // would miss queue items whose specific track isn't in history).
        var genreByArtist: [String: String] = [:]
        for entry in entries where !entry.genre.isEmpty {
            let key = entry.artist.lowercased()
            if genreByArtist[key] == nil { genreByArtist[key] = entry.genre }
        }

        // Art URL per entry, computed ONCE. `usableArt` costs a URL
        // parse plus Suno/TIDAL catalog lookups per call; the tier /
        // sprinkle / ambient passes below previously re-ran it over
        // the full history each (4 × ~10k entries ≈ the >1 s
        // main-thread stall behind every wall rebuild).
        let entryArt: [(entry: PlayHistoryEntry, url: URL)] = entries.compactMap { entry in
            usableArt(entry.albumArtURI, sourceURI: entry.sourceURI).map { (entry, $0) }
        }

        // Artist → ordered, deduped art URLs from history.
        var artByArtist: [String: [URL]] = [:]
        for (entry, url) in entryArt {
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
            guard !input.benched.contains(url) else { return }
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
        if let s = input.settledArtURL { heroURL = s }
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
            // Start at the track AFTER the one now playing —
            // trackNumber is the 1-based queue position, so index
            // trackNumber is the next track. Queue art on the wall
            // then previews what is coming rather than replaying the
            // queue's first covers.
            let upcoming: [QueueItem]
            if queueItems.isEmpty {
                upcoming = queueItems
            } else {
                let start = min(max(trackMetadata.trackNumber, 0), queueItems.count - 1)
                upcoming = Array(queueItems[start...]) + Array(queueItems[..<start])
            }
            for item in upcoming {
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
                for url in arts where !input.benched.contains(url) {
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
        for (entry, url) in entryArt {
            guard !seen.contains(url) else { continue }
            guard let tier = bestTier(entry) else { continue }
            switch tier {
            case 0: addTo(&tier1, url)
            case 1: addTo(&tier2, url)
            case 2: addTo(&tier3, url)
            default: break
            }
        }

        // Artist About photos — same gallery source the About panel
        // renders (`ArtistInfo.imageURLs`: Wikipedia media list +
        // Last.fm primary; single `imageURL` fallback for cached
        // pre-gallery entries). Built AHEAD of the random sprinkle so
        // the sprinkle/ambient/backfill passes below skip these URLs
        // via `seen`. Capped at 5, deduped by underlying file identity
        // (Wikipedia serves one photo at several thumbnail sizes).
        // Consumed by 1×1 slots only — see `pickURL`.
        var artistPhotos: [URL] = []
        if let info = input.artistInfo {
            var photoCandidates: [String] = []
            if let list = info.imageURLs, !list.isEmpty {
                photoCandidates = list
            } else if let single = info.imageURL {
                photoCandidates = [single]
            }
            var photoIdentities = Set<String>()
            for raw in photoCandidates
            where photoIdentities.insert(MusicMetadataService.imageIdentityKey(raw)).inserted {
                guard let url = URL(string: raw) else { continue }
                addTo(&artistPhotos, url)
                if artistPhotos.count == 5 { break }
            }
        }

        // Random sprinkle: entries with no genre match. Sized as a
        // percentage of the total cell count.
        let totalSlots = ClubVisWallView.cols * ClubVisWallView.rows
        let sprinkleTarget = max(0, Int((Double(totalSlots) * input.sprinklePercent / 100.0).rounded()))
        if sprinkleTarget > 0 {
            var candidates: [URL] = []
            for (_, url) in entryArt where !seen.contains(url) {
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
        var freshAmbient: [URL]? = nil
        if input.pinnedAmbientValid, !input.pinnedAmbientSample.isEmpty {
            for url in input.pinnedAmbientSample where !input.benched.contains(url) {
                if seen.insert(url).inserted { ambient.append(url) }
            }
            sonosDebugLog("[VIS] ambient REUSED — pinned=\(input.pinnedAmbientSample.count) usable=\(ambient.count)")
        } else {
            var ambientCandidates: [URL] = []
            for (_, url) in entryArt where !seen.contains(url) {
                ambientCandidates.append(url)
            }
            for url in ambientCandidates.shuffled().prefix(800) {
                if seen.insert(url).inserted {
                    ambient.append(url)
                }
            }
            freshAmbient = ambient
            sonosDebugLog("[VIS] ambient FRESH — generated=\(ambient.count)")
        }

        // Cache-fallback tier — enumerate URLs in ImageCache that
        // aren't already represented elsewhere in the pool, sampled
        // evenly across cache age. Caps at 400 URLs so the pool
        // doesn't balloon. Excludes URLs already in `seen` (the
        // dedup set built up during the tier passes above).
        var cacheBackfill: [URL] = []
        let candidates = input.cacheBackfillSample
        for url in candidates {
            if seen.insert(url).inserted {
                cacheBackfill.append(url)
                if cacheBackfill.count >= 400 { break }
            }
        }

        return (TilePool(
            preferred: preferred,
            similarArtists: similarArtists,
            artistPhotos: artistPhotos,
            genreTier1: tier1,
            genreTier2: tier2,
            genreTier3: tier3,
            random: random,
            ambient: ambient,
            cacheBackfill: cacheBackfill,
            isQueueMode: isQueueMode
        ), freshAmbient)
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
        let packStart = Date()
        let newSlots = WallSlotPacker.pack(seed: newSeed,
                                            cols: ClubVisWallView.cols,
                                            rows: ClubVisWallView.rows,
                                            cellSize: ClubVisWallView.cellSize,
                                            originX: ClubVisWallView.originX,
                                            originY: ClubVisWallView.originY,
                                            config: config)
        let packMs = Int(Date().timeIntervalSince(packStart) * 1000)
        if packMs > 20 { visLog("rebuild step — seq=\(seqId) pack ms=\(packMs)") }

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
        // Black point — the cover is opaque. Commit the new lighting
        // now (deferred match + fade snap) so the wall fades back in
        // already lit by the new scheme; the tone crossfade path is
        // for track changes without a rebuild.
        BackOfTheClubDebugState.shared.commitLightingAtRebuildBlackPoint()
        // Staged reveal: the wall comes back unlit; the rig fades in
        // after the cover has fully lifted. Direct write — the cover
        // is opaque, nothing visible changes here.
        lightingOpacity = 0.0
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
        // Wall is up — bring the lights on.
        visLog("rebuild step — seq=\(seqId) lighting fade-IN start (2.5s)")
        withAnimation(.easeInOut(duration: 2.5)) { lightingOpacity = 1.0 }
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

/// Reference box the wall view writes its on-screen URL set into.
/// Plain class (not ObservableObject): the parent only READS it at
/// trim time — display updates must not re-render the parent.
final class WallDisplayBox {
    var urls: Set<URL> = []
}

/// Live index of `preloaded`'s keys, maintained by the parent. The
/// wall view's long-lived tasks (swap loop, fade commits) capture the
/// view STRUCT at task start, so its `let preloaded` snapshot goes
/// stale — cache-eligibility gates evaluated in those tasks must
/// read through this reference instead (a stale snapshot made every
/// swap candidate look uncached: zero swaps, static wall).
final class PreloadedIndex {
    var keys: Set<URL> = []
}

/// Live pool reference for the same reason as PreloadedIndex: the
/// swap loop's captured `let pool` is the launch-time (empty) pool,
/// so swap/seed/hero candidate selection starved. The rebuild storm
/// used to mask this by recreating the wall view (fresh capture)
/// every few minutes.
final class TilePoolBox {
    fileprivate var pool: TilePool = .empty
}

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
    /// Current artist's About-panel photo gallery (Wikipedia media
    /// list + Last.fm primary via `ArtistInfo.imageURLs`), capped at
    /// 5. Candidates for 1×1 slots ONLY — never offered to 2×2/3×3/
    /// 4×4 slots or the hero. Consumed ahead of the random-sprinkle
    /// tier at every 1×1 selection point.
    let artistPhotos: [URL]
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
        preferred: [], similarArtists: [], artistPhotos: [],
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
    /// Reported-up set of URLs currently on screen (slot assignments
    /// + both ends of in-flight fades). The parent's `preloaded`
    /// trim excludes these — evicting a displayed image blanks its
    /// tile (the canvas draws from `preloaded`) and triggers a
    /// mass-repair fade storm on the next diff.
    let displayBox: WallDisplayBox
    /// Live cache-key index — cache gates in long-lived tasks MUST
    /// read this, never the `preloaded` let (stale struct capture).
    let preloadedIndex: PreloadedIndex
    /// Live pool — task contexts MUST read this, never the `pool`
    /// let (stale struct capture; see TilePoolBox).
    let poolBox: TilePoolBox

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
    /// Slots holding the guaranteed artist About photos — selected by
    /// `selectPhotoSlots`, protected from the periodic 1×1 rotation.
    @State private var photoSlotIndices: [Int] = []
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
    /// Lazy `NSImage → CGImage` cache. Held as a `@State`-backed class
    /// so internal mutation (cache fills) doesn't republish through
    /// SwiftUI's value-equality observation. Every `Canvas` tick used
    /// to call `GraphicsContext.draw(Image(nsImage:), in:)` per visible
    /// tile, which routed through `NSImageContents.displayList →
    /// CGImageForProposedRect → bestRepresentationForRect → hints
    /// validation` for every tile every frame — ~5 s of `NSImage`
    /// resolution work on a 41 s sample (≈ 12 % of wall, the single
    /// hottest path in the visualisation). Pre-resolving once per URL
    /// and drawing via `Image(decorative: cgImage, …)` bypasses the
    /// `NSImage` path entirely.
    @State private var cgImageCache = CGImageCache()
    /// Bumped (coalesced) when an off-main tile-bitmap render lands —
    /// the static canvas keys a repaint off it.
    @State private var bitmapVersion = 0
    @State private var bitmapVersionBumpTask: Task<Void, Never>?

    /// Reference-typed cache so per-tick reads/fills mutate in-place
    /// without triggering SwiftUI re-renders (the `@State` only tracks
    /// the wrapping reference). Indexed by the tile-pool URL key.
    /// Pre-scaled, decoded tile bitmaps keyed by (pixel size, url).
    /// The draw pass previously decoded + scaled ~200 full-resolution
    /// covers per canvas invalidation (measured ~1.5 s on every hero
    /// swap). Now a miss kicks an off-main render and returns nil —
    /// the tile paints on the next invalidation once ready — and the
    /// canvas only ever blits display-sized decoded bitmaps.
    /// Thread-safe: draw reads on main, renders land detached.
    fileprivate final class CGImageCache {
        private let lock = NSLock()
        private var cache: [String: CGImage] = [:]
        private var rendering: Set<String> = []
        /// Called (main actor, coalesced by the owner) when a render
        /// lands so the static canvas re-evaluates.
        var onRenderLanded: (@MainActor () -> Void)?

        private func key(_ url: URL, _ px: Int) -> String { "\(px)|\(url.absoluteString)" }

        /// Ready bitmap or nil; nil kicks one background render per
        /// (url, px).
        func cgImage(for url: URL, nsImage: NSImage, px: Int) -> CGImage? {
            let k = key(url, px)
            lock.lock()
            if let hit = cache[k] { lock.unlock(); return hit }
            let inFlight = rendering.contains(k)
            if !inFlight { rendering.insert(k) }
            lock.unlock()
            if !inFlight {
                Task.detached(priority: .userInitiated) { [weak self] in
                    guard let self else { return }
                    let rendered = Self.renderBitmap(nsImage, px: px)
                    self.lock.lock()
                    if let rendered { self.cache[k] = rendered }
                    self.rendering.remove(k)
                    let callback = self.onRenderLanded
                    self.lock.unlock()
                    if rendered != nil, let callback {
                        await MainActor.run { callback() }
                    }
                }
            }
            return nil
        }

        /// Synchronous render for callers already off-main.
        nonisolated func warm(url: URL, nsImage: NSImage, px: Int) {
            let k = key(url, px)
            lock.lock()
            let exists = cache[k] != nil || rendering.contains(k)
            if !exists { rendering.insert(k) }
            lock.unlock()
            guard !exists else { return }
            let rendered = Self.renderBitmap(nsImage, px: px)
            lock.lock()
            if let rendered { cache[k] = rendered }
            rendering.remove(k)
            lock.unlock()
        }

        /// Aspect-preserving decode + downscale to `px` on the SHORT
        /// side (tiles are square, drawn aspect-fill).
        private static func renderBitmap(_ image: NSImage, px: Int) -> CGImage? {
            guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            let w = CGFloat(cg.width), h = CGFloat(cg.height)
            guard w > 0, h > 0 else { return nil }
            let scale = min(1, CGFloat(px) / min(w, h))
            let tw = max(1, Int((w * scale).rounded()))
            let th = max(1, Int((h * scale).rounded()))
            guard let ctx = CGContext(data: nil, width: tw, height: th,
                                      bitsPerComponent: 8, bytesPerRow: tw * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: tw, height: th))
            return ctx.makeImage()
        }

        /// Drops entries whose URLs left the live pool.
        func prune(keepingURLs keep: Set<URL>) {
            lock.lock()
            for k in cache.keys {
                let urlPart = String(k.drop(while: { $0 != "|" }).dropFirst())
                if let url = URL(string: urlPart), !keep.contains(url) {
                    cache.removeValue(forKey: k)
                }
            }
            lock.unlock()
        }
    }

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
                // Eased ramps on both segments — the previous linear
                // ramps had a visible kink at each end of the dip.
                if out > 0, elapsed <= out {
                    return (1.0 - FadeState.eased(elapsed / out), 0)
                }
                if elapsed <= out + hold {
                    return (0, 0)
                }
                let inElapsed = elapsed - out - hold
                return fadeIn > 0
                    ? (0, FadeState.eased(inElapsed / fadeIn))
                    : (0, 1)
            }
        }
    }

    private enum FadeStyle {
        case crossfade
        case blackHold(out: TimeInterval, hold: TimeInterval, fadeIn: TimeInterval)
    }

    var body: some View {
        // Two-layer composite. The STATIC canvas draws every settled
        // tile and re-renders only on a state change (no timeline);
        // the FADE overlay ticks at 24 fps and draws ONLY the slots
        // currently fading. The previous single canvas redrew all
        // 200+ tiles every tick whenever ANY fade ran — measured as
        // the jank on wall change / hero fade / photo placement
        // (scrolling text, on its own cheap timeline, stayed smooth,
        // which is what isolated the per-tick tile cost).
        ZStack {
            Canvas { ctx, _ in
                // Dependency anchor: bumped (coalesced) when an
                // off-main bitmap render lands, so newly ready tiles
                // paint on the next evaluation.
                _ = bitmapVersion
                for (i, slot) in slots.enumerated() where fades[i] == nil {
                    // 1 pt inset — the back wall packs posters tightly
                    // with hairline gaps. Larger insets (the previous
                    // 4 pt) read as a moodboard, not a back wall.
                    let rect = slot.rect.insetBy(dx: 1, dy: 1)
                    if let url = slotURLs[i],
                       let img = preloaded[url],
                       let cg = cgImageCache.cgImage(for: url, nsImage: img,
                                                     px: slot.sizeClass * 160) {
                        ctx.draw(Image(decorative: cg, scale: 1, orientation: .up), in: rect)
                    }
                }
            }
            .frame(width: ClubVisWindow.logicalWidth, height: ClubVisWindow.logicalHeight)

            if !fades.isEmpty {
                TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    Canvas { ctx, _ in
                        #if DEBUG
                        BackOfTheClubDebugState.shared.recordWallFrame()
                        #endif
                        for (i, fade) in fades {
                            guard slots.indices.contains(i) else { continue }
                            let rect = slots[i].rect.insetBy(dx: 1, dy: 1)
                            // Opaque black base: the static layer
                            // skips fading slots, and the blackHold
                            // dip must read black, not whatever sits
                            // behind the wall.
                            ctx.fill(Path(rect), with: .color(.black))
                            let frac = (t - fade.startTime) / fade.duration
                            let (oldOp, newOp) = fade.opacities(at: frac)
                            if oldOp > 0,
                               let oldURL = fade.oldURL,
                               let oldImg = preloaded[oldURL],
                               let oldCG = cgImageCache.cgImage(for: oldURL, nsImage: oldImg,
                                                                px: slots[i].sizeClass * 160) {
                                var oldCtx = ctx
                                oldCtx.opacity = oldOp
                                oldCtx.draw(Image(decorative: oldCG, scale: 1, orientation: .up), in: rect)
                            }
                            if newOp > 0,
                               let newURL = fade.newURL,
                               let newImg = preloaded[newURL],
                               let newCG = cgImageCache.cgImage(for: newURL, nsImage: newImg,
                                                                px: slots[i].sizeClass * 160) {
                                var newCtx = ctx
                                newCtx.opacity = newOp
                                newCtx.draw(Image(decorative: newCG, scale: 1, orientation: .up), in: rect)
                            }
                        }
                    }
                    .frame(width: ClubVisWindow.logicalWidth, height: ClubVisWindow.logicalHeight)
                }
            }
        }
        .clipped()
        .task {
            // Coalesced repaint poke: renders land in bursts (a
            // wholesale fill kicks ~200); one bump per 100 ms.
            cgImageCache.onRenderLanded = {
                if bitmapVersionBumpTask == nil {
                    bitmapVersionBumpTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        bitmapVersion &+= 1
                        bitmapVersionBumpTask = nil
                    }
                }
            }
            assignInitialSlots()
            startSwapLoop()
        }
        .onChange(of: preloaded.count) {
            // Evict CGImage cache entries whose source URL is no
            // longer in the live `preloaded` dict. Without this the
            // cache only grows across a session; with it cumulative
            // memory tracks the parent's tile-pool retention policy.
            cgImageCache.prune(keepingURLs: Set(preloaded.keys))
            // A hero swap deferred on missing art fires as soon as
            // the image lands, so the anchor crossfades properly
            // instead of popping.
            if let pending = pendingHeroURL, preloaded[pending] != nil,
               !rebuildInProgress {
                triggerNowPlayingHeroSwap()
            }
        }
        .onChange(of: pool) {
            // Skip when a rebuild is in flight — the cover fade
            // would otherwise reveal tile fades happening behind it.
            // Settle window covers post-rebuild churn the same way.
            if rebuildInProgress { return }
            // Guaranteed artist photos are exempt from the settle
            // window: at launch the wall fills from a photos-empty
            // pool and the gallery arrives seconds later, inside the
            // window — waiting for the next general diff left the
            // wall photo-less until the next track change.
            placeArtistPhotos()
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
                syncDisplayBox()
                visLog("wallView — rebuild=true, cleared \(n) in-flight fades")
            } else {
                visLog("wallView — rebuild=false, swap loop resumes")
                // Guaranteed artist photos: pool changes arriving
                // DURING the rebuild return early from the pool
                // handler, and the fresh wall may have filled before
                // the gallery-carrying pool landed — re-place now.
                placeArtistPhotos()
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
        defer { publishSlotDebug(); syncDisplayBox() }
        visLog("wholesaleFill ENTER — slots=\(slots.count) rebuilding=\(BackOfTheClubDebugState.shared.isWallRebuilding)")
        var preferredQ = pool.preferred
        var similarArtistsQ = pool.similarArtists
        var artistPhotosQ = pool.artistPhotos
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
            // Cache-only: an uncached hero is NOT pinned — the
            // anchor takes pool art and the pendingHeroURL machinery
            // crossfades the hero in once its image lands. There is
            // deliberately NO queue-item stand-in: pinning
            // preferred[0] (the queue's FIRST track) made the anchor
            // flash that cover before fading to the actual current
            // track on every fill (reported: Elvis Costello flash).
            if let heroURL = nowPlayingHeroURL, preloadedIndex.keys.contains(heroURL) {
                pinned[first4x4] = heroURL
                // De-dup: if the hero URL is in preferred, remove it
                // so a smaller slot doesn't pick it up too.
                if let idx = preferredQ.firstIndex(of: heroURL) {
                    preferredQ.remove(at: idx)
                }
            }
        }
        if pool.isQueueMode,
           let first3x3 = sortedIdx.first(where: { slots[$0].sizeClass == 3 }),
           let url = takeFront(&preferredQ) {
            pinned[first3x3] = url
        }

        // Artist About photos are guaranteed wall content, not an
        // optional tier: each photo is pinned to a scattered central
        // 1×1 slot before the general walk, and the queue is drained
        // so no chain ever places (or skips) them.
        photoSlotIndices = []
        artistPhotosQ.removeAll { !preloadedIndex.keys.contains($0) }
        if !artistPhotosQ.isEmpty {
            let photoSlots = selectPhotoSlots(count: artistPhotosQ.count,
                                              excluding: Set(pinned.keys))
            for (slotIdx, url) in zip(photoSlots, artistPhotosQ) {
                pinned[slotIdx] = url
            }
            photoSlotIndices = photoSlots
            visLog("wholesaleFill — pinned \(photoSlots.count)/\(artistPhotosQ.count) artist photos to central slots \(photoSlots)")
            artistPhotosQ.removeAll()
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
    ///
    /// Artist About photos are NOT part of these chains — they are
    /// guaranteed content, pinned to scattered central 1×1 slots by
    /// `wholesaleFill` / placed by `diffFill` before the chain walk.
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
        defer { publishSlotDebug(); syncDisplayBox() }
        let fadesAtEntry = fades.count
        visLog("diffFill ENTER — slots=\(slots.count) slotURLs=\(slotURLs.count) fades=\(fadesAtEntry) rebuilding=\(BackOfTheClubDebugState.shared.isWallRebuilding)")
        let allNew = Set(pool.preferred)
            .union(pool.similarArtists)
            .union(pool.artistPhotos)
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
        // would suddenly be "evicted" even though its image was
        // already cached in `preloaded`. Keeping cached-image URLs
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

        placeArtistPhotos()

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

    /// Pops the first CACHED URL — display is cache-only, so an
    /// uncached candidate is dropped from this walk (the background
    /// warmer is fetching it; it re-enters on a later fill/diff).
    private func takeFront(_ array: inout [URL]) -> URL? {
        while !array.isEmpty {
            let url = array.removeFirst()
            if preloadedIndex.keys.contains(url) { return url }
        }
        return nil
    }

    /// Guaranteed placement of the current artist's About photos onto
    /// the designated central 1×1 slots (photos keep pool order —
    /// primary photo first). Idempotent: photos already visible are
    /// left alone. Called from diffFill AND directly from the pool
    /// change handler outside the settle window, because the gallery
    /// typically arrives seconds after the wall fills.
    private func placeArtistPhotos() {
        guard !pool.artistPhotos.isEmpty, !slots.isEmpty else { return }
        let validRange = 0..<slots.count
        var currentlyShown = Set(slotURLs.values)
        for fade in fades.values {
            if let url = fade.newURL { currentlyShown.insert(url) }
        }
        let photosToPlace = pool.artistPhotos.filter { !currentlyShown.contains($0) }
        guard !photosToPlace.isEmpty else { return }
        if photoSlotIndices.count < pool.artistPhotos.count
            || photoSlotIndices.contains(where: { !validRange.contains($0) }) {
            photoSlotIndices = selectPhotoSlots(count: pool.artistPhotos.count,
                                                excluding: [])
        }
        let photoSet = Set(pool.artistPhotos)
        var free = photoSlotIndices.filter { idx in
            validRange.contains(idx) && fades[idx] == nil
                && !(slotURLs[idx].map { photoSet.contains($0) } ?? false)
        }
        let now = Date().timeIntervalSinceReferenceDate
        var placed = 0
        for url in photosToPlace {
            guard !free.isEmpty else { break }
            let slotIdx = free.removeFirst()
            startFade(slotIdx: slotIdx, oldURL: slotURLs[slotIdx],
                      newURL: url, startTime: now)
            placed += 1
        }
        if placed > 0 {
            visLog("placeArtistPhotos — placed \(placed) artist photos on central slots \(photoSlotIndices)")
        }
    }

    /// Central-region 1×1 slots for the guaranteed artist-photo
    /// tiles. The region excludes the edge bleed, the right-hand
    /// panel column, and the lower band under the now-playing card,
    /// so every photo lands in the viewable middle of the wall.
    /// Selection is a deterministic hash-ordered scatter with a
    /// minimum pairwise separation, relaxed in steps only when the
    /// region can't satisfy it.
    private func selectPhotoSlots(count: Int, excluding: Set<Int>) -> [Int] {
        guard count > 0 else { return [] }
        let region = CGRect(x: ClubVisWindow.logicalWidth * 0.15,
                            y: ClubVisWindow.logicalHeight * 0.12,
                            width: ClubVisWindow.logicalWidth * 0.55,
                            height: ClubVisWindow.logicalHeight * 0.68)
        func centre(_ idx: Int) -> CGPoint {
            CGPoint(x: slots[idx].rect.midX, y: slots[idx].rect.midY)
        }
        let candidates = slots.indices.filter { idx in
            slots[idx].sizeClass == 1 && !excluding.contains(idx)
                && region.contains(centre(idx))
        }
        // Wall-stable ordering: same slot layout → same scatter;
        // a new wall's layout re-derives it. No runtime randomness.
        func orderHash(_ i: Int) -> UInt64 {
            var h: UInt64 = 5381
            for b in "\(i)/\(slots.count)".utf8 { h = ((h &<< 5) &+ h) &+ UInt64(b) }
            return h
        }
        let ordered = candidates.sorted { orderHash($0) < orderHash($1) }
        var best: [Int] = []
        for minSep in [240.0, 160.0, 0.0] {
            var chosen: [Int] = []
            for idx in ordered {
                let c = centre(idx)
                let farEnough = chosen.allSatisfy { other in
                    let o = centre(other)
                    return hypot(c.x - o.x, c.y - o.y) >= minSep
                }
                if farEnough { chosen.append(idx) }
                if chosen.count == count { return chosen }
            }
            if chosen.count > best.count { best = chosen }
        }
        return best
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
        // Display is cache-only: a fade to an image that isn't in
        // `preloaded` renders old → blank → pop when the download
        // lands. The background warmer keeps fetching; the URL
        // becomes eligible on a later pass. (nil newURL is a
        // legitimate fade-to-black.)
        if let newURL, !preloadedIndex.keys.contains(newURL) {
            visLog("fade SKIPPED — slot=\(slotIdx) uncached newURL source=\(source)")
            return
        }
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
        // Warm the display bitmaps off-main so the fade's first
        // frame blits instead of decoding mid-ramp.
        let px = slots[slotIdx].sizeClass * 160
        let warmCache = cgImageCache
        let warmNew = newURL.flatMap { url in preloaded[url].map { (url, $0) } }
        let warmOld = oldURL.flatMap { url in preloaded[url].map { (url, $0) } }
        if warmNew != nil || warmOld != nil {
            Task.detached(priority: .userInitiated) {
                if let (url, img) = warmNew { warmCache.warm(url: url, nsImage: img, px: px) }
                if let (url, img) = warmOld { warmCache.warm(url: url, nsImage: img, px: px) }
            }
        }
        fades[slotIdx] = FadeState(oldURL: oldURL, newURL: newURL,
                                   startTime: startTime, duration: duration,
                                   style: style, source: source)
        syncDisplayBox()
        scheduleFadeCommit(slotIdx: slotIdx, newURL: newURL,
                           startTime: startTime, duration: duration,
                           source: source)
    }

    /// Publishes the wall's current on-screen URL set (slots + both
    /// ends of in-flight fades) to the parent for trim protection.
    private func syncDisplayBox() {
        var urls = Set(slotURLs.values)
        for fade in fades.values {
            if let old = fade.oldURL { urls.insert(old) }
            if let new = fade.newURL { urls.insert(new) }
        }
        displayBox.urls = urls
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
            syncDisplayBox()
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
        // Photo slots are excluded — the guaranteed artist photos
        // stay put for the life of the wall.
        let protected = Set(photoSlotIndices)
        var slotIdx: Int? = slots.indices.filter {
            slots[$0].sizeClass == targetSize && fades[$0] == nil
                && !protected.contains($0)
        }.randomElement()
        if slotIdx == nil, targetSize != 1 {
            slotIdx = slots.indices.filter {
                slots[$0].sizeClass == 1 && fades[$0] == nil
                    && !protected.contains($0)
            }.randomElement()
        }
        guard let chosenIdx = slotIdx else { return }
        let actualSize = slots[chosenIdx].sizeClass

        // Cache-only display: swap candidates must already have
        // their image resolved.
        func avail(_ tier: [URL]) -> [URL] {
            tier.filter { !visible.contains($0) && preloadedIndex.keys.contains($0) }
        }
        let candidatesByPreference: [[URL]]
        if actualSize == 1 {
            // Variety-first chain — keeps small-tile rotation feeling
            // diverse rather than monotone-genre. Artist About photos
            // are NOT rotated in: they live on protected central
            // slots pinned at fill time.
            candidatesByPreference = [
                avail(poolBox.pool.random), avail(poolBox.pool.ambient),
                avail(poolBox.pool.genreTier3), avail(poolBox.pool.genreTier2),
                avail(poolBox.pool.genreTier1),
            ]
        } else {
            // Genres-first for 2×2/3×3 so larger rotations stay
            // contextually tied to the playing track.
            candidatesByPreference = [
                avail(poolBox.pool.genreTier1), avail(poolBox.pool.genreTier2),
                avail(poolBox.pool.genreTier3), avail(poolBox.pool.random),
                avail(poolBox.pool.ambient),
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
        // No preferred[0] fallback: in queue mode that is the queue's
        // FIRST track, and fading the anchor to it before the settled
        // hero arrives produced a wrong-cover flash on track changes.
        // The settle path re-fires this via heroUpdateTrigger.
        guard let heroURL = nowPlayingHeroURL else {
            visLog("triggerNowPlayingHeroSwap NOOP — heroURL not settled yet")
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
            syncDisplayBox()
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
        if !preloadedIndex.keys.contains(heroURL) {
            // The new art hasn't finished downloading: a fade started
            // now renders old → blank → pop, not a crossfade. Queue
            // and re-fire when `preloaded` picks the image up
            // (.onChange(of: preloaded.count) below).
            pendingHeroURL = heroURL
            visLog("triggerNowPlayingHeroSwap DEFERRED — hero art not preloaded yet")
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
                poolBox.pool.random.filter { !reserved.contains($0) && preloadedIndex.keys.contains($0) },
                poolBox.pool.ambient.filter { !reserved.contains($0) && preloadedIndex.keys.contains($0) },
                poolBox.pool.genreTier3.filter { !reserved.contains($0) && preloadedIndex.keys.contains($0) },
                poolBox.pool.genreTier2.filter { !reserved.contains($0) && preloadedIndex.keys.contains($0) },
                poolBox.pool.genreTier1.filter { !reserved.contains($0) && preloadedIndex.keys.contains($0) },
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
    /// URL from `poolBox.pool.genreTier1` (the new track's top-genre matches).
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
        let candidates = poolBox.pool.genreTier1.filter {
            !visible.contains($0) && preloadedIndex.keys.contains($0)
        }
        guard !candidates.isEmpty else { return }
        let protected = Set(photoSlotIndices)
        let smallIndices = slots.indices.filter {
            slots[$0].sizeClass == 1 && fades[$0] == nil
                && !protected.contains($0)
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

/// Zune-style ambient lighting driven by the active stage colour
/// set (`ClubStageSets`). Coloured light slowly moving across a
/// dark wall — not a spotlight rig, not an audio visualiser.
///
/// Layer stack (bottom → top; the poster wall below plays the
/// spec's flat desaturated base role):
///   - one `Canvas` on `.plusLighter` drawing every light blob as a
///     soft radial gradient with transparent falloff:
///       * 2 large faint washes (radius 1.0–1.3 × width, alpha
///         0.06–0.10, drift cycles 92 s / 133 s) — broad shifting
///         illumination,
///       * 5 smaller brighter highlight blooms (radius 0.21–0.38 ×
///         width, alpha 0.16–0.35, drift cycles 19–57 s) — the
///         visible Zune blooms, anchored asymmetrically so one
///         region reads strongly lit while the opposite corner
///         stays near-black; two anchors sit partly off-canvas so
///         blooms enter from the edges,
///   - a static vignette (`.multiply`) darkening the edges.
///
/// Every blob drifts on its own elliptical orbit (distinct anchor,
/// orbit, phase, period), wobbles with low-frequency deterministic
/// value noise, and breathes in opacity and radius. All motion is a
/// pure function of `t` — no runtime randomness, no cuts, no
/// strobes.
///
/// Set changes (track change, override, enable toggle) crossfade
/// all tones over `setFadeDuration` — never a hard cut.
///
/// 24 fps timeline cap — the motion is slow; higher rates only add
/// render cost on 4K fullscreen. All time math uses
/// `timeIntervalSinceReferenceDate` so phase is stable across
/// re-renders.
private struct ClubVisLightingView: View {
    /// Per-frame lighting tones — the active set's four roles after
    /// the set-change crossfade is applied.
    fileprivate struct ResolvedTones {
        let wash: StageTone
        let beamA: StageTone
        let beamB: StageTone
        let accent: StageTone

        init(wash: StageTone, beamA: StageTone, beamB: StageTone, accent: StageTone) {
            self.wash = wash
            self.beamA = beamA
            self.beamB = beamB
            self.accent = accent
        }

        init(set: StageSet) {
            self.init(wash: set.wash, beamA: set.beamA,
                      beamB: set.beamB, accent: set.accent)
        }

        static func lerp(_ a: ResolvedTones, _ b: ResolvedTones, t: Double) -> ResolvedTones {
            ResolvedTones(wash: StageTone.lerp(a.wash, b.wash, t: t),
                          beamA: StageTone.lerp(a.beamA, b.beamA, t: t),
                          beamB: StageTone.lerp(a.beamB, b.beamB, t: t),
                          accent: StageTone.lerp(a.accent, b.accent, t: t))
        }
    }

    // MARK: - Blob roster

    /// Colour role a blob resolves against the active set's tones
    /// each frame, so the set-change crossfade reaches every blob.
    fileprivate enum ToneRole {
        /// Set wash tone as declared.
        case wash
        /// beamA scaled down — the second large wash's muted
        /// variant.
        case mutedBeamA
        case beamA
        case beamB
        case accent
        /// Fixed warm white — the reference's upper-right bloom.
        case warmWhite
        /// beamA/accent midpoint — the reference's pink-purple
        /// lower-centre bloom.
        case pinkPurple

        func tone(from tones: ResolvedTones) -> StageTone {
            switch self {
            case .wash: return tones.wash
            case .mutedBeamA: return tones.beamA.scaled(0.55)
            case .beamA: return tones.beamA
            case .beamB: return tones.beamB
            case .accent: return tones.accent
            case .warmWhite: return StageTone(r: 1.0, g: 0.93, b: 0.82)
            case .pinkPurple: return StageTone.lerp(tones.beamA, tones.accent, t: 0.5)
            }
        }
    }

    /// One drifting radial-gradient blob. Anchors/orbits are
    /// fractions of the logical canvas (x/orbitX/noiseX × width,
    /// y/orbitY/noiseY × height); radii are fractions of the
    /// logical width. Position:
    ///   x = anchorX + cos(t·2π/period + phase) · orbitX + noise
    ///   y = anchorY + sin(t·2π/period·ySpeedRatio + phase) · orbitY + noise
    /// with low-frequency value-noise wobble, plus opacity and
    /// radius breathing on independent rates.
    fileprivate struct Blob {
        let role: ToneRole
        let anchorX: Double
        let anchorY: Double
        let orbitX: Double
        let orbitY: Double
        let radius: Double
        let baseAlpha: Double
        /// Seconds per drift cycle.
        let period: Double
        let phase: Double
        /// Vertical-frequency ratio — 0.6 for washes, 0.75 for
        /// highlights, so paths are ellipses, not lines.
        let ySpeedRatio: Double
        /// Opacity breathing (rad/s, ± amount).
        let pulseSpeed: Double
        let pulseAmount: Double
        /// Radius breathing (rad/s, ± amount as fraction of width).
        let radiusSpeed: Double
        let radiusAmount: Double
        /// Value-noise lattice offset — distinct per blob so wobble
        /// decorrelates.
        let noiseSeed: Double
        let noiseX: Double
        let noiseY: Double
    }

    /// Draw order: washes first (broad shifting illumination), then
    /// highlight blooms. Anchors cluster the bright mass toward the
    /// lower-left; the upper-right corner gets only the faint warm
    /// white, so the frame reads strongly asymmetric. Every
    /// anchor/orbit/phase/period/pulse rate differs — no two blobs
    /// ever move at the same speed.
    fileprivate static let blobs: [Blob] = [
        // Large faint washes — drift cycles 92 s / 133 s.
        Blob(role: .wash, anchorX: 0.30, anchorY: 0.55,
             orbitX: 0.16, orbitY: 0.10,
             radius: 1.30, baseAlpha: 0.14, period: 92, phase: 0.7,
             ySpeedRatio: 0.6,
             pulseSpeed: 2 * .pi / 47, pulseAmount: 0.020,
             radiusSpeed: 2 * .pi / 61, radiusAmount: 0.050,
             noiseSeed: 11, noiseX: 0.05, noiseY: 0.04),
        Blob(role: .mutedBeamA, anchorX: 0.50, anchorY: 0.70,
             orbitX: 0.13, orbitY: 0.09,
             radius: 1.00, baseAlpha: 0.09, period: 133, phase: 3.9,
             ySpeedRatio: 0.6,
             pulseSpeed: 2 * .pi / 53, pulseAmount: 0.015,
             radiusSpeed: 2 * .pi / 71, radiusAmount: 0.040,
             noiseSeed: 47, noiseX: 0.04, noiseY: 0.05),
        // Highlight blooms — drift cycles 19–57 s.
        // Dominant bloom, lower-left, anchored partly off-canvas.
        Blob(role: .beamA, anchorX: 0.14, anchorY: -0.06,
             orbitX: 0.09, orbitY: 0.11,
             radius: 0.38, baseAlpha: 0.46, period: 68, phase: 0.0,
             ySpeedRatio: 0.75,
             pulseSpeed: 2 * .pi / 13, pulseAmount: 0.050,
             radiusSpeed: 2 * .pi / 17, radiusAmount: 0.020,
             noiseSeed: 101, noiseX: 0.03, noiseY: 0.03),
        Blob(role: .accent, anchorX: 0.32, anchorY: 0.30,
             orbitX: 0.07, orbitY: 0.13,
             radius: 0.28, baseAlpha: 0.36, period: 52, phase: 4.4,
             ySpeedRatio: 0.75,
             pulseSpeed: 2 * .pi / 11, pulseAmount: 0.040,
             radiusSpeed: 2 * .pi / 19, radiusAmount: 0.015,
             noiseSeed: 163, noiseX: 0.025, noiseY: 0.03),
        Blob(role: .beamB, anchorX: 0.86, anchorY: 0.04,
             orbitX: 0.06, orbitY: 0.12,
             radius: 0.34, baseAlpha: 0.44, period: 46, phase: 2.1,
             ySpeedRatio: 0.75,
             pulseSpeed: 2 * .pi / 9.5, pulseAmount: 0.040,
             radiusSpeed: 2 * .pi / 14, radiusAmount: 0.018,
             noiseSeed: 211, noiseX: 0.025, noiseY: 0.025),
        // Faint warm white, upper-right, partly off-canvas — the
        // only light near the darkest corner.
        Blob(role: .warmWhite, anchorX: 0.97, anchorY: 0.05,
             orbitX: 0.05, orbitY: 0.05,
             radius: 0.25, baseAlpha: 0.22, period: 78, phase: 1.3,
             ySpeedRatio: 0.75,
             pulseSpeed: 2 * .pi / 15, pulseAmount: 0.030,
             radiusSpeed: 2 * .pi / 23, radiusAmount: 0.012,
             noiseSeed: 271, noiseX: 0.02, noiseY: 0.02),
        // Lower-centre, anchored below the canvas edge — enters
        // from the bottom.
        Blob(role: .pinkPurple, anchorX: 0.20, anchorY: -0.08,
             orbitX: 0.08, orbitY: 0.10,
             radius: 0.21, baseAlpha: 0.34, period: 38, phase: 5.5,
             ySpeedRatio: 0.75,
             pulseSpeed: 2 * .pi / 8, pulseAmount: 0.035,
             radiusSpeed: 2 * .pi / 12, radiusAmount: 0.014,
             noiseSeed: 331, noiseX: 0.03, noiseY: 0.02),
        // Centre-field ambience — one very large, very faint wash
        // over the vertical middle of the wall. The ceiling rig
        // (top band) and the stage sweeps (lower band) leave the
        // centre unlit; this blob carries the scheme's colour into
        // that band without adding structure that competes with
        // either. Slowest drift in the roster.
        Blob(role: .wash, anchorX: 0.50, anchorY: 0.45,
             orbitX: 0.06, orbitY: 0.04,
             radius: 0.90, baseAlpha: 0.13, period: 150, phase: 2.6,
             ySpeedRatio: 0.6,
             pulseSpeed: 2 * .pi / 59, pulseAmount: 0.012,
             radiusSpeed: 2 * .pi / 83, radiusAmount: 0.030,
             noiseSeed: 389, noiseX: 0.03, noiseY: 0.03),
    ]

    /// Vignette geometry — transparent centre to black-0.35 edges.
    private static let vignetteEdgeOpacity = 0.42
    /// Set-change crossfade length.
    fileprivate static let setFadeDuration = 6.0
    /// Global light-energy scalar applied to every blob and sweep
    /// alpha at draw time (clamped to 1.0). One knob for overall
    /// intensity — the roster's relative alpha structure is preserved.
    /// 1.35 was mathematically visible but visually flat against the
    /// Zune reference; beams now saturate their cores.
    fileprivate static let lightIntensity = 1.7
    /// Extra alpha scalar on emitters carrying the hue-outlier tone
    /// (see `emphasisSlot`).
    fileprivate static let emphasisBoost = 1.5

    /// Hue/saturation of a tone — pure math, no NSColor round-trip.
    fileprivate static func hueSat(_ tone: StageTone) -> (hue: Double, sat: Double) {
        let mx = max(tone.r, tone.g, tone.b)
        let mn = min(tone.r, tone.g, tone.b)
        let d = mx - mn
        guard mx > 0.0001, d > 0.0001 else { return (0, 0) }
        var h: Double
        if mx == tone.r { h = (tone.g - tone.b) / d }
        else if mx == tone.g { h = 2 + (tone.b - tone.r) / d }
        else { h = 4 + (tone.r - tone.g) / d }
        h *= 60
        if h < 0 { h += 360 }
        return (h, d / mx)
    }

    /// When three ladder tones cluster in hue and the fourth stands
    /// apart (a cover like gold/gold/gold + red), that differing tone
    /// is easy to lose on the wall. Returns the outlier slot with a
    /// CONTINUOUS weight in (0, 1]: full weight when all four tones
    /// are chromatic, the outlier sits ≥ 50° in hue from every other
    /// tone, and the remaining three sit within 25° — ramping to 0
    /// as any of those conditions relaxes (chromaticity below 0.20,
    /// separation below 40°, cluster spread above 35°). Nil when the
    /// weight is 0 (spread schemes, single-hue ladders, achromatic
    /// members). The ramps matter: emphasis is evaluated on the
    /// crossfade-resolved tones every frame, and a binary threshold
    /// made the boosted emitters step in one frame mid-fade —
    /// observed as the lights blinking on song change.
    fileprivate static func emphasisSlot(tones: ResolvedTones)
        -> (slot: ToneRole, weight: Double)? {
        let slots: [(ToneRole, StageTone)] =
            [(.wash, tones.wash), (.beamA, tones.beamA),
             (.beamB, tones.beamB), (.accent, tones.accent)]
        let hs = slots.map { hueSat($0.1) }
        func ramp(_ x: Double) -> Double { min(max(x, 0), 1) }
        let satW = hs.map { ramp(($0.sat - 0.20) / 0.05) }.min() ?? 0
        guard satW > 0 else { return nil }
        func dist(_ a: Double, _ b: Double) -> Double {
            let d = abs(a - b).truncatingRemainder(dividingBy: 360)
            return min(d, 360 - d)
        }
        let nn = (0..<4).map { i in
            (0..<4).filter { $0 != i }
                .map { dist(hs[i].hue, hs[$0].hue) }.min()!
        }
        guard let iMax = nn.indices.max(by: { nn[$0] < nn[$1] }) else { return nil }
        let nnW = ramp((nn[iMax] - 40) / 10)
        guard nnW > 0 else { return nil }
        let rest = (0..<4).filter { $0 != iMax }
        let clusterMax = rest.flatMap { i in
            rest.filter { $0 > i }.map { dist(hs[i].hue, hs[$0].hue) }
        }.max() ?? 0
        let clusterW = ramp((35 - clusterMax) / 10)
        let weight = satW * nnW * clusterW
        return weight > 0 ? (slots[iMax].0, weight) : nil
    }

    /// The ladder slot an emitter role draws from — nil for the
    /// derived roles (warm white, pink-purple blend) that never
    /// carry emphasis.
    fileprivate static func baseSlot(_ role: ToneRole) -> ToneRole? {
        switch role {
        case .wash: return .wash
        case .beamA, .mutedBeamA: return .beamA
        case .beamB: return .beamB
        case .accent: return .accent
        case .warmWhite, .pinkPurple: return nil
        }
    }

    @ObservedObject private var debugState = BackOfTheClubDebugState.shared

    var body: some View {
        // 12 fps. Each tick rasterizes the blob field TWICE (the
        // colorize and glow passes are separate full-window
        // Canvases) and composites both through full-window blend
        // modes — at 24 fps that fixed cost alone stuttered every
        // other layer. 12 fps halves it; the gradients are smooth
        // by construction so motion reads fine at this rate.
        TimelineView(.animation(minimumInterval: 1.0 / 12.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let tones = Self.resolvedTones(at: t, state: debugState)
            // Vibrancy-graded pass opacities. The colorize pass at a
            // fixed 0.85 tinted the ENTIRE wall with whatever peaks a
            // near-achromatic cover scraped past the saturation gate
            // — observed as a muddy sepia wall on a mostly-white/black
            // cover. Colorize lerps 0.35 → 0.85 with vibrancy; the
            // glow pass lerps the opposite way (0.65 → 0.55) so dim
            // covers still read lit, just neutrally.
            let vibrancy = Self.resolvedVibrancy(at: t, state: debugState)
            let colorizeOpacity = Self.colorizeOpacity(vibrancy: vibrancy)
            let glowOpacity = Self.glowOpacity(vibrancy: vibrancy)

            ZStack {
                // All light blobs in one Canvas. `.plusLighter` on
                // the view adds the canvas output to the wall; the
                // same blend inside the context stacks overlapping
                // blobs additively.
                // Colorize + glow double pass — the LightingLab
                // harness (tools/LightingLab) showed a single screen
                // pass lifts luminance and greys out; a `.color` hue
                // layer makes the light OWN its region at full
                // saturation (the Zune reference look) while the
                // moderated screen pass adds the glow.
                ClubVisBlobCanvas(tones: tones, t: t,
                                  seed: debugState.wallLightSeed)
                    .blendMode(.color)
                    .opacity(colorizeOpacity)
                ClubVisBlobCanvas(tones: tones, t: t,
                                  seed: debugState.wallLightSeed)
                    .blendMode(.screen)
                    .opacity(glowOpacity)

                // Static vignette — transparent centre, darkened
                // edges, per the reference frames.
                // Floor darkness — the back of a club is lit from the
                // ceiling rig; the bottom of the wall falls away into
                // crowd shadow. Linear pull-down under the radial
                // vignette.
                LinearGradient(
                    stops: [.init(color: .clear, location: 0.0),
                            .init(color: .clear, location: 0.55),
                            .init(color: .black.opacity(0.30), location: 1.0)],
                    startPoint: .top, endPoint: .bottom)
                    .blendMode(.multiply)

                RadialGradient(
                    colors: [.clear,
                             .black.opacity(Self.vignetteEdgeOpacity)],
                    center: .center,
                    startRadius: ClubVisWindow.logicalHeight * 0.15,
                    endRadius: ClubVisWindow.logicalWidth * 0.57)
                .blendMode(.multiply)
            }
            .frame(width: ClubVisWindow.logicalWidth,
                   height: ClubVisWindow.logicalHeight)
            .allowsHitTesting(false)
        }
    }

    // MARK: - Blob drawing

    /// Per-wall variation. Deterministic [−1, 1] jitter for one
    /// emitter channel — a pure function of (wall seed, emitter key,
    /// channel) built on the same `hash01` lattice hash the value
    /// noise uses. Same wall seed → identical light arrangement
    /// every frame; a new wall seed re-derives every offset. No
    /// runtime randomness.
    fileprivate static func seedJitter(_ seed: UInt64, key: Int, channel: Int) -> Double {
        hash01(key &+ channel &* 7919, salt: seed &+ 0xA5A5_1EAF) * 2.0 - 1.0
    }

    /// Renders one blob as a soft radial gradient with transparent
    /// falloff — no crisp circles, no spotlight cones. Position,
    /// opacity, and radius are continuous pure functions of `t` and
    /// the wall `seed`.
    fileprivate static func draw(_ blob: Blob, tones: ResolvedTones,
                             emphasis: (slot: ToneRole, weight: Double)?,
                             at t: Double, seed: UInt64, size: CGSize,
                             in ctx: inout GraphicsContext) {
        let w = size.width
        let h = size.height
        // Per-wall variation — anchors jittered ±0.10 in x/y and the
        // phase re-derived from the wall seed, so each wall lights a
        // recognisably different arrangement. The y clamp keeps each
        // emitter in its designed band: ceiling-rig blobs (roster
        // anchors ≤ 0.16) stay in the top band; the centre-field
        // ambience blob stays in the middle band.
        let key = Int(blob.noiseSeed)
        var anchorX = min(max(blob.anchorX + seedJitter(seed, key: key, channel: 0) * 0.10, 0.02), 1.02)
        let yBand: ClosedRange<Double> = blob.anchorY < 0.30 ? (-0.14)...0.26 : 0.35...0.55
        var anchorY = min(max(blob.anchorY + seedJitter(seed, key: key, channel: 1) * 0.10,
                              yBand.lowerBound), yBand.upperBound)
        // The differing colour must be CENTRALLY visible — several
        // roster anchors sit off-canvas or behind the right-hand
        // panels (beamB at x 0.86). Pull the emphasised emitter's
        // anchor toward the centre field, scaled by the continuous
        // emphasis weight so relocation glides with set crossfades.
        if let emphasis, Self.baseSlot(blob.role) == emphasis.slot {
            let pull = 0.65 * emphasis.weight
            anchorX += (0.42 - anchorX) * pull
            anchorY += (0.30 - anchorY) * pull
        }
        let phase = hash01(key &+ 3, salt: seed &+ 0x9E37_79B9) * 2.0 * .pi
        let speed = 2.0 * .pi / blob.period
        var x = anchorX * w + cos(t * speed + phase) * blob.orbitX * w
        var y = anchorY * h
            + sin(t * speed * blob.ySpeedRatio + phase) * blob.orbitY * h
        // Low-frequency wobble so orbits never read mechanical.
        x += smoothNoise(t * 0.015 + blob.noiseSeed) * blob.noiseX * w
        y += smoothNoise(t * 0.015 + blob.noiseSeed + 20) * blob.noiseY * h
        let boost: Double = {
            guard let emphasis, Self.baseSlot(blob.role) == emphasis.slot else { return 1.0 }
            return 1.0 + (Self.emphasisBoost - 1.0) * emphasis.weight
        }()
        let alpha = min(1.0, (blob.baseAlpha
            + sin(t * blob.pulseSpeed + phase) * blob.pulseAmount)
            * Self.lightIntensity * boost)
        let radius = (blob.radius
            + sin(t * blob.radiusSpeed + phase) * blob.radiusAmount) * w
        let color = Self.richColor(for: blob.role, tones: tones)
        // Blurred solid fill, not gradient shading: radial-gradient
        // shading in GraphicsContext rendered nothing on macOS
        // (probe-verified 2026-08-07 — solid .color fills in the same
        // canvas drew fine). The blur also produces the reference's
        // soft edge more faithfully than gradient stops.
        // Concentric falloff fills with a CAPPED blur. A blur radius
        // proportional to blob radius reached 300-950 px on the wash
        // blobs and the Canvas filter rasterized to nothing at that
        // size (probe-verified); three nested ellipses at falling
        // alpha carry the falloff, and a capped blur only softens the
        // ring edges.
        // Ring falloff with NO blur filter: the per-layer blur
        // rasterization (two passes x ten layers per frame) stalled the
        // main thread for seconds. Six rings under the colorize blend
        // read as soft against the wall texture at zero filter cost.
        // True radial gradient — smooth by construction, no banding,
        // no blur cost. The earlier gradient-draws-nothing failure was
        // specific to `ctx.blendMode = .plusLighter`; under default
        // in-canvas blending gradient shading renders correctly.
        ctx.fill(
            Path(ellipseIn: CGRect(x: x - radius, y: y - radius,
                                   width: radius * 2, height: radius * 2)),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: color.opacity(alpha), location: 0.0),
                    .init(color: color.opacity(alpha * 0.35), location: 0.45),
                    .init(color: color.opacity(0.0), location: 1.0),
                ]),
                center: CGPoint(x: x, y: y),
                startRadius: 0,
                endRadius: radius))
    }

    // (blob canvas extracted below as ClubVisBlobCanvas for the
    // colorize + glow double pass.)

    /// Club-photo grading: lit surfaces read as SATURATED colour at
    /// moderate luminance — a screen-blended layer built from bright
    /// tones lifts luminance and washes the top of the wall toward
    /// white. Rebuild each layer colour at full saturation with capped
    /// brightness so the light adds tint, not white. The warm-white
    /// bloom keeps its low saturation but is dimmed for the same
    /// reason.
    private static func richColor(for role: ToneRole, tones: ResolvedTones) -> Color {
        let tone = role.tone(from: tones)
        let base = NSColor(red: tone.r, green: tone.g, blue: tone.b, alpha: 1)
            .usingColorSpace(.deviceRGB) ?? .white
        var h: CGFloat = 0, sat: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.getHue(&h, saturation: &sat, brightness: &b, alpha: &a)
        // Stage-gel floor applied AFTER the role caps: no brown
        // stage light — a warm hue rendered dark reads brown, which
        // no fixture produces (see ClubStageSets.gelBrightnessFloor).
        let gelFloor = CGFloat(ClubStageSets.gelBrightnessFloor(hue: Double(h) * 360))
        switch role {
        case .warmWhite:
            return Color(NSColor(hue: h, saturation: sat, brightness: min(b, 0.72), alpha: 1))
        case .wash, .mutedBeamA:
            return Color(NSColor(hue: h, saturation: max(sat, 0.95),
                                 brightness: max(min(b, 0.70), gelFloor), alpha: 1))
        default:
            return Color(NSColor(hue: h, saturation: max(sat, 0.92),
                                 brightness: max(min(b, 0.85), gelFloor), alpha: 1))
        }
    }

    // MARK: - Stage beam sweeps

    /// Rotating oval beam footprints on the lower wall — stage-mounted
    /// moving heads. Position and rotation are independent value-noise
    /// signals per beam (no shared period): the three run async and
    /// only align when the noise happens to coincide.
    fileprivate struct SweepBeam {
        let role: ToneRole
        let posSeed: Double
        let rotSeed: Double
        /// Noise time scale — differs per beam so no two share a cadence.
        let speed: Double
        let anchorY: Double
        /// Beam footprint half-length as a fraction of canvas width.
        let length: Double
        /// Minor axis as a fraction of the major axis.
        let aspect: Double
        let alpha: Double
    }

    fileprivate static let sweeps: [SweepBeam] = [
        SweepBeam(role: .beamA, posSeed: 411, rotSeed: 412, speed: 0.011,
                  anchorY: 0.80, length: 0.24, aspect: 0.38, alpha: 0.78),
        SweepBeam(role: .beamB, posSeed: 421, rotSeed: 422, speed: 0.016,
                  anchorY: 0.88, length: 0.21, aspect: 0.36, alpha: 0.72),
        SweepBeam(role: .accent, posSeed: 431, rotSeed: 432, speed: 0.024,
                  anchorY: 0.76, length: 0.18, aspect: 0.40, alpha: 0.75),
    ]

    fileprivate static func drawSweep(_ sweep: SweepBeam, tones: ResolvedTones,
                                      emphasis: (slot: ToneRole, weight: Double)?,
                                      at t: Double, seed: UInt64, size: CGSize,
                                      in ctx: inout GraphicsContext) {
        // Per-wall variation — the position/rotation noise-timeline
        // seeds are offset by a wall-seed-derived shift (each wall
        // samples a different stretch of the noise field) and the
        // anchor row is jittered ±0.10, clamped to the lower band so
        // sweeps stay stage-mounted. Pure functions of the wall seed.
        let key = Int(sweep.posSeed)
        let posSeed = sweep.posSeed + hash01(key, salt: seed &+ 0x0BEA_C0DE) * 512.0
        let rotSeed = sweep.rotSeed + hash01(Int(sweep.rotSeed), salt: seed &+ 0x0BEA_C0DE) * 512.0
        let anchorY = min(max(sweep.anchorY + seedJitter(seed, key: key, channel: 2) * 0.10, 0.62), 0.92)
        let x = size.width * (0.5 + smoothNoise(t * sweep.speed + posSeed) * 0.42)
        // Vertical travel: sweeps range up from the stage row toward
        // the centre band on upward swings. 0.18 crowded the centre
        // (with the centre wash and the emphasised emitter also
        // there) — the blooms own the top, sweeps own the lower half.
        let y = size.height * (anchorY + smoothNoise(t * sweep.speed * 0.7 + posSeed + 7) * 0.14)
        let angle = smoothNoise(t * sweep.speed * 1.3 + rotSeed) * 0.9
        let major = sweep.length * size.width
        let color = richColor(for: sweep.role, tones: tones)
        let boost: Double = {
            guard let emphasis, baseSlot(sweep.role) == emphasis.slot else { return 1.0 }
            return 1.0 + (emphasisBoost - 1.0) * emphasis.weight
        }()
        let coreAlpha = min(1.0, sweep.alpha * lightIntensity * boost)
        ctx.drawLayer { layer in
            layer.translateBy(x: x, y: y)
            layer.rotate(by: .radians(angle))
            // Oval via y-scale so a circular radial gradient renders
            // the angled beam footprint smoothly (see blob comment on
            // gradient shading vs the removed ring ladder).
            layer.scaleBy(x: 1.0, y: sweep.aspect)
            layer.fill(
                Path(ellipseIn: CGRect(x: -major, y: -major,
                                       width: major * 2, height: major * 2)),
                with: .radialGradient(
                    Gradient(stops: [
                        .init(color: color.opacity(coreAlpha), location: 0.0),
                        .init(color: color.opacity(coreAlpha * 0.4), location: 0.5),
                        .init(color: color.opacity(0.0), location: 1.0),
                    ]),
                    center: .zero,
                    startRadius: 0,
                    endRadius: major))
        }
    }

    // MARK: - Noise

    /// Deterministic value noise in [−1, 1] — integer-lattice hash
    /// values, smoothstep-interpolated between neighbours. Pure
    /// function of its argument; no runtime randomness, so every
    /// body eval at the same `t` renders identically.
    static func smoothNoise(_ v: Double) -> Double {
        let i = Int(v.rounded(.down))
        let f = v - v.rounded(.down)
        let a = hash01(i, salt: 0x51D0_0D5E)
        let b = hash01(i + 1, salt: 0x51D0_0D5E)
        return (a + (b - a) * smoothstep(f)) * 2.0 - 1.0
    }

    /// Deterministic [0, 1) hash of an integer — lattice source for
    /// `smoothNoise`. splitmix64-style diffusion so adjacent lattice
    /// points decorrelate.
    static func hash01(_ n: Int, salt: UInt64) -> Double {
        var h = UInt64(bitPattern: Int64(n)) &* 0x9E37_79B9_7F4A_7C15 &+ salt
        h ^= h >> 33
        h &*= 0xFF51_AFD7_ED55_8CCD
        h ^= h >> 33
        return Double(h % 1_000_000) / 1_000_000.0
    }

    static func smoothstep(_ x: Double) -> Double {
        let c = min(1.0, max(0.0, x))
        return c * c * (3 - 2 * c)
    }

    // MARK: - Set resolution

    /// Target set for the current state, in precedence order:
    ///   1. Debug override ≥ 0 → pinned catalogue set (debug-only
    ///      control, wins over every scheme).
    ///   2. Settings scheme "Choragus" / "Custom" → the fixed set;
    ///      matching is bypassed but changes still crossfade.
    ///   3. Scheme "Album art" (default): lighting disabled →
    ///      fallback set; otherwise the generated cover-shades set
    ///      for the current artwork, or the fallback when no
    ///      generated set is present.
    fileprivate static func targetSet(state: BackOfTheClubDebugState) -> StageSet {
        let sets = ClubStageSets.sets
        let override = state.stageSetOverride
        if override >= 0 && override < sets.count { return sets[override] }
        switch state.colourScheme {
        case .choragus: return ClubStageSets.choragusSet
        case .custom: return state.customStageSet
        case .albumArt: break
        }
        guard state.stageSetLightingEnabled else { return sets[ClubStageSets.fallbackIndex] }
        if let generated = state.matchedGeneratedSet { return generated }
        // Achromatic (black-and-white) covers and no-art states
        // light with the Choragus wordmark neons — the brand scheme,
        // not a colour guess. The Zune house set remains only for
        // the explicit disabled toggle above.
        if state.matchedSetIndex == ClubStageSets.fallbackIndex {
            return ClubStageSets.choragusSet
        }
        let idx = state.matchedSetIndex
        return sets[(idx >= 0 && idx < sets.count) ? idx : ClubStageSets.fallbackIndex]
    }

    /// Tones rendered this frame. Every target change (new match,
    /// override, enable toggle) blends from the snapshot in
    /// `state.setFadeFrom` over `setFadeDuration` — never a hard
    /// cut. Mid-fade changes re-snapshot, so the blend always
    /// continues from the on-screen colours.
    fileprivate static func resolvedTones(at t: Double,
                                          state: BackOfTheClubDebugState) -> ResolvedTones {
        let target = ResolvedTones(set: targetSet(state: state))
        guard let from = state.setFadeFrom else { return target }
        let elapsed = t - state.setFadeStart.timeIntervalSinceReferenceDate
        guard elapsed >= 0, elapsed < setFadeDuration else { return target }
        return ResolvedTones.lerp(from, target, t: smoothstep(elapsed / setFadeDuration))
    }

    /// Vibrancy target for the current state. Album-art scheme uses
    /// the matched cover's vibrancy (mean sat × mean bri of chromatic
    /// pixels); the fixed schemes and the debug override apply their
    /// declared colours at full strength (v = 1).
    fileprivate static func targetVibrancy(state: BackOfTheClubDebugState) -> Double {
        if state.stageSetOverride >= 0 { return 1.0 }
        switch state.colourScheme {
        case .choragus, .custom: return 1.0
        case .albumArt: return state.matchedVibrancy
        }
    }

    /// Vibrancy rendered this frame — lerps from the snapshot in
    /// `state.vibrancyFadeFrom` on the same clock as `resolvedTones`
    /// so the colorize-pass opacity glides with the tone crossfade.
    fileprivate static func resolvedVibrancy(at t: Double,
                                             state: BackOfTheClubDebugState) -> Double {
        let target = targetVibrancy(state: state)
        guard let from = state.vibrancyFadeFrom else { return target }
        let elapsed = t - state.setFadeStart.timeIntervalSinceReferenceDate
        guard elapsed >= 0, elapsed < setFadeDuration else { return target }
        return from + (target - from) * smoothstep(elapsed / setFadeDuration)
    }

    /// Pass-opacity grading — single definition shared by the render
    /// body and the debug readout.
    fileprivate static func colorizeOpacity(vibrancy: Double) -> Double {
        0.40 + 0.45 * vibrancy
    }
    /// Glow strengthens as vibrancy falls: a muted cover's tint pass
    /// is weak, so the glow pass alone must carry visible light.
    /// Curve history: 0.65 − 0.10v left a v = 0.20 cover at ~25/255
    /// in blob cores (unlit); 0.85 − 0.30v was measurable but still
    /// visually flat against the Zune reference. Full-strength glow
    /// at v = 0 tapering to 0.70 at v = 1.
    fileprivate static func glowOpacity(vibrancy: Double) -> Double {
        1.0 - 0.30 * vibrancy
    }
}

/// One frame of the blob field. Rendered twice per frame by
/// `ClubVisLightingView` with different blend modes (colorize + glow).
private struct ClubVisBlobCanvas: View {
    let tones: ClubVisLightingView.ResolvedTones
    let t: Double
    /// Wall seed — per-wall emitter variation (see `seedJitter`).
    let seed: UInt64

    var body: some View {
        Canvas { ctx, size in
            let emphasis = ClubVisLightingView.emphasisSlot(tones: tones)
            // Uniform base wash: the wash BLOB is a radial gradient
            // centred mid-wall, so the corners and edges sat almost
            // unlit (reported: wash should be even across the whole
            // wall). A flat full-canvas fill in the wash tone carries
            // the scheme's colour to every tile; the blobs and sweeps
            // add the structured light on top. Slow breathing pulse
            // keeps it feeling live rather than painted on.
            let washTone = tones.wash
            let pulse = 0.85 + 0.15 * (0.5 + 0.5 * sin(t * 2 * .pi / 41))
            let washAlpha = min(1.0, 0.16 * ClubVisLightingView.lightIntensity) * pulse
            // Vertical falloff: the rig hangs from the ceiling, so
            // the wash is brightest at the top and falls to about a
            // third of that strength at the floor line (the multiply
            // floor-shadow below takes it the rest of the way down).
            let washColor = { (alpha: Double) in
                Color(red: washTone.r, green: washTone.g,
                      blue: washTone.b, opacity: alpha)
            }
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .linearGradient(
                        Gradient(stops: [
                            .init(color: washColor(washAlpha), location: 0.0),
                            .init(color: washColor(washAlpha * 0.75), location: 0.45),
                            .init(color: washColor(washAlpha * 0.35), location: 1.0),
                        ]),
                        startPoint: .zero,
                        endPoint: CGPoint(x: 0, y: size.height)))
            for blob in ClubVisLightingView.blobs {
                ClubVisLightingView.draw(blob, tones: tones, emphasis: emphasis,
                                         at: t, seed: seed, size: size, in: &ctx)
            }
            for sweep in ClubVisLightingView.sweeps {
                ClubVisLightingView.drawSweep(sweep, tones: tones, emphasis: emphasis,
                                              at: t, seed: seed, size: size, in: &ctx)
            }
        }
    }
}

// MARK: - Now Playing card

private struct ClubVisNowPlayingCard: View {
    let trackMetadata: TrackMetadata
    let albumArtURL: URL?
    let sourceLabel: String
    /// Format evidence line (Atmos / TV format / stream details) —
    /// nil renders nothing, matching the main window's pill rule.
    let formatDetails: String?
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
                        // Read + luma computation off-main; the disk
                        // queue can be busy for seconds during pool
                        // warms.
                        let luma = await Task.detached(priority: .utility) {
                            ImageCache.shared.image(for: url)?.averagePerceivedLuminance()
                        }.value
                        if let luma {
                            artLuma = luma
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
            // Line order mirrors the player's now-playing stack:
            // title, artist, album.
            VStack(alignment: .leading, spacing: 12) {
                if !trackMetadata.title.isEmpty {
                    Text(trackMetadata.title.uppercased())
                        .font(.system(size: 30, weight: .heavy))
                        .tracking(2)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                }
                if !trackMetadata.artist.isEmpty {
                    Text(trackMetadata.artist.uppercased())
                        .font(.system(size: 22, weight: .semibold))
                        .tracking(1.5)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
                if !trackMetadata.album.isEmpty {
                    Text(trackMetadata.album)
                        .font(.system(size: 22, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.95))
                        .lineLimit(1)
                        .padding(.top, 4)
                }
                Spacer(minLength: 0)
                if let formatDetails {
                    Text(formatDetails.uppercased())
                        .font(.system(size: 13, weight: .semibold))
                        .tracking(1.5)
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
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
    /// Lighting parameters surfaced to the debug window —
    /// `ClubVisWindow.stage` reads the black multiply opacity every
    /// body eval, so slider changes apply immediately.
    @Published var lighting: LightingControls = LightingControls()

    /// Seed of the wall currently on screen — the packer layout seed,
    /// written from `ClubVisWindow.recomputeSlots()` (the funnel every
    /// wall-start path passes through). `ClubVisLightingView` derives
    /// per-emitter anchor jitter, phases, and sweep noise offsets from
    /// it, so each wall renders a distinct deterministic light
    /// arrangement: same seed → identical lights, new wall → new
    /// arrangement. Never derived from runtime randomness here.
    @Published var wallLightSeed: UInt64 = 0

    // MARK: - Stage-set lighting (matched from now-playing art)

    /// Catalogue index applied when no generated set is present —
    /// the fallback for no-art and achromatic-cover states. Written
    /// only through `setMatchedSet` so every tone change starts a
    /// crossfade.
    @Published private(set) var matchedSetIndex: Int = ClubStageSets.fallbackIndex
    /// "Cover shades" set generated from the current artwork's
    /// detected hues — the automatic lighting target. Nil on the
    /// fallback path (no art / achromatic cover). Written only
    /// through `setMatchedSet`.
    @Published private(set) var matchedGeneratedSet: StageSet?
    /// Gate for matched-set lighting. Off = set #0 ("Zune house").
    /// Applies within the album-art scheme only — the fixed schemes
    /// bypass matching entirely.
    @Published var stageSetLightingEnabled: Bool = true {
        didSet { beginSetFade() }
    }

    // MARK: - Colour scheme (Settings-selected)

    /// Active Club Vis colour scheme. Bound directly by the Settings
    /// UI (single source of truth — no parallel @AppStorage), loaded
    /// from UserDefaults at init, persisted on change. Every change
    /// runs the standard set crossfade. `albumArt` (default) is the
    /// existing cover-derived pipeline including its fallback rules;
    /// `choragus` / `custom` bypass matching and apply a fixed set.
    @Published var colourScheme: VisColourScheme = VisColourScheme.current {
        didSet {
            guard colourScheme != oldValue else { return }
            beginSetFade()
            UserDefaults.standard.set(colourScheme.rawValue,
                                      forKey: UDKey.visColourScheme)
        }
    }
    /// Custom-scheme tones, "#RRGGBB". Defaults are the Choragus
    /// scheme's role tones so first-time Custom selection renders a
    /// coherent set before the user edits anything.
    @Published var customWashHex: String =
        UserDefaults.standard.string(forKey: UDKey.visCustomToneWash)
            ?? ClubStageSets.choragusSet.wash.hexString {
        didSet { customToneChanged(oldValue, customWashHex, key: UDKey.visCustomToneWash) }
    }
    @Published var customBeamAHex: String =
        UserDefaults.standard.string(forKey: UDKey.visCustomToneBeamA)
            ?? ClubStageSets.choragusSet.beamA.hexString {
        didSet { customToneChanged(oldValue, customBeamAHex, key: UDKey.visCustomToneBeamA) }
    }
    @Published var customBeamBHex: String =
        UserDefaults.standard.string(forKey: UDKey.visCustomToneBeamB)
            ?? ClubStageSets.choragusSet.beamB.hexString {
        didSet { customToneChanged(oldValue, customBeamBHex, key: UDKey.visCustomToneBeamB) }
    }
    @Published var customAccentHex: String =
        UserDefaults.standard.string(forKey: UDKey.visCustomToneAccent)
            ?? ClubStageSets.choragusSet.accent.hexString {
        didSet { customToneChanged(oldValue, customAccentHex, key: UDKey.visCustomToneAccent) }
    }

    private func customToneChanged(_ old: String, _ new: String, key: String) {
        guard new != old else { return }
        // Re-snapshot the fade so live ColorPicker drags glide from
        // the on-screen colours instead of hard-cutting.
        if colourScheme == .custom { beginSetFade() }
        UserDefaults.standard.set(new, forKey: key)
    }

    /// The custom StageSet built from the four stored tones.
    var customStageSet: StageSet {
        ClubStageSets.customSet(washHex: customWashHex,
                                beamAHex: customBeamAHex,
                                beamBHex: customBeamBHex,
                                accentHex: customAccentHex)
    }
    /// −1 = follow the matcher; valid set index = pin that set.
    @Published var stageSetOverride: Int = -1 {
        didSet { beginSetFade() }
    }
    /// Histogram readings behind the current match — dominant
    /// detected hue (nil = no chromatic mass) and chromatic
    /// fraction. Debug-window display only.
    @Published private(set) var matchedDominantHue: Double?
    @Published private(set) var matchedTopHues: [Double] = []
    @Published private(set) var matchedChromaticFraction: Double = 0
    /// Mean saturation / brightness of the cover's chromatic pixels
    /// and their product (the vibrancy factor v, [0, 1]). v grades
    /// the cover-shades ladder AND the lighting view's colorize-pass
    /// opacity: muted / near-achromatic covers get a mostly-neutral
    /// wall instead of a full-strength low-saturation tint.
    @Published private(set) var matchedMeanSaturation: Double = 0
    @Published private(set) var matchedMeanBrightness: Double = 0
    @Published private(set) var matchedVibrancy: Double = 0
    /// Crossfade origin — the tones rendered at the moment the
    /// target set last changed. `ClubVisLightingView` blends from
    /// here to the current target over
    /// `ClubVisLightingView.setFadeDuration`, so mid-fade changes
    /// continue from the on-screen colours.
    fileprivate var setFadeFrom: ClubVisLightingView.ResolvedTones?
    fileprivate var setFadeStart: Date = .distantPast
    /// Vibrancy crossfade origin — snapshotted alongside
    /// `setFadeFrom` so the colorize-pass opacity lerps on the same
    /// clock as the tones instead of hard-cutting.
    fileprivate var vibrancyFadeFrom: Double?

    /// Publishes a match result. Histogram diagnostics update on
    /// every call — a new cover can produce new readings while
    /// yielding identical tones; only a TONE change starts a
    /// crossfade (a new cover with the same detected hues keeps the
    /// current fade state; any tone change re-snapshots the fade).
    /// Match deferred while a wall rebuild is in flight — committed
    /// instantly at the rebuild's black point. Transition order on a
    /// track change WITH a wall rebuild is: wall fades out under the
    /// EXISTING lighting, the new lighting commits behind the opaque
    /// cover, the wall fades back in already lit by the new scheme.
    /// The 6 s tone crossfade is reserved for track changes without
    /// a rebuild.
    private var pendingRebuildMatch: (index: Int, generated: StageSet?,
                                      dominantHue: Double?, topHues: [Double],
                                      chromaticFraction: Double,
                                      meanSaturation: Double,
                                      meanBrightness: Double)?

    func setMatchedSet(_ index: Int,
                       generated: StageSet? = nil,
                       dominantHue: Double? = nil,
                       topHues: [Double] = [],
                       chromaticFraction: Double = 0,
                       meanSaturation: Double = 0,
                       meanBrightness: Double = 0) {
        if isWallRebuilding {
            visLog("lighting DEFER — match queued behind rebuild (set=\(index))")
            pendingRebuildMatch = (index, generated, dominantHue, topHues,
                                   chromaticFraction, meanSaturation, meanBrightness)
            return
        }
        matchedDominantHue = dominantHue
        matchedTopHues = topHues
        matchedChromaticFraction = chromaticFraction
        let newVibrancy = min(1.0, max(0.0, meanSaturation * meanBrightness))
        let oldTones = (matchedGeneratedSet ?? catalogueSet(matchedSetIndex)).tones
        let newTones = (generated ?? catalogueSet(index)).tones
        // Snapshot BEFORE mutating — beginSetFade resolves the
        // currently rendered tones (and vibrancy) from this state.
        // Vibrancy alone changing (same tones, different cover
        // statistics) also starts a fade so the colorize opacity
        // never hard-cuts.
        if newTones != oldTones || abs(newVibrancy - matchedVibrancy) > 0.01 {
            visLog("lighting FADE begin — tonesChanged=\(newTones != oldTones) vibDelta=\(String(format: "%.3f", abs(newVibrancy - matchedVibrancy))) set=\(index)")
            beginSetFade()
        } else {
            visLog("lighting NO-CHANGE — set=\(index) same tones+vibrancy")
        }
        matchedGeneratedSet = generated
        matchedSetIndex = index
        matchedMeanSaturation = meanSaturation
        matchedMeanBrightness = meanBrightness
        matchedVibrancy = newVibrancy
    }

    /// True when applying this match would change the rendered
    /// tones — the between-songs dip only runs for a real scheme
    /// change.
    func tonesWouldChange(_ index: Int, generated: StageSet?) -> Bool {
        let newTones = (generated ?? catalogueSet(index)).tones
        let oldTones = (matchedGeneratedSet ?? catalogueSet(matchedSetIndex)).tones
        return newTones != oldTones
    }

    /// Instant-commit for the dip path: the lights are dark, so any
    /// in-flight tone crossfade is cancelled — the new scheme must be
    /// fully resolved when they come back up.
    func snapFadeToTarget() {
        setFadeFrom = nil
        vibrancyFadeFrom = nil
        setFadeStart = .distantPast
    }

    /// Black-point commit for the rebuild pipeline: apply any match
    /// deferred during the fade-out and snap the tone/vibrancy fade
    /// to target — the reveal shows the new lighting fully resolved,
    /// with no crossfade running behind the fade-in.
    func commitLightingAtRebuildBlackPoint() {
        visLog("lighting SNAP at black point — pending=\(pendingRebuildMatch != nil)")
        if let p = pendingRebuildMatch {
            pendingRebuildMatch = nil
            matchedDominantHue = p.dominantHue
            matchedTopHues = p.topHues
            matchedChromaticFraction = p.chromaticFraction
            matchedGeneratedSet = p.generated
            matchedSetIndex = p.index
            matchedMeanSaturation = p.meanSaturation
            matchedMeanBrightness = p.meanBrightness
            matchedVibrancy = min(1.0, max(0.0, p.meanSaturation * p.meanBrightness))
        }
        setFadeFrom = nil
        vibrancyFadeFrom = nil
        setFadeStart = .distantPast
    }

    private func catalogueSet(_ index: Int) -> StageSet {
        let sets = ClubStageSets.sets
        return sets.indices.contains(index)
            ? sets[index] : sets[ClubStageSets.fallbackIndex]
    }

    private func beginSetFade() {
        let now = Date().timeIntervalSinceReferenceDate
        setFadeFrom = ClubVisLightingView.resolvedTones(at: now, state: self)
        vibrancyFadeFrom = ClubVisLightingView.resolvedVibrancy(at: now, state: self)
        setFadeStart = Date()
    }

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
            let fps = Double(wallFrameCount) / elapsed
            wallFrameCount = 0
            wallFrameSampleStart = Date()
            // Called from inside a Canvas draw closure — publishing
            // there mutates observable state DURING a view update
            // (undefined re-render behaviour). Defer off the render
            // pass.
            Task { @MainActor in self.wallFps = fps }
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
        /// Darkening pass over wall + lighting — venue-back-wall
        /// brightness target. (Wall saturation is pinned at 0.10 —
        /// not exposed here.)
        var blackMultiplyOpacity: Double = 0.40
    }
    /// URL → metadata snapshot used by the wall view to enrich
    /// slot rows. Updated alongside `poolRows` so the wall doesn't
    /// need access to `playHistoryManager.entries` directly.
    var entryByURL: [String: (title: String, artist: String, album: String)] = [:]
}

// MARK: - Debug companion window UI
//
// Maintainer tuning surface only. `CHORAGUS_DEV` is defined by the
// maintainer's local build configuration and by nothing else, so
// neither a release build nor a fork's build compiles any of this —
// the panel's controls and its English-only labels never reach a user.
#if CHORAGUS_DEV

struct BackOfTheClubDebugWindow: View {
    /// Sector name for a hue in degrees — the vocabulary of the
    /// match narration.
    /// Names aligned with the matcher's colour groups (see
    /// StageSetMatcher.hueGroup) so the narration and the peak
    /// discounting agree — the 30°-sector names called 25° "red".
    static func hueName(_ h: Double) -> String {
        let hn = StageSetMatcher.normalizedHue(h)
        switch StageSetMatcher.hueGroup(hn) {
        case 0: return "red"
        case 1: return hn < 50 ? "orange" : "yellow"
        case 2: return "green"
        case 3: return "teal"
        case 4: return "blue"
        case 5: return "violet"
        default: return "magenta"
        }
    }

    /// Narrates: which scheme is active, what was detected on the
    /// cover, then how the lighting tones were derived from it.
    static func matchExplanation(state: BackOfTheClubDebugState) -> String {
        let scheme: String
        switch state.colourScheme {
        case .choragus:
            scheme = "Scheme: Choragus (Settings) — fixed wordmark neon set; "
                   + "cover matching bypassed. Histogram readings below are "
                   + "informational only. "
        case .custom:
            scheme = "Scheme: Custom (Settings) — user-selected tones; "
                   + "cover matching bypassed. Histogram readings below are "
                   + "informational only. "
        case .albumArt:
            scheme = "Scheme: Album art (Settings default) — tones derive "
                   + "from the current cover. "
        }
        let pct = String(format: "%.1f", state.matchedChromaticFraction * 100)
        if state.matchedTopHues.isEmpty {
            return scheme
                 + "Detected: no usable colour — \(pct)% of sampled pixels are chromatic "
                 + "(black/white/grey are excluded). Below the 0.8% floor the cover is "
                 + "treated as achromatic and the Choragus wordmark scheme is used."
        }
        let peaks = state.matchedTopHues
            .map { String(format: "%.0f° (%@)", $0, hueName($0)) }
            .joined(separator: ", ")
        return scheme
             + "Detected: \(pct)% of sampled pixels are chromatic (black/white/grey "
             + "excluded). Strongest hue peaks, mass-ordered: \(peaks). "
             + "Selection: lighting tones are shade ladders of these detected hues "
             + "only — no hues are added. Colour theory grades the ladder "
             + "(wash deepest, accent brightest), scaled by cover vibrancy."
    }

    @StateObject private var state = BackOfTheClubDebugState.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                contextSection
                packerSection
                swapAndFadeSection
                stageSetSection
                setTemplatesSection
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

    // MARK: - Stage set lighting

    private var stageSetSection: some View {
        GroupBox("Stage set lighting") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Match set from now-playing art",
                       isOn: $state.stageSetLightingEnabled)
                let matched = state.matchedGeneratedSet ?? ClubStageSets.sets[
                    min(max(0, state.matchedSetIndex), ClubStageSets.sets.count - 1)]
                Text(state.matchedGeneratedSet != nil
                        ? "Matched: \(matched.name)"
                        : "Matched: \(matched.id). \(matched.name)")
                    .font(.system(.body, design: .monospaced))
                Text(matched.theoryBasis)
                    .font(.caption).foregroundStyle(.secondary)
                // Plain-language narration of the match pipeline,
                // composed from the live histogram readings.
                Text(Self.matchExplanation(state: state))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // Vibrancy readout — the applied value accounts for
                // the active scheme (fixed schemes pin v = 1).
                Text(String(format: "Vibrancy: cover v=%.2f (mean sat %.2f × mean bri %.2f "
                                  + "of chromatic pixels) — applied v=%.2f, colorize pass "
                                  + "opacity %.2f, glow pass %.2f.",
                            state.matchedVibrancy,
                            state.matchedMeanSaturation,
                            state.matchedMeanBrightness,
                            ClubVisLightingView.targetVibrancy(state: state),
                            ClubVisLightingView.colorizeOpacity(
                                vibrancy: ClubVisLightingView.targetVibrancy(state: state)),
                            ClubVisLightingView.glowOpacity(
                                vibrancy: ClubVisLightingView.targetVibrancy(state: state))))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // Hue-outlier emphasis readout — mirrors the render
                // path's emphasisSlot on the matched set's tones.
                if let emphasis = ClubVisLightingView.emphasisSlot(
                    tones: .init(wash: matched.wash, beamA: matched.beamA,
                                 beamB: matched.beamB, accent: matched.accent)) {
                    Text("Hue outlier: \(String(describing: emphasis.slot)) sits apart from "
                         + "the other three tones — its emitters draw at "
                         + String(format: "%.2f×",
                                  1.0 + (ClubVisLightingView.emphasisBoost - 1.0) * emphasis.weight)
                         + " alpha so the differing colour stays visible.")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Swatches show the ACTIVE set (override / disabled
                // state applied), not necessarily the matched one.
                let active = ClubVisLightingView.targetSet(state: state)
                HStack(spacing: 14) {
                    toneSwatch(label: "wash", tone: active.wash)
                    toneSwatch(label: "beam A", tone: active.beamA)
                    toneSwatch(label: "beam B", tone: active.beamB)
                    toneSwatch(label: "accent", tone: active.accent)
                    Spacer()
                }
                HStack {
                    Text("Override").frame(width: 110, alignment: .leading).font(.caption)
                    Picker("", selection: $state.stageSetOverride) {
                        Text("Auto (matched)").tag(-1)
                        ForEach(ClubStageSets.sets) { set in
                            Text("\(set.id). \(set.name)").tag(set.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 260)
                }
                Text("Set changes crossfade over \(Int(ClubVisLightingView.setFadeDuration)) s. Disabled toggle resolves to set 0 (Zune house); achromatic art resolves to the Choragus scheme.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    private func toneSwatch(label: String, tone: StageTone) -> some View {
        let r = Int((tone.r * 255).rounded())
        let g = Int((tone.g * 255).rounded())
        let b = Int((tone.b * 255).rounded())
        return VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 6)
                .fill(tone.color)
                .frame(width: 96, height: 48)
            Text(label).font(.caption2)
            Text(String(format: "#%02X%02X%02X", r, g, b))
                .font(.system(.caption2, design: .monospaced))
            Text("\(r) \(g) \(b)")
                .font(.system(.caption2, design: .monospaced))
        }
    }

    // MARK: - Set templates

    /// Every declared set in one auditable grid — index, name,
    /// theory basis, four role swatches. Tapping a row pins the set
    /// through the same override binding the picker uses.
    private var setTemplatesSection: some View {
        GroupBox("Set templates (\(ClubStageSets.sets.count))") {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(ClubStageSets.sets) { set in
                        templateRow(set)
                    }
                }
            }
            .frame(maxHeight: 300)
        }
    }

    private func templateRow(_ set: StageSet) -> some View {
        HStack(spacing: 8) {
            Text("\(set.id)")
                .monospacedDigit()
                .frame(width: 26, alignment: .trailing)
            Text(set.name)
                .frame(width: 160, alignment: .leading)
                .lineLimit(1)
            miniSwatch(set.wash)
            miniSwatch(set.beamA)
            miniSwatch(set.beamB)
            miniSwatch(set.accent)
            Text(set.theoryBasis)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(state.stageSetOverride == set.id
                        ? Color.accentColor.opacity(0.18)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture { state.stageSetOverride = set.id }
    }

    private func miniSwatch(_ tone: StageTone) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(tone.color)
            .frame(width: 26, height: 16)
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
        GroupBox("Lighting (live)") {
            VStack(alignment: .leading, spacing: 8) {
                slider("Black multiply", $state.lighting.blackMultiplyOpacity,
                       range: 0...0.95, step: 0.01) { String(format: "%.2f", $0) }
                Button("Reset to default") {
                    state.lighting = BackOfTheClubDebugState.LightingControls()
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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

#endif  // CHORAGUS_DEV
