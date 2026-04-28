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
    let captureScroll: Bool
    let captureMiddleClick: Bool
    let onScroll: (CGFloat) -> Void
    let onMiddleClick: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = CaptureView()
        view.configure(captureScroll: captureScroll,
                       captureMiddleClick: captureMiddleClick,
                       onScroll: onScroll, onMiddleClick: onMiddleClick)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CaptureView)?.configure(captureScroll: captureScroll,
                                            captureMiddleClick: captureMiddleClick,
                                            onScroll: onScroll, onMiddleClick: onMiddleClick)
    }

    private final class CaptureView: NSView {
        private var captureScroll: Bool = false
        private var captureMiddleClick: Bool = false
        private var onScroll: (CGFloat) -> Void = { _ in }
        private var onMiddleClick: () -> Void = { }

        func configure(captureScroll: Bool, captureMiddleClick: Bool,
                       onScroll: @escaping (CGFloat) -> Void,
                       onMiddleClick: @escaping () -> Void) {
            self.captureScroll = captureScroll
            self.captureMiddleClick = captureMiddleClick
            self.onScroll = onScroll
            self.onMiddleClick = onMiddleClick
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            // Claim only the event types whose feature flag is currently
            // enabled. With scroll disabled in Settings, scroll events
            // must fall through to the underlying SwiftUI ScrollView —
            // otherwise the overlay swallows the event for the (no-op)
            // handler and the user can't scroll the page.
            guard let event = NSApp.currentEvent else { return nil }
            switch event.type {
            case .scrollWheel:
                return captureScroll ? self : nil
            case .otherMouseDown, .otherMouseUp where event.buttonNumber == 2:
                return captureMiddleClick ? self : nil
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
    ///
    /// Each handler is gated by its own UserDefaults toggle
    /// (`UDKey.scrollVolumeEnabled`, `UDKey.middleClickMuteEnabled`) so
    /// a user who finds either gesture confusing can disable it from
    /// Settings without losing the other.
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
    @AppStorage(UDKey.scrollVolumeEnabled) private var scrollEnabled = false
    @AppStorage(UDKey.middleClickMuteEnabled) private var middleClickEnabled = true

    func body(content: Content) -> some View {
        if !scrollEnabled && !middleClickEnabled {
            content
        } else {
            content.overlay(
                ScrollWheelCapture(
                    captureScroll: scrollEnabled,
                    captureMiddleClick: middleClickEnabled,
                    onScroll: { deltaY in
                        let step = accumulator.consume(deltaY: deltaY)
                        if step != 0 { onVolumeStep(step) }
                    },
                    onMiddleClick: { onToggleMute() }
                )
            )
        }
    }
}
