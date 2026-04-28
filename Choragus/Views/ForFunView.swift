/// ForFunView.swift — Purely-visual explorations of the play-history data.
///
/// Four Canvas-rendered views share the app's `PlayHistoryManager.entries`
/// and a single animation timeline. They don't affect playback or persist
/// state; they exist to make the data fun to look at.
///
/// Animation model: a `TimelineView(.animation)` wall-clock drives a
/// `phase` in [0, 1] representing how far through the history range we
/// are. All four visualisations receive that phase and render whatever
/// their metaphor should look like at that point in history — particles
/// for Gource, filled bands for Stream, cumulative cells for Heatmap,
/// growing arcs for Chord. The loop length is shared, so switching tabs
/// continues the timelapse.
///
/// 1. Gource — rooms around a circle, a particle flies from centre to
///    room for every play near the current scrub time.
/// 2. Stream — stacked per-room listening hours per day, filled in
///    progressively left to right.
/// 3. Heatmap — rooms × hour-of-day, cells light up as cumulative plays
///    through the current scrub time accumulate.
/// 4. Chord — top artists ↔ rooms, arcs thicken as their co-play count
///    through the current scrub time grows.
import SwiftUI
import SonosKit

// MARK: - Container

struct ForFunView: View {
    @EnvironmentObject var history: PlayHistoryManager
    @State private var tab: ForFunTab = .gource
    /// Loop duration in seconds. Lower = faster timelapse. Shared so every
    /// tab animates at the same pace; also persists across tab switches.
    @State private var loopSeconds: Double = 30

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let phase = Self.phase(
                    for: timeline.date,
                    loopSeconds: loopSeconds
                )
                Group {
                    switch tab {
                    case .ridges:
                        ListeningRidgesVisualization(entries: history.entries, phase: phase)
                    case .journey:
                        DiscoveryJourneyVisualization(entries: history.entries, phase: phase)
                    case .albums:
                        AlbumConstellationsVisualization(entries: history.entries, phase: phase)
                    case .fingerprint:
                        FingerprintVisualization(entries: history.entries, phase: phase)
                    case .gource:
                        GourceVisualization(entries: history.entries, phase: phase)
                    case .stream:
                        StreamGraphVisualization(entries: history.entries, phase: phase)
                    case .heatmap:
                        HeatmapVisualization(entries: history.entries, phase: phase)
                    case .chord:
                        ChordVisualization(entries: history.entries, phase: phase)
                    case .racing:
                        RacingBarsVisualization(entries: history.entries, phase: phase)
                    case .calendar:
                        CalendarHeatmapVisualization(entries: history.entries, phase: phase)
                    case .spiral:
                        SpiralTimelineVisualization(entries: history.entries, phase: phase)
                    case .orbital:
                        OrbitalVisualization(entries: history.entries, phase: phase)
                    case .physarum:
                        PhysarumVisualization(entries: history.entries, phase: phase)
                    case .hyperbolic:
                        HyperbolicTreeVisualization(entries: history.entries, phase: phase)
                    case .voronoi:
                        VoronoiTreemapVisualization(entries: history.entries, phase: phase)
                    case .arc:
                        ArcDiagramVisualization(entries: history.entries, phase: phase)
                    case .reaction:
                        ReactionDiffusionVisualization(entries: history.entries, phase: phase)
                    case .flow:
                        FlowFieldVisualization(entries: history.entries, phase: phase)
                    case .mapper:
                        MapperVisualization(entries: history.entries, phase: phase)
                    case .embed:
                        ForceEmbeddingVisualization(entries: history.entries, phase: phase)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(ForFunTab.allCases, id: \.self) { t in
                        Button { tab = t } label: {
                            Text(t.title)
                                .font(.caption)
                                .fontWeight(tab == t ? .semibold : .regular)
                                .foregroundStyle(tab == t ? Color.accentColor : .primary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(tab == t
                                              ? Color.accentColor.opacity(0.18)
                                              : Color.secondary.opacity(0.08))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
            }

            HStack(spacing: 8) {
                Text("Speed")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { 60 / max(loopSeconds, 1) },  // display as "x"
                        set: { newRate in loopSeconds = 60 / max(newRate, 0.1) }
                    ),
                    in: 0.25...8.0
                )
                .frame(maxWidth: 260)
                Text(String(format: "%.1fx", 60 / max(loopSeconds, 1)))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
                Spacer()
                Text("Full history loops every \(Int(loopSeconds))s")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    /// Returns a fractional scrub position in [0, 1] that cycles every
    /// `loopSeconds` of wall-clock time. Shared across all four tabs so a
    /// single `TimelineView` can drive the animation.
    private static func phase(for date: Date, loopSeconds: Double) -> Double {
        let loop = max(loopSeconds, 0.1)
        return date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: loop) / loop
    }
}

private enum ForFunTab: String, CaseIterable {
    case ridges, journey, albums, fingerprint,
         gource, stream, heatmap, chord, racing, calendar, spiral, orbital,
         physarum, hyperbolic, voronoi, arc, reaction, flow, mapper, embed
    var title: String {
        switch self {
        case .ridges:      return "Ridges"
        case .journey:     return "Journey"
        case .albums:      return "Albums"
        case .fingerprint: return "Fingerprint"
        case .gource:      return "Gource"
        case .stream:      return "Stream"
        case .heatmap:     return "Heatmap"
        case .chord:       return "Chord"
        case .racing:      return "Race"
        case .calendar:    return "Calendar"
        case .spiral:      return "Spiral"
        case .orbital:     return "Orbit"
        case .physarum:    return "Trail"
        case .hyperbolic:  return "Hyper"
        case .voronoi:     return "Voronoi"
        case .arc:         return "Arcs"
        case .reaction:    return "Turing"
        case .flow:        return "Flow"
        case .mapper:      return "Topology"
        case .embed:       return "Embed"
        }
    }
}

/// Shared range information computed once per data set. Every viz needs
/// the earliest/latest timestamps to convert the shared phase into a
/// concrete "this is the history moment we're rendering" date.
private struct TimelineRange {
    let first: Date
    let last: Date
    var duration: TimeInterval { last.timeIntervalSince(first) }
    func date(at phase: Double) -> Date {
        first.addingTimeInterval(duration * phase)
    }
}

private func timelineRange(for entries: [PlayHistoryEntry]) -> TimelineRange? {
    guard let first = entries.first?.timestamp,
          let last = entries.last?.timestamp,
          last > first else { return nil }
    return TimelineRange(first: first, last: last)
}

// =============================================================================
// MARK: - NEW HEADLINE VISUALIZATIONS
// =============================================================================
// Designed to reveal patterns the existing 16 don't surface, while every
// element decodes back to a real data field per the project rule.
// =============================================================================

// MARK: - Listening Ridges
//
// Stacked ridgeline plot — Joy-Division "Unknown Pleasures" style — where each
// ridge is one of your top tracks and the ridge's vertical profile traces that
// track's plays-per-day across the full history. Reveals "song lifecycles"
// (binge → fade), "comfort tracks" (steady mesa shape), and "current obsessions"
// (rising horizon at the right edge). No other viz preserves per-track time.
//
// Encoding map (every visual element decodes to a data field):
//   • One ridge row         = one of the top N tracks (by total plays)
//   • Row order (top→bot)   = first-play date, newest at top (your latest finds
//                              are at eye level)
//   • Ridge height(x)       = smoothed plays-per-day for that track on day x
//   • Ridge fill colour     = service of the dominant play (Spotify / Plex / …)
//   • Ridge outline glow    = peak intensity for that day vs. the track's mean
//   • Vertical playhead     = current scrub position; ridges left of it are
//                              "lived through", right of it are dimmed
//   • Bloom flares at peaks = days where this track exceeded 2× its own mean
//                              (binge events surface as soft blooms)

private struct ListeningRidgesVisualization: View {
    let entries: [PlayHistoryEntry]
    let phase: Double

    /// One row of the ridgeline plot — a single track's daily play counts.
    private struct TrackRow {
        let key: String
        let title: String
        let artist: String
        let total: Int
        let firstPlay: Date
        let dominantService: String
        let counts: [Double]      // smoothed plays-per-day
        let dailyMean: Double     // for peak detection
        let dailyMax: Double
    }

    private struct Aggregated {
        let rows: [TrackRow]
        let range: TimelineRange
        let dayCount: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Listening Ridges").font(.headline)
                Spacer()
                Text("Each ridge = one top track. Height = plays per day. Newest finds at top, peaks bloom on binge days.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 6)
            Canvas { ctx, size in
                draw(ctx: ctx, size: size)
            }
        }
    }

    private func draw(ctx: GraphicsContext, size: CGSize) {
        guard !entries.isEmpty, let agg = aggregate() else {
            ctx.draw(Text("Building ridges…").font(.title3).foregroundStyle(.secondary),
                     at: CGPoint(x: size.width / 2, y: size.height / 2))
            return
        }

        let leftPad: CGFloat = 150       // room for track labels
        let rightPad: CGFloat = 16
        let topPad: CGFloat = 12
        let bottomPad: CGFloat = 28
        let plotW = max(50, size.width - leftPad - rightPad)
        let plotH = max(50, size.height - topPad - bottomPad)
        let rowCount = agg.rows.count
        guard rowCount > 0 else { return }
        // Each row gets a band that overlaps its neighbours so peaks rise
        // into the row above — that overlap is the Joy-Division signature.
        let bandH = plotH / CGFloat(rowCount)
        let peakAmplitude = bandH * 2.4   // peaks can rise into ~2 rows above

        // Phase → playhead day index
        let activeDays = Int(Double(agg.dayCount) * phase.clamped01)
        let playheadX = leftPad + plotW * CGFloat(phase.clamped01)

        // Faint vertical "today" lines every ~30 days for orientation.
        let monthSpacing: CGFloat = plotW * 30 / CGFloat(max(agg.dayCount, 1))
        var monthLine = Path()
        var mx: CGFloat = leftPad
        while mx <= leftPad + plotW {
            monthLine.move(to: CGPoint(x: mx, y: topPad))
            monthLine.addLine(to: CGPoint(x: mx, y: topPad + plotH))
            mx += monthSpacing
        }
        ctx.stroke(monthLine, with: .color(.secondary.opacity(0.06)), lineWidth: 0.5)

        // Render rows back-to-front (bottom row first) so upper ridges paint
        // over the lower ones — required for the overlap effect to read correctly.
        let orderedRows = Array(agg.rows.enumerated()).reversed()
        for (rowIdx, row) in orderedRows {
            let baselineY = topPad + bandH * (CGFloat(rowIdx) + 0.85)
            let serviceColor = serviceColor(for: row.dominantService)

            // Build the ridge path. Sample at every plot pixel for smoothness.
            let samples = max(60, Int(plotW))
            var ridge = Path()
            ridge.move(to: CGPoint(x: leftPad, y: baselineY))
            for i in 0...samples {
                let frac = Double(i) / Double(samples)
                let day = Int(Double(agg.dayCount - 1) * frac)
                let v = row.counts[min(day, row.counts.count - 1)]
                // Normalise this row by its own max so quiet tracks still show shape.
                let norm = row.dailyMax > 0 ? v / row.dailyMax : 0
                let x = leftPad + plotW * CGFloat(frac)
                // Phase damping: ridges right of the playhead are flattened.
                let phaseDamp: CGFloat = frac > phase.clamped01 ? 0.0 : 1.0
                let y = baselineY - peakAmplitude * CGFloat(norm) * phaseDamp
                ridge.addLine(to: CGPoint(x: x, y: y))
            }
            ridge.addLine(to: CGPoint(x: leftPad + plotW, y: baselineY))
            ridge.closeSubpath()

            // Fill: subtle gradient — top of ridge brighter than baseline.
            let fillTop = serviceColor.opacity(0.55)
            let fillBot = Color.black.opacity(0.85)
            ctx.fill(ridge, with: .linearGradient(
                Gradient(colors: [fillTop, fillBot]),
                startPoint: CGPoint(x: 0, y: baselineY - peakAmplitude),
                endPoint: CGPoint(x: 0, y: baselineY)
            ))

            // Outline: stroke just the top profile (not the closing baseline).
            var profile = Path()
            for i in 0...samples {
                let frac = Double(i) / Double(samples)
                let day = Int(Double(agg.dayCount - 1) * frac)
                let v = row.counts[min(day, row.counts.count - 1)]
                let norm = row.dailyMax > 0 ? v / row.dailyMax : 0
                let x = leftPad + plotW * CGFloat(frac)
                let phaseDamp: CGFloat = frac > phase.clamped01 ? 0.0 : 1.0
                let y = baselineY - peakAmplitude * CGFloat(norm) * phaseDamp
                if i == 0 { profile.move(to: CGPoint(x: x, y: y)) }
                else { profile.addLine(to: CGPoint(x: x, y: y)) }
            }
            ctx.stroke(profile, with: .color(serviceColor.opacity(0.95)), lineWidth: 1.0)

            // Bloom flares: any day where this track exceeded 2× its own mean.
            let binge2x = row.dailyMean * 2.0
            ctx.drawLayer { layer in
                layer.addFilter(.blur(radius: 6))
                for (dayIdx, v) in row.counts.enumerated() {
                    guard v > binge2x, dayIdx <= activeDays else { continue }
                    let frac = Double(dayIdx) / Double(max(agg.dayCount - 1, 1))
                    let norm = row.dailyMax > 0 ? v / row.dailyMax : 0
                    let x = leftPad + plotW * CGFloat(frac)
                    let y = baselineY - peakAmplitude * CGFloat(norm)
                    let r: CGFloat = 4 + CGFloat(min(v / max(binge2x, 0.1), 4)) * 2
                    let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                    layer.fill(Path(ellipseIn: rect),
                               with: .color(serviceColor.opacity(0.85)))
                }
            }

            // Track label (left margin).
            let labelText = Text(row.title)
                .font(.caption2.bold())
                .foregroundStyle(.primary)
            ctx.draw(labelText,
                     at: CGPoint(x: leftPad - 8, y: baselineY - bandH * 0.25),
                     anchor: .trailing)
            if !row.artist.isEmpty {
                let artText = Text(row.artist)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ctx.draw(artText,
                         at: CGPoint(x: leftPad - 8, y: baselineY - bandH * 0.05),
                         anchor: .trailing)
            }
        }

        // Playhead — soft accent line marking "now" in the timelapse.
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: 4))
            let glow = Path(CGRect(x: playheadX - 2, y: topPad,
                                   width: 4, height: plotH))
            layer.fill(glow, with: .color(.accentColor.opacity(0.6)))
        }
        var head = Path()
        head.move(to: CGPoint(x: playheadX, y: topPad))
        head.addLine(to: CGPoint(x: playheadX, y: topPad + plotH))
        ctx.stroke(head, with: .color(.accentColor.opacity(0.85)), lineWidth: 1)

