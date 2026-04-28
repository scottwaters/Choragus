/// ChoragusApp.swift — App entry point.
///
/// Creates the SonosManager singleton and injects it into the SwiftUI environment.
/// Discovery begins immediately on appear so speakers populate while the window loads.
/// Applies the user's appearance preference. The accent colour is propagated from
/// `ContentView` via `.tint(...)` so every descendant picks it up.
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
    static let menuShowForFun = Notification.Name("menuShowForFun")
}

@main
struct ChoragusApp: App {
    @StateObject private var sonosManager = SonosManager()
    @StateObject private var presetManager = PresetManager()
    @StateObject private var playHistoryManager = PlayHistoryManager()
    @StateObject private var playlistScanner = PlaylistServiceScanner()
    @StateObject private var smapiManager = SMAPIAuthManager()
    @StateObject private var plexAuth = PlexAuthManager.shared
    @StateObject private var lastFMScrobbler = LastFMScrobbler()
    /// Holds scrobble-manager init deferred until playHistoryManager is ready.
    /// Using @StateObject with a lazy init workaround: we build it inside a
    /// container and pass it in.
    @StateObject private var scrobbleManagerHolder = ScrobbleManagerHolder()
    /// Lyrics + Last.fm metadata services share a single SQLite cache
    /// in the same DB file as play history. Built once, injected as
    /// MainActor-isolated holders so the SwiftUI environment can carry
    /// non-ObservableObject types without ceremony.
    @StateObject private var metadataServicesHolder = MetadataServicesHolder()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(sonosManager)
                .environmentObject(presetManager)
                .environmentObject(playHistoryManager)
                .environmentObject(playlistScanner)
                .environmentObject(smapiManager)
                .environmentObject(plexAuth)
                .environmentObject(lastFMScrobbler)
                .environmentObject(scrobbleManagerHolder.ensureReady(playHistory: playHistoryManager, lastfm: lastFMScrobbler))
                .environmentObject(metadataServicesHolder.ensureReady(lastfm: lastFMScrobbler).lyrics)
                .environmentObject(metadataServicesHolder.ensureReady(lastfm: lastFMScrobbler).metadata)
                .onAppear {
                    // Register defaults for new toggles before any
                    // view reads them — keeps them ON for fresh
                    // installs / fresh sandbox containers.
                    UserDefaults.standard.register(defaults: [
                        // Off by default — surprising on a trackpad
                        // and easy to enable from Settings if wanted.
                        UDKey.scrollVolumeEnabled: false,
                        UDKey.middleClickMuteEnabled: true,
                    ])
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
                    // Backfill missing/ephemeral artwork from iTunes for
                    // recent history entries. Throttled and capped, so
                    // running it on every launch is cheap; the
                    // attempted-key cache stops it re-searching tracks
                    // that already failed.
                    Task.detached { @MainActor in
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        await playHistoryManager.backfillMissingArtwork()
                    }
                }
                .onChange(of: sonosManager.appearanceMode) {
                    WindowManager.shared.colorScheme = colorScheme
                }
                // Per-panel minimum widths are enforced from inside
                // ContentView (`.frame(minWidth: requiredMinWidth, …)`)
                // so the window floor tracks browse / queue visibility.
                // Setting a static minimum here would lock the floor at
                // that value and override the dynamic one.
                .navigationTitle("Choragus")
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
                Button(L10n.aboutChoragus) {
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
                Button(L10n.choragusHelp) {
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

                Button("Visualisations\u{2026}") {
                    NotificationCenter.default.post(name: .menuShowForFun, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
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

/// Boots the metadata cache + lyrics + Last.fm-info services lazily.
/// Cache lives in the same SQLite file as play history so users only
/// have one DB to back up / clear. Both downstream services share
/// the cache instance.
@MainActor
final class MetadataServicesHolder: ObservableObject {
    struct Services {
        let lyrics: LyricsServiceHolder
        let metadata: MusicMetadataServiceHolder
    }
    private var instance: Services?

    func ensureReady(lastfm: LastFMScrobbler) -> Services {
        if let instance { return instance }
        let cachePath = AppPaths.appSupportDirectory.appendingPathComponent("play_history.sqlite").path
        let cache = MetadataCacheRepository(dbPath: cachePath)
        let lyrics = LyricsService(cache: cache)
        let metadata = MusicMetadataService(tokenStore: lastfm.tokenStore, cache: cache)
        let services = Services(
            lyrics: LyricsServiceHolder(service: lyrics),
            metadata: MusicMetadataServiceHolder(service: metadata)
        )
        self.instance = services
        return services
    }
}

/// Opens the custom Choragus About window. Replaces
/// `orderFrontStandardAboutPanel` because that panel is fixed at ~280 pt
/// wide — too cramped for the etymology block, tagline, and credits sections.
@MainActor
private func showAboutPanel() {
    ChoragusAboutWindow.show()
}

/// Owns the singleton About window so reopening doesn't stack copies.
@MainActor
private enum ChoragusAboutWindow {
    static var controller: NSWindowController?

    static func show() {
        if let controller, let window = controller.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let host = NSHostingController(rootView: ChoragusAboutView())
        let window = NSWindow(contentViewController: host)
        window.title = "About Choragus"
        window.styleMask = [.titled, .closable]
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 540, height: 720))
        window.center()
        let wc = NSWindowController(window: window)
        controller = wc
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// SwiftUI rendering of the About content. Sized for breathing room: the
/// Greek glyph isn't fighting the etymology, the credits sections aren't
/// crammed into a 280 pt column, and links wrap naturally.
private struct ChoragusAboutView: View {
    private static let appVersion: String = {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return b.isEmpty ? "Version \(v)" : "Version \(v) (\(b))"
    }()

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                // Identity
                Image("ChoragusLogo")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 128, height: 128)
                    .padding(.top, 12)

                VStack(spacing: 4) {
                    Text("Choragus")
                        .font(.system(size: 28, weight: .semibold))
                    Text(Self.appVersion)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Text(L10n.aboutTagline)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().padding(.horizontal, 40)

                // Etymology
                VStack(spacing: 6) {
                    Text("χορηγός")
                        .font(.system(size: 30, weight: .semibold))
                    Text("choragus · n. (Ancient Greek)")
                        .font(.callout)
                        .italic()
                        .foregroundStyle(.secondary)
                    Text("The leader of the chorus — the citizen who funded and conducted the dramatic chorus in classical Athens.")
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                        .padding(.horizontal, 24)
                    Text("One conductor. Many voices. One chorus.")
                        .font(.callout)
                        .italic()
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }

                Divider().padding(.horizontal, 40)

                // Credits
                VStack(spacing: 16) {
                    Text("Credits").font(.headline)

                    creditsBlock(
                        title: "Data sources",
                        caption: "Synced lyrics, artist & album metadata, and album art.",
                        links: [
                            ("LRCLIB", "https://lrclib.net"),
                            ("Wikipedia", "https://www.wikipedia.org"),
                            ("MusicBrainz", "https://musicbrainz.org"),
                            ("Last.fm", "https://www.last.fm"),
                            ("iTunes Search API", "https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/iTuneSearchAPI/")
                        ]
                    )

                    creditsBlock(
                        title: "Contributors",
                        caption: "VLAN / Bonjour discovery design and initial implementation (v4.0).",
                        links: [
                            ("@mbieh", "https://github.com/mbieh"),
                            ("@steventamm", "https://github.com/steventamm")
                        ]
                    )
                }
                .padding(.horizontal, 24)

                Divider().padding(.horizontal, 40)

                // Footer
                VStack(spacing: 6) {
                    if let repo = AppLinks.repositoryURL {
                        Link("github.com/scottwaters/Choragus", destination: repo)
                            .font(.callout)
                    }
                    Text("Not affiliated with Sonos, Inc.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
        }
        .frame(minWidth: 540, minHeight: 720)
    }

    @ViewBuilder
    private func creditsBlock(title: String, caption: String, links: [(String, String)]) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            // Wrap-friendly link row: separated by · so a long line breaks
            // cleanly between names rather than mid-name.
            FlowingLinkRow(links: links)

            Text(caption)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Horizontally arranged links that wrap to a new line when the row is
/// narrower than the combined link widths. SwiftUI's `HStack` truncates
/// instead of wrapping; building this with `Text` concatenation gives us
/// natural line breaks while keeping each token clickable.
private struct FlowingLinkRow: View {
    let links: [(label: String, url: String)]

    var body: some View {
        // `Text` concatenation supports inline tappable links via Markdown
        // when the string is built with `LocalizedStringKey`. We assemble
        // a single Text so it wraps naturally on width.
        var combined = Text("")
        for (i, link) in links.enumerated() {
            if i > 0 {
                combined = combined + Text("  ·  ").foregroundStyle(.tertiary)
            }
            let md = "[\(link.label)](\(link.url))"
            combined = combined + Text(.init(md))
        }
        return combined
            .font(.callout)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }
}
