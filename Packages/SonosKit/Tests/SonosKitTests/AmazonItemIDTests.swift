/// AmazonItemIDTests.swift — Amazon Music's object-id → play-URI-id rewrite.
///
/// Amazon's SMAPI ids (`catalog:track:asin:<ASIN>`) are not the ids its
/// play URIs use (`catalog/tracks/<ASIN>/`). Feeding the object id in
/// verbatim faults UPnP 714; the encoded forms asserted here are the ones
/// a live household accepted via SetAVTransportURI.
import XCTest
@testable import SonosKit

final class AmazonItemIDTests: XCTestCase {

    // MARK: - Rewrite

    func testTrackIDBecomesCataloguePath() {
        XCTAssertEqual(
            ServiceSearchProvider.rewriteItemID("catalog:track:asin:B01DPX12SW",
                                                style: .amazonCatalogPath),
            "catalog/tracks/B01DPX12SW/")
    }

    func testAlbumIDBecomesCataloguePathWithDescriptor() {
        XCTAssertEqual(
            ServiceSearchProvider.rewriteItemID("catalog:album:asin:B01DPX15VQ",
                                                style: .amazonCatalogPath),
            "catalog/albums/B01DPX15VQ/#album_desc")
    }

    /// Artists, playlists and podcasts have no catalogue-path form here —
    /// they browse rather than play as a container, so the id is untouched.
    func testUnmappedKindsPassThrough() {
        for id in ["catalog:artist:asin:B001Q575AG",
                   "catalog:playlists:xyz",
                   "podcast:show:uuid:1234-5678"] {
            XCTAssertEqual(
                ServiceSearchProvider.rewriteItemID(id, style: .amazonCatalogPath), id)
        }
    }

    func testVerbatimStyleNeverRewrites() {
        XCTAssertEqual(
            ServiceSearchProvider.rewriteItemID("catalog:track:asin:B01DPX12SW",
                                                style: .verbatim),
            "catalog:track:asin:B01DPX12SW")
        XCTAssertEqual(
            ServiceSearchProvider.rewriteItemID("spotify:track:4uLU6hMCjMI75M1A2tKUQC",
                                                style: .verbatim),
            "spotify:track:4uLU6hMCjMI75M1A2tKUQC")
    }

    // MARK: - Rewrite + encoding, as the URI builders combine them

    private func encoded(_ id: String, _ style: ItemIDStyle) -> String {
        ServiceSearchProvider.sonosEncodeItemID(
            ServiceSearchProvider.rewriteItemID(id, style: style))
    }

    /// Slashes must survive as lowercase `%2f` and the album descriptor's
    /// `#` as `%23` — the speaker rejects uppercase hex escapes.
    func testEncodedTrackIDMatchesVerifiedURIForm() {
        XCTAssertEqual(encoded("catalog:track:asin:B01DPX12SW", .amazonCatalogPath),
                       "catalog%2ftracks%2fB01DPX12SW%2f")
    }

    func testEncodedAlbumIDMatchesVerifiedURIForm() {
        XCTAssertEqual(encoded("catalog:album:asin:B01DPX15VQ", .amazonCatalogPath),
                       "catalog%2falbums%2fB01DPX15VQ%2f%23album_desc")
    }

    /// A verbatim service: colons to `%3a`,
    /// nothing else touched.
    func testSpotifyIDEncodingUnchanged() {
        XCTAssertEqual(encoded("spotify:track:4uLU6hMCjMI75M1A2tKUQC", .verbatim),
                       "spotify%3atrack%3a4uLU6hMCjMI75M1A2tKUQC")
    }

    // MARK: - Rules, resolved through a household descriptor

    /// `rules(forSid:)` resolves through the household's descriptor name,
    /// so the catalog needs the descriptor before it can answer. Uses an
    /// isolated instance rather than `.shared` — no global test state.
    @MainActor
    private func catalogWithAmazon() -> MusicServiceCatalog {
        let c = MusicServiceCatalog(fetcher: NoopFetcher())
        c.applyRefresh([
            ServiceDescriptor(id: ServiceID.amazonMusic, name: "Amazon Music",
                              secureUri: "https://sonos.smapi.amazonmusic.com/",
                              authType: "AppLink"),
            ServiceDescriptor(id: ServiceID.spotify, name: "Spotify",
                              secureUri: "https://spotify-v5.ws.sonos.com/smapi",
                              authType: "AppLink"),
        ])
        return c
    }

