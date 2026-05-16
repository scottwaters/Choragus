/// MediaKeyHandler — bridges macOS keyboard media keys (F7/F8/F9 hardware
/// row, plus a custom ⌃⌥↑/↓/M chord for volume) to SonosManager actions
/// on the currently selected group.
///
/// Two interception channels with different reach:
///
/// - `MPRemoteCommandCenter` for transport (play/pause/next/previous).
///   System-wide; macOS routes the hardware media keys to whichever app
///   most recently published `MPNowPlayingInfoCenter` data, so this
///   handler also mirrors the selected group's title/artist/album and
///   playback rate into the now-playing center as the source of truth.
///   No special entitlements required; works in the App Sandbox.
///
/// - `NSEvent.addLocalMonitorForEvents` for the volume chord. Frontmost-
///   only by design: macOS reserves F10/F11/F12 for the system audio HUD
///   and only an Accessibility-permitted, non-sandbox tool can intercept
///   them. ⌃⌥↑/↓/M sidesteps that without leaving the sandbox.
///
/// All error paths emit through `sonosDiagLog` (tag "MEDIA-KEYS") so
/// failed transport / volume calls land in the Diagnostics window.
import Foundation
import AppKit
import MediaPlayer
import Combine

@MainActor
public final class MediaKeyHandler: ObservableObject {
    public static let shared = MediaKeyHandler()

    private weak var sonosManager: SonosManager?
    private var localMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private var commandsRegistered = false
    private var lastPublishedNowPlayingKey: String = ""
    /// Tracks the album-art URL most recently published to
    /// `MPNowPlayingInfoCenter`. Used to dedupe artwork fetches and to
    /// detect when the underlying art changed so we can re-download.
    private var lastPublishedArtURL: String = ""
    /// In-flight artwork download. Cancelled when the art URL changes
    /// so a slow LAN fetch for a previous track can't overwrite a fresh
    /// fetch's result.
    private var artworkFetchTask: URLSessionDataTask?

    /// Linear step applied per ⌃⌥↑/↓ press. Matches the scroll-wheel
    /// step in `NowPlayingViewModel.applyScrollVolumeStep` so the two
    /// input paths feel calibrated together.
    private static let volumeStep: Int = 5

    private init() {}

    // MARK: - Lifecycle

    public func start(sonosManager: SonosManager) {
        self.sonosManager = sonosManager
        registerRemoteCommands()
        installLocalKeyMonitor()
        // Eagerly seed MPNowPlayingInfoCenter BEFORE observing changes.
        // macOS's `rcd` daemon routes media keys to whichever app most
        // recently published Now Playing info AND set a non-`.unknown`
        // playbackState. Without this seed, Music.app — if it is
        // running — wins the routing because it publishes a
        // .stopped/.paused state at launch and Choragus isn't yet a
        // candidate. The placeholder is overwritten as soon as a real
        // track is selected.
        seedInitialNowPlayingClaim()
        observeSonosManagerForNowPlaying()
        sonosDiagLog(.info, tag: "MEDIA-KEYS", "MediaKeyHandler started")
    }

    public func stop() {
        if let token = localMonitor {
            NSEvent.removeMonitor(token)
            localMonitor = nil
        }
        cancellables.removeAll()
        unregisterRemoteCommands()
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
    }

    // MARK: - MPRemoteCommandCenter (transport)

