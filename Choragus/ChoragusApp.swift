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
/// `SUFeedURL`. Without it Sparkle stays inert and the GitHub-API
/// `UpdateChecker` notification path is used. The keys are substituted at
/// release time from `SPARKLE_FEED_URL` / `SPARKLE_PUBLIC_KEY`; forks and
/// ad-hoc dev builds leave them empty.
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
    /// Asks an already-open Settings window to switch tab (object: Int tag).
    static let settingsSelectTab = Notification.Name("settingsSelectTab")
    /// Asks an already-open Help window to show a topic (object: HelpTopic rawValue).
    static let helpSelectTopic = Notification.Name("helpSelectTopic")
    static let menuPlayPause = Notification.Name("menuPlayPause")
    static let menuNextTrack = Notification.Name("menuNextTrack")
    static let menuPreviousTrack = Notification.Name("menuPreviousTrack")
    static let menuToggleMute = Notification.Name("menuToggleMute")
    static let menuToggleBrowse = Notification.Name("menuToggleBrowse")
    static let menuToggleQueue = Notification.Name("menuToggleQueue")
    static let menuShowStats = Notification.Name("menuShowStats")
    static let menuOpenKaraoke = Notification.Name("menuOpenKaraoke")
}

/// Keeps the app running when the main window is closed so it stays available
/// in the menu bar / dock and can be reopened (Window > Open Choragus, ⌘0, or
/// the menu-bar control).
final class ChoragusAppDelegate: NSObject, NSApplicationDelegate {

