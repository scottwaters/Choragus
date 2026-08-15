/// ClubStageSets.swift — Stage colour sets for the Back of the Club
/// lighting system.
///
/// Automatic lighting is GENERATIVE: the four roles are shade
/// ladders of the hues detected on the now-playing cover
/// (`coverShadesSet(topHues:vibrancy:)`) — no theory-derived hues
/// the cover does not contain. Hue detection (histogram + peak extraction) is
/// delegated to `StageSetMatcher` (SonosKit).
///
/// The 31-set catalogue below remains for two purposes only:
///   - index 0 "Zune house" — the achromatic / no-art fallback
///   - the debug window's force-picker / audition grid
/// 30 catalogue sets span 10 hue roots (0°, 36°, … 324°) × 3
/// colour-theory families (analogous, split-complementary, triadic).
///
/// Every tone is club-graded: saturation 0.55–0.95, brightness
/// 0.5–0.9 band, wash deeper than beams, accent brightest.
import SwiftUI
import SonosKit

/// One display-space RGB lighting tone.
struct StageTone: Equatable {
    let r: Double
    let g: Double
    let b: Double

    var color: Color { Color(red: r, green: g, blue: b) }

    /// Parses "#RRGGBB" (leading "#" optional). Nil on malformed
    /// input — callers fall back to their default tone.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        self.init(r: Double((value >> 16) & 0xFF) / 255.0,
                  g: Double((value >> 8) & 0xFF) / 255.0,
                  b: Double(value & 0xFF) / 255.0)
    }

    init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// "#RRGGBB" for persistence and debug display.
    var hexString: String {
        String(format: "#%02X%02X%02X",
               Int((r * 255).rounded()),
               Int((g * 255).rounded()),
               Int((b * 255).rounded()))
    }

    /// Uniform component scale — used to deepen the wash tone for
    /// the multiply layer. Result stays in [0, 1].
    func scaled(_ k: Double) -> StageTone {
        StageTone(r: min(1, r * k), g: min(1, g * k), b: min(1, b * k))
    }

    static func lerp(_ a: StageTone, _ b: StageTone, t: Double) -> StageTone {
        StageTone(r: a.r + (b.r - a.r) * t,
                  g: a.g + (b.g - a.g) * t,
                  b: a.b + (b.b - a.b) * t)
    }
}

/// One coherent stage-lighting colour set — a wash, two beam tones,
/// and an accent that all derive from the same colour-theory
/// construction so the stage reads as a single design.
struct StageSet: Identifiable {
    let id: Int
    let name: String
    /// Human-readable construction rule — surfaced in the debug
    /// window next to the swatches.
    let theoryBasis: String
    /// Root hue in degrees [0, 360).
    let rootHue: Double
    let family: StageSetFamily
    let wash: StageTone
    let beamA: StageTone
    let beamB: StageTone
    let accent: StageTone

    /// Role tones in fixed order — the equality basis for crossfade
    /// triggering (a new cover with identical tones must not restart
    /// a fade; any tone change must).
    var tones: [StageTone] { [wash, beamA, beamB, accent] }
}

enum ClubStageSets {
    // Club grading bands. Wash sits deeper than the beams; accent is
    // the brightest tone in every set.
    private static let washSat = 0.85, washBri = 0.55
    private static let beamSat = 0.80, beamBri = 0.72
    private static let accentSat = 0.90, accentBri = 0.88

    /// Index 0 — fallback + disabled-state set. The classic
    /// amber/magenta/indigo trio from the original Zune-reference
    /// design, expressed in the wash/beam/accent roles.
    static let fallbackIndex = 0

    /// All sets. Index 0 is the fallback; indices 1–30 are the
    /// matcher-selectable sets, grouped by root in family order
    /// (analogous, split-complementary, triadic) to mirror
    /// `descriptors`.
    static let sets: [StageSet] = [
        StageSet(id: 0,
                 name: "Zune house",
                 theoryBasis: "Fixed amber wash with magenta / indigo beams — original reference design",
                 rootHue: 36,
                 family: .analogous,
                 wash: gelTone(hue: 36, s: washSat, b: washBri),
                 beamA: gelTone(hue: 320, s: beamSat, b: beamBri),
                 beamB: gelTone(hue: 255, s: beamSat, b: beamBri),
                 accent: gelTone(hue: 40, s: accentSat, b: accentBri)),
    ] + matchable

