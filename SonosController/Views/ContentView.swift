/// ContentView.swift — Top-level layout with sidebar/detail split and toolbar.
///
/// Manages the three-panel layout: room list sidebar, now-playing center,
/// and optional browse/queue side panels. Also hosts the stale-data and
/// cache banners that appear when Quick Start mode is active.
import SwiftUI
import SonosKit

struct ContentView: View {
    @EnvironmentObject var sonosManager: SonosManager
    @EnvironmentObject var presetManager: PresetManager
    @EnvironmentObject var playHistoryManager: PlayHistoryManager
    @EnvironmentObject var smapiManager: SMAPIAuthManager
    @State private var selectedGroupID: String?
    @State private var showQueue = false
    @State private var showBrowse = false
    // Alarms: Sonos S2 app uses cloud API for alarms, not local UPnP AlarmClock.
    // UPnP returns 0 alarms. Feature removed until cloud API access is available.
    @State private var showSettings = false
    @State private var showPresetManager = false
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .automatic

    private var selectedGroup: SonosGroup? {
        guard let id = selectedGroupID else { return nil }
        return sonosManager.groups.first { $0.id == id }
    }

    private let nowPlayingMinWidth: CGFloat = 640
    private let browseMinWidth: CGFloat = 260
    private let queueMinWidth: CGFloat = 280
    private let sidebarWidth: CGFloat = 200

    /// Calculates panel widths ensuring now playing always gets at least its minimum.
    /// Browse and queue share whatever space remains after now playing is guaranteed.
    private func panelWidths(totalWidth: CGFloat) -> (browse: CGFloat, nowPlaying: CGFloat, queue: CGFloat) {
        let remaining = totalWidth - nowPlayingMinWidth
        // Ideal sizes for side panels
        let idealBrowse = showBrowse ? min(totalWidth * 0.35, 400) : 0
        let idealQueue = showQueue ? min(totalWidth * 0.3, 400) : 0
        let idealTotal = idealBrowse + idealQueue

        let bw: CGFloat
        let qw: CGFloat
        if idealTotal <= remaining {
            // Enough room — use ideal sizes
            bw = idealBrowse
            qw = idealQueue
        } else if idealTotal > 0 {
            // Not enough room — shrink side panels proportionally, respecting minimums
            let ratio = remaining / idealTotal
            bw = showBrowse ? max(browseMinWidth, idealBrowse * ratio) : 0
            qw = showQueue ? max(queueMinWidth, idealQueue * ratio) : 0
        } else {
            bw = 0
            qw = 0
        }
        let nw = max(nowPlayingMinWidth, totalWidth - bw - qw)
        return (bw, nw, qw)
    }

    /// Minimum window width needed for current panel configuration
    private var requiredMinWidth: CGFloat {
        var width = sidebarWidth + nowPlayingMinWidth
        if showBrowse { width += browseMinWidth }
        if showQueue { width += queueMinWidth }
        return width
    }

    /// Ensures the window is wide enough for the current panels
    private func ensureWindowFits() {
        guard let window = NSApp.mainWindow else { return }
        let needed = requiredMinWidth
        if window.frame.width < needed {
            var frame = window.frame
            let growth = needed - frame.width
            frame.size.width = needed
            // Grow from center
            frame.origin.x -= growth / 2
            // Keep on screen
            if let screen = window.screen {
                let screenFrame = screen.visibleFrame
                if frame.origin.x < screenFrame.minX {
                    frame.origin.x = screenFrame.minX
                }
                if frame.maxX > screenFrame.maxX {
                    frame.origin.x = screenFrame.maxX - frame.width
                }
            }
            window.setFrame(frame, display: true, animate: true)
        }
    }

    @ObservedObject private var errorHandler = ErrorHandler.shared

