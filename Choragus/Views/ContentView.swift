/// ContentView.swift — Top-level layout with sidebar/detail split and toolbar.
///
/// Manages the three-panel layout: room list sidebar, now-playing center,
/// and optional browse/queue side panels. Also hosts the stale-data and
/// cache banners that appear when Quick Start mode is active.
import SwiftUI
import SonosKit
import AppKit

struct ContentView: View {
    @EnvironmentObject var sonosManager: SonosManager
    @EnvironmentObject var presetManager: PresetManager
    @EnvironmentObject var playHistoryManager: PlayHistoryManager
    @EnvironmentObject var smapiManager: SMAPIAuthManager
    @EnvironmentObject var plexAuth: PlexAuthManager
    @ObservedObject private var localNetworkMonitor = LocalNetworkPermissionMonitor.shared
    /// Forces the entire window subtree to re-render when the user
    /// changes the app language in Settings. `L10n.tr(...)` reads
    /// `UserDefaults` every call, but SwiftUI has no way to know that
    /// read happened unless something in the view tree is observing
    /// the same UserDefault. Putting the observer at the root means
    /// every L10n string in the main window picks up the new language
    /// the moment the picker flips.
    @AppStorage(UDKey.appLanguage) private var appLanguage: String = "en"
    @AppStorage(UDKey.hideDiagnosticsIcon) private var hideDiagnosticsIcon = false
    @State private var selectedGroupID: String?
    @AppStorage(UDKey.showQueue) private var showQueue = false
    @AppStorage(UDKey.showBrowse) private var showBrowse = false
    // Alarms: Sonos S2 app uses cloud API for alarms, not local UPnP AlarmClock.
    // UPnP returns 0 alarms. Feature removed until cloud API access is available.
    @State private var showPresetManager = false

    /// Opens the proper macOS Preferences window — the standalone
    /// non-modal Settings scene wired up at App level. Replaces the
    /// previous `.sheet`-based Settings presentation, which was modal
    /// over the main window and blocked any other alert/sheet from
    /// surfacing while it was open (notably Sparkle's "Install and
    /// Relaunch" prompt during in-app auto-update).
    @Environment(\.openSettings) private var openSettings
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .automatic
    @State private var showFirstRunWelcome = false

    private var selectedGroup: SonosGroup? {
        guard let id = selectedGroupID else { return nil }
        return sonosManager.groups.first { $0.id == id }
    }

    private let nowPlayingMinWidth: CGFloat = 640
    private let browseMinWidth: CGFloat = 260
    private let browseMaxWidth: CGFloat = 600
    /// 302 — the queue width measured from the user's reference window
    /// (1409 × 597) where the four toolbar icons, the title, the track
    /// count, and the vertical scroll-bar gutter all render without
    /// clipping. Sums to a `requiredMinWidth` of exactly 1409 pt
    /// (200 + 260 + 6 + 640 + 1 + 302) when all panels are visible.
    private let queueMinWidth: CGFloat = 302
    private let queueMaxWidth: CGFloat = 400
    private let sidebarWidth: CGFloat = 200
    /// Pixels eaten by the visible separators between panels. Browse panel
    /// is followed by a 6 pt drag handle (with a Divider overlay); queue
    /// panel is preceded by a 1 pt Divider. Both are rendered alongside
    /// the panels themselves in the HStack, so the panel widths must
    /// reserve room for them or the right edge clips (visible as the
    /// queue's vertical scrollbar getting truncated).
    private let browseDividerWidth: CGFloat = 6
    private let queueDividerWidth: CGFloat = 1
    /// Sentinel: 0 = no user override (allocator picks default).
    @AppStorage(UDKey.userBrowseWidth) private var userBrowseWidthStored: Double = 0
    private var userBrowseWidth: CGFloat? {
        get { userBrowseWidthStored > 0 ? CGFloat(userBrowseWidthStored) : nil }
        nonmutating set { userBrowseWidthStored = Double(newValue ?? 0) }
    }

