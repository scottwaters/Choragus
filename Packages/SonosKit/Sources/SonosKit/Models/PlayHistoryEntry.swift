/// PlayHistoryEntry.swift — A single play history record.
import Foundation

public struct PlayHistoryEntry: Identifiable, Codable {
    public var id: UUID
    public var timestamp: Date
    public var title: String
    public var artist: String
    public var album: String
    public var stationName: String
    public var sourceURI: String?
    public var groupName: String
    public var duration: TimeInterval
    public var albumArtURI: String?
    public var starred: Bool
    public var genre: String

    public init(id: UUID = UUID(), timestamp: Date = Date(), title: String, artist: String = "",
                album: String = "", stationName: String = "", sourceURI: String? = nil,
                groupName: String = "", duration: TimeInterval = 0, albumArtURI: String? = nil,
                starred: Bool = false, genre: String = "") {
        self.id = id
        self.timestamp = timestamp
        self.title = title
        self.artist = artist
        self.album = album
        self.stationName = stationName
        self.sourceURI = sourceURI
        self.groupName = groupName
        self.duration = duration
        self.albumArtURI = albumArtURI
        self.starred = starred
        self.genre = genre
    }
}
