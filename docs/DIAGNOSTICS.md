# Diagnostics reference

What Choragus records, what the entries mean, and what is worth acting on.
The same summary appears in the app under Help → Diagnostics.

## Levels

| Level | Meaning |
|---|---|
| **info** | Normal activity worth keeping for context — discovery results, topology changes, playback starts. |
| **warning** | Choragus recovered, but something was not as expected. Usually a speaker or a music service behaving oddly. |
| **error** | An action did not complete. |

Neither a warning nor an error is a crash, and most warnings need nothing from
you. They exist so that a bug report contains evidence rather than a
description from memory.

## Categories

### Speaker and network — `TOPOLOGY`, `TRANSPORT`, `SOAP`
A speaker did not answer, answered too slowly, or reported a group whose
coordinator was missing. Choragus repairs these itself, substituting a
reachable coordinator and re-reading the topology. Frequent entries usually
mean Wi-Fi trouble for one speaker rather than a fault in the app; the
Diagnostics → Network tab shows which one.

### Playback and queue — `PLAYBACK`, `QUEUE`, `QUEUELIB`
A track would not start, a queue add was refused, or tracks advanced seconds
after starting. That last one usually means a service's track links have
expired. Choragus now repairs those itself where it can: `QUEUELIB`
"Re-resolved saved-queue play URLs" records how many expired links in a saved
queue were refreshed before it was restored, and the automatic queue health
pass (`QUEUE` "Automatic health pass", with `flagged` and `probed` counts)
runs after track changes to find rows that will not play. Rows it cannot
repair stay greyed in the queue with a badge explaining why; remove or re-add
those from the service. Sonos also caps its own queue, so very large additions
stop at the limit and record that here. "Batch add refused — add already in
flight" means a second add for the same room arrived while one was still
running; it is dropped rather than doubled.

### Media servers — `MEDIASERVER`
A UPnP/DLNA server was found, added, removed, or failed to answer. "Search
unsupported or failed" means the server does not implement ContentDirectory
Search; browsing still works. "Reachability check finished" lists the speakers
(`unreachable`) that could not fetch from the server, usually a VLAN or
firewall rule that lets your Mac reach the server but not the speaker. A
speaker that never answered the probe is reported as offline rather than as
unable to reach the server. Help → Media Servers covers the firewall rule.

### Music services — `SMAPI`, `CATALOG`, `SERVICES`, `MUSIC-SERVICES`, `PLEX`, `LASTFM`
A service refused a sign-in, a token expired, or a service reported itself
under a different identifier than before. Signing out and back in from
Settings → Music resolves most of these. Some services block third-party
sign-in entirely; that is noted in Settings and is not a fault.

`CATALOG` "Descriptors folded into a canonical service by host match" is
informational: it lists services whose identity was inferred from their host
name rather than their advertised name, so a wrongly merged service can be
spotted from the log.

`PLEX` "session start" / "session end" lines bracket each track reported to a
Plex Media Server from Plex – Local playback. On "session end", `progress=`
is how far the track got against its duration and `played=true` means at
least 90 % was heard and the play was counted on the server; `played=false`
is a skip and counts nothing. A "timeline … failed" or "scrobble … failed"
entry means the server did not accept the report; playback is unaffected.

### Stored data — `HISTORY`, `SAVEDQ`, `META-CACHE`, `SCROBBLE`, `XML`
Choragus could not read or write one of its own databases, or a reply from a
speaker was cut short and only partly readable. A partial reply is usually
momentary and the next refresh fixes it. Repeated database errors are worth a
bug report, since they can indicate a damaged file.

### AI Agent access — `MCP`
One line per request an assistant makes through the MCP server: the token
name, the tool or method, a summary of its arguments (never the whole
payload), the outcome (ok, tool error, denied by access level, rejected
origin or host, rate-limited, wrong token) and the time taken; plus the
listener's own state changes and each playlist build's start. The
Diagnostics → AI Agent access tab shows the same log with the server state,
tokens (names and access levels only), lockouts and running builds.

### Controls and grouping — `MEDIA-KEYS`, `GROUPING`, `VOLUME`, `PORTABLE_VOL`, `HT-EQ`, `ALARMS`
A media key arrived with no speaker selected, a grouping or volume change was
refused, or an EQ or alarm write did not take. Almost always a speaker that was
briefly unreachable; repeat the action. `GROUPING` "Room drop refused" /
"Ungroup drop refused" record a sidebar drag that could not be honoured (own
group, a group that left the topology, no coordinator, or two households).
`PORTABLE_VOL` records volume writes to portable speakers (Roam, Move), which
report late and sometimes reject a write; it is context for a volume bug
report, not a fault.

### Artwork — `ART`, `APPLE_MUSICKIT`
An artwork lookup failed or returned something unreadable. Choragus falls back
to the next source and playback is unaffected; at worst a track shows the wrong
cover or none.

## Debug log lines

Alongside the diagnostics store, the debug log carries bracketed tags for
timing investigations. These are for the maintainer and appear in a bug bundle:

- `[MGR-PUB] last 1s: total=N …` — per-second count of tagged state writes in
  `SonosManager`, broken down by source bucket. Sustained totals of 20+ per
  second with nothing playing point at a missing equality gate.
- `[RC-EVENT]`, `[RC-WRITE]`, `[RC-VERIFY]`, `[RC-PROP]`, `[RC-SOAP-WRITE]`,
  `[RC-SUB]` — volume and mute: what a speaker reported, what was applied or
  dropped as an echo of our own write, and the debounced verification that
  re-reads a group after a change (`SCHED` / `FIRE` / `APPLY` / `NO-OP` /
  `FAIL` / `CANCELLED`).
- `[QUEUE] Position N via <basis>` — which rule decided the highlighted queue
  row (speaker position, confirmed URI, or title match).
- `[DISCOVERY] SSDP LOCATION host … != sender … — dropped` — a discovery reply
  advertised an address other than the one it came from and was ignored.
- `[EVENTS] Port 3401 …` — the event callback port was held and an ephemeral
  port was used; firewall rules scoped to 3401 will not see this session's
  events. Event connections from addresses that are not discovered speakers
  are refused silently and counted, not logged per connection.
- `[PLEX]` — the session lines above, plus `trackChanged` when a Plex track
  becomes current.

## What leaves your machine

Nothing, unless you export a bug bundle. Authentication tokens (bearer values,
OAuth tokens, `token=` / `api_key=` query parameters) are removed before an
entry is written to the on-disk diagnostics store at all. When you export,
LAN addresses, speaker identifiers, home folder paths and service account
names are removed as well before the file is written. The bundle is encrypted
to the maintainer's key, so its contents are not readable by GitHub or by
anyone else it passes through. A bundle also carries an `mcp` section (the
Agent access state and request log described above); token secrets are never
part of it.