    @MainActor
    func testAmazonRulesUseHLSStaticWithZeroFlags() {
        // S1 form.
        let c = catalogWithAmazon()
        XCTAssertEqual(c.trackURIScheme(forSid: ServiceID.amazonMusic, generation: .s1),
                       URIPrefix.sonosApiHLSStatic)
        XCTAssertEqual(c.trackPlaybackFlags(forSid: ServiceID.amazonMusic, generation: .s1), 0)
        XCTAssertEqual(c.itemIDStyle(forSid: ServiceID.amazonMusic, generation: .s1), .amazonCatalogPath)
    }

    /// S2 form: leaf tracks are not playable from
    /// the local queue at all; collections play as station wrappers with
    /// the anonymous descriptor; real stations keep the S1 stream form.
    @MainActor
    func testAmazonS2RulesPlayCollectionsAsStations() {
        let c = catalogWithAmazon()
        for generation in [SonosSystemVersion.s2, .unknown] {
            let r = c.rules(forSid: ServiceID.amazonMusic, generation: generation)
            XCTAssertEqual(r?.containerPlayForm, .stationWrapper)
            XCTAssertEqual(r?.cdudnForm, .anonymous)
            XCTAssertEqual(r?.didlContainerIdPrefix, "000c0000")
            XCTAssertEqual(r?.streamURIScheme, URIPrefix.sonosApiRadio)
            XCTAssertEqual(r?.streamPlaybackFlags, 8300)
            XCTAssertEqual(c.itemIDStyle(forSid: ServiceID.amazonMusic, generation: generation), .amazonAsin)
        }
        let s1 = c.rules(forSid: ServiceID.amazonMusic, generation: .s1)
        XCTAssertEqual(s1?.containerPlayForm, .cpContainer)
    }

    /// Stations play as `x-sonosapi-radio:` + 8300 with DIDL prefix
    /// `100c2068`; the stream defaults (`x-sonosapi-stream:` + 8224 +
    /// `10092020`) fault UPnP 402 on Amazon.
    @MainActor
    func testAmazonStationRulesUseRadioScheme() {
        let c = catalogWithAmazon()
        let r = c.rules(forSid: ServiceID.amazonMusic)
        XCTAssertEqual(r?.streamURIScheme, URIPrefix.sonosApiRadio)
        XCTAssertEqual(r?.streamPlaybackFlags, 8300)
        XCTAssertEqual(c.didlStreamIdPrefix(forSid: ServiceID.amazonMusic), "100c2068")
        XCTAssertEqual(c.didlTrackIdPrefix(forSid: ServiceID.amazonMusic, generation: .s1), "10030000")
        XCTAssertEqual(c.didlTrackIdPrefix(forSid: ServiceID.amazonMusic), "10030000")
    }

    /// Amazon's getMediaURI returns a signed HLS manifest the speaker can't
    /// play from the queue (UPnP 701) and faults for stations; the raw
    /// service URI is what plays. Every other service keeps resolving.
    @MainActor
    func testAmazonOptsOutOfGetMediaURI() {
        let c = catalogWithAmazon()
        XCTAssertFalse(c.resolvesViaGetMediaURI(forSid: ServiceID.amazonMusic))
        XCTAssertTrue(c.resolvesViaGetMediaURI(forSid: ServiceID.spotify))
        XCTAssertTrue(c.resolvesViaGetMediaURI(forSid: 9999))
    }

    @MainActor
    func testSpotifyKeepsVerbatimStyle() {
        XCTAssertEqual(catalogWithAmazon().itemIDStyle(forSid: ServiceID.spotify),
                       .verbatim)
    }

    /// An unknown sid must not accidentally inherit Amazon's rewrite.
    @MainActor
    func testUnknownServiceDefaultsToVerbatim() {
        XCTAssertEqual(catalogWithAmazon().itemIDStyle(forSid: 9999), .verbatim)
    }
}

