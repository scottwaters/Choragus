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
    @State private var vm: NowPlayingViewModel
    @State private var showShuffleHint = false
    let group: SonosGroup

    init(group: SonosGroup, sonosManager: SonosManager, playHistoryManager: PlayHistoryManager? = nil) {
        self.group = group
        _vm = State(wrappedValue: NowPlayingViewModel(sonosManager: sonosManager, group: group, playHistoryManager: playHistoryManager))
    }

    // Convenience accessors from ViewModel
    private var actionInFlight: String? { vm.actionInFlight }
    private var volume: Double { vm.volume }
    private var isMuted: Bool { vm.isMuted }
    private var speakerVolumes: [String: Double] { vm.speakerVolumes }
    private var speakerMutes: [String: Bool] { vm.speakerMutes }
    private var smoothPosition: TimeInterval { vm.smoothPosition }
    private var isDraggingSeek: Bool { vm.isDraggingSeek }
    private var crossfadeOn: Bool { vm.crossfadeOn }
    @State private var showGroupEditor = false
    @State private var showSleepTimer = false
    @State private var showEQ = false
    @State private var showCopied = false
    @State private var showExpandedArt = false
    @State private var showArtSearch = false

    // MARK: - Derived State (from ViewModel)

    private var transportState: TransportState { vm.transportState }
    private var trackMetadata: TrackMetadata { vm.trackMetadata }
    private var playMode: PlayMode { vm.playMode }
    private var hasTrack: Bool { vm.hasTrack }

    private var awaitingPlayback: Bool { vm.awaitingPlayback }
    private var currentServiceName: String? { vm.currentServiceName }
    private var displayArtist: String { vm.displayArtist }

    var body: some View {
        ScrollView {
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

                            // Service tag
                            if let serviceName = currentServiceName {
                                Label(serviceName, systemImage: "music.note.tv")
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
                                if sonosManager.htSatChannelMaps[group.coordinatorID] != nil {
                                    WindowManager.shared.openHomeTheaterEQ()
                                } else {
                                    showEQ = true
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
                                .tooltip(isCurrentTrackStarred ? "Starred" : "Star this track")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(24)

                Divider()

                // Time/seek area — fixed height to prevent layout shift
                VStack(spacing: 4) {
                    if trackMetadata.duration > 0 {
                        SliderWithPopup(
                            value: Binding(get: { vm.smoothPosition }, set: { vm.smoothPosition = $0 }),
                            range: 0...trackMetadata.duration,
                            format: { formatTime($0) }
                        ) { editing in
                            vm.isDraggingSeek = editing
                            if !editing {
                                seekToPosition(vm.smoothPosition)
                            }
                        }
                    }

                    HStack {
                        Text(transportState.isActive ? smoothPositionString : " ")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Spacer()
                        if trackMetadata.duration > 0 {
                            Text(trackMetadata.durationString)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        } else if transportState.isActive {
                            Text(L10n.live)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
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
                                        Text("Shuffle is disabled")
                                            .font(.caption)
                                            .fontWeight(.semibold)
                                        Text("Use the shuffle button in the Queue panel to physically reorder tracks, or enable Classic Shuffle Mode in Settings.")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .frame(width: 240)
                                    .padding(12)
                                }
                        }

                        transportButton("previous", icon: "backward.fill", size: .title2) {
                            performAction("previous") { try await sonosManager.previous(group: group) }
                        }
                        .tooltip("Previous")
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)

                    // Center: play/pause
                    transportButton("playPause",
                                    icon: transportState.isPlaying ? "pause.circle.fill" : "play.circle.fill",
                                    size: .system(size: 44)) {
                        togglePlayPause()
                    }
                    .tooltip(transportState.isPlaying ? "Pause" : "Play")
                    .keyboardShortcut(.space, modifiers: [])

                    // Right side: next + repeat + crossfade
                    HStack(spacing: 24) {
                        transportButton("next", icon: "forward.fill", size: .title2) {
                            performAction("next") { try await sonosManager.next(group: group) }
                        }
                        .tooltip("Next")

                        transportButton("repeat", icon: repeatIcon, size: .body,
                                        tint: playMode.repeatMode != .off ? (sonosManager.resolvedAccentColor ?? .accentColor) : .secondary) {
                            cycleRepeat()
                        }
                        .tooltip(L10n.repeat_)

                        transportButton("crossfade", icon: "arrow.triangle.swap", size: .caption,
                                        tint: crossfadeOn ? (sonosManager.resolvedAccentColor ?? .accentColor) : .secondary) {
                            toggleCrossfade()
                        }
                        .tooltip("Crossfade")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 16)
                .padding(.horizontal, UILayout.horizontalPadding)

                // Volume
                HStack(spacing: 12) {
                    Button { toggleMute() } label: {
                        Image(systemName: isMuted ? "speaker.slash.fill" : volumeIcon)
                            .frame(width: 20)
                    }
                    .buttonStyle(.plain)

                    SliderWithPopup(
                        value: Binding(get: { vm.volume }, set: { vm.volume = $0 }),
                        range: 0...100
                    ) { editing in
                        vm.isDraggingVolume = editing
                        if !editing {
                            vm.setVolume()
                            vm.commitVolume()
                        }
                    }
                    .frame(maxWidth: 300)

                    Text("\(Int(volume))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 28, alignment: .trailing)
                }
                .padding(.horizontal, UILayout.horizontalPadding)

                // Per-speaker volumes for grouped speakers
                if group.members.count > 1 {
                    VolumeControlView(group: group,
                                      speakerVolumes: Binding(get: { vm.speakerVolumes }, set: { vm.speakerVolumes = $0 }),
                                      speakerMutes: Binding(get: { vm.speakerMutes }, set: { vm.speakerMutes = $0 }),
                                      accentColor: sonosManager.resolvedAccentColor ?? .accentColor,
                                      onSetVolume: { device, vol in await vm.setSpeakerVolume(device: device, volume: vol) },
                                      onToggleMute: { device, muted in await vm.setSpeakerMute(device: device, muted: muted) },
                                      onDragStateChanged: { dragging in vm.isDraggingVolume = dragging })
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tint(sonosManager.resolvedAccentColor)
        .onAppear {
            startProgressTimer()
            syncFromManager()
            Task { await fetchCurrentState() }
        }
        .onDisappear { stopProgressTimer() }
        .onChange(of: group.id) {
            vm.group = group
            vm.art.reset()
            vm.resetForGroupChange()
            startProgressTimer()
            Task { await fetchCurrentState() }
        }
        .onReceive(sonosManager.$deviceVolumes) { _ in syncVolumeFromManager() }
        .onReceive(sonosManager.$deviceMutes) { _ in syncMuteFromManager() }
        .onChange(of: speakerMutes) { syncMasterMuteFromSpeakers() }
        .onReceive(sonosManager.$groupPositions) { positions in
            // Sync position from TransportStrategy updates for smooth interpolation
            if let pos = positions[group.coordinatorID] {
                vm.lastKnownPosition = pos
                vm.lastPositionTimestamp = Date()
                vm.smoothPosition = pos
            }
        }
        .onReceive(sonosManager.$groupTrackMetadata) { _ in
            // Force view to re-evaluate trackMetadata computed property
        }
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
        return ZStack(alignment: .bottomTrailing) {
            if let url = vm.art.artURLForDisplay(trackMetadata: trackMetadata) {
                CachedAsyncImage(url: url, cornerRadius: 8)
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
            }
            if vm.art.shouldShowStationBadge(trackMetadata: trackMetadata),
               let stationArt = vm.art.radioStationArtURL {
                CachedAsyncImage(url: stationArt, cornerRadius: 4)
                    .frame(width: 36, height: 36)
                    .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                    .padding(6)
            }
        }
        .onAppear {
            vm.onArtAppear()
        }
        .onReceive(sonosManager.$groupTrackMetadata) { newMeta in
            let meta = newMeta[group.coordinatorID] ?? TrackMetadata()
            vm.handleMetadataChanged(meta)
        }
            .contextMenu {
                Button("Search Artwork...") {
                    showArtSearch = true
                }
                Button(L10n.refreshArtwork) {
                    vm.art.forceITunesArtSearch(trackMetadata: trackMetadata, displayArtist: vm.displayArtist, group: group)
                }
                Divider()
                Button("Ignore Artwork") {
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
                    showArtSearch = false
                }
            }
    }

    // MARK: - Helpers (delegated to ViewModel)

    private var volumeIcon: String { vm.volumeIcon }
    private var repeatIcon: String { vm.repeatIcon }
    private var smoothPositionString: String { vm.smoothPositionString }
    private func formatTime(_ interval: TimeInterval) -> String { vm.formatTime(interval) }

    // MARK: - Actions (delegated to ViewModel)

    private func togglePlayPause() { vm.togglePlayPause() }
    private func seekToPosition(_ seconds: TimeInterval) { vm.seekToPosition(seconds) }
    private func toggleMute() { vm.toggleMute() }

    private func setVolume() { vm.setVolume() }
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
        return sonosManager.playHistoryManager?.entries.contains {
            $0.title == trackMetadata.title && $0.artist == trackMetadata.artist && $0.starred
        } ?? false
    }

    private func performAction(_ id: String, _ action: @escaping () async throws -> Void) {
        vm.performAction(id, action)
    }

    // MARK: - State Fetch & Polling (delegated to ViewModel)

    private func fetchCurrentState() async { await vm.fetchCurrentState() }
    private func startProgressTimer() { vm.startProgressTimer() }
    private func stopProgressTimer() { vm.stopProgressTimer() }

    private func syncFromManager() { vm.syncFromManager() }
    private func syncVolumeFromManager() { vm.syncVolumeFromManager() }
    private func syncMuteFromManager() { vm.syncMuteFromManager() }
    private func syncMasterMuteFromSpeakers() { vm.syncMasterMuteFromSpeakers() }
}

// MARK: - Expanded Art View

struct ExpandedArtView: View {
    let artURL: URL?
    let title: String
    let artist: String
    let album: String
    let stationName: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            if let url = artURL {
                CachedAsyncImage(url: url, cornerRadius: 12)
                    .frame(width: 400, height: 400)
                    .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
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

            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(30)
        .frame(width: 460, height: 560)
    }
}
