import Foundation

public enum TransportState: String {
    case playing = "PLAYING"
    case paused = "PAUSED_PLAYBACK"
    case stopped = "STOPPED"
    case transitioning = "TRANSITIONING"
    case noMedia = "NO_MEDIA_PRESENT"

    public var isPlaying: Bool { self == .playing }
    public var isActive: Bool { self == .playing || self == .transitioning }
}
