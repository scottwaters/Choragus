# Architecture

Full source documentation for SonosController.

## Project Structure

```
SonosController/
├── SonosController.xcodeproj        # Xcode project file
├── README.md                        # Project overview
├── LICENSE                          # MIT License
├── .gitignore
├── docs/
│   ├── ARCHITECTURE.md              # This file
│   ├── PROTOCOLS.md                 # UPnP/SOAP protocol reference
│   └── CACHING.md                   # Caching system documentation
│
├── SonosController/                 # SwiftUI App Target
│   ├── SonosControllerApp.swift
│   ├── Info.plist
│   ├── SonosController.entitlements
│   ├── Assets.xcassets/
│   ├── MenuBarController.swift      # Menu bar icon and dropdown controls
│   ├── WindowManager.swift          # AppKit-based window management
│   └── Views/
│       ├── ContentView.swift
│       ├── RoomListView.swift
│       ├── NowPlayingView.swift
│       ├── QueueView.swift
│       ├── BrowseView.swift
│       ├── GroupEditorView.swift
│       ├── VolumeControlView.swift
│       ├── EQView.swift
│       ├── HomeTheaterEQView.swift  # Home theater EQ/Sub/Surrounds window
│       ├── AlarmsView.swift
│       ├── SleepTimerView.swift
│       ├── SettingsView.swift
│       ├── RecentlyPlayedView.swift # Recently played stations/tracks
│       ├── CachedAsyncImage.swift
│       ├── MarqueeText.swift        # Auto-scrolling text for long names
│       └── HoverTooltip.swift       # Custom tooltip replacing .help()
│
└── Packages/SonosKit/               # Local Swift Package
    ├── Package.swift
    ├── Sources/SonosKit/
    │   ├── SonosManager.swift
    │   ├── SonosConstants.swift     # URI prefixes, service IDs, colors, timing, paths
    │   ├── Discovery/
    │   │   └── SSDPDiscovery.swift
    │   ├── Models/
    │   │   ├── SonosDevice.swift
    │   │   ├── SonosGroup.swift
    │   │   ├── HomeTheaterZone.swift # Home theater topology (soundbar/sub/surrounds)
    │   │   ├── GroupPreset.swift     # Saved group preset with per-speaker volumes
    │   │   ├── PlayHistoryEntry.swift # Play history entry with metadata
    │   │   ├── TransportState.swift
    │   │   ├── TrackMetadata.swift
    │   │   ├── PlayMode.swift
    │   │   └── BrowseItem.swift
    │   ├── Managers/
    │   │   ├── PresetManager.swift          # Save/load/apply group presets
    │   │   ├── PlayHistoryManager.swift     # Track play history, stats, CSV export
    │   │   └── PlaylistServiceScanner.swift # Background playlist service badge scanning
    │   ├── UPnP/
    │   │   ├── SOAPClient.swift
    │   │   ├── XMLResponseParser.swift
    │   │   ├── BrowseXMLParser.swift
    │   │   └── DeviceDescriptionParser.swift
    │   ├── Services/
    │   │   ├── AVTransportService.swift
    │   │   ├── RenderingControlService.swift
    │   │   ├── ZoneGroupTopologyService.swift
    │   │   ├── ContentDirectoryService.swift
    │   │   ├── AlarmClockService.swift
    │   │   └── MusicServicesService.swift
    │   └── Cache/
    │       ├── SonosCache.swift
    │       ├── ImageCache.swift
    │       └── StaleDataError.swift
    └── Tests/SonosKitTests/
        └── SonosKitTests.swift
```

## App Target: SonosController

The SwiftUI app layer. Contains views and the app entry point. All business logic lives in SonosKit.

### SonosControllerApp.swift

Entry point. Creates the `SonosManager` as a `@StateObject` and injects it into the view hierarchy via `@EnvironmentObject`. Starts speaker discovery on appear. Initializes `MenuBarController` and `WindowManager` for menu bar mode and AppKit-based window management.

### MenuBarController.swift

Manages the optional menu bar icon and its dropdown. Creates an `NSStatusItem` with a speaker icon. The dropdown provides quick playback controls (play/pause, next, previous), volume adjustment, and current track info without needing to bring the main window to the front.

