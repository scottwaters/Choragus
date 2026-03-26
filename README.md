# SonosController

A native macOS controller for Sonos speakers, built entirely in Swift and SwiftUI for Apple Silicon.

![SonosController](screenshots/main.png)

## Why This Exists

Sonos shipped a macOS desktop controller for years, but it was an Intel-only (x86_64) binary that relied on Apple's Rosetta 2 translation layer. Apple is discontinuing Rosetta, which means the official Sonos desktop app will stop working on modern Macs — and Sonos appears to have no plans to release a native replacement.

This project was built from scratch by a Sonos fan from the beginning who wanted to keep controlling their speakers from their Mac.  I usually use the phone app but I sit in front of my workstation most days and use the desktop app many times during those days for my office speakers.  I also added a few tweaks/features that always bugged me or I thought were missing (but I added settings options to revert to original behaviour if you have problems :) ).

It is not affiliated with, endorsed by, or derived from Sonos, Inc. in any way. No proprietary Sonos code, assets, or intellectual property were used. The app communicates with Sonos speakers using the same open UPnP/SOAP protocols that any device on your local network can see and use (the same the other fan built implementations also use).

## Development

Built interactively with [Claude Code](https://claude.ai/) and tested against a live Sonos system with 16 speakers. v2 was a few more hours of refinement — fixing rough edges and adding network and usability features based on daily use.

Testing has been done with a large local music library and a limited set of streaming services (Apple Music, Spotify, TuneIn, Calm Radio). Your experience may vary depending on which services you use — if something doesn't work as expected, please open an issue.

## What's New in v2.1

- **Group presets** — save your favorite speaker groups with per-speaker volumes, then recall them with one click from the toolbar menu
- **Play history** — see what you've been listening to with a dedicated stats window showing top artists, tracks, and sources. Filter by room and service, export to CSV.
- **Home theater EQ** — dedicated window for soundbar setups with EQ, Sub, and Surrounds tabs. Night mode, dialog enhancement, music playback mode (Full/Ambient).
- **Menu bar mode** — optional menu bar icon with quick playback controls so you can control music without switching to the app
- **Playlist service tags** — playlists show colored service badges for each track's source (Apple Music, Spotify, etc.), scanned in the background and cached to disk
- **Recently played** — quick-access list of recently played stations and tracks right in the browse panel
- **Crossfade toggle** — crossfade control in the transport bar, highlights with your accent color when active
- **Pause all / Resume all** — one-click pause or resume every active zone from the speaker toolbar menu
- **Drag browse to queue** — drag tracks from the browse panel and drop them at any position in the queue
- **Queue drag reorder** — drag-drop reordering within the queue with a visual drop position indicator
- **Marquee text** — long track and artist names auto-scroll in Now Playing with a pause at start and end
- **Custom hover tooltips** — reliable tooltips on transport controls, replacing the broken SwiftUI .help() modifier
- **Sidebar context menu** — right-click any room for play/pause, mute, group editor, ungroup, or home theater EQ
- **Smart case formatting** — preserves Roman numerals (III, IV), capitalizes after brackets in stream metadata
- **Centralized constants** — SonosConstants.swift for URI prefixes, service IDs, colors, timing, and app paths

### Also new in v2.0

- **13 languages** — full localization in English, German, French, Dutch, Spanish, Italian, Swedish, Norwegian, Danish, Japanese, Portuguese, Polish, and Chinese (Simplified)
- **Dark mode** — System, Light, or Dark theme selection
- **Appearance customization** — accent color picker, zone icon colors for playing/inactive states
- **Playback transition feedback** — clicking a favorite shows cached artwork and station/track name immediately with a loading spinner until the speaker confirms playback. No more wondering if you clicked.
- **Persistent artwork caching** — album art for favorites is remembered across app restarts. No more blank thumbnails every time you relaunch.
- **Service identification** — favorites show colored source badges (Apple Music, Spotify, TuneIn, Calm Radio, etc.) with a filterable service bar
- **Copy track info** — clipboard output with labelled Source/Artist/Album/Track lines in the active language
- **Album art context menu** — right-click to refresh from iTunes or clear cached art
- **Streaming service error handling** — clear error messages when playback fails (e.g. "Spotify may require sign-in")
- **Dynamic album art discovery** — multi-strategy art resolution for library items: embedded art, folder images, iTunes Search API, container browsing
- **UPnP event subscriptions (GENA)** — real-time push notifications from speakers replace polling as the default, with automatic subscription renewal and polling fallback
- **Many bug fixes and performance improvements** — faster browse loading, reduced unnecessary network requests, smoother UI transitions, fixed edge cases with grouped speaker volume, and general stability improvements throughout

## Features

### Playback Control
- Play, pause, stop, skip forward/back
- Seek within tracks
- Shuffle and repeat (off / all / one)
- Crossfade toggle — highlights with accent color when active
- Keyboard shortcut: spacebar for play/pause
- Pause all / Resume all — pause or resume every active zone from the toolbar menu
- Optimistic UI — controls respond instantly with a grace period system that prevents polling from reverting your action while the speaker processes it
- Playback transition feedback — when starting a new stream, cached artwork and track info display immediately with a loading spinner until the speaker confirms playback

### Now Playing
- Album art display with two-tier disk and memory caching
- Album art fallback: embedded file art → folder art → iTunes Search API → generic placeholder
- Right-click album art to refresh from iTunes or clear
- Copy track info to clipboard — source, artist, album, track on separate labelled lines (localized)
- Marquee text — long track and artist names auto-scroll with a pause at start and end
- Track title, artist, album — clears when nothing is playing
- Service tag below album name shows source (Apple Music, Music Library, Spotify, etc.)
- Radio station name displayed above current track info for streaming sources
- TV and Line-In source detection with room name display
- Streaming service identification (shows "Playing from Apple Music" etc.)
- Draggable seek slider with smooth interpolation (no 2-second jumps)
- Freeze period after play/seek prevents slider bounce while speaker buffers
- Live indicator for streaming content without fixed duration

### Volume
- **Single speaker** — direct volume slider and mute
- **Grouped speakers** — master slider adjusts all speakers proportionally, preserving relative balance. Master mute controls all speakers.
- Individual per-speaker volume sliders and mute buttons below the master
- Animated slider transitions when volumes change
- Delayed spinner indicators — only appear if a volume change takes more than 300ms
- Bass, treble, and loudness controls (EQ panel per speaker)
- EQ zone selector — grouped zones show a speaker picker in the EQ panel
- Mute/Unmute all speakers globally (toolbar menu)

### Home Theater EQ
- Dedicated window for soundbar/surround setups (auto-detected from zone topology)
- **EQ tab** — bass, treble, loudness for the soundbar
- **Sub tab** — sub on/off, sub level, sub crossover
- **Surrounds tab** — surround on/off, surround level, music playback mode (Full/Ambient)
- Night mode and dialog enhancement toggles
- Accessible from sidebar context menu on home theater zones

### Speaker Management
- Automatic SSDP discovery of all Sonos speakers on your network
- Zone grouping — add or remove speakers from groups with optimistic UI
- Group All / Ungroup All buttons for quick whole-house control
- **Group presets** — save speaker groups with per-speaker volumes, apply with one click from the toolbar menu
- Speakers already in another group are labelled in the group editor
- Coordinator speaker always listed first, others alphabetically
- Bonded speakers (soundbar + sub + surrounds) shown as a single room
- Home theater detection — parses HTSatChanMapSet from topology for 5.1/sub identification
- Invisible/satellite speakers filtered from the UI
- Custom sidebar with configurable zone icon colors (playing/inactive)
- Sidebar context menu — right-click rooms for play/pause, mute, group editor, ungroup, home theater EQ
- Sound wave indicators show which rooms are currently playing (animated pulse)
- Accent-colored selection highlight in the room list
- Restore last zone — app remembers your last selected room across restarts

### Browse & Library
- **Sonos Favorites** — play any saved favorite including radio stations, Spotify playlists, Apple Music content
- **Recently played** — quick-access list of recently played stations and tracks in the browse panel
- **Service identification** — each favorite shows a colored badge identifying its source (Apple Music, Spotify, TuneIn, Calm Radio, Music Library, etc.)
- **Service filter** — filter favorites and playlists by source service (All / Apple Music / Radio / Spotify / etc.)
- **Playlist service tags** — playlists show per-track service badges, scanned in the background and cached to disk
- **Music Library** — browse your local network music shares (NAS/server) by folder, all the way down to individual tracks
- **Dynamic album art** — library folders load art from embedded files, folder images, or iTunes Search API
- **Artists, Albums, Genres, Composers, Tracks** — full indexed library browsing with drill-down navigation
- **Sonos Playlists** and imported playlists
- **Search** across artists, albums, and tracks
- All browse sections dynamically discovered from your Sonos system (nothing hardcoded)
- Play now, play next, or add to queue from any browse result via right-click context menu
- Drag tracks from browse and drop at any position in the queue
- Home and back navigation buttons in the browse header
- Pagination for large libraries (tested with 45,000+ tracks, 6,500+ albums)

### Queue
- View the current play queue with album art
- Tap to jump to any track
- Remove individual tracks or clear the entire queue
- Drag-drop reordering with visual drop position indicator
- Drag tracks from the browse panel to insert at any queue position

### Alarms
- View all configured Sonos alarms
- Enable/disable individual alarms
- Delete alarms

### Sleep Timer
- Set from preset durations (15m, 30m, 45m, 1h, 2h)
- View remaining time
- Cancel active timer

### Menu Bar Mode
- Optional menu bar icon for quick access without switching to the app
- Playback controls (play/pause, next, previous) from the menu bar dropdown
- Volume control and current track info at a glance

### Play History
- Tracks what you listen to with timestamps, artist, album, source, and room
- Dedicated stats window with top artists, tracks, and sources
- Filter by room and streaming service
- Export to CSV
- Toggle on/off in Settings
- Right-click to copy track details

### Caching & Performance
- **Quick Start mode** — caches your speaker layout and browse menu locally. On subsequent launches, the UI appears instantly from cache while speakers are verified in the background. If anything changed, the UI updates automatically. Stale data is detected gracefully with user-visible notifications.
- **Classic mode** — waits for live network discovery before showing speakers (always current, slightly slower startup).
- **Album art cache** — two-tier caching (memory + disk) for album artwork. Images load instantly on repeat views. JPEG compressed with configurable max size (100 MB–5 GB) and max age (7 days–never). LRU eviction.
- **Art URL persistence** — art URLs discovered during playback are persisted to disk and restored on restart, so favorites show artwork immediately without re-discovering from the speaker.
- **Playlist services cache** — background scan results for playlist track service badges cached to disk, so badges appear instantly on subsequent views.
- **Grace period system** — after pressing play/pause or changing volume, the UI holds your intended state for 10 seconds so polling doesn't snap it back while the speaker processes the command.
- **Smooth progress interpolation** — the seek bar advances locally every 0.5s between 2-second server polls, with drift correction. Never jumps backward on small drift.
- Configurable via Settings (gear icon in toolbar).

### Communications
- **Event-Driven mode** (default) — UPnP event subscriptions for real-time state updates with automatic subscription renewal. Falls back to reconciliation polling every 10 seconds as a safety net. Position polled every 2 seconds for smooth progress bar.
- **Legacy Polling mode** — original 2-second polling for all state. More predictable on networks where event callbacks are unreliable.
- Switchable in Settings without restart.

### Music Services
- Streaming services (Spotify, Apple Music, TuneIn, Calm Radio, etc.) identified by colored badges in the browse list
- Content from these services is playable through **Sonos Favorites** — add favorites via the Sonos mobile app, then play them from the Favorites section in Browse
- Streaming service albums/playlists (x-rincon-cpcontainer URIs) are handled automatically via queue
- Service-specific error messages when playback fails (e.g. "Spotify may require sign-in or an active subscription")

### Appearance & Localization
- **Dark mode** — System / Light / Dark theme selection
- **Accent color** — customizable tint for sliders, selections, toggles. Preset colors + custom color picker. Does not affect toolbar icons.
- **Zone icon colors** — separate colors for playing and inactive speaker icons
- **Custom hover tooltips** — reliable tooltips on transport controls replacing the broken SwiftUI .help() modifier
- **13 languages** — English, German, French, Dutch, Spanish, Italian, Swedish, Norwegian, Danish, Japanese, Portuguese, Polish, Chinese (Simplified). Switchable in Settings.

## Requirements

- macOS 14.0 (Sonoma) or later
- Apple Silicon Mac (M1 or later) — also runs on Intel via Rosetta during the transition period
- Sonos speakers on the same local network

## Installation

### Option 1: Download Pre-Built App

1. Go to [Releases](../../releases) and download the latest `SonosController.zip`
2. Unzip and drag `SonosController.app` to your Applications folder
3. **First launch:** Right-click the app and click "Open", then click "Open" in the dialog (required once because the app is not notarized with Apple — it's a community project, not from the App Store)
4. macOS will ask to allow local network access — click Allow (the app needs this to find your Sonos speakers)

### Option 2: Build From Source

**Prerequisites:** Xcode 15 or later (free from the Mac App Store). No other tools or dependencies needed.

```bash
# Clone the repo
git clone https://github.com/scottwaters/SonosController.git
cd SonosController

# Build (Release, Apple Silicon)
xcodebuild -scheme SonosController \
  -configuration Release \
  -arch arm64 \
  CONFIGURATION_BUILD_DIR="$(pwd)/build" \
  build

# The built app is at:
# build/SonosController.app
```

Or open `SonosController.xcodeproj` in Xcode and press Cmd+R to build and run.

**No external dependencies.** No CocoaPods, no SPM remote packages, no downloads. The entire project builds using only Apple's standard frameworks (SwiftUI, Foundation, Darwin).

### Building a Release ZIP for Distribution

```bash
xcodebuild -scheme SonosController \
  -configuration Release \
  -arch arm64 \
  CONFIGURATION_BUILD_DIR="$(pwd)/build" \
  build

cd build && zip -r ~/Desktop/SonosController.zip SonosController.app
```

The resulting `SonosController.zip` can be uploaded to GitHub Releases.

## Architecture

The project is split into two targets:

- **SonosController** — SwiftUI app with 20+ view files
- **SonosKit** — local Swift package containing all networking, protocols, models, caching, events, localization, and album art services (zero external dependencies)

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for detailed source documentation.

### Protocol Stack (all implemented from scratch)

| Protocol | Purpose |
|----------|---------|
| SSDP | UDP multicast discovery of speakers on the LAN |
| UPnP/SOAP | HTTP+XML commands to speakers on port 1400 |
| UPnP Eventing (GENA) | Real-time push notifications via HTTP SUBSCRIBE/NOTIFY |
| DIDL-Lite | XML metadata format for tracks, albums, playlists |
| Sonos UPnP extensions | Zone topology, favorites, service account URIs |
| iTunes Search API | Album art fallback for local library content |

### Sonos Services Used

| Service | What It Controls |
|---------|-----------------|
| AVTransport | Play, pause, stop, seek, sleep timer, grouping |
| RenderingControl | Volume, mute, bass, treble, loudness |
| ZoneGroupTopology | Room/group/coordinator discovery |
| ContentDirectory | Queue, browse library, search, add to queue |
| AlarmClock | List, create, update, delete alarms |
| MusicServices | List available streaming services |

## How It Works

All communication happens on your local network. The app never contacts the internet.

1. **Discovery** — sends a UDP multicast M-SEARCH packet to `239.255.255.250:1900` asking for Sonos ZonePlayers. Each speaker responds with its IP address.
2. **Device description** — fetches XML from each speaker to learn its name, model, and UUID.
3. **Zone topology** — a single SOAP call to any speaker returns the complete map of all rooms, groups, and which speaker is the coordinator of each group.
4. **Commands** — all playback, volume, and browse operations are SOAP (HTTP POST with XML) to port 1400 on the relevant speaker. Transport commands go to the group coordinator; volume commands go to individual speakers.
5. **Event subscriptions** (default) — the app subscribes to UPnP events for real-time push notifications of state changes. AVTransport events for playback, RenderingControl events for volume/mute, with reconciliation polling as a safety net.
6. **Polling** (fallback) — alternatively, the app polls the selected speaker every 2 seconds. A grace period system prevents polling from overwriting optimistic UI state after user actions.
7. **Caching** — speaker topology and browse sections are cached to disk (JSON) for instant startup. Album artwork is cached to a two-tier memory + disk cache with LRU eviction. Art URLs discovered during playback are persisted to disk so favorites retain artwork across restarts.

## Limitations

- **Music service browsing** — Spotify, Apple Music, and other streaming services use Sonos's proprietary SMAPI protocol which requires OAuth authentication. Only the official Sonos mobile app can configure service accounts. Content from these services is accessible through Sonos Favorites.
- **Radio** — TuneIn, Calm Radio, and other radio services are SMAPI-based. Radio stations saved as Sonos Favorites play correctly with station name and current track info displayed. Browsing the radio directory is not supported.
- **Streaming track metadata** — some streaming services (particularly Apple Music) may not provide full track metadata (artist, album, art) for all content when played via UPnP. The app falls back to the favorite's metadata and iTunes Search API for album art.

## License

MIT License

Copyright (c) 2026

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Disclaimer

This project is not affiliated with, endorsed by, or connected to Sonos, Inc. "Sonos" is a trademark of Sonos, Inc. This software is an independent, fan-built controller that communicates with Sonos hardware using standard UPnP protocols. Use at your own risk.
