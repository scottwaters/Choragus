/// ContentDirectoryService.swift — UPnP ContentDirectory:1 service wrapper.
///
/// Handles browsing the Sonos content tree (library, favorites, playlists, radio),
/// queue management, and search. Note: queue mutation actions (remove, reorder)
/// route through AVTransport, not ContentDirectory — Sonos deviates from the
/// UPnP spec here.
import Foundation

public struct QueueItem: Identifiable, Equatable, Codable {
    public let id: Int // 1-based position in queue
    public var title: String
    public var artist: String
    public var album: String
    public var albumArtURI: String?
    public var duration: String
    /// The track's resource URI (`<res>`), used to recover a real title from
    /// the play-time cache when the speaker returns a filename (e.g. Suno's
    /// `<uuid>.mp3`) instead of the song name.
    public var uri: String?
    /// The track's `<r:resMD>` DIDL envelope when the speaker supplied one.
    /// Apple Music / SMAPI tracks fault UPnP 800 if re-enqueued without it,
    /// so it must be preserved when a queue is saved for later restore.
    public var metadata: String?

    public init(id: Int, title: String = "", artist: String = "", album: String = "",
                albumArtURI: String? = nil, duration: String = "", uri: String? = nil,
                metadata: String? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtURI = albumArtURI
        self.duration = duration
        self.uri = uri
        self.metadata = metadata
    }
}

public final class ContentDirectoryService {
    private let soap: SOAPClient
    private static let path = "/MediaServer/ContentDirectory/Control"
    private static let service = "ContentDirectory"

    public init(soap: SOAPClient = SOAPClient()) {
        self.soap = soap
    }

    /// `includeMetadata` adds `r:resMD` to the filter so each row carries its
    /// full DIDL envelope — needed only by the save-for-restore path (Apple
    /// Music / SMAPI tracks fault UPnP 800 when re-enqueued without it). The
    /// live queue panel omits it: it doesn't use the envelope, and requesting
    /// it makes the speaker return heavier per-item metadata for no benefit.
    public func browseQueue(device: SonosDevice, start: Int = 0, count: Int = PageSize.queue,
                            includeMetadata: Bool = false) async throws -> (items: [QueueItem], total: Int) {
        let filter = includeMetadata
            ? "dc:title,res,dc:creator,upnp:artist,upnp:album,upnp:albumArtURI,r:resMD"
            : "dc:title,res,dc:creator,upnp:artist,upnp:album,upnp:albumArtURI"
        let result = try await soap.send(
            to: device.baseURL,
            path: Self.path,
            service: Self.service,
            action: "Browse",
            arguments: [
                ("ObjectID", "Q:0"),
                ("BrowseFlag", "BrowseDirectChildren"),
                ("Filter", filter),
                ("StartingIndex", "\(start)"),
                ("RequestedCount", "\(count)"),
                ("SortCriteria", "")
            ]
        )

        let total = Int(result["TotalMatches"] ?? "0") ?? 0
        guard let didlResult = result["Result"], !didlResult.isEmpty else {
            return ([], total)
        }

        let items = QueueXMLParser.parse(didlResult, deviceIP: device.ip, devicePort: device.port, startIndex: start)
        return (items, total)
    }

    /// Remove a single track — note this goes through AVTransport, not ContentDirectory
    public func removeTrackFromQueue(device: SonosDevice, objectID: String) async throws {
        _ = try await soap.send(
            to: device.baseURL,
            path: "/MediaRenderer/AVTransport/Control",
            service: "AVTransport",
            action: "RemoveTrackFromQueue",
            arguments: [
                ("InstanceID", "0"),
                ("ObjectID", objectID),
                ("UpdateID", "0")
            ]
        )
    }

    public func removeAllTracksFromQueue(device: SonosDevice) async throws {
        _ = try await soap.send(
            to: device.baseURL,
            path: "/MediaRenderer/AVTransport/Control",
            service: "AVTransport",
            action: "RemoveAllTracksFromQueue",
            arguments: [("InstanceID", "0")]
        )
    }

