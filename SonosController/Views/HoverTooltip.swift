/// HoverTooltip.swift — Stable tooltip that survives SwiftUI re-renders.
/// Uses a persistent NSView with toolTip. The Coordinator pattern ensures
/// the NSView is created once and only updated (not replaced) on re-render,
/// so Sonos event-driven body re-evaluations don't reset the tooltip state.
import SwiftUI
import AppKit

private struct TooltipOverlay: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.toolTip = text
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Only update if text actually changed — avoids resetting tooltip state
        if nsView.toolTip != text {
            nsView.toolTip = text
        }
    }
}

extension View {
    func tooltip(_ text: String) -> some View {
        self.background(TooltipOverlay(text: text))
    }
}
