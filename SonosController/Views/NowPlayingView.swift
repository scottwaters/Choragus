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
    let group: SonosGroup

    @State private var actionInFlight: String?

    // MARK: - Local Volume State
    // Master volume and per-speaker volumes are managed locally for smooth interaction,
    // then synced back to SonosManager and speakers.
    @State private var volume: Double = 30
    @State private var isMuted = false
    @State private var speakerVolumes: [String: Double] = [:]
    @State private var speakerMutes: [String: Bool] = [:]
    @State private var lastMasterVolume: Double = 0
    @State private var volumeActionPending = false
    @State private var volumePendingTimer: Task<Void, Never>?
    @State private var volumeGraceUntil: Date = .distantPast
    @State private var muteGraceUntil: Date = .distantPast

    // MARK: - Smooth Progress Interpolation
    @State private var lastKnownPosition: TimeInterval = 0
    @State private var lastPositionTimestamp: Date = .distantPast
    @State private var progressTimer: Timer?
    @State private var smoothPosition: TimeInterval = 0
    @State private var isDraggingSeek = false
    @State private var positionFrozenUntil: Date = .distantPast

    @State private var crossfadeOn = false
    @State private var showGroupEditor = false
    @State private var showSleepTimer = false
    @State private var showEQ = false
    @State private var showCopied = false
    @State private var isInitialized = false

    // MARK: - Derived State from Manager

    private var transportState: TransportState {
        sonosManager.groupTransportStates[group.coordinatorID] ?? .stopped
    }

    private var trackMetadata: TrackMetadata {
        sonosManager.groupTrackMetadata[group.coordinatorID] ?? TrackMetadata()
    }

    private var playMode: PlayMode {
        sonosManager.groupPlayModes[group.coordinatorID] ?? .normal
    }

    private var hasTrack: Bool {
        !trackMetadata.title.isEmpty || !trackMetadata.stationName.isEmpty || trackMetadata.duration > 0
    }

    private var awaitingPlayback: Bool {
        sonosManager.awaitingPlayback[group.coordinatorID] ?? false
    }

    private var currentServiceName: String? {
        if let sid = trackMetadata.serviceID,
           let name = sonosManager.musicServiceName(for: sid) {
            return name
        }
        if let uri = trackMetadata.trackURI,
           let name = sonosManager.detectServiceName(fromURI: uri) {
            return name
        }
        if let uri = trackMetadata.trackURI, URIPrefix.isLocal(uri) {
            return "Music Library"
        }
        return nil
    }

    /// Resolves the artist field — converts RINCON device IDs to room names
    /// for TV/Line-In sources.
    private var displayArtist: String {
        let artist = trackMetadata.artist
        if artist.hasPrefix("RINCON_") {
            return ""
        }
        return artist
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Album art and track info
                HStack(spacing: 24) {
                    if hasTrack {
                        albumArtView
                            .frame(width: 180, height: 180)
                    } else if awaitingPlayback {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.quaternary)
                            .overlay {
                                ProgressView()
                                    .controlSize(.regular)
                            }
                            .frame(width: 180, height: 180)
                    } else {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.quaternary)
                            .overlay {
                                Image(systemName: "music.note")
                                    .font(.system(size: 40))
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(width: 180, height: 180)
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
                                if awaitingPlayback {
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
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(24)

                Divider()

                // Seek slider — hidden for streams with no duration
                if trackMetadata.duration > 0 {
                    VStack(spacing: 4) {
                        Slider(
                            value: Binding(
                                get: { smoothPosition },
                                set: { newVal in
                                    smoothPosition = newVal
                                }
                            ),
                            in: 0...trackMetadata.duration
                        ) { editing in
                            isDraggingSeek = editing
                            if !editing {
                                seekToPosition(smoothPosition)
                            }
                        }

                        HStack {
                            Text(smoothPositionString)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            Spacer()
                            Text(trackMetadata.durationString)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                } else if transportState.isActive {
                    // Streaming content — show elapsed time only
                    HStack {
                        Text(smoothPositionString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Spacer()
                        Text(L10n.live)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                } else {
                    Spacer()
                        .frame(height: 12)
                }

                // Transport controls
                HStack(spacing: 24) {
                    transportButton("shuffle", icon: "shuffle", size: .body,
                                    tint: playMode.isShuffled ? (sonosManager.resolvedAccentColor ?? .accentColor) : .secondary) {
                        toggleShuffle()
                    }
                    .tooltip(L10n.shuffle)

                    transportButton("previous", icon: "backward.fill", size: .title2) {
                        performAction("previous") { try await sonosManager.previous(group: group) }
                    }
                    .tooltip("Previous")

                    transportButton("playPause",
                                    icon: transportState.isPlaying ? "pause.circle.fill" : "play.circle.fill",
                                    size: .system(size: 44)) {
                        togglePlayPause()
                    }
                    .tooltip(transportState.isPlaying ? "Pause" : "Play")
                    .keyboardShortcut(.space, modifiers: [])

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
                .padding(.vertical, 16)

                // Volume
                HStack(spacing: 12) {
                    Button { toggleMute() } label: {
                        Image(systemName: isMuted ? "speaker.slash.fill" : volumeIcon)
                            .frame(width: 20)
                    }
                    .buttonStyle(.plain)

                    Slider(value: $volume, in: 0...100) { editing in
                        if !editing { setVolume() }
                    }
                    .frame(maxWidth: 300)

                    Text("\(Int(volume))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 28, alignment: .trailing)

                    if volumeActionPending {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 12)
                    } else {
                        Color.clear
                            .frame(width: 12)
                    }
                }
                .padding(.horizontal, 24)

                // Per-speaker volumes for grouped speakers
                if group.members.count > 1 {
                    VolumeControlView(group: group,
                                      speakerVolumes: $speakerVolumes,
                                      speakerMutes: $speakerMutes)
                        .environmentObject(sonosManager)
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
            startProgressTimer()
            syncFromManager()
            Task { await fetchCurrentState() }
        }
        .onReceive(sonosManager.$deviceVolumes) { _ in syncVolumeFromManager() }
        .onReceive(sonosManager.$deviceMutes) { _ in syncMuteFromManager() }
        .onChange(of: speakerMutes) { syncMasterMuteFromSpeakers() }
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

    // MARK: - Subviews

    @State private var webArtURL: URL?
    @State private var lastArtSearchKey = ""
    @State private var forceWebArt = false
    @State private var lastTrackURI = ""
    @State private var displayedArtURL: URL?
    @State private var radioTrackArtURL: URL?  // Track-specific art for radio stations
    @State private var radioStationArtURL: URL? // Station badge art for overlay
    @State private var lastRadioTrackKey = ""

    /// For local library files, construct a /getaa URL to extract embedded art
    private var localFileArtURL: String? {
        guard let uri = trackMetadata.trackURI,
              URIPrefix.isLocal(uri),
              let coordinator = group.coordinator else { return nil }
        let encoded = uri.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? uri
        return "http://\(coordinator.ip):\(coordinator.port)/getaa?s=1&u=\(encoded)"
    }

    /// Resolves the best art URL from all sources
    private func resolveArtURL() -> URL? {
        let isLocalFile = trackMetadata.trackURI.map(URIPrefix.isLocal) ?? false
        let artURI = trackMetadata.albumArtURI ?? localFileArtURL

        if forceWebArt {
            return webArtURL ?? artURI.flatMap { URL(string: $0) }
        } else if isLocalFile && webArtURL != nil {
            return webArtURL
        } else {
            return artURI.flatMap { URL(string: $0) } ?? webArtURL
        }
    }

    /// Updates displayedArtURL only when there's a genuine change
    private func updateDisplayedArt() {
        let resolved = resolveArtURL()
        // Only update if we have a new URL or if track changed (nil is valid — shows placeholder)
        if resolved != displayedArtURL {
            // Don't downgrade from a valid URL to nil unless the track actually changed
            if resolved == nil && displayedArtURL != nil {
                let currentURI = trackMetadata.trackURI ?? ""
                if currentURI == lastTrackURI { return } // Same track, don't clear art
            }
            displayedArtURL = resolved
        }
    }

    private var albumArtView: some View {
        return ZStack(alignment: .bottomTrailing) {
            if let trackArt = radioTrackArtURL, !trackMetadata.stationName.isEmpty {
                // Radio mode: track art as main, station art as badge
                CachedAsyncImage(url: trackArt, cornerRadius: 8)
            } else if let url = displayedArtURL {
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

            // Station badge overlay when showing track-specific art
            if radioTrackArtURL != nil, let stationArt = radioStationArtURL {
                CachedAsyncImage(url: stationArt, cornerRadius: 4)
                    .frame(width: 36, height: 36)
                    .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                    .padding(6)
            }
        }
        .onAppear { loadPersistedArtOverride(); searchWebArtIfNeeded(); updateDisplayedArt(); searchRadioTrackArt() }
        .onReceive(sonosManager.$groupTrackMetadata) { _ in
            searchWebArtIfNeeded()
            updateDisplayedArt()
            searchRadioTrackArt()
        }
            .contextMenu {
                Button(L10n.refreshArtwork) {
                    forceITunesArtSearch()
                }
                if webArtURL != nil || trackMetadata.albumArtURI != nil {
                    Button(L10n.clearArtwork) {
                        let searchTerm = !trackMetadata.title.isEmpty ? trackMetadata.title :
                                         !trackMetadata.stationName.isEmpty ? trackMetadata.stationName : ""
                        if !searchTerm.isEmpty {
                            UserDefaults.standard.removeObject(forKey: "artOverride:\(searchTerm.lowercased())")
                        }
                        webArtURL = nil
                        lastArtSearchKey = ""
                        forceWebArt = false
                    }
                }
            }
    }

    /// Searches for track-specific album art when playing a radio station.
    /// Shows the track's art as main with the station art as a small badge overlay.
    private func searchRadioTrackArt() {
        // Only for radio stations with track info
        guard !trackMetadata.stationName.isEmpty,
              !trackMetadata.title.isEmpty,
              trackMetadata.title != trackMetadata.stationName else {
            // No track info or title is just the station name — clear track art
            if radioTrackArtURL != nil { radioTrackArtURL = nil }
            return
        }

        // Dedup — don't search for the same track twice
        let key = "\(trackMetadata.title)|\(trackMetadata.artist)"
        guard key != lastRadioTrackKey else { return }
        lastRadioTrackKey = key

        // Save the station art for the badge overlay
        if radioStationArtURL == nil, let stationArt = displayedArtURL ?? trackMetadata.albumArtURI.flatMap({ URL(string: $0) }) {
            radioStationArtURL = stationArt
        }

        // Search iTunes for the current track using song-specific search
        let artist = trackMetadata.artist.hasPrefix("RINCON_") ? "" : trackMetadata.artist
        // Strip parenthetical text (often foreign translations that confuse search)
        let cleanTitle = trackMetadata.title
            .replacingOccurrences(of: "\\s*\\([^)]*\\)\\s*$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s*\\[[^\\]]*\\]\\s*$", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let searchTitle = cleanTitle.isEmpty ? trackMetadata.title : cleanTitle
        Task {
            if let artURL = await AlbumArtSearchService.shared.searchRadioTrackArt(
                artist: artist, title: searchTitle
            ) {
                radioTrackArtURL = URL(string: artURL)
            } else {
                radioTrackArtURL = nil
            }
        }
    }

    /// Forces an iTunes artwork search regardless of existing art.
    /// Persists the override to UserDefaults so it survives app restart.
    private func forceITunesArtSearch() {
        let artist = displayArtist
        let searchTerm = !trackMetadata.title.isEmpty ? trackMetadata.title :
                         !trackMetadata.stationName.isEmpty ? trackMetadata.stationName : ""
        guard !searchTerm.isEmpty else { return }
        lastArtSearchKey = ""
        forceWebArt = false
        Task {
            if let artURL = await AlbumArtSearchService.shared.searchArtwork(
                artist: artist, album: searchTerm
            ) {
                webArtURL = URL(string: artURL)
                forceWebArt = true
                let key = "artOverride:\(searchTerm.lowercased())"
                UserDefaults.standard.set(artURL, forKey: key)
                updateDisplayedArt()
            }
        }
    }

    /// Checks for a persisted art override from a previous "Refresh artwork" action.
    private func loadPersistedArtOverride() {
        let searchTerm = !trackMetadata.title.isEmpty ? trackMetadata.title :
                         !trackMetadata.stationName.isEmpty ? trackMetadata.stationName : ""
        guard !searchTerm.isEmpty else { return }
        let key = "artOverride:\(searchTerm.lowercased())"
        if let saved = UserDefaults.standard.string(forKey: key) {
            webArtURL = URL(string: saved)
            forceWebArt = true
            updateDisplayedArt()
        }
    }

    /// Searches iTunes for album art when none available from Sonos.
    private func searchWebArtIfNeeded() {
        // Detect track change — reset art state
        let currentURI = trackMetadata.trackURI ?? trackMetadata.title
        if currentURI != lastTrackURI && !currentURI.isEmpty {
            lastTrackURI = currentURI
            if !forceWebArt {
                webArtURL = nil
                lastArtSearchKey = ""
            }
            // Clear displayed art so stale art doesn't persist
            displayedArtURL = trackMetadata.albumArtURI.flatMap { URL(string: $0) }
            loadPersistedArtOverride()

            // Reset radio track art when source changes
            if trackMetadata.stationName.isEmpty {
                radioTrackArtURL = nil
                radioStationArtURL = nil
                lastRadioTrackKey = ""
            }
        }

        // Skip if we have art from the speaker (but not for local files with /getaa that may 404)
        let hasArt = trackMetadata.albumArtURI != nil && !(trackMetadata.albumArtURI?.isEmpty ?? true)
        let isLocalFile = trackMetadata.trackURI.map(URIPrefix.isLocal) ?? false
        sonosDebugLog("[ART-SEARCH] hasArt=\(hasArt) isLocal=\(isLocalFile) albumArtURI=\(trackMetadata.albumArtURI ?? "nil") trackURI=\(trackMetadata.trackURI?.prefix(60) ?? "nil")")
        if hasArt && !isLocalFile {
            sonosDebugLog("[ART-SEARCH] Skipping — has art and not local")
            if !forceWebArt {
                if webArtURL != nil { webArtURL = nil }
            }
            return
        }
        forceWebArt = false

        // For local library: prefer album name for search (track titles are too generic)
        // For radio/streaming: prefer station name or track title
        let searchTerm: String
        if isLocalFile && !trackMetadata.album.isEmpty {
            searchTerm = trackMetadata.album
        } else if !trackMetadata.stationName.isEmpty {
            searchTerm = trackMetadata.stationName
        } else if !trackMetadata.album.isEmpty {
            searchTerm = trackMetadata.album
        } else if !trackMetadata.title.isEmpty {
            searchTerm = trackMetadata.title
        } else {
            searchTerm = ""
        }
        let artist = displayArtist
        let key = "\(searchTerm)|\(artist)"
        sonosDebugLog("[ART-SEARCH] searchTerm=\(searchTerm) artist=\(artist) key=\(key) lastKey=\(lastArtSearchKey)")
        guard !searchTerm.isEmpty else { sonosDebugLog("[ART-SEARCH] Empty search term, skipping"); return }
        guard key != lastArtSearchKey else { sonosDebugLog("[ART-SEARCH] Same key, skipping"); return }
        lastArtSearchKey = key
        webArtURL = nil
        sonosDebugLog("[ART-SEARCH] Searching iTunes for artist='\(artist)' album='\(searchTerm)'")
        Task {
            if let artURL = await AlbumArtSearchService.shared.searchArtwork(
                artist: artist, album: searchTerm
            ) {
                sonosDebugLog("[ART-SEARCH] Found: \(artURL.prefix(80))")
                webArtURL = URL(string: artURL)
            } else {
                sonosDebugLog("[ART-SEARCH] No result from iTunes")
                webArtURL = nil
            }
            updateDisplayedArt()
        }
    }

    private var volumeIcon: String {
        if volume == 0 { return "speaker.fill" }
        if volume < 33 { return "speaker.wave.1.fill" }
        if volume < 66 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    private var repeatIcon: String {
        switch playMode.repeatMode {
        case .off, .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    private var smoothPositionString: String {
        formatTime(smoothPosition)
    }

    private func formatTime(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    // MARK: - Actions

    private func togglePlayPause() {
        let wasPlaying = transportState.isPlaying
        // Optimistically update manager state and hold with 10s grace
        sonosManager.groupTransportStates[group.coordinatorID] = wasPlaying ? .paused : .playing
        sonosManager.setTransportGrace(groupID: group.coordinatorID, duration: 10)
        // Freeze position bar for 3s to let Sonos catch up
        if !wasPlaying {
            positionFrozenUntil = Date().addingTimeInterval(3)
        }

        performAction("playPause") {
            if wasPlaying {
                try await sonosManager.pause(group: group)
            } else {
                try await sonosManager.play(group: group)
            }
        }
    }

    private func seekToPosition(_ seconds: TimeInterval) {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        let timeStr = String(format: "%d:%02d:%02d", h, m, s)

        // Freeze position for 3s — holds the dragged position until Sonos confirms
        lastKnownPosition = seconds
        lastPositionTimestamp = Date()
        positionFrozenUntil = Date().addingTimeInterval(3)
        // If playing, hold the transport state during seek buffering
        if transportState.isPlaying {
            sonosManager.setTransportGrace(groupID: group.coordinatorID, duration: 5)
        }

        Task {
            try? await sonosManager.seek(group: group, to: timeStr)
        }
    }

    private func toggleMute() {
        isMuted.toggle()
        muteGraceUntil = Date().addingTimeInterval(10)
        for member in group.members {
            speakerMutes[member.id] = isMuted
            sonosManager.setMuteGrace(deviceID: member.id, duration: 10)
            sonosManager.deviceMutes[member.id] = isMuted
        }
        showVolumePending()
        performAction("mute") {
            for member in group.members {
                try await sonosManager.setMute(device: member, muted: isMuted)
            }
            clearVolumePending()
        }
    }

    /// Applies the master volume change. For groups, computes the delta from last
    /// master position and adds it to each speaker proportionally — this preserves
    /// the relative volume balance (e.g. kitchen at 40, living room at 60).
    private func setVolume() {
        volumeGraceUntil = Date().addingTimeInterval(10)

        let delta = volume - lastMasterVolume
        lastMasterVolume = volume

        if group.members.count <= 1 {
            guard let coordinator = group.coordinator else { return }
            let targetVol = Int(volume)
            sonosManager.setVolumeGrace(deviceID: coordinator.id, duration: 10)
            sonosManager.deviceVolumes[coordinator.id] = targetVol
            showVolumePending()
            Task {
                try? await sonosManager.setVolume(device: coordinator, volume: targetVol)
                clearVolumePending()
            }
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                for member in group.members {
                    let current = speakerVolumes[member.id] ?? volume
                    let newVal = max(0, min(100, current + delta))
                    speakerVolumes[member.id] = newVal
                    sonosManager.setVolumeGrace(deviceID: member.id, duration: 10)
                    sonosManager.deviceVolumes[member.id] = Int(newVal)
                }
            }
            showVolumePending()
            Task {
                for member in group.members {
                    let newVol = Int(speakerVolumes[member.id] ?? 0)
                    try? await sonosManager.setVolume(device: member, volume: newVol)
                }
                clearVolumePending()
            }
        }
    }

    /// Delays the spinner by 300ms so fast operations don't flash
    private func showVolumePending() {
        volumePendingTimer?.cancel()
        volumePendingTimer = Task {
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled {
                volumeActionPending = true
            }
        }
    }

    private func clearVolumePending() {
        volumePendingTimer?.cancel()
        volumePendingTimer = nil
        volumeActionPending = false
    }

    private func toggleShuffle() {
        let newMode = playMode.togglingShuffle()
        sonosManager.groupPlayModes[group.coordinatorID] = newMode
        sonosManager.setModeGrace(groupID: group.coordinatorID)
        performAction("shuffle") {
            try await sonosManager.setPlayMode(group: group, mode: newMode)
        }
    }

    private func cycleRepeat() {
        let newMode = playMode.cyclingRepeat()
        sonosManager.groupPlayModes[group.coordinatorID] = newMode
        sonosManager.setModeGrace(groupID: group.coordinatorID)
        performAction("repeat") {
            try await sonosManager.setPlayMode(group: group, mode: newMode)
        }
    }

    private func toggleCrossfade() {
        let newValue = !crossfadeOn
        crossfadeOn = newValue
        performAction("crossfade") {
            try await sonosManager.setCrossfadeMode(group: group, enabled: newValue)
        }
    }

    private func copyTrackInfo() {
        var lines: [String] = []

        // Audio source (station or streaming service)
        if !trackMetadata.stationName.isEmpty {
            lines.append("\(L10n.sourceLabel): \(trackMetadata.stationName)")
        } else if let sid = trackMetadata.serviceID,
                  let serviceName = sonosManager.musicServiceName(for: sid) {
            lines.append("\(L10n.sourceLabel): \(serviceName)")
        }

        if !displayArtist.isEmpty {
            lines.append("\(L10n.artistLabel): \(displayArtist)")
        }
        if !trackMetadata.album.isEmpty {
            lines.append("\(L10n.albumLabel): \(trackMetadata.album)")
        }
        if !trackMetadata.title.isEmpty {
            lines.append("\(L10n.trackLabel): \(trackMetadata.title)")
        }

        let text = lines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        showCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            showCopied = false
        }
    }

    /// Executes a SOAP action with in-flight tracking.
    private func performAction(_ id: String, _ action: @escaping () async throws -> Void) {
        actionInFlight = id
        Task {
            do {
                try await action()
            } catch {
                // Action failed — UI will reflect actual state on next update
            }
            actionInFlight = nil
        }
    }

    // MARK: - Immediate State Fetch

    /// Fetches current state directly from the speaker when the user selects a room.
    /// Provides instant UI update; event-driven updates take over afterward.
    private func fetchCurrentState() async {
        guard let coordinator = group.coordinator else { return }

        do {
            async let stateResult = sonosManager.getTransportState(group: group)
            async let positionResult = sonosManager.getPositionInfo(group: group)
            async let modeResult = sonosManager.getPlayMode(group: group)

            let (state, position, mode) = try await (stateResult, positionResult, modeResult)

            sonosManager.groupTransportStates[group.coordinatorID] = state
            sonosManager.groupPlayModes[group.coordinatorID] = mode

            // Enrich with station name and art from GetMediaInfo
            var enrichedPosition = position
            if state.isActive {
                let mediaInfo = try? await sonosManager.getMediaInfo(group: group)
                if let rawDIDL = mediaInfo?["CurrentURIMetaData"], !rawDIDL.isEmpty,
                   rawDIDL != "NOT_IMPLEMENTED" {
                    let didl = rawDIDL.contains("&lt;") ? XMLResponseParser.xmlUnescape(rawDIDL) : rawDIDL
                    if let parsed = XMLResponseParser.parseDIDLMetadata(didl) {
                        let currentURI = mediaInfo?["CurrentURI"] ?? ""
                        let isRadio = currentURI.contains(URIPrefix.sonosApiStream) ||
                                      currentURI.contains(URIPrefix.sonosApiRadio) ||
                                      currentURI.contains(URIPrefix.rinconMP3Radio)
                        if isRadio && !parsed.title.isEmpty {
                            enrichedPosition.stationName = parsed.title
                        }
                        if enrichedPosition.title.isEmpty {
                            enrichedPosition.title = parsed.title
                        }
                        // Always try to get art from media info for radio
                        var artURI = parsed.albumArtURI
                        if artURI.hasPrefix("/") {
                            artURI = "http://\(coordinator.ip):\(coordinator.port)\(artURI)"
                        }
                        if !artURI.isEmpty {
                            enrichedPosition.albumArtURI = artURI
                            // Cache by the favorite's ID so the browse list can find it directly
                            if let favID = sonosManager.lastPlayedFavoriteID {
                                sonosManager.cacheArtURL(artURI, forURI: "", title: enrichedPosition.stationName.isEmpty ? enrichedPosition.title : enrichedPosition.stationName, itemID: favID)
                            }
                        }
                    }
                }
            }

            sonosManager.transportDidUpdateTrackMetadata(group.coordinatorID, metadata: enrichedPosition)

            // Set position directly on the slider
            lastKnownPosition = enrichedPosition.position
            lastPositionTimestamp = Date()
            smoothPosition = enrichedPosition.position

            // Fetch volume/mute per member (skip graced devices — preset just set them)
            for member in group.members {
                if !sonosManager.isVolumeGraceActive(deviceID: member.id) {
                    let vol = try await sonosManager.getVolume(device: member)
                    sonosManager.deviceVolumes[member.id] = vol
                }
                if !sonosManager.isMuteGraceActive(deviceID: member.id) {
                    let muted = try await sonosManager.getMute(device: member)
                    sonosManager.deviceMutes[member.id] = muted
                }
            }

            syncVolumeFromManager()
            syncMuteFromManager()

            // Fetch crossfade state
            crossfadeOn = (try? await sonosManager.getCrossfadeMode(group: group)) ?? false
        } catch {
            // Fall back to whatever the transport strategy has cached
        }
    }

    // MARK: - Position Polling & Interpolation
    //
    // Position tracking is owned by the view, matching the proven original design.
    // The view runs its own position poll (every 2s) and smooth interpolation (every 0.5s).
    // This is independent of the transport strategy — it always works.

    @State private var positionPollingTask: Task<Void, Never>?

    private func startProgressTimer() {
        stopProgressTimer()

        // Position polling — fetch position from speaker every 2s
        positionPollingTask = Task {
            while !Task.isCancelled {
                await pollPosition()
                try? await Task.sleep(for: .seconds(2))
            }
        }

        // Smooth progress timer — ticks every 0.5s for fluid bar movement
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [self] _ in
            guard !isDraggingSeek else { return }
            guard Date() > positionFrozenUntil else { return }
            guard transportState.isPlaying else { return }

            let elapsed = Date().timeIntervalSince(lastPositionTimestamp)
            let interpolated = lastKnownPosition + elapsed
            let duration = trackMetadata.duration
            let clamped = duration > 0 ? min(interpolated, duration) : interpolated
            if clamped >= smoothPosition {
                smoothPosition = clamped
            }
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
        positionPollingTask?.cancel()
        positionPollingTask = nil
    }

    /// Polls transport state, position, and track metadata from the speaker.
    /// Uses the original proven re-anchor logic for smooth position updates.
    private func pollPosition() async {
        // Skip while an action is in-flight or frozen
        guard actionInFlight == nil else { return }

        do {
            // Fetch transport state alongside position — catches external
            // playback changes (e.g. playing from favorites, Sonos app, etc.)
            async let stateResult = sonosManager.getTransportState(group: group)
            async let positionResult = sonosManager.getPositionInfo(group: group)

            var (state, position) = try await (stateResult, positionResult)

            // For streaming/radio content, enrich from GetMediaInfo when needed
            if (position.title.isEmpty || position.stationName.isEmpty), state.isActive,
               let coordinator = group.coordinator {
                let mediaInfo = try? await sonosManager.getMediaInfo(group: group)
                if let rawDIDL = mediaInfo?["CurrentURIMetaData"], !rawDIDL.isEmpty,
                   rawDIDL != "NOT_IMPLEMENTED" {
                    let didl = rawDIDL.contains("&lt;") ? XMLResponseParser.xmlUnescape(rawDIDL) : rawDIDL
                    if let parsed = XMLResponseParser.parseDIDLMetadata(didl) {
                        let currentURI = mediaInfo?["CurrentURI"] ?? ""
                        let isRadio = currentURI.contains(URIPrefix.sonosApiStream) ||
                                      currentURI.contains(URIPrefix.sonosApiRadio) ||
                                      currentURI.contains(URIPrefix.rinconMP3Radio)

                        if isRadio && position.stationName.isEmpty && !parsed.title.isEmpty {
                            position.stationName = parsed.title
                        }
                        if position.title.isEmpty { position.title = parsed.title }
                        if position.artist.isEmpty { position.artist = parsed.creator }
                        if position.album.isEmpty { position.album = parsed.album }
                        // For radio, always prefer MediaInfo art (e.g. TuneIn logo)
                        // over constructed /getaa URLs which may not work
                        var artURI = parsed.albumArtURI
                        if artURI.hasPrefix("/") {
                            artURI = "http://\(coordinator.ip):\(coordinator.port)\(artURI)"
                        }
                        if !artURI.isEmpty {
                            position.albumArtURI = artURI
                            if let favID = sonosManager.lastPlayedFavoriteID {
                                sonosManager.cacheArtURL(artURI, forURI: "", title: position.stationName.isEmpty ? position.title : position.stationName, itemID: favID)
                            }
                        }
                    }
                }
            }

            sonosManager.groupTransportStates[group.coordinatorID] = state
            sonosManager.transportDidUpdateTrackMetadata(group.coordinatorID, metadata: position)

            guard Date() > positionFrozenUntil else { return }

            let serverPosition = position.position
            let now = Date()

            guard !isDraggingSeek, Date() > positionFrozenUntil else { return }

            let ahead = smoothPosition - serverPosition   // positive = we're ahead
            let behind = serverPosition - smoothPosition   // positive = we're behind

            if behind > 2 || lastKnownPosition > serverPosition + 5 || !transportState.isPlaying {
                // We're significantly behind, or track changed, or paused — snap to server
                lastKnownPosition = serverPosition
                lastPositionTimestamp = now
                smoothPosition = serverPosition
            } else if ahead > 0 && ahead <= 2 {
                // We're slightly ahead — just re-anchor without moving smoothPosition.
                // The interpolation timer will pause until server catches up because
                // lastKnownPosition + elapsed won't exceed current smoothPosition.
                lastKnownPosition = serverPosition
                lastPositionTimestamp = now
            } else {
                // We're slightly behind or exactly right — re-anchor normally
                lastKnownPosition = serverPosition
                lastPositionTimestamp = now
            }
        } catch {
            // Silently retry next poll
        }
    }

    // MARK: - Sync from Manager

    /// Initial sync of volume/mute state from manager when view appears or group changes
    private func syncFromManager() {
        isInitialized = false
        syncVolumeFromManager()
        syncMuteFromManager()
        isInitialized = true
    }

    private func syncVolumeFromManager() {
        let now = Date()
        guard now > volumeGraceUntil else { return }

        if group.members.count > 1 {
            var totalVol = 0.0
            for member in group.members {
                // During grace, use the optimistic value already in deviceVolumes
                // (skip updating the local slider, but still include in average)
                if sonosManager.isVolumeGraceActive(deviceID: member.id) {
                    let v = Double(sonosManager.deviceVolumes[member.id] ?? 0)
                    if abs((speakerVolumes[member.id] ?? 0) - v) > 0.5 {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            speakerVolumes[member.id] = v
                        }
                    }
                    totalVol += v
                    continue
                }
                let v = Double(sonosManager.deviceVolumes[member.id] ?? 0)
                if abs((speakerVolumes[member.id] ?? 0) - v) > 0.5 || !isInitialized {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        speakerVolumes[member.id] = v
                    }
                }
                totalVol += v
            }
            let avg = totalVol / Double(group.members.count)
            if abs(volume - avg) > 0.5 || !isInitialized {
                withAnimation(.easeInOut(duration: 0.3)) {
                    volume = avg
                }
            }
            lastMasterVolume = avg
        } else if let coordinator = group.coordinator {
            guard !sonosManager.isVolumeGraceActive(deviceID: coordinator.id) else { return }
            let vol = Double(sonosManager.deviceVolumes[coordinator.id] ?? 0)
            if abs(volume - vol) > 0.5 || !isInitialized {
                withAnimation(.easeInOut(duration: 0.3)) {
                    volume = vol
                }
            }
            lastMasterVolume = vol
        }
    }

    private func syncMuteFromManager() {
        let now = Date()
        guard now > muteGraceUntil else { return }

        if group.members.count > 1 {
            var allMuted = true
            for member in group.members {
                // Skip devices with active grace (user just toggled mute on this speaker)
                guard !sonosManager.isMuteGraceActive(deviceID: member.id) else {
                    if !(speakerMutes[member.id] ?? false) { allMuted = false }
                    continue
                }
                let m = sonosManager.deviceMutes[member.id] ?? false
                speakerMutes[member.id] = m
                if !m { allMuted = false }
            }
            isMuted = allMuted
        } else if let coordinator = group.coordinator {
            guard !sonosManager.isMuteGraceActive(deviceID: coordinator.id) else { return }
            let m = sonosManager.deviceMutes[coordinator.id] ?? false
            speakerMutes[coordinator.id] = m
            isMuted = m
        }
    }

    /// When sub-speaker mutes change (e.g. user mutes all individually),
    /// update the master mute indicator to reflect the aggregate state.
    private func syncMasterMuteFromSpeakers() {
        guard group.members.count > 1 else { return }
        let allMuted = group.members.allSatisfy { speakerMutes[$0.id] ?? false }
        if isMuted != allMuted {
            isMuted = allMuted
        }
    }

}
