/// StageSetMatcher.swift — Album-art → stage-colour-set selection.
///
/// Pure matching math for the Back of the Club lighting system: a
/// hue histogram built from the now-playing artwork is scored
/// against a list of declared stage-set descriptors (each carrying
/// its full declared hue triple). The set declarations themselves
/// live in the app target; this module only sees their descriptors
/// so the selection rules stay unit-testable.
///
/// Rationale for multi-hue matching: a multi-hue cover (rainbow
/// prism on black) has no meaningful single dominant hue; matching
/// the cover's top hue peaks against each set's full triple selects
/// the scheme that best covers the cover's actual colours.
///
/// Scoring is bidirectional. Coverage alone (peaks → set hues) let
/// a single-hue cover select a triadic set whose other two hues the
/// cover does not contain — the stage then projects colours absent
/// from the artwork. The groundedness term (set hues → peaks)
/// penalises every declared hue with no nearby detected peak.
///
/// Selection rules:
///   1. Chromatic-pixel fraction below `minChromaticFraction` →
///      `fallbackIndex` (grayscale / near-monochrome covers).
///   2. Extract up to `maxPeakCount` hue peaks from the histogram:
///      repeatedly take the highest-mass bin, absorb the mass of all
///      bins within `peakSuppressionRadius` of it as that peak's
///      mass, and suppress those bins from further picks. Fewer
///      peaks when the histogram has no remaining mass.
///   3. Score each descriptor as coverage + groundedness, with peak
///      masses normalized to sum 1:
///        coverage     = Σ over peaks of normalizedPeakMass ×
///                       minCircularDistance(peak, declared hues)
///        groundedness = Σ over declared hues of λ ×
///                       minCircularDistance(hue, detected peaks)
///        λ            = groundednessWeight / max(1, hueCount)
///      Lowest score wins; ties resolve to the first descriptor in
///      declaration order.
///
/// Deterministic — no randomness, no time dependence.
import AppKit
import CoreGraphics

/// Colour-theory family of a stage set. Secondary offsets are the
/// hue positions (degrees from root) that distinguish the family.
public enum StageSetFamily: String, CaseIterable, Sendable {
    case analogous
    case splitComplementary
    case triadic

    public var secondaryHueOffsets: [Double] {
        switch self {
        case .analogous: return [-25, 25]
        case .splitComplementary: return [150, 210]
        case .triadic: return [120, 240]
        }
    }
}

/// Matching-relevant projection of one declared stage set.
public struct StageSetDescriptor: Equatable, Sendable {
    /// Index into the app's declared set array.
    public let index: Int
    /// Declared hues in degrees [0, 360), root first:
    /// [root, secondaryA, secondaryB]. All entries participate
    /// equally in matching.
    public let hues: [Double]

    public init(index: Int, hues: [Double]) {
        precondition(!hues.isEmpty)
        self.index = index
        self.hues = hues.map(StageSetMatcher.normalizedHue)
    }

    /// Backward-compatible construction from root + colour-theory
    /// family — derives the hue triple from the family's secondary
    /// offsets.
    public init(index: Int, rootHue: Double, family: StageSetFamily) {
        self.init(index: index,
                  hues: [rootHue] + family.secondaryHueOffsets.map { rootHue + $0 })
    }
}

/// Result of one histogram → descriptor match.
public struct StageSetMatch: Equatable, Sendable {
    /// Winning descriptor index, or the caller's fallback index.
    public let index: Int
    /// Extracted peak hues in degrees, ordered by descending peak
    /// mass. Empty when the histogram carries no chromatic mass.
    public let topHues: [Double]

    public init(index: Int, topHues: [Double]) {
        self.index = index
        self.topHues = topHues
    }
}

/// Mass-per-hue-bin summary of an image's chromatic content.
public struct HueHistogram: Equatable, Sendable {
    public static let binCount = 36

