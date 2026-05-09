/// WindowManager.swift — Opens auxiliary windows via AppKit to avoid SwiftUI Window scene issues.
import SwiftUI
import SonosKit

@MainActor
final class WindowManager {
    static let shared = WindowManager()

    var playHistoryManager: PlayHistoryManager?
    var sonosManager: SonosManager?
    var lyricsService: LyricsServiceHolder?
    var lyricsCoordinator: LyricsCoordinator?
    var metadataServicesHolder: MusicMetadataServiceHolder?
    var colorScheme: ColorScheme?

    private var playHistoryWindow: NSWindow?
    private var homeTheaterWindow: NSWindow?
    private var helpWindow: NSWindow?
    private var forFunWindow: NSWindow?
    private var karaokeLyricsWindow: NSWindow?
    private var diagnosticsWindow: NSWindow?
    private var clubVisWindow: NSWindow?
    private var clubVisDebugWindow: NSWindow?

    func openPlayHistory() {
        if let existing = playHistoryWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        showPlayHistoryWindow()
    }

    func togglePlayHistory() {
        if let existing = playHistoryWindow, existing.isVisible {
            existing.close()
            return
        }
        showPlayHistoryWindow()
    }

    private func showPlayHistoryWindow() {
        guard let manager = playHistoryManager else { return }
        let view = PlayHistoryView()
            .environmentObject(manager)
            .preferredColorScheme(colorScheme)
        // Default to 1440 × 810 (16:9, 75 % of 1080p) — same as the
        // karaoke window so the stats and karaoke popouts share a
        // consistent default footprint.
        let window = createWindow(title: "Listening Stats", content: view, width: 1440, height: 810)
        window.toolbar?.displayMode = .iconAndLabel
        // Persist frame across launches. AppKit auto-saves the window's
        // origin + size whenever the user drags or resizes, and applies
        // the saved frame on the next open — overriding the default
        // contentRect above. Subsequent launches keep the user's
        // preferred shape; first-ever launch uses 1440 × 810.
        window.setFrameAutosaveName("ChoragusListeningStatsWindow")
        // The hosting controller's intrinsic content size can override
        // contentRect on first launch — force the default frame here so
        // it always materialises at 1440 × 810 the very first time.
        if window.frameAutosaveName.isEmpty || NSRectFromString(UserDefaults.standard.string(forKey: "NSWindow Frame ChoragusListeningStatsWindow") ?? "") == .zero {
            let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
            window.setFrame(NSRect(x: screen.midX - 720, y: screen.midY - 405, width: 1440, height: 810), display: true)
        }
        playHistoryWindow = window
    }

    func openDiagnostics() {
        if let existing = diagnosticsWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        guard let manager = sonosManager else { return }
        // Create the LiveEventLog at window-open time so it starts
        // capturing UPnP events the instant the window appears, even
        // while the user is on the Log tab. SwiftUI's `@StateObject`
        // inside the LiveEventsView would only construct the log when
        // that tab becomes the active branch — events fired during a
        // Log-tab session would be lost.
        let liveLog = LiveEventLog(sonosManager: manager)
        let view = DiagnosticsView()
            .environmentObject(manager)
            .environmentObject(liveLog)
            .preferredColorScheme(colorScheme)
        let window = createWindow(title: "Choragus Diagnostics", content: view, width: 900, height: 560)
        diagnosticsWindow = window
    }

    func openHelp() {
        if let existing = helpWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let view = HelpView().preferredColorScheme(colorScheme)
        let window = createWindow(title: "Choragus Help", content: view, width: 820, height: 560)
        helpWindow = window
    }

    /// Visualisations window is offline while `ForFunView.swift` is
    /// gitignored for rework. The unused `forFunWindow` ivar above and
    /// the menu observer in `ContentView` are kept dormant so wiring
    /// it back on is a one-line restoration.
    func openForFun() { /* feature paused */ }

    /// Club Vis popout — tiled poster wall for the active group.
    /// Opens at 1920×1080 logical (16:9 locked) and fullscreens cleanly
    /// to native 4K. See `ClubVisWindow.swift` for the layout pipeline.
    @discardableResult
    func openClubVisForActiveGroup() -> Bool {
        guard let manager = sonosManager else { return false }
        let lastID = UserDefaults.standard.string(forKey: UDKey.lastSelectedGroupID)
        let group = manager.groups.first(where: { $0.id == lastID })
            ?? manager.groups.first
        guard let group else { return false }
        openClubVis(group: group)
        return true
    }

    private static let clubVisWindowIdentifier = NSUserInterfaceItemIdentifier("ChoragusClubVis")