/// The DIDL a service track plays with must carry the artist, album and
/// art URL the service reported. Without `<upnp:albumArtURI>` the only
/// art the now-playing pipeline sees is the speaker's `/getaa?` proxy,
/// which 404s for the first seconds of an Amazon track — and that miss
/// sends the resolver into an iTunes guess ("Beck Mellow Gold"
/// resolves to Rod Stewart's "Gold").
final class SMAPITrackDIDLTests: XCTestCase {

    private func trackItem(artist: String = "Beck",
                           album: String = "Mellow Gold [Explicit]",
                           art: String = "https://m.media-amazon.com/images/I/71wNoD7sx6L.jpg")
    -> SMAPIMediaItem {
        SMAPIMediaItem(id: "catalog:track:asin:B076WPXJLS", title: "Loser",
                       itemType: "track", artist: artist, album: album,
                       albumArtURI: art, canPlay: true, canBrowse: false,
                       uri: "", metadata: "")
    }

    @MainActor
    func testTrackDIDLCarriesServiceSuppliedArt() {
        let didl = ServiceSearchProvider.shared
            .smapiItemToBrowseItem(trackItem(), serviceID: ServiceID.amazonMusic, sn: 5, generation: .s1)
            .resourceMetadata ?? ""
        XCTAssertTrue(didl.contains("<dc:creator>Beck</dc:creator>"), didl)
        XCTAssertTrue(didl.contains("<upnp:album>Mellow Gold [Explicit]</upnp:album>"), didl)
        XCTAssertTrue(
            didl.contains("<upnp:albumArtURI>https://m.media-amazon.com/images/I/71wNoD7sx6L.jpg</upnp:albumArtURI>"),
            didl)
    }

    /// Empty fields are omitted, not emitted blank: an empty
    /// `<dc:creator/>` reads as "no artist" and blanks what the speaker
    /// would otherwise resolve on its own.
    @MainActor
    func testEmptyFieldsAreOmitted() {
        let didl = ServiceSearchProvider.shared
            .smapiItemToBrowseItem(trackItem(artist: "", album: "", art: ""),
                                   serviceID: ServiceID.amazonMusic, sn: 5, generation: .s1)
            .resourceMetadata ?? ""
        XCTAssertFalse(didl.contains("dc:creator"), didl)
        XCTAssertFalse(didl.contains("upnp:album>"), didl)
        XCTAssertFalse(didl.contains("albumArtURI"), didl)
        XCTAssertTrue(didl.contains("<dc:title>Loser</dc:title>"), didl)
    }

    /// XML-reserved characters in the art URL (`&` in a query string is
    /// the common case) must not break the envelope.
    @MainActor
    func testArtURLIsXMLEscaped() {
        let didl = ServiceSearchProvider.shared
            .smapiItemToBrowseItem(trackItem(art: "https://art.example/i?a=1&b=2"),
                                   serviceID: ServiceID.amazonMusic, sn: 5, generation: .s1)
            .resourceMetadata ?? ""
        XCTAssertTrue(didl.contains("https://art.example/i?a=1&amp;b=2"), didl)
    }
}

/// Amazon artist items can't be played through the generic container
/// prefix (they need `1008206c`, UPnP 714 otherwise). When Amazon marks
/// one canPlay && !canEnumerate the row must stay browse-only rather
/// than carry a URI that is known to fault.
final class AmazonArtistRoutingTests: XCTestCase {
    /// The guard reads the sid's `ItemIDStyle` from the shared catalog,
    /// which starts empty in tests — seed the Amazon descriptor so the
    /// lookup resolves to `.amazonCatalogPath` as it does at runtime.
    @MainActor
    override func setUp() {
        super.setUp()
        MusicServiceCatalog.shared.applyRefresh([
            ServiceDescriptor(id: ServiceID.amazonMusic, name: "Amazon Music",
                              secureUri: "https://sonos.smapi.amazonmusic.com/",
                              authType: "AppLink"),
            ServiceDescriptor(id: ServiceID.spotify, name: "Spotify",
                              secureUri: "https://spotify-v5.ws.sonos.com/smapi",
                              authType: "AppLink"),
        ])
    }