    /// Triggers a music-library reindex on the device's household. The call is
    /// household-wide: any one coordinator reindexes every configured share, so
    /// callers fire it once per household. `AlbumArtistDisplayOption` is sent
    /// empty to leave the speaker's current album-artist grouping unchanged.
    public func refreshShareIndex(device: SonosDevice) async throws {
        _ = try await soap.send(
            to: device.baseURL,
            path: Self.path,
            service: "ContentDirectory",
            action: "RefreshShareIndex",
            arguments: [("AlbumArtistDisplayOption", "")]
        )
    }

    /// Whether a library reindex is currently running on the device's
    /// household. Returns false on any error (treat unknown as not-indexing).
    public func isShareIndexInProgress(device: SonosDevice) async -> Bool {
        guard let result = try? await soap.send(
            to: device.baseURL,
            path: Self.path,
            service: "ContentDirectory",
            action: "GetShareIndexInProgress",
            arguments: []
        ) else { return false }
        return result["IsIndexing"] == "1"
    }

    public func reorderTracksInQueue(device: SonosDevice, startIndex: Int, numberOfTracks: Int, insertBefore: Int) async throws {
        _ = try await soap.send(
            to: device.baseURL,
            path: "/MediaRenderer/AVTransport/Control",
            service: "AVTransport",
            action: "ReorderTracksInQueue",
            arguments: [
                ("InstanceID", "0"),
                ("StartingIndex", "\(startIndex)"),
                ("NumberOfTracks", "\(numberOfTracks)"),
                ("InsertBefore", "\(insertBefore)"),
                ("UpdateID", "0")
            ]
        )
    }

    public func seekToTrack(device: SonosDevice, trackNumber: Int) async throws {
        _ = try await soap.send(
            to: device.baseURL,
            path: "/MediaRenderer/AVTransport/Control",
            service: "AVTransport",
            action: "Seek",
            arguments: [
                ("InstanceID", "0"),
                ("Unit", "TRACK_NR"),
                ("Target", "\(trackNumber)")
            ]
        )
    }

    /// Fetches metadata for a single item (not its children).
    /// Returns the item's own DIDL including albumArtURI if available.
    public func browseMetadata(device: SonosDevice, objectID: String) async throws -> BrowseItem? {
        let result = try await soap.send(
            to: device.baseURL,
            path: Self.path,
            service: Self.service,
            action: "Browse",
            arguments: [
                ("ObjectID", objectID),
                ("BrowseFlag", "BrowseMetadata"),
                ("Filter", "dc:title,res,dc:creator,upnp:artist,upnp:album,upnp:albumArtURI,upnp:class"),
                ("StartingIndex", "0"),
                ("RequestedCount", "1"),
                ("SortCriteria", "")
            ]
        )
        guard let didlResult = result["Result"], !didlResult.isEmpty else { return nil }
        let items = BrowseXMLParser.parse(didlResult, deviceIP: device.ip, devicePort: device.port)
        return items.first
    }

    // MARK: - Generic Browse

    public func browse(device: SonosDevice, objectID: String, start: Int = 0, count: Int = PageSize.browse) async throws -> (items: [BrowseItem], total: Int) {
        let result = try await soap.send(
            to: device.baseURL,
            path: Self.path,
            service: Self.service,
            action: "Browse",
            arguments: [
                ("ObjectID", objectID),
                ("BrowseFlag", "BrowseDirectChildren"),
                ("Filter", "dc:title,res,dc:creator,upnp:artist,upnp:album,upnp:albumArtURI,upnp:class"),
                ("StartingIndex", "\(start)"),
                ("RequestedCount", "\(count)"),
                ("SortCriteria", "")
            ]
        )

        let total = Int(result["TotalMatches"] ?? "0") ?? 0
        guard let didlResult = result["Result"], !didlResult.isEmpty else {
            return ([], total)
        }

        let items = BrowseXMLParser.parse(didlResult, deviceIP: device.ip, devicePort: device.port)
        return (items, total)
    }

    // MARK: - Add to Queue

