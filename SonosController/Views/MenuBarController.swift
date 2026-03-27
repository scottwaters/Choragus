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
            pop.contentSize = NSSize(width: 300, height: 340)
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

    var body: some View {
        VStack(spacing: 12) {
            // Room picker
            if sonosManager.groups.count > 1 {
                Picker("", selection: $selectedGroupID) {
                    ForEach(sonosManager.groups.sorted { $0.name < $1.name }) { group in
                        Text(group.name).tag(Optional(group.id))
                    }
                }
                .labelsHidden()
                .onChange(of: selectedGroupID) {
                    UserDefaults.standard.set(selectedGroupID, forKey: UDKey.lastSelectedGroupID)
                }
            }

            // Track info
            HStack(spacing: 10) {
                if let artURI = trackMetadata.albumArtURI, let url = URL(string: artURI) {
                    CachedAsyncImage(url: url, cornerRadius: 4)
                        .frame(width: 48, height: 48)
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: "music.note")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(width: 48, height: 48)
                }

                VStack(alignment: .leading, spacing: 2) {
                    if !trackMetadata.stationName.isEmpty {
                        Text(trackMetadata.stationName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(trackMetadata.title.isEmpty ? "Not Playing" : trackMetadata.title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if !trackMetadata.artist.isEmpty && !trackMetadata.artist.hasPrefix("RINCON_") {
                        Text(trackMetadata.artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()
            }

            Divider()

            // Transport controls
            HStack(spacing: 20) {
                Button {
                    guard let group = selectedGroup else { return }
                    Task { try? await sonosManager.previous(group: group) }
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)

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
                        .font(.system(size: 36))
                }
                .buttonStyle(.plain)

                Button {
                    guard let group = selectedGroup else { return }
                    Task { try? await sonosManager.next(group: group) }
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }

            // Volume
            HStack(spacing: 8) {
                Button {
                    guard let group = selectedGroup else { return }
                    let anyMuted = group.members.contains { sonosManager.deviceMutes[$0.id] == true }
                    let newMuted = !anyMuted
                    for member in group.members {
                        sonosManager.updateDeviceMute(member.id, muted: newMuted)
                        Task { try? await sonosManager.setMute(device: member, muted: newMuted) }
                    }
                } label: {
                    let anyMuted = selectedGroup?.members.contains { sonosManager.deviceMutes[$0.id] == true } ?? false
                    Image(systemName: anyMuted ? "speaker.slash.fill" : "speaker.fill")
                        .font(.caption)
                        .foregroundStyle(anyMuted ? .red.opacity(0.8) : .secondary)
                }
                .buttonStyle(.plain)
                Slider(value: Binding(
                    get: { volume },
                    set: { newVol in
                        guard let group = selectedGroup else { return }
                        let intVol = Int(newVol)
                        for member in group.members {
                            sonosManager.updateDeviceVolume(member.id, volume: intVol)
                            Task { try? await sonosManager.setVolume(device: member, volume: intVol) }
                        }
                    }
                ), in: 0...100)
                Image(systemName: "speaker.wave.3.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // Show main window
            Button {
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first(where: { $0.title.contains("Sonos") || $0.isKeyWindow }) {
                    window.makeKeyAndOrderFront(nil)
                } else {
                    NSApp.windows.first?.makeKeyAndOrderFront(nil)
                }
            } label: {
                Text("Show Main Window")
                    .font(.caption)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(16)
        .onAppear {
            syncFromMainUI()
        }
    }
}
