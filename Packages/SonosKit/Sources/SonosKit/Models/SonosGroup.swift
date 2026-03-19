import Foundation

public struct SonosGroup: Identifiable, Hashable {
    public let id: String // group ID
    public let coordinatorID: String // UUID of the coordinator device
    public var members: [SonosDevice]

    public init(id: String, coordinatorID: String, members: [SonosDevice]) {
        self.id = id
        self.coordinatorID = coordinatorID
        self.members = members
    }

    public var coordinator: SonosDevice? {
        members.first { $0.id == coordinatorID }
    }

    public var name: String {
        if members.count == 1 {
            return members.first?.roomName ?? "Unknown"
        }
        let names = members.map(\.roomName).sorted()
        return names.joined(separator: " + ")
    }
}