    public func addURIToQueue(device: SonosDevice, uri: String, metadata: String = "", desiredFirstTrackNumberEnqueued: Int = 0, enqueueAsNext: Bool = false) async throws -> Int {
        let result = try await soap.send(
            to: device.baseURL,
            path: "/MediaRenderer/AVTransport/Control",
            service: "AVTransport",
            action: "AddURIToQueue",
            arguments: [
                ("InstanceID", "0"),
                ("EnqueuedURI", uri),
                ("EnqueuedURIMetaData", metadata),
                ("DesiredFirstTrackNumberEnqueued", "\(desiredFirstTrackNumberEnqueued)"),
                ("EnqueueAsNext", enqueueAsNext ? "1" : "0")
            ]
        )
        return Int(result["FirstTrackNumberEnqueued"] ?? "0") ?? 0
    }

    /// Adds multiple tracks in a single SOAP round-trip. Max 16 items per call
    /// (Sonos firmware limit — callers should chunk larger batches). Returns
    /// the queue position of the first track added and the number of tracks
    /// successfully enqueued.
    ///
    /// Wire format (verified against SoCo, jishi/node-sonos-discovery, and
    /// node-sonos-ts — they all agree):
    /// - `EnqueuedURIs` — URIs joined with a single ASCII space.
    /// - `EnqueuedURIsMetaData` — **raw** DIDL-Lite XML strings joined with a
    ///   single ASCII space. Do NOT pre-escape. The SOAPClient performs the
    ///   single XML-entity escape pass required at envelope level. Escaping
    ///   here as well would produce `&amp;lt;DIDL…` on the wire — the
    ///   speaker unescapes once, sees `&lt;DIDL…` instead of `<DIDL…`, and
    ///   rejects the request with UPnPError 402 (Invalid Args).
    public func addMultipleURIsToQueue(
        device: SonosDevice,
        uris: [String],
        metadatas: [String],
        desiredFirstTrackNumberEnqueued: Int = 0,
        enqueueAsNext: Bool = false
    ) async throws -> (firstTrackNumber: Int, numAdded: Int) {
        precondition(uris.count == metadatas.count, "uris and metadatas must be the same length")
        guard !uris.isEmpty else { return (0, 0) }
        // The `EnqueuedURIs` argument is a SPACE-SEPARATED list of URIs.
        // Local-library SMB paths (`x-file-cifs://server/Pink Floyd/...`)
        // and many service URIs contain literal spaces inside the path
        // — without encoding, the speaker splits at the wrong places
        // and silently rejects every URI past the first one. The
        // single-URI `AddURIToQueue` path doesn't see this because
        // there's no separator there. Idempotent: existing `%20`
        // sequences are untouched.
        //
        // Metadata blobs are space-joined too, but each DIDL-Lite
        // element is delimited by `</DIDL-Lite>`, so internal spaces
        // there are unambiguous to the speaker's parser.
        let encodedURIs = uris.map { $0.replacingOccurrences(of: " ", with: "%20") }
        let joinedURIs = encodedURIs.joined(separator: " ")
        let joinedMeta = metadatas.joined(separator: " ")
        let result = try await soap.send(
            to: device.baseURL,
            path: "/MediaRenderer/AVTransport/Control",
            service: "AVTransport",
            action: "AddMultipleURIsToQueue",
            arguments: [
                ("InstanceID", "0"),
                ("UpdateID", "0"),
                ("NumberOfURIs", "\(uris.count)"),
                ("EnqueuedURIs", joinedURIs),
                ("EnqueuedURIsMetaData", joinedMeta),
                ("ContainerURI", ""),
                ("ContainerMetaData", ""),
                ("DesiredFirstTrackNumberEnqueued", "\(desiredFirstTrackNumberEnqueued)"),
                ("EnqueueAsNext", enqueueAsNext ? "1" : "0")
            ],
            // Bulk add scales linearly with the chunk size on the speaker.
            // 14-16 tracks ≈ 15-25 s on real hardware. Default 10 s
            // session timeout caused us to abort the batch even when
            // Sonos was still happily processing it, leading to false
            // "batch failed" → per-track fallback → DOUBLE-ADD.
            timeoutSeconds: 30
        )
        let first = Int(result["FirstTrackNumberEnqueued"] ?? "0") ?? 0
        let added = Int(result["NumTracksAdded"] ?? "0") ?? 0
        return (first, added)
    }

    // MARK: - Playlist Management (Saved Queues)

