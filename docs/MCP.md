# AI Agent access (MCP)

Choragus can act as a [Model Context Protocol](https://modelcontextprotocol.io) server, so an AI assistant on your Mac drives your Sonos system through Choragus: rooms, playback, volume, the queue, playlists, presets and line-in, plus a playlist builder that checks every song against a music service before it is saved.

Turn it on under **Settings → AI → AI Agent access (MCP)**. The section shows the endpoint, the access tokens, and the options below. Add one token per assistant (name it after the client); each can be copied or revoked on its own, and the list shows when it was last used.

> New to this? [docs/AI.md](AI.md) is the plain-language guide to Choragus's four levels of AI, of which this server is the third and fourth. This page is the reference: every tool, every client's configuration, and the security details.

## What it is

A local server inside Choragus, on your Mac, that an AI assistant talks to. Nothing goes through a cloud on Choragus's side: the assistant you already use (Claude, ChatGPT through Codex, Cursor and others) calls tools on `127.0.0.1`, and Choragus does the work against your speakers over your own network. That gives the assistant your **local music library** (the Sonos library on your NAS or shares, and DLNA media servers such as Plex or a Synology) as well as the **cloud services** signed in to Sonos — Apple Music, Spotify, TIDAL, Amazon Music, TuneIn and the rest — with the local library first whenever a request says so.

## Everyday examples

Once connected, ask in plain words. Some requests that work as they are:

- "What's playing in the kitchen?" — `now_playing`.
- "Turn the office down to 20 and skip this track." — `set_volume`, `next`.
- "Play Kind of Blue in the living room, from my library if you have it." — `search` (library), then `play_item`; falls back to `search_service` on Apple Music or Spotify.
- "Put the whole house on the kitchen, and put it back the way it was at ten." — `group_all` (returns a `snapshot_id`), later `restore_grouping`.
- "Make me a 90s indie playlist from my own music and start it on the deck." — `build_playlist` with `service: library`, `deliver: play`, `room: Deck`; the queue fills as songs match; misses are listed so you can say "try the missing ones on Spotify".
- "Add the Beatles song to the front of the queue and remove the duplicate." — `get_queue`, `move_in_queue`, `dedupe_queue`.
- "Save what's in the queue as a playlist called Sunday." — `save_queue_as_playlist`.
- "What have I listened to most this month?" — `most_played` with `days: 30`.
- "Wake me at 6:30 on weekdays in the bedroom with the chime at volume 15." — `create_alarm`.
- "Switch the bedroom to night mode." — `set_speaker_eq`.

What the assistant asks you before doing: clearing a queue, deleting a playlist, preset or alarm, splitting every group, or re-indexing the library — unless that token has **Skip confirmations** on in Settings. Playing something replaces the room's queue; the app's queue history can bring it back.

## Connecting a client

The server speaks MCP over HTTP (Streamable HTTP transport) at `http://127.0.0.1:52080/mcp` by default. Every request must carry the token as a bearer credential.

**Claude Code**

```bash
claude mcp add --transport http choragus http://127.0.0.1:52080/mcp \
  --header "Authorization: Bearer <token>"
```

**Claude Desktop and other clients that launch a command** use the `mcp-remote` bridge:

```json
{
  "mcpServers": {
    "choragus": {
      "command": "npx",
      "args": ["mcp-remote", "http://127.0.0.1:52080/mcp",
               "--header", "Authorization: Bearer <token>"]
    }
  }
}
```

Choragus has to be running. **Open Choragus at login** and **Prevent the Mac from sleeping** (both in the same section) keep it available; the window can stay closed when Menu Bar Controls are on.

### OpenAI

OpenAI's tools reach Choragus in three ways; all take the endpoint and a token from Settings. Create a separate token for each.

**Codex CLI** — add to `~/.codex/config.toml` (Codex launches a command, so the `mcp-remote` bridge carries the token):

```toml
[mcp_servers.choragus]
command = "npx"
args = ["mcp-remote", "http://127.0.0.1:52080/mcp",
        "--header", "Authorization: Bearer <token>"]
```

**Agents SDK (Python)** — runs on this Mac, so the loopback endpoint works as is:

```python
from agents import Agent, Runner
from agents.mcp import MCPServerStreamableHttp

async with MCPServerStreamableHttp(
    name="Choragus",
    params={"url": "http://127.0.0.1:52080/mcp",
            "headers": {"Authorization": "Bearer <token>"}},
) as choragus:
    agent = Agent(name="DJ", instructions="Control the Sonos system through Choragus.",
                  mcp_servers=[choragus])
    result = await Runner.run(agent, "Play something mellow in the kitchen at 25%.")
    print(result.final_output)
```

**Responses API with the hosted `mcp` tool** — OpenAI's servers call the endpoint, so it must be reachable from the internet over HTTPS. Turn on **Allow other devices on the network**, put an HTTPS tunnel in front of the port (Cloudflare Tunnel, ngrok, Tailscale Funnel), and pass the token in `headers`:

```json
{
  "model": "gpt-5",
  "tools": [{
    "type": "mcp",
    "server_label": "choragus",
    "server_url": "https://<your-tunnel-host>/mcp",
    "headers": {"Authorization": "Bearer <token>"},
    "require_approval": "never"
  }],
  "input": "What is playing in the office?"
}
```

The ChatGPT app's own connector list accepts only public HTTPS servers with OAuth or no authentication, so it cannot use a Choragus token; use the Agents SDK or the Responses API instead.

### Other clients

Any MCP client that supports the Streamable HTTP transport with custom headers connects directly:

**Cursor** — `.cursor/mcp.json`:

```json
{ "mcpServers": { "choragus": {
    "url": "http://127.0.0.1:52080/mcp",
    "headers": { "Authorization": "Bearer <token>" } } } }
```

**VS Code** — `.vscode/mcp.json`:

```json
{ "servers": { "choragus": {
    "type": "http",
    "url": "http://127.0.0.1:52080/mcp",
    "headers": { "Authorization": "Bearer <token>" } } } }
```

**Python (official `mcp` package)**:

```python
from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client

async with streamablehttp_client("http://127.0.0.1:52080/mcp",
                                 headers={"Authorization": "Bearer <token>"}) as (read, write, _):
    async with ClientSession(read, write) as session:
        await session.initialize()
        print(await session.call_tool("list_rooms", {}))
```

Clients that only launch a command (stdio) use `npx mcp-remote <endpoint> --header "Authorization: Bearer <token>"` as the command, as in the Claude Desktop example above.

### Raw protocol

For anything else, the endpoint is plain JSON-RPC 2.0 over HTTP:

- `POST /mcp` with `Content-Type: application/json` and `Authorization: Bearer <token>`; one JSON-RPC request or a batch per call; the reply is JSON (no server-sent events).
- Notifications (no `id`) get `202 Accepted` and no body. `GET /mcp` is not offered (405); `DELETE /mcp` returns 200.
- Methods: `initialize`, `ping`, `tools/list`, `tools/call`, `resources/list`, `resources/read`. Tool results carry the JSON both as `structuredContent` and as text.

```bash
TOKEN=<token>
curl -s http://127.0.0.1:52080/mcp -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"1"}}}'

curl -s http://127.0.0.1:52080/mcp -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"set_volume","arguments":{"room":"Kitchen","level":20}}}'
```

Errors follow JSON-RPC: `-32700` parse error, `-32600` invalid request, `-32601` unknown method, `-32602` bad arguments, `-32603` internal. A tool that fails returns a normal result with `isError: true` and the reason as text. Missing or wrong token: HTTP 401.

## Tools

Every tool needs a token whose access level covers it: **read only** tools look, **control** tools drive playback and the queue, **manage** tools change stored data (playlists, presets, the library index). Tools with a `confirm` flag are marked destructive so clients can ask before calling them.

### Rooms and playback

| Tool | What it does | Level |
|------|--------------|-------|
| `list_rooms` | Rooms and groups with state and volume | read |
| `list_devices` | Every speaker: id, room, model, IP, system generation | read |
| `now_playing` | Title, artist, album, position for a room | read |
| `play`, `pause`, `stop`, `next`, `previous` | Transport for a room | control |
| `seek` | Absolute `seconds` or relative `delta_seconds`, clamped to the track length | control |
| `pause_all`, `resume_all` | Every room at once | control |
| `set_volume`, `adjust_volume`, `set_mute` | Every speaker in the room; `adjust_volume` takes a delta | control |
| `set_group_volume` | Moves a group's level keeping each speaker's relative loudness | control |
| `set_speaker_volume` | One speaker by id | control |
| `get_play_mode`, `set_shuffle`, `set_repeat`, `set_crossfade` | Play mode | read / control |
| `set_sleep_timer`, `cancel_sleep_timer` | Sleep timer in minutes | control |
| `get_speaker_eq`, `set_speaker_eq` | Bass, treble and loudness (absolute, relative `bass_delta` / `treble_delta`, or `reset`), and on a soundbar night mode, speech enhancement, sub enabled / gain / polarity, surrounds enabled / TV level / music level / ambient or full. Address by `room` or `device_id` | read / control |
| `group_rooms`, `ungroup_room` | Grouping; `group_rooms` takes one `room` or several `rooms`, and playback in `with` wins | control |
| `group_all`, `snapshot_grouping`, `restore_grouping` | Party mode: `group_all` saves the grouping first and returns a `snapshot_id`; `restore_grouping` puts the old groups back | control / read / control |
| `ungroup_all` | Split every group, including ones that existed before (`confirm`) | control |
| `list_presets`, `get_preset`, `activate_preset` | Saved group presets, and one preset's full configuration — member rooms, volumes, EQ, home-theatre EQ; applying caps members at the agent volume limit | read / control |
| `save_preset`, `delete_preset` | Save the current setup, delete one (`confirm`) | manage |
| `list_inputs`, `select_input` | Line-in and TV inputs; stereo pairs list both units with `primary` marked | read / control |
| `rescan` | Look for speakers again | control |
| `speaker_network_status` | Per speaker: Wi-Fi band and channel, noise floor, PHY errors, round-trip time, firmware | read |
| `get_diagnostics` | Recent entries from the app's diagnostics log, filtered by level and category | read |
| `scrobble_status`, `scrobble_now` | Last.fm scrobbling state and pending count; send what is waiting | read / control |
| `open_window` | Open Back of the Club (`club_vis`) or Karaoke for a room, or Playlist Manager, Listening Stats, Alarms, Diagnostics, Home Theater EQ, Playlist Builder, Help | control |

Every volume tool honours the **Volume limit for agents** in Settings; a higher request is lowered to the limit and the reply carries `max_level`.

### Music

| Tool | What it does | Level |
|------|--------------|-------|
| `search` | The Sonos music library; `type` picks tracks, artists, album_artists, albums, genres, composers or playlists | read |
| `browse_library` | The library tree: sections at the top, then any container by id | read |
| `library_shares`, `reindex_library` | The indexed folders; ask for a re-scan (`confirm`) | read / manage |
| `list_media_servers`, `browse_media_server`, `search_media_server` | DLNA/UPnP servers (Plex, MinimServer, NAS). A server renamed in Settings lists its `advertised_name` too, and either name works in the other tools | read |
| `check_media_server` | Ask every speaker whether it can reach a server, and name those that cannot | control |
| `play_suno_link` | Play a suno.com song or share link in a room | control |
| `get_lyrics`, `get_artist_info`, `get_album_info` | Lyrics for a room's current track or a named one; artist biography, tags and similar artists; album release, summary and track list | read |
| `search_radio` | Internet radio stations (TuneIn) | read |
| `list_favorites` | Sonos favorites | read |
| `list_music_services`, `search_service` | Signed-in streaming services and Apple Music; search by songs, albums or artists, in each service's own search categories (Amazon Music, for one, answers only its own) | read |
| `play_item` | Play one result now, next, or add it to the end | control |

Results carry an `id`; `play_item`, `add_to_queue`, `create_playlist` and `add_to_playlist` accept them. Containers (albums, artists, genres, folders) add all their tracks. The id cache holds the last 500 results.

### Queue

| Tool | What it does | Level |
|------|--------------|-------|
| `get_queue` | The room's queue in order, paged with `start` and `limit`; `total` is the whole queue | read |
| `add_to_queue` | Several results at once, next or at the end | control |
| `play_queue_position`, `move_in_queue`, `remove_from_queue`, `dedupe_queue` | Edit in place. `get_queue` returns the speaker's `revision`; pass it back as `expected_revision` and the edit is refused if the queue changed in any way since (reorders included). `expected_total` guards the length only. Positions in one `remove_from_queue` call all refer to the queue as it was before the call; results carry `remaining` and the new `revision` | control |
| `clear_queue` | Empty it (`confirm`) | control |
| `save_queue_as_playlist` | Store the queue as a Choragus playlist; names are unique, `replace: true` overwrites | manage |
| `save_queue_as_sonos_playlist` | Store it on the Sonos system instead, where every controller sees it | manage |
| `list_queue_snapshots`, `restore_queue_snapshot` | The undo history: queues Choragus saved before replacing them | read / control |

### Choragus playlists

| Tool | What it does | Level |
|------|--------------|-------|
| `list_playlists`, `get_playlist_tracks`, `list_folders` | Read; `get_playlist_tracks` pages with `start` and `limit` | read |
| `play_playlist` | Play or append in a room | control |
| `create_playlist`, `add_to_playlist`, `remove_from_playlist`, `rename_playlist`, `duplicate_playlist`, `move_playlist`, `create_folder` | Edit; `remove_from_playlist` takes `expected_total` | manage |
| `delete_playlist` | Move to Deleted Items (`confirm`) | manage |
| `rename_folder`, `move_folder`, `delete_folder` | Folder upkeep; deleting a folder leaves its playlists at the top level (`confirm`) | manage |
| `list_deleted_playlists`, `restore_playlist`, `purge_playlist` | Deleted Items: what is in it, restore one, remove one or empty it for good (`confirm`) | read / manage |
| `export_playlist` | The playlist as M3U or CSV text | read |
| `list_sonos_playlists`, `play_sonos_playlist`, `add_to_sonos_playlist`, `rename_sonos_playlist`, `delete_sonos_playlist`, `clone_sonos_playlist` | Playlists stored on the Sonos system itself: read, play, edit, and copy one into Choragus. `delete_sonos_playlist` needs `confirm` — Sonos has no undo for it | read / control / manage |

Every playlist tool takes `playlist_id` or `playlist` (the name, case-insensitive, or the id as text). Playlist names are unique for agents: `create_playlist`, `save_queue_as_playlist` and `build_playlist` fail on an existing name unless `replace: true`, which overwrites that playlist's tracks in place; `rename_playlist` and `duplicate_playlist` refuse a name already in use.

### History

| Tool | What it does | Level |
|------|--------------|-------|
| `recently_played`, `most_played`, `starred_tracks` | From the play history; `most_played` ranks tracks, artists, albums or stations over N days | read |
| `listening_stats` | Hours, plays per day, by hour of day, by source, by room, current streak | read |
| `star_track`, `unstar_track` | Star or unstar a track in the history | manage |
| `export_history` | The whole play history as CSV text | read |
| `delete_history_entries` | Remove history rows by id, or by title / artist / station (`confirm`) | manage |
| `clear_history` | Erase the play history, stars and play counts (`confirm`) | manage |
| `play_smart_queue` | Most played, recently played or starred as a queue | control |

### Alarms

| Tool | What it does | Level |
|------|--------------|-------|
| `list_alarms` | Every alarm with room, time, recurrence, enabled, volume | read |
| `create_alarm` | A new alarm in a room: time, recurrence, volume, duration, chime or a result id | manage |
| `set_alarm` | Enable or disable, move the time, volume or recurrence | manage |
| `delete_alarm` | Remove one (`confirm`) | manage |

### Playlist builder

| Tool | What it does | Level |
|------|--------------|-------|
| `list_ai_profiles` | The AI services configured in Settings | read |
| `generate_song_list` | A song list from a brief, using the selected AI service | control |
| `build_playlist` | Starts a background job that matches a song list on a source and returns a `job_id` | control (manage when `save` is true) |
| `build_status` | Progress: `status` is `working`, `completed`, `failed` or `cancelled`; matched and unmatched songs so far; `wait_seconds` blocks up to 25 s | read |
| `cancel_build` | Stop a job; queued tracks stay unless `undo: true` | control |
| `undo_build` | Remove the tracks a job queued (only when the queue length still matches what the job left) and delete the playlist it created; appended-to or replaced playlists are left alone | manage |

`build_playlist` arguments: `service` is `library` (default), `apple_music`, a signed-in service name from `list_music_services`, or a media server name; `fallback_service` re-tries the misses on a second source; `deliver` is `none`, `queue` (each match is appended to the room's queue as it lands) or `play` (the first match plays, the rest queue) — `room` is required for either; `save` (default true) stores the matched tracks as a Choragus playlist when matching ends, failing at once on a name already in use unless `replace: true`; `playlist` / `playlist_id` appends the matches to an existing playlist instead, which is how a retry of unmatched songs on another source lands in the same playlist. Matches keep the song order; misses are dropped. A track the speaker refuses to queue counts in `queue_errors` and the job continues; on cancel, queued tracks stay. Matching paces itself at two seconds per song on hosted services, so a 30-song list takes about a minute; at most two builds run at once. The saved playlist keeps the input order even when a fallback pass finds a song later; the queue, filled as matches land, is arrival order. Each match reports its `album`, so a live or compilation recording is visible. `build_status` lists `queued_positions`. The status vocabulary follows the MCP Tasks extension so a client can treat the job like a task.

A room is addressed by its name as shown in Sonos (any member of a group works) or by the id `list_rooms` returns. A speaker is addressed by room name or `device_id`; naming the right-hand half of a stereo pair, a Sub or a surround resolves to the set's primary (the left unit or the soundbar), because Sonos applies EQ, alarms and inputs through it — the reply names the room the change landed on. Other structural rules are handled the same way rather than returned as errors: transport, queue and play-mode calls go to the group's coordinator, alarm reads and writes go to the speaker that owns the household's alarm list, and a room named anywhere addresses its whole group. Where the hardware genuinely cannot comply the reply says which room and why — a speaker with a fixed line-out is listed under `fixed_output` instead of a volume change being reported, and grouping rooms that sit on two different Sonos systems is refused by name.

Resources: `choragus://rooms`, `choragus://now-playing` and `choragus://playlists` return the same data as the matching tools.

Prompts: `play_for_me`, `playlist_from_brief` and `party_mode` are step-by-step playbooks a client can load; each names the tools to call, in order, and where to stop.

Retries: every tool accepts `request_id`. A mutating call repeated with the same `request_id` from the same token returns the first result instead of acting again, so a client that lost a reply can retry safely. The policy for `confirm` is narrow on purpose: it gates only removals that nothing can put back (queue removals, deletes, `ungroup_all`, `reindex_library`). Playing something replaces the room's queue, which the app's queue history can restore, so `play_item`, `play_playlist` and presets do not take `confirm`; the descriptions say so, and a client that wants approval for those can key off `destructiveHint` being false and the description.

Annotations: every tool carries `readOnlyHint`; `destructiveHint` marks tools that remove or overwrite something the tool cannot restore (queue removals, playlist track removals, deletes, `ungroup_all`, `reindex_library`). Replacing the queue to play something is not marked destructive because the app keeps a queue history. The main read tools (`list_rooms`, `now_playing`, `get_queue`, `group_all`) declare an `outputSchema`; results are also returned as `structuredContent`.

## Songs from a chat model

A chat model writes song titles, not playable tracks. `build_playlist` takes the list the model wrote and resolves each song on the service you name, the same matching the in-app Build Playlist window uses; only matched tracks are saved or queued, and the reply lists the misses so the model can try again. No provider API key is involved: the assistant supplies the model, Choragus supplies the Sonos side.

## Network and security

- Off by default. The listener binds to the address `127.0.0.1` (not a wildcard socket on the loopback interface) unless **Allow other devices on the network** is on; then it binds every interface and advertises `_mcp._tcp` over Bonjour, so a Mac with **Wake for network access** enabled wakes for the first request.
- Tokens are generated on this Mac, stored in the keychain, compared in constant time, and never logged. Each token has an access level (read only, control, manage) chosen when it is created and changeable in Settings; a call beyond the level is refused with the reason in the tool result. A per-token **Skip confirmations** switch lets a trusted assistant call the `confirm` tools without the flag. **Revoke** cuts one assistant off at once without touching the others.
- Requests carrying an `Origin` header (a web page) or a `Host` header naming anything other than this machine are refused with 403, so a page in a browser cannot reach the server and a DNS-rebinding page cannot reach a LAN listener. On the LAN, private addresses, `.local` names and bare machine names pass; public DNS names never do.
- Five wrong tokens from one address inside a minute lock that address out for five minutes (429 with `Retry-After`); a token is limited to 60 requests per 10 seconds.
- A **Volume limit for agents** (default 80) caps every volume tool, including alarm volumes and preset members; **Quiet hours** apply a lower limit (default 25) between two hours of the day on this Mac's clock.
- Text from speakers, services and files (titles, artists, albums, stations, room names) is capped at 200 characters and returned as JSON values, never folded into descriptions or error text.
- Authentication runs before the body is parsed; error text never carries file paths or internal ids beyond the ids the tools hand out.
- **Recent activity** in Settings lists every request by token, action, arguments summary, outcome and duration, with per-token call counts and any active lockouts; the same lines go to the diagnostics log. Diagnostics → AI Agent access shows the server state, tokens (names and scopes only), lockouts, running builds and the request log, and the encrypted bug-report bundle carries the same under `mcp`. Arguments are summarised, never stored whole; token secrets never leave the keychain.
- No API key, password or service token passes through the server; tool results carry titles, names and ids only.
- Requests are capped at 1 MB; one request per connection.
- Turning the server off closes the port immediately.