    /// Chromatic pixel mass per 10° bin. Achromatic pixels
    /// contribute nothing (see `StageSetMatcher` thresholds).
    public let mass: [Double]
    /// Chromatic pixels ÷ total sampled pixels, in [0, 1].
    public let chromaticFraction: Double
    /// Mean HSB saturation of the CHROMATIC pixels only, in [0, 1].
    /// 0 when no pixel passes the chromatic gates. Drives the
    /// vibrancy grading of generated cover-shades lighting — a
    /// neon-vivid cover and a muted one carry the same hue peaks
    /// but very different means.
    public let meanChromaticSaturation: Double
    /// Mean HSB brightness of the CHROMATIC pixels only, in [0, 1].
    /// 0 when no pixel passes the chromatic gates.
    public let meanChromaticBrightness: Double
    /// Mass-weighted mean saturation PER BIN (0 where the bin holds
    /// no mass). Distinguishes a real printed colour (saturated) from
    /// shadow/antialiasing residue at the same small mass — the gate
    /// the peak slot-filling stage runs on.
    public let binMeanSaturation: [Double]

    public init(mass: [Double], chromaticFraction: Double,
                meanChromaticSaturation: Double = 0,
                meanChromaticBrightness: Double = 0,
                binMeanSaturation: [Double] = []) {
        precondition(mass.count == Self.binCount)
        precondition(binMeanSaturation.isEmpty || binMeanSaturation.count == Self.binCount)
        self.mass = mass
        self.chromaticFraction = chromaticFraction
        self.meanChromaticSaturation = meanChromaticSaturation
        self.meanChromaticBrightness = meanChromaticBrightness
        self.binMeanSaturation = binMeanSaturation.isEmpty
            ? [Double](repeating: 0, count: Self.binCount)
            : binMeanSaturation
    }

    /// Centre hue of bin `i` in degrees.
    public static func binCenter(_ i: Int) -> Double {
        (Double(i) + 0.5) * 360.0 / Double(binCount)
    }
}

public enum StageSetMatcher {
    /// Achromatic-exclusion thresholds. Pixels below the saturation
    /// floor carry no hue signal; near-black / near-white pixels
    /// have numerically unstable hue.
    public static let minSaturation = 0.15
    public static let minBrightness = 0.12
    public static let maxBrightness = 0.95
    /// Below this chromatic fraction the cover is effectively
    /// grayscale — callers get the fallback index.
    public static let minChromaticFraction = 0.008
    /// Maximum number of hue peaks extracted from the histogram.
    public static let maxPeakCount = 3
    /// Bins within this circular distance of a chosen peak are
    /// absorbed into that peak and suppressed from further picks —
    /// two maxima closer than this count as one peak.
    public static let peakSuppressionRadius = 30.0
    /// A secondary peak must carry at least this fraction of the
    /// DOMINANT peak's mass to count as a colour of the cover. Trace
    /// hues — olive shadow pixels, edge antialiasing — otherwise
    /// scrape past the saturation gate and hand a whole beam a hue
    /// nobody sees on the sleeve (observed: a red-orange cover
    /// emitting chartreuse from an 85° peak with a sliver of mass).
    /// 0.15 (was 0.25): group absorption now guarantees every
    /// surviving candidate is a DIFFERENT colour group, and a
    /// modest-mass distinct colour (the red element on an orange
    /// sleeve, ~18% of the field) is a real cover colour that the
    /// higher floor wrongly dropped.
    public static let minRelativePeakMass = 0.15
    /// Groundedness weight numerator: per-declared-hue λ =
    /// groundednessWeight / max(1, hueCount). Peak masses are
    /// normalized to sum 1 before scoring, so this value is
    /// independent of histogram scale. Fixture-derived upper bound
    /// for 3-hue sets: with two similar-mass complementary peaks
    /// (55/45 at 5°/185°) the split-complementary set must beat
    /// analogous, requiring the weight to stay below 16.875. The
    /// historical LOWER bound of 12 (dominant peak + weak secondary
    /// selecting analogous over the covering split set) became
    /// unreachable once `minRelativePeakMass` (0.25) started
    /// dropping such secondaries before scoring — any secondary that
    /// survives the floor carries ≥ 20% normalized mass and the
    /// covering set then legitimately wins (see
    /// testAboveFloorSecondarySelectsCoveringSplitComplementary).
    /// 14.4 retains margin under the upper bound.
    public static let groundednessWeight = 14.4
    static let sampleSize = 48

