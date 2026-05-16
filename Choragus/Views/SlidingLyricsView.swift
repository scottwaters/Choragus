/// Karaoke-style synced-lyrics renderer. Sizing is parameterised so
/// both the inline panel and the popout karaoke window can size it
/// without forking the implementation.
///
/// Per-frame budget on the render thread:
/// - Tight visible slice (`visibleRows + 2·bufferRows` rows) so long
///   LRCs can't blow up the view tree.
/// - Per-row `.compositingGroup()` so each line is flattened to a
///   single CALayer; `scaleEffect` and `opacity` then become pure GPU
///   transforms, not re-rasterisations.
/// - `Equatable` short-circuit so parent re-renders (track metadata
///   updates, volume changes, etc.) don't tear down and rebuild the
///   `TimelineView` — only meaningful input changes do.
/// - Per-row opacity falloff replaces a wrap-the-stack `.mask()` so
///   we avoid the offscreen compositing pass that mask used to force
///   on every TimelineView tick.
import SwiftUI
import SonosKit

struct SlidingLyricsView: View, Equatable {
    let lines: [LyricLine]
    let anchor: PositionAnchor
    let offset: Double

    var visibleRows: Int = 5
    var rowHeight: CGFloat = 34
    var peakSize: CGFloat = 19
    var baseSize: CGFloat = 13
    /// Visual style for the lyrics readout. `.dynamic` (default) scales
    /// the active line up and neighbours down. `.classic` renders all
    /// lines at `peakSize` with only the opacity gradient marking the
    /// active row — matches the traditional karaoke-bouncing-ball
    /// presentation users associate with the term.
    var style: KaraokeStyle = .dynamic

    init(lines: [(time: Double, line: String)],
         anchor: PositionAnchor,
         offset: Double,
         visibleRows: Int = 5,
         rowHeight: CGFloat = 34,
         peakSize: CGFloat = 19,
         baseSize: CGFloat = 13,
         style: KaraokeStyle = .dynamic) {
        self.lines = lines.map { LyricLine(time: $0.time, line: $0.line) }
        self.anchor = anchor
        self.offset = offset
        self.visibleRows = visibleRows
        self.rowHeight = rowHeight
        self.peakSize = peakSize
        self.baseSize = baseSize
        self.style = style
    }

    private var centreRow: Int { visibleRows / 2 }
    /// One row of pre-roll above + below the visible band so a line can
    /// scale up before crossing into view.
    private let bufferRows = 1


    static func == (lhs: SlidingLyricsView, rhs: SlidingLyricsView) -> Bool {
        lhs.anchor == rhs.anchor
            && lhs.offset == rhs.offset
            && lhs.visibleRows == rhs.visibleRows
            && lhs.rowHeight == rhs.rowHeight
            && lhs.peakSize == rhs.peakSize
            && lhs.baseSize == rhs.baseSize
            && lhs.style == rhs.style
            && lhs.lines == rhs.lines
    }

