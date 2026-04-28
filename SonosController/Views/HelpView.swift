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
        case .gettingStarted:    gettingStarted
        case .playback:          playback
        case .grouping:          grouping
        case .browsing:          browsing
        case .systems:           systems
        case .preferences:       preferences
        case .shortcuts:         shortcuts
        case .about:             about
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
            heading(L10n.helpTransportState)
            paragraph(L10n.helpTransportStateBody)
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
            heading(L10n.helpHomeTheaterSets)
            paragraph(L10n.helpHomeTheaterSetsBody)
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
                L10n.helpBulletSearch
            ])
            heading(L10n.helpAddingToQueue)
            paragraph(L10n.helpAddingToQueueBody)
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
                L10n.helpBulletMenuBar,
                L10n.helpBulletCommunication,
                L10n.helpBulletQuickStart,
                L10n.helpBulletMusicServices
            ])
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
    case grouping
    case browsing
    case systems
    case preferences
    case shortcuts
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gettingStarted: return L10n.helpGettingStarted
        case .playback:       return L10n.helpPlayback
        case .grouping:       return L10n.helpGrouping
        case .browsing:       return L10n.helpBrowsingMusic
        case .systems:        return L10n.helpS1AndS2
        case .preferences:    return L10n.helpPreferences
        case .shortcuts:      return L10n.helpKeyboardShortcuts
        case .about:          return L10n.helpAboutAndSupport
        }
    }

    var symbol: String {
        switch self {
        case .gettingStarted: return "sparkles"
        case .playback:       return "play.circle"
        case .grouping:       return "hifispeaker.2"
        case .browsing:       return "music.note.list"
        case .systems:        return "rectangle.on.rectangle"
        case .preferences:    return "gear"
        case .shortcuts:      return "keyboard"
        case .about:          return "info.circle"
        }
    }
}
