/// Karaoke-style synced-lyrics renderer. Sizing is parameterised so
/// both the inline panel and the popout karaoke window can size it
/// without forking the implementation.
///
/// Render path: a single `Canvas` drawn inside a `TimelineView(.animation)`.
/// `Canvas` is a leaf to SwiftUI's diff, so the display-refresh redraw
/// repaints straight into a `GraphicsContext` without re-evaluating any
/// surrounding view tree. A `VStack { ForEach { Text } }` body re-builds
/// its subtree per frame, cascading `ViewGraph.updateOutputs` into the
/// surrounding `ScrollView` and putting the main thread into a continuous
/// `_layoutSubtreeWithOldSize` loop (~30–50% main-thread CPU).
///
/// Per-frame budget on the render thread:
/// - Visible slice (`visibleRows + 2·bufferRows` rows) so long LRCs
///   never materialise more than ~9 resolved-text objects per tick.
/// - Per-row scale + opacity applied via `GraphicsContext.drawLayer`,
///   i.e. a transform on the rendering pipeline, not a SwiftUI modifier.
/// - `Equatable` short-circuit so parent re-renders (track metadata
///   updates, volume changes, etc.) don't tear down and rebuild the
///   `TimelineView` — only meaningful input changes do.
/// - Fixed-height outer frame (`height: windowHeight`) so the Canvas's
///   intrinsic size can't fluctuate and pull the parent into layout.
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
            Canvas(opaque: false, rendersAsynchronously: false) { ctx, size in
                // `fractionalIndex` itself bakes in the per-line centre
                // lead from the karaoke model — no global offset needed.
                let live = anchor.projected(at: context.date) + offset
                let liveFractional = fractionalIndex(for: live)
                let halfWindow = centreRow + bufferRows
                let lineCount = lines.count
                guard lineCount > 0 else { return }
                // Clamp `active` into [0, lineCount-1]. Pre-roll path in
                // `fractionalIndex` returns unbounded negatives when a
                // stale manual offset is applied across a track change.
                let activeRaw = Int(liveFractional.rounded())
                let active = max(0, min(lineCount - 1, activeRaw))
                let lo = max(0, active - halfWindow)
                let hi = max(lo, min(lineCount, active + halfWindow + 1))
                // Centre of the row that holds `liveFractional` lands at
                // `centreRow * rowHeight + rowHeight/2`.
                let centreY = CGFloat(centreRow) * rowHeight + rowHeight / 2
                let centreX = size.width / 2
                // Horizontal slack for shrink-to-fit (16 pt each side).
                let availableWidth = max(size.width - 32, 1)
                let minFitScale: CGFloat = 0.3
                let minScale = baseSize / peakSize

                for index in lo..<hi {
                    guard index < lineCount else { continue }
                    let distance = abs(Double(index) - liveFractional)
                    let clamped = min(max(distance, 0), 2.5)
                    let t = 1.0 - (clamped / 2.5)
                    let scale: CGFloat
                    switch style {
                    case .dynamic:
                        scale = minScale + (1.0 - minScale) * CGFloat(t)
                    case .classic:
                        scale = 1.0
                    }
                    let opacity = t * t

                    let rowY = centreY + CGFloat(Double(index) - liveFractional) * rowHeight
                    // Cull rows whose centre is outside the visible band;
                    // bufferRows already keep one row of pre-roll above
                    // and below for the scale-in animation.
                    if rowY < -rowHeight || rowY > size.height + rowHeight { continue }

                    let text = Text(lines[index].line)
                        .font(.system(size: peakSize, weight: .semibold))
                        .foregroundColor(.primary)
                    let resolved = ctx.resolve(text)
                    let measured = resolved.measure(in: CGSize(
                        width: .greatestFiniteMagnitude,
                        height: rowHeight
                    ))
                    let widthFit = min(1.0, availableWidth / max(measured.width, 1))
                    let fitScale = max(widthFit, minFitScale)

                    ctx.drawLayer { layer in
                        layer.opacity *= opacity
                        layer.translateBy(x: centreX, y: rowY)
                        layer.scaleBy(x: scale * fitScale, y: scale * fitScale)
                        layer.draw(resolved, at: .zero, anchor: .center)
                    }
                }
            }
            // Fixed height — a `maxHeight` frame lets intrinsic content
            // negotiate, which fluctuates per tick as the visible-row
            // window shifts and pulls the parent ScrollView into a
            // `_layoutSubtreeWithOldSize` loop.
            .frame(maxWidth: .infinity,
                   minHeight: windowHeight,
                   maxHeight: windowHeight,
                   alignment: .top)
            .allowsHitTesting(false)
        }
    }

    /// Continuous fractional position of `pos` within the line list.
    /// Whole numbers = a line is dead-centre at its raw LRC timestamp;
    /// fractions = between two lines. No built-in lead — the user's
    /// per-track manual offset (the `±` toolbar) is the only timing
    /// adjustment.
    ///
    /// Binary search — TimelineView ticks at display refresh, so an
    /// O(N) scan over a few-hundred-line LRC drops frames on dense songs.
    private func fractionalIndex(for pos: Double) -> Double {
        // Interpolation, pre-roll and the degenerate cases live in
        // LyricScrollPosition so they can be tested without a running clock.
        LyricScrollPosition.fractionalIndex(
            for: pos,
            lines: lines.map { .init(time: $0.time, text: $0.line) })
    }

}

/// Equatable wrapper for synced-LRC entries so `SlidingLyricsView` can
/// short-circuit body re-evaluation when the parent re-renders for
/// unrelated reasons. Tuples don't conform to `Equatable`.
struct LyricLine: Equatable {
    let time: Double
    let line: String
}
