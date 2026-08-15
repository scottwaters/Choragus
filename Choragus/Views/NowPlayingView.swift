/// NowPlayingView.swift — Main playback control UI for a Sonos group.
///
/// Key design decisions:
/// - **Centralized state**: Reads transport state, volume, and metadata from
///   SonosManager's @Published properties (updated by the active transport strategy).
/// - **Grace period system**: After a user action (play/pause/volume/mode), the manager
///   holds the optimistic state for 5 seconds, ignoring updates from the transport strategy.
/// - **Awaiting playback**: When a new item is played, `awaitingPlayback` is set on
///   SonosManager. Cached artwork and item text display immediately with a loading
///   spinner. The flag clears only when the speaker confirms `.playing` state.
/// - **Smooth progress**: A 0.5s timer interpolates the position bar between server updates
///   so it moves fluidly. After seek/play, position is frozen for 3s until the speaker
///   reports the new position.
/// - **Proportional group volume**: The master slider applies a delta to each speaker,
///   preserving relative volume differences across grouped speakers.
import SwiftUI
import Combine
import AppKit
import SonosKit

struct NowPlayingView: View {
    @EnvironmentObject var sonosManager: SonosManager
    @EnvironmentObject var anchorTracker: AnchorTracker
    @EnvironmentObject var positionTracker: PositionTracker
    /// Forwarded into `NowPlayingContextPanel` so its VM can be
    /// initialised eagerly (services come from the SwiftUI environment
    /// at the App level — `ChoragusApp.swift`).
    @EnvironmentObject var lyricsService: LyricsServiceHolder
    @EnvironmentObject var metadataService: MusicMetadataServiceHolder
    @EnvironmentObject var lyricsCoordinator: LyricsCoordinator
    @State private var vm: NowPlayingViewModel
    @State private var showShuffleHint = false
    let group: SonosGroup

    init(group: SonosGroup, sonosManager: SonosManager, artCoordinator: ArtCoordinator) {
        self.group = group
        _vm = State(wrappedValue: NowPlayingViewModel(
            sonosManager: sonosManager,
            group: group,
            artCoordinator: artCoordinator
        ))
    }

    // Convenience accessors from ViewModel
    private var actionInFlight: String? { vm.actionInFlight }
    private var volume: Double { vm.volume }
    private var isMuted: Bool { vm.isMuted }
    private var speakerVolumes: [String: Double] { vm.speakerVolumes }
    private var speakerMutes: [String: Bool] { vm.speakerMutes }
    private var isDraggingSeek: Bool { vm.isDraggingSeek }
    private var crossfadeOn: Bool { vm.crossfadeOn }
    @State private var showGroupEditor = false
    @State private var showSleepTimer = false
    @State private var showEQ = false
    @State private var showCopied = false
    @State private var showExpandedArt = false
    @State private var showMasterVolumeInput = false
    @State private var showArtSearch = false
    /// Persisted collapse state for the Lyrics / About / History panel.
    /// `false` (default) keeps the panel visible; `true` hides it for
    /// users who prefer the cleaner now-playing-only layout. The
    /// chevron handle on the divider toggles this.
    @AppStorage(UDKey.contextPanelCollapsed) private var contextPanelCollapsed: Bool = false

    // MARK: - Derived State (from ViewModel)

    private var transportState: TransportState { vm.transportState }
    private var trackMetadata: TrackMetadata { vm.trackMetadata }
    private var playMode: PlayMode { vm.playMode }
    private var hasTrack: Bool { vm.hasTrack }

    private var awaitingPlayback: Bool { vm.awaitingPlayback }
    private var currentServiceName: String? { vm.currentServiceName }
    private var displayArtist: String { vm.displayArtist }

    /// Show the Lyrics/About/History panel whenever there's a real
    /// track to look up. Hides for empty states, ad breaks, and the
    /// "TV" / "Line-In" stream titles where there's nothing useful for
    /// LRCLIB or the metadata service to find.
    ///
    /// Artist is *not* required: some Sonos favorites deliver a track
    /// with an empty artist field (the album name lands in the artist
    /// slot or the artist is dropped entirely). In those cases the
    /// LyricsService falls back to a title-only search and the About
    /// tab queries the album, so showing the panel still beats hiding
    /// it — empty results render as "No lyrics found" / "No info found"
    /// instead of an unexplained missing UI.
    private var shouldShowContextPanel: Bool {
        guard hasTrack else { return false }
        if trackMetadata.isAdBreak { return false }
        let title = trackMetadata.title
        if title == "TV" || title == "Line-In" { return false }
        return !trackMetadata.title.isEmpty
    }