        // Date label below playhead.
        drawTimelineLabel(ctx: ctx, size: size, date: agg.range.date(at: phase.clamped01))
    }

    /// Build per-track daily counts from history. O(entries + tracks × days).
    private func aggregate() -> Aggregated? {
        guard let range = timelineRange(for: entries) else { return nil }
        let cal = Calendar.current
        let firstDay = cal.startOfDay(for: range.first)
        let lastDay = cal.startOfDay(for: range.last)
        let dayCount = (cal.dateComponents([.day], from: firstDay, to: lastDay).day ?? 1) + 1
        guard dayCount > 1 else { return nil }

        // Aggregate per track.
        struct Bucket {
            var title: String
            var artist: String
            var counts: [Double]
            var firstPlay: Date
            var serviceTally: [String: Int]
            var total: Int
        }
        var buckets: [String: Bucket] = [:]
        for e in entries where !e.title.isEmpty {
            let key = "\(e.title)|\(e.artist)"
            let day = cal.dateComponents([.day], from: firstDay, to: cal.startOfDay(for: e.timestamp)).day ?? 0
            let dayIdx = max(0, min(dayCount - 1, day))
            let svc = serviceBucket(for: e.sourceURI)
            if var b = buckets[key] {
                b.counts[dayIdx] += 1
                b.serviceTally[svc, default: 0] += 1
                b.total += 1
                if e.timestamp < b.firstPlay { b.firstPlay = e.timestamp }
                buckets[key] = b
            } else {
                var counts = [Double](repeating: 0, count: dayCount)
                counts[dayIdx] = 1
                buckets[key] = Bucket(
                    title: e.title, artist: e.artist,
                    counts: counts, firstPlay: e.timestamp,
                    serviceTally: [svc: 1], total: 1
                )
            }
        }

        // Top N by total plays.
        let topN = 24
        let topKeys = buckets.sorted { $0.value.total > $1.value.total }
            .prefix(topN).map { $0.key }
        guard !topKeys.isEmpty else { return nil }

        // Smooth each track's counts with a 5-day Gaussian (kernel weights).
        let kernel: [Double] = [0.05, 0.24, 0.42, 0.24, 0.05]
        var rows: [TrackRow] = []
        for key in topKeys {
            guard var b = buckets[key] else { continue }
            var smoothed = [Double](repeating: 0, count: dayCount)
            for i in 0..<dayCount {
                var s = 0.0
                for (k, w) in kernel.enumerated() {
                    let j = i + k - 2
                    if j >= 0 && j < dayCount {
                        s += b.counts[j] * w
                    }
                }
                smoothed[i] = s
            }
            b.counts = smoothed
            let total = b.total
            let mean = Double(total) / Double(dayCount)
            let maxV = smoothed.max() ?? 0
            let dominant = b.serviceTally.max { $0.value < $1.value }?.key ?? "Other"
            rows.append(TrackRow(
                key: key,
                title: b.title,
                artist: b.artist,
                total: total,
                firstPlay: b.firstPlay,
                dominantService: dominant,
                counts: smoothed,
                dailyMean: mean,
                dailyMax: maxV
            ))
        }

        // Newest first-play at top of plot.
        rows.sort { $0.firstPlay > $1.firstPlay }
        return Aggregated(rows: rows, range: range, dayCount: dayCount)
    }
}

// MARK: - Discovery / Comfort Path
//
// One dot per week, plotted on a 2D plane:
//   • X = comfort   (0…1) = fraction of week's plays from your top-3 lifetime artists
//   • Y = discovery (0…1) = fraction from artists with no plays in the prior 30 days
// Connects weeks chronologically as a glowing trail; the "current" week pulses.
// Background tints by season (warm autumn / cool winter / fresh spring / golden
// summer) so the path moves through visible temporal mood.
//
// Encoding map:
//   • One dot              = one week of history
//   • Dot X position       = comfort fraction
//   • Dot Y position       = discovery fraction
//   • Dot size             = total plays that week (engagement intensity)
//   • Connecting segment   = chronological adjacency of weeks
//   • Segment glow         = recency (older fades)
//   • Pulsing dot          = the week currently under the timelapse playhead
//   • Background tint      = month-of-year hue (seasons map to corners)

private struct DiscoveryJourneyVisualization: View {
    let entries: [PlayHistoryEntry]
    let phase: Double

    private struct WeekPoint {
        let date: Date
        let comfort: Double
        let discovery: Double
        let plays: Int
        let monthHue: Double  // 0…1 (Jan ≈ winter blue, Jul ≈ summer gold)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Discovery × Comfort").font(.headline)
                Spacer()
                Text("Each star = one week. X = % from top-3 artists. Y = % from artists you hadn't heard in 30 days. Trail = your taste path through time.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 6)
            Canvas { ctx, size in
                draw(ctx: ctx, size: size)
            }
        }
    }

    private func draw(ctx: GraphicsContext, size: CGSize) {
        let weeks = aggregate()
        guard !weeks.isEmpty else {
            ctx.draw(Text("Need at least a few weeks of history…").font(.title3).foregroundStyle(.secondary),
                     at: CGPoint(x: size.width / 2, y: size.height / 2))
            return
        }
        let pad: CGFloat = 56
        let plotRect = CGRect(x: pad, y: pad, width: size.width - pad * 2, height: size.height - pad * 2)

        // Background — gradient seasonal tint behind the plot.
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: 22))
            let bgGrad = Gradient(stops: [
                .init(color: Color(hue: 0.62, saturation: 0.4, brightness: 0.18), location: 0.0),  // top-left winter
                .init(color: Color(hue: 0.30, saturation: 0.4, brightness: 0.18), location: 0.5),  // mid spring
                .init(color: Color(hue: 0.10, saturation: 0.45, brightness: 0.20), location: 1.0), // bot-right autumn
            ])
            layer.fill(Path(plotRect),
                       with: .linearGradient(bgGrad,
                                             startPoint: CGPoint(x: plotRect.minX, y: plotRect.minY),
                                             endPoint: CGPoint(x: plotRect.maxX, y: plotRect.maxY)))
        }

        // Axis frame + tick lines at 0.25, 0.5, 0.75.
        let frame = Path(plotRect)
        ctx.stroke(frame, with: .color(.secondary.opacity(0.18)), lineWidth: 0.7)
        for t: Double in [0.25, 0.5, 0.75] {
            var v = Path()
            v.move(to: CGPoint(x: plotRect.minX + plotRect.width * CGFloat(t), y: plotRect.minY))
            v.addLine(to: CGPoint(x: plotRect.minX + plotRect.width * CGFloat(t), y: plotRect.maxY))
            ctx.stroke(v, with: .color(.secondary.opacity(0.08)), lineWidth: 0.4)
            var h = Path()
            h.move(to: CGPoint(x: plotRect.minX, y: plotRect.maxY - plotRect.height * CGFloat(t)))
            h.addLine(to: CGPoint(x: plotRect.maxX, y: plotRect.maxY - plotRect.height * CGFloat(t)))
            ctx.stroke(h, with: .color(.secondary.opacity(0.08)), lineWidth: 0.4)
        }
        // Axis labels.
        ctx.draw(Text("comfort →").font(.caption2).foregroundStyle(.secondary),
                 at: CGPoint(x: plotRect.maxX, y: plotRect.maxY + 14), anchor: .trailing)
        ctx.draw(Text("discovery ↑").font(.caption2).foregroundStyle(.secondary),
                 at: CGPoint(x: plotRect.minX - 6, y: plotRect.minY), anchor: .trailing)

        // Map week → plot point.
        func pt(_ w: WeekPoint) -> CGPoint {
            CGPoint(x: plotRect.minX + plotRect.width * CGFloat(w.comfort.clamped01),
                    y: plotRect.maxY - plotRect.height * CGFloat(w.discovery.clamped01))
        }

        // Phase: only show weeks up to the current scrub position.
        let activeCount = max(1, Int(Double(weeks.count) * phase.clamped01))
        let visible = Array(weeks.prefix(activeCount))

        // Draw the connecting trail with a glow.
        if visible.count >= 2 {
            ctx.drawLayer { layer in
                layer.addFilter(.blur(radius: 5))
                var trail = Path()
                trail.move(to: pt(visible[0]))
                for w in visible.dropFirst() { trail.addLine(to: pt(w)) }
                layer.stroke(trail, with: .color(.accentColor.opacity(0.45)), lineWidth: 4)
            }
            var trail = Path()
            trail.move(to: pt(visible[0]))
            for w in visible.dropFirst() { trail.addLine(to: pt(w)) }
            ctx.stroke(trail, with: .color(.accentColor.opacity(0.85)), lineWidth: 1.2)
        }

        // Each week as a star: size = plays, hue = month.
        let maxPlays = max(1, weeks.map(\.plays).max() ?? 1)
        for (i, w) in visible.enumerated() {
            let p = pt(w)
            let recency = Double(i) / Double(max(visible.count - 1, 1))
            let r: CGFloat = 1.5 + CGFloat(Double(w.plays) / Double(maxPlays)) * 5.5
            let starColor = Color(hue: w.monthHue, saturation: 0.65, brightness: 0.95)
            // Soft glow for the dot.
            ctx.drawLayer { layer in
                layer.addFilter(.blur(radius: r * 1.4))
                let g = Path(ellipseIn: CGRect(x: p.x - r * 1.6, y: p.y - r * 1.6,
                                                width: r * 3.2, height: r * 3.2))
                layer.fill(g, with: .color(starColor.opacity(0.35 + recency * 0.4)))
            }
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r,
                                             width: r * 2, height: r * 2)),
                     with: .color(starColor.opacity(0.55 + recency * 0.45)))
        }

        // Pulse the most-recent visible week.
        if let last = visible.last {
            let p = pt(last)
            let pulse = 0.5 + 0.5 * sin(Date().timeIntervalSinceReferenceDate * 3)
            let outer: CGFloat = 12 + CGFloat(pulse) * 6
            ctx.drawLayer { layer in
                layer.addFilter(.blur(radius: 8))
                layer.fill(Path(ellipseIn: CGRect(x: p.x - outer, y: p.y - outer,
                                                  width: outer * 2, height: outer * 2)),
                           with: .color(.accentColor.opacity(0.55)))
            }
            ctx.stroke(Path(ellipseIn: CGRect(x: p.x - outer * 0.6, y: p.y - outer * 0.6,
                                              width: outer * 1.2, height: outer * 1.2)),
                       with: .color(.accentColor.opacity(0.9)), lineWidth: 1.2)

            // Date label for the current week.
            let f = DateFormatter(); f.dateFormat = "MMM yyyy"
            ctx.draw(Text(f.string(from: last.date)).font(.caption2.bold()).foregroundStyle(.primary),
                     at: CGPoint(x: p.x, y: p.y - outer - 10))
        }

        // Region labels in faint type — anchors for the four extremes.
        ctx.draw(Text("exploring").font(.caption2).foregroundStyle(.secondary.opacity(0.6)),
                 at: CGPoint(x: plotRect.minX + 10, y: plotRect.minY + 10), anchor: .topLeading)
        ctx.draw(Text("comfort + exploring").font(.caption2).foregroundStyle(.secondary.opacity(0.6)),
                 at: CGPoint(x: plotRect.maxX - 10, y: plotRect.minY + 10), anchor: .topTrailing)
        ctx.draw(Text("nostalgia").font(.caption2).foregroundStyle(.secondary.opacity(0.6)),
                 at: CGPoint(x: plotRect.maxX - 10, y: plotRect.maxY - 18), anchor: .bottomTrailing)
        ctx.draw(Text("scattered").font(.caption2).foregroundStyle(.secondary.opacity(0.6)),
                 at: CGPoint(x: plotRect.minX + 10, y: plotRect.maxY - 18), anchor: .bottomLeading)
    }

    private func aggregate() -> [WeekPoint] {
        guard !entries.isEmpty else { return [] }
        let cal = Calendar.current

        // Top-3 lifetime artists.
        var artistCounts: [String: Int] = [:]
        for e in entries where !e.artist.isEmpty {
            artistCounts[e.artist, default: 0] += 1
        }
        let top3: Set<String> = Set(artistCounts.sorted { $0.value > $1.value }
                                     .prefix(3).map { $0.key })

        // Group by ISO week starting Monday.
        var byWeek: [Date: [PlayHistoryEntry]] = [:]
        for e in entries {
            let comp = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: e.timestamp)
            if let weekStart = cal.date(from: comp) {
                byWeek[weekStart, default: []].append(e)
            }
        }
        let sortedWeeks = byWeek.keys.sorted()
        guard sortedWeeks.count >= 4 else { return [] }

        // For each week: compute comfort + discovery.
        var result: [WeekPoint] = []
        let priorWindow: TimeInterval = 30 * 86_400  // 30 days
        for weekStart in sortedWeeks {
            let plays = byWeek[weekStart] ?? []
            guard !plays.isEmpty else { continue }
            let comfortCount = plays.filter { top3.contains($0.artist) }.count
            // Discovery: artists not heard in prior 30 days.
            let weekArtists = Set(plays.compactMap { $0.artist.isEmpty ? nil : $0.artist })
            let cutoff = weekStart.addingTimeInterval(-priorWindow)
            let priorArtists = Set(entries
                .filter { $0.timestamp >= cutoff && $0.timestamp < weekStart && !$0.artist.isEmpty }
                .map(\.artist))
            let novelArtists = weekArtists.subtracting(priorArtists)
            let discoveryCount = plays.filter { novelArtists.contains($0.artist) }.count

            let comfort = Double(comfortCount) / Double(plays.count)
            let discovery = Double(discoveryCount) / Double(plays.count)
            let month = cal.component(.month, from: weekStart)
            // Map month → hue: Jan=0.62 (winter blue), Apr=0.32 (spring green),
            // Jul=0.12 (summer gold), Oct=0.02 (autumn red), then wraps.
            let monthHue = ((Double(month - 1) / 12.0) * 0.6 + 0.6).truncatingRemainder(dividingBy: 1.0)
            result.append(WeekPoint(date: weekStart,
                                    comfort: comfort,
                                    discovery: discovery,
                                    plays: plays.count,
                                    monthHue: monthHue))
        }
        return result
    }
}

// MARK: - Album Constellations
//
// Each top album is rendered as a ring of "stars" (one per heard track) orbiting
// a central nucleus. Track stars light up in playback order as the timelapse
// scrubs through history. Albums you've actually finished form complete rings;
// tourist-listened albums show partial arcs with bright singles and dark gaps.
//
// Encoding map:
//   • One ring                  = one of the top albums
//   • Ring radius               = album rank (closer-in = more total plays)
//   • Star on the ring          = a distinct track of that album you've heard
//   • Star angular position     = playback order (first-played track at 12 o'clock)
//   • Star brightness           = play count for that track
//   • Star pulse on activation  = the moment that track was first played in the
//                                  currently-scrubbed timeline
//   • Ring colour               = service of dominant plays for that album
//   • Centre nucleus            = total plays across all top albums (size + glow)

private struct AlbumConstellationsVisualization: View {
    let entries: [PlayHistoryEntry]
    let phase: Double

    private struct AlbumOrbit {
        let albumLabel: String       // "Album — Artist"
        let totalPlays: Int
        let dominantService: String
        let tracks: [TrackStar]
    }

    private struct TrackStar {
        let title: String
        let firstPlay: Date
        let plays: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Album Constellations").font(.headline)
                Spacer()
                Text("Each ring = one album. Stars = its tracks. Brightness = plays. Stars light up in the order you first played them.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 6)
            Canvas { ctx, size in
                draw(ctx: ctx, size: size)
            }
        }
    }