### WindowManager.swift

AppKit-based window management replacing SwiftUI `Window` scenes to avoid menu bar flicker issues. Handles creation and lifecycle of auxiliary windows (play history stats, home theater EQ). Windows are created as `NSWindow` instances hosting SwiftUI views.

### Views

#### ContentView.swift
Main layout using `NavigationSplitView` (sidebar) + `HSplitView` (detail area). The detail area has three panels:
- **Left (optional):** Browse panel — toggled via toolbar grid icon
- **Center:** Now Playing — always visible when a room is selected
- **Right (optional):** Queue panel — toggled via toolbar list icon

Also renders:
- Stale data warning banner (orange) when a cached device is unreachable
- Cache status banner (blue) when using cached data on startup
- Toolbar buttons: Browse, Queue, Alarms, Group Presets, Play History, Refresh, Settings

#### RoomListView.swift
Sidebar list of Sonos zones/groups. Each row shows the group name, speaker icon (single vs. multi), and speaker count. Binds selection to `selectedGroupID`. Animated sound wave indicators pulse on playing rooms. Context menu on each room provides play/pause, mute, group editor, ungroup, and home theater EQ options. Restores last selected zone on startup.

#### NowPlayingView.swift
The main playback control view. Contains:
- **Album art** — uses `CachedAsyncImage` with disk/memory caching
- **Track info** — title, artist, album with `MarqueeText` for long names
- **Service tag** — shows source (Apple Music, Music Library, etc.) below album name
- **Progress bar** — linear progress with position/duration timestamps
- **Transport controls** — shuffle, previous, play/pause, next, repeat, crossfade. Each button uses `transportButton()` which shows a spinner overlay during network round-trips and dims the icon. Custom `HoverTooltip` on each control.
- **Volume slider** — master volume for the group coordinator
- **Per-speaker volume** — shown when the group has multiple visible members
- **Action buttons** — Group, Sleep, EQ

**Optimistic UI system:**
- Play/pause, shuffle, repeat, crossfade, mute all flip their state immediately on tap
- A grace period (`transportGraceUntil`, `volumeGraceUntil`, etc.) prevents the 2-second polling cycle from overwriting the optimistic state with stale data from the speaker
- Grace lasts 5 seconds or until the speaker confirms the new state, whichever comes first
- Polling is skipped entirely while an action is in flight

#### QueueView.swift
Displays the play queue fetched via `ContentDirectoryService.browseQueue()`. Shows track title, artist, duration, and cached album art. Current track is highlighted. Supports:
- Tap to play a track
- Right-click to remove
- Drag-drop reordering with visual drop position indicator
- Accept drops from browse panel to insert tracks at any position
- Clear queue button
- Refresh on group change

#### BrowseView.swift
Hierarchical content browser using `NavigationStack` with a path-based `navigationDestination`. Structure:
- **BrowseSectionsView** — top level showing dynamically discovered sections (Favorites, Playlists, Artists, Albums, etc.)
- **BrowseListView** — generic list view for any browse level. Handles containers (navigate deeper via `NavigationLink`) and leaf items (play on tap via `onTapGesture`). Tracks are draggable to the queue panel.
- **BrowseItemRow** — row component with cached album art, title, subtitle, and chevron for containers. Playlists show per-track service badges from the playlist services cache.

Items marked `requiresService` (no playable URI, like artist shortcuts from SMAPI) are shown dimmed with "Requires Sonos app" label and are not tappable.

Search submits a query that searches across artists, albums, and tracks concurrently.

#### GroupEditorView.swift
Sheet for adding/removing speakers from a group. Shows all visible (non-bonded) speakers with checkmarks. Tapping toggles membership via `joinGroup()` / `ungroupDevice()`. The group coordinator cannot be removed.

#### VolumeControlView.swift
Per-speaker volume sliders shown below the main volume when a group has multiple members. Each speaker gets its own slider and mute button.

#### EQView.swift
Popover with bass (-10 to +10), treble (-10 to +10) sliders and loudness toggle for a single speaker. When the selected zone is a group, shows a speaker picker to choose which speaker's EQ to adjust.

