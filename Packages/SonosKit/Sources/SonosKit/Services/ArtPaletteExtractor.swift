/// ArtPaletteExtractor.swift — Dominant-colour sampling for album art.
///
/// Produces the three lighting tones (primary / secondary / accent)
/// the Back of the Club visualisation uses to drive its fixture
/// colours from the now-playing artwork.
///
/// Method: downsample to 48×48, histogram in HSB space with
/// saturation × mid-brightness weighting, then pick:
///   - primary   = heaviest hue cluster (saturated mid-brightness
///     pixels dominate via the weighting),
///   - secondary = heaviest cluster ≥ 60° of hue away from primary
///     when one carries enough weight; otherwise a darker variant
///     of the primary hue,
///   - accent    = brightest sufficiently-saturated cluster;
///     otherwise a brighter variant of the primary hue.
///
/// Deterministic — no randomness; ties resolve to the lowest bin
/// index. Pure function of the input image, safe to call off-main.
/// Returns nil when the image has no usable chromatic content
/// (grayscale art, fully transparent, or no CGImage) so callers can
/// fall back to a fixed palette.
import AppKit
import CoreGraphics

public struct ArtPalette: Equatable, Sendable {
    /// One lighting tone as display-space RGB in [0, 1].
    public struct Tone: Equatable, Sendable {
        public let red: Double
        public let green: Double
        public let blue: Double
        public init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }
    }
    public let primary: Tone
    public let secondary: Tone
    public let accent: Tone
    public init(primary: Tone, secondary: Tone, accent: Tone) {
        self.primary = primary
        self.secondary = secondary
        self.accent = accent
    }
}

public enum ArtPaletteExtractor {
    // Tuning constants. Bin width is 360 / binCount degrees of hue.
    private static let sampleSize = 48
    private static let binCount = 36
    /// Pixels below this saturation carry no hue signal.
    private static let minSaturation = 0.15
    /// Near-black / near-white pixels are excluded — their hue is
    /// numerically unstable and visually irrelevant.
    private static let brightnessRange = 0.08...0.97
    /// Chromatic-pixel fraction below this → grayscale image → nil.
    private static let minChromaticFraction = 0.03
    /// Secondary must sit at least this many degrees of hue from
    /// primary to read as a distinct tone.
    private static let secondaryMinHueSeparation = 60.0
    /// Secondary cluster must carry at least this fraction of the
    /// primary cluster's weight; below it, a darker primary variant
    /// is used instead.
    private static let secondaryMinWeightFraction = 0.15
    /// Accent candidates need this much saturation to read as a
    /// highlight rather than a wash.
    private static let accentMinSaturation = 0.40
    /// Accent candidates below this fraction of primary weight are
    /// noise (single stray pixels).
    private static let accentMinWeightFraction = 0.05

    public static func extract(from image: NSImage) -> ArtPalette? {
        guard let pixels = downsample(image) else { return nil }

        // Hue histogram. Each qualifying pixel contributes weight
        // w = saturation × mid-brightness window, so saturated
        // mid-brightness hues dominate cluster selection. Hue means
        // are circular (sin/cos sums) so bins straddling 0° stay
        // correct.
        struct Bin {
            var weight = 0.0
            var cosSum = 0.0
            var sinSum = 0.0
            var satSum = 0.0
            var briSum = 0.0
        }
        var bins = [Bin](repeating: Bin(), count: binCount)
        var chromaticCount = 0
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
            guard s >= minSaturation, brightnessRange.contains(v) else { continue }
            chromaticCount += 1
            let w = s * max(0.05, 1.0 - abs(v - 0.55) * 1.6)
            let bin = min(binCount - 1, Int(h / 360.0 * Double(binCount)))
            let rad = h * .pi / 180.0
            bins[bin].weight += w
            bins[bin].cosSum += w * cos(rad)
            bins[bin].sinSum += w * sin(rad)
            bins[bin].satSum += w * s
            bins[bin].briSum += w * v
        }

        guard Double(chromaticCount) / Double(totalCount) >= minChromaticFraction else {
            return nil
        }

