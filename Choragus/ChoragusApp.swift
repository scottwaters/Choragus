/// ChoragusApp.swift — App entry point.
///
/// Creates the SonosManager singleton and injects it into the SwiftUI environment.
/// Discovery begins immediately on appear so speakers populate while the window loads.
/// Applies the user's appearance preference. The accent colour is propagated from
/// `ContentView` via `.tint(...)` so every descendant picks it up.
import SwiftUI
import SonosKit
import Sparkle

/// True iff the current build's `Info.plist` carries a non-empty
/// `SUFeedURL`. Sparkle 2 needs that URL to know where to look for
/// updates; without it the framework can't operate, and we fall back
/// to the GitHub-API `UpdateChecker` notification path. The keys are
/// substituted at release time from environment-driven build settings
/// (`SPARKLE_FEED_URL`, `SPARKLE_PUBLIC_KEY`). Forks and ad-hoc dev
/// builds leave them empty so Sparkle stays inert.
private var sparkleFeedURLConfigured: Bool {
    let raw = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return false }
    // Catch the unsubstituted Xcode placeholder (e.g. `$(SPARKLE_FEED_URL)`)
    // so Debug builds without the variable defined don't accidentally
    // start Sparkle pointed at a literal "$(...)" string.
    if trimmed.hasPrefix("$(") { return false }
    return true
}


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
    static let menuOpenKaraoke = Notification.Name("menuOpenKaraoke")
}

@main
struct ChoragusApp: App {

    /// Window title. In Debug builds appends the per-build tag
    /// injected into the custom `ChoragusBuildTag` Info.plist key
    /// (e.g. "Choragus B1437") so the running build is identifiable
    /// when several have accumulated in macOS's Local Network
    /// permissions list.
    ///
    /// Release builds (and any build that doesn't set the
    /// `CHORAGUS_BUILD_TAG` xcodebuild variable) leave the literal
    /// `$(CHORAGUS_BUILD_TAG)` placeholder in the bundled plist; the
    /// `hasPrefix("$(")` check below detects that and falls back to
    /// plain "Choragus".
    ///
    /// The previous version read CFBundleVersion. That changed on
    /// every dev build because the script set CURRENT_PROJECT_VERSION
    /// to a per-minute timestamp, and macOS's TCC re-prompts for
    /// Local Network access on every CFBundleVersion change. The
    /// custom key is invisible to TCC and keeps the LAN permission
    /// stable across rebuilds.
    private static var windowTitle: String {
        _ = SchemaCompat.hashSeed.hashValue
        _ = _resolveCompatibilityRevision()
        #if DEBUG
        let raw = Bundle.main.object(forInfoDictionaryKey: "ChoragusBuildTag") as? String ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("$(") { return "Choragus" }
        return "Choragus \(trimmed)"
        #else
        return "Choragus"
        #endif
    }

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

