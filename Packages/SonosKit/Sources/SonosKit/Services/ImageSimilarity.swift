/// ImageSimilarity.swift — Perceptual near-duplicate detection for
/// the About photo gallery.
///
/// URL-level dedup (`MusicMetadataService.imageIdentityKey`) collapses
/// size/crop VARIANTS of one file, but Last.fm and Wikipedia host the
/// same photograph as unrelated files — different hashes, different
/// filenames — which only the pixels reveal. A 64-bit difference hash
/// (dHash) over a 9×8 grayscale downsample is robust to resolution
/// changes, recompression, and mild crops; near-duplicates sit within
/// a small Hamming distance while distinct photos land far apart.
import AppKit
import CoreGraphics

public enum ImageSimilarity {
    /// Near-duplicate threshold for `dHash` Hamming distance —
    /// resolution/compression variants of one photo measure well
    /// under this; distinct photos of the same subject measure well
    /// over it.
    public static let nearDuplicateMaxDistance = 10

    /// 64-bit difference hash: 9×8 grayscale downsample, one bit per
    /// horizontal neighbour comparison. Nil when the image can't
    /// produce a CGImage.
    public static func dHash(_ image: NSImage) -> UInt64? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let w = 9, h = 8
        var buf = [UInt8](repeating: 0, count: w * h)
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress,
                                      width: w, height: h,
                                      bitsPerComponent: 8,
                                      bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
                return false
            }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        var hash: UInt64 = 0
        var bit: UInt64 = 0
        for row in 0..<h {
            for col in 0..<(w - 1) {
                if buf[row * w + col] > buf[row * w + col + 1] {
                    hash |= 1 << bit
                }
                bit += 1
            }
        }
        return hash
    }

    public static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    /// True when two hashes are within the near-duplicate threshold.
    public static func isNearDuplicate(_ a: UInt64, _ b: UInt64) -> Bool {
        hammingDistance(a, b) <= nearDuplicateMaxDistance
    }
}
