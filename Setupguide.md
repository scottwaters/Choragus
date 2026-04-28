# Setup Guide — Music Services in Choragus

This guide is for getting your favourite streaming services (Spotify, Apple Music, TuneIn, Plex, etc.) working inside Choragus. It's written for everyday users, not engineers — no command-line steps, no networking jargon. If anything is still unclear after reading this, please open an issue.

---

## Quick decision tree

Pick the service you care about. Each one falls into one of two paths:

| Service | Path |
|---|---|
| **TuneIn** | A — easy |
| **Calm Radio** | A — easy |
| **Sonos Radio** | A — easy |
| **Apple Music** *(search only)* | A — easy |
| **Spotify** | B — needs Sonos-app step |
| **Plex** | B — but skip the favourited-song step (B is shorter for Plex) |
| **Apple Music** *(playback, not just search)* | B — needs Sonos-app step |
| **Amazon Music, YouTube Music, SoundCloud** | Not supported in any third-party app — see the bottom of this guide for why |

If you only ever listen via TuneIn or radio, you can skip Path B entirely.

---

## Path A — Services that need no extra Choragus sign-in

**TuneIn, Calm Radio, Sonos Radio, Apple Music (search).**

These services don't require a Choragus-side OAuth — but they **do still need to exist in your Sonos household**. The radio services (TuneIn, Calm Radio, Sonos Radio) are pre-installed on most Sonos systems and you usually don't have to do anything; Apple Music has to be added explicitly. If a service hasn't been added in your Sonos household, the toggle in **Settings → Music** will be greyed out with an inline hint.

### Step 0 (only if needed) — Add the service in the official Sonos app

1. Open the official Sonos app on your phone or tablet.
2. Go to **Settings → Services & Voice → Add a Service**.
3. Pick the service. For Apple Music sign in with your Apple Account; for the radio services there's nothing to sign in to.
4. The service is now part of your Sonos household.

You only need to do this once per service per Sonos household. For TuneIn / Calm Radio / Sonos Radio you usually don't need this step at all — they're already there.

### Steps inside Choragus

1. **Open Choragus.**
2. **Press `⌘,`** (Command + comma) to open Settings. (Or `Choragus` menu → `Settings…`.)
3. Scroll to the **Music** section.
4. Under **Search Services**, tick the checkbox next to the service you want.

The service now appears in the **Browse** panel under **Service Search**. You can search, browse, and play music. No browser sign-in step.

> **Note for Apple Music:** the Path A checkbox enables *search* only (via the public iTunes API). To actually *play* an Apple Music track on your speakers, you also need to follow Path B's favourited-song step once. Tapping search results to preview works without it.

---

## Path B — Services that need a connection

**Spotify, Plex, Apple Music (for playback), and other AppLink services.**

These services require Sonos to authenticate with your account before Choragus can stream from them. There are three sub-steps, in this order:

### Step 1 — Add the service in the official Sonos app

This step happens *outside* Choragus, on your phone or tablet, in the official Sonos app published by Sonos, Inc.

1. Open the official Sonos app (the one made by Sonos).
2. Go to **Settings → Services & Voice → Add a Service**.
3. Pick the service (Spotify, Plex, Apple Music, etc.) and sign in with your account credentials.
4. The service should now appear in your Sonos system as a connected source.

You only need to do this once per service per Sonos household.

### Step 2 — *(Spotify and Apple Music only — skip for Plex)* Add one favourited song

This step is the one most users miss. **Sonos's internal account identifier (`sn=`) is only generated when you favourite content from a service.** Without that identifier, third-party apps like Choragus cannot authenticate playback through the service. There is no way for the app to do this on your behalf — it's a Sonos design constraint.

1. Still in the official Sonos app, browse the service you just connected.
2. Play any track from that service on any of your Sonos speakers.
3. While the track is playing, tap **the heart icon** (or *Save to Sonos Favorites*).

