/// HomeTheaterZone.swift — Models for bonded home theater setups (5.1 surround, sub, etc.)
import Foundation

public struct HomeTheaterZone: Identifiable {
    public var id: String { coordinatorID }
    public let coordinatorID: String
    public let name: String
    public let members: [HomeTheaterMember]

    public var hasSub: Bool { members.contains { $0.channel == .sub } }
    public var hasSurrounds: Bool { members.contains { $0.channel == .rearLeft || $0.channel == .rearRight } }

    public var description: String {
        var parts: [String] = []
        if hasSurrounds { parts.append("LS+RS") }
        if hasSub { parts.append("Sub") }
        return parts.isEmpty ? name : "\(name) (\(parts.joined(separator: "+")))"
    }
}

public struct HomeTheaterMember: Identifiable {
    public var id: String { device.id }
    public let device: SonosDevice
    public let channel: SpeakerChannel
}

public enum SpeakerChannel: String, CaseIterable {
    case soundbar = "LF,RF"
    case sub = "SW"
    case rearLeft = "LR"
    case rearRight = "RR"
    /// Stereo-pair left primary (Sonos `ChannelMapSet` `LF,LF`). The
    /// pair primary is a visible zone member; the right half is
    /// invisible and only discoverable via the channel map.
    case leftPair = "LF,LF"
    /// Stereo-pair right (invisible) — `ChannelMapSet` `RF,RF`.
    case rightPair = "RF,RF"

    public var displayName: String {
        switch self {
        case .soundbar: return "Soundbar"
        case .sub: return "Sub"
        case .rearLeft: return "Left Rear"
        case .rearRight: return "Right Rear"
        case .leftPair: return "Left"
        case .rightPair: return "Right"
        }
    }

    public var sortOrder: Int {
        switch self {
        case .soundbar: return 0
        case .leftPair: return 0
        case .rightPair: return 1
        case .sub: return 1
        case .rearLeft: return 2
        case .rearRight: return 3
        }
    }
}