    /// Allocates panel widths so they always sum exactly to
    /// `totalWidth`, every visible panel meets its minimum, and
    /// browse honors the user-set width when room allows. The OS
    /// pins `window.minSize` to `requiredMinWidth` so this never
    /// receives a totalWidth smaller than the sum of minimums.
    ///
    /// Algorithm: start each visible panel at its minimum, then
    /// distribute the slack (totalWidth − sum-of-minimums) in
    /// priority order:
    ///   1. Queue grows toward `queueMaxWidth`.
    ///   2. Browse grows toward `userBrowseWidth` (clamped to its
    ///      own min/max range).
    ///   3. Now Playing absorbs whatever remains.
    private func panelWidths(totalWidth: CGFloat) -> (browse: CGFloat, nowPlaying: CGFloat, queue: CGFloat) {
        let bMin = showBrowse ? browseMinWidth : 0
        let qMin = showQueue ? queueMinWidth : 0
        let nMin = nowPlayingMinWidth
        let dividers = (showBrowse ? browseDividerWidth : 0) + (showQueue ? queueDividerWidth : 0)
        // Subtract divider pixels so the panels + dividers together always
        // fit in totalWidth — otherwise the rightmost panel overflows and
        // its scrollbar gets clipped.
        let usable = max(0, totalWidth - dividers)
        let totalMin = bMin + qMin + nMin
        var slack = max(0, usable - totalMin)

        // Queue: grows up to its max via slack proportional split,
        // capped at queueMaxWidth - queueMinWidth.
        var qw = qMin
        if showQueue {
            let queueGrowCap = queueMaxWidth - queueMinWidth
            let queueGrowth = min(queueGrowCap, slack * 0.3)
            qw += queueGrowth
            slack -= queueGrowth
        }

        // Browse: honors user preference (from drag handle), else
        // takes a chunk of the remaining slack. Always clamped to
        // [browseMinWidth, browseMaxWidth].
        var bw = bMin
        if showBrowse {
            let preferred = userBrowseWidth ?? (browseMinWidth + slack * 0.4)
            let target = max(browseMinWidth, min(preferred, browseMaxWidth))
            let browseGrowth = min(max(0, target - browseMinWidth), slack)
            bw += browseGrowth
            slack -= browseGrowth
        }

        // Now Playing absorbs whatever's left — always >= its min.
        let nw = nMin + slack
        return (bw, nw, qw)
    }

    /// Minimum window width needed for current panel configuration.
    /// Whether the speaker sidebar column is currently consuming
    /// horizontal space. NavigationSplitView's `.detailOnly`
    /// visibility hides the sidebar entirely; in that mode we
    /// shouldn't reserve sidebar width in the OS resize floor or the
    /// user gets a window minimum 200 pt larger than the actual
    /// content needs.
    private var sidebarShown: Bool {
        sidebarVisibility != .detailOnly
    }

    /// Includes the divider pixels rendered alongside each panel so the
    /// OS-level resize floor exactly matches what `panelWidths` allocates.
    /// Sidebar width is conditional on `sidebarShown` — when the user
    /// toggles the sidebar off, the OS minimum drops by `sidebarWidth`
    /// so they can shrink the window down to just the visible content.
    private var requiredMinWidth: CGFloat {
        var width = nowPlayingMinWidth
        if sidebarShown { width += sidebarWidth }
        if showBrowse { width += browseMinWidth + browseDividerWidth }
        if showQueue { width += queueMinWidth + queueDividerWidth }
        return width
    }