    var body: some View {
        VStack(spacing: 0) {
            // Error banner
            if errorHandler.showError, let errorMsg = errorHandler.currentError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(errorMsg)
                        .font(.caption)
                        .lineLimit(2)
                    Spacer()
                    Button {
                        errorHandler.dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.red.opacity(0.1))
            }

            // Stale data / cache banner
            if let message = sonosManager.staleMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.caption)
                    Spacer()
                    Button(L10n.dismiss) {
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
                    Text("\(L10n.usingCachedData) (\(sonosManager.cacheAge))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if sonosManager.isRefreshing {
                        ProgressView()
                            .controlSize(.mini)
                        Text(L10n.refreshing)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(.blue.opacity(0.05))
            }

            NavigationSplitView(columnVisibility: $sidebarVisibility) {
                RoomListView(selectedGroupID: $selectedGroupID)
                    .navigationSplitViewColumnWidth(min: 140, ideal: 180, max: 220)
            } detail: {
                if let group = selectedGroup {
                    GeometryReader { geo in
                        let sizes = panelWidths(totalWidth: geo.size.width)
                        HStack(spacing: 0) {
                            if showBrowse {
                                BrowseView(group: group)
                                    .environmentObject(sonosManager)
                                    .frame(width: sizes.browse)
                                Divider()
                            }

                            NowPlayingView(group: group, sonosManager: sonosManager, playHistoryManager: playHistoryManager)
                                .frame(width: sizes.nowPlaying)

                            if showQueue {
                                Divider()
                                QueueView(group: group, sonosManager: sonosManager)
                                    .frame(width: sizes.queue)
                            }
                        }
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "hifispeaker.2")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        if sonosManager.groups.isEmpty && !sonosManager.isUsingCachedData {
                            Text(L10n.searchingForSpeakers)
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            ProgressView()
                        } else if sonosManager.groups.isEmpty {
                            Text(L10n.loadingCachedSpeakers)
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            ProgressView()
                        } else {
                            Text(L10n.selectARoom)
                                .font(.title2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
            .onAppear {
                restoreLastSelectedGroup()
                if selectedGroupID == nil {
                    sidebarVisibility = .all
                }
            }
            .onChange(of: selectedGroupID) {
                UserDefaults.standard.set(selectedGroupID, forKey: UDKey.lastSelectedGroupID)
            }
            .onChange(of: sonosManager.groups) {
                // When groups load/change, try to restore selection if nothing selected
                if selectedGroupID == nil || selectedGroup == nil {
                    restoreLastSelectedGroup()
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        showBrowse.toggle()
                        if showBrowse {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { ensureWindowFits() }
                        }
                    } label: {
                        Image(systemName: "square.grid.2x2")
                    }
                    .help(L10n.browseMusicLibrary)
                    .disabled(selectedGroupID == nil)

                    Button {
                        showQueue.toggle()
                        if showQueue {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { ensureWindowFits() }
                        }
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .help(L10n.showPlayQueue)
                    .disabled(selectedGroupID == nil)

                    Menu {
                        Button("Pause All") {
                            Task { await sonosManager.pauseAll() }
                        }
                        Button("Resume All") {
                            Task { await sonosManager.resumeAll() }
                        }
                        Divider()
                        Button(L10n.muteAllSpeakers) {
                            Task { await muteAll(muted: true) }
                        }
                        Button(L10n.unmuteAllSpeakers) {
                            Task { await muteAll(muted: false) }
                        }
                        Section(L10n.groupPresets) {
                            Button(L10n.managePresets) {
                                showPresetManager = true
                            }
                            ForEach(presetManager.presets) { preset in
                                Button(preset.name) {
                                    Task {
                                        await presetManager.applyPreset(preset, using: sonosManager)
                                    }
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "speaker.wave.3")
                    }
                    .help(L10n.muteOrUnmuteAll)
                    .sheet(isPresented: $showPresetManager) {
                        PresetManagerView()
                            .environmentObject(sonosManager)
                            .environmentObject(presetManager)
                    }

                    Button {
                        WindowManager.shared.togglePlayHistory()
                    } label: {
                        Image(systemName: "chart.bar.xaxis")
                    }
                    .help("Listening Stats")

                    Button {
                        sonosManager.rescan()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help(L10n.rescanNetwork)

                    Button {
                        showSettings.toggle()
                    } label: {
                        Image(systemName: "gear")
                    }
                    .help(L10n.appSettings)
                    .sheet(isPresented: $showSettings) {
                        SettingsView()
                            .environmentObject(sonosManager)
                            .environmentObject(playHistoryManager)
                            .environmentObject(smapiManager)
                    }
                }
            }
        }
    }

    /// Restores last selected group, falling back to coordinator if the group no longer exists
    private func restoreLastSelectedGroup() {
        guard !sonosManager.groups.isEmpty else { return }
        guard let lastID = UserDefaults.standard.string(forKey: UDKey.lastSelectedGroupID) else { return }

        // Exact match — group still exists
        if sonosManager.groups.contains(where: { $0.id == lastID }) {
            selectedGroupID = lastID
            return
        }

        // Group gone — find a group containing a device that was the coordinator
        // The lastID is a zone group ID; try to find the coordinator device in another group
        if let group = sonosManager.groups.first(where: { group in
            group.members.contains { $0.id == lastID }
        }) {
            selectedGroupID = group.id
            return
        }

        // Last resort — select first group
        selectedGroupID = sonosManager.groups.first?.id
    }

    private func muteAll(muted: Bool) async {
        // Mute/unmute all visible speakers across all groups
        var seen = Set<String>()
        for group in sonosManager.groups {
            for member in group.members {
                guard !seen.contains(member.id) else { continue }
                seen.insert(member.id)
                do {
                    try await sonosManager.setMute(device: member, muted: muted)
                } catch {
                    ErrorHandler.shared.handle(error, context: "MUTE")
                }
            }
        }
    }
}
