/// MusicServiceCatalogTests.swift — Coverage for the per-household sid
/// resolver that fixes issue #19. The catalog is the seam between the
/// hardcoded protocol facts (Spotify wants `x-sonos-spotify:`) and the
/// runtime sid the speaker actually reports for that service in this
/// household. Tests pin the contract that drove the refactor: the bug
/// surfaced when the speaker reported sid=9 for Spotify but the
/// compile-time table assumed sid=12, silently downgrading to
/// `x-sonos-http:` and triggering UPnP 714 on every single-track click.
import XCTest
@testable import SonosKit

@MainActor
final class MusicServiceCatalogTests: XCTestCase {

    // MARK: - Stub fetcher

    /// Test seam — feeds a canned descriptor list to the catalog
    /// without hitting a real speaker. `nextResponse` is mutated
    /// between refreshes to drive drift-detection cases.
    final class StubFetcher: ListAvailableServicesFetching, @unchecked Sendable {
        var nextResponse: [ServiceDescriptor]
        var fetchCount = 0
        var lastSpeakerIP: String?
        var error: Error?

        init(initial: [ServiceDescriptor]) {
            self.nextResponse = initial
        }

        func fetch(speakerIP: String) async throws -> [ServiceDescriptor] {
            fetchCount += 1
            lastSpeakerIP = speakerIP
            if let error { throw error }
            return nextResponse
        }
    }

    private func makeDescriptor(id: Int, name: String,
                                authType: String = "AppLink") -> ServiceDescriptor {
        ServiceDescriptor(id: id, name: name, secureUri: "https://\(name.lowercased())/smapi",
                          authType: authType)
    }

    // MARK: - Static rules table

    func testStaticRulesIncludeSpotifyWithCustomScheme() {
        let table = MusicServiceCatalog.buildStaticRulesTable()
        let spotify = table["spotify"]
        XCTAssertNotNil(spotify)
        XCTAssertEqual(spotify?.trackURIScheme, "x-sonos-spotify:")
        XCTAssertEqual(spotify?.trackURIExtension, "")
        XCTAssertEqual(spotify?.trackPlaybackFlags, 8224)
    }

    func testStaticRulesIncludeAppleMusicWithHLSStaticSchemeAndFlag8232() {
        // hls-static, no extension — byte-identical to the official Sonos
        // app's enqueue form (verified against a live queue 2026-06-11).
        // The legacy `x-sonos-http:…mp4` form made the speaker validate
        // every track against Apple at enqueue time (~0.85 s/track).
        let table = MusicServiceCatalog.buildStaticRulesTable()
        let am = table["apple music"]
        XCTAssertNotNil(am)
        XCTAssertEqual(am?.trackURIScheme, URIPrefix.sonosApiHLSStatic)
        XCTAssertEqual(am?.trackURIExtension, "")
        XCTAssertEqual(am?.trackPlaybackFlags, 8232)
    }

    func testStaticRulesAreCaseInsensitiveByName() {
        let table = MusicServiceCatalog.buildStaticRulesTable()
        XCTAssertNotNil(table["spotify"])
        XCTAssertNil(table["Spotify"], "Table is canonicalised lowercase; pass through `rules(forName:)` for case-insensitive access")
    }

    func testRulesForNameIsCaseInsensitive() {
        let catalog = MusicServiceCatalog(fetcher: StubFetcher(initial: []))
        XCTAssertNotNil(catalog.rules(forName: "Spotify"))
        XCTAssertNotNil(catalog.rules(forName: "SPOTIFY"))
        XCTAssertNotNil(catalog.rules(forName: "spotify"))
    }

    // MARK: - Refresh + sid mapping

    func testRefreshPopulatesDescriptorsAndEnablesSidLookup() async {
        let fetcher = StubFetcher(initial: [
            makeDescriptor(id: 9, name: "Spotify"),
            makeDescriptor(id: 254, name: "TuneIn", authType: "Anonymous"),
        ])
        let catalog = MusicServiceCatalog(fetcher: fetcher)
        await catalog.refresh(speakerIP: "10.0.0.1")
        XCTAssertEqual(fetcher.fetchCount, 1)
        XCTAssertEqual(catalog.descriptor(forSid: 9)?.name, "Spotify")
        XCTAssertEqual(catalog.descriptor(forName: "Spotify")?.id, 9)
        XCTAssertEqual(catalog.sid(forName: "Spotify"), 9)
    }