    private func draw(ctx: GraphicsContext, size: CGSize) {
        guard let range = timelineRange(for: entries) else {
            ctx.draw(Text("Building constellations…").font(.title3).foregroundStyle(.secondary),
                     at: CGPoint(x: size.width / 2, y: size.height / 2))
            return
        }
        let albums = aggregate()
        guard !albums.isEmpty else {
            ctx.draw(Text("No albums yet").font(.title3).foregroundStyle(.secondary),
                     at: CGPoint(x: size.width / 2, y: size.height / 2))
            return
        }

        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let maxR = min(size.width, size.height) * 0.46
        let minR: CGFloat = 50
        let cutoff = range.date(at: phase.clamped01)

        // Subtle radial backdrop.
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: 30))
            for r in stride(from: maxR, through: minR, by: -maxR / 4) {
                let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
                layer.stroke(Path(ellipseIn: rect),
                             with: .color(.accentColor.opacity(0.08)), lineWidth: 6)
            }
        }

        // Each album = one ring at rank-determined radius.
        let albumCount = albums.count
        for (idx, album) in albums.enumerated() {
            let frac = Double(idx) / Double(max(albumCount - 1, 1))
            let R = minR + (maxR - minR) * CGFloat(frac)
            let serviceColor = serviceColor(for: album.dominantService)

            // Ring guide.
            let ring = Path(ellipseIn: CGRect(x: center.x - R, y: center.y - R,
                                              width: R * 2, height: R * 2))
            ctx.stroke(ring, with: .color(serviceColor.opacity(0.18)), lineWidth: 0.6)

            // Tracks on the ring, angle = playback order.
            let trackCount = album.tracks.count
            guard trackCount > 0 else { continue }
            let maxTrackPlays = max(1, album.tracks.map(\.plays).max() ?? 1)

            for (ti, track) in album.tracks.enumerated() {
                let theta = -.pi / 2 + (Double(ti) / Double(trackCount)) * .pi * 2
                let p = CGPoint(x: center.x + R * CGFloat(cos(theta)),
                                y: center.y + R * CGFloat(sin(theta)))
                // Activation: only show stars whose first-play has occurred by
                // the current scrub time.
                let active = track.firstPlay <= cutoff
                guard active else { continue }
                let intensity = Double(track.plays) / Double(maxTrackPlays)
                let starR: CGFloat = 1.6 + CGFloat(intensity) * 4.2

                // Pulse stars whose first-play happened in the last ~5% of the
                // current scrub range — they "ignite" as time passes.
                let recency = cutoff.timeIntervalSince(track.firstPlay) / max(range.duration, 1)
                let pulseAmt = max(0, 1 - recency * 20)
                let pulseR = starR + CGFloat(pulseAmt) * 6

                // Glow.
                ctx.drawLayer { layer in
                    layer.addFilter(.blur(radius: 4 + pulseR * 0.4))
                    layer.fill(Path(ellipseIn: CGRect(x: p.x - pulseR, y: p.y - pulseR,
                                                      width: pulseR * 2, height: pulseR * 2)),
                               with: .color(serviceColor.opacity(0.35 + intensity * 0.5)))
                }
                // Crisp star.
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - starR, y: p.y - starR,
                                                width: starR * 2, height: starR * 2)),
                         with: .color(serviceColor.opacity(0.6 + intensity * 0.4)))
            }

            // Album label at the rim (hide if too cluttered).
            if albumCount <= 12 {
                let lblTheta = -.pi / 2 + 0.06
                let lblR = R + 12
                let lblP = CGPoint(x: center.x + lblR * CGFloat(cos(lblTheta)),
                                   y: center.y + lblR * CGFloat(sin(lblTheta)))
                ctx.draw(Text(album.albumLabel).font(.caption2).foregroundStyle(.secondary),
                         at: lblP, anchor: .leading)
            }
        }

        // Centre nucleus — total plays across all top albums, breathing slowly.
        let totalPlays = albums.reduce(0) { $0 + $1.totalPlays }
        let breath = 0.5 + 0.5 * sin(Date().timeIntervalSinceReferenceDate * 1.8)
        let nucR: CGFloat = 8 + CGFloat(min(Double(totalPlays) / 2000.0, 1.0)) * 12 + CGFloat(breath) * 2
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: 14))
            layer.fill(Path(ellipseIn: CGRect(x: center.x - nucR * 1.8, y: center.y - nucR * 1.8,
                                              width: nucR * 3.6, height: nucR * 3.6)),
                       with: .color(.accentColor.opacity(0.55)))
        }
        ctx.fill(Path(ellipseIn: CGRect(x: center.x - nucR, y: center.y - nucR,
                                         width: nucR * 2, height: nucR * 2)),
                 with: .color(.accentColor.opacity(0.85)))

        drawTimelineLabel(ctx: ctx, size: size, date: cutoff)
    }

    private func aggregate() -> [AlbumOrbit] {
        guard !entries.isEmpty else { return [] }
        struct AlbumBucket {
            var artist: String
            var album: String
            var totalPlays: Int
            var serviceTally: [String: Int]
            var trackPlays: [String: Int]
            var trackFirstPlay: [String: Date]
        }
        var buckets: [String: AlbumBucket] = [:]
        for e in entries where !e.album.isEmpty && !e.title.isEmpty {
            let key = "\(e.album)|\(e.artist)"
            let svc = serviceBucket(for: e.sourceURI)
            if var b = buckets[key] {
                b.totalPlays += 1
                b.serviceTally[svc, default: 0] += 1
                b.trackPlays[e.title, default: 0] += 1
                if let fp = b.trackFirstPlay[e.title] {
                    if e.timestamp < fp { b.trackFirstPlay[e.title] = e.timestamp }
                } else {
                    b.trackFirstPlay[e.title] = e.timestamp
                }
                buckets[key] = b
            } else {
                buckets[key] = AlbumBucket(
                    artist: e.artist, album: e.album,
                    totalPlays: 1,
                    serviceTally: [svc: 1],
                    trackPlays: [e.title: 1],
                    trackFirstPlay: [e.title: e.timestamp]
                )
            }
        }
        let topN = 14
        let topAlbums = buckets.sorted { $0.value.totalPlays > $1.value.totalPlays }
            .prefix(topN)
        return topAlbums.map { (_, b) in
            let stars = b.trackPlays.map { (title, plays) in
                TrackStar(title: title,
                          firstPlay: b.trackFirstPlay[title] ?? Date(),
                          plays: plays)
            }.sorted { $0.firstPlay < $1.firstPlay }
            let label = b.artist.isEmpty ? b.album : "\(b.album) — \(b.artist)"
            let dom = b.serviceTally.max { $0.value < $1.value }?.key ?? "Other"
            return AlbumOrbit(albumLabel: label, totalPlays: b.totalPlays,
                              dominantService: dom, tracks: stars)
        }
    }
}

// MARK: - Listening Fingerprint
//
// A single composite glyph — your "musical signature" — designed so two
// different users get visibly different glyphs. Layers of meaning radiate from
// the centre outward.
//
// Encoding map:
//   • Inner hand (clock)   = peak listening hour (12 = midnight, clockwise)
//   • Hand length          = peak-hour intensity (max bin / mean across hours)
//   • Inner ring (pie)     = service play-share distribution (Spotify / Plex / …)
//   • Mid ring breathing   = total listening hours (size pulses with magnitude)
//   • Outer wedges         = top-7 artists; wedge angular width = play share
//   • Wedge colour         = service most associated with each artist
//   • Background quadrant  = weekend-vs-weekday balance gradient (blue→amber)
//   • Outer rim glints     = days with starred plays in the visible scrub range

private struct FingerprintVisualization: View {
    let entries: [PlayHistoryEntry]
    let phase: Double

    private struct Snapshot {
        let total: Int
        let peakHour: Int
        let peakIntensity: Double
        let services: [(name: String, share: Double)]
        let topArtists: [(name: String, share: Double, color: Color)]
        let weekendShare: Double  // 0…1
        let starredDates: [Date]
        let range: TimelineRange
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Listening Fingerprint").font(.headline)
                Spacer()
                Text("Your signature: peak hour (hand), services (inner ring), top artists (outer wedges), weekend balance (background), starred days (rim glints).")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 6)
            Canvas { ctx, size in
                draw(ctx: ctx, size: size)
            }
        }
    }

    private func draw(ctx: GraphicsContext, size: CGSize) {
        guard let snap = aggregate() else {
            ctx.draw(Text("Building fingerprint…").font(.title3).foregroundStyle(.secondary),
                     at: CGPoint(x: size.width / 2, y: size.height / 2))
            return
        }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let outerR = min(size.width, size.height) * 0.42
        let midR = outerR * 0.66
        let innerR = outerR * 0.42
        let coreR = outerR * 0.18

        // Background — diagonal weekday/weekend tint behind everything.
        let bgRect = CGRect(origin: .zero, size: size)
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: 50))
            let weekendAmber = Color(hue: 0.10, saturation: 0.55, brightness: 0.32)
            let weekdayBlue  = Color(hue: 0.62, saturation: 0.45, brightness: 0.20)
            let stops = [
                Gradient.Stop(color: weekdayBlue.opacity(0.7), location: 0.0),
                Gradient.Stop(color: weekendAmber.opacity(0.7 * snap.weekendShare + 0.15),
                              location: 1.0),
            ]
            layer.fill(Path(bgRect),
                       with: .linearGradient(Gradient(stops: stops),
                                             startPoint: .zero,
                                             endPoint: CGPoint(x: size.width, y: size.height)))
        }

        // ── Outer wedges: top-7 artists, angular width = play share ──
        var startAngle: Double = -.pi / 2
        for artist in snap.topArtists {
            let sweep: Double = artist.share * 2 * .pi
            let endAngle = startAngle + sweep
            // Filled wedge between midR and outerR.
            var wedge = Path()
            wedge.move(to: CGPoint(x: center.x + midR * CGFloat(cos(startAngle)),
                                   y: center.y + midR * CGFloat(sin(startAngle))))
            wedge.addLine(to: CGPoint(x: center.x + outerR * CGFloat(cos(startAngle)),
                                      y: center.y + outerR * CGFloat(sin(startAngle))))
            wedge.addArc(center: center, radius: outerR,
                         startAngle: .radians(startAngle),
                         endAngle: .radians(endAngle), clockwise: false)
            wedge.addLine(to: CGPoint(x: center.x + midR * CGFloat(cos(endAngle)),
                                      y: center.y + midR * CGFloat(sin(endAngle))))
            wedge.addArc(center: center, radius: midR,
                         startAngle: .radians(endAngle),
                         endAngle: .radians(startAngle), clockwise: true)
            ctx.fill(wedge, with: .color(artist.color.opacity(0.55)))
            // Subtle outer rim highlight.
            var rim = Path()
            rim.addArc(center: center, radius: outerR,
                       startAngle: .radians(startAngle),
                       endAngle: .radians(endAngle), clockwise: false)
            ctx.stroke(rim, with: .color(artist.color.opacity(0.95)), lineWidth: 1.2)

            // Artist label at the wedge midpoint (just inside the rim).
            let mid = (startAngle + endAngle) / 2
            let labelR = (midR + outerR) / 2
            let lp = CGPoint(x: center.x + labelR * CGFloat(cos(mid)),
                             y: center.y + labelR * CGFloat(sin(mid)))
            ctx.draw(Text(shortLabel(artist.name)).font(.caption2.bold()).foregroundStyle(.white),
                     at: lp)

            startAngle = endAngle
        }

        // ── Inner ring: services (filled donut) ──
        var serviceAngle: Double = -.pi / 2
        for svc in snap.services {
            let sweep: Double = svc.share * 2 * .pi
            let end = serviceAngle + sweep
            var ring = Path()
            ring.move(to: CGPoint(x: center.x + innerR * CGFloat(cos(serviceAngle)),
                                  y: center.y + innerR * CGFloat(sin(serviceAngle))))
            ring.addArc(center: center, radius: midR,
                        startAngle: .radians(serviceAngle),
                        endAngle: .radians(end), clockwise: false)
            ring.addArc(center: center, radius: innerR,
                        startAngle: .radians(end),
                        endAngle: .radians(serviceAngle), clockwise: true)
            ctx.fill(ring, with: .color(serviceColor(for: svc.name).opacity(0.78)))
            serviceAngle = end
        }

        // ── Core: breathing nucleus, size = total plays ──
        let breath = 0.5 + 0.5 * sin(Date().timeIntervalSinceReferenceDate * 1.5)
        let liveCoreR = coreR + CGFloat(breath) * 4
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: 16))
            layer.fill(Path(ellipseIn: CGRect(x: center.x - liveCoreR * 1.6,
                                              y: center.y - liveCoreR * 1.6,
                                              width: liveCoreR * 3.2,
                                              height: liveCoreR * 3.2)),
                       with: .color(.accentColor.opacity(0.6)))
        }
        ctx.fill(Path(ellipseIn: CGRect(x: center.x - liveCoreR, y: center.y - liveCoreR,
                                        width: liveCoreR * 2, height: liveCoreR * 2)),
                 with: .color(.accentColor.opacity(0.95)))

        // ── Peak-hour clock hand ──
        let hourAngle = (Double(snap.peakHour) / 24.0) * 2 * .pi - .pi / 2
        let handLen = innerR * (0.5 + min(snap.peakIntensity, 4.0) / 8.0)
        var hand = Path()
        hand.move(to: center)
        hand.addLine(to: CGPoint(x: center.x + handLen * CGFloat(cos(hourAngle)),
                                 y: center.y + handLen * CGFloat(sin(hourAngle))))
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: 5))
            layer.stroke(hand, with: .color(.white.opacity(0.85)), lineWidth: 6)
        }
        ctx.stroke(hand, with: .color(.white.opacity(0.95)), lineWidth: 1.8)

        // ── Outer rim glints: starred days within the scrub range ──
        if !snap.starredDates.isEmpty {
            for d in snap.starredDates {
                let frac = d.timeIntervalSince(snap.range.first) / max(snap.range.duration, 1)
                guard frac <= phase.clamped01 else { continue }
                let theta = frac * 2 * .pi - .pi / 2
                let p = CGPoint(x: center.x + (outerR + 8) * CGFloat(cos(theta)),
                                y: center.y + (outerR + 8) * CGFloat(sin(theta)))
                ctx.drawLayer { layer in
                    layer.addFilter(.blur(radius: 3))
                    layer.fill(Path(ellipseIn: CGRect(x: p.x - 3.5, y: p.y - 3.5,
                                                      width: 7, height: 7)),
                               with: .color(.yellow.opacity(0.85)))
                }
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 1.5, y: p.y - 1.5, width: 3, height: 3)),
                         with: .color(.yellow))
            }
        }

        // Hour ticks at 0/6/12/18 around the rim — orientation only.
        for h in stride(from: 0, to: 24, by: 6) {
            let theta = (Double(h) / 24.0) * 2 * .pi - .pi / 2
            let inner = CGPoint(x: center.x + (outerR + 4) * CGFloat(cos(theta)),
                                y: center.y + (outerR + 4) * CGFloat(sin(theta)))
            let outer = CGPoint(x: center.x + (outerR + 14) * CGFloat(cos(theta)),
                                y: center.y + (outerR + 14) * CGFloat(sin(theta)))
            var p = Path(); p.move(to: inner); p.addLine(to: outer)
            ctx.stroke(p, with: .color(.secondary.opacity(0.45)), lineWidth: 0.8)
            ctx.draw(Text("\(h)").font(.caption2).foregroundStyle(.secondary),
                     at: CGPoint(x: center.x + (outerR + 26) * CGFloat(cos(theta)),
                                 y: center.y + (outerR + 26) * CGFloat(sin(theta))))
        }
    }

    private func shortLabel(_ name: String) -> String {
        if name.count <= 14 { return name }
        return String(name.prefix(13)) + "…"
    }

    private func aggregate() -> Snapshot? {
        guard let range = timelineRange(for: entries) else { return nil }
        let cal = Calendar.current
        let cutoff = range.date(at: phase.clamped01)
        let visible = entries.filter { $0.timestamp <= cutoff }
        guard !visible.isEmpty else { return nil }

        // Peak hour.
        var hourCounts = [Int](repeating: 0, count: 24)
        for e in visible { hourCounts[cal.component(.hour, from: e.timestamp)] += 1 }
        let peakHour = hourCounts.indices.max(by: { hourCounts[$0] < hourCounts[$1] }) ?? 12
        let mean = max(1, Double(visible.count) / 24.0)
        let peakIntensity = Double(hourCounts[peakHour]) / mean

        // Service shares.
        var svcCounts: [String: Int] = [:]
        for e in visible {
            let s = serviceBucket(for: e.sourceURI)
            svcCounts[s, default: 0] += 1
        }
        let svcTotal = max(1, svcCounts.values.reduce(0, +))
        let services = svcCounts.sorted { $0.value > $1.value }
            .map { (name: $0.key, share: Double($0.value) / Double(svcTotal)) }

        // Top-7 artists with their dominant service colour.
        var artistCounts: [String: Int] = [:]
        var artistService: [String: [String: Int]] = [:]
        for e in visible where !e.artist.isEmpty {
            artistCounts[e.artist, default: 0] += 1
            let s = serviceBucket(for: e.sourceURI)
            artistService[e.artist, default: [:]][s, default: 0] += 1
        }
        let topArtistRaw = artistCounts.sorted { $0.value > $1.value }.prefix(7)
        let topArtistTotal = max(1, topArtistRaw.reduce(0) { $0 + $1.value })
        let topArtists = topArtistRaw.map { (name, count) -> (name: String, share: Double, color: Color) in
            let dom = artistService[name]?.max { $0.value < $1.value }?.key ?? "Other"
            return (name: name,
                    share: Double(count) / Double(topArtistTotal),
                    color: serviceColor(for: dom))
        }

        // Weekend share.
        let weekendCount = visible.filter {
            let wd = cal.component(.weekday, from: $0.timestamp)
            return wd == 1 || wd == 7
        }.count
        let weekendShare = Double(weekendCount) / Double(visible.count)

        // Starred dates.
        let starredDates = visible.filter { $0.starred }.map { $0.timestamp }

        return Snapshot(
            total: visible.count,
            peakHour: peakHour,
            peakIntensity: peakIntensity,
            services: services,
            topArtists: topArtists,
            weekendShare: weekendShare,
            starredDates: starredDates,
            range: range
        )
    }
}