    // MARK: - Histogram construction

    /// Builds the hue histogram from a downsampled copy of `image`.
    /// Pixel mass = 1 per qualifying pixel — the histogram measures
    /// how much of the cover is each hue, not how saturated it is.
    public static func histogram(from image: NSImage) -> HueHistogram {
        guard let pixels = downsample(image) else {
            return HueHistogram(mass: [Double](repeating: 0, count: HueHistogram.binCount),
                                chromaticFraction: 0)
        }
        var mass = [Double](repeating: 0, count: HueHistogram.binCount)
        var binSatSums = [Double](repeating: 0, count: HueHistogram.binCount)
        var chromaticCount = 0
        var saturationSum = 0.0
        var brightnessSum = 0.0
        let totalCount = sampleSize * sampleSize
        for p in 0..<totalCount {
            let o = p * 4
            let a = Double(pixels[o + 3])
            guard a >= 128 else { continue }
            // Buffer is premultiplied — unpremultiply before HSB.
            let r = min(1.0, Double(pixels[o]) / a)
            let g = min(1.0, Double(pixels[o + 1]) / a)
            let b = min(1.0, Double(pixels[o + 2]) / a)
            let (h, s, v) = hsb(r: r, g: g, b: b)
            guard s >= minSaturation, v >= minBrightness, v <= maxBrightness else { continue }
            chromaticCount += 1
            saturationSum += s
            brightnessSum += v
            let bin = min(HueHistogram.binCount - 1,
                          Int(h / 360.0 * Double(HueHistogram.binCount)))
            mass[bin] += 1
            binSatSums[bin] += s
        }
        let denominator = Double(max(1, chromaticCount))
        let binMeans = (0..<HueHistogram.binCount).map {
            mass[$0] > 0 ? binSatSums[$0] / mass[$0] : 0
        }
        return HueHistogram(mass: mass,
                            chromaticFraction: Double(chromaticCount) / Double(totalCount),
                            meanChromaticSaturation: chromaticCount > 0 ? saturationSum / denominator : 0,
                            meanChromaticBrightness: chromaticCount > 0 ? brightnessSum / denominator : 0,
                            binMeanSaturation: binMeans)
    }

    // MARK: - Matching

    /// Returns the best-matching descriptor index plus the extracted
    /// peak hues. `fallbackIndex` when the histogram is too
    /// achromatic or the descriptor list is empty; peak hues are
    /// still reported in that case so the UI can display them.
    public static func match(histogram: HueHistogram,
                             descriptors: [StageSetDescriptor],
                             fallbackIndex: Int) -> StageSetMatch {
        let peaks = huePeaks(in: histogram)
        let topHues = peaks.map(\.hue)
        guard histogram.chromaticFraction >= minChromaticFraction,
              !peaks.isEmpty,
              !descriptors.isEmpty else {
            return StageSetMatch(index: fallbackIndex, topHues: topHues)
        }

        // Bidirectional score: coverage (peaks must lie near
        // declared hues, weighted by normalized peak mass) plus
        // groundedness (declared hues must lie near detected peaks,
        // weighted by λ). Strict < with declaration-order scan
        // resolves ties to the first descriptor.
        let totalPeakMass = peaks.reduce(0) { $0 + $1.mass }
        var best = descriptors[0]
        var bestScore = Double.greatestFiniteMagnitude
        for d in descriptors {
            var coverage = 0.0
            for peak in peaks {
                coverage += (peak.mass / totalPeakMass) * nearestDistance(from: peak.hue, to: d.hues)
            }
            let lambda = groundednessWeight / Double(max(1, d.hues.count))
            var groundedness = 0.0
            for hue in d.hues {
                groundedness += lambda * nearestDistance(from: hue, to: topHues)
            }
            let score = coverage + groundedness
            if score < bestScore {
                bestScore = score
                best = d
            }
        }
        return StageSetMatch(index: best.index, topHues: topHues)
    }