    /// The crux of issue #19 — when the household's runtime sid for
    /// Spotify is 9 instead of the compile-time constant 12, the
    /// catalog still resolves to the Spotify-specific URI scheme.
    func testSpotifyOnUnusualSidStillRoutesToSonosSpotifyScheme() async {
        let catalog = MusicServiceCatalog(fetcher: StubFetcher(initial: [
            makeDescriptor(id: 9, name: "Spotify"),
        ]))
        await catalog.refresh(speakerIP: "10.0.0.1")
        XCTAssertEqual(catalog.trackURIScheme(forSid: 9), "x-sonos-spotify:",
                       "Spotify on sid=9 must resolve to its custom URI scheme via the per-household name lookup; falling back to x-sonos-http: was the bug.")
    }

    func testAppleMusicAtRuntimeSidPicksUpExtensionAndFlags() async {
        let catalog = MusicServiceCatalog(fetcher: StubFetcher(initial: [
            makeDescriptor(id: 204, name: "Apple Music"),
        ]))
        await catalog.refresh(speakerIP: "10.0.0.1")
        XCTAssertEqual(catalog.trackURIScheme(forSid: 204), URIPrefix.sonosApiHLSStatic)
        XCTAssertEqual(catalog.trackURIExtension(forSid: 204), "")
        XCTAssertEqual(catalog.trackPlaybackFlags(forSid: 204), 8232)
    }

    func testUnknownSidFallsBackToXSonosHTTPWithoutCrashing() {
        let catalog = MusicServiceCatalog(fetcher: StubFetcher(initial: []))
        XCTAssertEqual(catalog.trackURIScheme(forSid: 9999), URIPrefix.sonosHTTP,
                       "When the catalog has no rules for a sid, we fall back to the generic HTTP scheme rather than producing nil and breaking URI construction.")
        XCTAssertEqual(catalog.trackURIExtension(forSid: 9999), "")
        XCTAssertEqual(catalog.trackPlaybackFlags(forSid: 9999), 8224)
    }

    func testRinconServiceTypeFallsBackToFormulaWhenDescriptorMissing() {
        let catalog = MusicServiceCatalog(fetcher: StubFetcher(initial: []))
        // (sid << 8) + 7 is the Sonos formula and is invariant for the
        // service across households — fine to use even when the
        // descriptor list hasn't loaded.
        XCTAssertEqual(catalog.rinconServiceType(forSid: 9), 2311,
                       "Spotify RINCON type for sid=9 is (9 << 8) + 7 = 2311.")
        XCTAssertEqual(catalog.rinconServiceType(forSid: 12), 3079,
                       "Spotify on sid=12 derives RINCON 3079; this is what the old hardcoded code was implicitly assuming.")
    }

    func testRinconServiceTypeUsesDescriptorWhenAvailable() async {
        let catalog = MusicServiceCatalog(fetcher: StubFetcher(initial: [
            makeDescriptor(id: 9, name: "Spotify"),
        ]))
        await catalog.refresh(speakerIP: "10.0.0.1")
        XCTAssertEqual(catalog.rinconServiceType(forSid: 9), 2311)
    }

    // MARK: - Refresh coalescing + drift

    func testConcurrentRefreshesCoalesceToSingleFetch() async {
        let fetcher = StubFetcher(initial: [makeDescriptor(id: 9, name: "Spotify")])
        let catalog = MusicServiceCatalog(fetcher: fetcher)

        async let r1: Void = catalog.refresh(speakerIP: "10.0.0.1")
        async let r2: Void = catalog.refresh(speakerIP: "10.0.0.1")
        async let r3: Void = catalog.refresh(speakerIP: "10.0.0.1")
        _ = await (r1, r2, r3)

        // The second and third callers should observe the in-flight
        // task rather than firing a second SOAP call. Without
        // coalescing, the catalog hammers the speaker on first launch
        // when multiple async setup paths each kick off a refresh.
        XCTAssertEqual(fetcher.fetchCount, 1,
                       "Concurrent refreshes must coalesce to a single fetch.")
    }

    func testEnsureFreshSkipsRefreshWhenWithinTTL() async {
        let fetcher = StubFetcher(initial: [makeDescriptor(id: 9, name: "Spotify")])
        let catalog = MusicServiceCatalog(fetcher: fetcher)
        catalog.bind(speakerIP: "10.0.0.1")
        await catalog.refresh(speakerIP: "10.0.0.1")
        XCTAssertEqual(fetcher.fetchCount, 1)

        await catalog.ensureFresh(ttl: 3600)
        XCTAssertEqual(fetcher.fetchCount, 1, "Within TTL, ensureFresh is a no-op.")

        await catalog.ensureFresh(ttl: -1)
        XCTAssertEqual(fetcher.fetchCount, 2, "When the TTL has elapsed, ensureFresh refetches.")
    }