// =============================================================================
// MARK: - Helpers shared by new viz
// =============================================================================

private extension Double {
    var clamped01: Double { max(0, min(1, self)) }
}

/// Service-bucket key derived from a source URI. Matches the buckets used by
/// the existing hyperbolic viz so colours stay consistent across tabs.
private func serviceBucket(for uri: String?) -> String {
    let l = (uri ?? "").lowercased()
    if l.contains("sid=12") || l.contains("spotify") { return "Spotify" }
    if l.contains("sid=204") { return "Apple Music" }
    if l.contains("sid=254") || l.contains("tunein") { return "TuneIn" }
    if l.contains("sid=212") { return "Amazon" }
    if l.contains("sid=303") { return "Plex" }
    if l.contains("sid=144") { return "YouTube" }
    if l.contains("x-file-cifs") { return "Local" }
    return "Other"
}

// MARK: - Gource (days as nodes, plays accumulate as dots)
//
// Each day in the history is a cell in a calendar grid. As the scrub time
// advances chronologically through the timeline, every play lands as a
// small coloured dot inside its day's cell (service colour). Days fill up
// with more dots the more you listened that day. The current-scrub day is
// ringed so you can see the "playhead" walking through history.
//
// Reading the view: busy days become dense patches; quiet days stay mostly
// empty; the overall constellation shows the rhythm of your listening over
// weeks and months at a glance.

private struct GourceVisualization: View {
    let entries: [PlayHistoryEntry]
    let phase: Double

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Days Constellation").font(.headline)
                Spacer()
                Text("Each cell = 1 day. Dots = plays, colour = service. Scrubber walks through history.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 6)
            Canvas { ctx, size in draw(ctx: ctx, size: size) }
        }
    }

    private func draw(ctx: GraphicsContext, size: CGSize) {
        guard !entries.isEmpty, let range = timelineRange(for: entries) else {
            ctx.draw(Text("No history yet").font(.title3).foregroundStyle(.secondary),
                     at: CGPoint(x: size.width / 2, y: size.height / 2))
            return
        }
        let cal = Calendar.current

        // Grid runs from the first-day-of-first-week to last-day-of-last-week
        // so columns always align to Sun-Sat.
        guard let startDay = cal.dateInterval(of: .weekOfYear, for: range.first)?.start,
              let endDay = cal.dateInterval(of: .weekOfYear, for: range.last)?.end else { return }
        let totalDays = cal.dateComponents([.day], from: startDay, to: endDay).day ?? 0
        guard totalDays > 0 else { return }
        let weeks = (totalDays + 6) / 7

        let leftPad: CGFloat = 40
        let topPad: CGFloat = 34
        let bottomPad: CGFloat = 30
        let rightPad: CGFloat = 20

        let plotW = size.width - leftPad - rightPad
        let cellW = min(32, plotW / 7)
        let cellH = cellW
        let plotH = cellH * CGFloat(weeks) + CGFloat(weeks - 1) * 3
        let startY = max(topPad, (size.height - plotH - bottomPad) / 2)

        let currentHistoryTime = range.date(at: phase)
        let scrubDay = cal.startOfDay(for: currentHistoryTime)

        // Draw cell backgrounds + weekday/month labels
        let weekdayLabels = ["S", "M", "T", "W", "T", "F", "S"]
        for d in 0..<7 {
            ctx.draw(Text(weekdayLabels[d]).font(.caption2).foregroundStyle(.tertiary),
                     at: CGPoint(x: leftPad + (CGFloat(d) + 0.5) * (cellW + 2),
                                 y: startY - 14))
        }
        let mf = DateFormatter(); mf.dateFormat = "MMM"; mf.locale = L10n.currentLocale
        var lastMonth = -1
        for w in 0..<weeks {
            guard let wd = cal.date(byAdding: .day, value: w * 7, to: startDay) else { continue }
            let m = cal.component(.month, from: wd)
            if m != lastMonth {
                lastMonth = m
                ctx.draw(Text(mf.string(from: wd)).font(.caption2).foregroundStyle(.tertiary),
                         at: CGPoint(x: leftPad - 26,
                                     y: startY + (CGFloat(w) + 0.5) * (cellH + 3)),
                         anchor: .leading)
            }
        }
        for w in 0..<weeks {
            for d in 0..<7 {
                guard let cellDay = cal.date(byAdding: .day, value: w * 7 + d, to: startDay) else { continue }
                let x = leftPad + CGFloat(d) * (cellW + 2)
                let y = startY + CGFloat(w) * (cellH + 3)
                let rect = CGRect(x: x, y: y, width: cellW, height: cellH)
                let isPast = cellDay <= currentHistoryTime
                ctx.fill(Path(roundedRect: rect, cornerRadius: 3),
                         with: .color(.primary.opacity(isPast ? 0.08 : 0.03)))
                // Current-day highlight ring
                if cal.isDate(cellDay, inSameDayAs: scrubDay) {
                    ctx.stroke(Path(roundedRect: rect, cornerRadius: 3),
                               with: .color(.accentColor), lineWidth: 1.5)
                }
            }
        }

        // Scatter one dot per play inside its day's cell. Position within the
        // cell is derived from a stable hash of the entry id, so dots don't
        // jitter between frames. Only plays up to the scrubber show.
        for entry in entries {
            guard entry.timestamp <= currentHistoryTime else { continue }
            let day = cal.startOfDay(for: entry.timestamp)
            let daysFromStart = cal.dateComponents([.day], from: startDay, to: day).day ?? -1
            guard daysFromStart >= 0 else { continue }
            let w = daysFromStart / 7
            let d = daysFromStart % 7
            guard w >= 0, w < weeks, d >= 0, d < 7 else { continue }
            let x0 = leftPad + CGFloat(d) * (cellW + 2)
            let y0 = startY + CGFloat(w) * (cellH + 3)

            // Stable pseudo-random position inside cell
            let h = UInt32(truncatingIfNeeded: entry.id.hashValue &* 0x9E3779B1)
            let fx = CGFloat((h >> 8) & 0xFF) / 255.0
            let fy = CGFloat((h >> 16) & 0xFF) / 255.0
            let margin: CGFloat = 3
            let px = x0 + margin + fx * (cellW - margin * 2)
            let py = y0 + margin + fy * (cellH - margin * 2)

            // Dots landing near scrubber get a brief "bloom"
            let dt = abs(entry.timestamp.timeIntervalSince(currentHistoryTime))
            let bloomWindow = range.duration * 0.015
            let bloom = max(0, 1 - dt / bloomWindow)
            let r: CGFloat = 1.6 + CGFloat(bloom) * 2.0
            let color = serviceColor(for: entry.sourceURI)
            ctx.fill(Path(ellipseIn: CGRect(x: px - r, y: py - r, width: r * 2, height: r * 2)),
                     with: .color(color.opacity(0.55 + 0.4 * bloom)))
        }

        drawTimelineLabel(ctx: ctx, size: size, date: currentHistoryTime)
    }
}

// MARK: - Stream graph (progressively fills)

private struct StreamGraphVisualization: View {
    let entries: [PlayHistoryEntry]
    let phase: Double

