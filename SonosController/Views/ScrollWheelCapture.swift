/// ScrollWheelCapture.swift — NSView wrapper that reports scroll-wheel
/// deltas and middle-click events up to a SwiftUI view tree.
///
/// SwiftUI on macOS has no native scroll-wheel API. This file provides a
/// minimal `NSViewRepresentable` wrapper plus a `.volumeScrollControl(…)`
/// modifier. Used by NowPlayingView to drive the group coordinator's
/// volume from the mouse wheel and toggle mute from middle-click.
///
/// The delta-accumulation logic is extracted into `ScrollVolumeAccumulator`
/// so it's unit-testable in isolation from AppKit event objects.
import SwiftUI
import AppKit
import SonosKit

/// NSView-backed capture. Applied as an overlay with selective hit-testing
/// so it intercepts scroll-wheel and middle-click events over its frame
/// while letting all other mouse events (clicks, drags, hovers, right-click)
/// fall through to the SwiftUI content beneath.
///
/// The selective-hit-test trick: during hitTest, AppKit sets
/// `NSApp.currentEvent` to the event being routed. Returning `self` for
/// events we want to capture and `nil` for everything else makes the
/// overlay transparent to normal mouse interaction while still receiving
/// scroll and middle-click.
struct ScrollWheelCapture: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void
    let onMiddleClick: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = CaptureView()
        view.configure(onScroll: onScroll, onMiddleClick: onMiddleClick)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CaptureView)?.configure(onScroll: onScroll, onMiddleClick: onMiddleClick)
    }

    private final class CaptureView: NSView {
        private var onScroll: (CGFloat) -> Void = { _ in }
        private var onMiddleClick: () -> Void = { }

        func configure(onScroll: @escaping (CGFloat) -> Void, onMiddleClick: @escaping () -> Void) {
            self.onScroll = onScroll
            self.onMiddleClick = onMiddleClick
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            // Claim only the two event types we're here to handle. Everything
            // else (clicks, right-clicks, drags, hovers) passes through to
            // SwiftUI content underneath the overlay.
            guard let event = NSApp.currentEvent else { return nil }
            switch event.type {
            case .scrollWheel:
                return self
            case .otherMouseDown, .otherMouseUp where event.buttonNumber == 2:
                return self
            default:
                return nil
            }
        }

        override func scrollWheel(with event: NSEvent) {
            onScroll(event.scrollingDeltaY)
        }

        override func otherMouseDown(with event: NSEvent) {
            // buttonNumber 2 is the scroll-wheel click on a standard mouse.
            if event.buttonNumber == 2 {
                onMiddleClick()
            } else {
                super.otherMouseDown(with: event)
            }
        }
    }
}

extension View {
    /// Captures mouse-wheel scroll and middle-click events over this view's
    /// area, forwarding discrete step counts to `onVolumeStep` and mute
    /// toggles to `onToggleMute`. Foreground controls (buttons, sliders)
    /// continue to work normally because the capture is installed as a
    /// background layer.
    func volumeScrollControl(
        onVolumeStep: @escaping (Int) -> Void,
        onToggleMute: @escaping () -> Void
    ) -> some View {
        modifier(VolumeScrollControlModifier(onVolumeStep: onVolumeStep, onToggleMute: onToggleMute))
    }
}

private struct VolumeScrollControlModifier: ViewModifier {
    let onVolumeStep: (Int) -> Void
    let onToggleMute: () -> Void
    @State private var accumulator = ScrollVolumeAccumulator()

    func body(content: Content) -> some View {
        content.overlay(
            ScrollWheelCapture(
                onScroll: { deltaY in
                    let step = accumulator.consume(deltaY: deltaY)
                    if step != 0 { onVolumeStep(step) }
                },
                onMiddleClick: { onToggleMute() }
            )
        )
    }
}
