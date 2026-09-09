/// MCPGroupingSnapshot.swift — A saved grouping layout, so an agent's
/// group_all can be undone to what the house had before.
import Foundation

struct MCPGroupingSnapshot {
    struct Group {
        let coordinatorID: String
        let memberIDs: [String]
        let rooms: [String]
    }

    let id = UUID().uuidString
    let takenAt = Date()
    let groups: [Group]

    var descriptor: [String: Any] {
        ["snapshot_id": id,
         "taken_at": ISO8601DateFormatter().string(from: takenAt),
         "groups": groups.map { ["coordinator_room": $0.rooms.first ?? "", "rooms": $0.rooms] }]
    }
}
