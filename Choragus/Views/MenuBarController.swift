/// MenuBarController.swift — Menu bar status item with mini player controls.
import SwiftUI
import AppKit
import SonosKit

@MainActor
final class MenuBarController {
    static let shared = MenuBarController()

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    var sonosManager: SonosManager?

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: UDKey.menuBarEnabled) }
        set {
            UserDefaults.standard.set(newValue, forKey: UDKey.menuBarEnabled)
            if newValue { show() } else { hide() }
        }
    }

    func setup(sonosManager: SonosManager) {
        self.sonosManager = sonosManager
        if isEnabled { show() }
    }

    func show() {
        guard statusItem == nil else { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            // Code-drawn template glyph following Apple's HIG for menu
            // bar extras: monochrome silhouette, isTemplate = true so
            // macOS auto-tints for light / dark / tinted-wallpaper
            // modes (matching system items like Wi-Fi, Volume, Battery).
            // Echoes the Choragus icon's "central node with satellites"
            // motif at a size that's legible at 18pt.
            button.image = MenuBarController.makeTemplateIcon()
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    /// "C with centred dot" — a stroked open arc forming a stylised
    /// C (Choragus brand initial) with a small filled dot at its
    /// centre representing the conductor / chorus leader. Drawn pure
    /// black on transparent + isTemplate=true so AppKit handles all
    /// the tinting (light, dark, tinted-wallpaper).
    private static func makeTemplateIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let cx = rect.midX
            let cy = rect.midY

            // Open C: 270° arc with the gap on the right. Rendered
            // by stroking a circle along that arc range. Plain
            // NSBezierPath uses degrees and counter-clockwise by
            // default — we sweep from 45° → 315° going CCW for a
            // clean right-side opening.
            let radius: CGFloat = 6.5
            let lineWidth: CGFloat = 2.0
            let arc = NSBezierPath()
            arc.lineWidth = lineWidth
            arc.lineCapStyle = .round
            arc.appendArc(
                withCenter: NSPoint(x: cx, y: cy),
                radius: radius,
                startAngle: 45,
                endAngle: 315,
                clockwise: false
            )
            arc.stroke()

            // Centre dot — small filled circle, the "conductor".
            let dotR: CGFloat = 1.6
            NSBezierPath(ovalIn: NSRect(
                x: cx - dotR, y: cy - dotR, width: dotR * 2, height: dotR * 2
            )).fill()

            return true
        }
        image.isTemplate = true
        return image
    }

    func hide() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
        popover?.close()
        popover = nil
    }

    @objc private func togglePopover() {
        if let popover = popover, popover.isShown {
            popover.close()
        } else {
            guard let sonosManager = sonosManager, let button = statusItem?.button else { return }
            let pop = NSPopover()
            pop.contentSize = NSSize(width: 320, height: 380)
            pop.behavior = .transient
            pop.contentViewController = NSHostingController(
                rootView: MenuBarPlayerView()
                    .environmentObject(sonosManager)
            )
            pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover = pop
        }
    }
}

// MARK: - Mini Player View

struct MenuBarPlayerView: View {
    @EnvironmentObject var sonosManager: SonosManager
    @State private var selectedGroupID: String?
    @State private var isHoveringArt = false
    @State private var starRevision = 0

    private var selectedGroup: SonosGroup? {
        guard let id = selectedGroupID else { return sonosManager.groups.first }
        return sonosManager.groups.first { $0.id == id } ?? sonosManager.groups.first
    }

    private func syncFromMainUI() {
        if let lastID = UserDefaults.standard.string(forKey: UDKey.lastSelectedGroupID),
           sonosManager.groups.contains(where: { $0.id == lastID }) {
            selectedGroupID = lastID
        }
    }

    private var transportState: TransportState {
        guard let group = selectedGroup else { return .stopped }
        return sonosManager.groupTransportStates[group.coordinatorID] ?? .stopped
    }

    private var trackMetadata: TrackMetadata {
        guard let group = selectedGroup else { return TrackMetadata() }
        return sonosManager.groupTrackMetadata[group.coordinatorID] ?? TrackMetadata()
    }

    private var volume: Double {
        guard let group = selectedGroup else { return 0 }
        let vols = group.members.compactMap { sonosManager.deviceVolumes[$0.id] }
        return vols.isEmpty ? 0 : Double(vols.reduce(0, +)) / Double(vols.count)
    }

