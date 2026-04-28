# Architecture

Full source documentation for Choragus.

## Project Structure

```
Choragus/
├── Choragus.xcodeproj               # Xcode project file
├── README.md                        # End-user overview
├── technical_readme.md              # Developer overview (entry point to docs/)
├── Setupguide.md                    # Plain-language onboarding for non-technical users
├── CHANGELOG.md                     # Per-release history
├── LICENSE                          # MIT License
├── .gitignore
├── docs/
│   ├── ARCHITECTURE.md              # This file — module-by-module breakdown
│   ├── PROTOCOLS.md                 # UPnP/SOAP/SMAPI protocol reference
│   ├── CACHING.md                   # Caching system documentation
│   ├── DISCOVERY.md                 # Discovery modes (Auto / Bonjour / Legacy Multicast)
│   ├── LOCALIZATION.md              # 13-locale architecture and conventions
│   └── SERVICES.md                  # Music-service status matrix
│
├── Choragus/                        # SwiftUI App Target
│   ├── ChoragusApp.swift
│   ├── Info.plist
│   ├── Choragus.entitlements
│   ├── Assets.xcassets/
│   ├── MenuBarController.swift      # Menu bar icon, mini-player, room picker
│   ├── WindowManager.swift          # AppKit window lifecycle for help/about/stats/HT EQ
│   └── Views/
│       ├── AccentColorHelper.swift          # Resolves user accent colour with system fallback
│       ├── AlarmsView.swift
│       ├── ArtworkSearchView.swift          # Manual artwork search dialog (iTunes Search)
│       ├── BrowseView.swift                 # Hierarchical content browser
│       ├── CachedAsyncImage.swift           # Drop-in AsyncImage backed by ImageCache
│       ├── ColorSwatchGrid.swift            # Grid picker for accent / zone colours
│       ├── ContentView.swift                # Main split layout
│       ├── EQView.swift                     # Bass / treble / loudness popover
│       ├── FirstRunWelcomeView.swift        # First-launch language + Sonos-app hint
│       ├── ForFunView.swift                 # Visualisation experiments — paused in v4.0
│       ├── GroupEditorView.swift            # Add/remove speakers from a group
│       ├── HelpView.swift                   # In-app Help (10 topics, full body localised)
│       ├── HomeTheaterEQView.swift          # Soundbar + Sub + Surrounds EQ window
│       ├── HoverTooltip.swift               # Reliable replacement for SwiftUI .help()
│       ├── LineInBrowseView.swift           # Browse Line-In sources across speakers
│       ├── MarqueeText.swift                # Auto-scrolling marquee for long names
│       ├── MenuBarController.swift          # Menu-bar mini player
│       ├── MusicServicesView.swift          # SMAPI setup, Connect / Disconnect, status dots
│       ├── NowPlayingContextPanel.swift     # Bottom tabbed panel — Lyrics / About / History
│       ├── NowPlayingView.swift             # Album art, transport, volume, star, action buttons
│       ├── PlayHistoryDashboard.swift       # Stats hero cards, charts, quick pills
│       ├── PlayHistoryView.swift            # Listening Stats container (Dashboard + Timeline)
│       ├── PlayHistoryView2.swift           # Card-based timeline grouped by day
│       ├── PlexDirectBrowseView.swift       # Plex AppLink browse drill-down
│       ├── PresetManagerView.swift          # Group preset CRUD + EQ editor
│       ├── QueueView.swift
│       ├── RecentlyPlayedView.swift
│       ├── RoomListView.swift               # Sidebar with household sections
│       ├── ScrollWheelCapture.swift         # NSEvent monitor for scroll-wheel volume
│       ├── SettingsScrobblingTab.swift      # Last.fm scrobbling tab content
│       ├── SettingsView.swift               # Settings sheet — 12 sections (see below)
│       ├── SleepTimerView.swift
│       ├── SliderPopup.swift                # Reusable slider popover
│       ├── SonosRadioSearchView.swift       # Anonymous Sonos Radio search drill-down
│       ├── UpdateChecker.swift              # GitHub /releases/latest poller
│       ├── VolumeControlView.swift          # Per-speaker volume sliders
│       └── WindowManager.swift              # Auxiliary-window factory
│
└── Packages/SonosKit/               # Local Swift Package
    ├── Package.swift
    ├── Sources/SonosKit/
    │   ├── SonosManager.swift            # Top-level @MainActor coordinator
    │   ├── SonosConstants.swift          # URIPrefix, ServiceID (incl. pandora=3), colours, timing, paths
    │   ├── AppError.swift / ErrorHandler.swift
    │   ├── Protocols.swift               # ISP service protocols (Playback, Volume, EQ, ...)
    │   ├── PresetManager.swift / PlayHistoryManager.swift / PlayHistoryRepository.swift
    │   ├── Discovery/
    │   │   ├── SpeakerDiscovery.swift    # Protocol abstraction over discovery transports
    │   │   ├── SSDPDiscovery.swift       # UDP multicast (239.255.255.250:1900)
    │   │   └── MDNSDiscovery.swift       # NWBrowser-backed _sonos._tcp Bonjour transport
    │   ├── Events/                       # GENA subscription + transport state events
    │   ├── Localization/
    │   │   └── L10n.swift                # 13-locale dictionary, ~1000+ keys, dup-key gate
    │   ├── Managers/
    │   │   └── PlaylistServiceScanner.swift
    │   ├── Models/
    │   │   ├── SonosDevice.swift / SonosGroup.swift
    │   │   ├── SonosSystemVersion.swift  # S1 vs S2 classifier
    │   │   ├── HomeTheaterZone.swift
    │   │   ├── GroupPreset.swift
    │   │   ├── PlayHistoryEntry.swift
    │   │   ├── TransportState.swift / TrackMetadata.swift / PlayMode.swift
    │   │   └── BrowseItem.swift
    │   ├── UPnP/
    │   │   ├── SOAPClient.swift / XMLResponseParser.swift
    │   │   ├── BrowseXMLParser.swift / DeviceDescriptionParser.swift
    │   ├── Services/
    │   │   ├── AVTransportService.swift / RenderingControlService.swift
    │   │   ├── ZoneGroupTopologyService.swift / ContentDirectoryService.swift
    │   │   ├── AlarmClockService.swift / MusicServicesService.swift
    │   │   ├── SMAPIClient.swift / SMAPIAuthManager.swift / SMAPITokenStore.swift
    │   │   ├── PlexDirectClient.swift
    │   │   ├── LyricsService.swift                 # LRCLIB synced + plain lyrics
    │   │   ├── MusicMetadataService.swift          # Wikipedia + MusicBrainz + Last.fm bios
    │   │   ├── MetadataCacheRepository.swift       # SQLite cache w/ language-prefixed keys
    │   │   ├── LastFMClient.swift / LastFMTokenStore.swift
    │   │   ├── AlbumArtSearchService.swift         # iTunes Search fallback
    │   │   ├── ArtCacheService.swift               # Persistent art-URL cache
    │   │   ├── ITunesRateLimiter.swift
    │   │   ├── ServiceSearchProvider.swift         # Apple Music / Sonos Radio / Calm Radio
    │   │   ├── LocalNetworkPermissionMonitor.swift # Local Network entitlement watch
    │   │   └── SecretsStore.swift                  # Unified Keychain item, Choragus service
    │   └── Cache/
    │       ├── SonosCache.swift                    # Topology + browse-section JSON
    │       ├── ImageCache.swift                    # Two-tier NSCache + JPEG disk
    │       └── StaleDataError.swift
    └── Tests/SonosKitTests/                        # Classifier, XML, equality, locale tests
```

