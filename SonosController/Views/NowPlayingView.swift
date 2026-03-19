/// NowPlayingView.swift — Main playback control UI for a Sonos group.
///
/// Key design decisions:
/// - **Grace period system**: After a user action (play/pause/volume/mode), the UI
///   holds the optimistic state for 5 seconds, ignoring poll responses. This prevents
///   the UI from flickering back to the old state while the speaker processes the command.
/// - **Smooth progress**: A 0.5s timer interpolates the position bar between 2s polls
///   so it moves fluidly. After seek/play, position is frozen for 3s until the speaker
///   reports the new position.
/// - **Proportional group volume**: The master slider applies a delta to each speaker,
///   preserving relative volume differences across grouped speakers.
import SwiftUI
import SonosKit

struct NowPlayingView: View {
    @EnvironmentObject var sonosManager: SonosManager
    let group: SonosGroup

    @State private var transportState: TransportState = .stopped
    @State private var trackMetadata = TrackMetadata()
    @State private var volume: Double = 30
    @State private var isMuted = false
    @State private var playMode: PlayMode = .normal
    @State private var isLoading = true
    @State private var pollingTask: Task<Void, Never>?
    @State private var actionInFlight: String?

    // MARK: - Grace Periods
    // Each controls a different piece of state; polling skips updates until grace expires.
    // If the speaker catches up early (reports the expected state), grace ends immediately.
    @State private var transportGraceUntil: Date = .distantPast
    @State private var volumeGraceUntil: Date = .distantPast
    @State private var muteGraceUntil: Date = .distantPast
    @State private var modeGraceUntil: Date = .distantPast

    private let graceDuration: TimeInterval = 5

    // MARK: - Group Volume
    // Per-speaker volumes allow proportional adjustment via the master slider
    @State private var speakerVolumes: [String: Double] = [:]
    @State private var speakerMutes: [String: Bool] = [:]
    @State private var lastMasterVolume: Double = 0

    @State private var volumeActionPending = false
    @State private var volumePendingTimer: Task<Void, Never>?

    // MARK: - Smooth Progress Interpolation
    @State private var lastKnownPosition: TimeInterval = 0
    @State private var lastPositionTimestamp: Date = .distantPast
    @State private var progressTimer: Timer?
    @State private var smoothPosition: TimeInterval = 0
    @State private var isDraggingSeek = false
    @State private var positionFrozenUntil: Date = .distantPast

    @State private var showGroupEditor = false
    @State private var showSleepTimer = false
    @State private var showEQ = false