    private var isMuted: Bool {
        guard let group = selectedGroup else { return false }
        return group.members.contains { sonosManager.deviceMutes[$0.id] == true }
    }

    /// Resolved art URL — checks in priority order:
    ///   1. User's persisted art override (manual `Search Artwork` choice)
    ///   2. Title-keyed cached art (radio-track auto-resolves write here
    ///      via `sonosManager.cacheArtURL`, so this is the track-specific
    ///      art for radio when iTunes resolved it)
    ///   3. Speaker's `albumArtURI` (canonical for non-radio; the station
    ///      logo for radio)
    /// On radio the cache wins over `albumArtURI` because `albumArtURI`
    /// is the station logo, not the song. For non-radio tracks the
    /// cache miss falls through to `albumArtURI` which is canonical.
    /// Mirrors the priority `ArtResolver.artURLForDisplay` uses for the
    /// inline view.
    private var resolvedArtURL: URL? {
        let meta = trackMetadata
        // Step 1: persisted override.
        let overrideKey = (!meta.title.isEmpty ? meta.title : meta.stationName)
            .lowercased()
        if !overrideKey.isEmpty {
            let udKey = "\(UDKey.artOverridePrefix)\(overrideKey)"
            if let saved = UserDefaults.standard.string(forKey: udKey) {
                if saved == "IGNORE" { return nil }
                if let url = URL(string: saved) { return url }
            }
        }
        // Step 2: cached track art. `searchRadioTrackArt` writes to
        // `sonosManager.cacheArtURL` whenever it resolves a real
        // track-specific URL via iTunes — this is exactly the lookup
        // that surfaces it for the menubar.
        if let cached = sonosManager.lookupCachedArt(uri: meta.trackURI, title: meta.title),
           !cached.isEmpty, let url = URL(string: cached) {
            return url
        }
        // Step 3: speaker's reported art.
        if let art = meta.albumArtURI, !art.isEmpty,
           let url = URL(string: art) {
            return url
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            // Album art + track info hero area
            ZStack(alignment: .bottomLeading) {
                // Art background (blurred)
                if let url = resolvedArtURL {
                    CachedAsyncImage(url: url, cornerRadius: 0, priority: .interactive)
                        .frame(height: 140)
                        .clipped()
                        .blur(radius: 20)
                        .overlay(Color.black.opacity(0.4))
                } else {
                    LinearGradient(colors: [.purple.opacity(0.4), .blue.opacity(0.4)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                        .frame(height: 140)
                }

                HStack(spacing: 12) {
                    // Album art
                    Group {
                        if let url = resolvedArtURL {
                            CachedAsyncImage(url: url, cornerRadius: 6, priority: .interactive)
                        } else {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(.ultraThinMaterial)
                                .overlay {
                                    Image(systemName: trackMetadata.stationName.isEmpty ? "music.note" : "radio")
                                        .font(.title3)
                                        .foregroundStyle(.white.opacity(0.6))
                                }
                        }
                    }
                    .frame(width: 64, height: 64)
                    .shadow(color: .black.opacity(0.3), radius: 6, y: 2)

                    // Track info
                    VStack(alignment: .leading, spacing: 3) {
                        if !trackMetadata.stationName.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                    .font(.system(size: 8))
                                Text(trackMetadata.stationName)
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                        }

                        Text(trackMetadata.title.isEmpty ? L10n.notPlaying : trackMetadata.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)

                        if !trackMetadata.artist.isEmpty && !TrackMetadata.isDeviceID(trackMetadata.artist) {
                            Text(trackMetadata.artist)
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.8))
                                .lineLimit(1)
                        }
                    }

                    Spacer()
                }
                .padding(12)
            }
            .frame(height: 140)
            .clipped()

            VStack(spacing: 14) {
                // Room picker
                if sonosManager.groups.count > 1 {
                    HStack(spacing: 6) {
                        Image(systemName: "hifispeaker")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Picker("", selection: $selectedGroupID) {
                            ForEach(sonosManager.groups.sorted { $0.name < $1.name }) { group in
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(sonosManager.groupTransportStates[group.coordinatorID]?.isPlaying == true ? .green : .gray.opacity(0.4))
                                        .frame(width: 6, height: 6)
                                    Text(group.name)
                                }
                                .tag(Optional(group.id))
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .onChange(of: selectedGroupID) {
                            UserDefaults.standard.set(selectedGroupID, forKey: UDKey.lastSelectedGroupID)
                            NotificationCenter.default.post(name: .selectedGroupChanged, object: nil)
                        }
                    }
                }

                // Transport controls
                HStack(spacing: 24) {
                    Button {
                        guard let group = selectedGroup else { return }
                        Task { try? await sonosManager.previous(group: group) }
                    } label: {
                        Image(systemName: "backward.end.fill")
                            .font(.system(size: 16))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)

                    Button {
                        guard let group = selectedGroup else { return }
                        Task {
                            if transportState.isPlaying {
                                try? await sonosManager.pause(group: group)
                            } else {
                                try? await sonosManager.play(group: group)
                            }
                        }
                    } label: {
                        Image(systemName: transportState.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 38))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)

                    Button {
                        guard let group = selectedGroup else { return }
                        Task { try? await sonosManager.next(group: group) }
                    } label: {
                        Image(systemName: "forward.end.fill")
                            .font(.system(size: 16))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)

                    // Star current track
                    Button { starCurrentTrack() } label: {
                        Image(systemName: isCurrentTrackStarred ? "star.fill" : "star")
                            .font(.system(size: 14))
                            .foregroundStyle(isCurrentTrackStarred ? .yellow : .secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(trackMetadata.title.isEmpty)
                    .opacity(trackMetadata.title.isEmpty ? 0.3 : 1)
                }

                // Volume
                HStack(spacing: 8) {
                    Button {
                        guard let group = selectedGroup else { return }
                        let newMuted = !isMuted
                        for member in group.members {
                            sonosManager.updateDeviceMute(member.id, muted: newMuted)
                            Task { try? await sonosManager.setMute(device: member, muted: newMuted) }
                        }
                    } label: {
                        Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.fill")
                            .font(.subheadline)
                            .foregroundStyle(isMuted ? .red.opacity(0.8) : .secondary)
                            .frame(width: 16)
                    }
                    .buttonStyle(.plain)

                    Slider(value: Binding(
                        get: { volume },
                        set: { newVol in
                            guard let group = selectedGroup else { return }
                            let oldVol = volume
                            let proportional = UserDefaults.standard.bool(forKey: UDKey.proportionalGroupVolume)

                            for member in group.members {
                                let currentVol = Double(sonosManager.deviceVolumes[member.id] ?? 0)
                                let newMemberVol: Int
                                if proportional && oldVol > 0 {
                                    newMemberVol = Int(max(0, min(100, currentVol * (newVol / oldVol))))
                                } else {
                                    newMemberVol = Int(max(0, min(100, currentVol + (newVol - oldVol))))
                                }
                                sonosManager.updateDeviceVolume(member.id, volume: newMemberVol)
                                Task { try? await sonosManager.setVolume(device: member, volume: newMemberVol) }
                            }
                        }
                    ), in: 0...100)

                    Text("\(Int(volume))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, alignment: .trailing)
                }

                // Show main window
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    // Find existing main window or create new one
                    if let window = NSApp.windows.first(where: {
                        // Title is "Choragus" (post-rename) — also accept the old
                        // "SonosController" title for users running mid-upgrade
                        // builds with cached window state.
                        ($0.title.contains("Choragus") || $0.title.contains("SonosController"))
                            && $0.contentView != nil
                    }) {
                        window.makeKeyAndOrderFront(nil)
                    } else {
                        // No window exists — trigger SwiftUI to create a new one
                        NSApp.sendAction(Selector(("newWindowForTab:")), to: nil, from: nil)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "macwindow")
                            .font(.footnote)
                        Text(L10n.openChoragus)
                            .font(.subheadline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(14)
        }
        .tint(sonosManager.resolvedAccentColor ?? .accentColor)
        .onAppear { syncFromMainUI() }
    }

    // MARK: - Star

    private var isCurrentTrackStarred: Bool {
        _ = starRevision // force dependency on revision to trigger re-eval
        guard !trackMetadata.title.isEmpty else { return false }
        return sonosManager.playHistoryManager?.entries.contains {
            $0.title == trackMetadata.title && $0.artist == trackMetadata.artist && $0.starred
        } ?? false
    }

    private func starCurrentTrack() {
        guard !trackMetadata.title.isEmpty,
              let manager = sonosManager.playHistoryManager else { return }
        if let entry = manager.entries.last(where: {
            $0.title == trackMetadata.title && $0.artist == trackMetadata.artist
        }) {
            manager.toggleStar(id: entry.id)
            starRevision += 1
        }
    }
}