    func openClubVis(group: SonosGroup) {
        sonosDebugLog("[CLUBVIS-OPEN] enter group=\(group.name) clubVisIvarSet=\(clubVisWindow != nil) appWindowsWithID=\(NSApp.windows.filter { $0.identifier == Self.clubVisWindowIdentifier }.count)")

        // Reuse the tracked window only when it is genuinely usable
        // from the user's current context: visible, on the active
        // Space, and not minimised. ClubVis is `.fullScreenPrimary`
        // so a user who fullscreened it then changed Spaces (or
        // exited fullscreen via ⌘W, which doesn't fire willClose)
        // leaves a window that AppKit still considers `isVisible`
        // but is on a Space the user isn't on — `makeKeyAndOrderFront`
        // alone doesn't pull them back. Diagnosed via `[CLUBVIS-OPEN]
        // reuse existing visible=true` repeating across rapid retries
        // with no `willClose fired` event ever logging.
        if let existing = clubVisWindow,
           existing.isVisible,
           existing.isOnActiveSpace,
           !existing.isMiniaturized {
            sonosDebugLog("[CLUBVIS-OPEN] refocus existing")
            existing.makeKeyAndOrderFront(nil)
            return
        }

        // Reuse not viable — tear down anything we know about plus
        // every orphan window with our identifier. Releasing the
        // autosave name first lets the new window claim it; without
        // this AppKit refuses re-registration while the stale window
        // still holds the slot (isReleasedWhenClosed == false keeps
        // it alive in NSApp.windows).
        if let stale = clubVisWindow {
            sonosDebugLog("[CLUBVIS-OPEN] discarding stale tracked visible=\(stale.isVisible) onActiveSpace=\(stale.isOnActiveSpace) miniaturised=\(stale.isMiniaturized)")
            stale.setFrameAutosaveName("")
            stale.contentViewController = nil
            stale.close()
            clubVisWindow = nil
        }
        for win in NSApp.windows
        where win.identifier == Self.clubVisWindowIdentifier {
            sonosDebugLog("[CLUBVIS-OPEN] closing orphan visible=\(win.isVisible)")
            win.setFrameAutosaveName("")
            win.contentViewController = nil
            win.close()
        }

        guard let manager = sonosManager,
              let history = playHistoryManager,
              let metadata = metadataServicesHolder else {
            sonosDebugLog("[CLUBVIS-OPEN] BAIL — sonos=\(sonosManager != nil) history=\(playHistoryManager != nil) metadata=\(metadataServicesHolder != nil)")
            return
        }

        let view = ClubVisWindow(groupID: group.coordinatorID)
            .environmentObject(manager)
            .environmentObject(history)
            .environmentObject(metadata)
            .environmentObject(manager.artCache)

        let title = group.name.isEmpty
            ? L10n.clubVisWindowTitle
            : L10n.clubVisWindowTitleFormat(group.name)

        // Default to 1920×1080 logical canvas. The aspect ratio is
        // locked to 16:9 below so the ClubVisWindow's GeometryReader
        // scaler always receives a width/height that match its
        // logical canvas, and fullscreen on a 4K display tiles
        // edge-to-edge.
        let window = createWindow(title: title, content: view, width: 1920, height: 1080)
        window.identifier = Self.clubVisWindowIdentifier
        window.contentAspectRatio = NSSize(width: 16, height: 9)
        window.contentMinSize = NSSize(width: 1280, height: 720)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.setFrameAutosaveName("ChoragusClubVisWindow")

        // Materialise the window at the intended default the first
        // time it opens — `NSHostingController` would otherwise size
        // it to the SwiftUI view's intrinsic size. Subsequent opens
        // honour the user's persisted frame via `setFrameAutosaveName`.
        let saved = UserDefaults.standard.string(forKey: "NSWindow Frame ChoragusClubVisWindow") ?? ""
        if saved.isEmpty {
            let screen = NSScreen.main?.visibleFrame
                ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
            // Open at 1280×720 if the screen is too small for native
            // 1920×1080 — otherwise the window falls off the visible
            // area on a 13" laptop.
            let openWidth: CGFloat = min(1920, screen.width - 80)
            let openHeight: CGFloat = openWidth * 9.0 / 16.0
            let originX = screen.midX - openWidth / 2
            let originY = screen.midY - openHeight / 2
            window.setFrame(NSRect(x: originX, y: originY,
                                   width: openWidth, height: openHeight),
                            display: true)
        }

        clubVisWindow = window
        sonosDebugLog("[CLUBVIS-OPEN] window created visible=\(window.isVisible) frame=\(window.frame)")

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            sonosDebugLog("[CLUBVIS-CLOSE] willClose fired isCurrentIvar=\(self?.clubVisWindow === window)")
            if self?.clubVisWindow === window {
                self?.clubVisWindow = nil
            }
            // `isReleasedWhenClosed = false` keeps the NSWindow + its
            // NSHostingController alive after close, which means the
            // SwiftUI view tree (ClubVisWindow + ClubVisWallView) is
            // never released — `.onDisappear` doesn't fire, swap loops
            // and observers keep running, and every subsequent open
            // adds another set. Drop the contentViewController to
            // release the SwiftUI tree synchronously on close.
            window?.contentViewController = nil
        }
        // The Back-of-the-Club debug companion window is no longer
        // auto-opened. It remains in the codebase but isn't called
        // from the production open path; it can be re-enabled by a
        // local developer for debugging by uncommenting an
        // `openClubVisDebugCompanion()` call here.
    }

    #if DEBUG
    private static let clubVisDebugWindowIdentifier = NSUserInterfaceItemIdentifier("ChoragusClubVisDebug")

    /// Auto-opens the Back of the Club debug companion window in
    /// DEBUG builds whenever the main Club Vis window opens. The
    /// companion window subscribes to `BackOfTheClubDebugState.shared`
    /// which the main view + wall view publish into on every rebuild
    /// and slot assignment.
    private func openClubVisDebugCompanion() {
        if let existing = clubVisDebugWindow {
            if existing.isVisible {
                existing.makeKeyAndOrderFront(nil)
                return
            }
            existing.close()
            clubVisDebugWindow = nil
        }
        let view = BackOfTheClubDebugWindow()
        let window = createWindow(title: "Back of the Club — Debug",
                                  content: view,
                                  width: 760,
                                  height: 720)
        window.identifier = Self.clubVisDebugWindowIdentifier
        // Position the debug window to the right of the main Club Vis
        // window so they don't overlap. Falls back to screen edge if
        // there's no room.
        if let main = clubVisWindow {
            let mainFrame = main.frame
            let screen = main.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
            var x = mainFrame.maxX + 16
            if x + 760 > screen.maxX { x = max(screen.minX, screen.maxX - 760) }
            window.setFrame(NSRect(x: x, y: mainFrame.maxY - 720,
                                   width: 760, height: 720),
                            display: true)
        }
        clubVisDebugWindow = window

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            if self?.clubVisDebugWindow === window {
                self?.clubVisDebugWindow = nil
            }
        }
    }
    #endif

    /// Stable identifier stamped onto every karaoke window so we can
    /// find orphans in `NSApp.windows` even after our ivar reference
    /// has been lost.
    private static let karaokeWindowIdentifier = NSUserInterfaceItemIdentifier("ChoragusKaraokeLyrics")

    /// Opens (or focuses) the karaoke-style lyrics popout for the given
    /// group. The window stays locked to that group for its lifetime —
    /// reopen from a different now-playing context to follow a different
    /// group.
    ///
    /// Defensive lifecycle:
    /// - Sweeps `NSApp.windows` for any karaoke window with a stale
    ///   identifier and closes it. Handles the case where the previous
    ///   window's hosting state went bad (rendered but unresponsive)
    ///   and our `karaokeLyricsWindow` ivar lost track of it.
    /// - Subscribes to `willCloseNotification` on the new window so the
    ///   ivar nils itself when the user closes — keeps `isVisible`
    ///   checks honest on subsequent reopens.
    /// Convenience entry point used by the View menu's ⌘K command and
    /// the toolbar shortcut — resolves the currently-selected group
    /// from `UDKey.lastSelectedGroupID` (kept in sync by `ContentView`)
    /// and falls back to the first available group. Returns `false`
    /// when there's nothing to open against (no speakers discovered),
    /// so callers can surface that state if needed.
    @discardableResult
    func openKaraokeLyricsForActiveGroup() -> Bool {
        guard let manager = sonosManager else { return false }
        let lastID = UserDefaults.standard.string(forKey: UDKey.lastSelectedGroupID)
        let group = manager.groups.first(where: { $0.id == lastID })
            ?? manager.groups.first
        guard let group else { return false }
        openKaraokeLyrics(group: group)
        return true
    }

    func openKaraokeLyrics(group: SonosGroup) {
        // First, prune any orphaned karaoke windows we've lost track
        // of. Without this, a locked-up window from a previous open
        // stays on screen with no way to close it, while a fresh open
        // creates a sibling beside it.
        for win in NSApp.windows
        where win.identifier == Self.karaokeWindowIdentifier
            && win !== karaokeLyricsWindow {
            win.close()
        }

        // If our ivar points to a still-good window, re-focus it.
        // Otherwise discard the stale reference.
        if let existing = karaokeLyricsWindow {
            if existing.isVisible {
                existing.makeKeyAndOrderFront(nil)
                return
            }
            existing.close()
            karaokeLyricsWindow = nil
        }

        guard let manager = sonosManager,
              let coordinator = lyricsCoordinator else { return }
        let view = LyricsKaraokeWindow(groupID: group.coordinatorID)
            .environmentObject(manager)
            .environmentObject(coordinator)
            .environmentObject(manager.artCache)
        // Note: no static `.preferredColorScheme(colorScheme)` here.
        // `LyricsKaraokeWindow.body` applies its own dynamic override
        // bound to `sonosManager.appearanceMode`, so the karaoke
        // window tracks Settings → Display changes live. Wrapping
        // the view in a static snapshot here would freeze the
        // override at window-open time and outrank the dynamic one.
        let title = group.name.isEmpty
            ? L10n.karaokeWindowTitle
            : L10n.karaokeWindowTitleFormat(group.name)
        // Default to 16:9 at 75 % of 1080p (1440 × 810) so AirPlaying
        // the window to a TV gives a native-aspect karaoke screen with
        // no letterbox/pillarbox.
        let window = createWindow(title: title, content: view, width: 1440, height: 810)
        window.identifier = Self.karaokeWindowIdentifier

        // Lock the resize handle to the same 16:9 aspect so the user
        // can't drag the window into a shape that would letterbox on
        // a TV. `contentAspectRatio` (vs `contentMinSize` alone)
        // forces AppKit to constrain BOTH dimensions during a drag.
        window.contentAspectRatio = NSSize(width: 16, height: 9)
        // Floor the size at 16:9 / 960 × 540 so the header + toolbar
        // can never be clipped on a small drag.
        window.contentMinSize = NSSize(width: 960, height: 540)
        // Force the frame to the intended default — `NSHostingController`
        // (used by `createWindow`) overrides `contentRect` with the
        // SwiftUI view's intrinsic size unless we set the frame after
        // it's been wired up.
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let originX = screenFrame.midX - 720
        let originY = screenFrame.midY - 405
        window.setFrame(NSRect(x: originX, y: originY, width: 1440, height: 810), display: true)
        karaokeLyricsWindow = window

        // Clear the ivar when this window closes so a future open
        // creates fresh instead of resurrecting a half-torn-down host.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            if self?.karaokeLyricsWindow === window {
                self?.karaokeLyricsWindow = nil
            }
        }
    }

    func openHomeTheaterEQ() {
        if let existing = homeTheaterWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        guard let manager = sonosManager else { return }
        let view = HomeTheaterEQView()
            .environmentObject(manager)
            .preferredColorScheme(colorScheme)
        let window = createWindow(title: "Home Theater EQ", content: view, width: 480, height: 420)
        homeTheaterWindow = window
    }

    private func createWindow<Content: View>(title: String, content: Content, width: CGFloat, height: CGFloat) -> NSWindow {
        // Wrap in `LanguageReactiveContainer` so the AppKit-hosted root
        // re-renders when the user flips `UDKey.appLanguage` in
        // Settings — otherwise `L10n.*` reads the new value but SwiftUI
        // has no signal to invalidate the body, and the window stays
        // stuck on whatever language was active when it first opened.
        //
        // Use `NSHostingController` rather than a bare `NSHostingView`
        // because the controller wires the SwiftUI hosting layer into
        // the window's view-controller hierarchy and display-link
        // pipeline. With a bare `NSHostingView`, `TimelineView(.animation)`
        // doesn't receive proper vsync ticks in a popout window — the
        // karaoke lyrics scroll at a degraded, irregular cadence even
        // though the render itself is trivial.
        let controller = NSHostingController(rootView: LanguageReactiveContainer { content })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentViewController = controller
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false
        return window
    }
}