The Views layer is intentionally flat (no per-feature subfolders) because most views are top-level scenes; deeper folders haven't paid off yet.

## App Target: Choragus

The SwiftUI app layer. Contains views and the app entry point. All business logic lives in SonosKit.

### ChoragusApp.swift

Entry point. Creates the `SonosManager` as a `@StateObject` and injects it into the view hierarchy via `@EnvironmentObject`. Starts speaker discovery on appear. Initializes `MenuBarController` and `WindowManager` for menu bar mode and AppKit-based window management. Window title is "Choragus".

### MenuBarController.swift

Manages the optional menu bar icon and its dropdown. Creates an `NSStatusItem` with a speaker icon. The dropdown provides quick playback controls (play/pause, next, previous), volume adjustment, star button for the current track, and current track info without needing to bring the main window to the front.

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
- Toolbar buttons: Browse, Queue, Group Presets, Play History, Refresh, Settings

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
- **Star button** — star/unstar the currently playing track (persisted in play history)
- **Action buttons** — Group, Sleep, EQ
- **Bottom context panel** — `NowPlayingContextPanel` is hosted at the bottom of the view as a collapsible section. The collapse state persists in `UserDefaults[nowPlayingDetails.collapsed]`.

**Optimistic UI system:**
- Play/pause, shuffle, repeat, crossfade, mute all flip their state immediately on tap
- A grace period (`transportGraceUntil`, `volumeGraceUntil`, etc.) prevents the 2-second polling cycle from overwriting the optimistic state with stale data from the speaker
- Grace lasts 5 seconds or until the speaker confirms the new state, whichever comes first
- Polling is skipped entirely while an action is in flight

#### NowPlayingContextPanel.swift
Tabbed details panel (`TabView` with segmented `Picker` style) shown below the transport controls when the panel isn't collapsed. Three tabs:

- **Lyrics** — driven by `LyricsService`. Synced word-by-word lyrics from LRCLIB when available with auto-scroll, centre-focused gradient, and a font-weight ramp toward the active line. Plain (unsynced) lyrics fall back to centre-justified text in a normal scroll view with the same line spacing as the synced layout. A manual offset slider compensates for stream/lyric clock drift in 250 ms steps.
- **About** — driven by `MusicMetadataService`. Artist bio, photo, tags, related artists, album release date, and tracklist. Sources: Wikipedia (per-language subdomain), MusicBrainz (release metadata), Last.fm (tags + similar). Right-click → Refresh metadata; click the photo to enlarge; click the Wikipedia link to open the article. Cached locally via `MetadataCacheRepository` keyed by `<lang>|artist:<name>` etc.
- **History** — recent plays of the current track for the active room, drawn from `play_history.sqlite`.

The tab `Picker` is decorated with `.languageReactive()` (which applies `.id(appLanguage)`) so segmented label rendering rebuilds on language flip — without it the cached labels stay in their pre-flip language.

The `ctxVM` is initialised eagerly in `init` (not via `.task`, which runs after the first body call) so the first render has services available.

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
Sheet with four tabs — Display, Music, Scrobbling, System — each broken into explicit labelled sub-sections (v4.0 promoted these from inline toggles to grouped sections so they're easier to scan):

- **Display tab** — `Language` (AppLanguage picker bound to `@AppStorage(UDKey.appLanguage)`, 13 locales); `Appearance` (Theme picker via `AppearanceMode.displayName`, Colors via `ColorSwatchGrid` for accent / playing-zone / inactive-zone with an "Other…" `ColorPicker` fallback, Menu Bar Controls toggle); `Mouse Controls` (scroll-wheel volume + middle-click mute, handled by `ScrollWheelCapture` over `NowPlayingView`).
- **Music tab** — `MusicServicesView` rendered inline. Tested-blue, untested-yellow, and blocked-red services with status dots, search-only services as toggles, plus the *Other Services (N available)* expandable section. Connect / Disconnect drives the SMAPI AppLink flow.
- **Scrobbling tab** — `SettingsScrobblingTab`. BYO Last.fm API key, browser OAuth via `auth.getSession`, room + service filters, Filter Preview.
- **System tab** — `Network` section (Updates: `CommunicationMode` segmented picker; Startup: `StartupMode` segmented picker; **Discovery: Auto / Bonjour / Legacy Multicast** segmented picker; live event-subscription count + Apple Music search rate-limiter status); `Cache` section (artwork max size dropdown, max age, Clear Speaker Cache, Clear Artwork Cache, current disk usage / image count).

All segmented pickers use `displayName` computed properties on their respective enums and are decorated with `.languageReactive()` so SwiftUI's cached label rendering rebuilds when the user flips the app language. Language flips re-render hosted SwiftUI windows (About box, Help, Listening Stats) via `LanguageReactiveContainer` in `WindowManager`.

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

### Discovery/

The discovery layer is a protocol-abstraction (`SpeakerDiscovery`) over two transport implementations. Both feed the same `handleDiscoveredDevice(location:)` pipeline in `SonosManager`, deduped by location URL. See `docs/DISCOVERY.md` for end-to-end design notes and the discovery-mode setting.

#### SpeakerDiscovery.swift
Protocol the rest of the app talks to. Hides the choice of SSDP vs Bonjour vs both behind a single interface. Backed by either a single transport (Bonjour-only, Legacy-Multicast/SSDP-only) or a parallel-merge wrapper (Auto = SSDP + Bonjour with location-URL dedup).

#### SSDPDiscovery.swift
UDP multicast speaker discovery using BSD sockets (Darwin). Sends M-SEARCH to `239.255.255.250:1900` for `urn:schemas-upnp-org:device:ZonePlayer:1`. Parses HTTP-like responses to extract `LOCATION` header (device description URL). Runs a receive loop on a background `DispatchQueue`. Filters responses for "ZonePlayer" or "Sonos" to ignore non-Sonos UPnP devices. `rescan()` re-sends the M-SEARCH without recreating the socket. Called every 30 seconds by a timer in SonosManager.

Use case: works on flat networks where all devices are in one broadcast domain. Often blocked by VLAN segmentation common with UniFi, OPNsense, and similar router setups.

#### MDNSDiscovery.swift
`NWBrowser`-backed mDNS discovery for `_sonos._tcp`. The Bonjour TXT record carries the same `location` URL that SSDP would surface in its M-SEARCH response, so the entire post-discovery pipeline is unchanged. The TXT record also surfaces the household ID, which lets the app skip one `GetHouseholdID` SOAP round-trip per speaker — measurable on S1 hardware.

Use case: works on segmented networks where mDNS is reflected (most modern routers, including UniFi with mDNS reflector enabled).

Both transports fan out to `handleDiscoveredDevice(location:)`, which dedupes by location URL so seeing the same speaker on both transports is harmless. `Info.plist` declares `NSBonjourServices` for `_sonos._tcp`; `NSLocalNetworkUsageDescription` covers the Local Network permission for both transports.

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
`Codable`. Represents a single play history record. Fields: `id`, `timestamp`, `title`, `artist`, `album`, `albumArtURI`, `source` (service name), `roomName`, `duration`, `starred`. Used by `PlayHistoryManager` for tracking, starring, and stats.

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
Manages saved group presets. Persists presets to `~/Library/Application Support/Choragus/group_presets.json`. Methods: `save(preset:)`, `load()`, `delete(id:)`, `apply(preset:manager:)`. Applying a preset ungroups all speakers, forms the saved group, and sets per-speaker volumes.

#### PlayHistoryManager.swift
Tracks play history with automatic deduplication (same track within a duration-based time window is not re-recorded). Persists to SQLite database. Provides stats (top artists, top tracks, top sources, total play count), star/favorite tracks (toggleStar, starCurrentTrack, starredEntries), and CSV export. SQL-based filtering by date range, room, source, and search text handles 50,000+ entries. Filterable by room, service, and starred status. Toggle on/off via Settings. Supports right-click copy of track details.

#### PlaylistServiceScanner.swift
Background scanner that determines which streaming service each track in a Sonos playlist belongs to. Browses playlist tracks via ContentDirectory, extracts service from URI pattern and SID metadata. Results cached to `~/Library/Application Support/Choragus/playlist_services_cache.json`. Scans one playlist at a time to limit network load. Results populate service badges in the browse list.

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

#### SMAPIClient.swift
SOAP client for Sonos Music API (SMAPI). Supports authenticated and anonymous browsing of music services. Methods: `getMetadata`, `getMediaMetadata`, `search`, `getMetadataAnonymous`, `searchAnonymous`. Builds SMAPI SOAP envelopes with device/session/credential headers. Parses `mediaCollection` and `mediaMetadata` results from DIDL-like XML responses. Falls back to `<logo>` element when `albumArtURI` is missing.

#### SMAPIAuthManager.swift
`@MainActor`, `ObservableObject`. Manages SMAPI service authentication flow (AppLink/DeviceLink). Handles service discovery, token acquisition, and service status tracking. Methods: `loadServices`, `initiateAuth`, `pollAuth`, `disconnect`. Publishes `services`, `isEnabled`, `authURL`.

#### SMAPITokenStore.swift
Keychain-based storage for SMAPI OAuth tokens. Stores access tokens keyed by service ID using `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. Methods: `store`, `retrieve`, `delete`.

### Cache

#### SonosCache.swift
JSON-based disk cache for speaker topology and browse sections. Stores in `~/Library/Application Support/Choragus/topology_cache.json`.

`CachedTopology` is `Codable` and contains: `groups`, `devices`, `browseSections`, `timestamp`. Provides `age` and `ageDescription` computed properties.

Methods: `save()`, `load()`, `clear()`, `restoreDevices()`, `restoreGroups()`, `restoreBrowseSections()`.

#### ImageCache.swift
Two-tier album artwork cache. Singleton via `ImageCache.shared`.

**Memory tier:** `NSCache` with 200 item limit and 50 MB cost limit. Instant access for recently viewed art.

**Disk tier:** JPEG files (80% compression) in `~/Library/Application Support/Choragus/ImageCache/`. 200 MB limit with LRU eviction — oldest-accessed files are removed first when the limit is exceeded. File modification date is updated on each read to track access recency.

Cache key: deterministic hash of the URL string.

Methods: `image(for:)`, `store(_:for:)`, `clearDisk()`, `clearMemory()`, `diskUsage`, `diskUsageString`, `evictIfNeeded()`.

#### StaleDataError.swift
Error types for cache staleness: `deviceUnreachable(roomName)`, `groupChanged(groupName)`, `topologyStale`. Each provides a user-facing `errorDescription` used in the warning banner.

### Tests

#### SonosKitTests.swift
100 unit tests covering:
- Zone group topology XML parsing (multi-group, multi-member)
- DIDL-Lite metadata parsing (title, creator, album)
- TrackMetadata enrichment, ad break detection, radio stream detection
- Time string parsing (HH:MM:SS to TimeInterval)
- TransportState enum mapping and `isPlaying`
- URI prefix detection (radio, HLS, streaming services)
- Art resolution and ArtResolver state management
- Grace period system and state mutations
- Protocol conformance (ISP service protocols)
- MockSonosServices for testable ViewModels