    var body: some View {
        let windowHeight = CGFloat(visibleRows) * rowHeight
        TimelineView(.animation) { context in
            // `fractionalIndex` itself bakes in the per-line centre
            // lead from the karaoke model — no global offset needed.
            let live = anchor.projected(at: context.date) + offset
            let liveFractional = fractionalIndex(for: live)
            let halfWindow = centreRow + bufferRows
            let lineCount = lines.count
            // Clamp `active` into [0, lineCount-1]. Pre-roll path in
            // `fractionalIndex` returns unbounded negatives when a stale
            // manual offset is applied across a track change; without the
            // clamp `hi` could go negative and `lo..<hi` would trap.
            let activeRaw = Int(liveFractional.rounded())
            let active = lineCount > 0 ? max(0, min(lineCount - 1, activeRaw)) : 0
            let lo = max(0, active - halfWindow)
            let hi = max(lo, min(lineCount, active + halfWindow + 1))
            let yOffset = CGFloat(Double(centreRow) - (liveFractional - Double(lo))) * rowHeight
            VStack(spacing: 0) {
                // `Array(lo..<hi)` materialises the range so SwiftUI's
                // ForEach diff sees a stable identifier set across track
                // changes — `ForEach(Range, id:\.self)` reuses indices
                // from a prior evaluation against the new (shorter)
                // `lines` for one frame and traps on subscript.
                ForEach(Array(lo..<hi), id: \.self) { index in
                    if index < lines.count {
                        lyricLine(
                            lines[index].line,
                            distance: abs(Double(index) - liveFractional)
                        )
                        .frame(height: rowHeight)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .offset(y: yOffset)
            .frame(maxWidth: .infinity, maxHeight: windowHeight, alignment: .top)
            .clipped()
            // Strip any inherited animation context from the per-frame
            // body so VStack offset jumps and ForEach insert/remove on
            // line transitions can't pick up SwiftUI's default ~0.25 s
            // implicit interpolation and fight the TimelineView motion.
            .transaction { $0.animation = nil }
        }
    }

    /// Continuous fractional position of `pos` within the line list.
    /// Whole numbers = a line is dead-centre at its raw LRC timestamp;
    /// fractions = between two lines. No built-in lead — the user's
    /// per-track manual offset (the `±` toolbar) is the only timing
    /// adjustment.
    ///
    /// Binary search — TimelineView ticks at display refresh, so an
    /// O(N) scan over a few-hundred-line LRC ran the main thread for
    /// long enough to drop frames on dense songs.
    private func fractionalIndex(for pos: Double) -> Double {
        guard !lines.isEmpty else { return 0 }
        var lo = 0
        var hi = lines.count - 1
        var prevIdx = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].time <= pos {
                prevIdx = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        if prevIdx < 0 {
            // Pre-roll: glide the first line in from below as the
            // song approaches its first lyric stamp.
            guard let firstTime = lines.first?.time, firstTime > 0 else { return 0 }
            return (pos / firstTime) - 1.0
        }
        let nextIdx = prevIdx + 1
        if nextIdx >= lines.count {
            return Double(prevIdx)
        }
        let prevTime = lines[prevIdx].time
        let nextTime = lines[nextIdx].time
        let span = nextTime - prevTime
        if span <= 0 { return Double(prevIdx) }
        let progress = (pos - prevTime) / span
        return Double(prevIdx) + min(max(progress, 0), 1)
    }

    @ViewBuilder
    private func lyricLine(_ text: String, distance: Double) -> some View {
        // Centre row at full opacity; rows ≥ 2.5 lines from centre fade
        // to 0. The per-row falloff replaces a `.mask()` LinearGradient
        // wrap that forced an offscreen compositing pass each frame.
        let clamped = min(max(distance, 0), 2.5)
        let t = 1.0 - (clamped / 2.5)
        // Classic style holds every visible line at `peakSize` — no
        // scale interpolation — and leans entirely on the opacity
        // gradient to mark the active row. Matches the traditional
        // karaoke presentation. Dynamic style keeps the existing
        // peak-to-base size interpolation. Wrapped in a closure so
        // the `switch` reads as control flow, not a SwiftUI
        // `@ViewBuilder` branch.
        let scale: CGFloat = {
            switch style {
            case .dynamic:
                let minScale = baseSize / peakSize
                return minScale + (1.0 - minScale) * CGFloat(t)
            case .classic:
                return 1.0
            }
        }()
        let opacity = CGFloat(t * t)

        Text(text)
            .font(.system(size: peakSize, weight: .semibold))
            .foregroundStyle(Color.primary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .lineLimit(1)
            // Long lines shrink to fit width instead of truncating "…".
            .minimumScaleFactor(0.3)
            .padding(.horizontal, 16)
            // `.compositingGroup()` flattens the row before applying the
            // per-frame transforms so scale/opacity touch one CALayer
            // on the render thread instead of walking the SwiftUI tree.
            .compositingGroup()
            .scaleEffect(scale)
            .opacity(opacity)
            // Suppress SwiftUI's default ~0.25 s implicit interpolation
            // — the TimelineView already provides smooth motion.
            .animation(nil, value: scale)
            .animation(nil, value: opacity)
            .allowsHitTesting(false)
    }
}

/// Equatable wrapper for synced-LRC entries so `SlidingLyricsView` can
/// short-circuit body re-evaluation when the parent re-renders for
/// unrelated reasons. Tuples don't conform to `Equatable`.
struct LyricLine: Equatable {
    let time: Double
    let line: String
}
