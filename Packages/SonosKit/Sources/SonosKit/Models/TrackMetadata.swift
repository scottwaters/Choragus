import Foundation

public struct TrackMetadata: Equatable {
    public var title: String
    public var artist: String
    public var album: String
    public var albumArtURI: String?
    public var duration: TimeInterval
    public var position: TimeInterval
    public var trackNumber: Int
    public var queueSize: Int

    public init(title: String = "", artist: String = "", album: String = "",
                albumArtURI: String? = nil, duration: TimeInterval = 0,
                position: TimeInterval = 0, trackNumber: Int = 0, queueSize: Int = 0) {
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtURI = albumArtURI
        self.duration = duration
        self.position = position
        self.trackNumber = trackNumber
        self.queueSize = queueSize
    }

    public var durationString: String {
        formatTime(duration)
    }

    public var positionString: String {
        formatTime(position)
    }

    private func formatTime(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    public static func parseTimeString(_ time: String) -> TimeInterval {
        let parts = time.split(separator: ":").compactMap { Double($0) }
        switch parts.count {
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2: return parts[0] * 60 + parts[1]
        case 1: return parts[0]
        default: return 0
        }
    }
}
