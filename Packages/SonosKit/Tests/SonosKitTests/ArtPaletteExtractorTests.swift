import XCTest
import AppKit
@testable import SonosKit

/// Covers the dominant-colour sampler behind Back of the Club
/// lighting v2. Synthetic CGContext images keep the inputs exact
/// and the assertions deterministic.
final class ArtPaletteExtractorTests: XCTestCase {

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

    func testSolidColourYieldsMatchingPrimary() {
        let img = makeImage { ctx in
            ctx.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 48, height: 48))
        }
        let palette = ArtPaletteExtractor.extract(from: img)
        XCTAssertNotNil(palette)
        guard let p = palette else { return }
        XCTAssertGreaterThan(p.primary.red, p.primary.green)
        XCTAssertGreaterThan(p.primary.red, p.primary.blue)
        // Single hue → secondary falls back to a darker variant of
        // the primary hue (still red-dominant, lower brightness).
        XCTAssertGreaterThan(p.secondary.red, p.secondary.green)
        XCTAssertLessThan(p.secondary.red, p.primary.red)
    }

    func testTwoToneYieldsDistinctPrimaryAndSecondary() {
        // 70% blue field / 30% orange band — hues ~140° apart, both
        // saturated, so primary must be blue-dominant and secondary
        // must land on the distinct orange cluster.
        let img = makeImage { ctx in
            ctx.setFillColor(CGColor(red: 0.10, green: 0.20, blue: 0.90, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 48, height: 34))
            ctx.setFillColor(CGColor(red: 0.95, green: 0.55, blue: 0.10, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 34, width: 48, height: 14))
        }
        let palette = ArtPaletteExtractor.extract(from: img)
        XCTAssertNotNil(palette)
        guard let p = palette else { return }
        XCTAssertGreaterThan(p.primary.blue, p.primary.red)
        XCTAssertGreaterThan(p.secondary.red, p.secondary.blue)
    }

    func testGrayscaleReturnsNil() {
        let img = makeImage { ctx in
            for x in 0..<48 {
                let v = CGFloat(x) / 47.0
                ctx.setFillColor(CGColor(red: v, green: v, blue: v, alpha: 1))
                ctx.fill(CGRect(x: x, y: 0, width: 1, height: 48))
            }
        }
        XCTAssertNil(ArtPaletteExtractor.extract(from: img))
    }

    func testExtractionIsDeterministic() {
        let img = makeImage { ctx in
            ctx.setFillColor(CGColor(red: 0.2, green: 0.7, blue: 0.3, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 48, height: 24))
            ctx.setFillColor(CGColor(red: 0.6, green: 0.2, blue: 0.7, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 24, width: 48, height: 24))
        }
        let a = ArtPaletteExtractor.extract(from: img)
        let b = ArtPaletteExtractor.extract(from: img)
        XCTAssertNotNil(a)
        XCTAssertEqual(a, b)
    }
}
