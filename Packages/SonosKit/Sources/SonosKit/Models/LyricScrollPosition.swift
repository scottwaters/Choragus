/// LyricScrollPosition.swift — Where synced lyrics sit at a playback position.
///
/// Synced (LRC) lyrics carry a timestamp per line. The karaoke and Lyrics views
/// do not snap between lines: they interpolate, so the text glides continuously
/// and the current line is always centred. That means the answer is a
/// *fractional* index — 4.5 is halfway between lines 4 and 5.
///
/// Edge cases:
///   - **Pre-roll.** Before the first stamp the result is negative, so the
///     opening line glides up from below rather than sitting pinned.
///   - **The last line.** There is no next stamp to interpolate toward, so it
///     holds rather than gliding off the end.
///   - **Duplicate stamps.** Two lines sharing a timestamp have a zero span,
///     and dividing by it would produce infinity or NaN, which SwiftUI turns
///     into a blank view rather than a crash.
///
/// Binary search rather than a scan: `TimelineView` ticks at display refresh,
/// and an O(N) walk over a dense LRC drops frames.
import Foundation

public enum LyricScrollPosition {

    /// A synced lyric line: seconds into the track, and its text.
    public struct Line: Equatable {
        public let time: Double
        public let text: String

        public init(time: Double, text: String) {
            self.time = time
            self.text = text
        }
    }

    /// The fractional line index for a playback position.
    ///
    /// Returns 0 for no lyrics; a negative value during pre-roll; and
    /// `index + progress` between two stamps, where progress is 0...1.
    public static func fractionalIndex(for position: Double, lines: [Line]) -> Double {
        guard !lines.isEmpty else { return 0 }

        var low = 0
        var high = lines.count - 1
        var previous = -1
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].time <= position {
                previous = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        if previous < 0 {
            // Before the first stamp: glide the opening line in from below,
            // reaching 0 exactly as its timestamp arrives.
            guard let first = lines.first?.time, first > 0 else { return 0 }
            return (position / first) - 1.0
        }

        let next = previous + 1
        guard next < lines.count else { return Double(previous) }

        let span = lines[next].time - lines[previous].time
        guard span > 0 else { return Double(previous) }

        let progress = (position - lines[previous].time) / span
        return Double(previous) + min(max(progress, 0), 1)
    }
}
