import XCTest
@testable import SonosKit

/// Dynamic, multi-id service resolution — the catalog must map a household's
/// runtime sid back to the right canonical service (name + tested status),
/// seeded from the well-known online id set and augmented by ListAvailableServices.
/// Motivated by #57: Spotify is sid 9 in most households, 12 in others.
final class CanonicalServiceResolutionTests: XCTestCase {

    // Fresh catalog = seed only (no live fetch).
    private func seededCatalog() -> MusicServiceCatalog {
        MusicServiceCatalog(fetcher: StubFetcher())
    }

    // MARK: seed — both Spotify ids resolve to "Spotify"

    func testSpotifyBothSeededIdsResolve() {
        let c = seededCatalog()
        XCTAssertEqual(c.canonicalDisplayName(forSid: 9), "Spotify")   // online/canonical
        XCTAssertEqual(c.canonicalDisplayName(forSid: 12), "Spotify")  // this codebase's household
    }

    func testRelatedSidsGroupBothSpotifyIds() {
        let c = seededCatalog()
        XCTAssertTrue(c.relatedSids(forSid: 9).isSuperset(of: [9, 12]))
        XCTAssertTrue(c.relatedSids(forSid: 12).isSuperset(of: [9, 12]))
    }

    func testOtherSeededServices() {
        let c = seededCatalog()
        XCTAssertEqual(c.canonicalDisplayName(forSid: 204), "Apple Music")
        XCTAssertEqual(c.canonicalDisplayName(forSid: 174), "TIDAL")
        XCTAssertEqual(c.canonicalDisplayName(forSid: 254), "TuneIn")
        XCTAssertEqual(c.canonicalDisplayName(forSid: 333), "TuneIn")  // TuneIn alt id
    }

    func testUnknownSidIsNil() {
        let c = seededCatalog()
        XCTAssertNil(c.canonicalDisplayName(forSid: 99999))
        XCTAssertEqual(c.relatedSids(forSid: 99999), [])
    }

    // MARK: descriptor augmentation — a household reporting a fresh id joins the group

    func testDescriptorIdJoinsCanonicalGroupByName() {
        let c = seededCatalog()
        c.rebuildCanonicalTable([ServiceDescriptor(id: 77, name: "Spotify")])
        XCTAssertEqual(c.canonicalDisplayName(forSid: 77), "Spotify")
        XCTAssertTrue(c.relatedSids(forSid: 9).contains(77))
    }

    func testDescriptorMatchesByUriSchemeWhenNameDiffers() {
        let c = seededCatalog()
        // A renamed/localised descriptor whose name doesn't match, but whose
        // SMAPI host carries the Spotify token → still maps home.
        let d = ServiceDescriptor(id: 88, name: "Musik-Streaming",
                                  uri: "https://spotify-v5.ws.sonos.com/smapi",
                                  secureUri: "https://spotify-v5.ws.sonos.com/smapi")
        c.rebuildCanonicalTable([d])
        XCTAssertEqual(c.canonicalDisplayName(forSid: 88), "Spotify")
    }

    func testDescriptorReassignsSeededIdAwayFromSeed() {
        let c = seededCatalog()
        // Sids are per-household: a household whose sid 9 belongs to an
        // unrecognised service must not keep the seed's Spotify mapping for
        // that id. The unreported seeded alias (12) still resolves.
        let d = ServiceDescriptor(id: 9, name: "Acme Audio",
                                  uri: "https://acme-audio.example.com/smapi",
                                  secureUri: "https://acme-audio.example.com/smapi")
        c.rebuildCanonicalTable([d])
        XCTAssertNil(c.canonicalDisplayName(forSid: 9))
        XCTAssertFalse(c.relatedSids(forSid: 12).contains(9))
        XCTAssertEqual(c.canonicalDisplayName(forSid: 12), "Spotify")
    }
}

/// No-op fetcher so the catalog never makes a live SOAP call in tests.
private struct StubFetcher: ListAvailableServicesFetching {
    func fetch(speakerIP: String) async throws -> [ServiceDescriptor] { [] }
}