    var body: some View {
        Canvas { ctx, size in
            draw(ctx: ctx, size: size)
        }
        .overlay(alignment: .bottomLeading) {
            Text("Daily listening hours per room, filled in over time.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(10)
        }
    }

    private func draw(ctx: GraphicsContext, size: CGSize) {
        guard !entries.isEmpty, let range = timelineRange(for: entries) else { return }
        let cal = Calendar.current
        var daysSet: Set<Date> = []
        var roomsSet: Set<String> = []
        var buckets: [Date: [String: Double]] = [:]
        for e in entries {
            let day = cal.startOfDay(for: e.timestamp)
            let room = displayRoom(e.groupName)
            guard !room.isEmpty else { continue }
            daysSet.insert(day)
            roomsSet.insert(room)
            let dur = e.duration > 0 ? e.duration : 180
            buckets[day, default: [:]][room, default: 0] += dur
        }
        let days = daysSet.sorted()
        let rooms = roomsSet.sorted()
        guard days.count > 1, !rooms.isEmpty else { return }

        let margin: CGFloat = 40
        let plotRect = CGRect(x: margin, y: 28,
                              width: size.width - margin * 2,
                              height: size.height - 68)

        let maxHours = days.map { d in (buckets[d] ?? [:]).values.reduce(0, +) / 3600.0 }.max() ?? 1

        // How far across the plot the animation has revealed. Maps phase
        // to the same history time everything else uses, then to an x
        // coordinate.
        let currentHistoryTime = range.date(at: phase)
        let revealedFraction: Double
        if let firstDay = days.first, let lastDay = days.last,
           lastDay > firstDay {
            revealedFraction = max(0, min(1,
                currentHistoryTime.timeIntervalSince(firstDay)
                / lastDay.timeIntervalSince(firstDay)))
        } else {
            revealedFraction = 1
        }
        let revealX = plotRect.minX + plotRect.width * CGFloat(revealedFraction)

        var lowerCurve = [CGPoint](repeating: .zero, count: days.count)
        for (i, _) in days.enumerated() {
            lowerCurve[i] = CGPoint(
                x: plotRect.minX + plotRect.width * CGFloat(i) / CGFloat(days.count - 1),
                y: plotRect.maxY
            )
        }

        // Draw stacked areas, then clip to revealed portion.
        for (ri, room) in rooms.enumerated() {
            var upperCurve = [CGPoint](repeating: .zero, count: days.count)
            for (i, day) in days.enumerated() {
                let hours = (buckets[day]?[room] ?? 0) / 3600.0
                let prev = lowerCurve[i]
                let y = prev.y - CGFloat(hours / maxHours) * plotRect.height
                upperCurve[i] = CGPoint(x: prev.x, y: y)
            }
            var path = Path()
            path.move(to: lowerCurve[0])
            for p in upperCurve { path.addLine(to: p) }
            for p in lowerCurve.reversed() { path.addLine(to: p) }
            path.closeSubpath()
            let color = roomColor(index: ri, total: rooms.count)
            var clipped = ctx
            clipped.clip(to: Path(CGRect(x: plotRect.minX, y: plotRect.minY,
                                          width: revealX - plotRect.minX,
                                          height: plotRect.height)))
            clipped.fill(path, with: .color(color.opacity(0.75)))
            lowerCurve = upperCurve
        }

        // Sweeping playhead line.
        var cursor = Path()
        cursor.move(to: CGPoint(x: revealX, y: plotRect.minY))
        cursor.addLine(to: CGPoint(x: revealX, y: plotRect.maxY))
        ctx.stroke(cursor, with: .color(.primary.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

        // Axis labels.
        ctx.draw(Text("\(Int(maxHours.rounded()))h").font(.caption2).foregroundStyle(.secondary),
                 at: CGPoint(x: 20, y: plotRect.minY))
        ctx.draw(Text("0").font(.caption2).foregroundStyle(.secondary),
                 at: CGPoint(x: 20, y: plotRect.maxY))

        let df = DateFormatter(); df.dateFormat = "MMM d"
        ctx.draw(Text(df.string(from: days.first!)).font(.caption2).foregroundStyle(.secondary),
                 at: CGPoint(x: plotRect.minX + 20, y: plotRect.maxY + 14))
        ctx.draw(Text(df.string(from: days.last!)).font(.caption2).foregroundStyle(.secondary),
                 at: CGPoint(x: plotRect.maxX - 20, y: plotRect.maxY + 14))

        // Legend.
        var legendY = plotRect.minY
        for (ri, room) in rooms.enumerated() {
            let swatch = Path(
                roundedRect: CGRect(x: plotRect.maxX - 150, y: legendY, width: 10, height: 10),
                cornerRadius: 2
            )
            ctx.fill(swatch, with: .color(roomColor(index: ri, total: rooms.count).opacity(0.85)))
            ctx.draw(Text(room).font(.caption2).foregroundStyle(.primary),
                     at: CGPoint(x: plotRect.maxX - 135 + 40, y: legendY + 5))
            legendY += 14
            if legendY > plotRect.maxY - 14 { break }
        }

        drawTimelineLabel(ctx: ctx, size: size, date: currentHistoryTime)
    }
}

// MARK: - Heatmap (cumulative fill)

private struct HeatmapVisualization: View {
    let entries: [PlayHistoryEntry]
    let phase: Double

    var body: some View {
        Canvas { ctx, size in
            draw(ctx: ctx, size: size)
        }
        .overlay(alignment: .bottomLeading) {
            Text("Cumulative plays through the scrub time, room × hour-of-day.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(10)
        }
    }

    private func draw(ctx: GraphicsContext, size: CGSize) {
        guard !entries.isEmpty, let range = timelineRange(for: entries) else { return }
        let cal = Calendar.current
        let cutoff = range.date(at: phase)

        var roomsSet: Set<String> = []
        var counts: [String: [Int: Int]] = [:]
        var fullMaxCount = 0  // across the full range — keeps scale stable as cells fill
        var tempFull: [String: [Int: Int]] = [:]

        for e in entries {
            let room = displayRoom(e.groupName)
            guard !room.isEmpty else { continue }
            roomsSet.insert(room)
            let h = cal.component(.hour, from: e.timestamp)
            tempFull[room, default: [:]][h, default: 0] += 1
            fullMaxCount = max(fullMaxCount, tempFull[room]![h]!)
            if e.timestamp <= cutoff {
                counts[room, default: [:]][h, default: 0] += 1
            }
        }
        let rooms = roomsSet.sorted()
        guard !rooms.isEmpty else { return }
        let maxCount = max(1, fullMaxCount)

        let leftPad: CGFloat = 120
        let topPad: CGFloat = 40
        let rightPad: CGFloat = 20
        let bottomPad: CGFloat = 48
        let plotW = size.width - leftPad - rightPad
        let plotH = size.height - topPad - bottomPad
        let cellW = plotW / 24
        let cellH = plotH / CGFloat(rooms.count)

        for (ri, room) in rooms.enumerated() {
            for h in 0..<24 {
                let c = counts[room]?[h] ?? 0
                let intensity = Double(c) / Double(maxCount)
                let x = leftPad + CGFloat(h) * cellW
                let y = topPad + CGFloat(ri) * cellH
                let rect = CGRect(x: x + 1, y: y + 1, width: cellW - 2, height: cellH - 2)
                let color = Color(hue: 0.6 - 0.15 * intensity,
                                  saturation: 0.7,
                                  brightness: 0.4 + 0.6 * intensity)
                ctx.fill(Path(rect), with: .color(color.opacity(0.2 + 0.8 * intensity)))
                if intensity > 0.5 {
                    ctx.draw(Text("\(c)").font(.caption2).foregroundStyle(.white),
                             at: CGPoint(x: rect.midX, y: rect.midY))
                }
            }
            ctx.draw(Text(room).font(.caption).foregroundStyle(.primary),
                     at: CGPoint(x: leftPad - 10, y: topPad + cellH * (CGFloat(ri) + 0.5)),
                     anchor: .trailing)
        }

        for h in stride(from: 0, to: 24, by: 2) {
            ctx.draw(Text("\(h)").font(.caption2).foregroundStyle(.secondary),
                     at: CGPoint(x: leftPad + (CGFloat(h) + 0.5) * cellW, y: topPad - 10))
        }
        ctx.draw(Text("Hour").font(.caption2).foregroundStyle(.tertiary),
                 at: CGPoint(x: leftPad + plotW / 2, y: topPad + plotH + 20))

        drawTimelineLabel(ctx: ctx, size: size, date: cutoff)
    }
}

// MARK: - Chord (arcs grow with accumulated plays)

private struct ChordVisualization: View {
    let entries: [PlayHistoryEntry]
    let phase: Double

    var body: some View {
        Canvas { ctx, size in
            draw(ctx: ctx, size: size)
        }
        .overlay(alignment: .bottomLeading) {
            Text("Top artists ↔ rooms. Arcs thicken as co-plays accumulate.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(10)
        }
    }

    private func draw(ctx: GraphicsContext, size: CGSize) {
        guard !entries.isEmpty, let range = timelineRange(for: entries) else { return }
        let cutoff = range.date(at: phase)

        // Top 10 artists across the full range (so the set doesn't churn as
        // time advances). Weights are only counted up to the cutoff so arcs
        // grow in over the animation.
        var fullCounts: [String: Int] = [:]
        for e in entries where !e.artist.isEmpty {
            fullCounts[e.artist, default: 0] += 1
        }
        let topArtists = Array(fullCounts.sorted { $0.value > $1.value }.prefix(10).map(\.key))
        let rooms = Array(Set(entries.map { displayRoom($0.groupName) })
            .filter { !$0.isEmpty }).sorted()
        guard !topArtists.isEmpty, !rooms.isEmpty else { return }

        var weights: [String: [String: Int]] = [:]
        var maxWeightFull = 1
        var tempFull: [String: [String: Int]] = [:]
        for e in entries {
            guard !e.artist.isEmpty, topArtists.contains(e.artist) else { continue }
            let r = displayRoom(e.groupName)
            guard !r.isEmpty else { continue }
            tempFull[e.artist, default: [:]][r, default: 0] += 1
            maxWeightFull = max(maxWeightFull, tempFull[e.artist]![r]!)
            if e.timestamp <= cutoff {
                weights[e.artist, default: [:]][r, default: 0] += 1
            }
        }

        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) * 0.36

        var artistPos: [String: CGPoint] = [:]
        var roomPos: [String: CGPoint] = [:]
        for (i, a) in topArtists.enumerated() {
            let frac = Double(i) / Double(max(1, topArtists.count - 1))
            let theta = .pi / 2 + frac * .pi
            artistPos[a] = CGPoint(
                x: center.x + CGFloat(cos(theta)) * radius,
                y: center.y + CGFloat(sin(theta)) * radius
            )
        }
        for (i, r) in rooms.enumerated() {
            let frac = Double(i) / Double(max(1, rooms.count - 1))
            let theta = -.pi / 2 + frac * .pi
            roomPos[r] = CGPoint(
                x: center.x + CGFloat(cos(theta)) * radius,
                y: center.y + CGFloat(sin(theta)) * radius
            )
        }

        for (a, rs) in weights {
            guard let pa = artistPos[a] else { continue }
            for (r, w) in rs {
                guard let pr = roomPos[r] else { continue }
                var p = Path()
                p.move(to: pa)
                p.addQuadCurve(to: pr, control: center)
                let alpha = 0.15 + 0.6 * (Double(w) / Double(maxWeightFull))
                let lw: CGFloat = 1 + 6 * (CGFloat(w) / CGFloat(maxWeightFull))
                ctx.stroke(p, with: .color(.accentColor.opacity(alpha)), lineWidth: lw)
            }
        }

        for (a, pt) in artistPos {
            let dot = Path(ellipseIn: CGRect(x: pt.x - 4, y: pt.y - 4, width: 8, height: 8))
            ctx.fill(dot, with: .color(.primary))
            ctx.draw(Text(a).font(.caption2).foregroundStyle(.primary),
                     at: CGPoint(x: pt.x - 10, y: pt.y), anchor: .trailing)
        }
        for (r, pt) in roomPos {
            let dot = Path(ellipseIn: CGRect(x: pt.x - 4, y: pt.y - 4, width: 8, height: 8))
            ctx.fill(dot, with: .color(.secondary))
            ctx.draw(Text(r).font(.caption2).foregroundStyle(.primary),
                     at: CGPoint(x: pt.x + 10, y: pt.y), anchor: .leading)
        }
        ctx.draw(Text("Artists").font(.caption).foregroundStyle(.tertiary),
                 at: CGPoint(x: center.x - radius - 60, y: 20))
        ctx.draw(Text("Rooms").font(.caption).foregroundStyle(.tertiary),
                 at: CGPoint(x: center.x + radius + 60, y: 20))

        drawTimelineLabel(ctx: ctx, size: size, date: cutoff)
    }
}

// MARK: - Racing bar chart (top artists rank over time)

private struct RacingBarsVisualization: View {
    let entries: [PlayHistoryEntry]
    let phase: Double

    var body: some View {
        Canvas { ctx, size in
            draw(ctx: ctx, size: size)
        }
        .overlay(alignment: .bottomLeading) {
            Text("Top artists by cumulative plays, ranked as history advances.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(10)
        }
    }

    private func draw(ctx: GraphicsContext, size: CGSize) {
        guard !entries.isEmpty, let range = timelineRange(for: entries) else { return }
        let cutoff = range.date(at: phase)

        // Tally plays per artist up to the cutoff.
        var counts: [String: Int] = [:]
        for e in entries where !e.artist.isEmpty && e.timestamp <= cutoff {
            counts[e.artist, default: 0] += 1
        }
        let top = counts.sorted { $0.value > $1.value }.prefix(10)
        guard !top.isEmpty else {
            ctx.draw(Text("Waiting for data\u{2026}").font(.title3).foregroundStyle(.secondary),
                     at: CGPoint(x: size.width / 2, y: size.height / 2))
            drawTimelineLabel(ctx: ctx, size: size, date: cutoff)
            return
        }
        let maxCount = top.first?.value ?? 1

        let leftPad: CGFloat = 180
        let rightPad: CGFloat = 60
        let topPad: CGFloat = 40
        let bottomPad: CGFloat = 40
        let plotW = size.width - leftPad - rightPad
        let plotH = size.height - topPad - bottomPad
        let rowH = plotH / CGFloat(max(top.count, 1))

        for (rank, entry) in top.enumerated() {
            let y = topPad + CGFloat(rank) * rowH + rowH * 0.5
            let width = plotW * CGFloat(entry.value) / CGFloat(maxCount)
            let barRect = CGRect(
                x: leftPad,
                y: y - rowH * 0.35,
                width: max(4, width),
                height: rowH * 0.7
            )
            // Gradient per rank — top bars are brighter.
            let hue = Double(rank) / Double(top.count)
            let color = Color(hue: 0.55 - hue * 0.55, saturation: 0.7, brightness: 0.85)
            ctx.fill(Path(roundedRect: barRect, cornerRadius: 4), with: .color(color))
            // Artist name on the left.
            ctx.draw(Text(entry.key).font(.callout.bold()).foregroundStyle(.primary),
                     at: CGPoint(x: leftPad - 10, y: y), anchor: .trailing)
            // Count on the right tip of the bar.
            ctx.draw(Text("\(entry.value)").font(.caption.monospaced()).foregroundStyle(.secondary),
                     at: CGPoint(x: barRect.maxX + 8, y: y), anchor: .leading)
            // Rank numeral.
            ctx.draw(Text("#\(rank + 1)").font(.caption2.monospaced()).foregroundStyle(.tertiary),
                     at: CGPoint(x: 28, y: y), anchor: .leading)
        }

        drawTimelineLabel(ctx: ctx, size: size, date: cutoff)
    }
}

// MARK: - Calendar heatmap (GitHub-style weekly grid)

private struct CalendarHeatmapVisualization: View {
    let entries: [PlayHistoryEntry]
    let phase: Double

    var body: some View {
        Canvas { ctx, size in
            draw(ctx: ctx, size: size)
        }
        .overlay(alignment: .bottomLeading) {
            Text("Each cell = one day. Brighter = more listening time.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(10)
        }
    }

    private func draw(ctx: GraphicsContext, size: CGSize) {
        guard !entries.isEmpty, let range = timelineRange(for: entries) else { return }
        let cal = Calendar.current
        // Always render the full year containing the history range, so the
        // grid doesn't change shape as the scrub advances. Bucketed by
        // start-of-day.
        var totals: [Date: Double] = [:]
        for e in entries {
            let day = cal.startOfDay(for: e.timestamp)
            totals[day, default: 0] += e.duration > 0 ? e.duration : 180
        }
        let maxSeconds = totals.values.max() ?? 1

        // Range from first-day-of-first-week to last-day-of-last-week.
        guard let startDay = cal.dateInterval(of: .weekOfYear, for: range.first)?.start,
              let endDay = cal.dateInterval(of: .weekOfYear, for: range.last)?.end else { return }
        let dayCount = cal.dateComponents([.day], from: startDay, to: endDay).day ?? 0
        guard dayCount > 0 else { return }
        let weeks = (dayCount + 6) / 7

        let leftPad: CGFloat = 60
        let topPad: CGFloat = 48
        let bottomPad: CGFloat = 40
        let plotW = size.width - leftPad - 20
        let cellW = min(18, plotW / CGFloat(weeks) - 2)
        let cellH = cellW
        let plotH = cellH * 7 + 6 * 2
        let startY = max(topPad, (size.height - plotH - bottomPad) / 2)

        let cutoff = range.date(at: phase)

        for w in 0..<weeks {
            for d in 0..<7 {
                guard let cellDay = cal.date(byAdding: .day, value: w * 7 + d, to: startDay) else { continue }
                let seconds = totals[cal.startOfDay(for: cellDay)] ?? 0
                let x = leftPad + CGFloat(w) * (cellW + 2)
                let y = startY + CGFloat(d) * (cellH + 2)
                let rect = CGRect(x: x, y: y, width: cellW, height: cellH)
                let visible = cellDay <= cutoff
                if !visible {
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 2),
                             with: .color(.primary.opacity(0.05)))
                    continue
                }
                let intensity = seconds > 0 ? min(1, seconds / maxSeconds) : 0
                let color = Color(
                    hue: 0.35 - intensity * 0.1,
                    saturation: 0.6,
                    brightness: 0.25 + intensity * 0.7
                )
                let bg = Color.primary.opacity(0.08)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 2),
                         with: .color(seconds > 0 ? color : bg))
            }
        }

        // Weekday labels.
        let dayLabels = ["S", "M", "T", "W", "T", "F", "S"]
        for (d, label) in dayLabels.enumerated() where d % 2 == 1 {
            ctx.draw(Text(label).font(.caption2).foregroundStyle(.secondary),
                     at: CGPoint(x: leftPad - 12,
                                 y: startY + CGFloat(d) * (cellH + 2) + cellH / 2),
                     anchor: .trailing)
        }

        // Month labels spread along the top.
        let df = DateFormatter(); df.dateFormat = "MMM"
        var lastMonth = -1
        for w in stride(from: 0, to: weeks, by: 1) {
            guard let weekStart = cal.date(byAdding: .day, value: w * 7, to: startDay) else { continue }
            let month = cal.component(.month, from: weekStart)
            if month != lastMonth {
                lastMonth = month
                let x = leftPad + CGFloat(w) * (cellW + 2) + cellW / 2
                ctx.draw(Text(df.string(from: weekStart)).font(.caption2).foregroundStyle(.secondary),
                         at: CGPoint(x: x, y: startY - 14))
            }
        }

        drawTimelineLabel(ctx: ctx, size: size, date: cutoff)
    }
}

// MARK: - Spiral timeline (time coils outward)

private struct SpiralTimelineVisualization: View {
    let entries: [PlayHistoryEntry]
    let phase: Double

    var body: some View {
        Canvas { ctx, size in
            draw(ctx: ctx, size: size)
        }
        .overlay(alignment: .bottomLeading) {
            Text("Time spirals outward. Each dot = one play, coloured by service.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(10)
        }
    }

    private func draw(ctx: GraphicsContext, size: CGSize) {
        guard !entries.isEmpty, let range = timelineRange(for: entries) else { return }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let maxR = min(size.width, size.height) * 0.42
        let minR: CGFloat = 12
        let turns: Double = 6  // total turns across the full history

        // Spiral guide.
        var guide = Path()
        let guideSteps = 600
        for i in 0...guideSteps {
            let t = Double(i) / Double(guideSteps)
            let r = minR + (maxR - minR) * CGFloat(t)
            let theta = turns * 2 * .pi * t - .pi / 2
            let pt = CGPoint(
                x: center.x + r * CGFloat(cos(theta)),
                y: center.y + r * CGFloat(sin(theta))
            )
            if i == 0 { guide.move(to: pt) } else { guide.addLine(to: pt) }
        }
        ctx.stroke(guide, with: .color(.secondary.opacity(0.12)), lineWidth: 0.5)

        // Plot each entry. t in [0,1] relative to history range.
        for e in entries {
            let t = e.timestamp.timeIntervalSince(range.first) / range.duration
            guard t <= phase else { continue }
            let r = minR + (maxR - minR) * CGFloat(t)
            let theta = turns * 2 * .pi * t - .pi / 2
            let pt = CGPoint(
                x: center.x + r * CGFloat(cos(theta)),
                y: center.y + r * CGFloat(sin(theta))
            )
            let color = serviceColor(for: e.sourceURI)
            let age = phase - t
            let alpha = 0.35 + 0.6 * max(0, 1 - age * 3)  // fade slightly as scrub moves away
            let size: CGFloat = 3.5
            let rect = CGRect(x: pt.x - size, y: pt.y - size, width: size * 2, height: size * 2)
            ctx.fill(Path(ellipseIn: rect), with: .color(color.opacity(alpha)))
        }

        drawTimelineLabel(ctx: ctx, size: size, date: range.date(at: phase))
    }
}

// MARK: - Listening Clock (2D polar: hour × day)
//
// Replaces the prior SceneKit "orbit" view, which was slow and didn't
// encode anything useful. This is a polar chart where
//   • angle       = hour of day (0h at top, clockwise)
//   • radius      = how long ago the play happened (centre = today,
//                   rim = start of history)
//   • dot colour  = music service
// Running the scrubber draws in your plays in chronological order, so the
// shape of your listening (morning person, night owl, weekends only) shows
// up as clusters in specific angular regions. An accent-coloured hand
// points to the "current" hour as the scrub advances.

private struct OrbitalVisualization: View {
    let entries: [PlayHistoryEntry]
    let phase: Double

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Listening Clock").font(.headline)
                Spacer()
                Text("Angle = hour of day (0 at top). Radius = how recent (centre = latest). Colour = service.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 6)
            Canvas { ctx, size in draw(ctx: ctx, size: size) }
        }
    }

    private func draw(ctx: GraphicsContext, size: CGSize) {
        guard !entries.isEmpty, let range = timelineRange(for: entries) else {
            ctx.draw(Text("No history yet").font(.title3).foregroundStyle(.secondary),
                     at: CGPoint(x: size.width / 2, y: size.height / 2))
            return
        }
        let cal = Calendar.current
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let maxR = min(size.width, size.height) * 0.42
        let minR: CGFloat = 30

        // Hour spokes + labels every 3 hours
        for h in 0..<24 {
            let theta = Double(h) / 24 * 2 * .pi - .pi / 2
            var p = Path()
            p.move(to: CGPoint(x: center.x + CGFloat(cos(theta)) * minR,
                               y: center.y + CGFloat(sin(theta)) * minR))
            p.addLine(to: CGPoint(x: center.x + CGFloat(cos(theta)) * maxR,
                                  y: center.y + CGFloat(sin(theta)) * maxR))
            let isMajor = (h % 6 == 0)
            ctx.stroke(p, with: .color(.secondary.opacity(isMajor ? 0.25 : 0.08)),
                       lineWidth: isMajor ? 0.8 : 0.4)
            if h % 3 == 0 {
                let labelR = maxR + 14
                let lp = CGPoint(x: center.x + CGFloat(cos(theta)) * labelR,
                                 y: center.y + CGFloat(sin(theta)) * labelR)
                ctx.draw(Text("\(h)").font(.caption2).foregroundStyle(.secondary), at: lp)
            }
        }

        // Week rings — one thin ring every 7 days so you have a radial scale
        let totalDays = range.duration / 86400
        let weekCount = max(1, Int(ceil(totalDays / 7)))
        for w in 0...weekCount {
            let ageFrac = Double(w * 7) / max(totalDays, 1)
            guard ageFrac <= 1 else { continue }
            let r = minR + (maxR - minR) * CGFloat(ageFrac)
            ctx.stroke(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r,
                                              width: r * 2, height: r * 2)),
                       with: .color(.secondary.opacity(0.08)), lineWidth: 0.5)
        }

        // Centre label (= latest date)
        let df = DateFormatter(); df.dateFormat = "MMM d"; df.locale = L10n.currentLocale
        ctx.draw(Text("latest").font(.caption2).foregroundStyle(.tertiary),
                 at: CGPoint(x: center.x, y: center.y - 8))
        ctx.draw(Text(df.string(from: range.last)).font(.caption2.monospaced())
                    .foregroundStyle(.secondary),
                 at: CGPoint(x: center.x, y: center.y + 6))

        let currentHistoryTime = range.date(at: phase)

        // Plot plays up to the scrubber as colored dots. Newest = near centre.
        for entry in entries {
            guard entry.timestamp <= currentHistoryTime else { continue }
            let hour = Double(cal.component(.hour, from: entry.timestamp))
                     + Double(cal.component(.minute, from: entry.timestamp)) / 60.0
            let theta = hour / 24 * 2 * .pi - .pi / 2
            // Radius: 0 (at newest edge) = minR, 1 (at oldest edge) = maxR.
            // So recent plays are inside, old plays at the rim.
            let ageFrac = 1.0 - (entry.timestamp.timeIntervalSince(range.first) / range.duration)
            let r = minR + (maxR - minR) * CGFloat(ageFrac)
            let pt = CGPoint(x: center.x + CGFloat(cos(theta)) * r,
                             y: center.y + CGFloat(sin(theta)) * r)
            // Bloom effect within the scrubber window
            let dt = abs(entry.timestamp.timeIntervalSince(currentHistoryTime))
            let bloom = max(0, 1 - dt / (range.duration * 0.012))
            let dotR: CGFloat = 2.2 + CGFloat(bloom) * 2.5
            let color = serviceColor(for: entry.sourceURI)
            ctx.fill(Path(ellipseIn: CGRect(x: pt.x - dotR, y: pt.y - dotR,
                                            width: dotR * 2, height: dotR * 2)),
                     with: .color(color.opacity(0.55 + 0.4 * bloom)))
        }

        // Scrubber "hand" at the current hour
        let nowHour = Double(cal.component(.hour, from: currentHistoryTime))
                    + Double(cal.component(.minute, from: currentHistoryTime)) / 60.0
        let handTheta = nowHour / 24 * 2 * .pi - .pi / 2
        var hand = Path()
        hand.move(to: CGPoint(x: center.x + CGFloat(cos(handTheta)) * minR,
                              y: center.y + CGFloat(sin(handTheta)) * minR))
        hand.addLine(to: CGPoint(x: center.x + CGFloat(cos(handTheta)) * maxR,
                                 y: center.y + CGFloat(sin(handTheta)) * maxR))
        ctx.stroke(hand, with: .color(.accentColor.opacity(0.75)), lineWidth: 2)

        drawTimelineLabel(ctx: ctx, size: size, date: currentHistoryTime)
    }
}