Just one favourite is enough — you don't need to do this for every track.

> **Why is this necessary?** Sonos generates the account identifier the first time you save content from a service. Once that identifier exists, every third-party Sonos controller can use it to authenticate playback. There's nothing Choragus can do to bypass this — the identifier is generated server-side by Sonos.
>
> **Plex doesn't need this.** Plex streams from your own home server, so Sonos doesn't track a per-account subscription identifier for it.

### Step 3 — Connect the service inside Choragus

1. Open Choragus.
2. Press `⌘,` to open Settings.
3. Scroll to the **Music** section.
4. Find **Connected Services**.
5. The service you connected in Step 1 should appear in the list with a grey dot and a **Connect** button.
6. Click **Connect**.
7. Your default browser opens; sign in with the same account as Step 1.
8. After authorisation, return to Choragus.

The dot beside the service should turn:

- 🟢 **Green** — fully active, ready to browse and play.
- 🟠 **Orange** — connected but missing the favourited-song step. Go back to Step 2.

Once it's green, the service appears in the **Browse** panel and you can search, browse, and play.

---

## What if my service is in neither list?

The **Other Services** section in Settings → Music lists every service Sonos has registered (~100). Most have not been individually tested — many *should* work via AppLink, but we haven't confirmed each one. If you connect one and it works, please open an issue so we can promote it to "tested".

Also see the in-app **Setup Guide** button (Settings → Music → top of Connected Services) for the same instructions in a compact form.

---

## Services that don't work — and why

Some services cannot be controlled by *any* third-party app, including this one:

- **Amazon Music** — Amazon uses a proprietary OAuth flow that Sonos exposes only to its own apps. Returns an empty auth URL when third-party apps ask. There is no workaround.
- **YouTube Music** — same pattern. Locked to Sonos's first-party apps.
- **SoundCloud** — Sonos's account-identity gate returns `Client.NOT_AUTHORIZED` (HTTP 403) to non-Sonos clients. Confirmed by live probe.
- **Sonos Radio (browsing categories)** — search works (Path A); browsing the curated categories requires DeviceLink authentication, which Sonos has not exposed to third-party apps.

These limitations apply equally to every third-party Sonos controller — not just Choragus. The official Sonos app remains the only way to drive these specific services.

---

## Troubleshooting

**The service shows orange ("Needs Favorite") in Settings → Music.**

You completed Step 1 and Step 3 but skipped Step 2. Open the official Sonos app, play a song from this service, and save it as a favourite. Return to Choragus; within a minute or two the indicator should turn green.

**The Connect button does nothing / browser doesn't open.**

Make sure you have a default browser set in macOS (System Settings → Desktop & Dock → Default web browser). If it's set and the button still doesn't respond, please open an issue with your macOS version and the service name.

**The service appears in Settings but not in the Browse panel.**

The Browse panel needs to be refreshed after you enable a service. Switch away from the Browse panel and back, or restart the app.

**I don't see the service at all in Settings → Music.**

Open the **Other Services** disclosure under Connected Services. It lists every service Sonos has registered. Use the search field to find it.

**I followed everything and it still doesn't work.**

Open an issue at <https://github.com/scottwaters/Choragus/issues>. Include:
- Which service.
- Which path (A or B).
- The dot colour beside the service in Settings → Music.
- Any error messages shown in the Settings panel.

---

## Summary

- **Path A (TuneIn, Calm Radio, Sonos Radio, Apple Music search):** open Choragus → `⌘,` → Music → tick the checkbox. Done.
- **Path B (Spotify, Plex, Apple Music playback):**
  1. In the official Sonos app, add the service.
  2. *(Spotify / Apple Music only)* In the official Sonos app, play a song from that service and save it as a favourite.
  3. In Choragus, `⌘,` → Music → Connected Services → click **Connect** → sign in via browser.
  4. Wait for the dot to turn green.

If you have any questions or hit something this guide doesn't cover, please open an issue.
