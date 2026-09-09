/// MCPScope.swift — Access levels for MCP tokens and tools.
///
/// A token carries one scope; a tool requires one. A call is refused
/// when the token's scope ranks below the tool's. Read-only tokens can
/// look but not touch; control tokens drive playback, volume, queue and
/// grouping; manage tokens can also change what is stored — playlists,
/// presets, the library index.
import Foundation

public enum MCPScope: String, Codable, CaseIterable, Sendable {
    case readOnly = "read"
    case control
    case manage

    private var rank: Int {
        switch self {
        case .readOnly: return 0
        case .control: return 1
        case .manage: return 2
        }
    }

    /// True when a token of this scope may call a tool needing `required`.
    public func covers(_ required: MCPScope) -> Bool { rank >= required.rank }

    public var title: String {
        switch self {
        case .readOnly: return "Read only"
        case .control: return "Control"
        case .manage: return "Manage"
        }
    }

    public var summary: String {
        switch self {
        case .readOnly: return "Rooms, now playing, queue, library, history: look only."
        case .control: return "Read, plus playback, volume, queue, grouping and presets."
        case .manage: return "Control, plus playlist, preset and library changes."
        }
    }
}
