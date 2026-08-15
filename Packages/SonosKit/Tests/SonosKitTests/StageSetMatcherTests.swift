import XCTest
import AppKit
@testable import SonosKit

/// Covers the album-art → stage-set selection math behind the Back
/// of the Club lighting system. Histograms are built either from
/// synthetic CGContext images (achromatic-exclusion coverage) or
/// constructed directly (selection-rule coverage).
final class StageSetMatcherTests: XCTestCase {

    /// 10 roots × 3 families, mirroring the app target's declaration
    /// order: fallback occupies index 0, then per root analogous /
    /// split-complementary / triadic. Built through the
    /// backward-compatible root+family init, which derives each
    /// descriptor's hue triple.
    private let descriptors: [StageSetDescriptor] = {
        var out: [StageSetDescriptor] = []
        var index = 1
        for step in 0..<10 {
            let root = Double(step) * 36.0
            for family in StageSetFamily.allCases {
                out.append(StageSetDescriptor(index: index, rootHue: root, family: family))
                index += 1
            }
        }
        return out
    }()

    /// Index a (rootStep, family) pair occupies in the fixture.
    private func fixtureIndex(rootStep: Int, family: StageSetFamily) -> Int {
        1 + rootStep * 3 + StageSetFamily.allCases.firstIndex(of: family)!
    }

