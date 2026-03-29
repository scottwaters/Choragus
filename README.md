# The SonosController

A native macOS controller for Sonos speakers, built entirely in Swift and SwiftUI for Apple Silicon and Intel Macs.

![SonosController](screenshots/main.png)

## Why This Exists

Sonos shipped a macOS desktop controller for years, but it was an Intel-only (x86_64) binary that relied on Apple's Rosetta 2 translation layer. Apple is discontinuing Rosetta, which means the official Sonos desktop app will stop working on modern Macs — and Sonos appears to have no plans to release a native replacement.

This project was built from scratch by a Sonos fan who wanted to keep controlling their speakers from their Mac. It is not affiliated with, endorsed by, or derived from Sonos, Inc. in any way. No proprietary Sonos code, assets, or intellectual property were used. The app communicates with Sonos speakers using the same open UPnP/SOAP protocols that any device on your local network can see and use.

## Development

Built interactively with [Claude Code](https://claude.ai/) and tested against a live Sonos system with 16 speakers across 10 zones. Testing has been done with a large local music library (45,000+ tracks) and streaming services (Apple Music, Spotify, TuneIn, Calm Radio, Sonos Radio).

## What's New in v3

### Music Service Browsing (SMAPI)
- **Connect streaming services** — TuneIn, Spotify, Deezer, TIDAL, and 40+ services with AppLink/DeviceLink authentication
- **Browse and play** from connected services directly in the sidebar
- **Setup guide** with step-by-step instructions and service status indicators (Active / Needs Favorite / Connect)
- **Serial number discovery** — automatically detects account identifiers from favorites and play history

### Listening Stats Overhaul
- **Dashboard** — top tracks, top stations, top albums, day-of-week distribution, room usage, listening streaks
- **Quick stats pills** — current streak, best streak, avg plays/day, unique albums, unique stations
- **Card-based history** — timeline view grouped by day with album art, metadata pills, context menus
- **Custom date range** filter with From/To date pickers
- **SQL-based filtering** — handles 50,000+ entries with instant search (debounced 300ms)
- **Service tags** — show streaming service name (Sonos Radio, TuneIn, Spotify) instead of station name

### Artwork System Rebuild
- **Single DIDL parser** — TrackMetadata.enrichFromDIDL consolidates 4 duplicate parsing paths
- **Ad break detection** — shows station art during radio ads, resumes track art when music returns
- **Station change tracking** — clears stale art when switching stations, captures new station art from metadata
- **Smart search** — strips parentheses, track suffixes (End Titles, Main Theme, Suite), handles unclosed parentheses
- **Art caching** — discovered art shared across main player, menu bar, and history views

### Star / Favorite Tracks
- **Star any track** — star button in Now Playing and menu bar mini player
- **Toggle on/off** — tap to star, tap again to unstar
- **Starred filter** — filter play history to show only starred tracks
- **Dashboard integration** — starred count shown in quick stats pills
- **Persisted** — stars stored in SQLite alongside play history

### Menu Bar Redesign
- **Hero art area** — blurred album art background with track info overlay
- **Room picker** — green/gray dots showing playing status per zone
- **Star button** — star/unstar the currently playing track
- **Mute button** — speaker icon toggles mute for all group members
- **Volume readout** — numeric display alongside slider
- **Proportional scaling** — uses same linear/proportional mode as main player
- **Accent color** — inherits custom accent from main app settings
- **Resolved artwork** — uses discovered art cache, not just raw metadata

### Architecture & Quality
- **11 service protocols** (ISP) — PlaybackService, VolumeService, EQService, QueueService, BrowsingService, GroupingService, AlarmService, MusicServiceDetection, TransportStateProviding, ArtCache
- **ViewModels use protocol types** — NowPlayingServices, BrowsingServices, QueueServices
- **Encapsulated state mutations** — updateTransportState, updateDeviceVolume, updatePlayMode etc.
- **100 unit tests** covering metadata enrichment, URI detection, art resolution, state mutations, grace periods, protocol conformance
- **App sandbox** enabled with minimal entitlements
- **Universal binary** — native arm64 + x86_64 (Apple Silicon + Intel)
- **Keychain security** — kSecAttrAccessibleWhenUnlockedThisDeviceOnly with error checking

### Performance
- **Removed duplicate polling** — NowPlayingViewModel no longer duplicates TransportStrategy's SOAP calls
- **@Published change guards** — dictionary writes only trigger SwiftUI updates when values actually change
- **Dashboard stats cached** — computed once in @State, not per-body evaluation
- **Position timer** — 1s interval with 0.5s change threshold to minimize re-renders

### Bug Fixes
- Radio station name preserved on pause
- Queue artwork for local library tracks via /getaa fallback
- History dedup uses track duration for window (no more duplicates for long songs)
- RINCON device IDs filtered from all metadata paths
- Volume/mute correctly syncs on zone switch (grace periods cleared, live fetch)
- Filter tags wrap with FlowLayout instead of hidden scroll
- Time display fixed height (no layout shift on play/pause)

## Features

### Playback Control
- Play, pause, stop, skip forward/back, seek
- Shuffle and repeat (off / all / one) with Classic Shuffle toggle
- Crossfade toggle
- Pause all / Resume all from toolbar menu
- Optimistic UI with grace period system
- Playback transition feedback with loading spinner

### Now Playing
- Album art with multi-strategy resolution (DIDL, /getaa, iTunes Search)
- Radio track art from iTunes with station badge overlay
- Station name displayed above track info for streaming sources
- TV and Line-In source detection
- Service tag showing source (Apple Music, Spotify, TuneIn, etc.)
- Copy track info to clipboard
- Draggable seek slider with smooth interpolation

### Volume
- Master slider adjusts all speakers (proportional or linear mode)
- Individual per-speaker volume sliders with drag protection
- Mute toggle per speaker and master
- Bass, treble, loudness controls (EQ panel)
- Home Theater EQ with Sub and Surround controls

### Speaker Management
- Automatic SSDP discovery
- Zone grouping with group editor
- Group presets with per-speaker volumes and EQ
- Bonded speakers (soundbar + sub + surrounds) shown as single room
- Sidebar with playing status indicators and context menus
- Restore last selected zone across restarts

### Browse & Library
- Sonos Favorites with service filter
- Music Library browsing (NAS/server) with pagination
- Recently played quick-access list
- Music Services browsing via SMAPI (TuneIn, Spotify, etc.)
- Search across artists, albums, and tracks
- Play now, play next, add to queue from context menu
- Drag tracks from browse to queue

### Queue
- View, reorder, and manage the play queue
- Tap to jump, drag to reorder, right-click to remove
- Queue shuffle (physical reorder)
- Save queue as Sonos playlist

### Play History
- Dashboard with charts: listening activity, peak hours, top artists/tracks/stations/albums, day-of-week, room usage
- Listening streaks (current + best)
- Card-based timeline grouped by day
- Star/favorite tracks with starred filter
- Search, date range, room, and source filters
- Export to CSV
- Right-click: copy details, filter by artist/room/source

### Menu Bar Mode
- Hero art area with blurred background
- Transport controls, volume slider with mute
- Star button for current track
- Room picker with playing status dots
- Inherits accent color from main app

### Settings
- Startup mode (Quick Start / Classic)
- Communication mode (Event-Driven / Legacy Polling)
- Appearance (System / Light / Dark)
- Accent color, zone icon colors
- Proportional Group Volume toggle
- Classic Shuffle toggle
- Music Services management with setup guide
- Image cache controls (size, age)
- 13 languages

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

- **SonosController** — SwiftUI app (26 view files, 4 ViewModels)
- **SonosKit** — local Swift package (networking, protocols, models, caching, events, localization, services)
- **21,000+ lines of Swift** across 80 source files
- **100 unit tests**
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

- **Apple Music** — blocks third-party AppLink auth (use via Sonos Favorites)
- **Add to Favorites** — requires the official Sonos app (UPnP CreateObject not supported)
- **Alarms** — Sonos S2 uses cloud API; UPnP AlarmClock returns empty
- **SMAPI serial number** — discovered from existing favorites/history; new services need one favorite added via Sonos app

## License

MIT License — Copyright (c) 2026

## Disclaimer

This project is not affiliated with, endorsed by, or connected to Sonos, Inc. "Sonos" is a trademark of Sonos, Inc. This software is an independent, fan-built controller that communicates with Sonos hardware using standard UPnP protocols. Use at your own risk.
