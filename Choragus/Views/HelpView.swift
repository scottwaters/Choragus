/// HelpView.swift — In-app help for Choragus.
///
/// Rendered in a dedicated auxiliary window (see WindowManager.openHelp).
/// Uses a two-column layout: topic list on the left, content on the right.
/// Both topic titles and body content are localized via L10n; see
/// SonosKit/Localization/L10n.swift for the translation dictionary.
import SwiftUI
import SonosKit

struct HelpView: View {
    @State private var selected: HelpTopic

    init(initialTopic: HelpTopic = .gettingStarted) {
        _selected = State(initialValue: initialTopic)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selected) {
                Label(HelpTopic.gettingStarted.title, systemImage: HelpTopic.gettingStarted.symbol)
                    .tag(HelpTopic.gettingStarted)
                ForEach(HelpTopic.groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.topics) { topic in
                            Label(topic.title, systemImage: topic.symbol)
                                .tag(topic)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 260)
        } detail: {
            ScrollView {
                content(for: selected)

                    .textSelection(.enabled)
                    .padding(24)
                    .frame(maxWidth: 640, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(selected.title)
        }
        .frame(minWidth: 720, minHeight: 480)
        // Deep link for an already-open window ("How does this work?"
        // in the Playlist Builder targets a topic directly).
        .onReceive(NotificationCenter.default.publisher(for: .helpSelectTopic)) { note in
            if let raw = note.object as? String, let topic = HelpTopic(rawValue: raw) {
                selected = topic
            }
        }
    }

    @ViewBuilder
    private func content(for topic: HelpTopic) -> some View {
        switch topic {
        case .gettingStarted:     gettingStarted
        case .aiPlaylists:        aiPlaylists
        case .playback:           playback
        case .nowPlayingDetails:  nowPlayingDetails
        case .grouping:           grouping
        case .browsing:           browsing
        case .musicServices:      musicServices
        case .systems:            systems
        case .preferences:        preferences
        case .diagnostics:        diagnostics
        case .shortcuts:          shortcuts
        case .appleShortcuts:     appleShortcuts
        case .alarms:             alarmsHelp
        case .visualisations:     visualisationsHelp
        case .agentAccess:        agentAccessHelp
        case .about:              about
        }
    }

    // MARK: - Sections

    private var visualisationsHelp: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading(L10n.helpVisualisationsHeading)
            paragraph(L10n.helpVisIntroBody)
            heading(L10n.visBackOfTheClubSection)
            paragraph(L10n.helpVisWallBody)
            paragraph(L10n.helpVisLightingBody)
            paragraph(L10n.helpVisSettingsBody)
            heading(L10n.helpKaraokePopoutHeading)
            paragraph(L10n.helpKaraokePopoutBody)
            paragraph(L10n.helpKaraokeSettingsBody)
        }
    }

    private var agentAccessHelp: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading(L10n.mcpSection)
            paragraph(L10n.helpMCPBody)
            heading(L10n.helpAgentWhatHeading)
            bulletedList([
                L10n.helpAgentBulletPlay,
                L10n.helpAgentBulletFind,
                L10n.helpAgentBulletQueue,
                L10n.helpAgentBulletPlaylists,
                L10n.helpAgentBulletBuilder,
                L10n.helpAgentBulletHouse,
                L10n.helpAgentBulletHistory,
                L10n.helpAgentBulletAlarms,
            ])
            heading(L10n.helpAgentLimitsHeading)
            paragraph(L10n.helpAgentLimitsBody)
            heading(L10n.helpMCPHeading)
            paragraph(L10n.helpMCPClientsBody)
            Text("claude mcp add --transport http choragus \\\n  \(ChoragusMCPServer.shared.endpointURL) \\\n  --header \"Authorization: Bearer <token>\"")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            paragraph(L10n.helpMCPOtherClientsBody)
            paragraph(L10n.helpMCPSafetyBody)
        }
    }

    private var alarmsHelp: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading(L10n.helpAlarmsHeading)
            paragraph(L10n.helpAlarmsBody)
            paragraph(L10n.helpAlarmsEditorBody)
            paragraph(L10n.helpAlarmsNotesBody)
        }
    }

    private var gettingStarted: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading(L10n.helpWelcome)
            paragraph(L10n.helpWelcomeBody)
            heading(L10n.helpFirstLaunch)
            bulletedList([
                L10n.helpBulletDiscovery,
                L10n.helpBulletSidebarRooms,
                L10n.helpBulletSelectRoom,
                L10n.helpBulletToolbar
            ])
            heading(L10n.helpNoSpeakersFound)
            paragraph(L10n.helpNoSpeakersFoundBody)
            heading(L10n.helpRebrandHeading)
            paragraph(L10n.helpRebrandBody)
        }
    }


    private var aiPlaylists: some View {
        VStack(alignment: .leading, spacing: 12) {
            paragraph(L10n.helpAIPlaylistsIntroBody)
            heading(L10n.helpAIPlaylistsAIHeading)
            paragraph(L10n.helpAIPlaylistsAIBody)
            heading(L10n.helpAIPlaylistsManualHeading)
            paragraph(L10n.helpAIPlaylistsManualBody)
            heading(L10n.helpAIPlaylistsSamplesHeading)
            bulletedList(L10n.playlistSamplePrompts)
            paragraph(L10n.helpAIPlaylistsFormatBody)
            Text("""
            Bridge Over Troubled Water - Simon & Garfunkel
            My Sharona - The Knack
            Le Freak - Chic
            """)
            .font(.system(.callout, design: .monospaced))
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            heading(L10n.helpMCPHeading)
            paragraph(L10n.helpMCPSeeAgentAccess)
        }
    }

    private var playback: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading(L10n.helpControllingPlayback)
            paragraph(L10n.helpControllingPlaybackBody)
            bulletedList([
                L10n.helpBulletSpaceBar,
                L10n.helpBulletControlsMenu,
                L10n.helpBulletRightClickRoom,
                L10n.helpBulletStarTrack
            ])
            heading(L10n.helpVolumeHeading)
            paragraph(L10n.helpVolumeBody)
            paragraph(L10n.helpVolumeSyncBody)
            heading(L10n.helpCrossfadeSleepHeading)
            paragraph(L10n.helpCrossfadeSleepBody)
            heading(L10n.helpMediaKeysHeading)
            paragraph(L10n.helpMediaKeysBody)
            paragraph(L10n.helpLockedScreenBody)
            heading(L10n.helpTransportState)
            paragraph(L10n.helpTransportStateBody)
            paragraph(L10n.helpQueueFollowBody)
            paragraph(L10n.helpQueueSourceBody)
            paragraph(L10n.helpQueueHeaderBody)
            heading(L10n.helpQueueSelectionHeading)
            paragraph(L10n.helpQueueSelectionBody)
            paragraph(L10n.helpQueueRunningTimeBody)
            heading(L10n.helpQueueHealthHeading)
            paragraph(L10n.helpQueueHealthBody)
            heading(L10n.helpQueueLibraryHeading)
            paragraph(L10n.helpQueueLibraryBody)
            paragraph(L10n.helpQueueLibrarySourcesBody)
            paragraph(L10n.helpQueueLibraryOrganiseBody)
            paragraph(L10n.helpQueueLibraryDeletedBody)
            paragraph(L10n.helpQueueLibraryExportBody)
            paragraph(L10n.helpSaveToPlaylistBody)
            paragraph(L10n.helpWindowLifecycleBody)
        }
    }

    private var nowPlayingDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading(L10n.helpNowPlayingDetailsHeading)
            paragraph(L10n.helpNowPlayingDetailsBody)
            heading(L10n.helpLyricsTabHeading)
            paragraph(L10n.helpLyricsTabBody)
            bulletedList([
                L10n.helpBulletLyricsSynced,
                L10n.helpBulletLyricsPlain,
                L10n.helpBulletLyricsOffset
            ])
            heading(L10n.helpKaraokePopoutHeading)
            paragraph(L10n.helpKaraokePopoutBody)
            paragraph(L10n.helpKaraokeSettingsBody)
            heading(L10n.helpAboutTabHeading)
            paragraph(L10n.helpAboutTabBody)
            paragraph(L10n.helpArtworkBody)
            heading(L10n.helpHistoryTabHeading)
            paragraph(L10n.helpHistoryTabBody)
            paragraph(L10n.helpHistoryActionsBody)
            paragraph(L10n.helpAudioFormatBadgesBody)
            heading(L10n.helpHomeTheaterTogglesHeading)
            paragraph(L10n.helpHomeTheaterTogglesBody)
            heading(L10n.helpCollapseHeading)
            paragraph(L10n.helpCollapseBody)
        }
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading(L10n.helpDiagnosticsHeading)
            paragraph(L10n.helpDiagnosticsBody)
            heading(L10n.helpDiagnosticsOpeningHeading)
            paragraph(L10n.helpDiagnosticsOpeningBody)
            heading(L10n.helpDiagnosticsLiveEventsHeading)
            paragraph(L10n.helpDiagnosticsLiveEventsBody)
            paragraph(L10n.helpSpeakersTabBody)
            heading(L10n.helpNetworkTabHeading)
            paragraph(L10n.helpNetworkTabBody)
            heading(L10n.diagTabMCP)
            paragraph(L10n.helpDiagnosticsMCPBody)
            heading(L10n.helpDiagnosticsReportingHeading)
            paragraph(L10n.helpDiagnosticsReportingBody)
            heading(L10n.helpDiagnosticsEncryptedHeading)
            paragraph(L10n.helpDiagnosticsEncryptedBody)
            heading(L10n.helpLogMessagesHeading)
            paragraph(L10n.helpLogMessagesBody)
            bulletedList([
                L10n.helpLogSpeakerConnection,
                L10n.helpLogPlaybackQueue,
                L10n.helpLogServicesAccounts,
                L10n.helpLogDataStorage,
                L10n.helpLogControlsGrouping,
                L10n.helpLogArtwork
            ])
            heading(L10n.helpDiagnosticsRedactionHeading)
            paragraph(L10n.helpDiagnosticsRedactionBody)
        }
    }

    private var grouping: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading(L10n.helpGroupingSpeakers)
            paragraph(L10n.helpGroupingSpeakersBody)
            bulletedList([
                L10n.helpBulletEditGroup,
                L10n.helpBulletUngroupAll,
                L10n.helpBulletGroupAll,
                L10n.helpBulletRescan,
                L10n.helpBulletPreset
            ])
            heading(L10n.helpPresetsHeading)
            paragraph(L10n.helpPresetsBody)
            heading(L10n.helpGroupingGesturesHeading)
            paragraph(L10n.helpGroupingGesturesBody)
            heading(L10n.helpHomeTheaterSets)
            paragraph(L10n.helpHomeTheaterSetsBody)
            paragraph(L10n.helpSurroundModeBody)
        }
    }

    private var browsing: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading(L10n.helpBrowsingMusicSection)
            paragraph(L10n.helpBrowsingMusicBody)
            bulletedList([
                L10n.helpBulletFavorites,
                L10n.helpBulletLibrary,
                L10n.helpBulletServicesSection,
                L10n.helpBulletChoragusSources,
                L10n.helpBulletSearch,
                L10n.helpBulletRecentlyPlayed,
                L10n.helpBulletLineIn
            ])
            paragraph(L10n.helpRenameFavoriteBody)
            paragraph(L10n.helpPlaylistManagementBody)
            paragraph(L10n.helpFastScrollBody)
            paragraph(L10n.helpBrowseSectionCardsBody)
            paragraph(L10n.helpSortBody)
            heading(L10n.helpAppleMusicHeading)
            paragraph(L10n.helpAppleMusicBody)
            heading(L10n.helpPlexHeading)
            paragraph(L10n.helpPlexBody)
            heading(L10n.helpAddingToQueue)
            paragraph(L10n.helpAddingToQueueBody)
        }
    }

    private var musicServices: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading(L10n.helpMusicServicesHeading)
            paragraph(L10n.helpMusicServicesBody)
            heading(L10n.helpStatusDotsHeading)
            paragraph(L10n.helpStatusDotsBody)
            bulletedList([
                L10n.helpBulletDotBlue,
                L10n.helpBulletDotGreen,
                L10n.helpBulletDotYellow,
                L10n.helpBulletDotRed,
                L10n.helpBulletDotGray
            ])
            heading(L10n.helpServiceSetupHeading)
            paragraph(L10n.helpServiceSetupBody)
            heading(L10n.helpMoreServicesHeading)
            paragraph(L10n.helpMoreServicesBody)
            paragraph(L10n.helpSunoBody)
            heading(L10n.helpLibrarySharesHeading)
            paragraph(L10n.helpLibrarySharesBody)
            heading(L10n.helpServiceNotesHeading)
            paragraph(L10n.helpServiceNotesBody)
            heading(L10n.helpMediaServersHeading)
            paragraph(L10n.helpMediaServersBody)
        }
    }

    private var systems: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading(L10n.helpSystemsSection)
            paragraph(L10n.helpSystemsBody)
            bulletedList([
                L10n.helpBulletBothSystems,
                L10n.helpBulletOneSystem,
                L10n.helpBulletUPnPIdent
            ])
            heading(L10n.helpIndependence)
            paragraph(L10n.helpIndependenceBody)
        }
    }

    private var preferences: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading(L10n.helpPreferencesSection)
            paragraph(L10n.helpPreferencesBody)
            bulletedList([
                L10n.helpBulletAppearance,
                L10n.helpBulletColors,
                L10n.helpBulletLanguage,
                L10n.helpBulletDisplayTab,
                L10n.helpBulletMenuBar,
                L10n.helpBulletMouseControls,
                L10n.helpBulletHistorySettings,
                L10n.helpBulletPlaybackSettings,
                L10n.helpBulletAITab,
                L10n.helpBulletCommunication,
                L10n.helpBulletDiscoveryMode,
                L10n.helpBulletDiscoveryHopLimit,
                L10n.helpBulletSeedAddresses,
                L10n.helpBulletSystemTab,
                L10n.helpBulletQuickStart,
                L10n.helpBulletMusicServices,
                L10n.helpBulletScrobbling,
                L10n.helpBulletImageCache,
                L10n.helpBulletSoftwareUpdates
            ])
            heading(L10n.helpSoftwareUpdatesHeading)
            paragraph(L10n.helpSoftwareUpdatesBody)
            heading(L10n.helpBetaChannelHeading)
            paragraph(L10n.helpBetaChannelBody)
            paragraph(L10n.helpIgnoreTVBody)
            heading(L10n.helpVisualisationsHeading)
            paragraph(L10n.helpVisualisationsBody)
            heading(L10n.helpListeningStatsSection)
            paragraph(L10n.helpListeningStatsBody)
        }
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading(L10n.helpShortcutsHeading)
            shortcutGroup(title: L10n.helpShortcutGroupPlayback, items: [
                (L10n.playPause, "\u{2318}P"),
                (L10n.helpPlayPauseFocus, "Space"),
                (L10n.nextTrack, "\u{2318}\u{2192}"),
                (L10n.previousTrack, "\u{2318}\u{2190}"),
                (L10n.muteUnmute, "\u{2325}\u{2318}\u{2193}")
            ])
            shortcutGroup(title: L10n.helpShortcutGroupView, items: [
                (L10n.toggleBrowseLibrary, "\u{2318}B"),
                (L10n.togglePlayQueue, "\u{2325}\u{2318}U"),
                (L10n.queueLibrary, "\u{2318}L"),
                (L10n.listeningStats, "\u{21E7}\u{2318}S"),
                (L10n.alarms, "\u{21E7}\u{2318}A"),
                (L10n.karaoke, "\u{2318}K"),
                (L10n.clubVis, "\u{2318}J"),
                (L10n.helpEnterFullScreen, "\u{2303}\u{2318}F")
            ])
            shortcutGroup(title: L10n.helpShortcutGroupApp, items: [
                (L10n.settings, "\u{2318},"),
                (L10n.openChoragus, "\u{2318}0"),
                (L10n.helpShortcutsHelp, "\u{2318}?"),
                (L10n.helpHideApp, "\u{2318}H"),
                (L10n.helpQuitApp, "\u{2318}Q")
            ])
        }
    }

    private var appleShortcuts: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading(L10n.helpAppleShortcutsHeading)
            paragraph(L10n.helpAppleShortcutsBody)
            heading(L10n.helpAppleShortcutsActionsHeading)
            bulletedList([
                L10n.helpShortcutActionPlay,
                L10n.helpShortcutActionSkip,
                L10n.helpShortcutActionVolume,
                L10n.helpShortcutActionPreset,
                L10n.helpShortcutActionInput
            ])
            heading(L10n.helpAppleShortcutsScheduleHeading)
            paragraph(L10n.helpAppleShortcutsScheduleBody)
            if let url = URL(string: "https://github.com/scottwaters/Choragus/blob/main/docs/SHORTCUTS.md") {
                Link("docs/SHORTCUTS.md", destination: url)
                    .font(.body)
            }
        }
    }

    private var about: some View {
        // About reads more like a credits card than a help article —
        // centering the text reflects that and matches the convention
        // most macOS apps use for their About sheet.
        VStack(alignment: .center, spacing: 12) {
            centeredHeading(L10n.helpAboutSection)
            centeredParagraph(L10n.helpAboutBody1)
            centeredParagraph(L10n.helpAboutBody2)
            centeredHeading(L10n.helpSourceCodeAndIssues)
            if let url = AppLinks.repositoryURL {
                Link("github.com/scottwaters/Choragus", destination: url)
                    .font(.body)
            }
            // Optional support link — rendered only when the bundle
            // carries a `ChoragusSupportURL` Info.plist key. Packaging
            // injects it; a bare checkout builds without one, so the
            // row is absent from third-party builds by construction.
            if let supportString = Bundle.main.object(forInfoDictionaryKey: "ChoragusSupportURL") as? String,
               !supportString.isEmpty,
               let supportURL = URL(string: supportString) {
                Link(destination: supportURL) {
                    Label(L10n.supportProject, systemImage: "heart")
                }
                .font(.body)
            }
            centeredHeading(L10n.helpSupportHeading)
            centeredParagraph(L10n.helpSupportBody)
            centeredHeading(L10n.helpLicense)
            centeredParagraph(L10n.helpLicenseBody)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func centeredHeading(_ text: String) -> some View {
        Text(text)
            .font(.title3)
            .fontWeight(.semibold)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 4)
    }

    private func centeredParagraph(_ text: String) -> some View {
        Text(text)
            .font(.body)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Helpers

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.title3)
            .fontWeight(.semibold)
            .padding(.top, 4)
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(.body)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func bulletedList(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\u{2022}").font(.body).foregroundStyle(.secondary)
                    Text(item).font(.body).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func shortcutGroup(title: String, items: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
                .padding(.top, 4)
            ForEach(items, id: \.0) { label, keys in
                HStack {
                    Text(label).font(.body)
                    Spacer()
                    Text(keys)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
    }
}

enum HelpTopic: String, CaseIterable, Identifiable {
    /// Sidebar groups by what the reader is doing; Getting Started sits
    /// above them on its own.
    struct Group {
        let title: String
        let topics: [HelpTopic]
    }

    static var groups: [Group] {
        [
            Group(title: L10n.helpGroupListening, topics: [.playback, .nowPlayingDetails, .grouping, .alarms, .visualisations]),
            Group(title: L10n.helpGroupMusic, topics: [.browsing, .musicServices]),
            Group(title: L10n.helpGroupAI, topics: [.aiPlaylists, .agentAccess]),
            Group(title: L10n.helpGroupAutomation, topics: [.appleShortcuts, .shortcuts]),
            Group(title: L10n.helpGroupSystem, topics: [.systems, .preferences, .diagnostics, .about]),
        ]
    }

    case gettingStarted
    case aiPlaylists
    case playback
    case nowPlayingDetails
    case grouping
    case browsing
    case musicServices
    case systems
    case preferences
    case diagnostics
    case shortcuts
    case appleShortcuts
    case alarms
    case visualisations
    case agentAccess
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gettingStarted:     return L10n.helpGettingStarted
        case .aiPlaylists:        return L10n.helpAIPlaylists
        case .playback:           return L10n.helpPlayback
        case .nowPlayingDetails:  return L10n.helpNowPlayingDetails
        case .grouping:           return L10n.helpGrouping
        case .browsing:           return L10n.helpBrowsingMusic
        case .musicServices:      return L10n.helpMusicServicesTopic
        case .systems:            return L10n.helpS1AndS2
        case .preferences:        return L10n.helpPreferences
        case .diagnostics:        return L10n.helpDiagnosticsTopic
        case .shortcuts:          return L10n.helpKeyboardShortcuts
        case .appleShortcuts:     return L10n.helpAppleShortcuts
        case .alarms:             return L10n.alarms
        case .visualisations:     return L10n.helpVisualisationsHeading
        case .agentAccess:        return L10n.mcpSection
        case .about:              return L10n.helpAboutAndSupport
        }
    }

    var symbol: String {
        switch self {
        case .gettingStarted:     return "sparkles"
        case .aiPlaylists:        return "wand.and.stars"
        case .playback:           return "play.circle"
        case .nowPlayingDetails:  return "text.book.closed"
        case .grouping:           return "hifispeaker.2"
        case .browsing:           return "music.note.list"
        case .musicServices:      return "circle.grid.2x2"
        case .systems:            return "rectangle.on.rectangle"
        case .preferences:        return "gear"
        case .diagnostics:        return "ant"
        case .shortcuts:          return "keyboard"
        case .appleShortcuts:     return "square.2.layers.3d"
        case .alarms:             return "alarm"
        case .visualisations:     return "sparkles.tv"
        case .agentAccess:        return "brain"
        case .about:              return "info.circle"
        }
    }
}
