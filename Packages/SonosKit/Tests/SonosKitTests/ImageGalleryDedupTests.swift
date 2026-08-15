import XCTest
import AppKit
@testable import SonosKit

/// Covers the About-gallery image dedup: same photo at different
/// resolutions collapses to one entry, keeping the highest-resolution
/// URL at the first-seen position.
final class ImageGalleryDedupTests: XCTestCase {

    // MARK: - Identity keys

    func testWikipediaThumbSizesShareOneKey() {
        let a = "https://upload.wikimedia.org/wikipedia/commons/thumb/1/1a/Band.jpg/320px-Band.jpg"
        let b = "https://upload.wikimedia.org/wikipedia/commons/thumb/1/1a/Band.jpg/640px-Band.jpg"
        XCTAssertEqual(MusicMetadataService.imageIdentityKey(a),
                       MusicMetadataService.imageIdentityKey(b))
    }

    func testLastfmSizeDirectoriesShareOneKey() {
        let a = "https://lastfm.freetls.fastly.net/i/u/174s/abc123def.png"
        let b = "https://lastfm.freetls.fastly.net/i/u/300x300/abc123def.png"
        XCTAssertEqual(MusicMetadataService.imageIdentityKey(a),
                       MusicMetadataService.imageIdentityKey(b))
    }

    func testQueryStringDoesNotSplitIdentity() {
        // Wikipedia's summary endpoint appends utm query params to
        // some thumb URLs; the underlying file is the same. Observed
        // live: both variants rendered as gallery tiles.
        let plain = "https://upload.wikimedia.org/wikipedia/commons/thumb/e/e7/Bob_Seger_2013_%28cropped%29.jpg/330px-Bob_Seger_2013_%28cropped%29.jpg"
        let tagged = "https://upload.wikimedia.org/wikipedia/commons/thumb/e/e7/Bob_Seger_2013_%28cropped%29.jpg/500px-Bob_Seger_2013_%28cropped%29.jpg?utm_source=en.wikipedia.org&utm_campaign=parser&utm_content=thumbnail"
        XCTAssertEqual(MusicMetadataService.imageIdentityKey(plain),
                       MusicMetadataService.imageIdentityKey(tagged))
        let lfmPlain = "https://lastfm.freetls.fastly.net/i/u/300x300/abc123def.png"
        let lfmTagged = "https://lastfm.freetls.fastly.net/i/u/300x300/abc123def.png?disallowbrowser=true"
        XCTAssertEqual(MusicMetadataService.imageIdentityKey(lfmPlain),
                       MusicMetadataService.imageIdentityKey(lfmTagged))
        // The tagged 500px variant outranks the plain 330px one.
        XCTAssertEqual(MusicMetadataService.dedupePreferHighRes([plain, tagged]),
                       [tagged])
    }

    func testDistinctPhotosKeepDistinctKeys() {
        let a = "https://upload.wikimedia.org/wikipedia/commons/thumb/1/1a/Band.jpg/320px-Band.jpg"
        let b = "https://upload.wikimedia.org/wikipedia/commons/thumb/2/2b/Live.jpg/320px-Live.jpg"
        XCTAssertNotEqual(MusicMetadataService.imageIdentityKey(a),
                          MusicMetadataService.imageIdentityKey(b))
    }

    // MARK: - Resolution hints

    func testResolutionHintOrdering() {
        let thumb320 = "https://upload.wikimedia.org/wikipedia/commons/thumb/1/1a/Band.jpg/320px-Band.jpg"
        let thumb640 = "https://upload.wikimedia.org/wikipedia/commons/thumb/1/1a/Band.jpg/640px-Band.jpg"
        let original = "https://upload.wikimedia.org/wikipedia/commons/1/1a/Band.jpg"
        XCTAssertLessThan(MusicMetadataService.imageResolutionHint(thumb320),
                          MusicMetadataService.imageResolutionHint(thumb640))
        XCTAssertLessThan(MusicMetadataService.imageResolutionHint(thumb640),
                          MusicMetadataService.imageResolutionHint(original))
        XCTAssertLessThan(MusicMetadataService.imageResolutionHint(
                              "https://lastfm.freetls.fastly.net/i/u/174s/abc.png"),
                          MusicMetadataService.imageResolutionHint(
                              "https://lastfm.freetls.fastly.net/i/u/300x300/abc.png"))
        XCTAssertEqual(MusicMetadataService.imageResolutionHint(
                           "https://example.com/photos/plain.jpg"), 0)
        XCTAssertGreaterThan(MusicMetadataService.imageResolutionHint(
                                 "https://is1-ssl.mzstatic.com/image/thumb/x/600x600bb.jpg"), 0)
    }

