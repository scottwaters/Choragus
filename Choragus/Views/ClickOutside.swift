/// ClickOutside.swift — Runs an action when the mouse goes down anywhere
/// in the window outside the modified view. Used to clear a list's
/// selection when the user clicks elsewhere, the way AppKit tables do.
import SwiftUI
import AppKit

private struct ClickOutsideAnchor: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.action = action
        return view
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        nsView.action = action
    }

    final class AnchorView: NSView {
        var action: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let inside = self.convert(self.bounds, to: nil).contains(event.locationInWindow)
                if !inside { self.action?() }
                return event
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

extension View {
    /// Calls `action` on any mouse-down in the same window that lands
    /// outside this view.
    func onClickOutside(_ action: @escaping () -> Void) -> some View {
        background(ClickOutsideAnchor(action: action))
    }
}
