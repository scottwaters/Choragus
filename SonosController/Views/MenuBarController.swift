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
            button.image = NSImage(systemSymbolName: "hifispeaker.fill", accessibilityDescription: "SonosController")
            button.image?.size = NSSize(width: 16, height: 16)
            button.action = #selector(togglePopover)
            button.target = self
        }
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

    /// Resolved art URL — checks discovered art cache for better art (iTunes, radio track)
    /// then falls back to metadata albumArtURI
    private var resolvedArtURL: URL? {
        let meta = trackMetadata
        // Check cached art by title or URI
        if let cached = sonosManager.lookupCachedArt(uri: meta.trackURI, title: meta.title),
           let url = URL(string: cached) {
            return url
        }
        if let art = meta.albumArtURI, !art.isEmpty {
            return URL(string: art)
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            // Album art + track info hero area
            ZStack(alignment: .bottomLeading) {
                // Art background (blurred)
                if let url = resolvedArtURL {
                    CachedAsyncImage(url: url, cornerRadius: 0)
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
                            CachedAsyncImage(url: url, cornerRadius: 6)
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

                        Text(trackMetadata.title.isEmpty ? "Not Playing" : trackMetadata.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)

                        if !trackMetadata.artist.isEmpty && !TrackMetadata.isDeviceID(trackMetadata.artist) {
                            Text(trackMetadata.artist)
                                .font(.system(size: 11))
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
                            .font(.system(size: 10))
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
                        }
                    }
                }

                // Transport controls
                HStack(spacing: 24) {
                    Button {
                        guard let group = selectedGroup else { return }
                        Task { try? await sonosManager.previous(group: group) }
                    } label: {
                        Image(systemName: "backward.fill")
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
                        Image(systemName: "forward.fill")
                            .font(.system(size: 16))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
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
                            .font(.system(size: 11))
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
                    if let window = NSApp.windows.first(where: { $0.title.contains("Sonos") || $0.isKeyWindow }) {
                        window.makeKeyAndOrderFront(nil)
                    } else {
                        NSApp.windows.first?.makeKeyAndOrderFront(nil)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "macwindow")
                            .font(.system(size: 10))
                        Text("Open SonosController")
                            .font(.system(size: 11))
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
}