    // MARK: - Dedup

    func testDedupKeepsHighestResolutionAtFirstSeenPosition() {
        let low = "https://upload.wikimedia.org/wikipedia/commons/thumb/1/1a/Band.jpg/320px-Band.jpg"
        let high = "https://upload.wikimedia.org/wikipedia/commons/thumb/1/1a/Band.jpg/640px-Band.jpg"
        let other = "https://upload.wikimedia.org/wikipedia/commons/thumb/2/2b/Live.jpg/320px-Live.jpg"
        let out = MusicMetadataService.dedupePreferHighRes([low, other, high])
        XCTAssertEqual(out, [high, other])
    }

    func testCroppedVariantSharesKeyWithOriginal() {
        // Commons crop variants are the same picture: "X.jpg" and
        // "X_(cropped).jpg" must collapse to one gallery entry.
        let original = "https://upload.wikimedia.org/wikipedia/commons/1/1a/Eric_Clapton_2010.jpg"
        let cropped = "https://upload.wikimedia.org/wikipedia/commons/thumb/2/2b/Eric_Clapton_2010_%28cropped%29.jpg/320px-Eric_Clapton_2010_%28cropped%29.jpg"
        XCTAssertEqual(MusicMetadataService.imageIdentityKey(original),
                       MusicMetadataService.imageIdentityKey(cropped))
        // Parenthesised years stay distinct — different photos.
        let y74 = "https://upload.wikimedia.org/wikipedia/commons/1/1a/Clapton_%281974%29.jpg"
        let y77 = "https://upload.wikimedia.org/wikipedia/commons/1/1a/Clapton_%281977%29.jpg"
        XCTAssertNotEqual(MusicMetadataService.imageIdentityKey(y74),
                          MusicMetadataService.imageIdentityKey(y77))
    }

    func testNonPhotoCandidatesAreDropped() {
        XCTAssertFalse(MusicMetadataService.isGalleryPhotoCandidate(
            "https://upload.wikimedia.org/wikipedia/commons/9/9c/Eric_Clapton_signature.png"))
        // Wikipedia PNGs are non-photo media (signatures, logos,
        // diagrams) even without a keyword in the filename.
        XCTAssertFalse(MusicMetadataService.isGalleryPhotoCandidate(
            "https://upload.wikimedia.org/wikipedia/commons/9/9c/Some_diagram.png"))
        XCTAssertTrue(MusicMetadataService.isGalleryPhotoCandidate(
            "https://upload.wikimedia.org/wikipedia/commons/1/1a/Band.jpg"))
        // Last.fm PNG hashes are photos — the PNG rule is
        // Wikipedia-only.
        XCTAssertTrue(MusicMetadataService.isGalleryPhotoCandidate(
            "https://lastfm.freetls.fastly.net/i/u/300x300/abc123.png"))
        // Dedup drops non-photos even from cached galleries.
        let out = MusicMetadataService.dedupePreferHighRes([
            "https://upload.wikimedia.org/wikipedia/commons/9/9c/Eric_Clapton_signature.png",
            "https://upload.wikimedia.org/wikipedia/commons/1/1a/Band.jpg",
        ])
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(out[0].hasSuffix("Band.jpg"))
    }

    func testDedupLimitCapsDistinctPhotosNotCandidates() {
        let a1 = "https://lastfm.freetls.fastly.net/i/u/174s/aaa.png"
        let a2 = "https://lastfm.freetls.fastly.net/i/u/300x300/aaa.png"
        let b = "https://lastfm.freetls.fastly.net/i/u/300x300/bbb.png"
        // Limit 2: two DISTINCT photos survive even though the first
        // photo appears twice among the candidates.
        let out = MusicMetadataService.dedupePreferHighRes([a1, a2, b], limit: 2)
        XCTAssertEqual(out, [a2, b])
    }

    // MARK: - Perceptual near-duplicate hashing

    private func gradientImage(width: Int, height: Int,
                               seed: Double) -> NSImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: colorSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for x in 0..<width {
            let v = (sin(Double(x) / Double(width) * .pi * 2 + seed) + 1) / 2
            ctx.setFillColor(CGColor(red: v, green: v * 0.5, blue: 1 - v, alpha: 1))
            ctx.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        let cg = ctx.makeImage()!
        return NSImage(cgImage: cg, size: NSSize(width: width, height: height))
    }

