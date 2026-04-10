# The SonosController

A native macOS controller for Sonos speakers, built entirely in Swift and SwiftUI. Ships as a universal binary with native support for both Apple Silicon and Intel Macs.

![SonosController — Now Playing with Browse and Queue](screenshots/v3/mainview_browse_search_queue.png)

## Why This Exists

Sonos shipped a macOS desktop controller for years, but it was an Intel-only (x86_64) binary that relied on Apple's Rosetta 2 translation layer. Apple is discontinuing Rosetta, which means the official Sonos desktop app will stop working on modern Macs — and Sonos appears to have no plans to release a native replacement.

This project was built from scratch by a Sonos fan who wanted to keep controlling their speakers from their Mac. It is not affiliated with, endorsed by, or derived from Sonos, Inc. in any way. No proprietary Sonos code, assets, or intellectual property were used. The app communicates with Sonos speakers using the same open UPnP/SOAP protocols that any device on your local network can see and use.

## Development

Tested against a live Sonos system with 16 speakers across 10 zones, a large local music library (45,000+ tracks), and multiple streaming services (Apple Music, Spotify, TuneIn, Calm Radio, Sonos Radio).

## What's New in v3

### Music Services
- **TuneIn, Calm Radio, Sonos Radio, Apple Music** — browse and search with no sign-in required, individually toggleable in Settings
- **Spotify** — full browse, search, and playback via AppLink authentication
- **40+ additional services** — Deezer, TIDAL, Qobuz, SoundCloud, iHeartRadio, Plex, and more via SMAPI AppLink/DeviceLink
- **Sonos Radio search** — search stations via anonymous SMAPI
- **Apple Music playback** — search via iTunes API, direct playback when Apple Music is connected in the Sonos app with one favorited song
- **Service availability status** — clear indicators in Settings showing what works, what needs connection, what's blocked
- **Setup guide** with step-by-step instructions and service status indicators (Active / Needs Favorite / Connect)
- **Serial number discovery** — automatically detects account identifiers from favorites and play history

### Listening Stats
- **Dashboard** — top tracks, top stations, top albums, day-of-week distribution, room usage, listening streaks
- **Quick stats pills** — current streak, best streak, avg plays/day, unique albums, unique stations
- **Card-based history** — timeline view grouped by day with album art, metadata pills, context menus
- **Custom date range** filter with From/To date pickers
- **SQL-based filtering** — handles 50,000+ entries with instant search (debounced 300ms)
- **Service tags** — show streaming service name (Sonos Radio, TuneIn, Spotify) instead of station name
- **Station-only logging** — radio stations logged to history even when no track data is available
- **Listening history** — any tracks played on any speakers are logged locally to a SQLite database while the app is running

### Star / Favorite Tracks
- **Star any track** — star button in Now Playing and menu bar mini player, works on queue tracks, radio streams, Spotify, Apple Music — any track where metadata is available
- **Toggle on/off** — tap to star, tap again to unstar
- **Starred filter** — filter play history to show only starred tracks - a great way to keep track of those radio station songs you like for later
- **Dashboard integration** — starred count shown in quick stats pills
- **Persisted** — stars stored in SQLite alongside play history

### Artwork Management
- **Manual artwork search** — right-click album art > Search Artwork, prepopulated with track metadata, pick from grid with large preview
- **Ignore artwork** — right-click > Ignore Artwork shows generic service icon, persisted per track
- **Automatic artwork resolution** — multi-strategy pipeline: speaker metadata, iTunes Search, manual override
- **Radio track art** — automatic iTunes search for radio tracks with station badge overlay
- **Ad break detection** — shows station art during radio ads, resumes track art when music returns
- **Pre-caching** — manually selected artwork cached to disk for instant reload
- **History sync** — artwork changes propagate to play history entries immediately

### Radio Streams
- **Artist/title parsing** — stream content "Artist - Title" correctly parsed with smart casing
- **Bare `&` handling** — stream content with unescaped ampersands (e.g. "Skrillex & Rick Ross") parsed correctly
- **Short artist names** — "SWV", "U2", "TLC", "REM" correctly recognised
- **Multi-language titles** — improved art scoring for titles like "Tristania (Troia Troy)"
- **Station change tracking** — clears stale art when switching stations

### Menu Bar Redesign
- **Hero art area** — blurred album art background with track info overlay
- **Room picker** — green/gray dots showing playing status per zone
- **Star button** — star/unstar the currently playing track
- **Mute button** — speaker icon toggles mute for all group members
- **Volume readout** — numeric display alongside slider
- **Accent color** — inherits custom accent from main app settings