    /// Divider with a centred chevron that toggles `contextPanelCollapsed`.
    /// Replaces the plain `Divider()` so users can hide the lower panel.
    private var contextPanelDivider: some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(height: 1)
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    contextPanelCollapsed.toggle()
                }
            } label: {
                Image(systemName: contextPanelCollapsed ? "chevron.down" : "chevron.up")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(contextPanelCollapsed ? L10n.showLyricsAboutHistory : L10n.hideLyricsAboutHistory)
            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(height: 1)
        }
        .padding(.top, 8)
        .padding(.horizontal, 8)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Wraps the playback controls + speaker volumes — the
                // section where mouse-wheel volume control makes sense.
                // The context panel below sits OUTSIDE this group so
                // scroll events over Lyrics/About/History scroll the
                // panel content instead of changing volume.
                playbackSection
                    .volumeScrollControl(
                        onVolumeStep: { vm.applyScrollVolumeStep($0) },
                        onToggleMute: { vm.toggleMute() }
                    )

                // Lyrics / About / History — fills the otherwise-empty
                // space below the speaker volumes when the user has a
                // track playing. Hidden for radio/empty states. The
                // chevron on the divider toggles between expanded and
                // collapsed; the collapsed state is persisted.
                if shouldShowContextPanel {
                    contextPanelDivider
                    if !contextPanelCollapsed {
                        NowPlayingContextPanel(
                            trackMetadata: trackMetadata,
                            group: group,
                            positionAnchor: vm.positionAnchor,
                            lyricsCoordinator: lyricsCoordinator,
                            metadataService: metadataService.service
                        )
                        // 260pt = tab picker (~36) + divider (1) +
                        // padding (~16) + 5-row × 34pt lyrics (170) +
                        // breathing room. Matches what
                        // `SlidingLyricsView` actually wants so the
                        // bottom of the gradient mask isn't clipped.
                        .frame(maxWidth: .infinity, minHeight: 260)
                        .padding(.top, 4)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tint(sonosManager.resolvedAccentColor)
        // AVTransport `LastChange` events deliberately exclude
        // `RelativeTimePosition`, so seek-bar position needs a poll.
        .onChange(of: trackMetadata.trackURI) {
            // Fixed-output isn't static (e.g. line-in source vs own track) —
            // re-check when the source changes so "Fixed Volume" appears/clears.
            Task { await sonosManager.ensureFixedOutputChecked(for: group) }
        }
        .task(id: group.id) {
            await sonosManager.ensureFixedOutputChecked(for: group)
            await fetchCurrentState()
            // A speaker sitting at 100% is a Fixed-output tell — re-verify now
            // that the volume state has loaded, so "Fixed Volume" shows on open.
            if vm.volume >= 100 {
                await sonosManager.ensureFixedOutputChecked(for: group)
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Timing.activePositionPolling))
                guard !Task.isCancelled else { return }
                await vm.pollActivePosition()
                // Re-poll fixed-output so a Fixed↔Variable change made in the
                // Sonos app while this view is open is reflected live (only
                // touches line-out models; others no-op).
                await sonosManager.ensureFixedOutputChecked(for: group)
            }
        }
        .onChange(of: group.id) {
            vm.group = group
            // No `vm.art.reset()` — resolvers live in the shared
            // `ArtCoordinator` registry and their state IS the per-
            // group art memory. Resetting the destination resolver
            // wipes its `displayedArtURL` and the coordinator's
            // dedup gate then prevents a re-fire until the next
            // track change, stranding the hero with the default icon.
            vm.resetForGroupChange()
        }
        .onChange(of: group.members.map(\.id)) {
            vm.group = group
        }
        // Volume / mute / track-metadata views read directly from
        // `sonosManager` via the VM's computed properties, so the prior
        // `.onReceive($deviceVolumes)` / `.onReceive($deviceMutes)` /
        // `.onReceive($groupTrackMetadata)` re-sync hooks are gone.
        // SwiftUI's @Observable / @EnvironmentObject machinery handles
        // invalidation automatically, and there's no longer a local
        // mirror to drift out of sync with the manager's authoritative
        // dictionaries — which removes the race window where a coord
        // event's optimistic propagation to a member dropped on the
        // floor until the next unrelated publish woke `.onReceive`.
        .sheet(isPresented: $showGroupEditor) {
            GroupEditorView(initialGroup: group)
                .environmentObject(sonosManager)
        }
        .sheet(isPresented: $showSleepTimer) {
            SleepTimerView(group: group)
                .environmentObject(sonosManager)
        }
        .sheet(isPresented: $showExpandedArt) {
            ExpandedArtView(
                artURL: vm.art.radioTrackArtURL ?? vm.art.displayedArtURL,
                title: trackMetadata.title,
                artist: trackMetadata.artist,
                album: trackMetadata.album,
                stationName: trackMetadata.stationName
            )
        }
    }

    /// The playback section — extracted so we can attach
    /// `volumeScrollControl` to just this part. The context panel
    /// below uses its own ScrollViews internally; we don't want our
    /// scroll-wheel capture stealing events from there.
    private var playbackSection: some View {
        choragusWatermarkBackground {
            playbackSectionContent
        }
    }

    /// Wraps content with the Choragus logo as a top-right watermark.
    ///
    /// At wide window sizes the watermark mirrors the album art's
    /// dimensions on the left (`UILayout.nowPlayingArtSize`). As the
    /// Now Playing panel narrows the watermark shrinks AND drifts
    /// further down-and-right so it gets out of the way of the
    /// transport controls / volume sliders that are now competing for
    /// the same horizontal real estate. Linear interpolation between
    /// `Self.watermarkUpperWidth` (full size) and `Self.watermarkLowerWidth`
    /// (min size). Inert (no hit testing) and rendered as `.background`
    /// so it sits behind content without disturbing layout.
    @ViewBuilder
    private func choragusWatermarkBackground<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .background {
                GeometryReader { geo in
                    let layout = Self.watermarkLayout(forWidth: geo.size.width)
                    Image("ChoragusLogo")
                        .resizable()
                        .interpolation(.high)
                        .frame(width: layout.size, height: layout.size)
                        .opacity(0.18)
                        .padding(.top, layout.topInset)
                        .padding(.trailing, UILayout.horizontalPadding)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
                .allowsHitTesting(false)
            }
    }

    /// Watermark size + top inset for a given panel width. At
    /// `watermarkUpperWidth` and above: full album-art size. At
    /// `watermarkLowerWidth` and below: minimum size and a deeper top
    /// inset (so the smaller icon sits lower, freeing the band right
    /// of the album art for transport controls). Linear in between.
    private static let watermarkUpperWidth: CGFloat = 900
    private static let watermarkLowerWidth: CGFloat = 500
    private static let watermarkMinSize: CGFloat = 60

    private static func watermarkLayout(forWidth width: CGFloat) -> (size: CGFloat, topInset: CGFloat) {
        let maxSize = UILayout.nowPlayingArtSize
        let minSize = watermarkMinSize
        let size: CGFloat
        if width >= watermarkUpperWidth {
            size = maxSize
        } else if width <= watermarkLowerWidth {
            size = minSize
        } else {
            let t = (width - watermarkLowerWidth) / (watermarkUpperWidth - watermarkLowerWidth)
            size = minSize + t * (maxSize - minSize)
        }
        // Top inset slides from 12 pt (full size) to 30 pt (min size).
        let topInset: CGFloat = 12 + (maxSize - size) * 0.15
        return (size, topInset)
    }

    private var playbackSectionContent: some View {
        VStack(spacing: 0) {
                // Album art and track info
                HStack(spacing: 24) {
                    if hasTrack {
                        albumArtView
                            .frame(width: UILayout.nowPlayingArtSize, height: UILayout.nowPlayingArtSize)
                            .onTapGesture { showExpandedArt = true }
                    } else if awaitingPlayback {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.quaternary)
                            .overlay {
                                ProgressView()
                                    .controlSize(.regular)
                            }
                            .frame(width: UILayout.nowPlayingArtSize, height: UILayout.nowPlayingArtSize)
                    } else {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.quaternary)
                            .overlay {
                                Image(systemName: "music.note")
                                    .font(.system(size: 40))
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(width: UILayout.nowPlayingArtSize, height: UILayout.nowPlayingArtSize)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        // Station name for radio/streams
                        if !trackMetadata.stationName.isEmpty {
                            HStack(spacing: 6) {
                                Label(trackMetadata.stationName, systemImage: "antenna.radiowaves.left.and.right")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                if awaitingPlayback && !transportState.isPlaying {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }
                        }

                        // Show track title only if it's different from the station name
                        let showTitle = !trackMetadata.title.isEmpty &&
                            trackMetadata.title.lowercased() != trackMetadata.stationName.lowercased()
                        if showTitle {
                            HStack(spacing: 8) {
                                MarqueeText(
                                    text: trackMetadata.title,
                                    font: trackMetadata.stationName.isEmpty ? .title2 : .title3,
                                    fontWeight: .semibold
                                )
                                if awaitingPlayback && trackMetadata.stationName.isEmpty {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }
                        } else if trackMetadata.stationName.isEmpty && awaitingPlayback {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(L10n.loading)
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                            }
                        } else if trackMetadata.stationName.isEmpty {
                            Text(L10n.noTrack)
                                .font(.title2)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                        }

                        if hasTrack {
                            if !displayArtist.isEmpty {
                                MarqueeText(
                                    text: displayArtist,
                                    font: .title3,
                                    foregroundStyle: AnyShapeStyle(.secondary)
                                )
                            }

                            if !trackMetadata.album.isEmpty {
                                Text(trackMetadata.album)
                                    .font(.body)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }

                            // Format badges on one line, service tag on the
                            // line below — the Club Vis wall card stacks
                            // format details above the source label, and the
                            // two surfaces should read the same way. The
                            // pill border, the service icon below it, and
                            // the title/artist/album text all share one
                            // leading edge.
                            HStack(spacing: 8) {
                                // Dolby Atmos badge — fires only when the
                                // speaker is reporting an Atmos stream
                                // (`r:streamInfo` d:1) AND the group's
                                // coordinator is Atmos-capable. Apple
                                // Spatial Audio rides the same E-AC3-JOC
                                // carrier, so this badge covers both
                                // modes on Apple Music.
                                if trackMetadata.audioFormat == .atmos,
                                   group.isAtmosCapable(devices: sonosManager.devices) {
                                    Label(L10n.audioFormatAtmos,
                                          systemImage: "hifispeaker.and.homepod")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, UILayout.badgePillInset)
                                        .padding(.vertical, 2)
                                        .background(
                                            RoundedRectangle(cornerRadius: 4)
                                                .strokeBorder(.secondary.opacity(0.35),
                                                              lineWidth: 1)
                                        )
                                        .help(L10n.audioFormatAtmos)
                                }
                                // TV / HDMI format pill — separate from
                                // the streaming Atmos badge above. Only
                                // fires for HDMI / line-in track URIs and
                                // only when we've recognised the integer
                                // bitfield. Unknown values fall through
                                // silently rather than guess.
                                if let tvFormatLabel = tvAudioFormatLabel(trackMetadata) {
                                    Label(tvFormatLabel, systemImage: "tv")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, UILayout.badgePillInset)
                                        .padding(.vertical, 2)
                                        .background(
                                            RoundedRectangle(cornerRadius: 4)
                                                .strokeBorder(.secondary.opacity(0.35),
                                                              lineWidth: 1)
                                        )
                                        .help(tvFormatLabel)
                                }
                                // Stream-details pill for normal audio —
                                // container, lossless flag, and bit
                                // depth / sample rate as reported by the
                                // speaker. Absent evidence renders no
                                // pill; nothing is guessed.
                                if let streamDetails = trackMetadata.streamDetailsLabel {
                                    Label(streamDetails, systemImage: "waveform")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, UILayout.badgePillInset)
                                        .padding(.vertical, 2)
                                        .background(
                                            RoundedRectangle(cornerRadius: 4)
                                                .strokeBorder(.secondary.opacity(0.35),
                                                              lineWidth: 1)
                                        )
                                        .help(streamDetails)
                                }
                            }

                            if let serviceName = currentServiceName {
                                Label(serviceName, systemImage: ServiceName.icon(for: serviceName))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text(L10n.nothingPlaying)
                                .font(.body)
                                .foregroundStyle(.tertiary)
                        }

                        Spacer()

                        HStack(spacing: 12) {
                            Button { showGroupEditor = true } label: {
                                Label(L10n.group, systemImage: "rectangle.stack")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button { showSleepTimer = true } label: {
                                Label(L10n.sleep, systemImage: "moon.zzz")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button {
                                // Read `htSatChannelMaps` authoritatively
                                // from the speaker on each click rather
                                // than trusting whatever the last
                                // topology refresh happened to leave
                                // cached. The map drifts across topology
                                // changes / regrouping / sub-add/remove,
                                // and a stale read here was sending the
                                // user into the surround-sound EQ for a
                                // stereo speaker (or vice-versa). One
                                // `GetZoneGroupState` SOAP per click is
                                // cheap (~17 ms after the XML-parse
                                // off-main fix) and removes the race.
                                Task {
                                    if let coordinator = group.coordinator {
                                        await sonosManager.refreshTopology(from: coordinator, force: true)
                                    }
                                    if sonosManager.htSatChannelMaps[group.coordinatorID] != nil {
                                        WindowManager.shared.openHomeTheaterEQ()
                                    } else {
                                        showEQ = true
                                    }
                                }
                            } label: {
                                Label(L10n.eq, systemImage: "slider.horizontal.3")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .popover(isPresented: $showEQ) {
                                EQView(group: group)
                                    .environmentObject(sonosManager)
                            }

                            if hasTrack {
                                Button { copyTrackInfo() } label: {
                                    Label(showCopied ? L10n.copied : L10n.copyTrackInfo, systemImage: showCopied ? "checkmark" : "doc.on.doc")
                                        .font(.caption)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                                Button { starCurrentTrack() } label: {
                                    Image(systemName: isCurrentTrackStarred ? "star.fill" : "star")
                                        .font(.caption)
                                        .foregroundStyle(isCurrentTrackStarred ? .yellow : .secondary)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .tooltip(isCurrentTrackStarred ? L10n.statStarred : L10n.starThisTrack)
                            }
                        }

                        // Home-theatre-only second row: the two settings
                        // that get toggled nightly, otherwise buried in
                        // the EQ window (#78). Renders nothing for
                        // non-HT zones.
                        HomeTheaterQuickControls(group: group)
                            .environmentObject(sonosManager)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(24)

                Divider()

                // Time/seek area — fixed height to prevent layout shift.
                //
                // 10 Hz `TimelineView` projects `vm.positionAnchor` so
                // the seek-bar value and time text advance smoothly. The
                // earlier `.animation` schedule (60/120 Hz at display
                // refresh) was the per-frame culprit behind karaoke
                // window jitter — `Slider` re-binds at every tick, which
                // saturates the main thread enough to starve the karaoke
                // popout's `TimelineView`. 10 Hz is visually smooth for a
                // slowly-advancing seek bar and frees ~50 frames/sec of
                // main-thread budget for other windows.
                //
                // While the user is dragging the slider, the binding
                // reads `vm.dragPosition` instead of the projection so
                // their drag isn't fought by per-frame projection
                // updates. On drag-end, `seekToPosition` updates the
                // anchor, which the projection picks up immediately.
                VStack(spacing: 4) {
                    SeekBarRow(
                        vm: vm,
                        durationSeconds: trackMetadata.duration,
                        transportIsActive: transportState.isActive,
                        durationString: trackMetadata.durationString,
                        formatTime: formatTime,
                        onDragStart: {
                            sonosManager.setPositionDragInProgress(coordinatorID: group.coordinatorID)
                        },
                        onDragEnd: { pos in
                            sonosManager.setPositionDragInProgress(coordinatorID: nil)
                            seekToPosition(pos)
                        }
                    )
                }
                .padding(.horizontal, UILayout.horizontalPadding)
                .padding(.top, 12)

                // Transport controls — play/pause centered above volume slider center
                HStack(spacing: 24) {
                    // Left side: shuffle + previous
                    HStack(spacing: 24) {
                        if UserDefaults.standard.bool(forKey: UDKey.classicShuffleEnabled) {
                            transportButton("shuffle", icon: "shuffle", size: .body,
                                            tint: playMode.isShuffled ? (sonosManager.resolvedAccentColor ?? .accentColor) : .secondary) {
                                toggleShuffle()
                            }
                            .tooltip(L10n.shuffle)
                        } else {
                            Image(systemName: "shuffle")
                                .font(.body)
                                .foregroundStyle(.tertiary)
                                .frame(minWidth: 32, minHeight: 32)
                                .contentShape(Rectangle())
                                .onTapGesture { showShuffleHint = true }
                                .popover(isPresented: $showShuffleHint, arrowEdge: .bottom) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(L10n.shuffleDisabledTitle)
                                            .font(.caption)
                                            .fontWeight(.semibold)
                                        Text(L10n.shuffleDisabledBody)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .frame(width: 240)
                                    .padding(12)
                                }
                        }

                        // `backward.end.fill` is SF Symbols' "skip to
                        // previous track" glyph (triangle + tape-head
                        // line). The earlier `backward.fill` reads as
                        // rewind/scrub, which is the wrong metaphor —
                        // Sonos treats this control as a hard track-to-
                        // track jump, not a continuous seek.
                        transportButton("previous", icon: "backward.end.fill", size: .title2) {
                            performAction("previous") { try await sonosManager.previous(group: group) }
                        }
                        .tooltip(L10n.previous)
                        // Queue playback supports next/prev regardless of any
                        // station metadata that might be piggybacked on the
                        // track (some service tracks carry a stationName value
                        // from the music provider that doesn't mean "radio").
                        // Disable only when we're in a non-queue radio/stream
                        // context where next/prev aren't meaningful.
                        .disabled(!trackMetadata.isQueueSource &&
                                  (trackMetadata.isRadioStream || !trackMetadata.stationName.isEmpty))
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)

                    // Center: play/pause
                    transportButton("playPause",
                                    icon: transportState.isPlaying ? "pause.circle.fill" : "play.circle.fill",
                                    size: .system(size: 44)) {
                        togglePlayPause()
                    }
                    .tooltip(transportState.isPlaying ? L10n.pause : L10n.play)
                    .keyboardShortcut(.space, modifiers: [])

                    // Right side: next + 15s/30s seek + repeat + crossfade
                    HStack(spacing: 24) {
                        // `forward.end.fill` mirrors `backward.end.fill` —
                        // the SF Symbols pair Apple uses everywhere for
                        // skip-to-next / skip-to-previous track. Sonos's
                        // semantics match (hard track-to-track jump).
                        transportButton("next", icon: "forward.end.fill", size: .title2) {
                            performAction("next") { try await sonosManager.next(group: group) }
                        }
                        .tooltip(L10n.next)
                        // Queue playback supports next/prev regardless of any
                        // station metadata that might be piggybacked on the
                        // track (some service tracks carry a stationName value
                        // from the music provider that doesn't mean "radio").
                        // Disable only when we're in a non-queue radio/stream
                        // context where next/prev aren't meaningful.
                        .disabled(!trackMetadata.isQueueSource &&
                                  (trackMetadata.isRadioStream || !trackMetadata.stationName.isEmpty))

                        transportButton("repeat", icon: repeatIcon, size: .body,
                                        tint: playMode.repeatMode != .off ? (sonosManager.resolvedAccentColor ?? .accentColor) : .secondary) {
                            cycleRepeat()
                        }
                        .tooltip(L10n.repeat_)

                        transportButton("crossfade", icon: "arrow.triangle.swap", size: .caption,
                                        tint: crossfadeOn ? (sonosManager.resolvedAccentColor ?? .accentColor) : .secondary) {
                            toggleCrossfade()
                        }
                        .tooltip(L10n.crossfade)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, 16)
                .padding(.leading, UILayout.horizontalPadding)
                .padding(.trailing, UILayout.horizontalPadding + 8)
                // 8pt extra trailing padding shifts the symmetric
                // content (and therefore the centred play button)
                // 4pt left — matches the master volume row whose
                // slider centre sits 4pt left of the bare-padding
                // centre because the trailing value label + spacing
                // (28 + 12 = 40pt) is 8pt wider than the leading
                // mute icon + spacing (20 + 12 = 32pt). Keeps the
                // play button aligned with the master slider centre.

                // In-track seek row — same outer column structure as the
                // main transport row above, so each seek pair straddles
                // the prev / next icon: -30 sits outside, -15 sits in
                // the centre column, putting prev visually between the
                // two buttons. Symmetric on the forward side. Smaller
                // visual weight via .footnote sizing keeps the main
                // transport dominant.
                HStack(spacing: 24) {
                    HStack(spacing: 0) {
                        Spacer()
                        transportButton("skipBack30", icon: "gobackward.30", size: .footnote) {
                            vm.seekRelative(by: -30)
                        }
                        .tooltip(L10n.skipBack30)
                        .disabled(!trackMetadata.isQueueSource &&
                                  (trackMetadata.isRadioStream || !trackMetadata.stationName.isEmpty))
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)

                    HStack(spacing: 24) {
                        transportButton("skipBack15", icon: "gobackward.15", size: .footnote) {
                            vm.seekRelative(by: -15)
                        }
                        .tooltip(L10n.skipBack15)
                        .disabled(!trackMetadata.isQueueSource &&
                                  (trackMetadata.isRadioStream || !trackMetadata.stationName.isEmpty))

                        // 44pt empty matches the play button's centred
                        // width above, keeping the symmetric column.
                        Color.clear.frame(width: 44, height: 1)

                        transportButton("skipForward15", icon: "goforward.15", size: .footnote) {
                            vm.seekRelative(by: 15)
                        }
                        .tooltip(L10n.skipForward15)
                        .disabled(!trackMetadata.isQueueSource &&
                                  (trackMetadata.isRadioStream || !trackMetadata.stationName.isEmpty))
                    }

                    HStack(spacing: 0) {
                        transportButton("skipForward30", icon: "goforward.30", size: .footnote) {
                            vm.seekRelative(by: 30)
                        }
                        .tooltip(L10n.skipForward30)
                        .disabled(!trackMetadata.isQueueSource &&
                                  (trackMetadata.isRadioStream || !trackMetadata.stationName.isEmpty))
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, 4)
                .padding(.bottom, 12)
                .padding(.leading, UILayout.horizontalPadding)
                .padding(.trailing, UILayout.horizontalPadding + 8)
                // Matches the main transport row's asymmetric trailing
                // padding so the symmetric central column (the −15 /
                // empty spacer / +15 group) stays vertically aligned
                // with the play button above it.
                .frame(maxWidth: .infinity)

                // Volume — master row + per-speaker rows share an alignment
                // column so the slider centres line up vertically. Master
                // is the position anchor (untouched); sub rows shift to
                // match via `.sliderCenter` alignment guides.
                VStack(alignment: .sliderCenter, spacing: 6) {
                HStack(spacing: 12) {
                    Button { toggleMute() } label: {
                        Image(systemName: isMuted ? "speaker.slash.fill" : volumeIcon)
                            .frame(width: 20)
                    }
                    .buttonStyle(.plain)

                    SliderWithPopup(
                        value: Binding(
                            get: { vm.volume },
                            set: { newValue in
                                // `applyMasterVolume` distributes the new
                                // master to each member proportionally /
                                // linearly and writes straight into
                                // `sonosManager.deviceVolumes`. The per-row
                                // sliders read from there on the next
                                // render — no local-mirror copy step.
                                // SOAP commit still deferred to drag-end.
                                vm.applyMasterVolume(newValue)
                            }
                        ),
                        range: 0...100,
                        // Render the master track 1.4× as thick as the
                        // per-speaker rows. The scale is applied inside
                        // `SliderWithPopup` against the bare slider only,
                        // so the floating value popup keeps its native
                        // proportions.
                        trackScaleY: 1.4
                    ) { editing in
                        vm.isDraggingVolume = editing
                        if !editing {
                            vm.commitVolume()
                        }
                    }
                    .frame(maxWidth: 300)
                    .alignmentGuide(.sliderCenter) { d in d[HorizontalAlignment.center] }
                    // Fixed line-out (Connect/Port/Amp): the whole group's
                    // volume can't be changed — disable the master so it doesn't
                    // look adjustable while SetVolume is silently skipped (#50).
                    .disabled(groupVolumeFixed)
                    .help(groupVolumeFixed ? L10n.fixedLineOutVolume : "")
                    .overlay {
                        if groupVolumeFixed {
                            Text(L10n.fixedVolume)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .background(.regularMaterial, in: Capsule())
                        }
                    }
                    // Explicit tint — the outer ScrollView tint can fall through
                    // to the system accent when resolvedAccentColor is nil, which
                    // loses the user's customization on the main volume slider.
                    .tint(sonosManager.resolvedAccentColor ?? .accentColor)

                    Text("\(Int(volume))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 28, alignment: .trailing)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { showMasterVolumeInput = true }
                        .help(L10n.doubleClickToTypeValue)
                        .popover(isPresented: $showMasterVolumeInput, arrowEdge: .top) {
                            VolumeNumberInputPopover(
                                initialValue: Int(volume),
                                onCommit: { newVal in
                                    vm.applyMasterVolume(Double(newVal))
                                    vm.commitVolume()
                                    showMasterVolumeInput = false
                                },
                                onCancel: { showMasterVolumeInput = false }
                            )
                        }
                }
                .padding(.horizontal, UILayout.horizontalPadding)

                // Per-speaker volumes for grouped speakers
                if group.members.count > 1 {
                    VolumeControlView(group: group,
                                      speakerVolumes: Binding(
                                          get: { vm.speakerVolumes },
                                          set: { newDict in
                                              // Per-row slider drag writes
                                              // straight into the manager
                                              // (optimistic) and schedules
                                              // a throttled mid-drag SOAP
                                              // per device — at most one
                                              // commit every 250 ms while
                                              // the slider is moving, so
                                              // other listeners hear
                                              // progressive change without
                                              // hammering the speaker.
                                              for (id, v) in newDict {
                                                  let current = sonosManager.deviceVolumes[id] ?? 0
                                                  let target = Int(v)
                                                  if target != current {
                                                      sonosManager.updateDeviceVolume(id, volume: target)
                                                      if let member = group.members.first(where: { $0.id == id }) {
                                                          vm.scheduleThrottledSpeakerCommit(device: member, volume: target)
                                                      }
                                                  }
                                              }
                                          }
                                      ),
                                      speakerMutes: Binding(
                                          get: { vm.speakerMutes },
                                          set: { newDict in
                                              for (id, m) in newDict {
                                                  let current = sonosManager.deviceMutes[id] ?? false
                                                  if m != current {
                                                      sonosManager.updateDeviceMute(id, muted: m)
                                                  }
                                              }
                                          }
                                      ),
                                      accentColor: sonosManager.resolvedAccentColor ?? .accentColor,
                                      fixedDeviceIDs: sonosManager.fixedOutputDeviceIDs,
                                      onSetVolume: { device, vol in await vm.setSpeakerVolume(device: device, volume: vol) },
                                      onToggleMute: { device, muted in await vm.setSpeakerMute(device: device, muted: muted) })
                    // `vm.isDraggingVolume` gates the master's drag-
                    // scratchpad — irrelevant during a sub drag.
                }
                } // VStack(alignment: .sliderCenter)

        }
    }

    // MARK: - Transport Button

    @ViewBuilder
    private func transportButton(_ id: String, icon: String, size: Font,
                                  tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            ZStack {
                Image(systemName: icon)
                    .font(size)
                    .foregroundStyle(tint ?? .primary)
                    .opacity(actionInFlight == id ? 0.3 : 1)

                if actionInFlight == id {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(minWidth: 32, minHeight: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(actionInFlight != nil)
    }


    // MARK: - Album Art (layout in view, logic in ViewModel)

    private var albumArtView: some View {
        // Resolve the URL once so `.id` and `.animation` observe the
        // same Optional<URL> rather than re-invoking the resolver per
        // modifier. Crossfade is driven by the value-based animation
        // attached at the end of the ZStack.
        let resolvedURL = vm.art.artURLForDisplay(trackMetadata: trackMetadata)
        return ZStack(alignment: .bottomTrailing) {
            if let url = resolvedURL {
                CachedAsyncImage(url: url, cornerRadius: 8, priority: .interactive)
                    // `.id(url)` makes SwiftUI treat each new URL as a
                    // view replacement, which lets `.transition(.opacity)`
                    // crossfade between the old and new art instead of
                    // snapping.
                    .id(url)
                    .transition(.opacity)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        LinearGradient(
                            colors: [.purple.opacity(0.3), .blue.opacity(0.3)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        Image(systemName: !trackMetadata.stationName.isEmpty ? "radio.fill" : "music.note")
                            .font(.system(size: 48))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .transition(.opacity)
            }
            // Station-art mini badge on the bottom-right of the album art is
            // disabled — its resolution heuristic is flaky and it was flickering.
            // Leaving the shouldShowStationBadge/radioStationArtURL APIs in place
            // so this can be re-enabled with one-line change when fixed.
            // if vm.art.shouldShowStationBadge(trackMetadata: trackMetadata),
            //    let stationArt = vm.art.radioStationArtURL {
            //     CachedAsyncImage(url: stationArt, cornerRadius: 4)
            //         .frame(width: 36, height: 36)
            //         .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
            //         .padding(6)
            // }
        }
        .animation(.easeInOut(duration: 0.4), value: resolvedURL)
        .onAppear {
            vm.onArtAppear()
        }
        .onReceive(sonosManager.$groupTrackMetadata) { newMeta in
            let meta = newMeta[group.coordinatorID] ?? TrackMetadata()
            vm.handleMetadataChanged(meta)
        }
            .contextMenu {
                Button(L10n.searchArtwork) {
                    showArtSearch = true
                }
                Button(L10n.refreshArtwork) {
                    vm.art.forceITunesArtSearch(trackMetadata: trackMetadata, displayArtist: vm.displayArtist, group: group)
                }
                Divider()
                Button(L10n.ignoreArtwork) {
                    vm.art.ignoreArtwork(trackMetadata: trackMetadata)
                }
                if vm.art.webArtURL != nil || vm.art.isArtIgnored || trackMetadata.albumArtURI != nil {
                    Button(L10n.clearArtwork) {
                        let searchTerm = vm.art.artOverrideKey(trackMetadata: trackMetadata)
                        if !searchTerm.isEmpty {
                            UserDefaults.standard.removeObject(forKey: "\(UDKey.artOverridePrefix)\(searchTerm.lowercased())")
                        }
                        vm.art.isArtIgnored = false
                        vm.art.webArtURL = nil
                        vm.art.lastArtSearchKey = ""
                        vm.art.forceWebArt = false
                        // Clearing is an explicit reset — let the next
                        // metadata tick re-run the search for this track.
                        vm.art.invalidateArtResolution(for: trackMetadata)
                        vm.art.updateDisplayedArt(trackMetadata: trackMetadata, group: group)
                    }
                }
            }
            .sheet(isPresented: $showArtSearch) {
                ArtworkSearchView(
                    artist: vm.displayArtist,
                    title: trackMetadata.title,
                    album: trackMetadata.album
                ) { selectedURL in
                    vm.art.setManualArtwork(selectedURL, trackMetadata: trackMetadata, group: group)
                    // Propagate the manual choice into the shared art
                    // cache so every other view (karaoke window, club
                    // vis, browse rows) picks up the new URL instead of
                    // sticking on whatever Sonos / iTunes resolved
                    // automatically. ArtResolver only owns the
                    // now-playing display; `artCache` is what the rest
                    // of the app reads through `lookupCachedArt`.
                    let uri = trackMetadata.trackURI ?? ""
                    sonosManager.cacheArtURL(
                        selectedURL,
                        forURI: uri,
                        title: trackMetadata.title,
                        itemID: ""
                    )
                    showArtSearch = false
                }
            }
    }

    // MARK: - Helpers (delegated to ViewModel)

    private var volumeIcon: String { vm.volumeIcon }

    /// True when every member of the group has a fixed line-out, so the group
    /// (master) volume can't be changed at all (#50).
    private var groupVolumeFixed: Bool {
        !group.members.isEmpty &&
            group.members.allSatisfy { sonosManager.fixedOutputDeviceIDs.contains($0.id) }
    }
    private var repeatIcon: String { vm.repeatIcon }
    /// Localised label for the HDMI / line-in audio format pill. Returns
    /// nil when the track isn't an HDMI / line-in source or the speaker
    /// hasn't classified the format yet — in either case the pill is
    /// suppressed so we never show a stale or guessed label.
    private func tvAudioFormatLabel(_ metadata: TrackMetadata) -> String? {
        guard let uri = metadata.trackURI else { return nil }
        let isHTSource = uri.contains("x-sonos-htastream:") || uri.contains("x-rincon-stream:")
        guard isHTSource else { return nil }
        return metadata.tvAudioFormat.displayLabel
    }

    private func formatTime(_ interval: TimeInterval) -> String { vm.formatTime(interval) }

    // MARK: - Actions (delegated to ViewModel)

    private func togglePlayPause() { vm.togglePlayPause() }
    private func seekToPosition(_ seconds: TimeInterval) { vm.seekToPosition(seconds) }
    private func toggleMute() { vm.toggleMute() }

    private func commitVolume() { vm.commitVolume() }
    private func showVolumePending() { /* handled by ViewModel */ }
    private func clearVolumePending() { /* handled by ViewModel */ }

    private func toggleShuffle() { vm.toggleShuffle() }
    private func cycleRepeat() { vm.cycleRepeat() }
    private func toggleCrossfade() { vm.toggleCrossfade() }
    private func copyTrackInfo() {
        vm.copyTrackInfo()
        showCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Timing.toastDismiss) { showCopied = false }
    }

    private func starCurrentTrack() {
        guard !trackMetadata.title.isEmpty,
              let manager = sonosManager.playHistoryManager else { return }
        // Find the most recent matching entry and toggle its star
        if let entry = manager.entries.last(where: {
            $0.title == trackMetadata.title && $0.artist == trackMetadata.artist
        }) {
            manager.toggleStar(id: entry.id)
        }
    }

    private var isCurrentTrackStarred: Bool {
        guard !trackMetadata.title.isEmpty else { return false }
        return sonosManager.playHistoryManager?.isStarred(
            title: trackMetadata.title,
            artist: trackMetadata.artist
        ) ?? false
    }

    private func performAction(_ id: String, _ action: @escaping () async throws -> Void) {
        vm.performAction(id, action)
    }

    // MARK: - State Fetch (delegated to ViewModel)

    private func fetchCurrentState() async { await vm.fetchCurrentState() }
}

// MARK: - Expanded Art View

struct ExpandedArtView: View {
    let artURL: URL?
    let title: String
    let artist: String
    let album: String
    let stationName: String
    /// Optional gallery for carousel paging (artist About photos).
    /// With more than one URL, chevron buttons and the arrow keys
    /// page through the set; empty at single-image call sites.
    var galleryURLs: [URL] = []
    @Environment(\.dismiss) private var dismiss
    @State private var galleryIndex: Int = 0

    private var showsCarousel: Bool { galleryURLs.count > 1 }
    private var displayedURL: URL? {
        showsCarousel
            ? galleryURLs[min(max(galleryIndex, 0), galleryURLs.count - 1)]
            : artURL
    }

    private func stepGallery(_ delta: Int) {
        let n = galleryURLs.count
        guard n > 1 else { return }
        galleryIndex = ((galleryIndex + delta) % n + n) % n
    }

    private func carouselButton(_ symbol: String, delta: Int,
                                key: KeyEquivalent) -> some View {
        Button { stepGallery(delta) } label: {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(.black.opacity(0.45), in: Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(key, modifiers: [])
    }

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                if let url = displayedURL {
                    CachedAsyncImage(url: url, cornerRadius: 12, priority: .interactive)
                        .frame(width: 400, height: 400)
                        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
                        .id(url)
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(
                            LinearGradient(
                                colors: [.purple.opacity(0.3), .blue.opacity(0.3)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 400, height: 400)
                        .overlay {
                            Image(systemName: !stationName.isEmpty ? "radio.fill" : "music.note")
                                .font(.system(size: 80))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                }
                if showsCarousel {
                    HStack {
                        carouselButton("chevron.left", delta: -1, key: .leftArrow)
                        Spacer()
                        carouselButton("chevron.right", delta: 1, key: .rightArrow)
                    }
                    .padding(.horizontal, 10)
                }
            }
            .frame(width: 400, height: 400)

            if showsCarousel {
                Text("\(galleryIndex + 1) / \(galleryURLs.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            VStack(spacing: 6) {
                if !stationName.isEmpty {
                    Text(stationName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !title.isEmpty {
                    Text(title)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                if !artist.isEmpty {
                    Text(artist)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !album.isEmpty {
                    Text(album)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Button(L10n.close) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(30)
        .frame(width: 460, height: showsCarousel ? 584 : 560)
        .onAppear {
            if showsCarousel, let url = artURL,
               let idx = galleryURLs.firstIndex(of: url) {
                galleryIndex = idx
            }
        }
    }
}

private struct SeekBarRow: View {
    let vm: NowPlayingViewModel
    let durationSeconds: TimeInterval
    let transportIsActive: Bool
    let durationString: String
    let formatTime: (TimeInterval) -> String
    let onDragStart: () -> Void
    let onDragEnd: (TimeInterval) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { context in
            let live = vm.isDraggingSeek
                ? vm.dragPosition
                : vm.positionAnchor.projected(at: context.date)

            if durationSeconds > 0 {
                SliderWithPopup(
                    value: Binding(
                        get: { live },
                        set: { vm.dragPosition = $0 }
                    ),
                    range: 0...durationSeconds,
                    format: { formatTime($0) }
                ) { editing in
                    if editing {
                        vm.dragPosition = vm.positionAnchor.projected(at: context.date)
                        vm.isDraggingSeek = true
                        onDragStart()
                    } else {
                        vm.isDraggingSeek = false
                        onDragEnd(vm.dragPosition)
                    }
                }
            }

            HStack {
                Text(transportIsActive ? formatTime(live) : " ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                if durationSeconds > 0 {
                    Text(durationString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else if transportIsActive {
                    Text(L10n.live)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