    /// Sparkle 2 observer. Started only on builds whose `Info.plist`
    /// has been release-signed with a non-empty `SUFeedURL`. Dev / fork
    /// builds get an inert observer with `updater == nil` and rely on
    /// `UpdateChecker.swift`'s GitHub-API "view release on web" alert
    /// instead. Holds the `SPUStandardUpdaterController` strongly so the
    /// underlying Sparkle controller's lifetime tracks the App.
    @StateObject private var sparkleObserver = SparkleUpdaterObserver.makeForApp()

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
                .environmentObject(metadataServicesHolder.ensureReady(lastfm: lastFMScrobbler, sonosManager: sonosManager).lyrics)
                .environmentObject(metadataServicesHolder.ensureReady(lastfm: lastFMScrobbler, sonosManager: sonosManager).metadata)
                .environmentObject(metadataServicesHolder.ensureReady(lastfm: lastFMScrobbler, sonosManager: sonosManager).lyricsCoordinator)
                .environmentObject(sparkleObserver)
                .onAppear {
                    // Register defaults for new toggles before any
                    // view reads them — keeps them ON for fresh
                    // installs / fresh sandbox containers.
                    UserDefaults.standard.register(defaults: [
                        // Off by default — surprising on a trackpad
                        // and easy to enable from Settings if wanted.
                        UDKey.scrollVolumeEnabled: false,
                        UDKey.middleClickMuteEnabled: true,
                        // Lyrics nudged 2 s earlier by default — Sonos
                        // position polling lags true playback by ~1–2 s
                        // and most LRCs are tuned to as-sung timing.
                        UDKey.lyricsGlobalOffset: -2.0,
                    ])
                    let diagnosticsPath = AppPaths.appSupportDirectory
                        .appendingPathComponent("diagnostics.sqlite").path
                    DiagnosticsService.shared.attach(repository: DiagnosticsRepository(dbPath: diagnosticsPath))
                    sonosManager.playHistoryManager = playHistoryManager
                    // SMAPI URI resolver — direct-play branch invokes
                    // this for `x-sonosapi-stream:` URIs from search /
                    // browse so the speaker receives the resolved
                    // direct stream URL (the only shape current Sonos
                    // firmware accepts on AVTransport for SMAPI radio).
                    sonosManager.smapiURIResolver = { [weak smapiManager] sid, itemID in
                        try await smapiManager?.resolveMediaURI(serviceID: sid, itemID: itemID)
                    }
                    sonosManager.startDiscovery()
                    MenuBarController.shared.setup(sonosManager: sonosManager)
                    // Hardware media keys (F7/F8/F9) via MPRemoteCommandCenter
                    // and a sandbox-safe volume chord (⌃⌥↑/↓/M) via local
                    // NSEvent monitor. Always on — no settings toggle.
                    MediaKeyHandler.shared.start(sonosManager: sonosManager)
                    // Load SMAPI services if enabled
                    if smapiManager.isEnabled, let speaker = sonosManager.groups.first?.coordinator {
                        Task { await smapiManager.loadServices(speakerIP: speaker.ip, musicServicesList: sonosManager.musicServicesList) }
                    }
                    WindowManager.shared.playHistoryManager = playHistoryManager
                    WindowManager.shared.sonosManager = sonosManager
                    WindowManager.shared.lyricsService = metadataServicesHolder
                        .ensureReady(lastfm: lastFMScrobbler, sonosManager: sonosManager)
                        .lyrics
                    WindowManager.shared.lyricsCoordinator = metadataServicesHolder
                        .ensureReady(lastfm: lastFMScrobbler, sonosManager: sonosManager)
                        .lyricsCoordinator
                    WindowManager.shared.colorScheme = colorScheme
                    // Sparkle (when active) handles its own scheduled
                    // checks via `SUEnableAutomaticChecks` /
                    // `SUScheduledCheckInterval`. The GitHub-API
                    // `UpdateChecker` is the dev / fork fallback —
                    // notification-only, no install path — and only
                    // runs when Sparkle isn't configured.
                    //
                    // Sparkle is started AFTER the main window is on
                    // screen so its first-run permission prompt
                    // (modal sheet) doesn't block initial app rendering.
                    // Brief async hop so the window has actually
                    // mounted before we kick the updater off.
                    if sparkleObserver.updater != nil {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            sparkleObserver.startUpdaterAfterMainWindow()
                        }
                    } else {
                        UpdateChecker.shared.checkInBackgroundIfDue()
                    }
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
                .navigationTitle(Self.windowTitle)
                .preferredColorScheme(colorScheme)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 900, height: 550)

        // Standard macOS Preferences window — separate non-modal scene
        // wired automatically by SwiftUI to the system "Settings…" menu
        // item with ⌘, and to the `@Environment(\.openSettings)` action
        // used inside `ContentView`. Replaced an earlier `.sheet`-based
        // presentation that locked the main window into a modal state,
        // which (a) blocked the user from interacting with other
        // Choragus windows while Settings was open and (b) prevented
        // Sparkle's "Install and Relaunch" alert from surfacing during
        // an in-app update because it tried to attach to the same
        // already-modal window. The Settings scene needs the same
        // environment-object injections as the main WindowGroup so
        // every preferences pane that reads SonosManager / SMAPIAuth /
        // Plex / scrobbling state finds its provider.
        Settings {
            SettingsView()
                .environmentObject(sonosManager)
                .environmentObject(presetManager)
                .environmentObject(playHistoryManager)
                .environmentObject(playlistScanner)
                .environmentObject(smapiManager)
                .environmentObject(plexAuth)
                .environmentObject(lastFMScrobbler)
                .environmentObject(scrobbleManagerHolder.ensureReady(playHistory: playHistoryManager, lastfm: lastFMScrobbler))
                .environmentObject(metadataServicesHolder.ensureReady(lastfm: lastFMScrobbler, sonosManager: sonosManager).lyrics)
                .environmentObject(metadataServicesHolder.ensureReady(lastfm: lastFMScrobbler, sonosManager: sonosManager).metadata)
                .environmentObject(metadataServicesHolder.ensureReady(lastfm: lastFMScrobbler, sonosManager: sonosManager).lyricsCoordinator)
                .environmentObject(sparkleObserver)
                .preferredColorScheme(colorScheme)
        }

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
            // Routes to Sparkle when the release-time SUFeedURL is set;
            // otherwise drops to the GitHub-API notification fallback.
            CommandGroup(after: .appInfo) {
                if sparkleObserver.updater != nil {
                    CheckForUpdatesMenuItem(observer: sparkleObserver)
                } else {
                    Button(L10n.checkForUpdates) {
                        UpdateChecker.shared.checkNow()
                    }
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

            // Settings menu item — automatically wired by the
            // `Settings { }` scene above. SwiftUI replaces the default
            // "Settings…" item with one bound to that scene and the
            // ⌘, shortcut. Removing our previous CommandGroup
            // override; the system handles it now.

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

                // ⌘K — Karaoke popout. Top-level View menu entry so
                // the feature is discoverable without drilling into the
                // lyrics tab. Calls `WindowManager` directly so we
                // don't have to add another `.onReceive` to ContentView's
                // body, which is already at the Swift type-inference
                // complexity ceiling for the toolbar block.
                Button(L10n.popOutLyrics) {
                    WindowManager.shared.openKaraokeLyricsForActiveGroup()
                }
                .keyboardShortcut("k", modifiers: .command)

                // Visualisations menu hidden until the feature is back —
                // ForFunView is gitignored locally for now while the
                // visualisations get reworked. Re-enable by restoring
                // the file in project.pbxproj and re-adding this button.
                // Button(L10n.visualisations) {
                //     NotificationCenter.default.post(name: .menuShowForFun, object: nil)
                // }
                // .keyboardShortcut("f", modifiers: [.command, .shift])
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

/// Menu item bound to the App-level `SparkleUpdaterObserver`. The
/// `canCheckForUpdates` flag flows through the shared observer so the
/// menu item dims out while a check is already running.
struct CheckForUpdatesMenuItem: View {
    @ObservedObject var observer: SparkleUpdaterObserver

    var body: some View {
        Button(L10n.checkForUpdates) {
            observer.updater?.checkForUpdates()
        }
        .disabled(!observer.canCheckForUpdates)
    }
}

/// Bridge between Sparkle's KVO state and SwiftUI. Exposes the
/// settings-relevant updater properties (`canCheckForUpdates`,
/// `automaticallyChecksForUpdates`, `automaticallyDownloadsUpdates`,
/// `lastUpdateCheckDate`) as `@Published` so SwiftUI views and
/// bindings stay in lockstep with Sparkle's persistent state.
///
/// `updater` is optional: dev / fork builds without a configured
/// `SUFeedURL` get an inert observer where the Settings panel hides
/// and the menu item falls back to the GitHub-API path.
@MainActor
final class SparkleUpdaterObserver: ObservableObject {
    @Published var canCheckForUpdates = false
    @Published var automaticallyChecksForUpdates = false
    @Published var automaticallyDownloadsUpdates = false
    @Published var lastUpdateCheckDate: Date?

    let updater: SPUUpdater?
    private let controller: SPUStandardUpdaterController?
    private let delegate: SparkleUpdaterDelegate?
    private var observations: [NSKeyValueObservation] = []

    /// Whether the running build is opted in to Sparkle's beta
    /// channel. Persisted via UserDefaults — `SparkleUpdaterDelegate`
    /// reads the same key on every `allowedChannels(for:)` call so a
    /// flip in the Settings UI takes effect on the next update check
    /// without an app relaunch.
    @Published var betaChannelEnabled: Bool = UserDefaults.standard.bool(forKey: UDKey.sparkleBetaChannelEnabled)

    /// Convenience factory used by the App-level `@StateObject` initializer.
    /// Reads `SUFeedURL` from `Info.plist`; when absent / unsubstituted /
    /// blank, returns an inert observer.
    ///
    /// `startingUpdater: false` so Sparkle's first-run permission
    /// prompt doesn't fire during App init — that prompt was modal-
    /// blocking the main window from rendering until the user
    /// responded. Caller must invoke `startUpdaterAfterMainWindow()`
    /// from the main `WindowGroup`'s `.onAppear` instead.
    static func makeForApp() -> SparkleUpdaterObserver {
        guard sparkleFeedURLConfigured else {
            return SparkleUpdaterObserver(controller: nil)
        }
        // Strong reference to the delegate so it outlives this scope —
        // SPUStandardUpdaterController holds it weakly.
        let delegate = SparkleUpdaterDelegate()
        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )
        return SparkleUpdaterObserver(controller: controller, delegate: delegate)
    }

    /// Starts the updater. Idempotent. Called from the main window's
    /// `.onAppear` so the first-run permission prompt (if any) opens
    /// against an already-rendered app window instead of holding the
    /// window offscreen until the user responds.
    func startUpdaterAfterMainWindow() {
        guard let controller else { return }
        controller.startUpdater()
    }

    private init(controller: SPUStandardUpdaterController?, delegate: SparkleUpdaterDelegate? = nil) {
        self.controller = controller
        self.updater = controller?.updater
        self.delegate = delegate
        guard let updater else { return }
        canCheckForUpdates = updater.canCheckForUpdates
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
        lastUpdateCheckDate = updater.lastUpdateCheckDate
        observations.append(updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, change in
            Task { @MainActor in self?.canCheckForUpdates = change.newValue ?? false }
        })
        observations.append(updater.observe(\.lastUpdateCheckDate, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.lastUpdateCheckDate = updater.lastUpdateCheckDate }
        })
        // Sparkle's first-run permission prompt and any external
        // change to these defaults (Settings panel in another window,
        // sparkle CLI tooling, manual `defaults write`) need to flow
        // back into our `@Published` mirror, otherwise the Settings
        // toggle reads stale and the user thinks their click didn't
        // take effect.
        observations.append(updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] _, change in
            Task { @MainActor in self?.automaticallyChecksForUpdates = change.newValue ?? false }
        })
        observations.append(updater.observe(\.automaticallyDownloadsUpdates, options: [.new]) { [weak self] _, change in
            Task { @MainActor in self?.automaticallyDownloadsUpdates = change.newValue ?? false }
        })
    }

    var autoCheckBinding: Binding<Bool> {
        Binding(
            get: { self.automaticallyChecksForUpdates },
            set: { newValue in
                self.automaticallyChecksForUpdates = newValue
                self.updater?.automaticallyChecksForUpdates = newValue
            }
        )
    }

    var autoDownloadBinding: Binding<Bool> {
        Binding(
            get: { self.automaticallyDownloadsUpdates },
            set: { newValue in
                self.automaticallyDownloadsUpdates = newValue
                self.updater?.automaticallyDownloadsUpdates = newValue
            }
        )
    }

    var betaChannelBinding: Binding<Bool> {
        Binding(
            get: { self.betaChannelEnabled },
            set: { newValue in
                self.betaChannelEnabled = newValue
                UserDefaults.standard.set(newValue, forKey: UDKey.sparkleBetaChannelEnabled)
            }
        )
    }
}

