/// SettingsView.swift — App preferences with tabbed layout following macOS HIG.
/// Tabs: Display, Music, System.
import SwiftUI
import SonosKit

struct SettingsView: View {
    @EnvironmentObject var sonosManager: SonosManager
    @EnvironmentObject var playHistoryManager: PlayHistoryManager
    @EnvironmentObject var smapiManager: SMAPIAuthManager
    @EnvironmentObject var scrobbleManager: ScrobbleManager
    @EnvironmentObject var lastFMScrobbler: LastFMScrobbler
    @EnvironmentObject var sparkleObserver: SparkleUpdaterObserver
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text(L10n.settings)
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button(L10n.done) { dismiss() }
                    .keyboardShortcut(.return)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()

            // Tab picker. Software Updates only appears when Sparkle
            // is active (release build with a configured feed URL) —
            // a dedicated tab when there's nothing to show would be
            // confusing on dev / fork builds where the controls are
            // necessarily inert.
            Picker("", selection: $selectedTab) {
                Label(L10n.displayTab, systemImage: "paintbrush").tag(0)
                Label(L10n.musicTab, systemImage: "music.note").tag(1)
                Label(L10n.scrobbling, systemImage: "waveform").tag(3)
                Label(L10n.visualisationsTab, systemImage: "sparkles").tag(5)
                Label(L10n.systemTab, systemImage: "gearshape").tag(2)
                if sparkleObserver.updater != nil {
                    Label(L10n.softwareUpdates, systemImage: "arrow.down.circle").tag(4)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)

            // Tab content
            TabContentView(tab: selectedTab)
                .environmentObject(sonosManager)
                .environmentObject(playHistoryManager)
                .environmentObject(smapiManager)
                .environmentObject(scrobbleManager)
                .environmentObject(lastFMScrobbler)
                .environmentObject(sparkleObserver)
        }
        .frame(width: 560, height: 720)
        .onDisappear {
            NSColorPanel.shared.close()
        }
    }
}

// MARK: - Tab Content Router

private struct TabContentView: View {
    @EnvironmentObject var sonosManager: SonosManager
    @EnvironmentObject var playHistoryManager: PlayHistoryManager
    @EnvironmentObject var smapiManager: SMAPIAuthManager
    @EnvironmentObject var scrobbleManager: ScrobbleManager
    @EnvironmentObject var lastFMScrobbler: LastFMScrobbler
    @Environment(\.dismiss) private var dismiss
    let tab: Int