#### HomeTheaterEQView.swift
Dedicated window for home theater (soundbar + sub + surround) configurations. Auto-detected from HTSatChanMapSet in zone topology. Three tabs:
- **EQ** — bass, treble, loudness for the soundbar
- **Sub** — sub on/off, sub level, sub crossover frequency
- **Surrounds** — surround on/off, surround level, music playback mode (Full/Ambient)

Also includes night mode toggle and dialog enhancement toggle. Accessible from sidebar context menu on home theater zones.

#### AlarmsView.swift
Popover listing all Sonos alarms with time, recurrence, room name. Toggle switches enable/disable. Right-click to delete.

#### SleepTimerView.swift
Sheet with preset duration buttons (15m–2h). Shows remaining time when active. Cancel button.

#### RecentlyPlayedView.swift
Quick-access list of recently played stations and tracks, displayed in the browse panel. Shows album art, track name, artist, and how long ago it was played. Tapping an entry starts playback of that item.

#### SettingsView.swift
Sheet with sections for:
- **Startup Mode** — segmented picker for Quick Start (cached) vs. Classic (live discovery)
- **Communications Mode** — Event-Driven vs. Legacy Polling
- **Appearance** — theme, accent color, zone icon colors
- **Play History** — enable/disable tracking, clear history with confirmation dialog
- **Menu Bar** — enable/disable menu bar mode
- **Cache Status** — shows live/cached indicator, cache age, and buttons to clear speaker cache and artwork cache separately. Artwork cache shows current disk usage.

Consistent padding and layout with confirmation dialogs for destructive actions.

#### CachedAsyncImage.swift
Drop-in replacement for SwiftUI's `AsyncImage` that checks `ImageCache.shared` before fetching. On cache miss, downloads the image, stores it in both memory and disk caches, then displays it. Shows a placeholder (rounded rectangle with music note icon) while loading or on failure.

#### MarqueeText.swift
Auto-scrolling text view for long track and artist names that don't fit in the available width. Text scrolls horizontally with a pause at start and end positions. Falls back to static text when the content fits.

#### HoverTooltip.swift
Custom tooltip view modifier that displays a tooltip on mouse hover. Replaces SwiftUI's `.help()` modifier which is unreliable on some controls. Shows a styled tooltip with configurable text after a short hover delay.

---

## Package: SonosKit

The networking, protocol, and model layer. Zero external dependencies. Targets macOS 14+.

### SonosManager.swift

The top-level coordinator. `@MainActor`, `ObservableObject`. Owns all services, the SSDP discovery instance, and published state:

**Published properties:**
- `groups: [SonosGroup]` — discovered zone groups
- `devices: [String: SonosDevice]` — all known devices keyed by UUID
- `isDiscovering: Bool` — whether discovery is active
- `browseSections: [BrowseSection]` — dynamically discovered browse categories
- `isUsingCachedData: Bool` — whether the UI shows cached vs. live data
- `cacheAge: String` — human-readable age of cached data
- `isRefreshing: Bool` — whether a background refresh is in progress
- `staleMessage: String?` — warning message shown when a cached device is unreachable
- `startupMode: StartupMode` — Quick Start or Classic, persisted to UserDefaults

**Startup flow:**
1. If Quick Start mode and cache exists: restore cached devices, groups, and browse sections immediately. Set `isUsingCachedData = true`.
2. Start SSDP discovery regardless of cache.
3. When first device responds: fetch zone topology, which updates `groups` and `devices` with live data. Set `isUsingCachedData = false`. Save new cache.

**Stale data handling:**
`withStaleHandling()` wraps SOAP calls. On network error or SOAP fault 701, it sets `staleMessage` and triggers `rescan()`. The UI shows an orange banner that auto-dismisses when fresh data arrives.

**`preferredDevice`:** Returns the first group's coordinator rather than an arbitrary device from the dictionary. This ensures SOAP calls go to a full speaker (never a sub or satellite).