    /// Contrast-hue recovery thresholds. A candidate must sit at
    /// least `contrastMinSeparation` degrees from every top peak and
    /// carry at least `contrastMinMassFraction` of the histogram's
    /// total chromatic mass — enough to be a real cover colour
    /// (sky, logo, clothing), not sensor noise.
    public static let contrastMinSeparation = 60.0
    public static let contrastMinMassFraction = 0.004

    /// Largest-mass hue at least `contrastMinSeparation` degrees
    /// from every entry of `peaks`. Recovers a REAL minor cover
    /// colour that the relative-mass peak floor dropped — the
    /// contrast-injection rule prefers this over inventing a
    /// complement when the cover itself offers an opposing hue.
    /// Nil when nothing sufficiently far carries enough mass.
    public static func contrastHue(in histogram: HueHistogram,
                                   awayFrom peaks: [Double]) -> Double? {
        let total = histogram.mass.reduce(0, +)
        guard total > 0, !peaks.isEmpty else { return nil }
        func admissible(_ bin: Int) -> Bool {
            let centre = HueHistogram.binCenter(bin)
            return peaks.allSatisfy { hueDistance(centre, $0) >= contrastMinSeparation }
        }
        // Candidate = admissible bin with the highest OWN mass —
        // own mass, not neighbourhood mass, so the returned centre
        // is where the colour actually sits.
        var bestBin = -1
        var bestOwn = 0.0
        for i in 0..<HueHistogram.binCount
        where admissible(i) && histogram.mass[i] > bestOwn {
            bestOwn = histogram.mass[i]
            bestBin = i
        }
        guard bestBin >= 0 else { return nil }
        // Mass floor judged on the candidate's ADMISSIBLE
        // neighbourhood (a hue straddling two bins is not
        // undercounted; near-peak mass is never credited to a far
        // candidate).
        let centre = HueHistogram.binCenter(bestBin)
        var neighbourhood = 0.0
        for j in 0..<HueHistogram.binCount
        where admissible(j)
            && hueDistance(HueHistogram.binCenter(j), centre) <= peakSuppressionRadius {
            neighbourhood += histogram.mass[j]
        }
        guard neighbourhood >= total * contrastMinMassFraction else { return nil }
        return centre
    }

    /// Minimum circular distance from `hue` to any entry of
    /// `candidates`. `candidates` is non-empty at every call site.
    private static func nearestDistance(from hue: Double, to candidates: [Double]) -> Double {
        var nearest = Double.greatestFiniteMagnitude
        for c in candidates {
            nearest = min(nearest, hueDistance(hue, c))
        }
        return nearest
    }

    /// Perceptual colour group of a hue. Groups are coarser than
    /// bins and deliberately non-uniform: the warm band packs more
    /// distinct colours per degree (red vs orange is a sharp
    /// perceptual boundary at ~20°), the cool bands fewer.
    /// Selecting a peak discounts its ENTIRE group from later picks,
    /// so a cover can never spend two of the three peak slots on
    /// shades of the same colour family (observed: an orange sleeve
    /// producing three orange/yellow peaks while its red and blue
    /// elements went undetected).
    public static func hueGroup(_ hue: Double) -> Int {
        let h = normalizedHue(hue)
        switch h {
        case ..<20, 345...: return 0   // red
        case ..<75: return 1           // orange / yellow
        case ..<160: return 2          // green
        case ..<200: return 3          // teal / cyan
        case ..<260: return 4          // blue
        case ..<300: return 5          // violet
        default: return 6              // magenta / pink
        }
    }