// MARK: - Trail (slime mold literally replaying your listening order)
//
// Top artists are placed on a ring (nodes sized by play count). A small
// swarm of "slimes" crawls through your actual listening history in
// chronological order — each slime is at a slightly different position in
// the sequence, so you see several parallel playbacks. Every time a slime
// hits a new play, it glides from the previous artist's node to the next
// play's artist, leaving a fading trail colored by the service. The shape
// that emerges is literally the path your listening took through your top
// artists over time: tight loops = binge sessions, long straight runs =
// hopping between artists, dense edges = pairs you play together.

@MainActor
private final class TrailSim {
    struct Node { let point: CGPoint; let artist: String; let count: Int }
    struct Slime {
        var x: Double           // current position
        var y: Double
        var index: Int          // position in the ordered play list
        var speed: Double       // plays advanced per frame
        var color: Color        // current segment colour (service of latest play)
    }
    var nodes: [Node] = []
    var artistIndex: [String: Int] = [:]
    /// Chronological list of plays restricted to top-artists (so slimes can
    /// always find a target). Each entry: (node index, service colour).
    var playOrder: [(Int, Color)] = []
    var slimes: [Slime] = []
    var trails: [(p: CGPoint, color: Color, life: Double)] = []  // life 0..1, decays
    var built = false

    func prepare(entries: [PlayHistoryEntry], in size: CGSize) {
        guard !built, size.width > 100 else { return }
        var counts: [String: Int] = [:]
        for e in entries where !e.artist.isEmpty { counts[e.artist, default: 0] += 1 }
        let top = counts.sorted { $0.value > $1.value }.prefix(14)
        guard !top.isEmpty else { built = true; return }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let r = min(size.width, size.height) * 0.34

        let topArr = Array(top)
        var builtNodes: [Node] = []
        builtNodes.reserveCapacity(topArr.count)
        for (i, kv) in topArr.enumerated() {
            let theta = Double(i) / Double(topArr.count) * .pi * 2 - .pi / 2
            let px = center.x + CGFloat(cos(theta)) * r
            let py = center.y + CGFloat(sin(theta)) * r
            builtNodes.append(Node(point: CGPoint(x: px, y: py),
                                   artist: kv.key, count: kv.value))
            artistIndex[kv.key] = i
        }
        nodes = builtNodes
        // Chronological list of entries filtered to top artists.
        playOrder = entries.compactMap { e in
            guard let idx = artistIndex[e.artist] else { return nil }
            return (idx, serviceColor(for: e.sourceURI))
        }
        guard !playOrder.isEmpty else { built = true; return }
        // Spawn ~6 slimes at different starting points so multiple
        // parallel replays are visible. Each has a slightly different speed
        // for visual richness.
        let startPositions = stride(from: 0, to: playOrder.count,
                                    by: max(1, playOrder.count / 6))
        slimes = startPositions.map { startIdx in
            let (nodeIdx, color) = playOrder[startIdx]
            let p = nodes[nodeIdx].point
            return Slime(x: Double(p.x), y: Double(p.y),
                         index: startIdx,
                         speed: 0.15 + Double((startIdx % 5)) * 0.04,
                         color: color)
        }
        built = true
    }

    func step() {
        guard !nodes.isEmpty, !playOrder.isEmpty else { return }
        for i in 0..<slimes.count {
            var s = slimes[i]
            let currentIdx = Int(s.index.clamped(to: 0...(playOrder.count - 1)))
            let target = nodes[playOrder[currentIdx].0].point
            let dx = Double(target.x) - s.x
            let dy = Double(target.y) - s.y
            let dist = (dx * dx + dy * dy).squareRoot()
            if dist < 6 {
                // Reached the current target — advance to the next play in history
                s.index += 1
                if s.index >= playOrder.count { s.index = 0 }
                s.color = playOrder[Int(s.index.clamped(to: 0...(playOrder.count - 1)))].1
            } else {
                // Glide toward the target, leaving a trail
                let step = 2.0 + s.speed * 6
                s.x += (dx / dist) * step
                s.y += (dy / dist) * step
                trails.append((p: CGPoint(x: s.x, y: s.y), color: s.color, life: 1.0))
            }
            slimes[i] = s
        }
        // Age existing trails
        for j in 0..<trails.count { trails[j].life *= 0.985 }
        trails.removeAll { $0.life < 0.02 }
        if trails.count > 3500 { trails.removeFirst(trails.count - 3500) }
    }
}

private struct PhysarumVisualization: View {
    let entries: [PlayHistoryEntry]
    let phase: Double
    @State private var sim = TrailSim()

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Listening Trail").font(.headline)
                Spacer()
                Text("Slimes replay your actual listening order through top artists. Colour = service. Dense edges = artist pairs you chain.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 6)
            Canvas { ctx, size in
                if !sim.built { sim.prepare(entries: entries, in: size) }
                draw(ctx: ctx, size: size)
            }
            .onChange(of: phase) { if sim.built { sim.step() } }
        }
    }

    private func draw(ctx: GraphicsContext, size: CGSize) {
        if sim.nodes.isEmpty {
            ctx.draw(Text("No history yet").font(.title3).foregroundStyle(.secondary),
                     at: CGPoint(x: size.width / 2, y: size.height / 2))
            return
        }
        // Trails (old dimmer, fresh brighter)
        for t in sim.trails {
            let s: CGFloat = 1.6
            ctx.fill(Path(ellipseIn: CGRect(x: t.p.x - s / 2, y: t.p.y - s / 2,
                                            width: s, height: s)),
                     with: .color(t.color.opacity(0.1 + t.life * 0.55)))
        }
        // Artist nodes
        let maxCount = sim.nodes.first?.count ?? 1
        for n in sim.nodes {
            let r: CGFloat = 5 + CGFloat(Double(n.count) / Double(max(maxCount, 1))) * 16
            let rect = CGRect(x: n.point.x - r, y: n.point.y - r, width: r * 2, height: r * 2)
            ctx.fill(Path(ellipseIn: rect), with: .color(.secondary.opacity(0.22)))
            ctx.stroke(Path(ellipseIn: rect), with: .color(.primary.opacity(0.45)), lineWidth: 1)
            ctx.draw(Text(n.artist).font(.caption2.bold()).foregroundStyle(.primary),
                     at: CGPoint(x: n.point.x, y: n.point.y + r + 10))
        }
        // Slime heads (bright dots)
        for s in sim.slimes {
            let headR: CGFloat = 3.5
            let rect = CGRect(x: CGFloat(s.x) - headR, y: CGFloat(s.y) - headR,
                              width: headR * 2, height: headR * 2)
            ctx.fill(Path(ellipseIn: rect), with: .color(s.color))
            // Subtle glow
            let gR: CGFloat = 6
            let grect = CGRect(x: CGFloat(s.x) - gR, y: CGFloat(s.y) - gR,
                               width: gR * 2, height: gR * 2)
            ctx.fill(Path(ellipseIn: grect), with: .color(s.color.opacity(0.25)))
        }
    }
}

// MARK: - Hyperbolic tree (Poincaré disk of services → artists)
//
// Radial tree placed in the unit disk with tanh scaling — parents close to
// the centre, descendants compressed toward the rim. Creates a "fisheye"
// look: the focus you pick gets more visual real estate than edge nodes.

private struct HyperbolicTreeVisualization: View {
    let entries: [PlayHistoryEntry]
    let phase: Double

    var body: some View {
        Canvas { ctx, size in draw(ctx: ctx, size: size) }
            .overlay(alignment: .bottomLeading) {
                Text("Poincaré disk: services (inner) → top artists (outer rim).")
                    .font(.caption2).foregroundStyle(.secondary).padding(10)
            }
    }

