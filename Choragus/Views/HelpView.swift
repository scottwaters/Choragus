/// HelpView.swift — In-app help for Choragus.
///
/// Rendered in a dedicated auxiliary window (see WindowManager.openHelp).
/// Uses a two-column layout: topic list on the left, content on the right.
/// Both topic titles and body content are localized via L10n; see
/// SonosKit/Localization/L10n.swift for the translation dictionary.
import SwiftUI
import SonosKit

struct HelpView: View {
    @State private var selected: HelpTopic = .gettingStarted

    var body: some View {
        NavigationSplitView {
            List(HelpTopic.allCases, selection: $selected) { topic in
                Label(topic.title, systemImage: topic.symbol)
                    .tag(topic)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 260)
        } detail: {
            ScrollView {
                content(for: selected)
                    .padding(24)
                    .frame(maxWidth: 640, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(selected.title)
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    @ViewBuilder
    private func content(for topic: HelpTopic) -> some View {
        switch topic {
        case .gettingStarted:     gettingStarted
        case .playback:           playback
        case .nowPlayingDetails:  nowPlayingDetails
        case .grouping:           grouping
        case .browsing:           browsing
        case .musicServices:      musicServices
        case .systems:            systems
        case .preferences:        preferences
        case .diagnostics:        diagnostics
        case .shortcuts:          shortcuts
        case .about:              about
        }
    }

    // MARK: - Sections

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
            heading(L10n.helpQueueLibraryHeading)
            paragraph(L10n.helpQueueLibraryBody)
            paragraph(L10n.helpQueueLibrarySourcesBody)
            paragraph(L10n.helpQueueLibraryOrganiseBody)
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
            heading(L10n.helpDiagnosticsReportingHeading)
            paragraph(L10n.helpDiagnosticsReportingBody)
            heading(L10n.helpDiagnosticsEncryptedHeading)
            paragraph(L10n.helpDiagnosticsEncryptedBody)
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
                L10n.helpBulletSearch,
                L10n.helpBulletRecentlyPlayed,
                L10n.helpBulletLineIn
            ])
            paragraph(L10n.helpRenameFavoriteBody)
            paragraph(L10n.helpPlaylistManagementBody)
            paragraph(L10n.helpFastScrollBody)
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
                L10n.helpBulletMenuBar,
                L10n.helpBulletMouseControls,
                L10n.helpBulletCommunication,
                L10n.helpBulletDiscoveryMode,
                L10n.helpBulletDiscoveryHopLimit,
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
                (L10n.listeningStats, "\u{21E7}\u{2318}S"),
                (L10n.helpEnterFullScreen, "\u{2303}\u{2318}F")
            ])
            shortcutGroup(title: L10n.helpShortcutGroupApp, items: [
                (L10n.settings, "\u{2318},"),
                (L10n.helpShortcutsHelp, "\u{2318}?"),
                (L10n.helpHideApp, "\u{2318}H"),
                (L10n.helpQuitApp, "\u{2318}Q")
            ])
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
    case gettingStarted
    case playback
    case nowPlayingDetails
    case grouping
    case browsing
    case musicServices
    case systems
    case preferences
    case diagnostics
    case shortcuts
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gettingStarted:     return L10n.helpGettingStarted
        case .playback:           return L10n.helpPlayback
        case .nowPlayingDetails:  return L10n.helpNowPlayingDetails
        case .grouping:           return L10n.helpGrouping
        case .browsing:           return L10n.helpBrowsingMusic
        case .musicServices:      return L10n.helpMusicServicesTopic
        case .systems:            return L10n.helpS1AndS2
        case .preferences:        return L10n.helpPreferences
        case .diagnostics:        return L10n.helpDiagnosticsTopic
        case .shortcuts:          return L10n.helpKeyboardShortcuts
        case .about:              return L10n.helpAboutAndSupport
        }
    }

    var symbol: String {
        switch self {
        case .gettingStarted:     return "sparkles"
        case .playback:           return "play.circle"
        case .nowPlayingDetails:  return "text.book.closed"
        case .grouping:           return "hifispeaker.2"
        case .browsing:           return "music.note.list"
        case .musicServices:      return "circle.grid.2x2"
        case .systems:            return "rectangle.on.rectangle"
        case .preferences:        return "gear"
        case .diagnostics:        return "ant"
        case .shortcuts:          return "keyboard"
        case .about:              return "info.circle"
        }
    }
}
