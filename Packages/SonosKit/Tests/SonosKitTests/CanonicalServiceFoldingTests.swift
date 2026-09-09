import XCTest
@testable import SonosKit

/// When a descriptor's name does not match a known service, identity falls
/// back to the host's first DNS label. Vendors host their Sonos integration at
/// `sonos.<vendor>.com`, so that fallback folds unrelated services into Sonos
/// Radio, and every folded service inherits its search-only toggle.
final class CanonicalServiceFoldingTests: XCTestCase {

    private func descriptor(_ id: Int, _ name: String, host: String) -> ServiceDescriptor {
        ServiceDescriptor(id: id, name: name, secureUri: "https://\(host)/smapi/control")
    }

    private func canonicalKey(_ descriptor: ServiceDescriptor) -> String? {
        let catalog = MusicServiceCatalog.shared
        catalog.rebuildCanonicalTable([descriptor])
        return catalog.relatedSids(forSid: descriptor.id).isEmpty
            ? nil
            : catalog.canonicalDisplayName(forSid: descriptor.id)?.lowercased()
    }

    // MARK: - The fold that shipped

    /// Hosts under `sonos.<vendor>.com` must not fold into "Sonos Radio".
    func testVendorHostedServicesAreNotFoldedIntoSonosRadio() {
        let folded = [
            (321, "80s80s - REAL 80s Radio", "sonos.80s80s.de"),
            (861, "Astiga", "sonos.asti.ga"),
            (307, "Bookmate", "sonos.bookmate.com"),
            (256, "CBC Radio & Music", "sonos.cbc.ca"),
            (279, "Global Player", "sonos.globalplayer.com"),
        ]
        for (id, name, host) in folded {
            let key = canonicalKey(descriptor(id, name, host: host))
            XCTAssertNotEqual(key, "sonos radio", "\(name) must keep its own identity")
        }
    }

    /// `x-sonosapi-radio:` reduces to "radio" and matches any vendor whose host
    /// says what it serves rather than who it is.
    func testServicesAreNotFoldedByTheWordRadio() {
        let key = canonicalKey(descriptor(267, "RadioApp", host: "radioapp.example.com"))
        XCTAssertNotEqual(key, "pandora")
    }

    /// `x-sonosapi-stream:` reduces to "stream", which folds an in-store music
    /// service into TuneIn.
    func testServicesAreNotFoldedByTheWordStream() {
        let key = canonicalKey(descriptor(1157, "HearDis! Instore Radio", host: "stream.heardis.com"))
        XCTAssertNotEqual(key, "tunein")
    }

    // MARK: - Matching that must still work

    /// A distinctive host token is the signal the fallback exists for: a renamed
    /// or localised descriptor must still map to its service.
    func testDistinctiveHostTokenStillIdentifiesTheService() {
        let key = canonicalKey(descriptor(9, "Spotify (DE)", host: "spotify-v5.ws.sonos.com"))
        XCTAssertEqual(key, "spotify")
    }

    func testExactNameMatchIsUnaffected() {
        let key = canonicalKey(descriptor(303, "Sonos Radio", host: "sonos.ws.sonos.com"))
        XCTAssertEqual(key, "sonos radio")
    }

    /// A household reporting Spotify at a non-standard sid must still resolve
    /// to Spotify.
    func testAlternateHouseholdSidStillGroupsWithItsService() {
        let catalog = MusicServiceCatalog.shared
        catalog.rebuildCanonicalTable([descriptor(9, "Spotify", host: "spotify-v5.ws.sonos.com")])
        XCTAssertTrue(catalog.relatedSids(forSid: 9).contains(9))
    }
}