    private func draw(ctx: GraphicsContext, size: CGSize) {
        guard !entries.isEmpty, let range = timelineRange(for: entries) else { return }
        let cutoff = range.date(at: phase)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let R = min(size.width, size.height) * 0.44

        // Draw unit disk boundary.
        let disk = Path(ellipseIn: CGRect(x: center.x - R, y: center.y - R, width: R * 2, height: R * 2))
        ctx.stroke(disk, with: .color(.secondary.opacity(0.25)), lineWidth: 1)

        // Group artists by dominant service, keep top 6 artists per service.
        var byService: [String: [(artist: String, count: Int, color: Color)]] = [:]
        var artistCount: [String: Int] = [:]
        var artistService: [String: String] = [:]
        for e in entries where !e.artist.isEmpty && e.timestamp <= cutoff {
            artistCount[e.artist, default: 0] += 1
            if artistService[e.artist] == nil { artistService[e.artist] = e.sourceURI ?? "" }
        }
        for (artist, count) in artistCount {
            let svc = artistService[artist] ?? "unknown"
            let bucket = serviceBucketKey(svc)
            byService[bucket, default: []].append((artist, count, serviceColor(for: svc)))
        }
        let services = byService.keys.sorted()
        guard !services.isEmpty else {
            ctx.draw(Text("Waiting for data…").font(.title3).foregroundStyle(.secondary),
                     at: center); return
        }

        // Place service nodes on an inner ring at hyperbolic radius ~0.35.
        let innerRHyper = 0.35
        let outerRHyper = 0.88
        func project(_ h: Double, _ theta: Double) -> CGPoint {
            // tanh compresses so h=1 lies exactly on the disk edge.
            let eucl = CGFloat(tanh(h * 2))  // bounded in (0, ~1)
            return CGPoint(x: center.x + eucl * R * CGFloat(cos(theta)),
                           y: center.y + eucl * R * CGFloat(sin(theta)))
        }

        for (si, svc) in services.enumerated() {
            let frac = Double(si) / Double(max(services.count, 1))
            let thetaS = frac * .pi * 2 - .pi / 2
            let sp = project(innerRHyper, thetaS)
            let children = (byService[svc] ?? []).sorted { $0.count > $1.count }.prefix(6)
            let arc = 2 * .pi / Double(services.count)
            for (ci, child) in children.enumerated() {
                let cf = (Double(ci) + 0.5) / Double(max(children.count, 1))
                let thetaC = thetaS - arc / 2 + cf * arc
                let cp = project(outerRHyper, thetaC)
                // Edge: geodesic approximated by a simple arc toward the centre.
                var p = Path()
                p.move(to: sp)
                let mid = CGPoint(x: (sp.x + cp.x) / 2 + (center.x - (sp.x + cp.x) / 2) * 0.25,
                                  y: (sp.y + cp.y) / 2 + (center.y - (sp.y + cp.y) / 2) * 0.25)
                p.addQuadCurve(to: cp, control: mid)
                ctx.stroke(p, with: .color(child.color.opacity(0.45)), lineWidth: 1.2)
                let r: CGFloat = 3 + CGFloat(min(Double(child.count) / 20.0, 1.0)) * 7
                ctx.fill(Path(ellipseIn: CGRect(x: cp.x - r, y: cp.y - r, width: r * 2, height: r * 2)),
                         with: .color(child.color))
                ctx.draw(Text(child.artist).font(.caption2).foregroundStyle(.primary),
                         at: CGPoint(x: cp.x, y: cp.y + r + 7))
            }
            let sR: CGFloat = 8
            ctx.fill(Path(ellipseIn: CGRect(x: sp.x - sR, y: sp.y - sR, width: sR * 2, height: sR * 2)),
                     with: .color(serviceColor(for: svc).opacity(0.9)))
            ctx.draw(Text(svc).font(.caption2.bold()).foregroundStyle(.primary),
                     at: CGPoint(x: sp.x, y: sp.y - sR - 8))
        }
        // Centre root.
        ctx.fill(Path(ellipseIn: CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)),
                 with: .color(.primary))
        drawTimelineLabel(ctx: ctx, size: size, date: cutoff)
    }

    private func serviceBucketKey(_ uri: String) -> String {
        let l = uri.lowercased()
        if l.contains("sid=12") || l.contains("spotify") { return "Spotify" }
        if l.contains("sid=204") { return "Apple Music" }
        if l.contains("sid=254") || l.contains("tunein") { return "TuneIn" }
        if l.contains("sid=212") { return "Amazon" }
        if l.contains("sid=303") { return "Plex" }
        if l.contains("sid=144") { return "YouTube" }
        if l.contains("x-file-cifs") { return "Local" }
        return "Other"
    }
}

// MARK: - Voronoi treemap (weighted cells per artist)
//
// Coarse-grid approximation of additively-weighted Voronoi: every grid cell
// is assigned to the nearest artist seed after dividing by sqrt(playCount).
// Cells grow with play count. Looks organic, no rectangles.

private struct VoronoiTreemapVisualization: View {
    let entries: [PlayHistoryEntry]
    let phase: Double

    var body: some View {
        Canvas { ctx, size in draw(ctx: ctx, size: size) }
            .overlay(alignment: .bottomLeading) {
                Text("Additively-weighted Voronoi cells. Area ∝ play count.")
                    .font(.caption2).foregroundStyle(.secondary).padding(10)
            }
    }

    private struct Seed {
        let center: CGPoint
        let weight: Double
        let artist: String
        let color: Color
    }

    private func draw(ctx: GraphicsContext, size: CGSize) {
        guard !entries.isEmpty, let range = timelineRange(for: entries) else { return }
        let cutoff = range.date(at: phase)
        var counts: [String: Int] = [:]
        var services: [String: String] = [:]
        for e in entries where !e.artist.isEmpty && e.timestamp <= cutoff {
            counts[e.artist, default: 0] += 1
            if services[e.artist] == nil { services[e.artist] = e.sourceURI ?? "" }
        }
        let top = counts.sorted { $0.value > $1.value }.prefix(20)
        guard !top.isEmpty else { return }
        // Lay out seeds on a jittered low-discrepancy ring so cells start spread.
        var seeds: [Seed] = []
        for (i, kv) in top.enumerated() {
            let t = Double(i) / Double(top.count)
            let theta = t * .pi * 2 * 2.399963  // golden-angle spiral
            let r = 0.15 + t * 0.75
            seeds.append(Seed(
                center: CGPoint(x: size.width / 2 + CGFloat(cos(theta)) * CGFloat(r) * size.width * 0.35,
                                y: size.height / 2 + CGFloat(sin(theta)) * CGFloat(r) * size.height * 0.35),
                weight: Double(kv.value),
                artist: kv.key,
                color: serviceColor(for: services[kv.key])
            ))
        }
        // Render on a coarse grid.
        let cellSize: CGFloat = 8
        let cols = Int(size.width / cellSize)
        let rows = Int(size.height / cellSize)
        for r in 0..<rows {
            for c in 0..<cols {
                let px = CGFloat(c) * cellSize + cellSize / 2
                let py = CGFloat(r) * cellSize + cellSize / 2
                var bestIdx = 0
                var bestD = Double.greatestFiniteMagnitude
                for (si, s) in seeds.enumerated() {
                    let dx = Double(px - s.center.x)
                    let dy = Double(py - s.center.y)
                    let d = (dx * dx + dy * dy) / (s.weight + 1)
                    if d < bestD { bestD = d; bestIdx = si }
                }
                let seed = seeds[bestIdx]
                let rect = CGRect(x: CGFloat(c) * cellSize, y: CGFloat(r) * cellSize,
                                  width: cellSize, height: cellSize)
                // Subtle darkening at seed edges based on distance.
                let fade = min(1.0, bestD / 2000)
                ctx.fill(Path(rect), with: .color(seed.color.opacity(0.35 + (1 - fade) * 0.5)))
            }
        }
        // Label seed centres with artist name + count.
        for s in seeds {
            ctx.draw(Text(s.artist).font(.caption2.bold()).foregroundStyle(.white),
                     at: s.center)
        }
        drawTimelineLabel(ctx: ctx, size: size, date: cutoff)
    }
}

// MARK: - Arc diagram (artists on a line, arcs connect co-plays)

private struct ArcDiagramVisualization: View {
    let entries: [PlayHistoryEntry]
    let phase: Double

    var body: some View {
        Canvas { ctx, size in draw(ctx: ctx, size: size) }
            .overlay(alignment: .bottomLeading) {
                Text("Top artists on the baseline. Arcs connect consecutive plays; thicker = more.")
                    .font(.caption2).foregroundStyle(.secondary).padding(10)
            }
    }

    private func draw(ctx: GraphicsContext, size: CGSize) {
        guard !entries.isEmpty, let range = timelineRange(for: entries) else { return }
        let cutoff = range.date(at: phase)
        var counts: [String: Int] = [:]
        for e in entries where !e.artist.isEmpty { counts[e.artist, default: 0] += 1 }
        let top = counts.sorted { $0.value > $1.value }.prefix(18).map(\.key)
        let topSet = Set(top)
        guard !top.isEmpty else { return }

        // Build adjacency from consecutive plays up to the cutoff.
        var edges: [String: [String: Int]] = [:]
        var maxEdge = 1
        var prev: String?
        for e in entries where e.timestamp <= cutoff {
            if topSet.contains(e.artist), let p = prev, p != e.artist, topSet.contains(p) {
                let a = min(p, e.artist); let b = max(p, e.artist)
                edges[a, default: [:]][b, default: 0] += 1
                maxEdge = max(maxEdge, edges[a]![b]!)
            }
            if !e.artist.isEmpty { prev = e.artist }
        }

        let leftPad: CGFloat = 40
        let rightPad: CGFloat = 40
        let baselineY = size.height - 80
        let spacing = (size.width - leftPad - rightPad) / CGFloat(max(top.count - 1, 1))
        var xFor: [String: CGFloat] = [:]
        for (i, a) in top.enumerated() {
            xFor[a] = leftPad + CGFloat(i) * spacing
        }
        // Arcs (semicircles above baseline).
        for (a, map) in edges {
            guard let xa = xFor[a] else { continue }
            for (b, w) in map {
                guard let xb = xFor[b] else { continue }
                let x1 = min(xa, xb), x2 = max(xa, xb)
                let cx = (x1 + x2) / 2
                let rx = (x2 - x1) / 2
                let ry = min(rx * 0.85, baselineY - 40)
                var p = Path()
                p.move(to: CGPoint(x: x1, y: baselineY))
                p.addCurve(to: CGPoint(x: x2, y: baselineY),
                           control1: CGPoint(x: x1, y: baselineY - ry * 1.2),
                           control2: CGPoint(x: x2, y: baselineY - ry * 1.2))
                // Hue varies with arc span so adjacent artists are distinguishable.
                let hue = Double(cx / size.width)
                let intensity = Double(w) / Double(maxEdge)
                let color = Color(hue: hue, saturation: 0.7, brightness: 0.9)
                ctx.stroke(p, with: .color(color.opacity(0.25 + 0.55 * intensity)),
                           lineWidth: 0.8 + 4 * CGFloat(intensity))
            }
        }
        // Baseline + nodes + labels.
        var base = Path()
        base.move(to: CGPoint(x: leftPad, y: baselineY))
        base.addLine(to: CGPoint(x: size.width - rightPad, y: baselineY))
        ctx.stroke(base, with: .color(.secondary.opacity(0.4)), lineWidth: 0.5)
        for a in top {
            guard let x = xFor[a] else { continue }
            let count = counts[a] ?? 1
            let r: CGFloat = 3 + CGFloat(min(Double(count) / 40.0, 1.0)) * 7
            ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: baselineY - r, width: r * 2, height: r * 2)),
                     with: .color(.accentColor))
            // Rotated-ish label: draw vertically staggered instead of rotated.
            ctx.draw(Text(a).font(.caption2).foregroundStyle(.primary),
                     at: CGPoint(x: x, y: baselineY + 20 + CGFloat((a.hashValue & 1) * 12)))
        }
        drawTimelineLabel(ctx: ctx, size: size, date: cutoff)
    }
}

// MARK: - Reaction-Diffusion (Gray-Scott, seeded by hour × weekday plays)
//
// Turing patterns: two virtual chemicals react and diffuse, spots form at
// high-V regions which we seed from the listening intensity at each (hour,
// day-of-week) cell. As the sim runs it evolves organic pattern formations
// that capture where listening is dense.

@MainActor
private final class GrayScottSim {
    var cols = 160, rows = 100
    var u: [Double] = []
    var v: [Double] = []
    var built = false
    let du = 1.0, dv = 0.5
    let feed = 0.037, kill = 0.06

    func prepare(entries: [PlayHistoryEntry], cols c: Int, rows r: Int) {
        guard !built, !entries.isEmpty else { return }
        cols = max(40, min(c, 240))
        rows = max(30, min(r, 180))
        u = [Double](repeating: 1, count: cols * rows)
        v = [Double](repeating: 0, count: cols * rows)
        // Seed by hour × weekday intensity (normalised), mapped to a smaller
        // pattern that gets smeared across the grid.
        let cal = Calendar.current
        var hist = [Double](repeating: 0, count: 7 * 24)
        var maxH = 0.0
        for e in entries {
            let h = cal.component(.hour, from: e.timestamp)
            let wd = (cal.component(.weekday, from: e.timestamp) - 1) % 7
            let idx = wd * 24 + h
            hist[idx] += 1
            maxH = max(maxH, hist[idx])
        }
        for y in 0..<rows {
            for x in 0..<cols {
                let hx = Int(Double(x) / Double(cols) * 24)
                let wy = Int(Double(y) / Double(rows) * 7)
                let intensity = hist[wy * 24 + hx] / max(maxH, 1)
                if intensity > 0.25 && (x + y) % 3 == 0 {
                    u[y * cols + x] = 0.5
                    v[y * cols + x] = 0.25 + intensity * 0.5
                }
            }
        }
        built = true
    }

    func step(iterations: Int = 4) {
        guard built else { return }
        var un = u, vn = v
        for _ in 0..<iterations {
            for y in 1..<(rows - 1) {
                for x in 1..<(cols - 1) {
                    let i = y * cols + x
                    let lU = u[i - 1] + u[i + 1] + u[i - cols] + u[i + cols] - 4 * u[i]
                    let lV = v[i - 1] + v[i + 1] + v[i - cols] + v[i + cols] - 4 * v[i]
                    let uvv = u[i] * v[i] * v[i]
                    un[i] = u[i] + (du * lU - uvv + feed * (1 - u[i]))
                    vn[i] = v[i] + (dv * lV + uvv - (kill + feed) * v[i])
                }
            }
            swap(&u, &un); swap(&v, &vn)
        }
    }
}

private struct ReactionDiffusionVisualization: View {
    let entries: [PlayHistoryEntry]
    let phase: Double
    @State private var sim = GrayScottSim()

    var body: some View {
        Canvas { ctx, size in
            let cols = max(40, Int(size.width / 5))
            let rows = max(30, Int(size.height / 5))
            if !sim.built { sim.prepare(entries: entries, cols: cols, rows: rows) }
            draw(ctx: ctx, size: size)
        }
        .onChange(of: phase) { if sim.built { sim.step() } }
        .overlay(alignment: .bottomLeading) {
            Text("Gray-Scott reaction-diffusion seeded by hour × weekday listening density.")
                .font(.caption2).foregroundStyle(.secondary).padding(10)
        }
    }

    private func draw(ctx: GraphicsContext, size: CGSize) {
        guard sim.built, sim.cols > 0, sim.rows > 0 else {
            ctx.draw(Text("Seeding…").font(.title3).foregroundStyle(.secondary),
                     at: CGPoint(x: size.width / 2, y: size.height / 2)); return
        }
        let cw = size.width / CGFloat(sim.cols)
        let ch = size.height / CGFloat(sim.rows)
        for y in 0..<sim.rows {
            for x in 0..<sim.cols {
                let val = min(1, max(0, sim.v[y * sim.cols + x] * 2.5))
                guard val > 0.02 else { continue }
                let color = Color(hue: 0.55 - val * 0.5, saturation: 0.85, brightness: 0.35 + val * 0.65)
                let rect = CGRect(x: CGFloat(x) * cw, y: CGFloat(y) * ch, width: cw + 0.5, height: ch + 0.5)
                ctx.fill(Path(rect), with: .color(color.opacity(0.15 + val * 0.85)))
            }
        }
    }
}

// MARK: - Flow field (particles advected by artist-transition vector field)

@MainActor
private final class FlowFieldSim {
    struct Particle { var x: Double; var y: Double; var life: Int }
    var particles: [Particle] = []
    var field: [(dx: Double, dy: Double)] = []  // row-major
    var cols = 40, rows = 30
    var built = false
    var seed: UInt64 = 0x243F_6A88_85A3_08D3
    private func rnd() -> Double {
        seed &*= 6364136223846793005
        seed &+= 1442695040888963407
        return Double((seed >> 33) & 0xFFFFFF) / Double(0xFFFFFF)
    }