**Key methods:**
- `startDiscovery()` / `stopDiscovery()` / `rescan()`
- `play/pause/stop/next/previous/seek(group:)` — all route to coordinator
- `getTransportState/getPositionInfo/getPlayMode(group:)` — polling targets
- `setVolume/getMute/setBass/setTreble/setLoudness(device:)` — per-speaker
- `getQueue/removeFromQueue/clearQueue/playTrackFromQueue/moveTrackInQueue(group:)`
- `joinGroup/ungroupDevice` — grouping with topology refresh
- `browse/search` — content directory navigation
- `playBrowseItem/addBrowseItemToQueue` — plays favorites, tracks, or containers
- `loadBrowseSections()` — probes the system for available content categories
- `getAlarms/updateAlarm/deleteAlarm`

### Discovery/SSDPDiscovery.swift

UDP multicast speaker discovery using BSD sockets (Darwin). Sends M-SEARCH to `239.255.255.250:1900` for `urn:schemas-upnp-org:device:ZonePlayer:1`. Parses HTTP-like responses to extract `LOCATION` header (device description URL).

Runs a receive loop on a background `DispatchQueue`. Filters responses for "ZonePlayer" or "Sonos" to ignore non-Sonos UPnP devices.

`rescan()` re-sends the M-SEARCH without recreating the socket. Called every 30 seconds by a timer in SonosManager.

### SonosConstants.swift

Centralized constants file containing:
- **URIPrefix** — URI prefix patterns for service identification (x-rincon-cpcontainer, x-sonosapi-stream, etc.)
- **ServiceID** — numeric service IDs for streaming services (Spotify = 9, Apple Music = 204, TuneIn = 254, etc.)
- **RINCONService** — SA_RINCON descriptor mappings for service identification
- **ServiceColor** — SwiftUI color definitions for each service badge
- **Timing** — grace period durations, polling intervals, debounce delays
- **AppPaths** — centralized Application Support directory paths replacing duplicated init code

### Models

#### SonosDevice.swift
`Identifiable`, `Hashable`. Represents one speaker. Fields: `id` (UUID like RINCON_xxxx), `ip`, `port`, `roomName`, `modelName`, `modelNumber`, `isCoordinator`, `groupID`. Computed `baseURL` for SOAP calls.

#### SonosGroup.swift
`Identifiable`, `Hashable`. Represents a zone group. Fields: `id`, `coordinatorID`, `members: [SonosDevice]`. Computed `coordinator` (first member matching coordinatorID) and `name` (single room name or "Room1 + Room2" for groups).

#### HomeTheaterZone.swift
Represents a home theater configuration parsed from `HTSatChanMapSet` in the zone topology XML. Fields: `soundbarID`, `subID`, `surroundIDs`, `channelMap`. Used to detect 5.1/sub setups and enable the home theater EQ window. Computed `hasSubwoofer` and `hasSurrounds`.

#### GroupPreset.swift
`Codable`. Represents a saved speaker group configuration. Fields: `id`, `name`, `coordinatorID`, `memberIDs: [String]`, `volumes: [String: Int]` (per-speaker volume map). Stored as JSON array via `PresetManager`.

#### PlayHistoryEntry.swift
`Codable`. Represents a single play history record. Fields: `id`, `timestamp`, `title`, `artist`, `album`, `albumArtURI`, `source` (service name), `roomName`, `duration`. Used by `PlayHistoryManager` for tracking and stats.

#### TransportState.swift
Enum: `playing`, `paused`, `stopped`, `transitioning`, `noMedia`. Raw values match Sonos SOAP responses. Computed `isPlaying`.

#### TrackMetadata.swift
Current track info: `title`, `artist`, `album`, `albumArtURI`, `duration`, `position`, `trackNumber`, `queueSize`. Helper methods for time formatting and `parseTimeString()` for HH:MM:SS parsing.

#### PlayMode.swift
Enum with 6 cases: `normal`, `repeatAll`, `repeatOne`, `shuffleNoRepeat`, `shuffle`, `shuffleRepeatOne`. Computed `isShuffled`, `repeatMode`. State machine methods `togglingShuffle()` and `cyclingRepeat()` return the next mode in sequence.