        // A cluster is a bin merged with half of each neighbour —
        // smooths hue quantisation at bin edges without letting a
        // single wide colour dominate every bin.
        struct Cluster {
            let index: Int
            let weight: Double
            let hue: Double
            let saturation: Double
            let brightness: Double
        }
        func cluster(at i: Int) -> Cluster? {
            let l = (i + binCount - 1) % binCount
            let r = (i + 1) % binCount
            let w = bins[i].weight + 0.5 * (bins[l].weight + bins[r].weight)
            guard w > 0 else { return nil }
            let cosSum = bins[i].cosSum + 0.5 * (bins[l].cosSum + bins[r].cosSum)
            let sinSum = bins[i].sinSum + 0.5 * (bins[l].sinSum + bins[r].sinSum)
            var hue = atan2(sinSum, cosSum) * 180.0 / .pi
            if hue < 0 { hue += 360 }
            let sat = (bins[i].satSum + 0.5 * (bins[l].satSum + bins[r].satSum)) / w
            let bri = (bins[i].briSum + 0.5 * (bins[l].briSum + bins[r].briSum)) / w
            return Cluster(index: i, weight: w, hue: hue, saturation: sat, brightness: bri)
        }

        // Primary — heaviest cluster; strict > with ascending scan
        // resolves ties to the lowest bin index.
        var primary: Cluster?
        for i in 0..<binCount {
            guard let c = cluster(at: i) else { continue }
            if c.weight > (primary?.weight ?? 0) { primary = c }
        }
        guard let primary else { return nil }

        // Secondary — heaviest cluster far enough from primary in
        // hue and carrying non-trivial weight.
        var secondary: Cluster?
        for i in 0..<binCount {
            guard let c = cluster(at: i),
                  hueDistance(c.hue, primary.hue) >= secondaryMinHueSeparation,
                  c.weight >= primary.weight * secondaryMinWeightFraction
            else { continue }
            if c.weight > (secondary?.weight ?? 0) { secondary = c }
        }

        // Accent — brightest cluster that is saturated enough to
        // read as a highlight and heavy enough to not be noise.
        var accent: Cluster?
        for i in 0..<binCount {
            guard let c = cluster(at: i),
                  c.saturation >= accentMinSaturation,
                  c.weight >= primary.weight * accentMinWeightFraction
            else { continue }
            if c.brightness > (accent?.brightness ?? -1) { accent = c }
        }

        // Brightness clamps keep the washes visible on a near-black
        // stage without blowing out — the lighting layer's own
        // intensity/opacity controls do the rest.
        let primaryTone = tone(hue: primary.hue,
                               saturation: primary.saturation,
                               brightness: clamp(primary.brightness, 0.25, 0.95))
        let secondaryTone: ArtPalette.Tone
        if let s = secondary {
            secondaryTone = tone(hue: s.hue,
                                 saturation: s.saturation,
                                 brightness: clamp(s.brightness, 0.25, 0.95))
        } else {
            // No distinct second hue — darker variant of primary.
            secondaryTone = tone(hue: primary.hue,
                                 saturation: primary.saturation,
                                 brightness: clamp(primary.brightness * 0.55, 0.12, 0.60))
        }
        let accentTone: ArtPalette.Tone
        if let a = accent {
            accentTone = tone(hue: a.hue,
                              saturation: a.saturation,
                              brightness: clamp(a.brightness * 1.15, 0.50, 1.0))
        } else {
            // No saturated highlight — brighter variant of primary.
            accentTone = tone(hue: primary.hue,
                              saturation: primary.saturation,
                              brightness: clamp(primary.brightness + 0.25, 0.50, 1.0))
        }

        return ArtPalette(primary: primaryTone,
                          secondary: secondaryTone,
                          accent: accentTone)
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

    private static func tone(hue: Double, saturation: Double, brightness: Double) -> ArtPalette.Tone {
        let h = hue.truncatingRemainder(dividingBy: 360) / 60.0
        let s = clamp(saturation, 0, 1)
        let v = clamp(brightness, 0, 1)
        let i = Int(h.rounded(.down)) % 6
        let f = h - h.rounded(.down)
        let p = v * (1 - s)
        let q = v * (1 - s * f)
        let t = v * (1 - s * (1 - f))
        let (r, g, b): (Double, Double, Double)
        switch i {
        case 0: (r, g, b) = (v, t, p)
        case 1: (r, g, b) = (q, v, p)
        case 2: (r, g, b) = (p, v, t)
        case 3: (r, g, b) = (p, q, v)
        case 4: (r, g, b) = (t, p, v)
        default: (r, g, b) = (v, p, q)
        }
        return ArtPalette.Tone(red: r, green: g, blue: b)
    }

    /// Circular hue distance in degrees, range [0, 180].
    private static func hueDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return d > 180 ? 360 - d : d
    }

    private static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        min(hi, max(lo, x))
    }
}
