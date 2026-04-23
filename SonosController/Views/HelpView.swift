/// HelpView.swift — In-app help for SonosController.
///
/// Rendered in a dedicated auxiliary window (see WindowManager.openHelp).
/// Uses a two-column layout: topic list on the left, content on the right.
/// Topic titles are localized via L10n; body paragraphs remain in English
/// in this release to keep scope reasonable.
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
            heading("Welcome")
            paragraph("SonosController is a native macOS controller for Sonos speakers. All control happens locally over your network — no cloud account is required.")
            heading("First launch")
            bulletedList([
                "Speakers on your local network are discovered automatically via SSDP.",
                "The sidebar lists every room, grouped by system (S2 modern, S1 legacy).",
                "Select a room to show its Now Playing view.",
                "Use the toolbar to show the music browser and play queue."
            ])
            heading("No speakers found?")
            paragraph("Make sure the Mac is on the same Wi-Fi network as the speakers. When the app asks for permission to access devices on the local network, grant it — discovery will not work otherwise.")
        }
    }

    private var playback: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("Controlling playback")
            paragraph("Select a room in the sidebar. The Now Playing view shows the current track, transport controls, and volume for the selected group.")
            bulletedList([
                "Space bar toggles play and pause while the Now Playing view has focus.",
                "The Controls menu provides Play/Pause, Next, Previous, and Mute with standard keyboard shortcuts.",
                "Right-click a room for quick Play/Pause, Mute, and grouping actions.",
                "Right-click the track title to star the track so it appears in Starred history."
            ])
            heading("Volume")
            paragraph("The volume slider below the track adjusts the coordinator. When the group contains multiple speakers, enabling Proportional Group Volume in Settings keeps the relative volumes of each speaker intact when you drag the slider.")
            heading("Transport state")
            paragraph("SonosController uses UPnP event subscriptions for near-instant state updates. If your network drops events, the app falls back to periodic polling automatically.")
        }
    }

    private var grouping: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("Grouping speakers")
            paragraph("A group has one coordinator and zero or more members. All members play whatever the coordinator plays, in sync.")
            bulletedList([
                "Right-click a room → Edit Group… to assemble or disband a group with checkboxes.",
                "Right-click a grouped room → Ungroup All to split all members back into single-room groups.",
                "Save a frequently used arrangement as a Preset from the speaker menu in the toolbar."
            ])
            heading("Home Theater sets")
            paragraph("Speakers paired as home-theater satellites or subwoofers are hidden from the sidebar as individual rows. Right-click the home-theater room and choose Home Theater EQ… to tune channel levels.")
        }
    }

    private var browsing: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("Browsing music")
            paragraph("Click the music-library button in the toolbar, or press ⌘B, to open the browser panel.")
            bulletedList([
                "Sonos Favorites and Sonos Playlists appear at the top.",
                "The music library browses any indexed shares on the speaker.",
                "Enabled music services (set in Settings → Services) show as additional sections.",
                "Search across enabled services with the search field; results are cached so the back button returns to prior search results."
            ])
            heading("Adding to the queue")
            paragraph("Drag an item from the browser into the Play Queue panel (⌥⌘U) to enqueue, or click it to play immediately.")
        }
    }

    private var systems: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("Sonos S1 and S2 systems")
            paragraph("Sonos speakers are split across two platforms. Legacy S1 speakers and modern S2 speakers cannot join the same household, but both can coexist on the same network.")
            bulletedList([
                "If both systems are present, the sidebar shows an S2 section and an S1 section separated by a horizontal divider.",
                "When only one system is present, no section headers are shown.",
                "Each speaker self-identifies its platform via its UPnP device description; classification does not require any cloud service."
            ])
            heading("Independence")
            paragraph("S1 and S2 groups cannot be merged across platforms. This is a Sonos constraint, not an app limitation. Each system has its own queue, its own presets, and its own favorites.")
        }
    }

    private var preferences: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("Preferences")
            paragraph("Open SonosController → Settings… (⌘,) to configure the app.")
            bulletedList([
                "Appearance: system, light, or dark.",
                "Menu bar: enable a compact now-playing menu bar extra for quick control without the main window.",
                "Communication mode: event-driven (default, efficient) or legacy polling (compatibility fallback).",
                "Quick Start: shows cached speakers instantly on launch while live discovery runs in the background.",
                "Music services: toggle Apple Music, TuneIn, Calm Radio, Sonos Radio and other service search sources."
            ])
            heading("Listening stats")
            paragraph("Enable play history in Settings to record tracks played over time. The Listening Stats window (⇧⌘S) shows top tracks, stations, albums, listening streaks, and starred tracks.")
        }
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("Keyboard shortcuts")
            shortcutGroup(title: "Playback", items: [
                ("Play / Pause", "⌘P"),
                ("Play / Pause (Now Playing focus)", "Space"),
                ("Next track", "⌘→"),
                ("Previous track", "⌘←"),
                ("Mute / Unmute", "⌥⌘↓")
            ])
            shortcutGroup(title: "View", items: [
                ("Toggle Browse Library", "⌘B"),
                ("Toggle Play Queue", "⌥⌘U"),
                ("Listening Stats", "⇧⌘S"),
                ("Enter Full Screen", "⌃⌘F")
            ])
            shortcutGroup(title: "App", items: [
                ("Settings", "⌘,"),
                ("Help", "⌘?"),
                ("Hide SonosController", "⌘H"),
                ("Quit SonosController", "⌘Q")
            ])
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("About SonosController")
            paragraph("SonosController is a third-party controller for Sonos speakers. It is not affiliated with or endorsed by Sonos, Inc.")
            paragraph("All control uses local UPnP over your home network. No data leaves your network and no cloud account is required. Music service authentication (when enabled) uses the standard Sonos SMAPI flow.")
            heading("Source code and issues")
            if let url = AppLinks.repositoryURL {
                Link("github.com/scottwaters/SonosController", destination: url)
                    .font(.body)
            }
            heading("License")
            paragraph("Trademarks belong to their respective owners. Sonos is a registered trademark of Sonos, Inc.")
        }
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
                    Text("•").font(.body).foregroundStyle(.secondary)
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
