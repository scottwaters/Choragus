# Sonos UPnP Protocol Reference

This document describes the UPnP/SOAP protocols used by SonosController to communicate with Sonos speakers. All communication is local network HTTP — no internet access required.

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

## Discovery (SSDP)

Speakers are found via SSDP multicast:

```
M-SEARCH * HTTP/1.1
HOST: 239.255.255.250:1900
MAN: "ssdp:discover"
MX: 3
ST: urn:schemas-upnp-org:device:ZonePlayer:1
```

Each speaker responds with a `LOCATION` header pointing to its device description XML (e.g., `http://192.168.1.x:1400/xml/device_description.xml`).

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
- Members with `Invisible="1"` are bonded speakers (subs, surrounds, stereo pair secondary) — hide from the UI
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

## Play Modes

| Value | Shuffle | Repeat |
|-------|---------|--------|
| `NORMAL` | Off | Off |
| `REPEAT_ALL` | Off | All |
| `REPEAT_ONE` | Off | One |
| `SHUFFLE_NOREPEAT` | On | Off |
| `SHUFFLE` | On | All |
| `SHUFFLE_REPEAT_ONE` | On | One |
