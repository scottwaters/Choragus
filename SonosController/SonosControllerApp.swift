/// SonosControllerApp.swift — App entry point.
///
/// Creates the SonosManager singleton and injects it into the SwiftUI environment.
/// Discovery begins immediately on appear so speakers populate while the window loads.
/// Applies the user's appearance preference. Accent color is applied per-view,
/// not on the whole window, to avoid tinting toolbar icons.
import SwiftUI
import SonosKit


extension Notification.Name {
    static let openSettings = Notification.Name("openSettings")
    static let menuPlayPause = Notification.Name("menuPlayPause")
    static let menuNextTrack = Notification.Name("menuNextTrack")
    static let menuPreviousTrack = Notification.Name("menuPreviousTrack")
    static let menuToggleMute = Notification.Name("menuToggleMute")
    static let menuToggleBrowse = Notification.Name("menuToggleBrowse")
    static let menuToggleQueue = Notification.Name("menuToggleQueue")
    static let menuShowStats = Notification.Name("menuShowStats")
}

@main
struct SonosControllerApp: App {
    @StateObject private var sonosManager = SonosManager()
    @StateObject private var presetManager = PresetManager()
    @StateObject private var playHistoryManager = PlayHistoryManager()
    @StateObject private var playlistScanner = PlaylistServiceScanner()
    @StateObject private var smapiManager = SMAPIAuthManager()
    @StateObject private var lastFMScrobbler = LastFMScrobbler()
    /// Holds scrobble-manager init deferred until playHistoryManager is ready.
    /// Using @StateObject with a lazy init workaround: we build it inside a
    /// container and pass it in.
    @StateObject private var scrobbleManagerHolder = ScrobbleManagerHolder()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(sonosManager)
                .environmentObject(presetManager)
                .environmentObject(playHistoryManager)
                .environmentObject(playlistScanner)
                .environmentObject(smapiManager)
                .environmentObject(lastFMScrobbler)
                .environmentObject(scrobbleManagerHolder.ensureReady(playHistory: playHistoryManager, lastfm: lastFMScrobbler))
                .onAppear {
                    sonosManager.playHistoryManager = playHistoryManager
                    sonosManager.startDiscovery()
                    MenuBarController.shared.setup(sonosManager: sonosManager)
                    // Load SMAPI services if enabled
                    if smapiManager.isEnabled, let speaker = sonosManager.groups.first?.coordinator {
                        Task { await smapiManager.loadServices(speakerIP: speaker.ip, musicServicesList: sonosManager.musicServicesList) }
                    }
                    WindowManager.shared.playHistoryManager = playHistoryManager
                    WindowManager.shared.sonosManager = sonosManager
                    WindowManager.shared.colorScheme = colorScheme
                    // Check GitHub for a newer release at most once per 24h.
                    UpdateChecker.shared.checkInBackgroundIfDue()
                }
                .onChange(of: sonosManager.appearanceMode) {
                    WindowManager.shared.colorScheme = colorScheme
                }
                .frame(minWidth: 640, minHeight: 450)
                .navigationTitle("The SonosController")
                .preferredColorScheme(colorScheme)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 900, height: 550)
        .commands {
            // No document model, so hide File > New. Keep the Edit menu
            // (undo/redo, cut/copy/paste, select-all) intact — Settings has
            // text fields for credentials, and replacing those groups breaks
            // ⌘V keyboard-shortcut resolution even if the menu items aren't
            // used otherwise.
            CommandGroup(replacing: .newItem) {}

            // Custom About panel — adds a clickable GitHub link to the credits.
            CommandGroup(replacing: .appInfo) {
                Button(L10n.aboutSonosController) {
                    showAboutPanel()
                }
            }

            // Check for Updates — sits just below the About item in the app menu.
            CommandGroup(after: .appInfo) {
                Button(L10n.checkForUpdates) {
                    UpdateChecker.shared.checkNow()
                }
            }

            // Help menu — replaces the default to surface real help content and
            // a link to the project's GitHub repository.
            CommandGroup(replacing: .help) {
                Button(L10n.sonosControllerHelp) {
                    WindowManager.shared.openHelp()
                }
                .keyboardShortcut("?", modifiers: .command)

                Divider()

                Button(L10n.viewSourceOnGitHub) {
                    if let url = AppLinks.repositoryURL { NSWorkspace.shared.open(url) }
                }

                Button(L10n.reportAnIssue) {
                    if let url = AppLinks.issuesURL { NSWorkspace.shared.open(url) }
                }
            }

            // Settings — app menu, ⌘,
            CommandGroup(replacing: .appSettings) {
                Button("\(L10n.settings)\u{2026}") {
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            // View — panel toggles. Items are injected into the system-provided
            // View menu (via the .sidebar placement) instead of creating a
            // duplicate top-level "View" menu. Shortcuts chosen to avoid Apple
            // Music/Finder conflicts: ⌘B (Browse), ⌥⌘U (Up Next / queue),
            // ⇧⌘S (Stats).
            CommandGroup(after: .sidebar) {
                Divider()

                Button(L10n.toggleBrowseLibrary) {
                    NotificationCenter.default.post(name: .menuToggleBrowse, object: nil)
                }
                .keyboardShortcut("b", modifiers: .command)

                Button(L10n.togglePlayQueue) {
                    NotificationCenter.default.post(name: .menuToggleQueue, object: nil)
                }
                .keyboardShortcut("u", modifiers: [.command, .option])

                Button(L10n.listeningStats) {
                    NotificationCenter.default.post(name: .menuShowStats, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }

            // Controls — playback. Shortcuts match Apple Music conventions:
            // ⌘→ next, ⌘← previous, ⌥⌘↓ mute. Play/Pause uses Space globally
            // in NowPlayingView; the menu item provides a discoverable equivalent.
            CommandMenu(L10n.controls) {
                Button(L10n.playPause) {
                    NotificationCenter.default.post(name: .menuPlayPause, object: nil)
                }
                .keyboardShortcut("p", modifiers: .command)

                Button(L10n.nextTrack) {
                    NotificationCenter.default.post(name: .menuNextTrack, object: nil)
                }
                .keyboardShortcut(.rightArrow, modifiers: .command)

                Button(L10n.previousTrack) {
                    NotificationCenter.default.post(name: .menuPreviousTrack, object: nil)
                }
                .keyboardShortcut(.leftArrow, modifiers: .command)

                Divider()

                Button(L10n.muteUnmute) {
                    NotificationCenter.default.post(name: .menuToggleMute, object: nil)
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            }
        }
    }

    private var colorScheme: ColorScheme? {
        switch sonosManager.appearanceMode {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Holds the `ScrobbleManager` as an `ObservableObject` that gets lazily
/// initialized with its dependencies on first access. `ScrobbleManager` needs
/// `PlayHistoryManager` (for the repository) and a list of concrete
/// `ScrobbleService` implementations — those aren't available during
/// `@StateObject`'s default-construction phase, so we defer instantiation
/// until the view body runs (where the other managers are already alive).
@MainActor
final class ScrobbleManagerHolder: ObservableObject {
    private var instance: ScrobbleManager?

    func ensureReady(playHistory: PlayHistoryManager, lastfm: LastFMScrobbler) -> ScrobbleManager {
        if let instance { return instance }
        let manager = ScrobbleManager(
            repository: playHistory.repo,
            services: [lastfm]
        )
        self.instance = manager
        return manager
    }
}

/// Opens the macOS standard About panel with custom credits containing a
/// clickable link to the project's GitHub repository. The standard panel
/// auto-populates name, icon, version, and copyright from Info.plist.
@MainActor
private func showAboutPanel() {
    let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    let credits = NSMutableAttributedString(
        string: "\(L10n.aboutTagline)\n\n",
        attributes: [.font: font, .foregroundColor: NSColor.labelColor]
    )
    if let url = AppLinks.repositoryURL {
        credits.append(NSAttributedString(
            string: "github.com/scottwaters/SonosController",
            attributes: [.font: font, .link: url, .foregroundColor: NSColor.linkColor]
        ))
    }
    NSApp.orderFrontStandardAboutPanel(options: [
        .credits: credits,
        .applicationName: "SonosController"
    ])
    NSApp.activate(ignoringOtherApps: true)
}