    private static let matchable: [StageSet] = {
        // Root hue → name stem, ascending 36° steps.
        let stems = ["Crimson", "Amber", "Chartreuse", "Emerald", "Jade",
                     "Cyan", "Cobalt", "Indigo", "Magenta", "Fuchsia"]
        var out: [StageSet] = []
        var index = 1
        for (step, stem) in stems.enumerated() {
            let root = Double(step) * 36.0
            out.append(analogous(index, "\(stem) analogous", root: root)); index += 1
            out.append(splitComplementary(index, "\(stem) split", root: root)); index += 1
            out.append(triadic(index, "\(stem) triad", root: root)); index += 1
        }
        return out
    }()

    /// Descriptor projection of the catalogue sets (index 0
    /// excluded). Passed to `StageSetMatcher.match` solely to run
    /// its histogram → peak pipeline; the catalogue index it returns
    /// is discarded — automatic selection is generative.
    static let descriptors: [StageSetDescriptor] = sets.dropFirst().map {
        StageSetDescriptor(index: $0.id, rootHue: $0.rootHue, family: $0.family)
    }

    /// Sentinel id for generated (non-catalogue) sets — never a
    /// valid index into `sets`.
    static let generatedSetID = -1

    /// Match result plus the histogram readings that drove it —
    /// surfaced in the debug window next to the matched set.
    struct MatchResult {
        /// Catalogue index applied when `generated` is nil — always
        /// the fallback; automatic matching no longer selects
        /// catalogue sets.
        let index: Int
        /// Cover-shades set built from the detected hues. Nil on
        /// the achromatic path.
        let generated: StageSet?
        /// Top hue peaks driving the match, degrees [0, 360),
        /// descending mass order, up to three. Empty when the cover
        /// has no chromatic mass.
        let topHues: [Double]
        /// Chromatic pixels ÷ sampled pixels, [0, 1].
        let chromaticFraction: Double
        /// Mean saturation / brightness of the CHROMATIC pixels —
        /// see `HueHistogram`. Zero on fully achromatic covers.
        let meanChromaticSaturation: Double
        let meanChromaticBrightness: Double
        var dominantHue: Double? { topHues.first }
        /// Vibrancy factor in [0, 1] — mean saturation × mean
        /// brightness of the chromatic pixels. Drives (a) the
        /// cover-shades ladder grading and (b) the lighting view's
        /// colorize-pass opacity: a neon-vivid cover approaches 1,
        /// a muted / sepia cover approaches 0.
        var vibrancy: Double {
            min(1.0, max(0.0, meanChromaticSaturation * meanChromaticBrightness))
        }
    }

