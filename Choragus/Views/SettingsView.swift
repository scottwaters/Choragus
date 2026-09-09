/// SettingsView.swift — App preferences with tabbed layout following macOS HIG.
/// Tabs: Display, Music, System.
import SwiftUI
import SonosKit
import ServiceManagement

struct SettingsView: View {
    @Environment(SonosManager.self) private var sonosManager
    @EnvironmentObject var playHistoryManager: PlayHistoryManager
    @EnvironmentObject var smapiManager: SMAPIAuthManager
    @EnvironmentObject var scrobbleManager: ScrobbleManager
    @EnvironmentObject var lastFMScrobbler: LastFMScrobbler
    @EnvironmentObject var sparkleObserver: SparkleUpdaterObserver
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab = 0

    var body: some View {
        // @Environment has no projected value; @Bindable restores $-bindings.
        @Bindable var sonosManager = sonosManager
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
                Label(L10n.aiTab, systemImage: "brain").tag(6)
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
                .choragusServices(sonosManager)
                .environmentObject(playHistoryManager)
                .environmentObject(smapiManager)
                .environmentObject(scrobbleManager)
                .environmentObject(lastFMScrobbler)
                .environmentObject(sparkleObserver)
        }
        .frame(width: 560, height: 720)
        .onAppear {
            // Deep link: a caller (e.g. the Playlist Builder's "Open
            // Settings" link) stages the tab it wants shown.
            if let pending = UserDefaults.standard.object(forKey: UDKey.settingsPendingTab) as? Int {
                selectedTab = pending
                UserDefaults.standard.removeObject(forKey: UDKey.settingsPendingTab)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .settingsSelectTab)) { note in
            if let tag = note.object as? Int { selectedTab = tag }
            // Consume the staged tab here too: when this window was
            // already open, onAppear never fires, and a stale staged
            // value would hijack the next fresh open.
            UserDefaults.standard.removeObject(forKey: UDKey.settingsPendingTab)
        }
        .onDisappear {
            NSColorPanel.shared.close()
        }
    }
}

// MARK: - Tab Content Router

private struct TabContentView: View {
    @Environment(SonosManager.self) private var sonosManager
    @EnvironmentObject var playHistoryManager: PlayHistoryManager
    @EnvironmentObject var smapiManager: SMAPIAuthManager
    @EnvironmentObject var scrobbleManager: ScrobbleManager
    @EnvironmentObject var lastFMScrobbler: LastFMScrobbler
    @Environment(\.dismiss) private var dismiss
    let tab: Int

    // @AppStorage observes UserDefaults changes so the toggle updates
    // instantly; a manual `Binding(get:set:)` against UserDefaults
    // doesn't, leaving the checkbox visually stuck.
    @AppStorage(UDKey.menuBarEnabled) private var menuBarEnabled = false
    /// Event-listener callback port (applied at next launch — see
    /// EventListener.preferredPort). Clamped to the unprivileged range.
    @AppStorage(UDKey.eventListenerPort) private var eventListenerPort = 3401
    @AppStorage(UDKey.ssdpMulticastTTL) private var ssdpMulticastTTL = Int(Timing.ssdpDefaultMulticastTTL)
    @AppStorage(UDKey.seedSpeakerAddresses) private var seedSpeakerAddresses = ""
    @AppStorage(UDKey.hideDiagnosticsIcon) private var hideDiagnosticsIcon = false
    @AppStorage(UDKey.mediaKeysEnabled) private var mediaKeysEnabled = true
    @AppStorage(UDKey.scrollVolumeEnabled) private var scrollVolumeEnabled = false
    @AppStorage(UDKey.middleClickMuteEnabled) private var middleClickMuteEnabled = true
    @AppStorage(UDKey.classicShuffleEnabled) private var classicShuffleEnabled = false
    @AppStorage(UDKey.proportionalGroupVolume) private var proportionalGroupVolume = false
    @AppStorage(UDKey.ignoreTV) private var ignoreTV = false
    @AppStorage(UDKey.realtimeStats) private var realtimeStats = false
    @AppStorage(UDKey.rollupInterval) private var rollupInterval = 60
    @AppStorage(UDKey.lyricsGlobalOffset) private var lyricsGlobalOffset: Double = -2.0