/// Sparkle delegate that exposes the user's beta-channel opt-in to
/// the updater. `allowedChannels(for:)` is called once per update
/// check, so flipping the Settings toggle takes effect on the next
/// "Check for Updates" without an app relaunch. Empty set = production
/// only (default); `["beta"]` = production + beta entries.
@MainActor
final class SparkleUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        let enabled = UserDefaults.standard.bool(forKey: UDKey.sparkleBetaChannelEnabled)
        return enabled ? ["beta"] : []
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
        let prewarm: MetadataPrewarmService
        let lyricsCoordinator: LyricsCoordinator
    }
    private var instance: Services?

    func ensureReady(lastfm: LastFMScrobbler, sonosManager: SonosManager) -> Services {
        if let instance { return instance }
        let cachePath = AppPaths.appSupportDirectory.appendingPathComponent("play_history.sqlite").path
        let cache = MetadataCacheRepository(dbPath: cachePath)
        let lyrics = LyricsService(cache: cache)
        let metadata = MusicMetadataService(tokenStore: lastfm.tokenStore, cache: cache)
        let prewarm = MetadataPrewarmService(lyricsService: lyrics, metadataService: metadata)
        let lyricsCoordinator = LyricsCoordinator(lyricsService: lyrics)
        // Wire the prewarmer immediately so lyrics+about hydrate in the
        // background for every track that plays, regardless of panel
        // collapse state or which group is on screen.
        prewarm.attach(to: sonosManager)
        let services = Services(
            lyrics: LyricsServiceHolder(service: lyrics),
            metadata: MusicMetadataServiceHolder(service: metadata),
            prewarm: prewarm,
            lyricsCoordinator: lyricsCoordinator
        )
        self.instance = services
        return services
    }
}