    @MainActor
    func testPlayableArtistGetsNoPlayURI() {
        let item = SMAPIMediaItem(id: "catalog:artist:asin:B000QJPQ0Y", title: "Beck",
                                  itemType: "artist", artist: "", album: "",
                                  albumArtURI: "", canPlay: true, canBrowse: false,
                                  uri: "", metadata: "")
        let row = ServiceSearchProvider.shared
            .smapiItemToBrowseItem(item, serviceID: ServiceID.amazonMusic, sn: 5, generation: .s1)
        XCTAssertNil(row.resourceURI, "artist must not get a 1004206c container URI")
    }

    @MainActor
    func testSpotifyArtistStillRoutesToContainer() {
        let item = SMAPIMediaItem(id: "spotify:artist:abc", title: "Beck",
                                  itemType: "artist", artist: "", album: "",
                                  albumArtURI: "", canPlay: true, canBrowse: false,
                                  uri: "", metadata: "")
        let row = ServiceSearchProvider.shared
            .smapiItemToBrowseItem(item, serviceID: ServiceID.spotify, sn: 5)
        XCTAssertTrue(row.resourceURI?.hasPrefix("x-rincon-cpcontainer:") == true, row.resourceURI ?? "nil")
    }
}

/// Amazon items must reach the speaker as their raw service URI + DIDL:
/// tracks through the queue (`x-sonosapi-hls-static:`), stations by direct
/// SetAVTransportURI (`x-sonosapi-radio:`). Resolving either through
/// getMediaURI — the default `.smapiResolveThenEmpty` strategy — enqueued a
/// signed CloudFront manifest that faulted UPnP 701 on Play (track), or
/// fell back to an `x-sonosapi-stream:` URI that faulted 402 (station).
final class AmazonPlaybackRoutingTests: XCTestCase {
    @MainActor
    override func setUp() {
        super.setUp()
        MusicServiceCatalog.shared.applyRefresh([
            ServiceDescriptor(id: ServiceID.amazonMusic, name: "Amazon Music",
                              secureUri: "https://sonos.smapi.amazonmusic.com/",
                              authType: "AppLink"),
            ServiceDescriptor(id: ServiceID.spotify, name: "Spotify",
                              secureUri: "https://spotify-v5.ws.sonos.com/smapi",
                              authType: "AppLink"),
        ])
    }

    private func leaf(id: String, type: String, sid: Int, generation: SonosSystemVersion = .s1) -> BrowseItem {
        let item = SMAPIMediaItem(id: id, title: "x", itemType: type, artist: "", album: "",
                                  albumArtURI: "", canPlay: true, canBrowse: false,
                                  uri: "", metadata: "")
        return ServiceSearchProvider.shared.smapiItemToBrowseItem(item, serviceID: sid, sn: 5, generation: generation)
    }

    @MainActor
    func testStationPlaysAsRadioURIWithStationDIDL() {
        let row = leaf(id: "catalog:station:key:A2W1BPRE6V4O9I", type: "stream",
                       sid: ServiceID.amazonMusic)
        XCTAssertEqual(row.resourceURI,
                       "x-sonosapi-radio:catalog%3astation%3akey%3aA2W1BPRE6V4O9I?sid=201&flags=8300&sn=5")
        XCTAssertTrue(row.resourceMetadata?.contains(
            "<item id=\"100c2068catalog%3astation%3akey%3aA2W1BPRE6V4O9I\"") == true,
            row.resourceMetadata ?? "nil")
        XCTAssertEqual(row.playbackStrategy, .directURIWithDIDL)
    }

    @MainActor
    func testTrackKeepsRawHLSStaticURI() {
        let row = leaf(id: "catalog:track:asin:B0C2ZTQJZ9", type: "track",
                       sid: ServiceID.amazonMusic)
        XCTAssertEqual(row.resourceURI,
                       "x-sonosapi-hls-static:catalog%2ftracks%2fB0C2ZTQJZ9%2f?sid=201&flags=0&sn=5")
        XCTAssertTrue(row.resourceMetadata?.contains(
            "<item id=\"10030000catalog%2ftracks%2fB0C2ZTQJZ9%2f\"") == true,
            row.resourceMetadata ?? "nil")
        XCTAssertEqual(row.playbackStrategy, .directURIWithDIDL)
        XCTAssertTrue(SonosManager.isSMAPIServiceTrackURI(row.resourceURI ?? ""),
                      "hls-static tracks must still take the queue path")
    }