    /// Ensures the window is wide enough for the current panels AND
    /// enforces that minimum at the NSWindow level so the user cannot
    /// drag the resize handle down to a width that would clip toolbars
    /// (queue header, browse search bar) off the right edge.
    private func ensureWindowFits() {
        guard let window = NSApp.mainWindow else { return }
        let needed = requiredMinWidth
        // Pin the OS-level resize floor so the user cannot shrink past
        // the visible-toolbar threshold.
        let currentMin = window.minSize
        if currentMin.width != needed || currentMin.height < 450 {
            window.minSize = NSSize(width: needed, height: max(currentMin.height, 450))
        }
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
            // Persists the main window's frame across launches via the
            // host NSWindow's `setFrameAutosaveName`. Background view
            // because it doesn't render anything itself — it just
            // attaches to the window once it's available.
            WindowFrameAutosaver(name: "ChoragusMainWindow")
                .frame(width: 0, height: 0)

            // Error banner
            if errorHandler.showError, let errorMsg = errorHandler.currentError {
                DismissibleBanner(
                    icon: "exclamationmark.circle.fill",
                    tint: .red,
                    message: errorMsg,
                    onDismiss: errorHandler.dismiss
                )
            }

            // Info / success banner (e.g. "Added to queue: <track>")
            if errorHandler.showInfo, let infoMsg = errorHandler.currentInfo {
                DismissibleBanner(
                    icon: "checkmark.circle.fill",
                    tint: .green,
                    message: infoMsg,
                    onDismiss: errorHandler.dismissInfo
                )
                .transition(.move(edge: .top).combined(with: .opacity))
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

            // Wrap the visibility binding so toggling the sidebar
            // re-runs `ensureWindowFits()` — without this the OS-level
            // minSize would stay set for "sidebar shown" even after
            // the user hides it, locking the window 200 pt wider than
            // it needs to be.
            NavigationSplitView(columnVisibility: Binding(
                get: { sidebarVisibility },
                set: { newValue in
                    sidebarVisibility = newValue
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { ensureWindowFits() }
                }
            )) {
                RoomListView(selectedGroupID: $selectedGroupID)
                    // Pinned to the exact width the panel-width
                    // calculator (`requiredMinWidth`, `panelWidths`)
                    // assumes. The previous range (min 140, ideal 180,
                    // max 220) let the user drag the sidebar to a width
                    // greater than `sidebarWidth`, leaving
                    // `requiredMinWidth` short by up to 20 pt — the OS
                    // resize floor was wrong, the queue panel got
                    // squeezed below its declared minimum, and the
                    // queue toolbar's trailing icons clipped off the
                    // right edge. Pinning to a single value keeps the
                    // calculator and the rendered layout in lockstep.
                    .navigationSplitViewColumnWidth(sidebarWidth)
            } detail: {
                if let group = selectedGroup {
                    GeometryReader { geo in
                        let sizes = panelWidths(totalWidth: geo.size.width)
                        HStack(spacing: 0) {
                            if showBrowse {
                                BrowseView(group: group)
                                    .environmentObject(sonosManager)
                                    .frame(width: sizes.browse)

                                // Draggable resize handle
                                Rectangle()
                                    .fill(Color.clear)
                                    .frame(width: 6)
                                    .contentShape(Rectangle())
                                    .onHover { inside in
                                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                                    }
                                    .overlay(Divider())
                                    .gesture(
                                        DragGesture(minimumDistance: 1)
                                            .onChanged { value in
                                                let newWidth = (userBrowseWidth ?? sizes.browse) + value.translation.width
                                                let clamped = max(browseMinWidth, min(newWidth, browseMaxWidth))
                                                let neededWindow = sidebarWidth + clamped + browseDividerWidth + nowPlayingMinWidth + (showQueue ? queueMinWidth + queueDividerWidth : 0)
                                                // Grow window if player would be squeezed
                                                if let window = NSApp.mainWindow, neededWindow > window.frame.width {
                                                    var frame = window.frame
                                                    let growth = neededWindow - frame.width
                                                    frame.size.width = neededWindow
                                                    frame.origin.x -= growth / 2
                                                    if let screen = window.screen {
                                                        if frame.origin.x < screen.visibleFrame.minX { frame.origin.x = screen.visibleFrame.minX }
                                                        if frame.maxX > screen.visibleFrame.maxX { frame.origin.x = screen.visibleFrame.maxX - frame.width }
                                                    }
                                                    window.setFrame(frame, display: true)
                                                }
                                                userBrowseWidth = clamped
                                            }
                                    )
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
                // Set the window's drag-resize floor to the current panel
                // configuration so toolbars can't be clipped off-screen.
                // Toggle handlers re-call ensureWindowFits() whenever showBrowse
                // or showQueue change (existing call sites at the toolbar
                // buttons + menu observers), so onAppear is enough for startup.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { ensureWindowFits() }
                // Show the welcome popup once, on the very first launch.
                if !FirstRunWelcome.hasBeenShown {
                    // Small delay so the main window finishes appearing first.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        showFirstRunWelcome = true
                    }
                }
            }
            .sheet(isPresented: $showFirstRunWelcome) {
                FirstRunWelcomeView(
                    onOpenSettings: {
                        FirstRunWelcome.markShown()
                        showFirstRunWelcome = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            openSettings()
                        }
                    },
                    onDismiss: {
                        FirstRunWelcome.markShown()
                        showFirstRunWelcome = false
                    }
                )
            }
            .modifier(LocalNetworkPermissionAlert(monitor: localNetworkMonitor))
            .onChange(of: selectedGroupID) {
                UserDefaults.standard.set(selectedGroupID, forKey: UDKey.lastSelectedGroupID)
            }
            .onChange(of: sonosManager.groups) {
                // When groups load/change, try to restore selection if nothing selected
                if selectedGroupID == nil || selectedGroup == nil {
                    restoreLastSelectedGroup()
                }
                // Quick-Start cache restores groups + selection from disk
                // before live discovery completes. The first scan runs
                // against possibly-stale coordinator data and quietly
                // fails / returns empty metadata — Now Playing then sits
                // blank until the user switches speakers (which retriggers
                // `NowPlayingView.onChange(of: group.id)`). Re-scan the
                // currently-selected group whenever topology updates so
                // live data lands without that extra click.
                if let group = selectedGroup {
                    Task { await sonosManager.scanGroup(group) }
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        showBrowse.toggle()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { ensureWindowFits() }
                    } label: {
                        Image(systemName: "square.grid.2x2")
                    }
                    .help(L10n.browseMusicLibrary)
                    .disabled(selectedGroupID == nil)

                    Button {
                        showQueue.toggle()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { ensureWindowFits() }
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .help(L10n.showPlayQueue)
                    .disabled(selectedGroupID == nil)

                    Menu {
                        Button(L10n.pauseAll) {
                            Task { await sonosManager.pauseAll() }
                        }
                        Button(L10n.resumeAll) {
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
                    .tint(.primary)
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
                    .help(L10n.listeningStats)

                    Menu {
                        Button(L10n.karaoke) {
                            WindowManager.shared.openKaraokeLyricsForActiveGroup()
                        }
                        Button(L10n.clubVis) {
                            WindowManager.shared.openClubVisForActiveGroup()
                        }
                    } label: {
                        Image(systemName: "sparkles.tv")
                    }
                    .menuIndicator(.hidden)
                    .help(L10n.visualisationMenu)

                    // Rescan button moved to the room/speaker list
                    // (RoomListView header) so it lives next to the
                    // speakers it operates on. Removed from the
                    // global toolbar to declutter.

                    if !hideDiagnosticsIcon {
                        Button {
                            WindowManager.shared.openDiagnostics()
                        } label: {
                            if NSImage(named: "BugIcon") != nil {
                                Image("BugIcon")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 18, height: 18)
                            } else {
                                ZStack(alignment: .topTrailing) {
                                    Image(systemName: "ant.fill")
                                    Image(systemName: "exclamationmark.circle.fill")
                                        .font(.system(size: 8))
                                        .foregroundStyle(.white, .red)
                                        .symbolRenderingMode(.palette)
                                        .offset(x: 5, y: -3)
                                }
                            }
                        }
                        .help(L10n.diagnostics)
                    }

                    Button {
                        openSettings()
                    } label: {
                        Image(systemName: "gear")
                    }
                    .help(L10n.appSettings)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .menuToggleBrowse)) { _ in
                showBrowse.toggle()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { ensureWindowFits() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .menuToggleQueue)) { _ in
                showQueue.toggle()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { ensureWindowFits() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .menuShowStats)) { _ in
                WindowManager.shared.togglePlayHistory()
            }
            .onReceive(NotificationCenter.default.publisher(for: .menuShowForFun)) { _ in
                WindowManager.shared.openForFun()
            }
            .onReceive(NotificationCenter.default.publisher(for: .menuPlayPause)) { _ in
                handlePlayPause()
            }
            .onReceive(NotificationCenter.default.publisher(for: .menuNextTrack)) { _ in
                guard let group = selectedGroup else { return }
                Task { await ErrorHandler.shared.handleAsync("PLAYBACK") { try await sonosManager.next(group: group) } }
            }
            .onReceive(NotificationCenter.default.publisher(for: .menuPreviousTrack)) { _ in
                guard let group = selectedGroup else { return }
                Task { await ErrorHandler.shared.handleAsync("PLAYBACK") { try await sonosManager.previous(group: group) } }
            }
            .onReceive(NotificationCenter.default.publisher(for: .menuToggleMute)) { _ in
                guard let group = selectedGroup else { return }
                let allMuted = group.members.allSatisfy { sonosManager.deviceMutes[$0.id] == true }
                Task {
                    for member in group.members {
                        try? await sonosManager.setMute(device: member, muted: !allMuted)
                    }
                }
            }
        }
        // Drives `NSWindow.minSize` from the visible-panel set.
        // SwiftUI propagates the intrinsic min content size of the
        // root view into the WindowGroup's window-level min, so when
        // `requiredMinWidth` changes (showBrowse / showQueue toggle),
        // the OS-level drag-resize floor moves with it — including
        // shrinking when panels are hidden.
        .frame(minWidth: requiredMinWidth, minHeight: 450)
        // Propagate the user's chosen accent through the whole tree
        // so every `Color.accentColor` / `.tint` reference picks it
        // up. Without this, only the views that explicitly read
        // `sonosManager.resolvedAccentColor` change colour when the
        // setting is updated, and the picker appears to "do nothing".
        .tint(sonosManager.resolvedAccentColor)
    }

    /// Karaoke popout — top-level toolbar shortcut so the feature is
    /// discoverable without drilling into the lyrics tab. Extracted so
    /// the toolbar's `ToolbarItemGroup` body stays under the Swift
    /// compiler's type-inference complexity ceiling.
    @ViewBuilder
    private var karaokeToolbarButton: some View {
        Button {
            if let group = selectedGroup {
                WindowManager.shared.openKaraokeLyrics(group: group)
            }
        } label: {
            Image(systemName: "music.mic")
        }
        .disabled(selectedGroup == nil)
        .help(L10n.popOutLyrics)
    }

    /// Speaker / group menu (pause-all, resume-all, mute, presets).
    /// Extracted so the toolbar `ToolbarItemGroup` body fits inside
    /// the Swift compiler's type-inference budget once the karaoke
    /// button and the diagnostics button are also present.
    @ViewBuilder
    private var speakerControlMenu: some View {
        Menu {
            Button(L10n.pauseAll) {
                Task { await sonosManager.pauseAll() }
            }
            Button(L10n.resumeAll) {
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
        .tint(.primary)
        .help(L10n.muteOrUnmuteAll)
        .sheet(isPresented: $showPresetManager) {
            PresetManagerView()
                .environmentObject(sonosManager)
                .environmentObject(presetManager)
        }
    }

    /// Same extraction reason as `karaokeToolbarButton` — the inline
    /// conditional + ZStack composite of the bug icon was tipping the
    /// toolbar `ToolbarItemGroup` over the type-inference complexity
    /// budget once the karaoke button was added beside it.
    @ViewBuilder
    private var diagnosticsToolbarButton: some View {
        if !hideDiagnosticsIcon {
            Button {
                WindowManager.shared.openDiagnostics()
            } label: {
                if NSImage(named: "BugIcon") != nil {
                    Image("BugIcon")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                } else {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "ant.fill")
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.white, .red)
                            .symbolRenderingMode(.palette)
                            .offset(x: 5, y: -3)
                    }
                }
            }
            .help(L10n.diagnostics)
        }
    }

    private func handlePlayPause() {
        guard let group = selectedGroup else { return }
        let isPlaying = sonosManager.groupTransportStates[group.coordinatorID]?.isActive ?? false
        Task {
            await ErrorHandler.shared.handleAsync("PLAYBACK") {
                if isPlaying {
                    try await sonosManager.pause(group: group)
                } else {
                    try await sonosManager.play(group: group)
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

/// Extracted to a ViewModifier so ContentView's already-massive `body`
/// stays under Swift's type-check budget — inlining the alert pushed
/// the compiler past its timeout. Fires when `LocalNetworkPermissionMonitor`
/// detects macOS has denied the app Local Network access.
private struct LocalNetworkPermissionAlert: ViewModifier {
    @ObservedObject var monitor: LocalNetworkPermissionMonitor

    func body(content: Content) -> some View {
        content.alert(
            L10n.localNetworkAccessRequired,
            isPresented: Binding(
                get: { monitor.shouldShowAlert },
                set: { if !$0 { monitor.acknowledge() } }
            )
        ) {
            Button(L10n.openSystemSettings) {
                NSWorkspace.shared.open(LocalNetworkPermissionMonitor.systemSettingsURL)
                monitor.acknowledge()
            }
            Button(L10n.later, role: .cancel) {
                monitor.acknowledge()
            }
        } message: {
            Text(L10n.localNetworkAccessMessage)
        }
    }
}

/// Top-of-window pill for transient state — error / success / info.
/// `tint` drives both the icon colour and the (10 %) background tint
/// so future banners only have to pick a system colour. Stale-data and
/// cached-data banners stay distinct because they have unique chrome
/// (text-style "Dismiss" button, embedded ProgressView).
private struct DismissibleBanner: View {
    let icon: String
    let tint: Color
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(message)
                .font(.caption)
                .lineLimit(2)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(tint.opacity(0.1))
    }
}

/// Hooks into the host `NSWindow` once it's available and assigns a
/// stable autosave name so AppKit persists the window's frame
/// (position + size) to UserDefaults across launches.
private struct WindowFrameAutosaver: NSViewRepresentable {
    let name: String
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // `view.window` is nil at make-time. Defer to the next runloop
        // tick so the host has attached the view before we look it up.
        DispatchQueue.main.async {
            view.window?.setFrameAutosaveName(name)
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

