# Sonos UPnP Protocol Reference

This document describes the UPnP/SOAP protocols used by Choragus to communicate with Sonos speakers. All communication is local network HTTP (no internet access required).

## Overview

Sonos speakers run a UPnP stack on port 1400. Each speaker exposes several services, each with a control URL that accepts SOAP (XML-over-HTTP) requests.

Every SOAP request follows the same pattern:

```http
POST /MediaRenderer/AVTransport/Control HTTP/1.1
Host: 192.168.1.x:1400
Content-Type: text/xml; charset="utf-8"
SOAPAction: "urn:schemas-upnp-org:service:AVTransport:1#Play"

<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
  s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:Play xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <InstanceID>0</InstanceID>
      <Speed>1</Speed>
    </u:Play>
  </s:Body>
</s:Envelope>
```

## Discovery (SSDP + Bonjour)

Speakers are found by two parallel transports that feed the same post-discovery pipeline. See [DISCOVERY.md](DISCOVERY.md) for the full design.

### SSDP multicast

```
M-SEARCH * HTTP/1.1
HOST: 239.255.255.250:1900
MAN: "ssdp:discover"
MX: 3
ST: urn:schemas-upnp-org:device:ZonePlayer:1
```

Each speaker responds with a `LOCATION` header pointing to its device description XML (e.g., `http://192.168.1.x:1400/xml/device_description.xml`).

The reply is unauthenticated, so `LOCATION` is accepted only when its scheme is `http` and its host equals the address the datagram came from; a mismatch is dropped and logged (`[DISCOVERY] SSDP LOCATION host … != sender … — dropped`). Device descriptions are read up to 256 KB.

### Seed addresses

Where multicast is blocked outright, a plain unicast `GET /xml/device_description.xml` against a user-supplied address feeds the same pipeline (`SeedAddressDiscovery`). One address is enough: `GetZoneGroupState` on that speaker lists every other member.

### Bonjour / mDNS

Speakers also advertise the `_sonos._tcp` Bonjour service. `NWBrowser` enumerates them and resolves the TXT record, which carries the same `location` URL plus the household ID:

```
PTR _sonos._tcp.local
TXT location=http://192.168.1.x:1400/xml/device_description.xml
TXT householdid=Sonos_xxxxxxxxxxxx
```

Both transports merge by location URL, so seeing a speaker on both is harmless. Bonjour-supplied speakers skip the `GetHouseholdID` SOAP round-trip during topology discovery. The speaker's host is taken from the resolved connection endpoint, not from the TXT record.

## SOAP response bounds

A SOAP response over 2 MB is rejected (`SOAPError.parseError`); the largest legitimate payload, a 200-item queue browse page, stays under a quarter of that. HTTP error bodies are kept to a 300-character excerpt.

## Service Endpoints

| Service | Control URL | Namespace |
|---------|-----------|-----------|
| AVTransport | `/MediaRenderer/AVTransport/Control` | `AVTransport` |
| RenderingControl | `/MediaRenderer/RenderingControl/Control` | `RenderingControl` |
| ZoneGroupTopology | `/ZoneGroupTopology/Control` | `ZoneGroupTopology` |
| ContentDirectory | `/MediaServer/ContentDirectory/Control` | `ContentDirectory` |
| AlarmClock | `/AlarmClock/Control` | `AlarmClock` |
| MusicServices | `/MusicServices/Control` | `MusicServices` |

## AVTransport Actions

All actions use `InstanceID: 0` (Sonos always uses instance 0).

| Action | Arguments | Returns |
|--------|-----------|---------|
| `Play` | `Speed: "1"` | — |
| `Pause` | — | — |
| `Stop` | — | — |
| `Next` | — | — |
| `Previous` | — | — |
| `Seek` | `Unit: "REL_TIME"`, `Target: "H:MM:SS"` | — |
| `Seek` | `Unit: "TRACK_NR"`, `Target: "3"` | — |
| `GetTransportInfo` | — | `CurrentTransportState` (PLAYING, PAUSED_PLAYBACK, STOPPED, TRANSITIONING) |
| `GetPositionInfo` | — | `Track`, `TrackDuration`, `TrackMetaData` (DIDL-Lite), `TrackURI`, `RelTime` |
| `GetMediaInfo` | — | `CurrentURI`, `CurrentURIMetaData`, `NrTracks` |
| `GetTransportSettings` | — | `PlayMode` (NORMAL, REPEAT_ALL, SHUFFLE, etc.) |
| `SetPlayMode` | `NewPlayMode` | — |
| `ConfigureSleepTimer` | `NewSleepTimerDuration: "H:MM:SS"` or `""` to cancel | — |
| `GetRemainingSleepTimerDuration` | — | `RemainingSleepTimerDuration` |
| `SetAVTransportURI` | `CurrentURI`, `CurrentURIMetaData` | — |
| `BecomeCoordinatorOfStandaloneGroup` | — | — |
| `AddURIToQueue` | `EnqueuedURI`, `EnqueuedURIMetaData`, `DesiredFirstTrackNumberEnqueued`, `EnqueueAsNext` | `FirstTrackNumberEnqueued` |
| `RemoveTrackFromQueue` | `ObjectID: "Q:0/N"`, `UpdateID: "0"` | — |
| `RemoveAllTracksFromQueue` | — | — |
| `ReorderTracksInQueue` | `StartingIndex`, `NumberOfTracks`, `InsertBefore`, `UpdateID` | — |

