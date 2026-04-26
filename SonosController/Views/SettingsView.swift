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

            // Tab picker
            Picker("", selection: $selectedTab) {
                Label(L10n.displayTab, systemImage: "paintbrush").tag(0)
                Label(L10n.musicTab, systemImage: "music.note").tag(1)
                Label(L10n.scrobbling, systemImage: "waveform").tag(3)
                Label(L10n.systemTab, systemImage: "gearshape").tag(2)
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                switch tab {
                case 0: displayTab
                case 1: musicTab
                case 3: scrobblingTab
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
            }

            // ─── APPEARANCE ───
            settingsSection(L10n.appearance) {
                settingsRow(L10n.theme) {
                    Picker("", selection: $sonosManager.appearanceMode) {
                        ForEach(AppearanceMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 240)
                }

                Text(L10n.colors)
                    .font(.subheadline)
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

                Toggle(L10n.menuBarControls, isOn: Binding(
                    get: { MenuBarController.shared.isEnabled },
                    set: { MenuBarController.shared.isEnabled = $0 }
                ))

                infoToggle(isExpanded: $showAppearanceInfo, label: L10n.aboutAppearance,
                           text: L10n.appearanceInfo)
            }
        }
    }

    // MARK: - Music Tab

    @State private var showClearHistoryConfirm = false
    @State private var isRebuildingSummaries = false

    private var musicTab: some View {
        Group {
            // ─── PLAYBACK ───
            settingsSection(L10n.playbackSection) {
                Toggle(L10n.classicShuffleMode, isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: UDKey.classicShuffleEnabled) },
                    set: { UserDefaults.standard.set($0, forKey: UDKey.classicShuffleEnabled) }
                ))
                Text(L10n.classicShuffleHelp)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Divider().padding(.vertical, 4)

                Toggle(L10n.proportionalGroupVolume, isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: UDKey.proportionalGroupVolume) },
                    set: { UserDefaults.standard.set($0, forKey: UDKey.proportionalGroupVolume) }
                ))
                Text(L10n.proportionalVolumeHelp)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // ─── PLAY HISTORY ───
            settingsSection(L10n.playHistory) {
                Toggle(L10n.enablePlayHistory, isOn: Binding(
                    get: { playHistoryManager.isEnabled },
                    set: { playHistoryManager.isEnabled = $0 }
                ))

                Toggle(L10n.ignoreTVHDMILineIn, isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: UDKey.ignoreTV) },
                    set: { UserDefaults.standard.set($0, forKey: UDKey.ignoreTV) }
                ))
                .font(.system(size: 12))

                Divider().padding(.vertical, 4)

                Toggle(L10n.realtimeDashboardSummaries, isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: UDKey.realtimeStats) },
                    set: { newValue in
                        UserDefaults.standard.set(newValue, forKey: UDKey.realtimeStats)
                        if newValue {
                            isRebuildingSummaries = true
                            // Delay rebuild to let UI render first
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                playHistoryManager.rebuildAllSummaries()
                                isRebuildingSummaries = false
                            }
                        }
                    }
                ))
                .font(.system(size: 12))

                if UserDefaults.standard.bool(forKey: UDKey.realtimeStats) {
                    if isRebuildingSummaries {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text(L10n.buildingSummaries)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    settingsRow("Interval") {
                        Picker("", selection: Binding(
                            get: { UserDefaults.standard.integer(forKey: UDKey.rollupInterval) == 0 ? 60 : UserDefaults.standard.integer(forKey: UDKey.rollupInterval) },
                            set: { UserDefaults.standard.set($0, forKey: UDKey.rollupInterval) }
                        )) {
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
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    Text(L10n.dailySummariesHelp)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Divider().padding(.vertical, 4)

                if playHistoryManager.totalEntries > 0 {
                    Text("\(playHistoryManager.totalEntries) entries, \(String(format: "%.1f", playHistoryManager.totalListeningHours)) hours")
                        .font(.caption)
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
        }
    }

    // MARK: - Scrobbling Tab

    private var scrobblingTab: some View {
        SettingsScrobblingTab(lastfm: lastFMScrobbler)
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
                        ForEach(CommunicationMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 260)
                }

                if sonosManager.communicationMode == .hybridEventFirst,
                   sonosManager.activeSubscriptionCount > 0 {
                    HStack(spacing: 4) {
                        Circle().fill(.green).frame(width: 6, height: 6)
                        Text("\(sonosManager.activeSubscriptionCount) \(L10n.activeSubscriptions)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                settingsRow(L10n.startup) {
                    Picker("", selection: $sonosManager.startupMode) {
                        ForEach(StartupMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 240)
                }

                Divider()

                settingsRow(L10n.discovery) {
                    Picker("", selection: $sonosManager.discoveryMode) {
                        ForEach(DiscoveryMode.allCases, id: \.self) { Text($0 == .mdns ? L10n.bonjourDiscovery : L10n.legacyMulticast).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 260)
                }

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
                            .font(.caption)
                    }
                    Spacer()
                    Text(L10n.artworkImagesSummary(ImageCache.shared.diskUsageString, ImageCache.shared.fileCount))
                        .font(.caption)
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
        }
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
                        .font(.caption2)
                        .rotationEffect(isExpanded.wrappedValue ? .degrees(90) : .zero)
                    Text(label)
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded.wrappedValue {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                    .padding(.leading, 16)
            }
        }
    }

    private func colorRow(label: String, systemImage: String, iconColor: Color, storedColor: Binding<StoredColor>, allowSystem: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(iconColor)
                .frame(width: 14)
            Text(label)
                .font(.caption)
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
                .font(.subheadline)
                .frame(width: 70, alignment: .leading)
            content()
        }
    }
}