### Settings Redesign
- **Tabbed layout** — Display, Music, System tabs
- **Music Services management** — enable search services, connect Spotify, service status with setup guide
- **Playback options** — Classic Shuffle, Proportional Group Volume

### Now Playing
- **Panel sizing** — now playing guaranteed minimum 640px, browse/queue shrink proportionally when window resized
- **Copy Track Details** — copies formatted Artist/Album/Track to clipboard
- **Track change cleanup** — artwork overrides correctly reset on track change

### Architecture & Quality
- **11 service protocols** (ISP) — PlaybackService, VolumeService, EQService, QueueService, BrowsingService, GroupingService, AlarmService, MusicServiceDetection, TransportStateProviding, ArtCache
- **Code deduplication** — stream content parsing, technical name detection, metadata enrichment consolidated into single sources of truth
- **Centralized constants** — all hardcoded values moved to Timing, PageSize, BrowseID, CacheDefaults enums
- **267 unit tests** covering all code paths
### Security
- **Keychain storage** — when you connect a music service like Spotify, the authentication tokens and private keys are stored in the macOS Keychain, not in plain text files. Tokens are protected with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, meaning they can only be accessed while your Mac is unlocked and cannot be transferred to another device. Service metadata (which services are connected) is stored separately — the actual secrets never leave the Keychain
- **App sandbox** — runs with minimal entitlements (network client/server only). No access to your files, contacts, or other apps
- **ATS hardened** — specific domain exceptions instead of blanket NSAllowsArbitraryLoads
- **Error sanitization** — SOAP faults and HTTP errors show user-friendly messages, raw details never exposed
- **Cache file permissions** — all cache files created with 0o600 (owner-only read/write)
- **URL validation** — HTTP-to-HTTPS conversion uses proper URL parsing
- **No telemetry** — no analytics, no crash reporting, no data sent anywhere. All data stays on your Mac

### Performance
- **Removed duplicate polling** — NowPlayingViewModel no longer duplicates TransportStrategy's SOAP calls
- **@Published change guards** — dictionary writes only trigger SwiftUI updates when values actually change
- **Dashboard stats cached** — computed once in @State, not per-body evaluation

### Bug Fixes
- Radio station name preserved on pause
- Queue artwork for local library tracks via /getaa fallback
- History dedup uses track duration for window (no more duplicates for long songs)
- RINCON device IDs filtered from all metadata paths
- Volume/mute correctly syncs on zone switch
- Time display fixed height (no layout shift on play/pause)

## Features

### Now Playing, Browse, and Queue

![Now Playing with Browse panel and Queue](screenshots/v3/mainview_browse_search_queue.png)

The main view shows three panels: Browse (left), Now Playing (center), and Queue (right). All three are togglable from the toolbar. The Now Playing panel is guaranteed a minimum width of 640px — side panels shrink proportionally when the window is resized.

**Now Playing** shows album art with automatic artwork resolution from multiple sources (speaker metadata, iTunes Search, manual override). Right-click the artwork to search for alternative art, ignore incorrect art, or refresh. The service tag (Spotify, Radio, Music Library, etc.) shows the source at a glance.

**Star any track** — click the star icon next to "Copy Track Info" to star the currently playing track. This works for any source: queue tracks, radio streams, Spotify, Apple Music — any track where metadata is available. Starred tracks are persisted in SQLite and can be filtered in the listening history. Star and unstar from the Now Playing view or the menu bar mini player.

**Copy Track Details** — click "Copy Track Info" to copy the current track's metadata to your clipboard in a clean format:

```
Artist: Lofi Girl
Album: Lofi Girl x Assassin's Creed Shadows - stealthy beats to relax to
Track: A Moment of Sweetness - Prithvi Remix
```

This is useful for sharing what you're listening to, logging tracks manually, or searching for a track on another platform.

**Playback controls** — play, pause, stop, skip forward/back, seek with draggable slider and smooth position interpolation. Shuffle and repeat (off / all / one), crossfade toggle, sleep timer. Pause all / Resume all from the toolbar menu.

**Volume** — master slider adjusts all speakers in a group (proportional or linear mode). Individual per-speaker sliders with drag protection. Mute toggle per speaker and master. Bass, treble, loudness, and Home Theater EQ (sub/surround levels, night mode, dialog enhancement) via the EQ panel.

### Browse & Library

