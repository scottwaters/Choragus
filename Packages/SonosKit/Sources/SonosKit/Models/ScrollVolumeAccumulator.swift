import Foundation

/// Pure accumulator that converts raw scroll-wheel delta values into
/// discrete integer volume steps. Extracted from the view layer so the
/// threshold and cap logic can be unit-tested without AppKit.
///
/// Call `consume(deltaY:)` once per scroll event. Accumulates sub-threshold
/// deltas across calls; returns 0 when below threshold, otherwise the
/// rounded integer step count (capped at ±`maxStepPerEvent`).
///
/// Sign convention matches macOS `NSEvent.scrollingDeltaY`:
/// - Scroll up → negative `deltaY` → positive return value.
/// - Scroll down → positive `deltaY` → negative return value.
public struct ScrollVolumeAccumulator {
    public private(set) var accumulated: CGFloat = 0

    /// Minimum absolute accumulated delta required to emit a step.
    public let stepThreshold: CGFloat

    /// Per-event cap on the absolute step count (flick-scroll guard).
    public let maxStepPerEvent: Int

    public init(stepThreshold: CGFloat = 1.0, maxStepPerEvent: Int = 3) {
        self.stepThreshold = stepThreshold
        self.maxStepPerEvent = maxStepPerEvent
    }

    public mutating func consume(deltaY: CGFloat) -> Int {
        accumulated -= deltaY
        guard abs(accumulated) >= stepThreshold else { return 0 }
        let rawSteps = Int(accumulated.rounded(.towardZero))
        accumulated -= CGFloat(rawSteps)
        return max(-maxStepPerEvent, min(maxStepPerEvent, rawSteps))
    }

    public mutating func reset() {
        accumulated = 0
    }
}