## RenderingControl Actions

| Action | Arguments | Returns |
|--------|-----------|---------|
| `GetVolume` | `Channel: "Master"` | `CurrentVolume` (0–100) |
| `SetVolume` | `Channel: "Master"`, `DesiredVolume` | — |
| `GetMute` | `Channel: "Master"` | `CurrentMute` (0 or 1) |
| `SetMute` | `Channel: "Master"`, `DesiredMute` | — |
| `GetBass` | — | `CurrentBass` (-10 to 10) |
| `SetBass` | `DesiredBass` | — |
| `GetTreble` | — | `CurrentTreble` (-10 to 10) |
| `SetTreble` | `DesiredTreble` | — |
| `GetLoudness` | `Channel: "Master"` | `CurrentLoudness` (0 or 1) |
| `SetLoudness` | `Channel: "Master"`, `DesiredLoudness` | — |

## ContentDirectory Browse

The `Browse` action navigates the content hierarchy:

| ObjectID | Content |
|----------|---------|
| `0` | Root — lists top-level containers |
| `A:` | Music library root (Artists, Albums, Genres, etc.) |
| `A:ALBUMARTIST` | Artists |
| `A:ALBUM` | Albums |
| `A:GENRE` | Genres |
| `A:TRACKS` | All tracks |
| `A:COMPOSER` | Composers |
| `A:PLAYLISTS` | Imported playlists |
| `FV:2` | Sonos Favorites |
| `SQ:` | Sonos Playlists |
| `SQ:0`, `SQ:1`, ... | Individual Sonos playlists |
| `S:` | Music shares (network drives) |
| `R:0` | Radio (may be empty on modern firmware) |
| `Q:0` | Current play queue |

Browse results are returned as DIDL-Lite XML inside a SOAP `Result` element. The DIDL uses `<item>` for playable content and `<container>` for navigable folders.

### Music library shares are read-only over UPnP

`S:` can be browsed to list the folders a system indexes, and `DestroyObject` removes one, but a share cannot be added. `CreateObject` against the `S:` container answers HTTP 200 with a well-formed `ObjectID` and `Result` container, then persists nothing. The share is absent from `Browse("S:")` immediately afterwards. Verified on both S1 (firmware 57.x) and S2 (96.x), with a path that does not exist and with an existing guest-readable share, and with both DIDL shapes (`<item>` plus plain path, and `<container>` plus an `x-file-cifs://` `res`). Adding a share requires the Sonos app.

### `HTSatChanMapSet` is advertised per member, not per zone

Every bonded member carries the attribute, but a satellite advertises only the soundbar and itself; the complete set appears on the soundbar's own entry. A live 5.1 zone publishes four different values (the soundbar's full map plus one partial view per satellite). Reading the first non-empty value found therefore records whichever partial view was enumerated first. Merge across all members.

## Zone Group Topology

`GetZoneGroupState` returns XML describing all groups:

```xml
<ZoneGroups>
  <ZoneGroup Coordinator="RINCON_xxxx" ID="group1">
    <ZoneGroupMember UUID="RINCON_xxxx"
      Location="http://192.168.1.x:1400/xml/device_description.xml"
      ZoneName="Living Room"
      Invisible="0" />
    <ZoneGroupMember UUID="RINCON_yyyy"
      ZoneName="Living Room"
      Invisible="1" />  <!-- This is a sub or surround -->
  </ZoneGroup>
</ZoneGroups>
```

**Key rules:**
- Transport commands (play, pause, next) go to the **group coordinator**
- Volume commands go to **individual speakers**
- Members with `Invisible="1"` are bonded speakers (subs, surrounds, stereo pair secondary); hide them from the UI
- The `Coordinator` attribute tells you which UUID leads each group

## Grouping

To add a speaker to a group:
```
SetAVTransportURI(CurrentURI: "x-rincon:COORDINATOR_UUID")
```

To remove a speaker from a group (make it standalone):
```
BecomeCoordinatorOfStandaloneGroup()
```

## DIDL-Lite Metadata

Track metadata from `GetPositionInfo` and browse results uses DIDL-Lite XML:

```xml
<DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/"
  xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">
  <item>
    <dc:title>Song Title</dc:title>
    <dc:creator>Artist Name</dc:creator>
    <upnp:album>Album Name</upnp:album>
    <upnp:albumArtURI>/getaa?u=encoded_uri&amp;v=123</upnp:albumArtURI>
    <upnp:class>object.item.audioItem.musicTrack</upnp:class>
    <res duration="0:03:45">x-file-cifs://server/path/song.mp3</res>
  </item>
</DIDL-Lite>
```

**Album art URIs** that start with `/` are relative to the speaker's IP and port (e.g., `http://192.168.1.x:1400/getaa?...`).