    /// Extracts up to `maxPeakCount` peaks: repeatedly picks the
    /// highest-mass remaining bin (lowest bin index on ties), then
    /// absorbs and suppresses every bin in the SAME colour group,
    /// plus bins within `peakSuppressionRadius` that don't cross
    /// the red/warm boundary (radius absorption smooths group-edge
    /// straddling everywhere else, but red next to orange is the
    /// one adjacency where 20° apart is a different colour, not a
    /// shade). Result is ordered by descending absorbed mass (pick
    /// order on ties).
    /// Slot-filling thresholds (stage 2): a candidate must carry at
    /// least `fillMinMassFraction` of the total chromatic mass AND
    /// its bin's mean saturation must reach `fillMinSaturation` — a
    /// real printed colour, not shadow/antialiasing residue at the
    /// same small mass.
    public static let fillMinMassFraction = 0.02
    public static let fillMinSaturation = 0.45

    private static func huePeaks(in histogram: HueHistogram) -> [(hue: Double, mass: Double)] {
        var remaining = histogram.mass
        var peaks: [(hue: Double, mass: Double)] = []

        // Absorb the chosen bin's ENTIRE colour group, plus bins
        // within the suppression radius that don't cross a sharp
        // boundary. Radius absorption never crosses the two sharp
        // boundaries flanking red: red/warm (orange 20° away is a
        // different colour, not a shade) and red/magenta (pink 25°
        // the other way is too — observed: a magenta-dominant
        // psychedelic sleeve whose pink mass was swallowed by the
        // red peak and never lit).
        // Returns the absorbed mass AND the mass-weighted circular
        // mean hue of the absorbed bins — the peak is anchored at
        // the group's centre of mass, not the single tallest bin
        // (observed: a yellow-jacket cover whose warm mass anchored
        // at the 25° argmax and reported orange, with the yellow
        // never surfacing as a tone).
        func absorb(around bestBin: Int) -> (mass: Double, hue: Double) {
            let peakHue = HueHistogram.binCenter(bestBin)
            let peakGroup = hueGroup(peakHue)
            var absorbed = 0.0
            var vx = 0.0, vy = 0.0
            for i in 0..<HueHistogram.binCount where remaining[i] > 0 {
                let binHue = HueHistogram.binCenter(i)
                let binGroup = hueGroup(binHue)
                let sameGroup = binGroup == peakGroup
                let sharpAdjacency = (binGroup == 0 && (peakGroup == 1 || peakGroup == 6))
                    || (peakGroup == 0 && (binGroup == 1 || binGroup == 6))
                let inRadius = hueDistance(binHue, peakHue) <= peakSuppressionRadius
                    && !sharpAdjacency
                if sameGroup || inRadius {
                    absorbed += remaining[i]
                    let rad = binHue * .pi / 180
                    vx += remaining[i] * cos(rad)
                    vy += remaining[i] * sin(rad)
                    remaining[i] = 0
                }
            }
            // Degenerate antipodal cancellation → fall back to the
            // picked bin's centre. Rounded to 0.1° so the atan2
            // round-trip can't smear exact bin centres into
            // 224.999… epsilon values.
            let hue = (vx * vx + vy * vy) > 1e-9
                ? (normalizedHue(atan2(vy, vx) * 180 / .pi) * 10).rounded() / 10
                : peakHue
            return (absorbed, hue)
        }

        // Non-destructive absorption preview — same membership rule
        // as `absorb`, without zeroing.
        func previewAbsorption(around bestBin: Int) -> Double {
            let peakHue = HueHistogram.binCenter(bestBin)
            let peakGroup = hueGroup(peakHue)
            var sum = 0.0
            for i in 0..<HueHistogram.binCount where remaining[i] > 0 {
                let binHue = HueHistogram.binCenter(i)
                let binGroup = hueGroup(binHue)
                let sameGroup = binGroup == peakGroup
                let sharpAdjacency = (binGroup == 0 && (peakGroup == 1 || peakGroup == 6))
                    || (peakGroup == 0 && (binGroup == 1 || binGroup == 6))
                let inRadius = hueDistance(binHue, peakHue) <= peakSuppressionRadius
                    && !sharpAdjacency
                if sameGroup || inRadius { sum += remaining[i] }
            }
            return sum
        }

        // Stage 1 — dominant structure: highest-mass bins, one per
        // colour group, floored relative to the dominant peak. A
        // floor-rejected candidate is DEFERRED (excluded from
        // further stage-1 picks, mass left intact) rather than
        // absorbed away — stage 2 reconsiders it under the relaxed
        // gates.
        var deferred = Set<Int>()
        for _ in 0..<maxPeakCount {
            var bestBin = -1
            var bestMass = 0.0
            for i in 0..<HueHistogram.binCount
            where remaining[i] > bestMass && !deferred.contains(i) {
                bestMass = remaining[i]
                bestBin = i
            }
            guard bestBin >= 0 else { break }
            if let dominant = peaks.first?.mass {
                let wouldAbsorb = previewAbsorption(around: bestBin)
                if wouldAbsorb < dominant * minRelativePeakMass {
                    deferred.insert(bestBin)
                    continue
                }
            }
            let result = absorb(around: bestBin)
            peaks.append((hue: result.hue, mass: result.mass))
        }

        // Stage 2 — slot filling: a cover whose secondary colours
        // are real but SMALL (green frames and a teal window on a
        // yellow-checkerboard sleeve) otherwise collapses to a
        // single-hue ladder — three shades of the dominant plus a
        // contrast beam. Remaining slots take the largest unabsorbed
        // distinct-group candidates that pass the mass fraction and
        // per-bin saturation gates. The saturation gate is what
        // keeps low-sat trace hues (olive shadows) out at this
        // relaxed floor.
        let total = histogram.mass.reduce(0, +)
        while peaks.count < maxPeakCount {
            var bestBin = -1
            var bestMass = 0.0
            for i in 0..<HueHistogram.binCount
            where remaining[i] > bestMass
                && histogram.binMeanSaturation[i] >= fillMinSaturation {
                bestMass = remaining[i]
                bestBin = i
            }
            guard bestBin >= 0 else { break }
            let result = absorb(around: bestBin)
            guard result.mass >= total * fillMinMassFraction else { continue }
            peaks.append((hue: result.hue, mass: result.mass))
        }

        return peaks.enumerated()
            .sorted { a, b in
                a.element.mass != b.element.mass
                    ? a.element.mass > b.element.mass
                    : a.offset < b.offset
            }
            .map(\.element)
    }