    func testEnsureSidKnownSkipsWhenSidPresent() async {
        let fetcher = StubFetcher(initial: [makeDescriptor(id: 9, name: "Spotify")])
        let catalog = MusicServiceCatalog(fetcher: fetcher)
        catalog.bind(speakerIP: "10.0.0.1")
        await catalog.refresh(speakerIP: "10.0.0.1")
        XCTAssertEqual(fetcher.fetchCount, 1)

        await catalog.ensureSidKnown(9)
        XCTAssertEqual(fetcher.fetchCount, 1, "Known sid → no refetch.")
    }

    func testEnsureSidKnownTriggersRefreshOnMiss() async {
        let fetcher = StubFetcher(initial: [makeDescriptor(id: 9, name: "Spotify")])
        let catalog = MusicServiceCatalog(fetcher: fetcher)
        catalog.bind(speakerIP: "10.0.0.1")
        await catalog.refresh(speakerIP: "10.0.0.1")

        // Speaker just minted a URI with a sid we haven't seen — say
        // the user added a new service mid-session. Fetcher updates to
        // include it on the next call.
        fetcher.nextResponse = [
            makeDescriptor(id: 9, name: "Spotify"),
            makeDescriptor(id: 174, name: "TIDAL"),
        ]
        await catalog.ensureSidKnown(174)
        XCTAssertEqual(fetcher.fetchCount, 2, "Unknown sid must trigger a refresh.")
        XCTAssertEqual(catalog.descriptor(forSid: 174)?.name, "TIDAL")
    }

    func testApplyRefreshDoesNotPanicOnDrift() async {
        // Drift case: same household refreshes and Spotify's sid
        // changed (user removed-and-re-added the account in the Sonos
        // app — the documented cause of this happening). The catalog
        // must accept the new sid as authoritative without crashing,
        // and downstream `trackURIScheme(forSid:)` must follow.
        let fetcher = StubFetcher(initial: [makeDescriptor(id: 9, name: "Spotify")])
        let catalog = MusicServiceCatalog(fetcher: fetcher)
        await catalog.refresh(speakerIP: "10.0.0.1")
        XCTAssertEqual(catalog.trackURIScheme(forSid: 9), "x-sonos-spotify:")

        fetcher.nextResponse = [makeDescriptor(id: 12, name: "Spotify")]
        await catalog.refresh(speakerIP: "10.0.0.1")
        XCTAssertEqual(catalog.descriptor(forSid: 9), nil,
                       "After drift, the old sid is no longer a known service descriptor.")
        XCTAssertEqual(catalog.trackURIScheme(forSid: 12), "x-sonos-spotify:",
                       "After drift, the new sid resolves to Spotify's scheme.")
    }

    // MARK: - Parser

    func testParserExtractsAllServiceAttributes() {
        let xml = """
        <Services>
        <Service Id="9" Name="Spotify" Uri="https://x" SecureUri="https://x/secure" \
        ContainerType="MService" Capabilities="2563" Auth="AppLink"/>
        <Service Id="254" Name="TuneIn" Uri="https://t" SecureUri="https://t/secure" \
        ContainerType="MService" Capabilities="2049" Auth="Anonymous"/>
        </Services>
        """
        let parsed = MusicServiceCatalogParser.parse(xml)
        XCTAssertEqual(parsed.count, 2)
        let spotify = parsed.first { $0.name == "Spotify" }
        XCTAssertEqual(spotify?.id, 9)
        XCTAssertEqual(spotify?.secureUri, "https://x/secure")
        XCTAssertEqual(spotify?.authType, "AppLink")
        XCTAssertEqual(spotify?.capabilities, 2563)
    }

    func testParserSortsByName() {
        let xml = """
        <Services>
        <Service Id="254" Name="TuneIn" SecureUri="" Auth="Anonymous"/>
        <Service Id="9" Name="Spotify" SecureUri="" Auth="AppLink"/>
        <Service Id="204" Name="Apple Music" SecureUri="" Auth="AppLink"/>
        </Services>
        """
        let parsed = MusicServiceCatalogParser.parse(xml)
        XCTAssertEqual(parsed.map(\.name), ["Apple Music", "Spotify", "TuneIn"])
    }
}