The Browse panel provides access to your entire music library and connected services:

- **Service Search** — Apple Music, TuneIn, Calm Radio, Sonos Radio, Spotify (individually toggleable in Settings)
- **Sonos Favorites & Playlists** — everything you've set up in the Sonos app
- **Local Library** — NAS/network music library with artists, albums, tracks, genres, composers, and folder browsing
- **Recently Played** — quick access to tracks from your listening history
- **Search** — local library search across artists, albums, and tracks
- Play now, play next, add to queue, replace queue from context menu
- Drag tracks from browse directly into the queue

### Queue

The Queue panel shows the current play queue with album art, track info, and duration. Tap to jump to a track, drag to reorder, right-click to remove. Queue shuffle physically reorders the tracks. Save the current queue as a Sonos playlist.

### Music Services

Services are managed in Settings > Music. Each can be individually enabled.

#### Available — No Connection Required

| Service | Browse | Search | Playback | Notes |
|---------|:------:|:------:|:--------:|-------|
| **Local Music Library** | Yes | Yes | Yes | NAS/network shares via UPnP |
| **Sonos Favorites** | Yes | — | Yes | Favorites set up in the Sonos app |
| **Sonos Playlists** | Yes | — | Yes | Playlists saved from queues |
| **TuneIn** | Yes | Yes | Yes | Public RadioTime API, no login needed |
| **Calm Radio** | Yes | — | Yes | Public API, no login needed |
| **Apple Music** | — | Yes | Yes | Search via iTunes API. Playback requires Apple Music connected in the Sonos app and one favorited song — this lets the app discover your account credentials. Once set up, all search results are directly playable |
| **Sonos Radio** | — | Yes | Yes | Search via anonymous SMAPI. Category browsing requires DeviceLink auth (not yet supported) |

#### Available — Connection Required (Tested)

| Service | Browse | Search | Playback | Notes |
|---------|:------:|:------:|:--------:|-------|
| **Spotify** | Yes | Yes | Yes | AppLink authentication. Connect in Settings, then add one favorited song via the Sonos app |

#### Available — Connection Required (Untested)

40+ additional services are available via SMAPI AppLink/DeviceLink authentication including Deezer, TIDAL, Qobuz, SoundCloud, iHeartRadio, Plex, Pocket Casts, and others. These can be connected from Settings > Music > Other Services. Results are not guaranteed.

#### Not Available

| Service | Reason |
|---------|--------|
| **Amazon Music** | Requires Amazon's native OAuth — returns empty auth URL via SMAPI |
| **YouTube Music** | Requires Google's native OAuth — returns empty auth URL via SMAPI |
| **Sonos Radio browsing** | Category browsing requires DeviceLink auth not yet implemented (search works) |

### Listening History

![Listening Stats — Dashboard](screenshots/v3/history_stats.png)

The **Dashboard** shows your listening patterns at a glance: total plays, hours listened, unique artists and rooms. Quick stat pills show your current streak, best streak, average plays per day, unique albums, stations, and starred track count. Charts show listening activity over time, peak hours, and day-of-week distribution.

![Listening Stats — Timeline](screenshots/v3/history_list.png)

The **History** timeline groups tracks by day with album art, artist, album, service source badge, room, and duration. Starred tracks show a star icon. Tracks from radio streams show the station name and service badge (Sonos Radio, TuneIn, etc.). Filter by date range, room, source, or search text. Starred-only filter shows just your favorites.

![History — Right-click menu](screenshots/v3/history_rightclick.png)

**Right-click any track** in the history to:
- **Star / Unstar** — mark tracks as favorites
- **Copy Track Details** — copies formatted metadata (Artist, Album, Track, Station) to clipboard
- **Copy Title / Copy Artist** — copy individual fields
- **Filter by artist, room, or source** — instantly filter the history view

### Menu Bar Mode

![Menu Bar Mini Player](screenshots/v3/menubar.png)

Control playback without switching apps. The menu bar mini player shows album art with a blurred background, track title, artist, and room. Transport controls (skip, play/pause, skip), volume slider with mute toggle, and a **star button** to star the currently playing track. Room picker shows green/gray dots for playing status across zones. Click "Open SonosController" to bring up the main window.

### Speaker Presets

![Group Presets](screenshots/v3/presets.png)

Save and recall speaker group configurations with per-speaker volumes. Optionally include EQ settings (bass, treble, loudness, home theater sub/surround levels). One-click Apply to instantly reconfigure your speakers.

