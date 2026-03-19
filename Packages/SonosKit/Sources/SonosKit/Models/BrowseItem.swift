/// BrowseItem.swift — Models for the Sonos content directory browse tree.
///
/// BrowseItem represents a single entry (track, album, playlist, etc.) from
/// a ContentDirectory Browse response. BrowseItemClass maps UPnP class strings
/// (e.g. "object.container.album.musicAlbum") to a simpler local enum.
import Foundation

public struct BrowseItem: Identifiable, Equatable {
    public let id: String // UPnP objectID, e.g. FV:2/124, SQ:17, A:ARTIST/Beatles
    public var title: String
    public var artist: String
    public var album: String
    public var albumArtURI: String?
    public var itemClass: BrowseItemClass
    public var resourceURI: String? // playable URI
    public var resourceMetadata: String? // DIDL metadata for playback

    public init(id: String, title: String = "", artist: String = "", album: String = "",
                albumArtURI: String? = nil, itemClass: BrowseItemClass = .unknown,
                resourceURI: String? = nil, resourceMetadata: String? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtURI = albumArtURI
        self.itemClass = itemClass
        self.resourceURI = resourceURI
        self.resourceMetadata = resourceMetadata
    }

    public var isContainer: Bool {
        itemClass.isContainer
    }

    public var isPlayable: Bool {
        (resourceURI != nil && !(resourceURI?.isEmpty ?? true)) || isContainer
    }

    /// True when the item exists in Sonos favorites but needs a streaming service
    /// (Spotify, Apple Music, etc.) to actually play — we can't play these via UPnP alone
    public var requiresService: Bool {
        !isContainer && (resourceURI == nil || resourceURI?.isEmpty == true)
    }
}

public enum BrowseItemClass: Equatable {
    case container
    case musicTrack
    case musicAlbum
    case musicArtist
    case genre
    case playlist
    case favorite
    case radioStation
    case radioShow
    case unknown

    public var isContainer: Bool {
        switch self {
        case .container, .musicAlbum, .musicArtist, .genre, .playlist, .radioStation, .radioShow:
            return true
        case .musicTrack, .favorite, .unknown:
            return false
        }
    }

    public var systemImage: String {
        switch self {
        case .container: return "folder"
        case .musicTrack: return "music.note"
        case .musicAlbum: return "square.stack"
        case .musicArtist: return "person"
        case .genre: return "guitars"
        case .playlist: return "music.note.list"
        case .favorite: return "star"
        case .radioStation: return "antenna.radiowaves.left.and.right"
        case .radioShow: return "radio"
        case .unknown: return "music.note"
        }
    }

    /// Maps UPnP class URNs (e.g. "object.item.audioItem.musicTrack") to local types.
    /// Uses contains() rather than exact match because Sonos appends vendor extensions.
    public static func from(upnpClass: String) -> BrowseItemClass {
        if upnpClass.contains("musicTrack") { return .musicTrack }
        if upnpClass.contains("musicAlbum") { return .musicAlbum }
        if upnpClass.contains("musicArtist") || upnpClass.contains("person") { return .musicArtist }
        if upnpClass.contains("genre") { return .genre }
        if upnpClass.contains("playlistContainer") || upnpClass.contains("playlist") { return .playlist }
        if upnpClass.contains("favorite") { return .favorite }
        if upnpClass.contains("audioBroadcast") { return .radioStation }
        if upnpClass.contains("container") { return .container }
        return .unknown
    }
}

public struct BrowseSection: Identifiable {
    public let id: String
    public let title: String
    public let objectID: String
    public let icon: String

    public init(id: String, title: String, objectID: String, icon: String) {
        self.id = id
        self.title = title
        self.objectID = objectID
        self.icon = icon
    }
}
