/// WindowManager.swift — Opens auxiliary windows via AppKit to avoid SwiftUI Window scene issues.
import SwiftUI
import SonosKit

@MainActor
final class WindowManager {
    static let shared = WindowManager()

    var playHistoryManager: PlayHistoryManager?
    var sonosManager: SonosManager?
    var colorScheme: ColorScheme?

    private var playHistoryWindow: NSWindow?
    private var homeTheaterWindow: NSWindow?
    private var helpWindow: NSWindow?
    private var forFunWindow: NSWindow?

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
        let window = createWindow(title: "Listening Stats", content: view, width: 960, height: 720)
        window.toolbar?.displayMode = .iconAndLabel
        playHistoryWindow = window
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
        let hostingView = NSHostingView(rootView: LanguageReactiveContainer { content })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentView = hostingView
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