    /// Creates a new Sonos playlist from the current queue
    public func createSavedQueue(device: SonosDevice, title: String) async throws -> String {
        let result = try await soap.send(
            to: device.baseURL,
            path: "/MediaRenderer/AVTransport/Control",
            service: "AVTransport",
            action: "CreateSavedQueue",
            arguments: [
                ("InstanceID", "0"),
                ("Title", title),
                ("EnqueuedURI", ""),
                ("EnqueuedURIMetaData", "")
            ]
        )
        return result["AssignedObjectID"] ?? ""
    }

    /// Saves the current queue as a new Sonos playlist (includes all tracks)
    public func saveQueue(device: SonosDevice, title: String, objectID: String = "") async throws -> String {
        let result = try await soap.send(
            to: device.baseURL,
            path: "/MediaRenderer/AVTransport/Control",
            service: "AVTransport",
            action: "SaveQueue",
            arguments: [
                ("InstanceID", "0"),
                ("Title", title),
                ("ObjectID", objectID)
            ]
        )
        return result["AssignedObjectID"] ?? ""
    }

    /// Adds a track to an existing Sonos playlist
    public func addURIToSavedQueue(device: SonosDevice, objectID: String, uri: String, metadata: String = "", addAtIndex: Int = 4294967295) async throws -> Int {
        let result = try await soap.send(
            to: device.baseURL,
            path: "/MediaRenderer/AVTransport/Control",
            service: "AVTransport",
            action: "AddURIToSavedQueue",
            arguments: [
                ("InstanceID", "0"),
                ("ObjectID", objectID),
                ("EnqueuedURI", uri),
                ("EnqueuedURIMetaData", metadata),
                ("AddAtIndex", "\(addAtIndex)"),
                ("UpdateID", "0")
            ]
        )
        return Int(result["NewQueueLength"] ?? "0") ?? 0
    }

    /// Deletes a Sonos playlist
    public func destroyObject(device: SonosDevice, objectID: String) async throws {
        _ = try await soap.send(
            to: device.baseURL,
            path: Self.path,
            service: Self.service,
            action: "DestroyObject",
            arguments: [("ObjectID", objectID)]
        )
    }

    /// Renames a Sonos playlist via UpdateObject.
    ///
    /// Titles need their own entity-escape INSIDE the fragment: SOAPClient
    /// escapes the whole argument once at envelope level, and the speaker
    /// unescapes once before parsing the fragment — so a raw "R&B Mix"
    /// would arrive as invalid inner XML (UPnP fault), and a title
    /// containing `</dc:title>` would rewrite the tag value.
    public func renameSavedQueue(device: SonosDevice, objectID: String, oldTitle: String, newTitle: String) async throws {
        func escaped(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "'", with: "&apos;")
        }
        _ = try await soap.send(
            to: device.baseURL,
            path: Self.path,
            service: Self.service,
            action: "UpdateObject",
            arguments: [
                ("ObjectID", objectID),
                ("CurrentTagValue", "<dc:title>\(escaped(oldTitle))</dc:title>"),
                ("NewTagValue", "<dc:title>\(escaped(newTitle))</dc:title>")
            ]
        )
    }

    // MARK: - Search

    /// Sonos "search" is actually a Browse with a colon-delimited search term appended
    /// to the container ID (e.g. "A:ARTIST:Beatles"). This is a Sonos-specific convention,
    /// not standard UPnP Search.
    public func search(device: SonosDevice, containerID: String = BrowseID.tracks, searchTerm: String, start: Int = 0, count: Int = PageSize.search) async throws -> (items: [BrowseItem], total: Int) {
        let searchObjectID = "\(containerID):\(searchTerm)"
        let result = try await soap.send(
            to: device.baseURL,
            path: Self.path,
            service: Self.service,
            action: "Browse",
            arguments: [
                ("ObjectID", searchObjectID),
                ("BrowseFlag", "BrowseDirectChildren"),
                ("Filter", "dc:title,res,dc:creator,upnp:artist,upnp:album,upnp:albumArtURI,upnp:class"),
                ("StartingIndex", "\(start)"),
                ("RequestedCount", "\(count)"),
                ("SortCriteria", "")
            ]
        )

        let total = Int(result["TotalMatches"] ?? "0") ?? 0
        guard let didlResult = result["Result"], !didlResult.isEmpty else {
            return ([], total)
        }

        let items = BrowseXMLParser.parse(didlResult, deviceIP: device.ip, devicePort: device.port)
        return (items, total)
    }
}