/// Re-renders its content whenever `UDKey.appLanguage` flips, so any
/// `L10n.*` call inside picks up the new translation. Used by every
/// AppKit-hosted SwiftUI window in the app — the SwiftUI scene root
/// already observes UserDefaults via its environment, but `NSHostingView`
/// roots don't, so without this wrapper the window stays on the
/// language that was active when it was first opened.
private struct LanguageReactiveContainer<Content: View>: View {
    @AppStorage(UDKey.appLanguage) private var appLanguage: String = "en"
    @ViewBuilder let content: () -> Content
    var body: some View { content() }
}

/// Forces SwiftUI to discard any cached subview state when the user
/// flips `UDKey.appLanguage`. Most views just re-render and pick up
/// fresh `L10n.*` reads, but a few SwiftUI controls — especially
/// segmented `Picker`s — cache their label text from the first
/// render and ignore subsequent text changes. Applying
/// `.languageReactive()` ties the view's identity to the language
/// code, so changing language triggers a full rebuild.
extension View {
    func languageReactive() -> some View {
        modifier(LanguageReactiveModifier())
    }
}

private struct LanguageReactiveModifier: ViewModifier {
    @AppStorage(UDKey.appLanguage) private var appLanguage: String = "en"
    func body(content: Content) -> some View {
        content.id(appLanguage)
    }
}
