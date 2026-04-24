# TODO

Tracking cross-release work items too small for GitHub issues but worth remembering.

## Post-v3.6

### Plex integration
- Sonos SMAPI endpoint for Plex (sid=212, URI `https://sonos.plex.tv/v2.2/soap`) uses the **standard SMAPI AppLink flow** — confirmed by live probe (2026-04-24): `getAppLink` returned HTTP 200 with a usable `regUrl` pointing to `app.plex.tv/auth`.
- Reuses the existing `SMAPIClient.getAppLink` / `getDeviceAuthToken` / `search` / `getMetadata` code paths already proven with Spotify.
- Plex streams audio directly from the **user's own server** (no third-party CDN, no short-lived signatures) so playback on Sonos should be reliable.
- Scope: wire up auth → add Plex tab in BrowseView → verify DIDL format for `AddURIToQueue` against Plex's returned URIs.

### SoundCloud integration — blocked
- Sonos SMAPI endpoint for SoundCloud (sid=160) returns `Client.NOT_AUTHORIZED` (403) when `getAppLink` is called from a non-Sonos client. Confirmed by live probe (2026-04-24).
- Only feasible third-party path is the unofficial `api-v2.soundcloud.com` + scraped `client_id` approach (what `scdl` uses). Fragile: client_id rotates, stream URLs expire, against SoundCloud ToS.
- **Scrobbling of SoundCloud listens already works** (tracks played via the Sonos app appear in play history with `sid=160` and match the scrobble filter).
- Decision: not pursuing until a cleaner path opens. Revisit if SoundCloud reopens their public API or if a community proxy emerges.

### YouTube Music — not feasible
- GCP-level 403 on `music.googleapis.com/v1:sendRequest` before auth. Sonos manifest ships encrypted `apiKey.cr` / `apiKey.zp` blobs that require Sonos firmware keys to decrypt.
- Link-out to the Sonos app remains the only realistic option for YTM playback.

## Smaller cleanups

- Queue load/switch during multi-track batch adds — sometimes the queue view doesn't update immediately when multiple tracks are added quickly; needs a single-shot refresh debounce.
- `@discardableResult` warning at `SonosManager.swift:1340` (function returns Void).
- Consider flipping auto-scrobble default to on after real-world confidence.
- Window panel spacing — user is adjusting manually; debug labels remain in place.
- Tooltip implementation — user prefers to handle manually; don't touch.