    /// Full match pipeline for one artwork image. Deterministic;
    /// safe to call off-main. Chromatic covers produce a generated
    /// "Cover shades" set whose tones use ONLY the detected hues;
    /// achromatic covers resolve to the catalogue fallback.
    static func match(for image: NSImage) -> MatchResult {
        let histogram = StageSetMatcher.histogram(from: image)
        let match = StageSetMatcher.match(histogram: histogram,
                                          descriptors: descriptors,
                                          fallbackIndex: fallbackIndex)
        // Same chromaticity gate the matcher applies internally —
        // topHues can be non-empty even below the chromatic floor.
        let chromatic = histogram.chromaticFraction >= StageSetMatcher.minChromaticFraction
            && !match.topHues.isEmpty
        let vibrancy = min(1.0, max(0.0, histogram.meanChromaticSaturation
                                        * histogram.meanChromaticBrightness))
        // Contrast injection: an all-similar ladder (every detected
        // hue within 40° — e.g. an all-orange sleeve) lights the
        // room in one colour family. One much-different tone is
        // required for visual variety: prefer a REAL minor cover
        // hue the peak floor dropped (sky, logo), fall back to the
        // colour-theory complement of the dominant hue.
        var contrast: (hue: Double, fromCover: Bool)?
        if chromatic, huesAllSimilar(match.topHues) {
            if let recovered = StageSetMatcher.contrastHue(in: histogram,
                                                          awayFrom: match.topHues) {
                contrast = (recovered, true)
            } else if let h1 = match.topHues.first {
                contrast = (StageSetMatcher.normalizedHue(h1 + 180), false)
            }
        }
        // Mostly black/white/greyscale cover → neon R/G/B. Full
        // vibrancy is reported so the colorize/glow grading renders
        // the gels at arcade strength instead of muting them by the
        // cover's (near-zero) measured chroma.
        if histogram.chromaticFraction < neonAchromaticMaxFraction {
            return MatchResult(index: fallbackIndex,
                               generated: neonRGBSet,
                               topHues: match.topHues,
                               chromaticFraction: histogram.chromaticFraction,
                               meanChromaticSaturation: 1,
                               meanChromaticBrightness: 1)
        }
        return MatchResult(index: fallbackIndex,
                           generated: chromatic
                               ? coverShadesSet(topHues: match.topHues,
                                                vibrancy: vibrancy,
                                                contrast: contrast)
                               : nil,
                           topHues: match.topHues,
                           chromaticFraction: histogram.chromaticFraction,
                           meanChromaticSaturation: histogram.meanChromaticSaturation,
                           meanChromaticBrightness: histogram.meanChromaticBrightness)
    }

    /// True when every pairwise circular distance between the given
    /// hues is at most 40° — the ladder would read as one colour
    /// family.
    static func huesAllSimilar(_ hues: [Double]) -> Bool {
        guard hues.count > 1 else { return true }
        for i in hues.indices {
            for j in hues.indices where j > i {
                if StageSetMatcher.hueDistance(hues[i], hues[j]) > 40 { return false }
            }
        }
        return true
    }

    // MARK: - Generated cover-shades set

