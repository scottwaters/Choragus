# Music Services

Single source of truth for which Sonos music services Choragus can drive directly, which are confirmed blocked, and which haven't been tested yet. Compiled from live probes against `ListAvailableServices` + `getAppLink` and from real-world usage.

For the end-user view see the **Music Services** section in [README.md](../README.md). For SMAPI internals see [docs/PROTOCOLS.md](PROTOCOLS.md).

## Status legend

| Dot | Meaning |
|-----|---------|
| 🟢 Green | Connected and working in this app right now |
| 🔵 Blue | Confirmed working in this app — connect via **Settings → Music** |
| 🟡 Yellow | Service exists in the Sonos catalogue but you haven't added the required Sonos Favorite yet (some services need it to expose the account serial number) |
| 🔴 Red | Blocked — Sonos-identity-gated; third-party clients receive `403 / NOT_AUTHORIZED` |
| ⚫ Grey | Service exists in the Sonos catalogue but isn't linked to your household — set it up in the official Sonos app first |

## No connection required

These work out of the box on any Sonos household. No login, no AppLink flow.

| Service | Source | Notes |
|---------|--------|-------|
| **Local Music Library** | UPnP `ContentDirectory` | NAS / network shares indexed by Sonos |
| **Sonos Favorites** | UPnP `FV:2` | Anything you've saved as a Favorite in the Sonos app |
| **Sonos Playlists** | UPnP `SQ:` | Playlists saved from queues |
| **TuneIn** | Public RadioTime API | No login needed |
| **Calm Radio** | Public API | No login needed |
| **Sonos Radio** *(search only)* | Anonymous SMAPI | Category browsing requires DeviceLink (not yet supported) |
| **Apple Music** *(search only)* | iTunes Search API | Search via iTunes; playback through Sonos Favorites |
| **Line-In** | UPnP per-device | Any speaker with a physical line-in input |

## Connection required — confirmed working

These work in Choragus after a one-time AppLink connect. SMAPI sids verified by live probe against `ListAvailableServices`.

| Service | SID | Auth flow | Notes |
|---------|:---:|-----------|-------|
| **Spotify** | 12 | AppLink (browser) | Connect in Settings, then add one favorited song via the Sonos app to expose the account serial number |
| **Plex** *(v3.7)* | varies | AppLink (PIN) at [app.plex.tv/auth](https://app.plex.tv/auth) | Streams from your own Plex Media Server — no third-party CDN, no short-lived signatures. `linkDeviceId` is per-install and echoed back in `getDeviceAuthToken`. Self-hosted, no `sn=` favorite required |
| **Audible** *(v4.0)* | varies | AppLink (browser) | Audiobook playback works; chapter navigation surfaces as a Sonos queue |

## Connection required — untested

40+ additional services are reachable via SMAPI AppLink/DeviceLink and may work without modifications. Connect via **Settings → Music → Other Services** and please [open an issue](https://github.com/scottwaters/Choragus/issues) with the result.

| Service | SID (SMAPI) | Notes |
|---------|:---:|-------|
| **Pandora** *(v4.0)* | 3 | US-only as of 2026. SMAPI sid 3 (distinct from the RINCON service descriptor 519, which is what RINCON-based lookups historically used). Visible in Settings as untested |
| Various others | — | Tidal, Deezer, iHeartRadio, Bandcamp, etc. — discovered dynamically from `ListAvailableServices` |

## Blocked — Sonos-identity-gated

Confirmed by live probe against `ListAvailableServices` + `getAppLink` (most recent verification 2026-04-24). These services ship encrypted API keys in their Sonos manifest at `cf.ws.sonos.com/p/m/<uuid>` that only Sonos's own app and speaker firmware can decrypt. Third-party clients receive `403 / NOT_AUTHORIZED` from the SMAPI endpoint before authentication can begin.

| Service | SID | Response | Workaround |
|---------|:---:|----------|------------|
| **Apple Music** (as SMAPI service) | 204 | `SonosError 999` | iTunes Search API fallback already used for search; playback via Sonos Favorites |
| **Amazon Music** | 201 | Same Sonos-identity gate | — |
| **YouTube Music** | 284 | GCP `403 PERMISSION_DENIED` (no API key) | — |
| **SoundCloud** | 160 | `Client.NOT_AUTHORIZED` (403) | Scrobbling of SoundCloud listens via the Sonos app still works |
| **Sonos Radio** *(category browsing)* | 303 | DeviceLink-only | Search works |

**Scrobbling remains possible for all services above** — play history is recorded from whatever the Sonos app plays, regardless of whether Choragus can directly browse/search that service. See [Last.fm scrobbling](../README.md#what-s-new-in-v36).

## Where the SIDs live

`Packages/SonosKit/Sources/SonosKit/SonosConstants.swift` — `enum ServiceID` is the authoritative list:

```swift
enum ServiceID {
    static let appleMusic   = 204
    static let spotify      = 12
    static let pandora      = 3       // SMAPI sid (not RINCON 519)
    static let tunein       = 254
    static let soundcloud   = 160
    static let sonosRadio   = 303
    static let calmRadio    = 144
    static let youtubeMusic = 284
    static let amazonMusic  = 201
    // …
}
```

These are the same numeric IDs used for scrobbling-filter matching, so any new service added here is immediately filterable by the user in **Settings → Scrobbling**.

## Adding a new service

1. Probe the household with `ListAvailableServices` to discover its sid.
2. If `getAppLink` returns HTTP 200 with a usable `regUrl`, it's likely tested-blue eligible. Add to `MusicServicesView.testedAppLinkServices` and to `SonosConstants.ServiceID`.
3. If `getAppLink` returns `403 / NOT_AUTHORIZED`, the service is Sonos-identity-gated. Add to the blocked list and document the response.
4. If the service requires a Sonos Favorite to expose the account serial number, add the sid to `servicesNeedingSN` (or the inverse, `servicesNotNeedingSN`, for self-hosted services like Plex).
5. Update this document.