    private func registerRemoteCommands() {
        guard !commandsRegistered else { return }
        commandsRegistered = true
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            self?.handleTransport(.play) ?? .commandFailed
        }
        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            self?.handleTransport(.pause) ?? .commandFailed
        }
        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.handleTransport(.togglePlayPause) ?? .commandFailed
        }
        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.handleTransport(.next) ?? .commandFailed
        }
        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.handleTransport(.previous) ?? .commandFailed
        }
    }

    private func unregisterRemoteCommands() {
        guard commandsRegistered else { return }
        commandsRegistered = false
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = false
        center.pauseCommand.isEnabled = false
        center.togglePlayPauseCommand.isEnabled = false
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
    }

    private enum TransportAction { case play, pause, togglePlayPause, next, previous }

    private func handleTransport(_ action: TransportAction) -> MPRemoteCommandHandlerStatus {
        guard let manager = sonosManager, let group = currentGroup() else {
            sonosDiagLog(.warning, tag: "MEDIA-KEYS",
                         "Transport key with no selected group — ignored",
                         context: ["action": String(describing: action)])
            return .noSuchContent
        }

        let isPlaying = manager.groupTransportStates[group.coordinatorID]?.isPlaying ?? false

        Task { @MainActor in
            do {
                switch action {
                case .play:
                    try await manager.play(group: group)
                case .pause:
                    try await manager.pause(group: group)
                case .togglePlayPause:
                    if isPlaying {
                        try await manager.pause(group: group)
                    } else {
                        try await manager.play(group: group)
                    }
                case .next:
                    try await manager.next(group: group)
                case .previous:
                    try await manager.previous(group: group)
                }
            } catch {
                sonosDiagLog(.error, tag: "MEDIA-KEYS",
                             "Transport command failed: \(error.localizedDescription)",
                             context: [
                                "action": String(describing: action),
                                "group": group.name
                             ])
            }
        }
        return .success
    }

    // MARK: - Local key monitor (volume chord)

    private func installLocalKeyMonitor() {
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if self.handleVolumeChord(event) {
                return nil
            }
            return event
        }
    }

    /// Returns `true` if the event matched a volume chord and was
    /// consumed; `false` if it should pass through to the responder
    /// chain. Required modifier set is exactly Control+Option (any other
    /// modifier — Command, Shift — disqualifies, so the existing menu
    /// shortcuts ⌥⌘↓ etc. are not double-handled).
    private func handleVolumeChord(_ event: NSEvent) -> Bool {
        let required: NSEvent.ModifierFlags = [.control, .option]
        let masked = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let allowed: NSEvent.ModifierFlags = [.control, .option, .capsLock]
        guard masked.contains(required), masked.subtracting(allowed).isEmpty else {
            return false
        }

        switch event.keyCode {
        case 126: // Up arrow
            adjustVolume(by: Self.volumeStep)
            return true
        case 125: // Down arrow
            adjustVolume(by: -Self.volumeStep)
            return true
        case 46:  // M
            toggleMute()
            return true
        default:
            return false
        }
    }

    private func adjustVolume(by delta: Int) {
        guard let manager = sonosManager, let group = currentGroup() else {
            sonosDiagLog(.warning, tag: "MEDIA-KEYS",
                         "Volume key with no selected group — ignored",
                         context: ["delta": String(delta)])
            return
        }
        let members = group.members
        guard !members.isEmpty else { return }

        let snapshot: [(SonosDevice, Int)] = members.map { device in
            let current = manager.deviceVolumes[device.id] ?? 0
            let next = max(0, min(100, current + delta))
            return (device, next)
        }
        // Optimistic local write so the UI reflects the change before the
        // SOAP round-trip completes — matches NowPlayingViewModel.commitVolume.
        for (device, value) in snapshot {
            manager.updateDeviceVolume(device.id, volume: value)
        }
        Task { @MainActor in
            await withTaskGroup(of: Void.self) { tg in
                for (device, value) in snapshot {
                    tg.addTask { @MainActor in
                        do {
                            try await manager.setVolume(device: device, volume: value)
                        } catch {
                            sonosDiagLog(.error, tag: "MEDIA-KEYS",
                                         "Volume write failed: \(error.localizedDescription)",
                                         context: [
                                            "room": device.roomName,
                                            "target": String(value)
                                         ])
                        }
                    }
                }
            }
        }
    }

    private func toggleMute() {
        guard let manager = sonosManager, let group = currentGroup() else {
            sonosDiagLog(.warning, tag: "MEDIA-KEYS",
                         "Mute key with no selected group — ignored")
            return
        }
        let members = group.members
        guard let probe = members.first else { return }
        let newMuted = !(manager.deviceMutes[probe.id] ?? false)

        for member in members {
            manager.updateDeviceMute(member.id, muted: newMuted)
        }
        Task { @MainActor in
            await withTaskGroup(of: Void.self) { tg in
                for member in members {
                    tg.addTask { @MainActor in
                        do {
                            try await manager.setMute(device: member, muted: newMuted)
                        } catch {
                            sonosDiagLog(.error, tag: "MEDIA-KEYS",
                                         "Mute write failed: \(error.localizedDescription)",
                                         context: [
                                            "room": member.roomName,
                                            "target": newMuted ? "mute" : "unmute"
                                         ])
                        }
                    }
                }
            }
        }
    }

    // MARK: - Now-playing info mirror

    /// macOS routes hardware media keys to whichever app most recently
    /// updated `MPNowPlayingInfoCenter`. Mirroring the selected group's
    /// metadata + playback state keeps Choragus the active recipient
    /// while it is running, even if it isn't frontmost.
    private func observeSonosManagerForNowPlaying() {
        guard let manager = sonosManager else { return }
        manager.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                // objectWillChange fires before the value mutation lands;
                // hop to the next runloop tick so reads see the new state.
                DispatchQueue.main.async { self?.refreshNowPlayingInfo() }
            }
            .store(in: &cancellables)
    }

    private func refreshNowPlayingInfo() {
        guard let manager = sonosManager, let group = currentGroup() else {
            // Don't blank the info center on transient "no group" states —
            // doing that hands the media-key route back to Music.app
            // until the next refresh. Keep the seed claim in place.
            return
        }
        let meta = manager.groupTrackMetadata[group.coordinatorID] ?? TrackMetadata()
        let transport = manager.groupTransportStates[group.coordinatorID] ?? .stopped
        let isPlaying = transport.isPlaying
        // Cheap dedup: skip the system call when the user-visible payload
        // hasn't changed. objectWillChange fires far more often than the
        // displayed track / state actually changes.
        let key = "\(group.coordinatorID)|\(meta.title)|\(meta.artist)|\(meta.album)|\(transport.rawValue)"
        guard key != lastPublishedNowPlayingKey else { return }
        lastPublishedNowPlayingKey = key

        var info: [String: Any] = [
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        let title = meta.title.isEmpty ? "Choragus" : meta.title
        info[MPMediaItemPropertyTitle] = title
        if !meta.artist.isEmpty { info[MPMediaItemPropertyArtist] = meta.artist }
        if !meta.album.isEmpty { info[MPMediaItemPropertyAlbumTitle] = meta.album }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        // playbackState is the master signal `rcd` uses to pick the
        // active media app on macOS 11.4+. Without this set,
        // `nowPlayingInfo` alone is insufficient and Music.app wins the
        // key route. Map TransportState → MPNowPlayingPlaybackState.
        center.playbackState = mapPlaybackState(transport)

        // Fetch the album art asynchronously and patch it onto the
        // info dict once decoded. Without `MPMediaItemPropertyArtwork`
        // macOS substitutes the app icon in the system Now Playing
        // strip — fine for the initial seed but wrong once a real
        // track is loaded.
        publishArtwork(forURL: meta.albumArtURI, expectedKey: key)
    }

    /// Downloads the speaker-reported album art and pushes it into
    /// `MPNowPlayingInfoCenter`. Off-main-thread, deduped against the
    /// previous URL, and gated by the `expectedKey` snapshot so a slow
    /// art fetch can't overwrite a newer track's artwork.
    private func publishArtwork(forURL artURL: String?, expectedKey: String) {
        let url = (artURL?.isEmpty == false) ? artURL! : ""
        // Same URL as last publish → nothing to do.
        guard url != lastPublishedArtURL else { return }
        lastPublishedArtURL = url
        // Cancel any prior in-flight fetch; its result would be stale.
        artworkFetchTask?.cancel()
        artworkFetchTask = nil
        // No URL — leave any previously-published artwork in place
        // until the next track explicitly provides new art. Avoids the
        // OS briefly falling back to the app icon on a transient
        // empty-art event mid-playback.
        guard !url.isEmpty, let parsed = URL(string: url) else { return }
        let task = URLSession.shared.dataTask(with: parsed) { [weak self] data, _, error in
            guard let self = self else { return }
            guard error == nil, let data = data, let image = NSImage(data: data) else { return }
            DispatchQueue.main.async {
                // Guard against late arrival: if the displayed track
                // has moved on since we kicked off the fetch, drop the
                // result on the floor.
                guard self.lastPublishedNowPlayingKey == expectedKey else { return }
                let center = MPNowPlayingInfoCenter.default()
                var info = center.nowPlayingInfo ?? [:]
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                info[MPMediaItemPropertyArtwork] = artwork
                center.nowPlayingInfo = info
            }
        }
        artworkFetchTask = task
        task.resume()
    }

    /// First publish on launch. Establishes Choragus as a Now Playing
    /// candidate before any track is loaded — required so the media-key
    /// router treats Choragus as a peer of Music.app, not a non-entrant.
    private func seedInitialNowPlayingClaim() {
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: "Choragus",
            MPNowPlayingInfoPropertyPlaybackRate: 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        center.playbackState = .paused
        lastPublishedNowPlayingKey = ""
    }

    private func mapPlaybackState(_ state: TransportState) -> MPNowPlayingPlaybackState {
        switch state {
        case .playing:       return .playing
        case .paused:        return .paused
        case .stopped:       return .stopped
        case .transitioning: return .playing
        case .noMedia:       return .stopped
        }
    }

    // MARK: - Group resolution

    /// Resolves the currently selected group from UserDefaults (the same
    /// key `ContentView` and `MenuBarController` write on selection).
    /// Falls back to the first group so the keys still work before the
    /// user has explicitly picked one.
    private func currentGroup() -> SonosGroup? {
        guard let manager = sonosManager else { return nil }
        let selectedID = UserDefaults.standard.string(forKey: UDKey.lastSelectedGroupID)
        if let id = selectedID, let match = manager.groups.first(where: { $0.id == id }) {
            return match
        }
        return manager.groups.first
    }
}