**Favorites** include an `<r:resMD>` element containing escaped DIDL-Lite metadata needed for playback. This metadata must be preserved and sent back in `SetAVTransportURI` or `AddURIToQueue` calls.

## UPnP Events (GENA)

In event-first mode the app `SUBSCRIBE`s to AVTransport, RenderingControl and ZoneGroupTopology and receives `NOTIFY` callbacks on a TCP listener (default port 3401; ephemeral fallback if the port is held). The AVTransport `LastChange` body carries `TransportState`, `CurrentTrackMetaData`, `CurrentTrackURI`, `CurrentTrackDuration`, `NumberOfTracks` and `CurrentTrack` (the speaker's own 1-based queue position). `CurrentTrack` is read on the event path so the queue highlight follows the speaker's position rather than a title match; zero means "not reported", not row zero.

`NOTIFY` connections are accepted only from addresses in the discovered speaker set (refreshed on every topology change; an IPv4-mapped IPv6 peer is compared in its IPv4 form). Other peers are dropped without a response and counted, not logged per event. Sonos speakers accept unauthenticated SOAP from any LAN host, so this is input validation (it keeps a peer from feeding the app a false view of the household), not access control.

## UPnP/DLNA media servers

Sonos cannot browse UPnP media servers, but a speaker plays an ordinary HTTP URL, so a server on the network (Synology Media Server, MinimServer, Asset, Plex, Jellyfin) supplies both the browse tree and the audio.

**Discovery.** SSDP `M-SEARCH` with `ST: urn:schemas-upnp-org:device:MediaServer:1`, 4 s collect window. A responder is accepted only once its description document contains `urn:schemas-upnp-org:service:ContentDirectory:1`. Description URLs must be `http`/`https` and point at a private address; the fetch is capped at 256 KB.

**Control URL.** The `controlURL` is taken from inside the `ContentDirectory:1` `<service>` block. The first `controlURL` in the document usually belongs to `ConnectionManager` and faults on every `Browse`.

**Advertised vs answering host.** The base URL is built from the address that answered the search. If the description advertised a different host, that is recorded as `advertisedHostMismatch` rather than normalised away: the `res` URLs the server hands out live on the advertised host, and speakers are given those. A server answering from `192.168.50.200` while advertising `10.10.10.200` browsed without error and played nothing.

**Browse.** Standard `ContentDirectory` `Browse` (`BrowseDirectChildren`) from `ObjectID` `0`, paged. Items with video or image classes are filtered; roots are pruned by a first-page class verdict.

**Search.** `Search` against `ContainerID` `0` with

```
SearchCriteria: upnp:class derivedfrom "object.item.audioItem" and dc:title contains "<term>"
```

Backslashes and double quotes in the term are escaped. Search support is server-dependent; a fault or empty result reads as a miss, not an error.

**Playback.** The item's `res` URL is handed to the speaker with the direct-HTTP DIDL (the same strategy as Suno and TIDAL). The speaker fetches from the server itself, so the speaker, not the Mac, needs a route to it.

**Per-speaker reachability probe.** A VLAN the speaker cannot route to, a server bound to the wrong interface and a one-speaker firewall hole all present as transport STOPPED, status OK, no fault. The check makes each visible group member fetch a reference track through its own art proxy:

```
GET http://<speaker>:1400/getaa?u=<url-encoded res URL>
```

`/getaa` answers 200 only when the speaker retrieved the file and extracted embedded art, so with a reference track known to carry art: 200 → reached; 404 after ~5 s → the proxy's connect timeout, unreachable; fast 404 → unknown. No transport action is sent. A speaker that never answers is reported as offline, not as unable to reach the server. Bonded satellites are not probed individually.

## Plex direct playback reporting

"Plex – Local" hands the speaker a file URL from the Plex Media Server, so the server never sees a session. `PlexPlaybackReporter` reports the way a Plex client does, authenticated with `X-Plex-Token`:

```
GET <server>/:/timeline?ratingKey=<rk>&key=/library/metadata/<rk>
    &identifier=com.plexapp.plugins.library&state=<playing|paused|buffering|stopped>
    &time=<ms>&duration=<ms>&hasMDE=0&X-Plex-Device-Name=<room>
```

Sent when a Plex track becomes current, every 10 s while playing, and on each state change; stop keeps the session so Play resumes it. At track end, when at least 90 % of the duration was played (Plex's own threshold; a skip counts nothing):

```
GET <server>/:/scrobble?identifier=com.plexapp.plugins.library&key=<rk>
```

The play URL names a media part, not the track, so the browse layer registers `part path → ratingKey` when it builds a playable item; the mapping is persisted so a queue that outlives the app still reports. Listings page 500 at a time with `X-Plex-Container-Start` / `X-Plex-Container-Size`.

## Play Modes

| Value | Shuffle | Repeat |
|-------|---------|--------|
| `NORMAL` | Off | Off |
| `REPEAT_ALL` | Off | All |
| `REPEAT_ONE` | Off | One |
| `SHUFFLE_NOREPEAT` | On | Off |
| `SHUFFLE` | On | All |
| `SHUFFLE_REPEAT_ONE` | On | One |
