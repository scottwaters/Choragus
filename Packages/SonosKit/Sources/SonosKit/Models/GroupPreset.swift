/// GroupPreset.swift — Named speaker group configurations with per-speaker volumes and EQ.
import Foundation

// MARK: - EQ Settings

public struct SpeakerEQ: Codable, Equatable {
    public var bass: Int        // -10 to 10
    public var treble: Int      // -10 to 10
    public var loudness: Bool

    public init(bass: Int = 0, treble: Int = 0, loudness: Bool = true) {
        self.bass = bass
        self.treble = treble
        self.loudness = loudness
    }
}

public struct HomeTheaterEQ: Codable, Equatable {
    public var nightMode: Bool
    public var dialogLevel: Bool
    public var subEnabled: Bool
    public var subGain: Int             // -15 to 15
    public var subPolarity: Bool
    public var surroundEnabled: Bool
    public var surroundLevel: Int       // -15 to 15
    public var musicSurroundLevel: Int  // -15 to 15
    public var surroundMode: Int        // 0=Ambient, 1=Full

    public init(nightMode: Bool = false, dialogLevel: Bool = false,
                subEnabled: Bool = true, subGain: Int = 0, subPolarity: Bool = false,
                surroundEnabled: Bool = true, surroundLevel: Int = 0,
                musicSurroundLevel: Int = 0, surroundMode: Int = 1) {
        self.nightMode = nightMode
        self.dialogLevel = dialogLevel
        self.subEnabled = subEnabled
        self.subGain = subGain
        self.subPolarity = subPolarity
        self.surroundEnabled = surroundEnabled
        self.surroundLevel = surroundLevel
        self.musicSurroundLevel = musicSurroundLevel
        self.surroundMode = surroundMode
    }
}

// MARK: - Preset

public struct GroupPreset: Identifiable, Codable {
    public var id: UUID
    public var name: String
    public var coordinatorDeviceID: String
    public var members: [PresetMember]
    public var includesEQ: Bool
    public var homeTheaterEQ: HomeTheaterEQ?

    public init(id: UUID = UUID(), name: String, coordinatorDeviceID: String,
                members: [PresetMember], includesEQ: Bool = false,
                homeTheaterEQ: HomeTheaterEQ? = nil) {
        self.id = id
        self.name = name
        self.coordinatorDeviceID = coordinatorDeviceID
        self.members = members
        self.includesEQ = includesEQ
        self.homeTheaterEQ = homeTheaterEQ
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        coordinatorDeviceID = try container.decode(String.self, forKey: .coordinatorDeviceID)
        members = try container.decode([PresetMember].self, forKey: .members)
        includesEQ = try container.decodeIfPresent(Bool.self, forKey: .includesEQ) ?? false
        homeTheaterEQ = try container.decodeIfPresent(HomeTheaterEQ.self, forKey: .homeTheaterEQ)
    }
}

// MARK: - Preset Member

public struct PresetMember: Identifiable, Codable {
    public var id: String { deviceID }
    public var deviceID: String
    public var volume: Int
    public var eq: SpeakerEQ?

    public init(deviceID: String, volume: Int, eq: SpeakerEQ? = nil) {
        self.deviceID = deviceID
        self.volume = volume
        self.eq = eq
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceID = try container.decode(String.self, forKey: .deviceID)
        volume = try container.decode(Int.self, forKey: .volume)
        eq = try container.decodeIfPresent(SpeakerEQ.self, forKey: .eq)
    }
}