    private func makeImage(width: Int = 48, height: Int = 48,
                           draw: (CGContext) -> Void) -> NSImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil,
                            width: width,
                            height: height,
                            bitsPerComponent: 8,
                            bytesPerRow: width * 4,
                            space: colorSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(ctx)
        let cg = ctx.makeImage()!
        return NSImage(cgImage: cg, size: NSSize(width: width, height: height))
    }

    /// Builds a histogram with all mass placed at the bins whose
    /// centres are nearest the given hues.
    private func histogram(hues: [(hue: Double, mass: Double)],
                           chromaticFraction: Double = 1.0) -> HueHistogram {
        var mass = [Double](repeating: 0, count: HueHistogram.binCount)
        for (hue, m) in hues {
            let bin = min(HueHistogram.binCount - 1,
                          Int(StageSetMatcher.normalizedHue(hue) / 360.0 * Double(HueHistogram.binCount)))
            mass[bin] += m
        }
        return HueHistogram(mass: mass, chromaticFraction: chromaticFraction)
    }

    // MARK: - Achromatic exclusion

    func testGrayscaleImageHistogramHasNoChromaticMass() {
        let img = makeImage { ctx in
            for x in 0..<48 {
                let v = CGFloat(x) / 47.0
                ctx.setFillColor(CGColor(red: v, green: v, blue: v, alpha: 1))
                ctx.fill(CGRect(x: x, y: 0, width: 1, height: 48))
            }
        }
        let h = StageSetMatcher.histogram(from: img)
        XCTAssertLessThan(h.chromaticFraction, StageSetMatcher.minChromaticFraction)
        XCTAssertEqual(h.mass.reduce(0, +), 0, accuracy: 0.001)
    }

    func testNearBlackAndNearWhitePixelsExcluded() {
        // Saturated hue at brightness extremes — outside the
        // [minBrightness, maxBrightness] window on both sides.
        let img = makeImage { ctx in
            ctx.setFillColor(CGColor(red: 0.08, green: 0.0, blue: 0.0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 48, height: 24))
            ctx.setFillColor(CGColor(red: 1.0, green: 0.97, blue: 0.97, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 24, width: 48, height: 24))
        }
        let h = StageSetMatcher.histogram(from: img)
        XCTAssertLessThan(h.chromaticFraction, StageSetMatcher.minChromaticFraction)
    }

    func testAchromaticHistogramFallsBackToIndexZero() {
        let h = histogram(hues: [(0, 100)], chromaticFraction: 0.005)
        let result = StageSetMatcher.match(histogram: h,
                                           descriptors: descriptors,
                                           fallbackIndex: 0)
        XCTAssertEqual(result.index, 0)
        // Peak hues are still reported for UI display in the
        // fallback case.
        XCTAssertEqual(result.topHues, [5.0])
    }

    // MARK: - Peak extraction

    func testCloseTogetherPeaksSuppressToOne() {
        // Two maxima 10° apart (bin centres 105° / 115°) sit inside
        // one suppression radius — they must merge into a single
        // peak carrying the combined mass, anchored at the
        // mass-weighted mean hue (60:40 across 105/115 → 109°).
        let h = histogram(hues: [(100, 60), (110, 40)])
        let result = StageSetMatcher.match(histogram: h,
                                           descriptors: descriptors,
                                           fallbackIndex: 0)
        XCTAssertEqual(result.topHues.count, 1)
        XCTAssertEqual(result.topHues[0], 109, accuracy: 0.5)
        // Merged peak at 105° → all three root-108 sets cover it at
        // distance 3, but only the analogous set keeps every
        // declared hue near the single peak (lowest groundedness).
        XCTAssertEqual(result.index, fixtureIndex(rootStep: 3, family: .analogous))
    }

    func testTopHuesAreMassOrderedAndCappedAtThree() {
        // Four separated clusters — only the three heaviest survive,
        // ordered by descending mass.
        let h = histogram(hues: [(100, 10), (0, 40), (240, 30), (170, 20)])
        let result = StageSetMatcher.match(histogram: h,
                                           descriptors: descriptors,
                                           fallbackIndex: 0)
        XCTAssertEqual(result.topHues, [5.0, 245.0, 175.0])
    }

    // MARK: - Family selection

    func testSinglePeakSelectsAnalogous() {
        // All mass in one bin → one peak at 35°. All three root-36
        // sets cover it at distance 1; the analogous set wins
        // outright on groundedness — its secondaries sit ±25° from
        // the peak versus ±120° (triadic) / 150°+210° (split).
        let h = histogram(hues: [(36, 100)])
        let result = StageSetMatcher.match(histogram: h,
                                           descriptors: descriptors,
                                           fallbackIndex: 0)
        XCTAssertEqual(result.topHues, [35.0])
        XCTAssertEqual(result.index, fixtureIndex(rootStep: 1, family: .analogous))
    }

    func testComplementaryPairSelectsSplitComplementary() {
        // Similar-mass peaks at 35° / 185°. Root-36
        // split-complementary declares [36, 186, 246] — both peaks
        // land within 1° of a declared hue; no other descriptor
        // covers both. Similar mass matters under bidirectional
        // scoring: a lopsided split (e.g. 70/30) shrinks the
        // analogous set's coverage penalty for the secondary peak
        // below the split set's groundedness penalty for its
        // unmatched 246° hue, and analogous wins instead.
        let h = histogram(hues: [(36, 50), (186, 50)])
        let result = StageSetMatcher.match(histogram: h,
                                           descriptors: descriptors,
                                           fallbackIndex: 0)
        XCTAssertEqual(result.index, fixtureIndex(rootStep: 1, family: .splitComplementary))
    }

    func testRainbowHistogramSelectsTriadicOverAnalogous() {
        // Rainbow-like cover: three spread peaks at 5° / 125° / 245°
        // (red / green / blue on black). Root-0 triadic declares
        // [0, 120, 240] — 5° from every peak, so both its coverage
        // and its groundedness are near zero. Root-0 analogous
        // covers only the red peak and scores far worse on both
        // terms.
        let h = histogram(hues: [(0, 40), (120, 30), (240, 30)])
        let result = StageSetMatcher.match(histogram: h,
                                           descriptors: descriptors,
                                           fallbackIndex: 0)
        XCTAssertEqual(result.topHues, [5.0, 125.0, 245.0])
        XCTAssertEqual(result.index, fixtureIndex(rootStep: 0, family: .triadic))
    }

    func testNeighbouringHueMassMergesAndSelectsAnalogous() {
        // Wide single-hue cluster (216° ± 20°): all three bins merge
        // into one peak at 215°, 1° from the root-216 hue shared by
        // its three sets → analogous wins on groundedness (all its
        // hues stay within 26° of the sole peak).
        let h = histogram(hues: [(216, 60), (196, 20), (236, 20)])
        let result = StageSetMatcher.match(histogram: h,
                                           descriptors: descriptors,
                                           fallbackIndex: 0)
        XCTAssertEqual(result.topHues, [215.0])
        XCTAssertEqual(result.index, fixtureIndex(rootStep: 6, family: .analogous))
    }

    // MARK: - Groundedness

    func testAboveFloorSecondarySelectsCoveringSplitComplementary() {
        // Salmon-pink cover with a genuine secondary: peaks at 15°
        // (mass 75) and 225° (mass 25). The weak-secondary defence
        // moved into the relative-mass floor (0.25 × dominant,
        // covered by testTracePeakIsDroppedByRelativeMassFloor):
        // any secondary that SURVIVES the floor carries ≥ 20% of
        // normalized peak mass, and covering both peaks then always
        // outweighs analogous groundedness —
        //   coverage(root-0 analogous) − coverage(root-216 split)
        //     = 1 + 100·m₂ ≥ 21  >  4λ = 4·(14.4/3) = 19.2
        // — so no admissible two-peak fixture of this geometry can
        // select analogous. A surviving secondary is a real cover
        // colour: the root-216 split-complementary set [216, 6, 66],
        // which covers both peaks within 9°, must win.
        let h = histogram(hues: [(15, 75), (220, 25)])
        let result = StageSetMatcher.match(histogram: h,
                                           descriptors: descriptors,
                                           fallbackIndex: 0)
        XCTAssertEqual(result.topHues, [15.0, 225.0])
        XCTAssertEqual(result.index, fixtureIndex(rootStep: 6, family: .splitComplementary))
    }

    // MARK: - Chromatic saturation / brightness means

    func testHistogramRecordsChromaticSaturationAndBrightnessMeans() {
        // Uniform vivid red (s 0.75, v 0.80) vs uniform muted
        // red-grey (s 0.25, v 0.50). Uniform fills keep the means
        // independent of population weighting; the wide accuracy
        // absorbs the CGContext colour-space round-trip. The final
        // ordering assertion is the property the vibrancy grading
        // relies on: vivid covers must report a higher
        // saturation × brightness product than muted ones.
        let vivid = makeImage { ctx in
            ctx.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.2, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 48, height: 48))
        }
        let muted = makeImage { ctx in
            ctx.setFillColor(CGColor(red: 0.5, green: 0.375, blue: 0.375, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 48, height: 48))
        }
        let hv = StageSetMatcher.histogram(from: vivid)
        let hm = StageSetMatcher.histogram(from: muted)
        XCTAssertEqual(hv.meanChromaticSaturation, 0.75, accuracy: 0.08)
        XCTAssertEqual(hv.meanChromaticBrightness, 0.80, accuracy: 0.08)
        XCTAssertEqual(hm.meanChromaticSaturation, 0.25, accuracy: 0.08)
        XCTAssertEqual(hm.meanChromaticBrightness, 0.50, accuracy: 0.08)
        XCTAssertGreaterThan(hv.meanChromaticSaturation * hv.meanChromaticBrightness,
                             hm.meanChromaticSaturation * hm.meanChromaticBrightness)
    }

    func testAchromaticImageMeansAreZero() {
        // Grayscale gradient — zero chromatic pixels, so the means
        // report 0 rather than NaN from a 0/0 division.
        let img = makeImage { ctx in
            for x in 0..<48 {
                let v = CGFloat(x) / 47.0
                ctx.setFillColor(CGColor(red: v, green: v, blue: v, alpha: 1))
                ctx.fill(CGRect(x: x, y: 0, width: 1, height: 48))
            }
        }
        let h = StageSetMatcher.histogram(from: img)
        XCTAssertEqual(h.meanChromaticSaturation, 0)
        XCTAssertEqual(h.meanChromaticBrightness, 0)
    }

    func testDirectHistogramInitDefaultsMeansToZero() {
        // Fixture histograms built without the new fields keep
        // decoding/behaving as before — means default to 0.
        let h = histogram(hues: [(15, 100)])
        XCTAssertEqual(h.meanChromaticSaturation, 0)
        XCTAssertEqual(h.meanChromaticBrightness, 0)
    }

    func testTracePeakIsDroppedByRelativeMassFloor() {
        // 85° carries 12% of the dominant peak's mass — a trace hue
        // (olive shadows on a red-orange cover) that must NOT become
        // a projected beam colour. Sits just under the 0.15 floor.
        let h = histogram(hues: [(15, 88), (85, 12)])
        let result = StageSetMatcher.match(histogram: h,
                                           descriptors: descriptors,
                                           fallbackIndex: 0)
        XCTAssertEqual(result.topHues, [15.0])
    }

    // MARK: - Colour-group discounting

    func testSecondWarmShadeAbsorbedIntoOneGroupPeak() {
        // Orange 25° dominant plus yellow 55° — same orange/yellow
        // group. Must merge into ONE warm peak rather than spending
        // two of the three peak slots on shades of the same colour
        // family, anchored at the mass-weighted mean (60:40 across
        // 25/55 → 37°) so the reported tone represents the mixture,
        // not just the tallest bin.
        let h = histogram(hues: [(25, 60), (55, 40)])
        let result = StageSetMatcher.match(histogram: h,
                                           descriptors: descriptors,
                                           fallbackIndex: 0)
        XCTAssertEqual(result.topHues.count, 1)
        XCTAssertEqual(result.topHues[0], 37, accuracy: 0.5)
    }

    func testMagentaSurvivesNextToDominantRed() {
        // Magenta-dominant psychedelic sleeve geometry: pink mass at
        // 335° sits inside the 30° radius of a red peak at 5° but is
        // a different colour group across a sharp boundary — it must
        // become its own peak, not be swallowed into the red.
        let h = histogram(hues: [(5, 55), (335, 45)])
        let result = StageSetMatcher.match(histogram: h,
                                           descriptors: descriptors,
                                           fallbackIndex: 0)
        XCTAssertEqual(result.topHues, [5.0, 335.0])
    }

    /// Histogram with explicit per-bin mean saturation for the
    /// slot-filling gates.
    private func histogramWithSat(hues: [(hue: Double, mass: Double, sat: Double)])
        -> HueHistogram {
        var mass = [Double](repeating: 0, count: HueHistogram.binCount)
        var sat = [Double](repeating: 0, count: HueHistogram.binCount)
        for (hue, m, s) in hues {
            let bin = min(HueHistogram.binCount - 1,
                          Int(StageSetMatcher.normalizedHue(hue) / 360.0 * Double(HueHistogram.binCount)))
            mass[bin] += m
            sat[bin] = s
        }
        return HueHistogram(mass: mass, chromaticFraction: 1.0,
                            binMeanSaturation: sat)
    }

    func testSmallSaturatedColoursFillRemainingPeakSlots() {
        // Freeze Frame geometry: dominant yellow checkerboard with
        // small but REAL saturated green (8%) and teal (4%) — both
        // under the stage-1 relative floor. The slot-filling stage
        // must surface them so the ladder reads yellow / green /
        // teal instead of three yellow shades.
        let h = histogramWithSat(hues: [(55, 88, 0.85),
                                        (125, 8, 0.70),
                                        (185, 4, 0.65)])
        let result = StageSetMatcher.match(histogram: h,
                                           descriptors: descriptors,
                                           fallbackIndex: 0)
        XCTAssertEqual(result.topHues, [55.0, 125.0, 185.0])
    }

    func testLowSaturationResidueDoesNotFillSlots() {
        // Same masses, but the small hues are LOW-saturation residue
        // (shadow/antialiasing) — the saturation gate keeps them out
        // and the cover stays single-peak.
        let h = histogramWithSat(hues: [(55, 88, 0.85),
                                        (125, 8, 0.30),
                                        (185, 4, 0.25)])
        let result = StageSetMatcher.match(histogram: h,
                                           descriptors: descriptors,
                                           fallbackIndex: 0)
        XCTAssertEqual(result.topHues, [55.0])
    }

    func testDistinctRedSurvivesNextToDominantOrange() {
        // Screaming for Vengeance geometry: dominant orange field
        // with a red element at ~19% of its mass only 20° away — a
        // DIFFERENT colour group that must become its own peak
        // (previously absorbed by the 30° radius, producing three
        // warm shades while the cover's red went undetected). The
        // 8% blue stays under the floor and is left for the
        // contrast-recovery path.
        let h = histogram(hues: [(25, 70), (5, 13), (215, 8)])
        let result = StageSetMatcher.match(histogram: h,
                                           descriptors: descriptors,
                                           fallbackIndex: 0)
        XCTAssertEqual(result.topHues, [25.0, 5.0])
    }

    func testComplementaryPeaksSelectSplitOverAnalogousAndTriad() {
        // Two strong near-complementary peaks at 5° / 185° with
        // similar mass (0.55 / 0.45). Split-complementary is the
        // only family that covers both peaks while keeping most of
        // its declared hues grounded; analogous leaves the 185° peak
        // uncovered, triadic carries an ungrounded third hue 55°+
        // from any peak. Root-0 split [0, 150, 210] wins.
        let h = histogram(hues: [(0, 55), (185, 45)])
        let result = StageSetMatcher.match(histogram: h,
                                           descriptors: descriptors,
                                           fallbackIndex: 0)
        XCTAssertEqual(result.topHues, [5.0, 185.0])
        XCTAssertEqual(result.index, fixtureIndex(rootStep: 0, family: .splitComplementary))
    }

    // MARK: - Peak-mass weighting

    func testMassWeightingDecidesBetweenCoveringSets() {
        // Peaks at 5° / 185°. Sparse two-descriptor list (precedent:
        // testHueWraparoundDistance) isolates the coverage term's
        // mass weighting: both split sets have identical groundedness
        // against these peaks (per-hue distances 31/1/61 vs 31/1/61),
        // so only mass-weighted coverage separates them. Root-216
        // declares hue 6° (1° from the 5° peak, 31° from the 185°
        // peak); root-36 declares hue 186° (the mirror). The heavier
        // peak decides which wins.
        let sparse = [
            StageSetDescriptor(index: 1, rootHue: 216, family: .splitComplementary), // [216, 6, 66]
            StageSetDescriptor(index: 2, rootHue: 36, family: .splitComplementary),  // [36, 186, 246]
        ]
        let heavyRed = histogram(hues: [(5, 80), (185, 20)])
        let redResult = StageSetMatcher.match(histogram: heavyRed,
                                              descriptors: sparse,
                                              fallbackIndex: 0)
        XCTAssertEqual(redResult.index, 1)

        let heavyCyan = histogram(hues: [(5, 20), (185, 80)])
        let cyanResult = StageSetMatcher.match(histogram: heavyCyan,
                                               descriptors: sparse,
                                               fallbackIndex: 0)
        XCTAssertEqual(cyanResult.index, 2)
    }

    func testHueWraparoundDistance() {
        // Sparse two-descriptor list isolates the wrap: a peak at
        // 355° is 5° from hue 0° through the wrap but 6° from hue
        // 349°. A non-circular distance would read 355° to hue 0°
        // and pick the second descriptor.
        let sparse = [
            StageSetDescriptor(index: 1, rootHue: 0, family: .analogous),   // [0, 335, 25]
            StageSetDescriptor(index: 2, rootHue: 324, family: .analogous), // [324, 299, 349]
        ]
        let h = histogram(hues: [(350, 100)])
        let result = StageSetMatcher.match(histogram: h,
                                           descriptors: sparse,
                                           fallbackIndex: 0)
        XCTAssertEqual(result.index, 1)
    }

    // MARK: - Determinism

    func testMatchIsDeterministicOverRepeatedCalls() {
        let img = makeImage { ctx in
            ctx.setFillColor(CGColor(red: 0.10, green: 0.20, blue: 0.90, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 48, height: 30))
            ctx.setFillColor(CGColor(red: 0.95, green: 0.55, blue: 0.10, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 30, width: 48, height: 18))
        }
        let first = StageSetMatcher.histogram(from: img)
        let firstResult = StageSetMatcher.match(histogram: first,
                                                descriptors: descriptors,
                                                fallbackIndex: 0)
        for _ in 0..<5 {
            let h = StageSetMatcher.histogram(from: img)
            XCTAssertEqual(h, first)
            XCTAssertEqual(StageSetMatcher.match(histogram: h,
                                                 descriptors: descriptors,
                                                 fallbackIndex: 0),
                           firstResult)
        }
    }

    func testEmptyDescriptorListFallsBack() {
        let h = histogram(hues: [(120, 100)])
        XCTAssertEqual(StageSetMatcher.match(histogram: h,
                                             descriptors: [],
                                             fallbackIndex: 0).index, 0)
    }

    // MARK: - Contrast-hue recovery

    func testContrastHueRecoversFarMinorHue() {
        // Orange-dominant cover with a small REAL blue population
        // (~1.2% of chromatic mass) — under the relative peak floor,
        // but recoverable as the contrast hue.
        var mass = [Double](repeating: 0, count: HueHistogram.binCount)
        mass[2] = 800    // 25°
        mass[3] = 150    // 35°
        mass[20] = 12    // 205°
        let h = HueHistogram(mass: mass, chromaticFraction: 0.5)
        let contrast = StageSetMatcher.contrastHue(in: h, awayFrom: [25, 35])
        XCTAssertNotNil(contrast)
        XCTAssertEqual(contrast ?? -1, 205, accuracy: 6)
    }

    func testContrastHueNilWhenNothingFarEnough() {
        // All mass within 60° of the peaks — no admissible candidate.
        var mass = [Double](repeating: 0, count: HueHistogram.binCount)
        mass[2] = 800
        mass[3] = 150
        mass[6] = 20     // 65° — only 40° from the 25° peak
        let h = HueHistogram(mass: mass, chromaticFraction: 0.5)
        XCTAssertNil(StageSetMatcher.contrastHue(in: h, awayFrom: [25, 35]))
    }

    func testContrastHueNilBelowMassFloor() {
        // A far hue exists but carries under contrastMinMassFraction
        // of total mass — noise, not a cover colour.
        var mass = [Double](repeating: 0, count: HueHistogram.binCount)
        mass[2] = 1000
        mass[20] = 2     // 0.2% of total
        let h = HueHistogram(mass: mass, chromaticFraction: 0.5)
        XCTAssertNil(StageSetMatcher.contrastHue(in: h, awayFrom: [25]))
    }
}
