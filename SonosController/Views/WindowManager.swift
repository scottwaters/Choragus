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
        let window = createWindow(title: "SonosController Help", content: view, width: 820, height: 560)
        helpWindow = window
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
        let hostingView = NSHostingView(rootView: content)
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
