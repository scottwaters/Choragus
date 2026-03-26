/// GroupPreset.swift — Named speaker group configurations with per-speaker volumes.
import Foundation

public struct GroupPreset: Identifiable, Codable {
    public var id: UUID
    public var name: String
    public var coordinatorDeviceID: String
    public var members: [PresetMember]

    public init(id: UUID = UUID(), name: String, coordinatorDeviceID: String, members: [PresetMember]) {
        self.id = id
        self.name = name
        self.coordinatorDeviceID = coordinatorDeviceID
        self.members = members
    }
}

public struct PresetMember: Identifiable, Codable {
    public var id: String { deviceID }
    public var deviceID: String
    public var volume: Int

    public init(deviceID: String, volume: Int) {
        self.deviceID = deviceID
        self.volume = volume
    }
}