    func prepare(entries: [PlayHistoryEntry], cols c: Int, rows r: Int) {
        guard !built, !entries.isEmpty else { return }
        cols = c; rows = r
        field = [(dx: Double, dy: Double)](repeating: (0, 0), count: cols * rows)
        // Build a scalar density from hour × weekday.
        let cal = Calendar.current
        var density = [[Double]](repeating: [Double](repeating: 0, count: 7), count: 24)
        var maxD = 0.0
        for e in entries {
            let h = cal.component(.hour, from: e.timestamp)
            let wd = (cal.component(.weekday, from: e.timestamp) - 1) % 7
            density[h][wd] += 1
            maxD = max(maxD, density[h][wd])
        }
        // Sample density at each grid point then take the gradient — particles
        // will follow contours of equal density.
        func sampleD(_ gx: Int, _ gy: Int) -> Double {
            let h = Int(Double(gx) / Double(cols) * 24).clamped(to: 0...23)
            let wd = Int(Double(gy) / Double(rows) * 7).clamped(to: 0...6)
            return density[h][wd] / max(maxD, 1)
        }
        for y in 0..<rows {
            for x in 0..<cols {
                let d00 = sampleD(x, y)
                let dx = sampleD(min(x + 1, cols - 1), y) - d00
                let dy = sampleD(x, min(y + 1, rows - 1)) - d00
                // Rotate 90° so particles swirl around hotspots instead of
                // collapsing into them.
                field[y * cols + x] = (-dy, dx)
            }
        }
        particles = (0..<450).map { _ in
            Particle(x: rnd() * Double(cols - 1), y: rnd() * Double(rows - 1),
                     life: Int(rnd() * 60) + 30)
        }
        built = true
    }

    func step(cellW: Double, cellH: Double) {
        guard built else { return }
        for i in 0..<particles.count {
            var p = particles[i]
            let ix = max(0, min(cols - 1, Int(p.x)))
            let iy = max(0, min(rows - 1, Int(p.y)))
            let f = field[iy * cols + ix]
            p.x += f.dx * 6 + (rnd() - 0.5) * 0.2
            p.y += f.dy * 6 + (rnd() - 0.5) * 0.2
            p.life -= 1
            if p.life <= 0 || p.x < 0 || p.x >= Double(cols) || p.y < 0 || p.y >= Double(rows) {
                p = Particle(x: rnd() * Double(cols - 1), y: rnd() * Double(rows - 1),
                             life: Int(rnd() * 60) + 30)
            }
            particles[i] = p
            _ = (cellW, cellH)
        }
    }
}

private extension Int {
    func clamped(to r: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, r.lowerBound), r.upperBound)
    }
}

private struct FlowFieldVisualization: View {
    let entries: [PlayHistoryEntry]
    let phase: Double
    @State private var sim = FlowFieldSim()
    @State private var trails: [CGPoint] = []

    var body: some View {
        Canvas { ctx, size in
            let cols = 40, rows = 30
            if !sim.built { sim.prepare(entries: entries, cols: cols, rows: rows) }
            draw(ctx: ctx, size: size)
        }
        .onChange(of: phase) {
            if sim.built {
                sim.step(cellW: 1, cellH: 1)
                // Sample a subset into trails for visual persistence.
                for p in sim.particles.prefix(200) {
                    trails.append(CGPoint(x: p.x, y: p.y))
                }
                if trails.count > 3000 { trails.removeFirst(trails.count - 3000) }
            }
        }
        .overlay(alignment: .bottomLeading) {
            Text("Particles drift along rotated gradient of hour × weekday listening density.")
                .font(.caption2).foregroundStyle(.secondary).padding(10)
        }
    }

    private func draw(ctx: GraphicsContext, size: CGSize) {
        let cw = size.width / CGFloat(sim.cols)
        let ch = size.height / CGFloat(sim.rows)
        // Trail fade.
        for (i, p) in trails.enumerated() {
            let age = Double(i) / Double(max(1, trails.count))
            let s: CGFloat = 1.2
            let rect = CGRect(x: CGFloat(p.x) * cw - s / 2, y: CGFloat(p.y) * ch - s / 2, width: s, height: s)
            ctx.fill(Path(ellipseIn: rect),
                     with: .color(Color(hue: 0.58 + age * 0.15, saturation: 0.7, brightness: 0.95)
                        .opacity(0.04 + age * 0.35)))
        }
        // Live particles.
        for p in sim.particles {
            let rect = CGRect(x: CGFloat(p.x) * cw - 1.5, y: CGFloat(p.y) * ch - 1.5, width: 3, height: 3)
            ctx.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.85)))
        }
    }
}

// MARK: - Mapper (topological skeleton: hour-bin cover × dominant artists)

private struct MapperVisualization: View {
    let entries: [PlayHistoryEntry]
    let phase: Double

    var body: some View {
        Canvas { ctx, size in draw(ctx: ctx, size: size) }
            .overlay(alignment: .bottomLeading) {
                Text("Mapper: hour-bin cover → artist-overlap graph. Edges = shared artists.")
                    .font(.caption2).foregroundStyle(.secondary).padding(10)
            }
    }

    private func draw(ctx: GraphicsContext, size: CGSize) {
        guard !entries.isEmpty, let range = timelineRange(for: entries) else { return }
        let cutoff = range.date(at: phase)
        let cal = Calendar.current
        // Cover: 8 overlapping hour bins.
        let binCount = 8
        let binWidth = 24.0 / Double(binCount)
        let overlap = 0.4
        var bins: [Set<String>] = Array(repeating: [], count: binCount)
        var binPlayCount = [Int](repeating: 0, count: binCount)
        for e in entries where !e.artist.isEmpty && e.timestamp <= cutoff {
            let h = Double(cal.component(.hour, from: e.timestamp))
            for b in 0..<binCount {
                let lo = Double(b) * binWidth - overlap
                let hi = lo + binWidth + overlap * 2
                if (h >= lo && h < hi) || (lo < 0 && h >= 24 + lo) || (hi > 24 && h < hi - 24) {
                    bins[b].insert(e.artist)
                    binPlayCount[b] += 1
                }
            }
        }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) * 0.34
        var nodePos: [CGPoint] = []
        var nodeR: [CGFloat] = []
        for b in 0..<binCount {
            let t = Double(b) / Double(binCount) * .pi * 2 - .pi / 2
            nodePos.append(CGPoint(x: center.x + CGFloat(cos(t)) * radius,
                                   y: center.y + CGFloat(sin(t)) * radius))
            let r = 10 + CGFloat(min(Double(binPlayCount[b]) / 50, 1.0)) * 28
            nodeR.append(r)
        }
        // Edges where artist sets overlap.
        for i in 0..<binCount {
            for j in (i + 1)..<binCount {
                let inter = bins[i].intersection(bins[j])
                guard !inter.isEmpty else { continue }
                var p = Path()
                p.move(to: nodePos[i])
                p.addQuadCurve(to: nodePos[j], control: center)
                let alpha = 0.15 + min(Double(inter.count) / 10.0, 1.0) * 0.6
                let w: CGFloat = 1 + CGFloat(min(Double(inter.count) / 10.0, 1.0)) * 6
                ctx.stroke(p, with: .color(.accentColor.opacity(alpha)), lineWidth: w)
            }
        }
        // Nodes: draw inner circle of dominant artists as mini stippling.
        for b in 0..<binCount {
            let p = nodePos[b]; let r = nodeR[b]
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                     with: .color(.secondary.opacity(0.15)))
            ctx.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                       with: .color(.accentColor.opacity(0.7)), lineWidth: 1.2)
            let sortedArtists = Array(bins[b].sorted().prefix(8))
            for (ai, a) in sortedArtists.enumerated() {
                let frac = Double(ai) / Double(max(sortedArtists.count, 1))
                let theta = frac * .pi * 2
                let cp = CGPoint(x: p.x + CGFloat(cos(theta)) * (r * 0.55),
                                 y: p.y + CGFloat(sin(theta)) * (r * 0.55))
                ctx.fill(Path(ellipseIn: CGRect(x: cp.x - 2.5, y: cp.y - 2.5, width: 5, height: 5)),
                         with: .color(.white.opacity(0.9)))
                _ = a
            }
            let loHour = Int(Double(b) * binWidth)
            let hiHour = Int(Double(b + 1) * binWidth) % 24
            ctx.draw(Text("\(loHour)–\(hiHour)h").font(.caption2.bold()).foregroundStyle(.primary),
                     at: CGPoint(x: p.x, y: p.y - r - 10))
            ctx.draw(Text("\(bins[b].count) artists").font(.caption2).foregroundStyle(.secondary),
                     at: CGPoint(x: p.x, y: p.y + r + 10))
        }
        drawTimelineLabel(ctx: ctx, size: size, date: cutoff)
    }
}

// MARK: - Force-directed embedding (co-play network)

@MainActor
private final class ForceSim {
    struct Node { var x: Double; var y: Double; var vx: Double = 0; var vy: Double = 0
        let artist: String; let count: Int; let color: Color }
    var nodes: [Node] = []
    var edges: [(Int, Int, Double)] = []
    var built = false
    var seed: UInt64 = 0xCAFE_F00D_DEAD_BEEF
    private func rnd() -> Double {
        seed &*= 6364136223846793005
        seed &+= 1442695040888963407
        return Double((seed >> 33) & 0xFFFFFF) / Double(0xFFFFFF)
    }

    func prepare(entries: [PlayHistoryEntry], in size: CGSize) {
        guard !built, size.width > 100 else { return }
        var counts: [String: Int] = [:]
        var services: [String: String] = [:]
        for e in entries where !e.artist.isEmpty {
            counts[e.artist, default: 0] += 1
            if services[e.artist] == nil { services[e.artist] = e.sourceURI ?? "" }
        }
        let top = counts.sorted { $0.value > $1.value }.prefix(20).map(\.key)
        let topIdx: [String: Int] = Dictionary(uniqueKeysWithValues: top.enumerated().map { ($1, $0) })
        nodes = top.map { a in
            Node(x: (rnd() - 0.5) * Double(size.width) * 0.6 + Double(size.width / 2),
                 y: (rnd() - 0.5) * Double(size.height) * 0.6 + Double(size.height / 2),
                 artist: a, count: counts[a] ?? 1,
                 color: serviceColor(for: services[a]))
        }
        // Co-play edges from consecutive plays.
        var pair: [Int: [Int: Int]] = [:]
        var prev: String?
        for e in entries where !e.artist.isEmpty {
            if let p = prev, p != e.artist, let a = topIdx[p], let b = topIdx[e.artist] {
                let (lo, hi) = a < b ? (a, b) : (b, a)
                pair[lo, default: [:]][hi, default: 0] += 1
            }
            prev = e.artist
        }
        for (a, map) in pair {
            for (b, w) in map { edges.append((a, b, Double(w))) }
        }
        built = true
    }

    func step(in size: CGSize) {
        guard built else { return }
        let k: Double = 90     // natural spring length
        let repulse: Double = 9000
        let damp: Double = 0.82
        var newNodes = nodes
        // Repulsion O(n²) but N≤20.
        for i in 0..<nodes.count {
            for j in (i + 1)..<nodes.count {
                let dx = nodes[j].x - nodes[i].x
                let dy = nodes[j].y - nodes[i].y
                let d2 = max(dx * dx + dy * dy, 1)
                let d = d2.squareRoot()
                let f = repulse / d2
                newNodes[i].vx -= f * dx / d
                newNodes[i].vy -= f * dy / d
                newNodes[j].vx += f * dx / d
                newNodes[j].vy += f * dy / d
            }
        }
        // Spring attraction along edges.
        for (a, b, w) in edges {
            let dx = nodes[b].x - nodes[a].x
            let dy = nodes[b].y - nodes[a].y
            let d = max((dx * dx + dy * dy).squareRoot(), 1)
            let strength = (d - k) * 0.015 * log(1 + w)
            newNodes[a].vx += strength * dx / d
            newNodes[a].vy += strength * dy / d
            newNodes[b].vx -= strength * dx / d
            newNodes[b].vy -= strength * dy / d
        }
        // Gentle centring.
        let cx = Double(size.width / 2), cy = Double(size.height / 2)
        for i in 0..<newNodes.count {
            newNodes[i].vx += (cx - newNodes[i].x) * 0.002
            newNodes[i].vy += (cy - newNodes[i].y) * 0.002
            newNodes[i].vx *= damp
            newNodes[i].vy *= damp
            newNodes[i].x += newNodes[i].vx
            newNodes[i].y += newNodes[i].vy
        }
        nodes = newNodes
    }
}

private struct ForceEmbeddingVisualization: View {
    let entries: [PlayHistoryEntry]
    let phase: Double
    @State private var sim = ForceSim()

    var body: some View {
        Canvas { ctx, size in
            if !sim.built { sim.prepare(entries: entries, in: size) }
            draw(ctx: ctx, size: size)
        }
        .onChange(of: phase) { if sim.built { sim.step(in: .init(width: 800, height: 600)) } }
        .overlay(alignment: .bottomLeading) {
            Text("Force-directed co-play graph. Springs pull artists that follow each other.")
                .font(.caption2).foregroundStyle(.secondary).padding(10)
        }
    }

    private func draw(ctx: GraphicsContext, size: CGSize) {
        guard !sim.nodes.isEmpty else { return }
        let maxW = sim.edges.map(\.2).max() ?? 1
        for (a, b, w) in sim.edges {
            var p = Path()
            p.move(to: CGPoint(x: sim.nodes[a].x, y: sim.nodes[a].y))
            p.addLine(to: CGPoint(x: sim.nodes[b].x, y: sim.nodes[b].y))
            let alpha = 0.10 + (w / maxW) * 0.55
            ctx.stroke(p, with: .color(.accentColor.opacity(alpha)),
                       lineWidth: 0.5 + CGFloat(w / maxW) * 3.5)
        }
        let maxCount = sim.nodes.map(\.count).max() ?? 1
        for n in sim.nodes {
            let r: CGFloat = 4 + CGFloat(Double(n.count) / Double(maxCount)) * 14
            let rect = CGRect(x: n.x - Double(r), y: n.y - Double(r),
                              width: Double(r) * 2, height: Double(r) * 2)
            ctx.fill(Path(ellipseIn: rect), with: .color(n.color.opacity(0.9)))
            ctx.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.35)), lineWidth: 1)
            ctx.draw(Text(n.artist).font(.caption2.bold()).foregroundStyle(.primary),
                     at: CGPoint(x: n.x, y: n.y + Double(r) + 10))
        }
    }
}

// MARK: - Shared helpers

private func drawTimelineLabel(ctx: GraphicsContext, size: CGSize, date: Date) {
    let df = DateFormatter(); df.dateFormat = "MMM d, yyyy"
    let label = Text(df.string(from: date))
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.primary)
    ctx.draw(label, at: CGPoint(x: size.width / 2, y: 20))
}

/// Reduces grouped names like "Office + Kitchen" to the first element so
/// visualizations aren't dominated by every possible group permutation.
private func displayRoom(_ groupName: String) -> String {
    groupName
        .components(separatedBy: " + ")
        .first?
        .trimmingCharacters(in: .whitespaces) ?? ""
}

private func roomColor(index: Int, total: Int) -> Color {
    Color(hue: Double(index) / Double(max(1, total)), saturation: 0.55, brightness: 0.85)
}

private func serviceColor(for uri: String?) -> Color {
    guard let uri = uri?.lowercased() else { return .gray }
    if uri.contains("sid=204") { return .pink }
    if uri.contains("sid=12") || uri.contains("spotify") { return .green }
    if uri.contains("sid=254") || uri.contains("tunein") { return .orange }
    if uri.contains("sid=212") { return .yellow }
    if uri.contains("sid=303") { return .purple }
    if uri.contains("sid=144") { return .teal }
    if uri.contains("x-file-cifs") { return .blue }
    return .gray
}
