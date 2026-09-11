# Music Services

Single source of truth for which Sonos music services Choragus can drive directly, which are confirmed blocked, and which haven't been tested yet. Compiled from live probes against `ListAvailableServices` + `getAppLink` and from real-world usage.

For the end-user view see [README.md](../README.md) and [docs/FEATURES.md](FEATURES.md). For SMAPI internals see [docs/PROTOCOLS.md](PROTOCOLS.md).

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
| **Local Music Library** | UPnP `ContentDirectory` | NAS / network shares indexed by Sonos. A share is per-system: the same folder on an S1 and an S2 system is two shares, tagged (S1) / (S2) / (S1/S2) |
| **Sonos Favorites** | UPnP `FV:2` | Anything you've saved as a Favorite in the Sonos app |
| **Sonos Playlists** | UPnP `SQ:` | Playlists saved from queues |
| **Media Servers** *(v5.0)* | UPnP/DLNA `ContentDirectory` on the server | Synology Media Server, MinimServer, Asset, Plex, Jellyfin and any other DLNA server. Discovered by SSDP or added by address in Settings → Music. The server supplies the browse tree and the audio URL; the speaker fetches directly, so each speaker needs a route to the server (per-speaker reachability check in Settings). See [PROTOCOLS.md](PROTOCOLS.md#upnpdlna-media-servers) |
| **TuneIn** (Choragus Sources) | Public RadioTime API (`opml.radiotime.com`) | No login needed. Stations resolve through `Tune.ashx` to a direct stream when the household no longer lists the legacy TuneIn service, and fall back to it when the `x-sonosapi-stream:` form is rejected. Topics / podcasts (t/p/g guide IDs) always resolve this way. Sonos's newer TuneIn surfaces separately as a standard SMAPI row |
| **Calm Radio** | Public API | No login needed |
| **Sonos Radio** *(search only)* | Anonymous SMAPI | Category browsing requires DeviceLink, which Choragus does not implement |
| **Apple Music** *(search only)* | iTunes Search API | Search via iTunes; playback through Sonos Favorites |
| **Line-In** | UPnP per-device | Any speaker with a physical line-in input |

## Connection required — confirmed working

These work in Choragus after a one-time AppLink connect. SMAPI sids verified by live probe against `ListAvailableServices`.

| Service | SID | Auth flow | Notes |
|---------|:---:|-----------|-------|
| **Spotify** | 12 | AppLink (browser) | Connect in Settings, then add one favorited song via the Sonos app to expose the account serial number |
| **Plex – Local** *(v3.7, reporting v5.0)* | 212 | PIN flow at [app.plex.tv/auth](https://app.plex.tv/auth), no household needed | Talks to your own Plex Media Server directly. Streams on the LAN — no third-party CDN, no short-lived signatures. Listings page 500 at a time. Playback is reported back to the server (`/:/timeline` heartbeats, `/:/scrobble` at ≥90 %), so Now Playing, play counts and smart playlists on the server stay current. Self-hosted, no `sn=` favorite required |
| **Plex – Remote** *(v5.0 naming)* | 212 | AppLink via Sonos's Plex SMAPI service (relayed through plex.tv) | Sonos's own Plex integration, reached through Plex's servers. It lists your server only when Plex Remote Access has a direct public address; a relay-only server (CGNAT) is reported by Plex's service as unavailable (no available servers). For rooms on your network use Plex – Local |
| **Audible** *(v4.0)* | varies | AppLink (browser) | Audiobook playback works; chapter navigation surfaces as a Sonos queue |
| **Amazon Music** | 201 | AppLink (browser) | S1 (verified 2026-09-06, Unlimited): tracks enqueue as `x-sonosapi-hls-static:catalog/tracks/<ASIN>/` with `flags=0`, DIDL prefix `10030000`; albums enqueue track by track. S2 (live tests 2026-09-09): ids the service shapes as `sp:container:station:…` (albums and playlists on a Prime account, itemType `program`, shown by the Sonos app with a shuffle badge) and artist rows (wrapped with that prefix) play as `x-sonosapi-radio:` on the transport with DIDL prefix `000c0000` and the anonymous `SA_RINCON<type>_` descriptor; tracks use the verbatim `catalog:track:asin:<ASIN>` id as `x-sonosapi-hls-static:` with `flags=0`, DIDL prefix `10030000`, anonymous descriptor, through the queue — verified with audio on an Unlimited account (2026-09-09; the speaker rewrites the row to `x-sonos-http:…mpd?flags=40`). Amazon Music **Prime** (the tier bundled with Prime) refuses every single-track form with UPnP 701 — Prime is station playback only; on-demand tracks need Amazon Music **Unlimited**. Choragus reports that refusal by name. Search ids carry a `#erefid-…` fragment that is stripped. `getMediaURI` is never used. Stations allow Next but not Previous — read off `CurrentTransportActions` |

## Connection required — untested

40+ additional services are reachable via SMAPI AppLink/DeviceLink and may work without modifications. Connect via **Settings → Music → Other Services** and please [open an issue](https://github.com/scottwaters/Choragus/issues) with the result.

| Service | SID (SMAPI) | Notes |
|---------|:---:|-------|
| **Pandora** | 3 | US-only as of 2026. `getAppLink` at `https://sonos.pandora.com/smapi` answers HTTP 200 with a `regUrl` and link code even from an AU household (2026-09-08), so sign-in is open; the row appears in Settings only for households whose descriptor list carries Pandora. Playback is untested: the rules table sends stations as `x-sonosapi-radio:` with `flags=8300`, which is the form the Sonos app uses, and the older synthesised `-0-Token` URI faulted SOAP 402 |
| Various others | — | Tidal, Deezer, iHeartRadio, Bandcamp, etc. — discovered dynamically from `ListAvailableServices` |

## Amazon Music — why it was listed as blocked

Amazon Music sat in the blocked table from v3.51 until v5.0, recorded as
"same Sonos-identity gate" with the code comment "returns empty auth URL".
Re-probed on 2026-09-06 against a live S1 household, that does not
reproduce: the descriptor reports `Policy Auth="AppLink"`, and `getAppLink`
returns HTTP 200 with a usable `regUrl`, including with the exact request
Choragus sends (`householdId` only, speaker device id). Four request
variants were tried, all succeeded.

The `hardware` / `osVersion` / `sonosAppName` fields that the SMAPI WSDL
lists as optional are optional here; they are not what unblocks it.
Token refresh works too: Amazon returns fresh credentials inside the
`Client.TokenRefreshRequired` fault's `<detail>`, which is exactly what
`soapCallWithRefresh` already reads.

Two things did need fixing, both in playback rather than auth:

- **Item ids.** Amazon's object ids (`catalog:track:asin:<ASIN>`) are not
  the ids its play URIs use (`catalog/tracks/<ASIN>/`). The verbatim id
  faults UPnP 714. Handled by `ItemIDStyle.amazonCatalogPath`.
- **URI scheme.** Tracks play through `x-sonosapi-hls-static:` with
  `flags=0` and DIDL id prefix `10030000`, not `x-sonos-http:` with 8224.
  Stations (`catalog:station:key:<key>`, id unrewritten) play through
  `x-sonosapi-radio:` with `flags=8300` and DIDL prefix `100c2068`; the
  generic `x-sonosapi-stream:` + 8224 form faults UPnP 402. Both taken from
  / verified against the household's own favorites and a live play test.
- **No `getMediaURI`.** Amazon's `getMediaURI` returns a signed CloudFront
  HLS manifest (`…/api/manifest.m3u8?…&Signature=…`). The speaker enqueues
  it but faults UPnP 701 on Play, and the call faults `ItemNotFound` for
  stations. `ServiceRules.resolvesViaGetMediaURI = false` keeps Amazon items
  on their raw service URI + DIDL, which is what the speaker plays.

The cdudn form turned out not to matter: the speaker accepted both the
token-bearing and the `-0-Token` variant.

Whether SiriusXM (37) and YouTube Music (284) are misdiagnosed the same way
is untested. Both carry the same "returns empty auth URL" comment, which is
now known to be an unreliable signal. SoundCloud (160) is different: a real
`403 Client.NOT_AUTHORIZED`.

## Blocked — Sonos-identity-gated

Confirmed by live probe against `ListAvailableServices` + `getAppLink` (most recent verification 2026-04-24). These services ship encrypted API keys in their Sonos manifest at `cf.ws.sonos.com/p/m/<uuid>` that only Sonos's own app and speaker firmware can decrypt. Third-party clients receive `403 / NOT_AUTHORIZED` from the SMAPI endpoint before authentication can begin.

| Service | SID | Response | Workaround |
|---------|:---:|----------|------------|
| **Apple Music** (as SMAPI service) | 204 | `SonosError 999` | iTunes Search API fallback already used for search; playback via Sonos Favorites |
| **YouTube Music** | 284 | GCP `403 PERMISSION_DENIED` (no API key) | — |
| **SoundCloud** | 160 | `Client.NOT_AUTHORIZED` (403) | Scrobbling of SoundCloud listens via the Sonos app still works |
| **Sonos Radio** *(category browsing)* | 303 | DeviceLink-only | Search works |

Scrobbling remains possible for all services above: play history is recorded from whatever the Sonos app plays, regardless of whether Choragus can directly browse/search that service. See [Last.fm scrobbling](../README.md#what-s-new-in-v36).

## AI playlist providers

Not music services: the chat AI behind **Build Playlist with AI** (Choragus Sources, opt-in via Settings → AI). Each entry is a user-named `AIServiceProfile` with its own model, endpoint and keychain key (`aiProfile.<id>`), so several custom servers can coexist.

| Provider | Endpoint | Notes |
|----------|----------|-------|
| **Claude** | `https://api.anthropic.com/v1/messages` | Raw HTTP, no SDK |
| **OpenAI** | `https://api.openai.com/v1` chat completions | — |
| **Custom (OpenAI-compatible)** | User-supplied base URL | DeepSeek, Ollama, LM Studio, vLLM. A bare host gains `/v1`; a URL that already carries a path is used as given. A 200 that is not an event stream surfaces the server's message (LM Studio answers an unknown path that way) |

The API key is sent only to that profile's host, and only as a bearer header over `https` or to a private address (Ollama / LM Studio on the LAN); cleartext to a non-local address is refused (`insecureEndpoint`). The reply is treated as untrusted input: typed decode, control-character stripping, field and list caps, stream size caps. A connection test in Settings gates the builder's source menu until it passes. Songs are then matched on a chosen service (Apple Music (iTunes catalog), any authenticated SMAPI service, the Sonos local library, or a DLNA server's `Search`), with artist match mandatory.

## Service identity folding

A household advertises around 90 third-party descriptors. `MusicServiceCatalog` resolves each to a canonical service by sid, then by name, then by the host's first DNS label. Vendors conventionally host their Sonos integration at `sonos.<vendor>.com`, so the host pass rejects tokens that describe what a service serves rather than who it is (`sonos`, `radio`, `music`, `player`, `stream`, `media`, `audio`) in both the scheme-token pass (`x-sonosapi-radio:` → "radio") and the name-word pass ("Sonos Radio" → "sonos"). Without that guard 37 unrelated services folded into Sonos Radio and inherited its search-only toggle. Descriptors folded by host match are logged under `CATALOG`.

Services that resolve through SMAPI to a plain HTTPS stream with no `sid=` (Radio Paradise, SomaFM, TIDAL) are named from the stream host as a last resort; a sid still wins where one exists. Plain-HTTP URIs on a known media-server host carry the server's name.

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
3. If `getAppLink` returns a fault (`403 / NOT_AUTHORIZED`, `SonosError 999`), the service is Sonos-identity-gated. Add to the blocked list and document the response; record the actual fault code, not "same as" another service.
4. If `getAppLink` returns HTTP 200 but an *empty* `regUrl`, treat it as inconclusive, not as a gate. Re-probe against the `SecureUri` from `ListAvailableServices` (or, for a service the household does not list, the service's own SMAPI host) and check the raw response for namespace-prefixed elements before concluding anything. This is what mis-filed Amazon Music as blocked for five releases, and Pandora for two.
5. If the service does not need a Sonos Favorite to expose the account serial number (self-hosted services like Plex), add the sid to `servicesNotNeedingSN` in `MusicServicesView`.
6. Update this document.