    // MARK: - Pixel access

    /// Draws the image into a fixed-size RGBA8 premultiplied buffer.
    /// nil when the image can't produce a CGImage.
    private static func downsample(_ image: NSImage) -> [UInt8]? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: sampleSize * sampleSize * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress,
                                      width: sampleSize,
                                      height: sampleSize,
                                      bitsPerComponent: 8,
                                      bytesPerRow: sampleSize * 4,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))
            return true
        }
        return ok ? buffer : nil
    }

    // MARK: - Colour math

    private static func hsb(r: Double, g: Double, b: Double) -> (h: Double, s: Double, v: Double) {
        let maxc = max(r, g, b)
        let minc = min(r, g, b)
        let delta = maxc - minc
        let v = maxc
        let s = maxc <= 0 ? 0 : delta / maxc
        guard delta > 0 else { return (0, s, v) }
        var h: Double
        if maxc == r {
            h = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        } else if maxc == g {
            h = 60 * ((b - r) / delta + 2)
        } else {
            h = 60 * ((r - g) / delta + 4)
        }
        if h < 0 { h += 360 }
        return (h, s, v)
    }

    /// Circular hue distance in degrees, range [0, 180].
    public static func hueDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return d > 180 ? 360 - d : d
    }

    /// Wraps any hue value into [0, 360).
    public static func normalizedHue(_ h: Double) -> Double {
        let r = h.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }
}
