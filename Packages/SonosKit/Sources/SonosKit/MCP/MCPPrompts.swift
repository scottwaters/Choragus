/// MCPPrompts.swift — Playbooks an assistant can load: which tools to
/// call, in what order, and where to stop. Served through
/// `prompts/list` and `prompts/get`.
import Foundation

struct MCPPrompt {
    struct Argument {
        let name: String
        let description: String
        let required: Bool
        var descriptor: [String: Any] { ["name": name, "description": description, "required": required] }
    }

    let name: String
    let description: String
    let arguments: [Argument]
    let render: ([String: String]) -> String

    var descriptor: [String: Any] {
        ["name": name, "description": description, "arguments": arguments.map(\.descriptor)]
    }

    static let all: [MCPPrompt] = [
        MCPPrompt(name: "play_for_me",
                  description: "Find something and play it in a room, trying the library before streaming services.",
                  arguments: [.init(name: "request", description: "What to play, in plain words", required: true),
                              .init(name: "room", description: "Room name", required: true)]) { args in
            """
            Play "\(args["request"] ?? "")" in \(args["room"] ?? "the room").
            1. Call list_rooms once to confirm the room name.
            2. Call search on the Sonos library first (type tracks, albums or artists as the request implies). If nothing fits, call list_music_services and search_service on a signed-in service, then search_radio for stations.
            3. Play the best match with play_item (mode now). Prefer albums or artists when the request names one; prefer a single track when it names a song.
            4. Report what is playing from now_playing. If every search comes back empty, say so and stop; do not guess a different piece of music.
            """
        },
        MCPPrompt(name: "playlist_from_brief",
                  description: "Turn a description into a playlist, matched on the local library first with a streaming fallback, and optionally playing as it builds.",
                  arguments: [.init(name: "brief", description: "What the playlist should be", required: true),
                              .init(name: "room", description: "Room to play in; omit to only save", required: false),
                              .init(name: "service", description: "Match source; default library", required: false)]) { args in
            let room = args["room"] ?? ""
            let service = args["service"] ?? "library"
            return """
            Build a playlist for: \(args["brief"] ?? "").
            1. Write the song list yourself (title and artist per song, 15-30 songs unless the brief says otherwise), or call generate_song_list if the user prefers the app's configured AI.
            2. Call build_playlist with service "\(service)"\(room.isEmpty ? " and deliver \"none\"" : ", deliver \"play\" and room \"\(room)\""). Keep save true so the result is stored.
            3. Poll build_status with wait_seconds 20 until state is completed, failed or cancelled. Report progress briefly between polls.
            4. When songs are unmatched, list them and ask whether to retry them on another source (call list_music_services for the choices). If yes, call build_playlist again with only those songs, the chosen service, the same room and deliver settings, and playlist_id set to the playlist_id from step 3 so the new matches are appended to the same playlist rather than saved as a second one. (When the user names the fallback up front, pass fallback_service in step 2 instead and skip this.)
            5. Finish with the playlist name, matched and unmatched counts, and the playlist_id.
            """
        },
        MCPPrompt(name: "party_mode",
                  description: "Group every room behind one and set a house-wide level.",
                  arguments: [.init(name: "room", description: "Room whose music the house follows", required: true),
                              .init(name: "level", description: "Volume 0-100; omit to leave levels alone", required: false)]) { args in
            let level = args["level"] ?? ""
            return """
            Put the whole house on \(args["room"] ?? "the room").
            1. Call list_rooms and note the current grouping so it can be described back.
            2. Call group_all with room "\(args["room"] ?? "")".
            \(level.isEmpty ? "3. Leave volumes as they are." : "3. Call set_group_volume with level \(level) on that room.")
            4. Confirm with list_rooms and report which rooms joined, and keep the snapshot_id group_all returned. To undo later, call restore_grouping with that snapshot_id — it puts back the groups that existed before; ungroup_all would split those too.
            """
        },
    ]
}