![Preset EQ Editor](screenshots/v3/presets_setup.png)

The preset editor shows all EQ controls including Home Theater settings: Night Mode, Dialog Enhancement, Sub level, Surround level, TV/Music balance, and Full/Ambient playback mode.

### Settings

![Settings — Display tab](screenshots/v3/settings_themes.png)

Settings are organized into three tabs:

- **Display** — Language (13 languages), theme (System/Light/Dark), custom colors for accent, playing zone, and inactive zone icons, menu bar controls toggle
- **Music** — Playback options (Classic Shuffle, Proportional Group Volume), Play History toggle with stats, Music Services management (enable search services, connect Spotify, service status)
- **System** — Communication mode (Event-Driven / Legacy Polling), Startup mode (Quick Start / Classic), Image cache controls (size limit, age limit, clear)

## Requirements

- macOS 14.0 (Sonoma) or later
- Apple Silicon Mac (M1+) or Intel Mac
- Sonos speakers on the same local network

## Installation

### Option 1: Download Pre-Built App

1. Go to [Releases](../../releases) and download the latest `SonosController.zip`
2. Unzip and drag `SonosController.app` to your Applications folder
3. **First launch:** Right-click the app and click "Open", then click "Open" in the dialog (required once because the app is not notarized)
4. macOS will ask to allow local network access — click Allow

### Option 2: Build From Source

**Prerequisites:** Xcode 15 or later.

```bash
git clone https://github.com/scottwaters/SonosController.git
cd SonosController

# Build universal binary (Apple Silicon + Intel)
xcodebuild -scheme SonosController \
  -configuration Release \
  -destination 'platform=macOS' \
  CONFIGURATION_BUILD_DIR="$(pwd)/build" \
  ONLY_ACTIVE_ARCH=NO \
  ARCHS="arm64 x86_64" \
  build

# The built app is at: build/SonosController.app
```

**No external dependencies.** No CocoaPods, no SPM remote packages. The entire project builds using only Apple's standard frameworks.

## Architecture

- **SonosController** — SwiftUI app (28 view files, 6 ViewModels)
- **SonosKit** — local Swift package (networking, protocols, models, caching, events, localization, services)
- **23,000+ lines of Swift** across 80 source files
- **267 unit tests**
- **Zero external dependencies**

### Protocol Stack

| Protocol | Purpose |
|----------|---------|
| SSDP | UDP multicast discovery of speakers |
| UPnP/SOAP | HTTP+XML commands to speakers on port 1400 |
| GENA | Real-time push notifications via HTTP SUBSCRIBE/NOTIFY |
| SMAPI | Music service browsing and authentication |
| DIDL-Lite | XML metadata format for tracks, albums, playlists |
| iTunes Search API | Album art fallback for local library content |

## Known Limitations

- **Apple Music** — search works via iTunes API; playback requires Apple Music connected in Sonos app + one favorited song
- **Sonos Radio** — search works anonymously; browsing categories requires DeviceLink auth (not yet supported)
- **Amazon Music / YouTube Music** — blocked (require native OAuth not available to third-party apps)
- **Add to Favorites** — requires the official Sonos app (UPnP CreateObject not supported)
- **Alarms** — Sonos S2 uses cloud API; UPnP AlarmClock returns empty
- **SMAPI serial number** — discovered from existing favorites/history; new services need one favorite added via Sonos app

## License

MIT License — Copyright (c) 2026

## Disclaimer

This project is not affiliated with, endorsed by, or connected to Sonos, Inc. or any of the music service providers referenced in this software. All trademarks are the property of their respective owners: "Sonos" and "Sonos Radio" are trademarks of Sonos, Inc.; "Spotify" is a trademark of Spotify AB; "Apple Music" and "iTunes" are trademarks of Apple Inc.; "Amazon Music" is a trademark of Amazon.com, Inc.; "YouTube Music" is a trademark of Google LLC; "TuneIn" is a trademark of TuneIn, Inc.; "TIDAL" is a trademark of Aspiro AB; "Deezer" is a trademark of Deezer SA; "SoundCloud" is a trademark of SoundCloud Limited; "iHeartRadio" is a trademark of iHeartMedia, Inc.; "Plex" is a trademark of Plex, Inc.; "Calm Radio" is a trademark of Calm Radio Ltd.

This software is an independent, fan-built controller that communicates with Sonos hardware using standard UPnP protocols. No proprietary code, assets, or intellectual property from any of these companies was used. Use at your own risk.
