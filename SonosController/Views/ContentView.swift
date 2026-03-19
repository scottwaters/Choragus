/// ContentView.swift — Top-level layout with sidebar/detail split and toolbar.
///
/// Manages the three-panel layout: room list sidebar, now-playing center,
/// and optional browse/queue side panels. Also hosts the stale-data and
/// cache banners that appear when Quick Start mode is active.
import SwiftUI
import SonosKit

struct ContentView: View {
    @EnvironmentObject var sonosManager: SonosManager
    @State private var selectedGroupID: String?
    @State private var showQueue = false
    @State private var showBrowse = false
    @State private var showAlarms = false
    @State private var showSettings = false

    private var selectedGroup: SonosGroup? {
        guard let id = selectedGroupID else { return nil }
        return sonosManager.groups.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Stale data / cache banner
            if let message = sonosManager.staleMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.caption)
                    Spacer()
                    Button("Dismiss") {
                        sonosManager.dismissStaleMessage()
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.orange.opacity(0.1))
            } else if sonosManager.isUsingCachedData {
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(.blue)
                        .font(.caption)
                    Text("Using cached data (from \(sonosManager.cacheAge))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if sonosManager.isRefreshing {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Refreshing...")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(.blue.opacity(0.05))
            }

            NavigationSplitView {
                RoomListView(selectedGroupID: $selectedGroupID)
            } detail: {
                if let group = selectedGroup {
                    HSplitView {
                        if showBrowse {
                            BrowseView(group: group)
                                .environmentObject(sonosManager)
                                .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
                        }

                        NowPlayingView(group: group)
                            .frame(minWidth: 400)

                        if showQueue {
                            QueueView(group: group)
                                .frame(minWidth: 280, idealWidth: 320, maxWidth: 400)
                        }
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "hifispeaker.2")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        if sonosManager.groups.isEmpty && !sonosManager.isUsingCachedData {
                            Text("Searching for Sonos speakers...")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            ProgressView()
                        } else if sonosManager.groups.isEmpty {
                            Text("Loading cached speakers...")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            ProgressView()
                        } else {
                            Text("Select a room")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        showBrowse.toggle()
                    } label: {
                        Image(systemName: "square.grid.2x2")
                    }
                    .help("Toggle Browse")
                    .disabled(selectedGroupID == nil)

                    Button {
                        showQueue.toggle()
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .help("Toggle Queue")
                    .disabled(selectedGroupID == nil)

                    Button {
                        showAlarms.toggle()
                    } label: {
                        Image(systemName: "alarm")
                    }
                    .help("Alarms")
                    .popover(isPresented: $showAlarms) {
                        AlarmsView()
                            .environmentObject(sonosManager)
                            .frame(width: 340, height: 400)
                    }

                    Menu {
                        Button("Mute All Speakers") {
                            Task { await muteAll(muted: true) }
                        }
                        Button("Unmute All Speakers") {
                            Task { await muteAll(muted: false) }
                        }
                    } label: {
                        Image(systemName: "speaker.wave.3")
                    }
                    .help("Mute/Unmute All")

                    Button {
                        sonosManager.rescan()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Rescan for speakers")

                    Button {
                        showSettings.toggle()
                    } label: {
                        Image(systemName: "gear")
                    }
                    .help("Settings")
                    .sheet(isPresented: $showSettings) {
                        SettingsView()
                            .environmentObject(sonosManager)
                    }
                }
            }
        }
    }

    private func muteAll(muted: Bool) async {
        // Mute/unmute all visible speakers across all groups
        var seen = Set<String>()
        for group in sonosManager.groups {
            for member in group.members {
                guard !seen.contains(member.id) else { continue }
                seen.insert(member.id)
                try? await sonosManager.setMute(device: member, muted: muted)
            }
        }
    }
}