    /// Set by the app's composition root at first appearance. An explicit
    /// reference rather than `SonosManager.current`, so the shutdown path
    /// does not reach its own state through a process-wide global.
    weak var manager: SonosManager?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// State restoration can resurrect the main window on a Space that isn't
    /// displayed (login relaunch) or on coordinates that no longer exist
    /// (displays swapped identity at boot), while every window-server metric
    /// still reports it "on screen". Rescue it once launch has settled.
    ///
    /// The SwiftUI scene mounts asynchronously and `WindowFrameAutosaver`
    /// applies the saved frame a tick later, so a single fixed delay is
    /// fragile at reboot login. Re-check at 1 s / 3 s / 6 s and stop at the
    /// first attempt that finds the window, so a window the user closes later
    /// is never pulled back.
    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.rescueMainWindowWhenSettled()
    }

    private static let rescueDelays: [TimeInterval] = [1, 2, 3]

    private static func rescueMainWindowWhenSettled(attempt: Int = 0) {
        guard attempt < rescueDelays.count else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + rescueDelays[attempt]) {
            if !ensureMainWindowVisible() {
                rescueMainWindowWhenSettled(attempt: attempt + 1)
            }
        }
    }

    /// Returns true once the main window has been found (whether or not it
    /// needed rescuing) so the retry loop knows to stop. Miniaturized counts
    /// as found: a Dock-minimized restore is a legitimate state, not a ghost.
    @discardableResult
    static func ensureMainWindowVisible() -> Bool {
        guard let window = NSApp.windows.first(where: {
            $0.frameAutosaveName == "ChoragusMainWindow"
        }) else { return false }
        guard !window.isMiniaturized else { return true }

        // Restored frame no longer meaningfully overlaps any attached
        // screen (display arrangement changed since the frame was saved):
        // pull it back to the center of the main screen. "Meaningful"
        // guards against a sliver technically intersecting an edge.
        let visiblyPlaced = NSScreen.screens.contains { screen in
            let overlap = screen.visibleFrame.intersection(window.frame)
            return overlap.width >= 200 && overlap.height >= 100
        }
        if !visiblyPlaced {
            window.center()
        }

        // Never ordered in at all (login-launch restore race): order front
        // on the active Space. `orderFrontRegardless` shows the window
        // without activating the app, so a background login relaunch
        // doesn't steal focus. Collection behavior is restored a tick
        // later — the move happens during ordering.
        //
        // Not gated on `isOnActiveSpace`: a window restored visible on
        // another Space or display is at the user's chosen location. The
        // ghost this rescue exists for (#73) is never ordered in at all, so
        // `isVisible` alone identifies it.
        if !window.isVisible {
            let saved = window.collectionBehavior
            window.collectionBehavior.insert(.moveToActiveSpace)
            window.orderFrontRegardless()
            DispatchQueue.main.async {
                window.collectionBehavior = saved
            }
        }
        return true
    }

    /// Best-effort GENA unsubscribe on quit. Orphaned subscriptions make the
    /// speaker burn a connect-timeout per dead callback before delivering
    /// NOTIFY to live subscribers. Hard kills still orphan, bounded by the
    /// 10-minute lease.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let manager else { return .terminateNow }
        Task { @MainActor in
            await manager.unsubscribeAllForShutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        // Watchdog: never hang quit on a wedged speaker.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}


// MARK: - Service injection

extension View {
    /// Injects `SonosManager` and its extracted collaborators as one unit.
    ///
    /// Every root that hosts Choragus views must apply this. `NSHostingController`
    /// roots and separate `Scene`s inherit nothing from the main window, and a
    /// missing `@Environment(T.self)` for an `@Observable` type is a runtime trap
    /// with no compile-time signal. One modifier means a root cannot be
    /// half-injected and a new collaborator is a one-line change here.
    func choragusServices(_ manager: SonosManager) -> some View {
        environment(manager)
            .environment(manager.topology)
            .environment(manager.volume)
            .environment(manager.library)
            .environment(manager.queue)
            .environment(\.eqService, manager.eq)
    }
}

/// `EQServiceProtocol` reaches views through an `EnvironmentKey` rather than
/// `.environment(object)`: its conformer `RenderingControlService` is not
/// `@Observable`, and EQ is a set of verbs with no observable state.
///
/// The value is optional only because `EnvironmentKey.defaultValue` is
/// non-isolated and `EQServiceProtocol` is `@MainActor`, so a stand-in cannot
/// be constructed here. A missed injection is caught by the
/// `@Environment(TopologyStore.self)` trap in `.choragusServices`, not here.
private struct EQServiceKey: EnvironmentKey {
    static let defaultValue: (any EQServiceProtocol)? = nil
}

extension EnvironmentValues {
    var eqService: (any EQServiceProtocol)? {
        get { self[EQServiceKey.self] }
        set { self[EQServiceKey.self] = newValue }
    }
}

@main
struct ChoragusApp: App {

    @NSApplicationDelegateAdaptor(ChoragusAppDelegate.self) private var appDelegate

    /// Window title. Debug builds append the tag from the custom
    /// `ChoragusBuildTag` Info.plist key so the running build is
    /// identifiable. Builds that don't set `CHORAGUS_BUILD_TAG` leave the
    /// literal `$(CHORAGUS_BUILD_TAG)` placeholder; the `hasPrefix("$(")`
    /// check falls back to plain "Choragus".
    ///
    /// A custom key rather than CFBundleVersion: macOS TCC re-prompts for
    /// Local Network access on every CFBundleVersion change, and the custom
    /// key is invisible to TCC.
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

    @State private var sonosManager = SonosManager()
    @StateObject private var presetManager = PresetManager()
    @StateObject private var playHistoryManager = PlayHistoryManager()
    @StateObject private var playlistScanner = PlaylistServiceScanner()
    @StateObject private var smapiManager = SMAPIAuthManager()
    @StateObject private var plexAuth = PlexAuthManager.shared
    @StateObject private var lastFMScrobbler = LastFMScrobbler()
    /// Defers scrobble-manager construction until playHistoryManager is ready.
    @StateObject private var scrobbleManagerHolder = ScrobbleManagerHolder()
    /// Lyrics + Last.fm metadata services share a single SQLite cache in the
    /// play-history DB file. Injected as MainActor-isolated holders so the
    /// SwiftUI environment can carry non-ObservableObject types.
    @StateObject private var metadataServicesHolder = MetadataServicesHolder()
    @StateObject private var artCoordinatorHolder = ArtCoordinatorHolder()

    /// Sparkle 2 observer. Started only on builds with a non-empty
    /// `SUFeedURL`; dev / fork builds get an inert observer with
    /// `updater == nil` and use the GitHub-API `UpdateChecker` instead.
    /// Holds the `SPUStandardUpdaterController` strongly so its lifetime
    /// tracks the App.
    @StateObject private var sparkleObserver = SparkleUpdaterObserver.makeForApp()

    var body: some Scene {
        Window("Choragus", id: "main") {
            ContentView()
                .background(MainWindowOpenerCapture())
                .choragusServices(sonosManager)
                .environmentObject(sonosManager.positionTracker)
                .environmentObject(sonosManager.anchorTracker)
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
                .environmentObject(artCoordinatorHolder.ensureReady(sonosManager: sonosManager, playHistory: playHistoryManager))
                .environmentObject(sparkleObserver)
                .onAppear {
                    // Expose the live managers to AppIntents (Shortcuts /
                    // Spotlight / Siri) which run outside the SwiftUI
                    // environment and need reachable references.
                    SonosManager.current = sonosManager
                    appDelegate.manager = sonosManager
                    PresetManager.current = presetManager
                    SMAPIAuthManager.current = smapiManager
                    installMCPAppHooks(sonosManager: sonosManager)
                    ChoragusMCPServer.shared.applySettings()
                    // Wire Apple Music catalog as the preferred artwork source;
                    // a nil return falls through to the iTunes Search path.
                    // The closures must capture the provider strongly —
                    // `makeCurrent()` returns a fresh instance that nothing
                    // else retains, so a weak capture is deallocated as soon
                    // as onAppear returns.
                    let amProvider = AppleMusicProviderFactory.makeCurrent()
                    AlbumArtSearchService.appleMusicAlbumArtLookup = { [amProvider] artist, album in
                        guard !album.isEmpty else { return nil }
                        guard let result = await amProvider.lookupAlbum(artist: artist, title: album) else { return nil }
                        return result.artworkURL?.absoluteString
                    }
                    AlbumArtSearchService.appleMusicArtistArtLookup = { [amProvider] artist in
                        guard let result = await amProvider.lookupArtist(name: artist) else { return nil }
                        return result.artworkURL?.absoluteString
                    }
                    AlbumArtSearchService.appleMusicTrackArtLookup = { [amProvider] artist, title in
                        guard let song = await amProvider.lookupSong(title: title, artist: artist) else { return nil }
                        return song.artworkURL?.absoluteString
                    }
                    MusicMetadataService.appleMusicArtistEnrichment = { [amProvider] artist in
                        guard let details = await amProvider.lookupArtist(name: artist) else { return nil }
                        return (details.artworkURL?.absoluteString, details.genreNames)
                    }
                    MusicMetadataService.appleMusicAlbumEnrichment = { [amProvider] artist, album in
                        // Song-level lookup: song details carry genre tags,
                        // standalone album lookup returns only artwork.
                        guard let song = await amProvider.lookupSong(title: album, artist: artist) else { return nil }
                        return (song.artworkURL?.absoluteString, song.genreNames)
                    }
                    // Register defaults before any view reads them.
                    UserDefaults.standard.register(defaults: [
                        // Off by default — surprising on a trackpad.
                        UDKey.scrollVolumeEnabled: false,
                        UDKey.middleClickMuteEnabled: true,
                        // On by default; users hit by stray Bluetooth AVRCP
                        // play commands turn it off.
                        UDKey.mediaKeysEnabled: true,
                        // Sonos position polling lags true playback by ~1–2 s
                        // and most LRCs are tuned to as-sung timing.
                        UDKey.lyricsGlobalOffset: -2.0,
                    ])
                    let diagnosticsPath = AppPaths.appSupportDirectory
                        .appendingPathComponent("diagnostics.sqlite").path
                    DiagnosticsService.shared.attach(repository: DiagnosticsRepository(dbPath: diagnosticsPath))
                    sonosManager.playHistoryManager = playHistoryManager
                    PlexPlaybackReporter.shared.positionProvider = { [weak sonosManager] id in
                        sonosManager?.positionAnchor(coordinatorID: id)
                    }
                    sonosManager.plexPlaybackReporter = PlexPlaybackReporter.shared
                    // SMAPI URI resolver for `x-sonosapi-stream:` URIs from
                    // search / browse: current Sonos firmware only accepts
                    // the resolved direct stream URL on AVTransport for
                    // SMAPI radio.
                    sonosManager.smapiURIResolver = { [weak smapiManager] sid, itemID in
                        try await smapiManager?.resolveMediaURI(serviceID: sid, itemID: itemID)
                    }
                    sonosManager.startDiscovery()
                    #if DEBUG
                    MainThreadHeartbeat.shared.start()
                    #endif
                    MenuBarController.shared.setup(sonosManager: sonosManager)
                    // Media keys (F7/F8/F9) via MPRemoteCommandCenter honour
                    // `UDKey.mediaKeysEnabled`; the volume chord (⌃⌥↑/↓/M)
                    // via local NSEvent monitor is always on.
                    MediaKeyHandler.shared.start(sonosManager: sonosManager)
                    if smapiManager.isEnabled, let speaker = sonosManager.groups.first?.coordinator {
                        Task { await smapiManager.loadServices(speakerIP: speaker.ip, musicServicesList: sonosManager.musicServicesList) }
                    }
                    WindowManager.shared.playHistoryManager = playHistoryManager
                    WindowManager.shared.sonosManager = sonosManager
                    WindowManager.shared.smapiManager = smapiManager
                    WindowManager.shared.lyricsService = metadataServicesHolder
                        .ensureReady(lastfm: lastFMScrobbler, sonosManager: sonosManager)
                        .lyrics
                    WindowManager.shared.lyricsCoordinator = metadataServicesHolder
                        .ensureReady(lastfm: lastFMScrobbler, sonosManager: sonosManager)
                        .lyricsCoordinator
                    WindowManager.shared.metadataServicesHolder = metadataServicesHolder
                        .ensureReady(lastfm: lastFMScrobbler, sonosManager: sonosManager)
                        .metadata
                    WindowManager.shared.artCoordinator = artCoordinatorHolder
                        .ensureReady(sonosManager: sonosManager, playHistory: playHistoryManager)
                    WindowManager.shared.colorScheme = colorScheme
                    // Sparkle handles its own scheduled checks; the GitHub-API
                    // `UpdateChecker` is the notification-only fallback when
                    // Sparkle isn't configured. Sparkle starts after the main
                    // window has mounted so its first-run permission prompt
                    // (modal sheet) doesn't block initial rendering.
                    if sparkleObserver.updater != nil {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            sparkleObserver.startUpdaterAfterMainWindow()
                        }
                    } else {
                        UpdateChecker.shared.checkInBackgroundIfDue()
                    }
                    // Backfill missing/ephemeral artwork for recent history
                    // entries. Throttled and capped; the attempted-key cache
                    // stops re-searching tracks that already failed.
                    Task.detached { @MainActor in
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        await playHistoryManager.backfillMissingArtwork()
                    }
                    // Genre backfill for the Club Vis genre-matched tile
                    // pool, staggered after the artwork backfill so the
                    // network bursts don't pile up.
                    Task.detached { @MainActor in
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        let services = metadataServicesHolder.ensureReady(
                            lastfm: lastFMScrobbler, sonosManager: sonosManager)
                        await playHistoryManager.backfillMissingGenres(
                            using: services.metadata.service)
                    }
                }
                .onChange(of: sonosManager.appearanceMode) {
                    WindowManager.shared.colorScheme = colorScheme
                    Self.applyAppAppearance(sonosManager.appearanceMode)
                }
                .onAppear {
                    Self.applyAppAppearance(sonosManager.appearanceMode)
                }
                // No static minimum here: ContentView enforces a dynamic
                // `minWidth` that tracks browse / queue visibility.
                .navigationTitle(Self.windowTitle)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 900, height: 550)

        // Non-modal Settings scene, wired by SwiftUI to the "Settings…"
        // menu item (⌘,) and `@Environment(\.openSettings)`. Must stay
        // non-modal: a modal main window blocks Sparkle's "Install and
        // Relaunch" alert. Needs the same injections as the main window.
        Settings {
            SettingsView()
                .choragusServices(sonosManager)
                .environmentObject(sonosManager.positionTracker)
                .environmentObject(sonosManager.anchorTracker)
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
                .environmentObject(artCoordinatorHolder.ensureReady(sonosManager: sonosManager, playHistory: playHistoryManager))
                .environmentObject(sparkleObserver)
        }

        .commands {
            // No document model, so hide File > New. Keep the Edit menu
            // intact — replacing those groups breaks ⌘V resolution in
            // Settings credential fields.
            CommandGroup(replacing: .newItem) {}

            // Reopen / focus the main window from the standard Window menu
            // (issue #60).
            CommandGroup(after: .windowList) {
                Button(L10n.openChoragus) {
                    MainWindowHolder.shared.show()
                }
                .keyboardShortcut("0", modifiers: .command)
            }

            // Custom About panel — adds a clickable GitHub link to the credits.
            CommandGroup(replacing: .appInfo) {
                Button(L10n.aboutChoragus) {
                    showAboutPanel()
                }
            }

            // Check for Updates — Sparkle when SUFeedURL is set, otherwise
            // the GitHub-API notification fallback.
            CommandGroup(after: .appInfo) {
                if sparkleObserver.updater != nil {
                    CheckForUpdatesMenuItem(observer: sparkleObserver)
                } else {
                    Button(L10n.checkForUpdates) {
                        UpdateChecker.shared.checkNow()
                    }
                }
            }

            // Help menu — help window plus GitHub links.
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

            // Settings menu item is wired automatically by the `Settings { }`
            // scene above.

            // View — panel toggles, injected into the system View menu via
            // the .sidebar placement. Shortcuts avoid Apple Music / Finder
            // conflicts: ⌘B (Browse), ⌥⌘U (Up Next / queue), ⇧⌘S (Stats).
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

                Button(L10n.queueLibrary) {
                    WindowManager.shared.openQueueLibraryForActiveGroup()
                }
                .keyboardShortcut("l", modifiers: .command)

                Button(L10n.listeningStats) {
                    NotificationCenter.default.post(name: .menuShowStats, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Button(L10n.alarms) {
                    WindowManager.shared.openAlarms()
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            }

            // Top-level Visualisation menu — Karaoke (⌘K) and Back of the
            // Club (⌘J), kept separate from the View menu's panel toggles.
            CommandMenu(L10n.visualisationMenu) {
                Button(L10n.karaoke) {
                    WindowManager.shared.openKaraokeLyricsForActiveGroup()
                }
                .keyboardShortcut("k", modifiers: .command)

                Button(L10n.clubVis) {
                    WindowManager.shared.openClubVisForActiveGroup()
                }
                .keyboardShortcut("j", modifiers: .command)
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

    /// Theme is applied at the AppKit level, not via per-scene
    /// `preferredColorScheme`: with two windows open, a `nil` scheme from
    /// one does not clear the scheme the other still supplies (System
    /// renders as a mixed theme). `NSApp.appearance = nil` reverts every
    /// window atomically; per-window schemes (karaoke) still override.
    static func applyAppAppearance(_ mode: AppearanceMode) {
        switch mode {
        case .system: NSApp.appearance = nil
        case .light:  NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:   NSApp.appearance = NSAppearance(named: .darkAqua)
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

    /// Factory for the App-level `@StateObject`. Returns an inert observer
    /// when `SUFeedURL` is absent / unsubstituted / blank.
    ///
    /// `startingUpdater: false` so Sparkle's modal first-run permission
    /// prompt doesn't fire during App init and block the main window from
    /// rendering. Caller must invoke `startUpdaterAfterMainWindow()`.
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
    /// `.onAppear` so the first-run permission prompt opens against an
    /// already-rendered window.
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
        // Sparkle's first-run permission prompt and external changes to
        // these defaults (`defaults write`, another window) must flow back
        // into the `@Published` mirror or the Settings toggles read stale.
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

extension ChoragusApp {
    /// Windows, lyrics, artist and album metadata and scrobbling live in
    /// the app target; the MCP server calls them back through these
    /// closures so SonosKit stays free of app dependencies.
    @MainActor
    func installMCPAppHooks(sonosManager: SonosManager) {
        let server = ChoragusMCPServer.shared
        server.windowOpener = { window, group in
            let windows = WindowManager.shared
            NSApp.activate(ignoringOtherApps: true)
            switch window {
            case "club_vis":
                if let group { windows.openClubVis(group: group); return true }
                return windows.openClubVisForActiveGroup()
            case "karaoke":
                if let group { windows.openKaraokeLyrics(group: group); return true }
                return windows.openKaraokeLyricsForActiveGroup()
            case "playlist_manager":
                if let group { windows.openQueueLibrary(group: group); return true }
                return windows.openQueueLibraryForActiveGroup()
            case "listening_stats": windows.openPlayHistory(); return true
            case "alarms": windows.openAlarms(); return true
            case "diagnostics": windows.openDiagnostics(); return true
            case "home_theater_eq": windows.openHomeTheaterEQ(); return true
            case "playlist_builder": windows.openPlaylistBuilder(); return true
            case "help": windows.openHelp(); return true
            default: return false
            }
        }
        let services = metadataServicesHolder.ensureReady(lastfm: lastFMScrobbler, sonosManager: sonosManager)
        server.lyricsProvider = { [service = services.lyrics.service] artist, title, album, uri in
            guard let lyrics = await service.fetch(artist: artist, title: title, album: album, trackURI: uri) else { return nil }
            return (lyrics.plainText, lyrics.synced, lyrics.isInstrumental)
        }
        server.artistInfoProvider = { [service = services.metadata.service] name in
            guard let info = await service.artistInfo(name: name) else { return nil }
            var out: [String: Any] = ["artist": info.name, "tags": info.tags, "similar_artists": info.similarArtists]
            if let bio = info.bio { out["biography"] = bio }
            if let listeners = info.listeners { out["listeners"] = listeners }
            if let url = info.wikipediaURL { out["wikipedia"] = url }
            return out
        }
        server.albumInfoProvider = { [service = services.metadata.service] artist, album in
            guard let info = await service.albumInfo(artist: artist, album: album) else { return nil }
            var out: [String: Any] = ["album": info.title, "artist": info.artist, "tags": info.tags,
                                      "tracks": info.tracks.map(\.title)]
            if let released = info.releaseDate { out["released"] = released }
            if let summary = info.summary { out["summary"] = summary }
            return out
        }
        let scrobbler = scrobbleManagerHolder.ensureReady(playHistory: playHistoryManager, lastfm: lastFMScrobbler)
        server.scrobbleStatusProvider = { [scrobbler] in
            ["services": scrobbler.services.map { service in
                let stats = scrobbler.stats(for: service)
                return ["name": service.displayName,
                        "enabled": scrobbler.isServiceEnabled(service),
                        "pending": scrobbler.pendingCount(for: service),
                        "sent": stats.sent, "ignored": stats.ignored, "failed": stats.failed]
            }]
        }
        server.scrobbleSender = { [scrobbler] in await scrobbler.scrobblePending() }
    }
}

/// Lazily constructs the `ScrobbleManager` on first access. Its dependencies
/// (`PlayHistoryManager`, `ScrobbleService` implementations) aren't available
/// during `@StateObject` default construction, only once the view body runs.
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

/// Lazily boots the metadata cache + lyrics + Last.fm-info services. The
/// cache shares the play-history SQLite file so there is one DB to back up.
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
        // Prewarmer hydrates lyrics + about for every track that plays,
        // regardless of panel state or which group is on screen.
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

/// Opens the custom About window. `orderFrontStandardAboutPanel` is fixed
/// at ~280 pt wide, too narrow for the etymology and credits sections.
/// Internal so the Settings → Software Updates pane can open it too.
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

/// SwiftUI rendering of the About content.
private struct ChoragusAboutView: View {
    /// Forces the body to re-evaluate on language change. The AppKit-hosted
    /// window has nothing else observing the UserDefaults key `L10n.*` reads.
    @AppStorage(UDKey.appLanguage) private var appLanguage: String = "en"

    /// Same for theme: no `@EnvironmentObject` link to `SonosManager` here,
    /// so the persistence key is observed directly.
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

            // Wordmark with light/dark luminosity variants, shared with the
            // karaoke header.
            Image("ChoragusTextLogo")
                .resizable()
                .scaledToFit()
                .frame(height: 72)
                .accessibilityLabel("Choragus")

            Text(Self.appVersion)
                .font(.system(.caption, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(.secondary)

            // Serif-italic tagline for the classical Greek brand concept.
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

/// Link row that wraps on width. `HStack` truncates instead of wrapping;
/// `Text` concatenation gives natural line breaks with each token clickable.
private struct FlowingLinkRow: View {
    let links: [(label: String, url: String)]

    var body: some View {
        // Markdown links stay tappable inside a concatenated `Text` when
        // built with `LocalizedStringKey`.
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

/// Captures SwiftUI's `openWindow` action so the menu-bar popover and the
/// Window-menu command can reopen the main `Window` scene after it has been
/// closed (issue #60). `openWindow(id:)` fronts the window if open and
/// rebuilds it if closed; re-showing a closed `NSWindow` brings back a stale
/// SwiftUI view tree.
final class MainWindowHolder {
    static let shared = MainWindowHolder()
    var opener: OpenWindowAction?

    /// Brings the main window forward, rebuilding it if it was closed.
    func show() {
        NSApp.activate(ignoringOtherApps: true)
        opener?(id: "main")
    }
}

/// Captures the `openWindow` environment action from the main scene into
/// `MainWindowHolder`. The action is app-scoped, so it stays valid for reopen
/// even after the window (and this view) are gone.
private struct MainWindowOpenerCapture: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Color.clear.onAppear { MainWindowHolder.shared.opener = openWindow }
    }
}