    /// S2: a track takes the id form the S2 Sonos app streams (verbatim
    /// ASIN id, hls-static, flags 0, fragment dropped). A station id the
    /// service shaped itself (`sp:container:station:…`, how a Prime
    /// account receives albums and playlists) plays as-is on the
    /// transport with the anonymous descriptor; an artist row is wrapped
    /// into its artist station. Both are exactly what the Sonos app sets.
    func testS2TrackUsesVerbatimIdAndStationsPlayWhole() {
        let track = leaf(id: "catalog:track:asin:B0C2ZTQJZ9#erefid-3d9588a6", type: "track",
                         sid: ServiceID.amazonMusic, generation: .s2)
        XCTAssertEqual(track.resourceURI,
                       "x-sonosapi-hls-static:catalog%3atrack%3aasin%3aB0C2ZTQJZ9?sid=201&flags=0&sn=5")
        XCTAssertTrue(track.resourceMetadata?.contains(
            "<item id=\"10030000catalog%3atrack%3aasin%3aB0C2ZTQJZ9\"") == true, track.resourceMetadata ?? "<nil>")
        XCTAssertTrue(track.resourceMetadata?.contains(">SA_RINCON51463_<") == true)

        let albumStation = SMAPIMediaItem(id: "sp:container:station:catalog:album:asin:B073JC948P", title: "Celebration",
                                          itemType: "program", artist: "Madonna", album: "", albumArtURI: "",
                                          canPlay: true, canBrowse: true, uri: "", metadata: "")
        let row = ServiceSearchProvider.shared.smapiItemToBrowseItem(albumStation, serviceID: ServiceID.amazonMusic, sn: 29,
                                                                     generation: .s2)
        // Drills into the plain album id (full track list), plays the station.
        XCTAssertEqual(row.itemClass, .container)
        XCTAssertEqual(row.objectID, "smapi:201:catalog:album:asin:B073JC948P")
        XCTAssertEqual(row.resourceURI,
                       "x-sonosapi-radio:sp%3acontainer%3astation%3acatalog%3aalbum%3aasin%3aB073JC948P?sid=201&flags=0&sn=29")
        XCTAssertTrue(row.resourceMetadata?.contains(
            "<item id=\"000c0000sp%3acontainer%3astation%3acatalog%3aalbum%3aasin%3aB073JC948P\"") == true,
            row.resourceMetadata ?? "<nil>")
        XCTAssertTrue(row.resourceMetadata?.contains("object.item.audioItem.audioBroadcast") == true)
        XCTAssertTrue(row.resourceMetadata?.contains(">SA_RINCON51463_<") == true, row.resourceMetadata ?? "<nil>")
        XCTAssertEqual(row.playbackStrategy, .directURIWithDIDL)

        let unplayable = SMAPIMediaItem(id: "catalog:track:asin:B000TGVN06", title: "Skin O' My Teeth", itemType: "track",
                                        artist: "Megadeth", album: "", albumArtURI: "", canPlay: false, canBrowse: false,
                                        uri: "", metadata: "")
        let dead = ServiceSearchProvider.shared.smapiItemToBrowseItem(unplayable, serviceID: ServiceID.amazonMusic, sn: 29,
                                                                      generation: .s2)
        // canPlay=false describes the controller's link, not the speaker's
        // account: such a track played with audio through the queue.
        XCTAssertEqual(dead.resourceURI,
                       "x-sonosapi-hls-static:catalog%3atrack%3aasin%3aB000TGVN06?sid=201&flags=0&sn=29")

        let artist = SMAPIMediaItem(id: "catalog:artist:asin:B000QJPK78", title: "Megadeth", itemType: "artist",
                                    artist: "", album: "", albumArtURI: "", canPlay: true, canBrowse: true,
                                    uri: "", metadata: "")
        let artistRow = ServiceSearchProvider.shared.smapiItemToBrowseItem(artist, serviceID: ServiceID.amazonMusic, sn: 29,
                                                                           generation: .s2)
        XCTAssertTrue(artistRow.isContainer)
        XCTAssertEqual(artistRow.resourceURI,
                       "x-sonosapi-radio:sp%3acontainer%3astation%3acatalog%3aartist%3aasin%3aB000QJPK78?sid=201&flags=0&sn=29")
    }