    /// Builds the "Cover shades" set: all four roles are club-graded
    /// shades of the detected hues — exact hue values, no offsets,
    /// no added hues. Colour theory grades the ladder only (wash
    /// deepest, accent brightest).
    ///
    /// Role assignment by peak count (hues in descending mass order):
    ///   - 3 peaks: wash + accent on hue 1, beams on hues 2 and 3.
    ///   - 2 peaks: wash, mid beam A and accent on hue 1 (dominant),
    ///     beam B mid on hue 2.
    ///   - 1 peak: single-hue ladder — deep wash, mid beam A,
    ///     lighter desaturated beam B, bright accent.
    ///
    /// `vibrancy` (mean saturation × mean brightness of the cover's
    /// chromatic pixels, [0, 1]) grades the ladder's saturation:
    /// each saturation constant lerps between (base − 0.10) at
    /// vibrancy 0 and (base + 0.12, capped 0.95) at vibrancy 1.
    /// Brightness lerps upward only — base at vibrancy 0 to
    /// (base + 0.12, capped 0.95) at vibrancy 1 — never below base:
    /// a muted cover's neutrality comes from the reduced colorize
    /// tint, and darkening the glow tones as well leaves the wall
    /// reading unlit (observed with Demons and Wizards, v = 0.20).
    ///
    /// `contrast` (all-similar ladders only) replaces beam A — the
    /// least-bright beam — with the opposing hue so one light always
    /// differs from the colour family (observed need: an all-
    /// orange sleeve lit the room in undifferentiated amber).
    ///
    /// Every tone passes through `gelTone`, the stage-gel gamut
    /// clamp — there is no brown stage light.
    /// Deterministic — a pure function of the inputs.
    static func coverShadesSet(topHues: [Double], vibrancy: Double,
                               contrast: (hue: Double, fromCover: Bool)? = nil) -> StageSet {
        let hues = Array(topHues.prefix(3))
        precondition(!hues.isEmpty,
                     "coverShadesSet requires at least one detected hue")
        let h1 = hues[0]
        let degrees = hues.map { String(format: "%.0f°", $0) }
            .joined(separator: ", ")
        var basis = (hues.count == 1
            ? "Shades of detected hue \(degrees)"
            : "Shades of detected hues \(degrees)")
            + String(format: ", vibrancy %.2f", vibrancy)
        if let contrast {
            basis += String(format: "; contrast beam %.0f° (%@)",
                            contrast.hue,
                            contrast.fromCover
                                ? "cover minor hue" : "complementary")
        }
        let v = min(max(vibrancy, 0), 1)
        // Neon push with a CLUB FLOOR: the room is a club, so even a
        // muted cover gets a third of the push toward gel intensity —
        // the previous grading let mid-vibrancy covers read as paint
        // chips (reported: colours need more lighting intensity).
        // Vivid covers go full neon: saturation to the gel ceiling,
        // brightness lifted harder than before, and no de-saturation
        // below the base ladder at any vibrancy.
        let vClub = 0.35 + 0.65 * v
        func gradedSat(_ base: Double) -> Double {
            let high = min(base + 0.20, 0.98)
            return base + (high - base) * vClub
        }
        func gradedBri(_ base: Double) -> Double {
            base + (min(base + 0.35, 0.98) - base) * vClub
        }
        // Stage-gel gamut clamp on every generated tone. Primary
        // hues get the CYBERPUNK-NEON treatment: a detected red,
        // green, or blue (within 25° of 0/120/240) renders as a
        // tube glow on dark — saturation pinned to the ceiling,
        // brightness held in a deep 0.50–0.72 band (dark blue, deep
        // red — intense colour, restrained luminance) regardless of
        // the cover's measured vibrancy. The hue itself stays exact.
        func gel(hue: Double, s: Double, b: Double) -> StageTone {
            // Cold band (cyan through blue, 175–265°): CYBERPUNK
            // BLUE — the hue snaps 70% of the way to pure blue 235°,
            // saturation to the ceiling, brightness deep (0.42–0.58).
            // Intense pure dark blue, not a bright cyan.
            if StageSetMatcher.hueDistance(hue, 220) <= 45 {
                let snapped = hue + (235 - hue) * 0.7
                return tone(hue: snapped, s: 0.99,
                            b: min(max(b, 0.42), 0.58))
            }
            // Red / green primaries: deep saturated glow, exact hue.
            // Direct tone() — gelBrightnessFloor would lift the deep
            // band back up; at ceiling saturation the dark primaries
            // stay rich, not muddy.
            if StageSetMatcher.hueDistance(hue, 0) <= 25 {
                return tone(hue: hue, s: max(s, 0.96),
                            b: min(max(b, 0.50), 0.70))
            }
            if StageSetMatcher.hueDistance(hue, 120) <= 25 {
                return tone(hue: hue, s: max(s, 0.95),
                            b: min(max(b, 0.48), 0.66))
            }
            return gelTone(hue: hue, s: s, b: b)
        }
        // Beam A carries the contrast hue when present — the least
        // bright of the two beams, so the opposing colour reads as
        // variety, not a repaint.
        let beamAHue: Double
        switch (contrast, hues.count) {
        case (let c?, _): beamAHue = c.hue
        case (nil, 1), (nil, 2): beamAHue = h1
        default: beamAHue = hues[1]
        }
        let wash: StageTone, beamA: StageTone
        let beamB: StageTone, accent: StageTone
        switch hues.count {
        case 1:
            wash = gel(hue: h1, s: gradedSat(0.88), b: gradedBri(0.50))
            beamA = gel(hue: beamAHue, s: gradedSat(0.80), b: gradedBri(0.68))
            beamB = gel(hue: h1, s: gradedSat(0.55), b: gradedBri(0.78))
            accent = gel(hue: h1, s: gradedSat(0.92), b: gradedBri(0.88))
        case 2:
            wash = gel(hue: h1, s: gradedSat(washSat), b: gradedBri(washBri))
            beamA = gel(hue: beamAHue, s: gradedSat(0.75), b: gradedBri(0.68))
            beamB = gel(hue: hues[1], s: gradedSat(beamSat), b: gradedBri(beamBri))
            accent = gel(hue: h1, s: gradedSat(accentSat), b: gradedBri(accentBri))
        default:
            wash = gel(hue: h1, s: gradedSat(washSat), b: gradedBri(washBri))
            beamA = gel(hue: beamAHue, s: gradedSat(beamSat), b: gradedBri(beamBri))
            beamB = gel(hue: hues[2], s: gradedSat(beamSat), b: gradedBri(beamBri))
            accent = gel(hue: h1, s: gradedSat(accentSat), b: gradedBri(accentBri))
        }
        return StageSet(id: generatedSetID,
                        name: "Cover shades",
                        theoryBasis: basis,
                        rootHue: StageSetMatcher.normalizedHue(h1),
                        // Family is catalogue metadata; generated
                        // sets carry no theory family — nearest
                        // label used as a placeholder.
                        family: .analogous,
                        wash: wash, beamA: beamA,
                        beamB: beamB, accent: accent)
    }