    func testDHashStableAcrossResolutions() {
        // Same picture at 200px and 800px — near-duplicate distance.
        let small = gradientImage(width: 200, height: 150, seed: 0.3)
        let large = gradientImage(width: 800, height: 600, seed: 0.3)
        let hs = ImageSimilarity.dHash(small)
        let hl = ImageSimilarity.dHash(large)
        XCTAssertNotNil(hs)
        XCTAssertNotNil(hl)
        XCTAssertTrue(ImageSimilarity.isNearDuplicate(hs!, hl!))
    }

    func testDHashSeparatesDistinctImages() {
        let a = gradientImage(width: 400, height: 300, seed: 0.3)
        let b = gradientImage(width: 400, height: 300, seed: 2.6)
        let ha = ImageSimilarity.dHash(a)!
        let hb = ImageSimilarity.dHash(b)!
        XCTAssertFalse(ImageSimilarity.isNearDuplicate(ha, hb))
    }

    func testHammingDistance() {
        XCTAssertEqual(ImageSimilarity.hammingDistance(0, 0), 0)
        XCTAssertEqual(ImageSimilarity.hammingDistance(0b1011, 0b0010), 2)
        XCTAssertEqual(ImageSimilarity.hammingDistance(.max, 0), 64)
    }

    // MARK: - Persisted hash cache

    /// Service wired to an in-memory SQLite cache. Only the cache-hit
    /// paths run in these tests, so no keychain or network is touched.
    /// MainActor because `LastFMTokenStore.init`'s default `SecretsStore`
    /// is MainActor-isolated.
    @MainActor
    private func makeService(cache: MetadataCacheRepository) -> MusicMetadataService {
        MusicMetadataService(tokenStore: LastFMTokenStore(), cache: cache)
    }

    private func seed(_ cache: MetadataCacheRepository,
                      url: URL, hash: UInt64, pixels: Int) throws {
        let record = MusicMetadataService.ImageHashRecord(hash: hash, pixels: pixels)
        let payload = try XCTUnwrap(String(data: JSONEncoder().encode(record),
                                           encoding: .utf8))
        cache.set(MusicMetadataService.imageHashKey(url), payload: payload)
    }

    func testImageHashReturnsPersistedRecordWithoutImageWork() async throws {
        let cache = MetadataCacheRepository(dbPath: ":memory:")
        let service = await makeService(cache: cache)
        // Unresolvable host: a cache miss would fall through to the
        // network and fail, so a non-nil result proves the persisted
        // record short-circuits the download + hash.
        let url = try XCTUnwrap(URL(string: "https://invalid.invalid/photo.jpg"))
        try seed(cache, url: url, hash: 0xDEAD_BEEF, pixels: 240_000)
        let record = await service.imageHash(for: url)
        XCTAssertEqual(record,
                       MusicMetadataService.ImageHashRecord(hash: 0xDEAD_BEEF,
                                                            pixels: 240_000))
    }

    func testImageHashKeyIsCaseSensitive() throws {
        let a = try XCTUnwrap(URL(string: "https://upload.wikimedia.org/a/Bob_seger.jpg"))
        let b = try XCTUnwrap(URL(string: "https://upload.wikimedia.org/a/Bob_Seger.jpg"))
        XCTAssertNotEqual(MusicMetadataService.imageHashKey(a),
                          MusicMetadataService.imageHashKey(b))
    }

    func testRefineGalleryCollapsesNearDuplicatesFromCachedHashes() async throws {
        let cache = MetadataCacheRepository(dbPath: ":memory:")
        let service = await makeService(cache: cache)
        let small = try XCTUnwrap(URL(string: "https://invalid.invalid/photo-330.jpg"))
        let large = try XCTUnwrap(URL(string: "https://invalid.invalid/photo-500.jpg"))
        let other = try XCTUnwrap(URL(string: "https://invalid.invalid/different.jpg"))
        // small/large: identical hash, different pixel counts — one
        // photo at two sizes. other: far hash — distinct photo.
        try seed(cache, url: small, hash: 0x0F0F_0F0F, pixels: 100)
        try seed(cache, url: large, hash: 0x0F0F_0F0F, pixels: 400)
        try seed(cache, url: other, hash: 0xF0F0_F0F0_F0F0_F0F0, pixels: 100)
        let refined = await service.refineGallery([small, other, large])
        // Higher-pixel variant wins, at the first-seen position.
        XCTAssertEqual(refined, [large, other])
    }
}