// MARK: - Queue DIDL-Lite Parser

private class QueueXMLParser: NSObject, XMLParserDelegate {
    private var items: [QueueItem] = []
    private var currentElement = ""
    private var currentValue = ""
    private var currentTitle = ""
    private var currentArtist = ""
    private var currentAlbum = ""
    private var currentArtURI = ""
    private var currentResURI = ""
    private var currentDuration = ""
    private var currentResMD = ""
    private var inItem = false
    private var inResMD = false
    private var resMDHadChildElements = false
    private var itemIndex: Int
    private let deviceIP: String
    private let devicePort: Int

    init(deviceIP: String, devicePort: Int, startIndex: Int) {
        self.deviceIP = deviceIP
        self.devicePort = devicePort
        self.itemIndex = startIndex
    }

    static func parse(_ xml: String, deviceIP: String, devicePort: Int, startIndex: Int) -> [QueueItem] {
        // Do NOT call xmlUnescape — SOAP parser already unescaped the outer layer
        guard let data = xml.data(using: .utf8) else { return [] }
        let handler = QueueXMLParser(deviceIP: deviceIP, devicePort: devicePort, startIndex: startIndex)
        let parser = XMLParser(data: data)
        parser.delegate = handler
        parser.parse()
        return handler.items
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let name = elementName.components(separatedBy: ":").last ?? elementName
        currentElement = name
        currentValue = ""

        // `<r:resMD>` holds a nested DIDL. Normally it arrives XML-escaped, so
        // the SAX layer delivers it as character data and no child-element
        // events fire. Some firmware returns it as real nested elements,
        // though — guard against that so a nested `<item>`/`<res>`/
        // `<albumArtURI>` can't reset or clobber the OUTER queue row's fields
        // (the cause of queue artwork vanishing when resMD was requested).
        if inResMD {
            resMDHadChildElements = true
            return
        }
        if name == "resMD" {
            inResMD = true
            return
        }

        if name == "item" {
            inItem = true
            currentTitle = ""
            currentArtist = ""
            currentAlbum = ""
            currentArtURI = ""
            currentResURI = ""
            currentDuration = ""
            currentResMD = ""
            resMDHadChildElements = false
        }

        if name == "res", let dur = attributes["duration"] {
            currentDuration = dur
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentValue += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let name = elementName.components(separatedBy: ":").last ?? elementName
        let trimmed = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)

        // Close of the resMD element — capture the (escaped-text) envelope.
        // If the firmware nested real child elements, `currentValue` is
        // unreliable, so skip capture rather than store a fragment.
        if name == "resMD" {
            inResMD = false
            if !resMDHadChildElements, !trimmed.isEmpty { currentResMD = trimmed }
            return
        }
        if inResMD { return }   // ignore nested element ends inside resMD

        if inItem {
            switch name {
            case "title": currentTitle = trimmed
            case "creator", "artist": if currentArtist.isEmpty { currentArtist = trimmed }
            case "album": currentAlbum = trimmed
            case "albumArtURI":
                if trimmed.hasPrefix("/") {
                    currentArtURI = "http://\(deviceIP):\(devicePort)\(trimmed)"
                } else {
                    currentArtURI = trimmed
                }
            case "res":
                if !trimmed.isEmpty { currentResURI = trimmed }
            case "item":
                // Fallback: if no albumArtURI but have a local file URI, use /getaa
                var artURI = currentArtURI
                if artURI.isEmpty, !currentResURI.isEmpty,
                   URIPrefix.isLocal(currentResURI) {
                    artURI = AlbumArtSearchService.getaaURL(
                        speakerIP: deviceIP, port: devicePort, trackURI: currentResURI)
                }
                itemIndex += 1
                items.append(QueueItem(
                    id: itemIndex,
                    title: currentTitle,
                    artist: currentArtist,
                    album: currentAlbum,
                    albumArtURI: artURI.isEmpty ? nil : artURI,
                    duration: currentDuration,
                    uri: currentResURI.isEmpty ? nil : currentResURI,
                    metadata: currentResMD.isEmpty ? nil : currentResMD
                ))
                inItem = false
            default: break
            }
        }
    }
}