    @MainActor
    func testSpotifyTrackStillResolves() {
        let row = leaf(id: "spotify:track:4uLU6hMCjMI75M1A2tKUQC", type: "track",
                       sid: ServiceID.spotify)
        XCTAssertEqual(row.playbackStrategy, .smapiResolveThenEmpty)
    }

    /// S1 Amazon containers keep the generic cpcontainer prefix; the S2
    /// `000c0000` prefix belongs to the station form only.
    @MainActor
    func testS1ContainerPrefixFollowsGeneration() {
        let album = SMAPIMediaItem(id: "catalog:album:asin:B073JC948P", title: "x", itemType: "album",
                                   artist: "", album: "", albumArtURI: "", canPlay: true, canBrowse: false,
                                   uri: "", metadata: "")
        let s1 = ServiceSearchProvider.shared.smapiItemToBrowseItem(album, serviceID: ServiceID.amazonMusic,
                                                                    sn: 5, generation: .s1)
        let s2 = ServiceSearchProvider.shared.smapiItemToBrowseItem(album, serviceID: ServiceID.amazonMusic,
                                                                    sn: 5, generation: .s2)
        XCTAssertTrue(s1.resourceMetadata?.contains("<item id=\"1004206c") == true, s1.resourceMetadata ?? "<nil>")
        XCTAssertTrue(s2.resourceMetadata?.contains("<item id=\"000c0000") == true, s2.resourceMetadata ?? "<nil>")
    }

    // MARK: - S2 form and search-result fragments

    func testSearchFragmentIsStrippedBeforeRewrite() {
        XCTAssertEqual(
            ServiceSearchProvider.rewriteItemID("catalog:track:asin:B00123HFAM#erefid-3d9588a6-cb8d-4edc-a7a1-28576dcc48f4",
                                                style: .amazonCatalogPath),
            "catalog/tracks/B00123HFAM/")
        XCTAssertEqual(
            ServiceSearchProvider.rewriteItemID("catalog:track:asin:B00123HFAM#erefid-3d9588a6",
                                                style: .amazonAsin),
            "catalog:track:asin:B00123HFAM")
    }

    func testAsinStyleKeepsIdWithoutFragment() {
        XCTAssertEqual(ServiceSearchProvider.rewriteItemID("catalog:station:key:abc", style: .amazonAsin),
                       "catalog:station:key:abc")
    }

    /// The S2 default and the S1 variant are distinct rule sets.
    func testAmazonRulesDifferByGeneration() {
        let s2 = MusicServiceCatalog.buildStaticRulesTable()["amazon music"]
        let s1 = MusicServiceCatalog.buildS1RulesTable()["amazon music"]
        XCTAssertEqual(s2?.trackURIScheme, URIPrefix.sonosApiHLSStatic)
        XCTAssertEqual(s2?.trackURIExtension, "")
        XCTAssertEqual(s2?.trackPlaybackFlags, 0)
        XCTAssertEqual(s2?.didlTrackIdPrefix, "10030000")
        XCTAssertEqual(s2?.didlContainerIdPrefix, "000c0000")
        XCTAssertEqual(s2?.itemIDStyle, .amazonAsin)
        XCTAssertEqual(s2?.containerPlayForm, .stationWrapper)
        XCTAssertEqual(s2?.cdudnForm, .anonymous)
        XCTAssertEqual(s1?.trackURIScheme, URIPrefix.sonosApiHLSStatic)
        XCTAssertEqual(s1?.trackPlaybackFlags, 0)
        XCTAssertEqual(s1?.didlTrackIdPrefix, "10030000")
        XCTAssertEqual(s1?.didlContainerIdPrefix, "1004206c")
        XCTAssertEqual(s1?.itemIDStyle, .amazonCatalogPath)
        XCTAssertEqual(s1?.containerPlayForm, .cpContainer)
        XCTAssertEqual(s1?.resolvesViaGetMediaURI, false)
        XCTAssertEqual(s2?.resolvesViaGetMediaURI, false)
    }
}

/// No-op fetcher so the catalog never makes a live SOAP call in tests.
private struct NoopFetcher: ListAvailableServicesFetching {
    func fetch(speakerIP: String) async throws -> [ServiceDescriptor] { [] }
}