    // MARK: - Fixed colour schemes (Settings)

    /// Sentinel ids for the two Settings-selected fixed schemes —
    /// never valid indices into `sets`.
    static let choragusSetID = -2
    static let customSetID = -3

    /// The "Choragus" scheme — neon colours sampled from the wordmark
    /// asset (`ChoragusTextLogo.imageset/choragus_text_dark@2x.png`,
    /// per-hue-cluster means of pixels with s ≥ 0.35 ∧ v ≥ 0.35):
    ///   cyan   187° s 0.99 (#02E1FE)  — largest cluster
    ///   azure  203° s 0.94 (#0FA5FE)
    ///   violet 248° s 0.66 (#6E56FE)
    ///   purple 277° s 0.73 (#B644FE)
    /// The source pixels all sit at brightness ~1.0 (screen neon);
    /// brightness here is role-graded to the catalogue ladder (wash
    /// deepest, accent brightest) so the set behaves like every
    /// other stage set under the club grading. Hue and saturation
    /// are the sampled values.
    static let choragusSet = StageSet(
        id: choragusSetID,
        name: "Choragus",
        theoryBasis: "Neon hues sampled from the Choragus wordmark — cyan 187°, azure 203°, violet 248°, purple 277°",
        rootHue: 248,
        family: .analogous,
        wash: tone(hue: 248, s: 0.66, b: washBri),
        beamA: tone(hue: 187, s: 0.99, b: beamBri),
        beamB: tone(hue: 277, s: 0.73, b: beamBri),
        accent: tone(hue: 203, s: 0.94, b: accentBri))

    /// Mostly-monochrome threshold: below this chromatic fraction a
    /// cover is treated as black/white/greyscale for lighting
    /// purposes. Deliberately ABOVE the matcher's chromatic floor —
    /// a sliver of colour (a logo, a sticker) cannot honestly drive
    /// a whole room's lighting.
    static let neonAchromaticMaxFraction = 0.05

    static let neonRGBSetID = -3

    /// Neon R/G/B for monochrome sleeves: no hue evidence on the
    /// cover, so instead of a muted house fallback the room goes
    /// full arcade — saturated primary red / green / blue gels.
    static let neonRGBSet = StageSet(
        id: neonRGBSetID,
        name: "Neon RGB",
        theoryBasis: "Monochrome cover — cyberpunk neon: deep blue 240°, red 0°, green 120°",
        rootHue: 240,
        family: .triadic,
        wash: tone(hue: 237, s: 0.99, b: 0.45),
        beamA: tone(hue: 0, s: 0.96, b: 0.66),
        beamB: tone(hue: 120, s: 0.95, b: 0.60),
        accent: tone(hue: 235, s: 0.98, b: 0.62))

    /// The "Custom" scheme — four user-selected tones from Settings.
    /// Malformed / missing stored hex values fall back to the
    /// Choragus scheme's corresponding role tone so a half-configured
    /// custom scheme still renders a coherent set.
    static func customSet(washHex: String, beamAHex: String,
                          beamBHex: String, accentHex: String) -> StageSet {
        StageSet(id: customSetID,
                 name: "Custom",
                 theoryBasis: "User-selected wash / beam / accent tones (Settings)",
                 rootHue: 0,
                 family: .analogous,
                 wash: StageTone(hex: washHex) ?? choragusSet.wash,
                 beamA: StageTone(hex: beamAHex) ?? choragusSet.beamA,
                 beamB: StageTone(hex: beamBHex) ?? choragusSet.beamB,
                 accent: StageTone(hex: accentHex) ?? choragusSet.accent)
    }