    // Toggle UI updates instantly when flipped because @AppStorage
    // observes UserDefaults changes. Manual `Binding(get:set:)` against
    // UserDefaults doesn't, which made the checkboxes feel stuck.
    @AppStorage(UDKey.menuBarEnabled) private var menuBarEnabled = false
    @AppStorage(UDKey.hideDiagnosticsIcon) private var hideDiagnosticsIcon = false
    @AppStorage(UDKey.scrollVolumeEnabled) private var scrollVolumeEnabled = false
    @AppStorage(UDKey.middleClickMuteEnabled) private var middleClickMuteEnabled = true
    @AppStorage(UDKey.classicShuffleEnabled) private var classicShuffleEnabled = false
    @AppStorage(UDKey.proportionalGroupVolume) private var proportionalGroupVolume = false
    @AppStorage(UDKey.ignoreTV) private var ignoreTV = false
    @AppStorage(UDKey.realtimeStats) private var realtimeStats = false
    @AppStorage(UDKey.rollupInterval) private var rollupInterval = 60
    @AppStorage(UDKey.lyricsGlobalOffset) private var lyricsGlobalOffset: Double = -2.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                switch tab {
                case 0: displayTab
                case 1: musicTab
                case 3: scrobblingTab
                case 4: softwareUpdatesTab
                case 5: visualisationsTab
                default: systemTab
                }
            }
            .padding(32)
        }
    }

    // MARK: - Display Tab

    @State private var showAppearanceInfo = false

    private var displayTab: some View {
        Group {
            // ─── LANGUAGE ───
            settingsSection(L10n.language) {
                Picker("", selection: $sonosManager.appLanguage) {
                    ForEach(AppLanguage.allCases, id: \.self) { lang in
                        Text("\(lang.displayName) — \(lang.englishName)").tag(lang)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 300)

                Text(LocalizedStringKey(L10n.translationHelpNote))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            // ─── APPEARANCE ───
            settingsSection(L10n.appearance) {
                settingsRow(L10n.theme) {
                    Picker("", selection: $sonosManager.appearanceMode) {
                        ForEach(AppearanceMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 240)
                    .languageReactive()
                }

                settingsRow(L10n.karaokeTheme) {
                    Picker("", selection: $sonosManager.karaokeAppearanceMode) {
                        ForEach(AppearanceMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 240)
                    .languageReactive()
                }

                Text(L10n.colors)
                    .font(.body)
                    .foregroundStyle(.secondary)

                colorRow(label: L10n.accent, systemImage: "paintpalette.fill",
                         iconColor: sonosManager.resolvedAccentColor ?? .accentColor,
                         storedColor: $sonosManager.accentColor, allowSystem: true)

                colorRow(label: L10n.playing, systemImage: "hifispeaker.fill",
                         iconColor: sonosManager.resolvedPlayingZoneColor,
                         storedColor: $sonosManager.playingZoneColor, allowSystem: true)

                colorRow(label: L10n.inactive, systemImage: "hifispeaker",
                         iconColor: sonosManager.resolvedInactiveZoneColor,
                         storedColor: $sonosManager.inactiveZoneColor, allowSystem: true)

                Divider()

                Toggle(L10n.menuBarControls, isOn: $menuBarEnabled)
                    .onChange(of: menuBarEnabled) { _, on in
                        // Status item lifecycle is the heavy work
                        // here (NSStatusBar.statusItem creation /
                        // tear-down). Doing it on the next runloop
                        // tick keeps the SwiftUI checkbox animation
                        // crisp; the bound value already updated
                        // instantly via @AppStorage.
                        DispatchQueue.main.async {
                            if on {
                                MenuBarController.shared.show()
                            } else {
                                MenuBarController.shared.hide()
                            }
                        }
                    }

                Toggle(L10n.hideDiagnosticsIcon, isOn: $hideDiagnosticsIcon)
                Text(L10n.hideDiagnosticsIconHint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                Text(L10n.mouseControls)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)

                Toggle(L10n.scrollWheelAdjustsVolume, isOn: $scrollVolumeEnabled)
                Text(L10n.scrollWheelAdjustsVolumeHint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle(L10n.middleClickTogglesMute, isOn: $middleClickMuteEnabled)
                Text(L10n.middleClickTogglesMuteHint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                infoToggle(isExpanded: $showAppearanceInfo, label: L10n.aboutAppearance,
                           text: L10n.appearanceInfo)
            }
        }
    }

    // MARK: - Music Tab

    @State private var showClearHistoryConfirm = false
    @State private var isRebuildingSummaries = false

    @AppStorage(UDKey.playHistoryMaxEntries) private var playHistoryMaxEntries: Int = 0

    private var musicTab: some View {
        Group {
            // ─── PLAY HISTORY ───
            settingsSection(L10n.playHistory) {
                Toggle(L10n.enablePlayHistory, isOn: Binding(
                    get: { playHistoryManager.isEnabled },
                    set: { playHistoryManager.isEnabled = $0 }
                ))

                Toggle(L10n.ignoreTVHDMILineIn, isOn: $ignoreTV)

                settingsRow(L10n.historyDataCap) {
                    Picker("", selection: $playHistoryMaxEntries) {
                        Text(L10n.unlimited).tag(0)
                        Text("50,000").tag(50_000)
                        Text("100,000").tag(100_000)
                        Text("250,000").tag(250_000)
                        Text("500,000").tag(500_000)
                        Text("1,000,000").tag(1_000_000)
                    }
                    .frame(maxWidth: 160)
                    .labelsHidden()
                }

                Divider().padding(.vertical, 4)

                Toggle(L10n.realtimeDashboardSummaries, isOn: $realtimeStats)
                    .onChange(of: realtimeStats) { _, newValue in
                        guard newValue else { return }
                        isRebuildingSummaries = true
                        // Delay rebuild to let UI render first
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            playHistoryManager.rebuildAllSummaries()
                            isRebuildingSummaries = false
                        }
                    }

                if realtimeStats {
                    if isRebuildingSummaries {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text(L10n.buildingSummaries)
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    settingsRow("Interval") {
                        Picker("", selection: $rollupInterval) {
                            Text("30 min").tag(30)
                            Text("1 hour").tag(60)
                            Text(L10n.manualOnly).tag(0)
                        }
                        .frame(maxWidth: 140)
                    }

                    Button(L10n.rebuildAllSummaries) {
                        isRebuildingSummaries = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            playHistoryManager.rebuildAllSummaries()
                            isRebuildingSummaries = false
                        }
                    }
                    .controlSize(.small)
                    .disabled(isRebuildingSummaries)

                    if let lastRollup = playHistoryManager.lastRollupDate {
                        Text(L10n.lastUpdatedFormat(lastRollup.formatted(date: .omitted, time: .shortened)))
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    }

                    Text(L10n.dailySummariesHelp)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }

                Divider().padding(.vertical, 4)

                if playHistoryManager.totalEntries > 0 {
                    Text("\(playHistoryManager.totalEntries) entries, \(String(format: "%.1f", playHistoryManager.totalListeningHours)) hours")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Button(L10n.playHistory) {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            WindowManager.shared.openPlayHistory()
                        }
                    }
                    .controlSize(.small)

                    Button(L10n.clearHistory) {
                        showClearHistoryConfirm = true
                    }
                    .controlSize(.small)
                    .disabled(playHistoryManager.entries.isEmpty)
                }
            }
            .alert(L10n.clearPlayHistoryPrompt, isPresented: $showClearHistoryConfirm) {
                Button(L10n.cancel, role: .cancel) {}
                Button(L10n.clearHistory, role: .destructive) {
                    playHistoryManager.clearHistory()
                }
            }

            // ─── MUSIC SERVICES ───
            settingsSection(L10n.musicServicesBeta) {
                MusicServicesSettingsSection()
                    .environmentObject(smapiManager)
            }

            // ─── PLAYBACK ───
            settingsSection(L10n.playbackSection) {
                Toggle(L10n.classicShuffleMode, isOn: $classicShuffleEnabled)
                Text(L10n.classicShuffleHelp)
                    .font(.callout)
                    .foregroundStyle(.tertiary)

                Divider().padding(.vertical, 4)

                Toggle(L10n.proportionalGroupVolume, isOn: $proportionalGroupVolume)
                Text(L10n.proportionalVolumeHelp)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Scrobbling Tab

    private var scrobblingTab: some View {
        SettingsScrobblingTab(lastfm: lastFMScrobbler)
    }

    // MARK: - Visualisations Tab

    @AppStorage(UDKey.visGenreMatchMode) private var visGenreMatchModeRaw = VisGenreMatchMode.defaultMode.rawValue
    @AppStorage(UDKey.visRandomSprinklePercent) private var visRandomSprinklePercent: Double = 5.0
    @AppStorage(UDKey.visShowAboutPanel) private var visShowAboutPanel: Bool = true
    @AppStorage(UDKey.visHistorySource) private var visHistorySourceRaw = VisHistorySource.defaultMode.rawValue
    @AppStorage(UDKey.karaokeStyle) private var karaokeStyleRaw = KaraokeStyle.defaultMode.rawValue

    @ViewBuilder
    private var visualisationsTab: some View {
        // All visualisation settings live as sibling sections so users
        // can scan settings per visualisation rather than per setting
        // type. New visualisations slot in as additional sections at
        // the same level (Back of the Club, Karaoke, …).
        settingsSection(L10n.visBackOfTheClubSection) {
            VStack(alignment: .leading, spacing: 18) {
                visSettingRow(label: L10n.visGenreMatching,
                              help: L10n.visGenreMatchingHelp) {
                    Picker("", selection: $visGenreMatchModeRaw) {
                        Text(L10n.visGenreMatchPartial).tag(VisGenreMatchMode.partial.rawValue)
                        Text(L10n.visGenreMatchFull).tag(VisGenreMatchMode.full.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .languageReactive()
                }

                visSettingRow(label: L10n.visRandomArtMix,
                              help: L10n.visRandomArtMixHelp) {
                    HStack(spacing: 12) {
                        Stepper(value: $visRandomSprinklePercent, in: 0...50, step: 1) {
                            EmptyView()
                        }
                        .labelsHidden()
                        Text("\(Int(visRandomSprinklePercent))%")
                            .monospacedDigit()
                            .frame(minWidth: 44, alignment: .leading)
                    }
                }

                visSettingRow(label: L10n.visShowAboutPanel,
                              help: L10n.visShowAboutPanelHelp) {
                    Toggle("", isOn: $visShowAboutPanel)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                visSettingRow(label: L10n.visHistorySource,
                              help: L10n.visHistorySourceHelp) {
                    Picker("", selection: $visHistorySourceRaw) {
                        Text(L10n.visHistorySourceGroup).tag(VisHistorySource.group.rawValue)
                        Text(L10n.visHistorySourceAll).tag(VisHistorySource.all.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .languageReactive()
                }
            }
        }
        settingsSection(L10n.karaokeSection) {
            VStack(alignment: .leading, spacing: 18) {
                visSettingRow(label: L10n.karaokeStyleLabel,
                              help: L10n.karaokeStyleHelp) {
                    Picker("", selection: $karaokeStyleRaw) {
                        Text(L10n.karaokeStyleDynamic).tag(KaraokeStyle.dynamic.rawValue)
                        Text(L10n.karaokeStyleClassic).tag(KaraokeStyle.classic.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .languageReactive()
                }
                // Lyrics timing offset — moved out of its own LYRICS
                // settings tab since the karaoke window is the only
                // visible consumer of synced lyrics.
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        Text(L10n.lyricsGlobalTimingOffset)
                            .font(.body)
                        Spacer()
                        Text(String(format: "%@%.1fs",
                                    lyricsGlobalOffset > 0 ? "+" : "",
                                    lyricsGlobalOffset))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 60, alignment: .trailing)
                        Button(L10n.reset) { lyricsGlobalOffset = -2.0 }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    Slider(value: $lyricsGlobalOffset, in: -5.0...5.0, step: 0.1)
                    Text(L10n.lyricsGlobalOffsetHint)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Single setting row inside a visualisation section: the
    /// control on the right, the label on the left, and a wrapped
    /// help caption underneath. Caption is `.callout` and dimmed so
    /// it reads as supporting copy without crowding the control.
    @ViewBuilder
    private func visSettingRow<Control: View>(
        label: String,
        help: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.body)
                Spacer()
                control()
            }
            Text(help)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - System Tab

    @State private var showNetworkInfo = false
    @State private var showCacheInfo = false
    @State private var showClearSpeakerCacheConfirm = false
    @State private var showClearArtworkCacheConfirm = false

    private var systemTab: some View {
        Group {
            // ─── NETWORK ───
            settingsSection(L10n.network) {
                settingsRow(L10n.updates) {
                    Picker("", selection: $sonosManager.communicationMode) {
                        ForEach(CommunicationMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 260)
                    .languageReactive()
                }

                if sonosManager.communicationMode == .hybridEventFirst,
                   sonosManager.activeSubscriptionCount > 0 {
                    HStack(spacing: 4) {
                        Circle().fill(.green).frame(width: 6, height: 6)
                        Text("\(sonosManager.activeSubscriptionCount) \(L10n.activeSubscriptions)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                settingsRow(L10n.startup) {
                    Picker("", selection: $sonosManager.startupMode) {
                        ForEach(StartupMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 240)
                    .languageReactive()
                }

                Divider()

                settingsRow(L10n.discovery) {
                    Picker("", selection: $sonosManager.discoveryMode) {
                        ForEach(DiscoveryMode.allCases, id: \.self) { mode in
                            Text(discoveryModeLabel(mode)).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 320)
                    .languageReactive()
                }

                if sonosManager.discoveryMode == .auto {
                    Text(L10n.discoveryAutoHint)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Divider()

                ITunesThrottleStatusRow()

                infoToggle(isExpanded: $showNetworkInfo, label: L10n.aboutNetwork,
                           text: L10n.aboutNetworkBody)
            }

            // ─── CACHE ───
            settingsSection(L10n.cache) {
                HStack(spacing: 16) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(sonosManager.isUsingCachedData ? .orange : .green)
                            .frame(width: 6, height: 6)
                        Text(sonosManager.isUsingCachedData ? L10n.cachedData : L10n.liveData)
                            .font(.callout)
                    }
                    Spacer()
                    Text(L10n.artworkImagesSummary(ImageCache.shared.diskUsageString, ImageCache.shared.fileCount))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 20) {
                    settingsRow(L10n.maxSize) {
                        Picker("", selection: Binding(
                            get: { ImageCache.shared.maxSizeMB },
                            set: { ImageCache.shared.maxSizeMB = $0 }
                        )) {
                            Text("100 MB").tag(100)
                            Text("500 MB").tag(500)
                            Text("1 GB").tag(1024)
                            Text("5 GB").tag(5120)
                        }
                        .frame(width: 100)
                    }

                    settingsRow(L10n.maxAge) {
                        Picker("", selection: Binding(
                            get: { ImageCache.shared.maxAgeDays },
                            set: { ImageCache.shared.maxAgeDays = $0 }
                        )) {
                            Text("7 days").tag(7)
                            Text("30 days").tag(30)
                            Text("90 days").tag(90)
                            Text("1 year").tag(365)
                            Text(L10n.never_).tag(99999)
                        }
                        .frame(width: 100)
                    }
                }

                HStack(spacing: 8) {
                    Button(L10n.clearSpeakerCache) { showClearSpeakerCacheConfirm = true }
                        .controlSize(.small)
                    Button(L10n.clearArtworkCache) { showClearArtworkCacheConfirm = true }
                        .controlSize(.small)
                }
                .alert(L10n.clearSpeakerCachePrompt, isPresented: $showClearSpeakerCacheConfirm) {
                    Button(L10n.cancel, role: .cancel) {}
                    Button(L10n.clearSpeakerCache, role: .destructive) { sonosManager.clearCache() }
                } message: {
                    Text(L10n.rescanCacheHelp)
                }
                .alert(L10n.clearArtworkCachePrompt, isPresented: $showClearArtworkCacheConfirm) {
                    Button(L10n.cancel, role: .cancel) {}
                    Button(L10n.clearArtworkCache, role: .destructive) {
                        ImageCache.shared.clearDisk()
                        ImageCache.shared.clearMemory()
                    }
                } message: {
                    Text(L10n.clearArtCacheHelp)
                }

                infoToggle(isExpanded: $showCacheInfo, label: L10n.aboutCache,
                           text: L10n.aboutCacheBody)
            }

            // Software Updates section moved out of the System tab
            // and into a dedicated top-level tab — see the
            // `softwareUpdatesTab` case in TabContentView.body.
        }
    }

    @EnvironmentObject private var sparkleObserver: SparkleUpdaterObserver

    private var softwareUpdatesTab: some View {
        VStack(alignment: .leading, spacing: 28) {
            updatesSection
        }
    }

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsSection(L10n.softwareUpdates) {
                // Quick-reference version line at the top of the pane.
                // Clickable so users hunting for "what version am I on?"
                // can drill straight into the full About window (with
                // build, copyright, credits) without leaving the
                // Software Updates context. Plain-button styling +
                // .link pointer keeps it understated — version strings
                // shouldn't shout.
                HStack(spacing: 4) {
                    Text(L10n.currentVersionLabel)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button {
                        showAboutPanel()
                    } label: {
                        Text(currentVersionString)
                            .font(.callout)
                            .underline()
                    }
                    .buttonStyle(.plain)
                    .help(L10n.openAboutWindowTooltip)
                    Spacer()
                }

                Toggle(L10n.autoCheckForUpdates, isOn: sparkleObserver.autoCheckBinding)

                Toggle(L10n.autoDownloadUpdates, isOn: sparkleObserver.autoDownloadBinding)
                    .disabled(!sparkleObserver.automaticallyChecksForUpdates)

                HStack(spacing: 8) {
                    Button(L10n.checkForUpdates) {
                        sparkleObserver.updater?.checkForUpdates()
                    }
                    .controlSize(.small)
                    .disabled(!sparkleObserver.canCheckForUpdates)

                    Spacer()

                    Text(lastCheckedLabel)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
            }

            settingsSection(L10n.softwareUpdatesBetaSection) {
                Toggle(L10n.softwareUpdatesBetaOptIn, isOn: sparkleObserver.betaChannelBinding)

                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .imageScale(.small)
                        .padding(.top, 2)
                    Text(L10n.softwareUpdatesBetaWarning)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var lastCheckedLabel: String {
        guard let last = sparkleObserver.lastUpdateCheckDate else {
            return L10n.neverChecked
        }
        let fmt = DateFormatter()
        fmt.dateStyle = .short
        fmt.timeStyle = .short
        fmt.locale = L10n.currentLocale
        return L10n.lastCheckedFormat(fmt.string(from: last))
    }

    /// Marketing version + build number, e.g. "4.5.1 (build 14)". Read
    /// from the running bundle so it tracks whatever was installed
    /// regardless of source. Used for the clickable label in the
    /// Software Updates pane.
    private var currentVersionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return L10n.versionBuildFormat(version, build)
    }

    // MARK: - Layout Helpers

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .padding(.leading, 4)

            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func infoToggle(isExpanded: Binding<Bool>, label: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.callout)
                        .rotationEffect(isExpanded.wrappedValue ? .degrees(90) : .zero)
                    Text(label)
                        .font(.body)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded.wrappedValue {
                // `LocalizedStringKey(text)` so SwiftUI renders the
                // markdown (`**bold**`, `[text](url)`) instead of
                // showing the raw asterisks and brackets.
                Text(LocalizedStringKey(text))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                    .padding(.leading, 16)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    private func colorRow(label: String, systemImage: String, iconColor: Color, storedColor: Binding<StoredColor>, allowSystem: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(iconColor)
                .frame(width: 14)
            Text(label)
                .font(.callout)
                .frame(width: 50, alignment: .leading)
            ColorSwatchGrid(
                storedColor: storedColor,
                allowSystem: allowSystem
            )
        }
    }

    private func settingsRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label)
                .font(.body)
                .frame(width: 70, alignment: .leading)
            content()
        }
    }

    private func discoveryModeLabel(_ mode: DiscoveryMode) -> String {
        switch mode {
        case .auto:    return L10n.autoDiscovery
        case .bonjour: return L10n.bonjourDiscovery
        case .ssdp:    return L10n.legacyMulticast
        }
    }
}

/// Status row showing iTunes Search API health: live / cooling-down, the
/// sliding-window utilisation, and cumulative counters since launch.
/// Polls the actor every 5s while visible.
private struct ITunesThrottleStatusRow: View {
    @State private var snap: ITunesRateLimiter.Snapshot?

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(L10n.appleMusicSearch)
                        .font(.body)
                    Text(statusLabel)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let s = snap {
                    Text(L10n.iTunesQueriesInWindow(s.requestsInWindow, s.softLimit))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if let until = s.cooldownUntil {
                        Text(L10n.appleMusicResumesAt(Self.timeFmt.string(from: until)))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
        }
        .task {
            // Poll the actor every 5 s while the Settings tab is visible.
            // .task auto-cancels when the row leaves the hierarchy.
            while !Task.isCancelled {
                snap = await ITunesRateLimiter.shared.snapshot()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private var statusColor: Color {
        guard let s = snap else { return .secondary }
        return s.isAvailable ? .green : .orange
    }

    private var statusLabel: String {
        guard let s = snap else { return "—" }
        return s.isAvailable ? L10n.appleMusicSearchReady : L10n.appleMusicSearchCoolingDown
    }
}
