/// NSImage+Brightness.swift — Average perceived luminance for an
/// NSImage, used by Vis surfaces to adapt overlays to the artwork.
///
/// Implementation notes: draws into a 1×1 Core Graphics context and
/// reads back the resulting RGB pixel, then weights with Rec. 601
/// luma coefficients. Cheap (microseconds) and works for any
/// NSImage that can produce a CGImage.
import AppKit
import CoreGraphics

public extension NSImage {
    /// Returns the image's average perceived brightness in [0, 1].
    /// 0 = pure black, 1 = pure white. Returns 0.5 when the image
    /// can't be downscaled (no CGImage representation).
    func averagePerceivedLuminance() -> Double {
        guard let cgImage = self.cgImage(forProposedRect: nil,
                                         context: nil,
                                         hints: nil) else {
            return 0.5
        }
        var pixel: [UInt8] = [0, 0, 0, 0]
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(data: &pixel,
                                      width: 1,
                                      height: 1,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 4,
                                      space: colorSpace,
                                      bitmapInfo: bitmapInfo) else {
            return 0.5
        }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let r = Double(pixel[0]) / 255
        let g = Double(pixel[1]) / 255
        let b = Double(pixel[2]) / 255
        return 0.299 * r + 0.587 * g + 0.114 * b
    }
}