#### BrowseItem.swift
Represents a browsable content item. Fields: `id` (objectID), `title`, `artist`, `album`, `albumArtURI`, `itemClass`, `resourceURI`, `resourceMetadata`. Computed `isContainer`, `isPlayable`, `requiresService`.

`BrowseItemClass` enum classifies UPnP items: `container`, `musicTrack`, `musicAlbum`, `musicArtist`, `genre`, `playlist`, `favorite`, `radioStation`, `radioShow`, `unknown`. Each has `isContainer` and `systemImage` properties. `from(upnpClass:)` maps UPnP class strings to enum cases.

`BrowseSection` is a top-level browse category with `id`, `title`, `objectID`, and `icon`.

### Managers

#### PresetManager.swift
Manages saved group presets. Persists presets to `~/Library/Application Support/SonosController/group_presets.json`. Methods: `save(preset:)`, `load()`, `delete(id:)`, `apply(preset:manager:)`. Applying a preset ungroups all speakers, forms the saved group, and sets per-speaker volumes.

#### PlayHistoryManager.swift
Tracks play history with automatic deduplication (same track within a time window is not re-recorded). Persists to `~/Library/Application Support/SonosController/play_history.json`. Provides stats (top artists, top tracks, top sources, total play count) and CSV export. Filterable by room and service. Toggle on/off via Settings. Supports right-click copy of track details.

#### PlaylistServiceScanner.swift
Background scanner that determines which streaming service each track in a Sonos playlist belongs to. Browses playlist tracks via ContentDirectory, extracts service from URI pattern and SID metadata. Results cached to `~/Library/Application Support/SonosController/playlist_services_cache.json`. Scans one playlist at a time to limit network load. Results populate service badges in the browse list.

### UPnP

#### SOAPClient.swift
Builds SOAP envelopes and sends HTTP POST requests to Sonos speakers. Takes `baseURL`, `path`, `service`, `action`, and `arguments`. Returns parsed response as `[String: String]`.

Handles HTTP 500 as SOAP fault — extracts `errorCode` and `faultstring`. Defines `SOAPError` enum with cases for invalid URL, HTTP errors, network errors, parse errors, and SOAP faults.

XML-escapes argument values (`&`, `<`, `>`, `"`, `'`).

#### XMLResponseParser.swift
Central XML parsing utilities. All use Foundation's `XMLParser` (SAX-based).

- `parseActionResponse()` — extracts leaf element text values from SOAP responses
- `parseFault()` — extracts `errorCode` and `faultstring` from SOAP faults
- `parseDeviceDescription()` — extracts UDN, roomName, modelName from device XML
- `parseZoneGroupState()` — parses the zone group topology XML, handling the double-encoded XML-in-XML structure. Extracts `ZoneGroup` and `ZoneGroupMember` attributes including `Invisible` flag for bonded speakers.
- `parseDIDLMetadata()` — parses DIDL-Lite XML for track metadata (title, creator, album, albumArtURI)

**Important:** The SOAP SAX parser unescapes XML entities in element text. DIDL-Lite content within `Result` elements arrives already unescaped by the SAX parser. The DIDL parsers do NOT call `xmlUnescape()` again — doing so would corrupt `&amp;` in URLs and break XML parsing.

#### BrowseXMLParser.swift
Parses DIDL-Lite XML from ContentDirectory Browse results. Handles both `<item>` and `<container>` elements. Strips namespace prefixes from element names.

Special handling for `<r:resMD>`: this element contains escaped DIDL-Lite XML (metadata for favorites playback). Since the SAX parser would descend into the unescaped nested XML, `resMD` content is pre-extracted via regex before SAX parsing and stored in a lookup map by item ID.

#### DeviceDescriptionParser.swift
Fetches and parses `/xml/device_description.xml` from a speaker URL. Returns `DeviceDescription` with UUID, room name, model info.

### Services

Each service wraps SOAP calls to a specific Sonos UPnP service endpoint.

#### AVTransportService.swift
Control URL: `/MediaRenderer/AVTransport/Control`

Actions: `Play`, `Pause`, `Stop`, `Next`, `Previous`, `Seek` (by time or track number), `GetTransportInfo`, `GetPositionInfo`, `GetMediaInfo`, `GetTransportSettings`, `SetPlayMode`, `ConfigureSleepTimer`, `GetRemainingSleepTimerDuration`, `SetAVTransportURI`, `BecomeCoordinatorOfStandaloneGroup`.

