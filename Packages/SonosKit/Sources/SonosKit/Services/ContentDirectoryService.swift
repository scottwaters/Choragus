/// ContentDirectoryService.swift — UPnP ContentDirectory:1 service wrapper.
///
/// Handles browsing the Sonos content tree (library, favorites, playlists, radio),
/// queue management, and search. Note: queue mutation actions (remove, reorder)
/// route through AVTransport, not ContentDirectory — Sonos deviates from the
/// UPnP spec here.
import Foundation

public struct QueueItem: Identifiable, Equatable {
    public let id: Int // 1-based position in queue
    public var title: String
    public var artist: String
    public var album: String
    public var albumArtURI: String?
    public var duration: String

    public init(id: Int, title: String = "", artist: String = "", album: String = "",
                albumArtURI: String? = nil, duration: String = "") {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtURI = albumArtURI
        self.duration = duration
    }
}

public final class ContentDirectoryService {
    private let soap: SOAPClient
    private static let path = "/MediaServer/ContentDirectory/Control"
    private static let service = "ContentDirectory"

    public init(soap: SOAPClient = SOAPClient()) {
        self.soap = soap
    }

    public func browseQueue(device: SonosDevice, start: Int = 0, count: Int = PageSize.queue) async throws -> (items: [QueueItem], total: Int) {
        let result = try await soap.send(
            to: device.baseURL,
            path: Self.path,
            service: Self.service,
            action: "Browse",
            arguments: [
                ("ObjectID", "Q:0"),
                ("BrowseFlag", "BrowseDirectChildren"),
                ("Filter", "dc:title,res,dc:creator,upnp:artist,upnp:album,upnp:albumArtURI"),
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

    /// Renames a Sonos playlist via UpdateObject
    public func renameSavedQueue(device: SonosDevice, objectID: String, oldTitle: String, newTitle: String) async throws {
        _ = try await soap.send(
            to: device.baseURL,
            path: Self.path,
            service: Self.service,
            action: "UpdateObject",
            arguments: [
                ("ObjectID", objectID),
                ("CurrentTagValue", "<dc:title>\(oldTitle)</dc:title>"),
                ("NewTagValue", "<dc:title>\(newTitle)</dc:title>")
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
    private var inItem = false
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

        if name == "item" {
            inItem = true
            currentTitle = ""
            currentArtist = ""
            currentAlbum = ""
            currentArtURI = ""
            currentResURI = ""
            currentDuration = ""
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
                    duration: currentDuration
                ))
                inItem = false
            default: break
            }
        }
    }
}