    private var hasTrack: Bool {
        !trackMetadata.title.isEmpty || trackMetadata.duration > 0
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Album art and track info
                HStack(spacing: 24) {
                    if hasTrack {
                        albumArtView
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
                        Text(hasTrack ? trackMetadata.title : "No Track")
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundStyle(hasTrack ? .primary : .secondary)
                            .lineLimit(2)

                        if hasTrack {
                            Text(trackMetadata.artist.isEmpty ? "Unknown Artist" : trackMetadata.artist)
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)

                            Text(trackMetadata.album.isEmpty ? "" : trackMetadata.album)
                                .font(.body)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        } else {
                            Text("Nothing playing on this speaker")
                                .font(.body)
                                .foregroundStyle(.tertiary)
                        }

                        Spacer()

                        HStack(spacing: 12) {
                            Button { showGroupEditor = true } label: {
                                Label("Group", systemImage: "rectangle.stack")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button { showSleepTimer = true } label: {
                                Label("Sleep", systemImage: "moon.zzz")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            if let coordinator = group.coordinator {
                                Button { showEQ = true } label: {
                                    Label("EQ", systemImage: "slider.horizontal.3")
                                        .font(.caption)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .popover(isPresented: $showEQ) {
                                    EQView(device: coordinator)
                                        .environmentObject(sonosManager)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(24)

                Divider()

                // Seek slider
                VStack(spacing: 4) {
                    Slider(
                        value: Binding(
                            get: { smoothPosition },
                            set: { newVal in
                                smoothPosition = newVal
                            }
                        ),
                        in: 0...max(trackMetadata.duration, 1)
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

                // Transport controls
                HStack(spacing: 24) {
                    transportButton("shuffle", icon: "shuffle", size: .body,
                                    tint: playMode.isShuffled ? Color.accentColor : .secondary) {
                        toggleShuffle()
                    }
                    .help("Shuffle")

                    transportButton("previous", icon: "backward.fill", size: .title2) {
                        performAction("previous") { try await sonosManager.previous(group: group) }
                    }

                    transportButton("playPause",
                                    icon: transportState.isPlaying ? "pause.circle.fill" : "play.circle.fill",
                                    size: .system(size: 44)) {
                        togglePlayPause()
                    }
                    .keyboardShortcut(.space, modifiers: [])

                    transportButton("next", icon: "forward.fill", size: .title2) {
                        performAction("next") { try await sonosManager.next(group: group) }
                    }

                    transportButton("repeat", icon: repeatIcon, size: .body,
                                    tint: playMode.repeatMode != .off ? Color.accentColor : .secondary) {
                        cycleRepeat()
                    }
                    .help("Repeat")
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
        .onAppear { startPolling() }
        .onDisappear { stopPolling() }
        .onChange(of: group.id) { startPolling() }
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
        }
        .buttonStyle(.plain)
        .disabled(actionInFlight != nil)
    }

    // MARK: - Subviews

    private var albumArtView: some View {
        let url = trackMetadata.albumArtURI.flatMap { URL(string: $0) }
        return CachedAsyncImage(url: url, cornerRadius: 8)
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

    private var progress: Double {
        guard trackMetadata.duration > 0 else { return 0 }
        return min(smoothPosition / trackMetadata.duration, 1.0)
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
        transportState = wasPlaying ? .paused : .playing
        transportGraceUntil = Date().addingTimeInterval(graceDuration)
        // Freeze position bar for 3s after play/resume to let Sonos catch up
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

        Task {
            try? await sonosManager.seek(group: group, to: timeStr)
        }
    }

    private func toggleMute() {
        isMuted.toggle()
        muteGraceUntil = Date().addingTimeInterval(graceDuration)
        for member in group.members {
            speakerMutes[member.id] = isMuted
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
        volumeGraceUntil = Date().addingTimeInterval(graceDuration)

        let delta = volume - lastMasterVolume
        lastMasterVolume = volume

        if group.members.count <= 1 {
            guard let coordinator = group.coordinator else { return }
            showVolumePending()
            Task {
                try? await sonosManager.setVolume(device: coordinator, volume: Int(volume))
                clearVolumePending()
            }
        } else {
            // Animate individual sliders proportionally
            withAnimation(.easeInOut(duration: 0.2)) {
                for member in group.members {
                    let current = speakerVolumes[member.id] ?? volume
                    speakerVolumes[member.id] = max(0, min(100, current + delta))
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
        playMode = newMode
        modeGraceUntil = Date().addingTimeInterval(graceDuration)
        performAction("shuffle") {
            try await sonosManager.setPlayMode(group: group, mode: newMode)
        }
    }

    private func cycleRepeat() {
        let newMode = playMode.cyclingRepeat()
        playMode = newMode
        modeGraceUntil = Date().addingTimeInterval(graceDuration)
        performAction("repeat") {
            try await sonosManager.setPlayMode(group: group, mode: newMode)
        }
    }

    /// Executes a SOAP action with in-flight tracking. Polling is suppressed while
    /// actionInFlight is set. After completion, the grace period (not an immediate
    /// refresh) ensures the optimistic state holds until the speaker catches up.
    private func performAction(_ id: String, _ action: @escaping () async throws -> Void) {
        actionInFlight = id
        Task {
            do {
                try await action()
            } catch {
                print("Action failed: \(error)")
            }
            actionInFlight = nil
        }
    }

    // MARK: - Polling

    private func startPolling() {
        stopPolling()
        pollingTask = Task {
            while !Task.isCancelled {
                await refreshState()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        // Smooth progress timer — ticks every 0.5s for fluid bar movement
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [self] _ in
            // Don't advance while user is dragging the seek slider
            guard !isDraggingSeek else { return }
            // Don't advance while frozen (waiting for Sonos after play/seek)
            guard Date() > positionFrozenUntil else { return }
            guard transportState.isPlaying else { return }

            let elapsed = Date().timeIntervalSince(lastPositionTimestamp)
            let interpolated = lastKnownPosition + elapsed
            // Only move forward — never jump back
            let clamped = trackMetadata.duration > 0 ? min(interpolated, trackMetadata.duration) : interpolated
            if clamped >= smoothPosition {
                smoothPosition = clamped
            }
            // If clamped < smoothPosition, we're ahead — just wait (don't move)
        }
    }

    private func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func refreshState() async {
        // Skip polling entirely while an action is in flight
        guard actionInFlight == nil else { return }

        do {
            let now = Date()

            async let stateResult = sonosManager.getTransportState(group: group)
            async let positionResult = sonosManager.getPositionInfo(group: group)
            async let modeResult = sonosManager.getPlayMode(group: group)

            let (state, position, mode) = try await (stateResult, positionResult, modeResult)

            // Only update transport state if grace period has expired
            // During grace, keep the optimistic state (e.g. "playing") even if
            // the speaker still reports TRANSITIONING or STOPPED
            if now > transportGraceUntil {
                transportState = state
            } else if state == .playing || state == .paused {
                // If the speaker has caught up to our intended state, end grace early
                transportState = state
                transportGraceUntil = .distantPast
            }

            // Update track metadata
            trackMetadata = position

            // Sync smooth position from server — but not while dragging or frozen
            let serverPosition = position.position

            if !isDraggingSeek && now > positionFrozenUntil {
                let ahead = smoothPosition - serverPosition // positive = we're ahead
                let behind = serverPosition - smoothPosition // positive = we're behind

                if behind > 2 || lastKnownPosition > serverPosition + 5 || !state.isPlaying {
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
                    // Don't update smoothPosition — it stays where it is, timer pauses naturally
                } else {
                    // We're slightly behind or exactly right — re-anchor normally
                    lastKnownPosition = serverPosition
                    lastPositionTimestamp = now
                }
            } else if now > positionFrozenUntil && !isDraggingSeek {
                // Freeze just ended — accept server position
                lastKnownPosition = serverPosition
                lastPositionTimestamp = now
                smoothPosition = serverPosition
            }

            if now > modeGraceUntil {
                playMode = mode
            }

            // Volume: for groups, compute average across all members
            if now > volumeGraceUntil {
                if group.members.count > 1 {
                    var totalVol = 0.0
                    for member in group.members {
                        let v = try await sonosManager.getVolume(device: member)
                        let dv = Double(v)
                        if abs((speakerVolumes[member.id] ?? 0) - dv) > 0.5 {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                speakerVolumes[member.id] = dv
                            }
                        }
                        totalVol += dv
                    }
                    let avg = totalVol / Double(group.members.count)
                    withAnimation(.easeInOut(duration: 0.3)) {
                        volume = avg
                    }
                    lastMasterVolume = avg
                } else if let coordinator = group.coordinator {
                    let vol = Double(try await sonosManager.getVolume(device: coordinator))
                    if abs(volume - vol) > 0.5 {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            volume = vol
                        }
                    }
                    lastMasterVolume = vol
                }
            }

            // Mute: for groups, poll each speaker and sync speakerMutes
            if now > muteGraceUntil {
                if group.members.count > 1 {
                    var allMuted = true
                    for member in group.members {
                        let m = try await sonosManager.getMute(device: member)
                        speakerMutes[member.id] = m
                        if !m { allMuted = false }
                    }
                    isMuted = allMuted
                } else if let coordinator = group.coordinator {
                    let m = try await sonosManager.getMute(device: coordinator)
                    speakerMutes[coordinator.id] = m
                    isMuted = m
                }
            }

            isLoading = false
        } catch {
            // Silently retry on next poll
        }
    }
}