    // MARK: - Family constructors

    /// Analogous — wash and accent on the root, beams at root ± 25°.
    private static func analogous(_ id: Int, _ name: String, root: Double) -> StageSet {
        StageSet(id: id, name: name,
                 theoryBasis: "Analogous — root \(Int(root))°, beams at ±25°",
                 rootHue: root, family: .analogous,
                 wash: gelTone(hue: root, s: washSat, b: washBri),
                 beamA: gelTone(hue: root - 25, s: beamSat, b: beamBri),
                 beamB: gelTone(hue: root + 25, s: beamSat, b: beamBri),
                 accent: gelTone(hue: root, s: accentSat, b: accentBri))
    }

    /// Split-complementary — wash and accent on the root, beams at
    /// root ± 150° (the two hues flanking the complement).
    private static func splitComplementary(_ id: Int, _ name: String, root: Double) -> StageSet {
        StageSet(id: id, name: name,
                 theoryBasis: "Split-complementary — root \(Int(root))°, beams at +150° / −150°",
                 rootHue: root, family: .splitComplementary,
                 wash: gelTone(hue: root, s: washSat, b: washBri),
                 beamA: gelTone(hue: root + 150, s: beamSat, b: beamBri),
                 beamB: gelTone(hue: root - 150, s: beamSat, b: beamBri),
                 accent: gelTone(hue: root, s: accentSat, b: accentBri))
    }

    /// Triadic — wash and accent on the root, beams at root + 120°
    /// and root + 240°.
    private static func triadic(_ id: Int, _ name: String, root: Double) -> StageSet {
        StageSet(id: id, name: name,
                 theoryBasis: "Triadic — root \(Int(root))°, beams at +120° / +240°",
                 rootHue: root, family: .triadic,
                 wash: gelTone(hue: root, s: washSat, b: washBri),
                 beamA: gelTone(hue: root + 120, s: beamSat, b: beamBri),
                 beamB: gelTone(hue: root + 240, s: beamSat, b: beamBri),
                 accent: gelTone(hue: root, s: accentSat, b: accentBri))
    }

    // MARK: - Colour math

    /// HSB → display RGB. Hue in degrees (any value, wrapped).
    /// Stage-gel gamut: these tones drive simulated stage lights,
    /// and no fixture produces brown — brown is dark orange/yellow,
    /// a hue-brightness combination a lit gel cannot reach. Warm-
    /// band hues (15°–75°) get a 0.92 brightness floor: 0.78 still
    /// read as ochre/brown on the wall (observed) — a real amber
    /// gel sits near full brightness. Every hue gets a 0.60
    /// saturation floor (a gel is a colour, not a tint) and a 0.55
    /// brightness floor (a light is on).
    static func gelBrightnessFloor(hue: Double) -> Double {
        let h = StageSetMatcher.normalizedHue(hue)
        if h >= 15 && h <= 75 { return 0.92 }   // amber/yellow: brown below
        if h < 20 || h >= 345 { return 0.75 }   // red: brick/maroon below
        return 0.65
    }

    static func gelTone(hue: Double, s: Double, b: Double) -> StageTone {
        tone(hue: hue,
             s: max(s, 0.60),
             b: max(b, gelBrightnessFloor(hue: hue)))
    }

    private static func tone(hue: Double, s: Double, b v: Double) -> StageTone {
        let wrapped = StageSetMatcher.normalizedHue(hue)
        let h = wrapped / 60.0
        let i = Int(h.rounded(.down)) % 6
        let f = h - h.rounded(.down)
        let p = v * (1 - s)
        let q = v * (1 - s * f)
        let t = v * (1 - s * (1 - f))
        switch i {
        case 0: return StageTone(r: v, g: t, b: p)
        case 1: return StageTone(r: q, g: v, b: p)
        case 2: return StageTone(r: p, g: v, b: t)
        case 3: return StageTone(r: p, g: q, b: v)
        case 4: return StageTone(r: t, g: p, b: v)
        default: return StageTone(r: v, g: p, b: q)
        }
    }
}