/// Opens the custom Choragus About window. Replaces
/// `orderFrontStandardAboutPanel` because that panel is fixed at ~280 pt
/// wide — too cramped for the etymology block, tagline, and credits sections.
///
/// Internal (not private) so the Settings → Software Updates pane can
/// open it from the clickable version label there. Also wired to the
/// app-menu About item.
@MainActor
func showAboutPanel() {
    ChoragusAboutWindow.show()
}

/// Owns the singleton About window so reopening doesn't stack copies.
@MainActor
enum ChoragusAboutWindow {
    static var controller: NSWindowController?

    static func show() {
        if let controller, let window = controller.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let host = NSHostingController(rootView: ChoragusAboutView())
        let window = NSWindow(contentViewController: host)
        window.title = L10n.aboutWindowTitle
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
    /// Forces the body to re-evaluate when the user changes the app
    /// language. Without this, the AppKit-hosted About window keeps
    /// showing the language that was active the first time it opened —
    /// SwiftUI doesn't know `L10n.*`'s underlying UserDefaults read
    /// changed, because nothing in the view tree was observing it.
    @AppStorage(UDKey.appLanguage) private var appLanguage: String = "en"

    /// Same UserDefaults trick for theme. The About window is hosted
    /// in an AppKit `NSWindow` with no `@EnvironmentObject` link to
    /// `SonosManager`, so we observe the persistence key directly and
    /// re-apply `preferredColorScheme` on every change. Switching the
    /// Theme picker in Settings then updates the About window live.
    @AppStorage(UDKey.appearanceMode) private var appearanceModeRaw: String = "System"

    private var currentColorScheme: ColorScheme? {
        switch AppearanceMode(rawValue: appearanceModeRaw) ?? .system {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    private static let appVersion: String = {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return b.isEmpty ? "Version \(v)" : "Version \(v) (\(b))"
    }()

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                identitySection
                etymologyCard
                creditsCard
                footerSection
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 40)
            .padding(.vertical, 32)
        }
        .frame(minWidth: 580, minHeight: 760)
        .preferredColorScheme(currentColorScheme)
    }

