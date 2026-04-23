import Foundation

public struct SonosGroup: Identifiable, Hashable {
    public let id: String // group ID
    public let coordinatorID: String // UUID of the coordinator device
    public var members: [SonosDevice]
    public var householdID: String? // System identity — distinguishes S1 vs S2 households on the same LAN

    public init(id: String, coordinatorID: String, members: [SonosDevice], householdID: String? = nil) {
        self.id = id
        self.coordinatorID = coordinatorID
        self.members = members
        self.householdID = householdID
    }

    /// System version derived from the coordinator (or first member with a known version).
    public var systemVersion: SonosSystemVersion {
        if let coordinator = coordinator, coordinator.systemVersion != .unknown {
            return coordinator.systemVersion
        }
        for member in members where member.systemVersion != .unknown {
            return member.systemVersion
        }
        return .unknown
    }

    public var coordinator: SonosDevice? {
        members.first { $0.id == coordinatorID }
    }

    public var name: String {
        if members.count == 1 {
            return members.first?.roomName ?? "Unknown"
        }
        let coordName = coordinator?.roomName ?? ""
        let others = members
            .filter { $0.id != coordinatorID }
            .map(\.roomName)
            .sorted()
        return ([coordName] + others).joined(separator: " + ")
    }
}