    var body: some View {
        // @Environment has no projected value; @Bindable restores $-bindings.
        @Bindable var sonosManager = sonosManager
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                switch tab {
                case 0: displayTab
                case 1: musicTab
                case 3: scrobblingTab
                case 4: softwareUpdatesTab
                case 5: visualisationsTab
                case 6: aiTab
                default: systemTab
                }
            }
            .padding(32)
        }
    }

    // MARK: - Display Tab

    @State private var showAppearanceInfo = false

    private var displayTab: some View {
        @Bindable var sonosManager = sonosManager   // @Environment has no projected value
        return Group {
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

                Text(L10n.keyboardControls)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)

                Toggle(L10n.mediaKeysEnabled, isOn: $mediaKeysEnabled)
                Text(L10n.mediaKeysEnabledHint)
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

                    settingsRow(L10n.intervalLabel) {
                        Picker("", selection: $rollupInterval) {
                            Text(L10n.minutes30).tag(30)
                            Text(L10n.hour1).tag(60)
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
                    Text(L10n.historyStats(entries: playHistoryManager.totalEntries, hours: playHistoryManager.totalListeningHours))
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
            // ─── MEDIA SERVERS ───
            settingsSection(L10n.mediaServersHeader) {
                MediaServersSettingsSection()
                    .choragusServices(sonosManager)
            }

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


    // MARK: - AI Tab

    @AppStorage(UDKey.playlistAIEnabled) private var playlistAIEnabled = false
    /// The profile list is loaded on appearance and written back through
    /// `aiPersist()` on every edit — `AIServiceProfileStore` owns the
    /// storage format; this view owns the editing session.
    @State private var aiProfiles: [AIServiceProfile] = []
    @State private var aiSelectedID: UUID?
    @State private var aiKeyDraft = ""
    @State private var aiKeyRevision = 0
    @State private var aiIsTesting = false
    @State private var aiTestRun = 0
    @State private var aiTestError: String?
    /// Model ids fetched from each provider, keyed by profile; a profile
    /// absent here shows the built-in list.
    @State private var aiModelLists: [UUID: [String]] = [:]
    @State private var aiModelsLoadingID: UUID?
    @State private var aiModelsErrors: [UUID: String] = [:]

    private var aiSelected: AIServiceProfile? {
        aiProfiles.first { $0.id == aiSelectedID }
    }

    private var aiSelectedIndex: Int? {
        aiProfiles.firstIndex { $0.id == aiSelectedID }
    }

    private var aiHasKey: Bool {
        _ = aiKeyRevision
        guard let aiSelected else { return false }
        return !(SecretsStore.shared.get(aiSelected.apiKeySecretName) ?? "").isEmpty
    }

    private func aiLoad() {
        aiProfiles = AIServiceProfileStore.load()
        aiSelectedID = AIServiceProfileStore.selected()?.id
    }

    private func aiPersist() {
        AIServiceProfileStore.save(aiProfiles)
        AIServiceProfileStore.selectedID = aiSelectedID
    }

    private func aiSelect(_ id: UUID) {
        aiSelectedID = id
        aiKeyDraft = ""
        aiInvalidateTest()
        aiPersist()
    }

    /// Edits the selected profile's connection settings; any such edit
    /// invalidates its test.
    private func aiUpdate(_ change: (inout AIServiceProfile) -> Void) {
        guard let index = aiSelectedIndex else { return }
        change(&aiProfiles[index])
        aiProfiles[index].verified = false
        aiInvalidateTest()
        aiPersist()
    }

    private func aiRename(_ name: String) {
        guard let index = aiSelectedIndex else { return }
        aiProfiles[index].name = String(name.prefix(AIServiceProfile.maxNameLength))
        aiPersist()
    }

    private func aiAdd(_ provider: SongListAIProvider) {
        let profile = AIServiceProfile.template(provider, existingNames: aiProfiles.map(\.name))
        aiProfiles.append(profile)
        aiSelect(profile.id)
    }

    private func aiRemoveSelected() {
        guard let index = aiSelectedIndex else { return }
        SecretsStore.shared.set(aiProfiles[index].apiKeySecretName, nil)
        aiProfiles.remove(at: index)
        aiSelectedID = aiProfiles.indices.contains(index) ? aiProfiles[index].id : aiProfiles.last?.id
        aiKeyDraft = ""
        aiInvalidateTest()
        aiPersist()
    }

    private func aiMoveSelected(by delta: Int) {
        guard let index = aiSelectedIndex, aiProfiles.indices.contains(index + delta) else { return }
        aiProfiles.swapAt(index, index + delta)
        aiPersist()
    }

    private func aiInvalidateTest() {
        aiTestError = nil
        // Orphan any in-flight test — its result describes the old config.
        aiTestRun &+= 1
        aiIsTesting = false
    }

    /// The picker's rows: the provider's list when fetched, else the
    /// built-in one; the stored model is kept selectable either way.
    private func aiModelOptions(for profile: AIServiceProfile) -> [String] {
        var options = aiModelLists[profile.id] ?? SongListAIConfig.defaultModels(for: profile.provider)
        if !profile.model.isEmpty, !options.contains(profile.model) {
            options.insert(profile.model, at: 0)
        }
        return options
    }

    /// Fetches the provider's model list once per profile (or again on
    /// `force`). Needs a stored key; a failure keeps the built-in list
    /// and shows the reason under the picker.
    private func aiLoadModels(for profile: AIServiceProfile, force: Bool = false) {
        guard profile.provider != .custom, aiHasKey else { return }
        guard force || aiModelLists[profile.id] == nil else { return }
        let config = SongListAIConfig(profile: profile)
        aiModelsLoadingID = profile.id
        aiModelsErrors[profile.id] = nil
        Task {
            do {
                let ids = try await AIModelCatalog.models(for: config)
                if !ids.isEmpty { aiModelLists[profile.id] = ids }
            } catch {
                aiModelsErrors[profile.id] = error.localizedDescription
            }
            if aiModelsLoadingID == profile.id { aiModelsLoadingID = nil }
        }
    }

    private func aiRunTest() {
        guard let profile = aiSelected else { return }
        let config = SongListAIConfig(profile: profile)
        aiIsTesting = true
        aiTestError = nil
        // Run identity: a config change during the round trip
        // invalidates this test — its completion must not stamp the
        // new config as verified.
        aiTestRun &+= 1
        let myTest = aiTestRun
        Task {
            do {
                try await SongListAIService.testConnection(config: config)
                guard myTest == aiTestRun else { return }
                if let index = aiProfiles.firstIndex(where: { $0.id == profile.id }) {
                    aiProfiles[index].verified = true
                    aiPersist()
                }
            } catch {
                guard myTest == aiTestRun else { return }
                aiTestError = error.localizedDescription
            }
            if myTest == aiTestRun { aiIsTesting = false }
        }
    }

    // MARK: - Agent access (MCP)

    @AppStorage(UDKey.mcpEnabled) private var mcpEnabled = false
    @AppStorage(UDKey.mcpAllowLAN) private var mcpAllowLAN = false
    @AppStorage(UDKey.mcpPreventSleep) private var mcpPreventSleep = false
    @AppStorage(UDKey.mcpPort) private var mcpPort = Int(ChoragusMCPServer.defaultPort)
    @ObservedObject private var mcpServer = ChoragusMCPServer.shared
    @State private var mcpTokenRevision = 0
    @State private var mcpNewTokenName = ""
    @State private var mcpNewTokenScope: MCPScope = .control
    @AppStorage(UDKey.mcpMaxVolume) private var mcpMaxVolume = ChoragusMCPServer.defaultMaxVolume
    @AppStorage(UDKey.mcpQuietEnabled) private var mcpQuietEnabled = false
    @AppStorage(UDKey.mcpQuietStart) private var mcpQuietStart = 22
    @AppStorage(UDKey.mcpQuietEnd) private var mcpQuietEnd = 7
    @AppStorage(UDKey.mcpQuietMaxVolume) private var mcpQuietMaxVolume = ChoragusMCPServer.defaultQuietMaxVolume
    @AppStorage(UDKey.mcpShowInToolbar) private var mcpShowInToolbar = true
    @ObservedObject private var mcpActivity = MCPActivityLog.shared
    @State private var mcpLoginItem = SMAppService.mainApp.status == .enabled
    @State private var mcpLoginError: String?

    @ViewBuilder
    private var mcpStatusLabel: some View {
        switch mcpServer.status {
        case .running(let port):
            Label("\(L10n.mcpStatusRunning) · \(port)", systemImage: "circle.fill").foregroundStyle(.green)
        case .stopped:
            Label(L10n.mcpStatusStopped, systemImage: "circle").foregroundStyle(.secondary)
        case .failed(let reason):
            Label(L10n.mcpStatusFailedFormat(reason), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    /// One row per assistant: name and dates, the token itself, Copy and
    /// Revoke. A name field and Add token sit underneath.
    @ViewBuilder
    private var mcpTokenList: some View {
        let _ = mcpTokenRevision
        let tokens = mcpServer.tokens.tokens
        Text(L10n.mcpTokens).font(.callout).foregroundStyle(.secondary)
        if tokens.isEmpty {
            Text(L10n.mcpNoTokens).font(.caption).foregroundStyle(.tertiary)
        }
        ForEach(tokens) { token in
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "key.fill").foregroundStyle(.secondary).frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(token.name).lineLimit(1)
                    Text(token.lastUsedAt.map { L10n.mcpTokenLastUsedFormat($0.formatted(date: .abbreviated, time: .shortened)) }
                         ?? L10n.mcpTokenCreatedFormat(token.createdAt.formatted(date: .abbreviated, time: .omitted)))
                        .font(.caption).foregroundStyle(.secondary)
                    if let calls = mcpActivity.callsByClient[token.name] {
                        Text(L10n.mcpTokenCallsFormat(calls)).font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
                Picker("", selection: Binding(
                    get: { token.scope },
                    set: { mcpServer.tokens.setScope(id: token.id, to: $0); mcpTokenRevision += 1 })) {
                    ForEach(MCPScope.allCases, id: \.self) { Text(mcpScopeTitle($0)).tag($0) }
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .help(mcpScopeHelp(token.scope))
                // First four characters identify the token; Copy carries the rest.
                Text(String((mcpServer.tokens.secret(for: token) ?? "").prefix(4)) + "…")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                Button {
                    if let secret = mcpServer.tokens.secret(for: token) { copyToPasteboard(secret) }
                } label: { Image(systemName: "doc.on.doc") }
                .controlSize(.small)
                .help(L10n.copy)
                Button(role: .destructive) {
                    mcpServer.tokens.revoke(id: token.id)
                    mcpTokenRevision += 1
                } label: { Image(systemName: "trash") }
                .controlSize(.small)
                .help(L10n.mcpRevoke)
            }
            .padding(.vertical, 2)
            Toggle(L10n.mcpSkipConfirm, isOn: Binding(
                get: { token.skipsConfirmations },
                set: { mcpServer.tokens.setSkipsConfirmations(id: token.id, $0); mcpTokenRevision += 1 }))
                .toggleStyle(.checkbox)
                .font(.caption)
                .padding(.leading, 26)
                .padding(.bottom, 4)
                .help(L10n.mcpSkipConfirmHelp)
        }
        HStack(spacing: 8) {
            TextField(L10n.mcpTokenNamePlaceholder, text: $mcpNewTokenName)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 140)
                .onSubmit(mcpAddToken)
            Picker(L10n.mcpScope, selection: $mcpNewTokenScope) {
                ForEach(MCPScope.allCases, id: \.self) { Text(mcpScopeTitle($0)).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .help(mcpScopeHelp(mcpNewTokenScope))
            Button(L10n.mcpAddToken, action: mcpAddToken)
                .fixedSize()
                .disabled(mcpNewTokenName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        Text(L10n.mcpSkipConfirmHelp).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        // What the three levels mean, on the page rather than in a tooltip.
        VStack(alignment: .leading, spacing: 3) {
            ForEach(MCPScope.allCases, id: \.self) { scope in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(mcpScopeTitle(scope)).fontWeight(.medium).frame(width: 76, alignment: .leading)
                    Text(mcpScopeHelp(scope)).foregroundStyle(.secondary)
                }
            }
        }
        .font(.caption)
        .padding(.top, 4)
    }

    private func mcpAddToken() {
        let name = String(mcpNewTokenName.trimmingCharacters(in: .whitespaces).prefix(MCPClientToken.maxNameLength))
        guard !name.isEmpty else { return }
        let created = mcpServer.tokens.create(name: name, scope: mcpNewTokenScope)
        copyToPasteboard(created.secret)
        mcpNewTokenName = ""
        mcpTokenRevision += 1
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func mcpHourLabel(_ hour: Int) -> String {
        var parts = DateComponents(); parts.hour = hour; parts.minute = 0
        let formatter = DateFormatter(); formatter.timeStyle = .short
        return Calendar.current.date(from: parts).map(formatter.string(from:)) ?? String(format: "%02d:00", hour)
    }

    private func mcpScopeTitle(_ scope: MCPScope) -> String {
        switch scope {
        case .readOnly: return L10n.mcpScopeReadOnly
        case .control: return L10n.mcpScopeControl
        case .manage: return L10n.mcpScopeManage
        }
    }

    private func mcpScopeHelp(_ scope: MCPScope) -> String {
        switch scope {
        case .readOnly: return L10n.mcpScopeReadOnlyHelp
        case .control: return L10n.mcpScopeControlHelp
        case .manage: return L10n.mcpScopeManageHelp
        }
    }

    @ViewBuilder
    private var mcpSettings: some View {
        Toggle(L10n.mcpEnable, isOn: $mcpEnabled)
            .onChange(of: mcpEnabled) { mcpServer.applySettings() }
        Text(L10n.mcpEnableHelp)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if mcpEnabled {
            mcpStatusLabel.font(.caption)
            settingsRow(L10n.mcpEndpoint) {
                Text(mcpServer.endpointURL)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                Button(L10n.copy) { copyToPasteboard(mcpServer.endpointURL) }
                    .controlSize(.small)
            }
            mcpTokenList
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.mcpMaxVolume)
                HStack(spacing: 10) {
                    Slider(value: Binding(get: { Double(mcpMaxVolume) }, set: { mcpMaxVolume = Int($0) }), in: 0...100)
                        .frame(maxWidth: 260)
                    Text("\(mcpMaxVolume)").monospacedDigit().frame(width: 30, alignment: .trailing)
                }
            }
            .padding(.top, 6)
            Text(L10n.mcpMaxVolumeHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(L10n.mcpQuietHours, isOn: $mcpQuietEnabled)
                .padding(.top, 6)
            if mcpQuietEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Text(L10n.mcpQuietFrom).foregroundStyle(.secondary)
                        Picker("", selection: $mcpQuietStart) { ForEach(0..<24, id: \.self) { Text(mcpHourLabel($0)).tag($0) } }
                            .labelsHidden().fixedSize()
                        Text(L10n.mcpQuietTo).foregroundStyle(.secondary)
                        Picker("", selection: $mcpQuietEnd) { ForEach(0..<24, id: \.self) { Text(mcpHourLabel($0)).tag($0) } }
                            .labelsHidden().fixedSize()
                    }
                    HStack(spacing: 10) {
                        Text(L10n.mcpQuietVolume).foregroundStyle(.secondary)
                        Slider(value: Binding(get: { Double(mcpQuietMaxVolume) }, set: { mcpQuietMaxVolume = Int($0) }), in: 0...100)
                            .frame(maxWidth: 200)
                        Text("\(mcpQuietMaxVolume)").monospacedDigit().frame(width: 30, alignment: .trailing)
                    }
                }
                .padding(.leading, 20)
            }
            Text(L10n.mcpQuietHoursHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            MCPActivityList(rows: 20)
            settingsRow(L10n.mcpPort) {
                TextField("", value: $mcpPort, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .onSubmit { mcpServer.applySettings() }
            }
            Toggle(L10n.mcpAllowLAN, isOn: $mcpAllowLAN)
                .onChange(of: mcpAllowLAN) { mcpServer.applySettings() }
            Text(L10n.mcpAllowLANHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(L10n.mcpShowInToolbar, isOn: $mcpShowInToolbar)
            Text(L10n.mcpShowInToolbarHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(L10n.mcpPreventSleep, isOn: $mcpPreventSleep)
                .onChange(of: mcpPreventSleep) { mcpServer.applySettings() }
            Toggle(L10n.mcpOpenAtLogin, isOn: $mcpLoginItem)
                .onChange(of: mcpLoginItem) { _, wanted in
                    do {
                        if wanted { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        mcpLoginError = nil
                    } catch {
                        mcpLoginError = error.localizedDescription
                        mcpLoginItem = SMAppService.mainApp.status == .enabled
                    }
                }
            if let mcpLoginError {
                Text(mcpLoginError).font(.caption).foregroundStyle(.orange)
            }
            Button(L10n.mcpSetupLink) { WindowManager.shared.openHelp(topic: .aiPlaylists) }
                .buttonStyle(.link)
        }
    }

    private var aiTab: some View {
        Group {
            // The service list and the selected service's connection
            // settings are one subject — which AI writes the song list —
            // so they share a card instead of sitting in two.
            settingsSection(L10n.aiPlaylistSection) {
                Toggle(L10n.aiEnableService, isOn: $playlistAIEnabled)
                if playlistAIEnabled {
                    aiServiceList
                    if let profile = aiSelected {
                        Divider().padding(.vertical, 6)
                        Text(profile.name)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        aiEditor(profile)
                    }
                }
            }

            settingsSection(L10n.mcpSection) {
                mcpSettings
            }
        }
        .onAppear(perform: aiLoad)
    }

    /// The configured services in menu order, with add / remove /
    /// reorder controls. Selecting a row makes it the builder's source.
    private var aiServiceList: some View {
        VStack(alignment: .leading, spacing: 8) {
            if aiProfiles.isEmpty {
                Text(L10n.aiNoServices)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(aiProfiles) { profile in
                        let selected = profile.id == aiSelectedID
                        Button { aiSelect(profile.id) } label: {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(profile.name)
                                        .fontWeight(selected ? .semibold : .regular)
                                    Text(profile.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if profile.verified {
                                    Image(systemName: "checkmark.seal.fill")
                                        .foregroundStyle(.green)
                                }
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                            .contentShape(Rectangle())
                            .background(selected ? Color.accentColor.opacity(0.15) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack(spacing: 6) {
                Menu {
                    ForEach(SongListAIProvider.allCases, id: \.rawValue) { provider in
                        Button(provider.displayName) { aiAdd(provider) }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(L10n.aiAddService)
                Button { aiRemoveSelected() } label: { Image(systemName: "minus") }
                    .disabled(aiSelected == nil)
                    .help(L10n.aiRemoveService)
                Divider().frame(height: 16)
                Button { aiMoveSelected(by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled((aiSelectedIndex ?? 0) == 0)
                    .help(L10n.moveUp)
                Button { aiMoveSelected(by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(aiSelectedIndex == nil || aiSelectedIndex == aiProfiles.count - 1)
                    .help(L10n.moveDown)
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func aiEditor(_ profile: AIServiceProfile) -> some View {
        settingsRow(L10n.name) {
            LimitedTextField(placeholder: L10n.aiServiceNamePlaceholder,
                             text: Binding(get: { profile.name }, set: { aiRename($0) }),
                             limit: AIServiceProfile.maxNameLength)
                .frame(maxWidth: 280)
        }
        settingsRow(L10n.playlistBuilderAIModel) {
            switch profile.provider {
            case .claude, .openAI:
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Picker("", selection: Binding(get: { profile.model },
                                                      set: { model in aiUpdate { $0.model = model } })) {
                            ForEach(aiModelOptions(for: profile), id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 220)
                        if aiModelsLoadingID == profile.id {
                            ProgressView().controlSize(.small)
                        } else {
                            Button { aiLoadModels(for: profile, force: true) } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.plain)
                            .help(L10n.aiModelsReload)
                            .disabled(!aiHasKey)
                        }
                    }
                    if !aiHasKey {
                        Text(L10n.aiModelsNeedKey)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let reason = aiModelsErrors[profile.id] {
                        Text(L10n.aiModelsUnavailableFormat(reason))
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                // Re-fetch when the profile changes or a key is saved.
                .task(id: "\(profile.id.uuidString)-\(aiKeyRevision)") { aiLoadModels(for: profile) }
            case .custom:
                TextField("", text: Binding(get: { profile.model },
                                            set: { model in aiUpdate { $0.model = model } }))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
            }
        }
        if profile.provider == .custom {
            TextField(L10n.playlistBuilderAIBaseURL,
                      text: Binding(get: { profile.baseURL }, set: { url in aiUpdate { $0.baseURL = url } }))
                .textFieldStyle(.roundedBorder)
            // The URL requests go to — a bare host gains /v1.
            if let endpoint = SongListAIConfig.chatCompletionsURL(baseURL: profile.baseURL) {
                Text(endpoint.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }

        Divider()

        if aiHasKey {
            HStack(spacing: 12) {
                Label(L10n.aiKeyStored, systemImage: "key.fill")
                    .foregroundStyle(.secondary)
                Button(L10n.aiKeyClear) {
                    SecretsStore.shared.set(profile.apiKeySecretName, nil)
                    aiKeyRevision += 1
                    aiUpdate { _ in }
                }
            }
        } else {
            HStack(spacing: 8) {
                SecureField(L10n.playlistBuilderAIKeyPlaceholder, text: $aiKeyDraft)
                    .textFieldStyle(.roundedBorder)
                Button(L10n.aiKeySave) {
                    let trimmed = aiKeyDraft.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    SecretsStore.shared.set(profile.apiKeySecretName, trimmed)
                    aiKeyDraft = ""
                    aiKeyRevision += 1
                    aiUpdate { _ in }
                }
                .disabled(aiKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }

        HStack(spacing: 12) {
            Button(L10n.aiTest) { aiRunTest() }
                .disabled(aiIsTesting
                          || !aiKeyDraft.isEmpty
                          || (profile.provider != .custom && !aiHasKey))
            if aiIsTesting {
                ProgressView().controlSize(.small)
            } else if profile.verified {
                Label(L10n.aiVerified, systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            }
        }
        // A typed-but-unsaved key yields a 401: the test would run
        // with the stored (or empty) key.
        if !aiKeyDraft.isEmpty {
            Text(L10n.aiSaveKeyFirst)
                .font(.caption)
                .foregroundStyle(.orange)
        }
        if let aiTestError {
            Text(aiTestError)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Visualisations Tab

    @AppStorage(UDKey.visGenreMatchMode) private var visGenreMatchModeRaw = VisGenreMatchMode.defaultMode.rawValue
    @AppStorage(UDKey.visRandomSprinklePercent) private var visRandomSprinklePercent: Double = 5.0
    @AppStorage(UDKey.visShowAboutPanel) private var visShowAboutPanel: Bool = true
    @AppStorage(UDKey.visHistorySource) private var visHistorySourceRaw = VisHistorySource.defaultMode.rawValue
    @AppStorage(UDKey.karaokeStyle) private var karaokeStyleRaw = KaraokeStyle.defaultMode.rawValue

    /// Colour-scheme state lives on the shared Club Vis state object
    /// (not @AppStorage) — it persists itself to UserDefaults and
    /// starts the lighting crossfade on every change, so Settings and
    /// the vis window stay on a single source of truth.
    @ObservedObject private var clubVisState = BackOfTheClubDebugState.shared

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

                visSettingRow(label: L10n.visColourScheme,
                              help: L10n.visColourSchemeHelp) {
                    Picker("", selection: $clubVisState.colourScheme) {
                        Text(L10n.visColourSchemeAlbumArt).tag(VisColourScheme.albumArt)
                        Text(L10n.visColourSchemeChoragus).tag(VisColourScheme.choragus)
                        Text(L10n.visColourSchemeCustom).tag(VisColourScheme.custom)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .languageReactive()
                }

                if clubVisState.colourScheme == .custom {
                    HStack(spacing: 24) {
                        customTonePicker(L10n.visCustomToneWash,
                                         hex: $clubVisState.customWashHex,
                                         fallback: ClubStageSets.choragusSet.wash)
                        customTonePicker(L10n.visCustomToneBeamA,
                                         hex: $clubVisState.customBeamAHex,
                                         fallback: ClubStageSets.choragusSet.beamA)
                        customTonePicker(L10n.visCustomToneBeamB,
                                         hex: $clubVisState.customBeamBHex,
                                         fallback: ClubStageSets.choragusSet.beamB)
                        customTonePicker(L10n.visCustomToneAccent,
                                         hex: $clubVisState.customAccentHex,
                                         fallback: ClubStageSets.choragusSet.accent)
                        Spacer()
                    }
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
                // Lyrics timing offset lives here — the karaoke window
                // is the only visible consumer of synced lyrics.
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

    /// One custom-scheme tone: a labelled ColorPicker bridging the
    /// persisted "#RRGGBB" string to SwiftUI Color. Malformed stored
    /// values render as the role's Choragus fallback tone (matching
    /// `ClubStageSets.customSet`).
    private func customTonePicker(_ label: String,
                                  hex: Binding<String>,
                                  fallback: StageTone) -> some View {
        ColorPicker(label, selection: Binding<Color>(
            get: {
                (StageTone(hex: hex.wrappedValue) ?? fallback).color
            },
            set: { newColor in
                let ns = NSColor(newColor).usingColorSpace(.sRGB) ?? .white
                hex.wrappedValue = StageTone(r: Double(ns.redComponent),
                                             g: Double(ns.greenComponent),
                                             b: Double(ns.blueComponent)).hexString
            }),
            supportsOpacity: false)
            .font(.body)
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
    @State private var showAdvancedNetwork = false
    @State private var showCacheInfo = false
    @State private var showClearSpeakerCacheConfirm = false
    @State private var showClearArtworkCacheConfirm = false

    private var systemTab: some View {
        @Bindable var sonosManager = sonosManager   // @Environment has no projected value
        return Group {
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

                // Three controls that only matter when discovery is
                // failing, collapsed behind one row.
                DisclosureGroup(isExpanded: $showAdvancedNetwork) {
                    VStack(alignment: .leading, spacing: 12) {
                        settingsRow(L10n.eventListenerPort) {
                            TextField("", value: $eventListenerPort, format: .number.grouping(.never))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 90)
                                .onSubmit { clampEventListenerPort() }
                        }
                        Text(L10n.eventListenerPortHint)
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        Divider()

                        settingsRow(L10n.ssdpMulticastTTL) {
                            TextField("", value: $ssdpMulticastTTL, format: .number.grouping(.never))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 90)
                                .onSubmit { clampMulticastTTL() }
                        }
                        Text(L10n.ssdpMulticastTTLHint)
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        Divider()

                        Text(L10n.seedSpeakerAddresses)
                            .font(.body)
                        TextEditor(text: $seedSpeakerAddresses)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 64, maxHeight: 96)
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(.secondary.opacity(0.3)))
                        Text(L10n.seedSpeakerAddressesHint)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 10)
                } label: {
                    // macOS makes only the disclosure triangle a hit target;
                    // contentShape makes the whole row width clickable.
                    Text(L10n.advancedNetwork)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showAdvancedNetwork.toggle()
                            }
                        }
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
                            Text(L10n.days7).tag(7)
                            Text(L10n.days30).tag(30)
                            Text(L10n.days90).tag(90)
                            Text(L10n.year1).tag(365)
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

    @EnvironmentObject private var sparkleObserver: SparkleUpdaterObserver

    private var softwareUpdatesTab: some View {
        VStack(alignment: .leading, spacing: 28) {
            updatesSection
        }
    }

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsSection(L10n.softwareUpdates) {
                // Version line, clickable to open the full About window
                // (build, copyright, credits). Plain-button styling +
                // .link pointer keeps it understated.
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
        SettingsSectionCard(title, body: content())
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

    /// Keep the event-listener port inside the unprivileged range —
    /// EventListener falls back to the default for out-of-range values, so
    /// the clamp keeps the field showing what will actually bind.
    private func clampEventListenerPort() {
        if eventListenerPort < 1024 || eventListenerPort > 65535 {
            eventListenerPort = 3401
        }
    }


    private func clampMulticastTTL() {
        let limit = Int(Timing.ssdpMaxMulticastTTL)
        if ssdpMulticastTTL < 1 || ssdpMulticastTTL > limit {
            ssdpMulticastTTL = Int(Timing.ssdpDefaultMulticastTTL)
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

// MARK: - Section card

/// The shaded, rounded settings section every tab uses — a headline
/// title above a card of controls. Shared so tabs that live in their
/// own files (Scrobbling) render the same way.
struct SettingsSectionCard<Content: View>: View {
    let title: String
    let inner: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.inner = content()
    }

    init(_ title: String, body: Content) {
        self.title = title
        self.inner = body
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .padding(.leading, 4)

            VStack(alignment: .leading, spacing: 12) {
                inner
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