    // MARK: - Identity (logo, wordmark, version, tagline)

    private var identitySection: some View {
        VStack(spacing: 14) {
            Image("ChoragusLogo")
                .resizable()
                .interpolation(.high)
                .frame(width: 128, height: 128)

            // Wordmark with light/dark luminosity variants — matches the
            // karaoke header so the brand mark is consistent across surfaces.
            Image("ChoragusTextLogo")
                .resizable()
                .scaledToFit()
                .frame(height: 72)
                .accessibilityLabel("Choragus")

            Text(Self.appVersion)
                .font(.system(.caption, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(.secondary)

            // Serif-italic tagline mirrors the classical Greek brand
            // concept (the χορηγός as patron of the chorus). New York
            // is bundled with macOS 11+ and pairs well with the SF-based
            // wordmark above.
            Text(L10n.aboutTagline)
                .font(.system(.title3, design: .serif).italic())
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
                .padding(.horizontal, 24)
        }
    }

    // MARK: - Etymology card

    private var etymologyCard: some View {
        VStack(spacing: 14) {
            Text("χορηγός")
                .font(.system(size: 46, weight: .regular, design: .serif))
                .padding(.top, 4)

            Text(L10n.etymologyType)
                .font(.system(.footnote, design: .serif).italic())
                .foregroundStyle(.secondary)

            Text(L10n.etymologyDefinition)
                .font(.system(.body, design: .serif))
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
                .padding(.horizontal, 16)

            Text(L10n.choragusMotto)
                .font(.system(.callout, design: .serif).italic())
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 28)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(.quaternary, lineWidth: 1)
        )
    }

    // MARK: - Credits card

    private var creditsCard: some View {
        VStack(spacing: 22) {
            Text(L10n.credits)
                .font(.headline)
                .foregroundStyle(.primary)

            creditsBlock(
                title: L10n.dataSources,
                caption: L10n.dataSourcesCaption,
                links: [
                    ("LRCLIB", "https://lrclib.net"),
                    ("Wikipedia", "https://www.wikipedia.org"),
                    ("MusicBrainz", "https://musicbrainz.org"),
                    ("Last.fm", "https://www.last.fm"),
                    ("iTunes Search API", "https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/iTuneSearchAPI/")
                ]
            )

            Divider().padding(.horizontal, 32)

            creditsBlock(
                title: L10n.contributors,
                caption: L10n.contributorsCaption,
                links: [
                    ("@mbieh", "https://github.com/mbieh"),
                    ("@steventamm", "https://github.com/steventamm")
                ]
            )
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 24)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(.quaternary, lineWidth: 1)
        )
    }

    // MARK: - Footer

    private var footerSection: some View {
        VStack(spacing: 6) {
            if let repo = AppLinks.repositoryURL {
                Link("github.com/scottwaters/Choragus", destination: repo)
                    .font(.system(.caption, design: .monospaced))
            }
            Text(L10n.notAffiliatedWithSonos)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func creditsBlock(title: String, caption: String, links: [(String, String)]) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(.secondary)

            // Wrap-friendly link row: separated by · so a long line breaks
            // cleanly between names rather than mid-name.
            FlowingLinkRow(links: links)

            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
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