`getPositionInfo()` parses DIDL-Lite track metadata and resolves relative album art URIs to absolute URLs using the speaker's IP.

#### RenderingControlService.swift
Control URL: `/MediaRenderer/RenderingControl/Control`

Actions: `GetVolume`/`SetVolume`, `GetMute`/`SetMute`, `GetBass`/`SetBass`, `GetTreble`/`SetTreble`, `GetLoudness`/`SetLoudness`. All use `InstanceID: 0`, `Channel: Master`. Volume clamped to 0–100, bass/treble clamped to -10–+10.

#### ZoneGroupTopologyService.swift
Control URL: `/ZoneGroupTopology/Control`

Single action: `GetZoneGroupState`. Returns XML describing all zone groups, their coordinators, and members. Delegates parsing to `XMLResponseParser.parseZoneGroupState()`.

#### ContentDirectoryService.swift
Control URL: `/MediaServer/ContentDirectory/Control`

Actions:
- `Browse` — generic hierarchical content browsing by ObjectID. Used for Favorites (`FV:2`), Playlists (`SQ:`), Library (`A:*`), Shares (`S:`), Radio (`R:0`), and Queue (`Q:0`).
- `Search` — library search using Sonos's ObjectID-based search syntax (`A:TRACKS:searchterm`).
- `AddURIToQueue` — adds a track or container to the play queue.
- `RemoveTrackFromQueue` / `RemoveAllTracksFromQueue`
- `ReorderTracksInQueue`
- `Seek` (by track number) — used for queue track jumping.

Also contains `QueueXMLParser` for parsing queue-specific DIDL results with track numbering.

#### AlarmClockService.swift
Control URL: `/AlarmClock/Control`

Actions: `ListAlarms`, `CreateAlarm`, `UpdateAlarm`, `DestroyAlarm`. Parses alarm XML attributes (ID, StartTime, Duration, Recurrence, Enabled, RoomUUID, Volume, etc.).

`SonosAlarm` model includes display helpers: `displayTime` (12-hour format) and `recurrenceDisplay` (human-readable schedule).

#### MusicServicesService.swift
Control URL: `/MusicServices/Control`

Single action: `ListAvailableServices`. Returns all streaming services available on the Sonos platform. Parses `Service` elements with ID, Name, URI attributes.

### Cache

#### SonosCache.swift
JSON-based disk cache for speaker topology and browse sections. Stores in `~/Library/Application Support/SonosController/topology_cache.json`.

`CachedTopology` is `Codable` and contains: `groups`, `devices`, `browseSections`, `timestamp`. Provides `age` and `ageDescription` computed properties.

Methods: `save()`, `load()`, `clear()`, `restoreDevices()`, `restoreGroups()`, `restoreBrowseSections()`.

#### ImageCache.swift
Two-tier album artwork cache. Singleton via `ImageCache.shared`.

**Memory tier:** `NSCache` with 200 item limit and 50 MB cost limit. Instant access for recently viewed art.

**Disk tier:** JPEG files (80% compression) in `~/Library/Application Support/SonosController/ImageCache/`. 200 MB limit with LRU eviction — oldest-accessed files are removed first when the limit is exceeded. File modification date is updated on each read to track access recency.

Cache key: deterministic hash of the URL string.

Methods: `image(for:)`, `store(_:for:)`, `clearDisk()`, `clearMemory()`, `diskUsage`, `diskUsageString`, `evictIfNeeded()`.

#### StaleDataError.swift
Error types for cache staleness: `deviceUnreachable(roomName)`, `groupChanged(groupName)`, `topologyStale`. Each provides a user-facing `errorDescription` used in the warning banner.

### Tests

#### SonosKitTests.swift
Unit tests for:
- Zone group topology XML parsing (multi-group, multi-member)
- DIDL-Lite metadata parsing (title, creator, album)
- Time string parsing (HH:MM:SS to TimeInterval)
- TransportState enum mapping and `isPlaying`
