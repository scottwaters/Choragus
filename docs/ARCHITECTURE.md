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
├── LICENSE                          # PolyForm Noncommercial 1.0.0
├── .gitignore
├── docs/
│   ├── ARCHITECTURE.md              # This file — module-by-module breakdown
│   ├── PROTOCOLS.md                 # UPnP/SOAP/SMAPI protocol reference
│   ├── CACHING.md                   # Caching system documentation
│   ├── DISCOVERY.md                 # Discovery modes (Auto / Bonjour / Legacy Multicast / seed addresses)
│   ├── DIAGNOSTICS.md               # Diagnostic log categories and what leaves the machine
│   ├── FORKS.md                     # Notes for forks
│   ├── LOCALIZATION.md              # 13-locale architecture and conventions
│   └── SERVICES.md                  # Music-service status matrix
│
├── .github/workflows/ci.yml         # Package tests, unsigned app compile, L10n catalog + content hygiene
│
├── Choragus/                        # SwiftUI App Target
│   ├── ChoragusApp.swift            # Entry point; `.choragusServices()` injection modifier
│   ├── Info.plist
│   ├── Choragus.entitlements
│   ├── PrivacyInfo.xcprivacy
│   ├── Assets.xcassets/
│   ├── PlaybackIntents.swift        # AppIntents (run outside the SwiftUI environment)
│   ├── MainThreadHeartbeat.swift    # Main-thread responsiveness probe
│   ├── AppleMusic/                  # MusicKit provider + iTunes-catalog helpers
│   ├── ViewModels/
│   │   ├── BrowseViewModel.swift            # Browse navigation; GenerationGuard for late results
│   │   ├── QueueViewModel.swift             # Queue rows, selection, position via QueuePositionResolver
│   │   ├── NowPlayingViewModel.swift        # Transport + group-volume drag (GroupVolumeDistribution)
│   │   ├── NowPlayingContextPanelViewModel.swift
│   │   ├── ArtCoordinator.swift / ArtResolver.swift / BrowseItemArtLoader.swift
│   │   ├── AlarmsViewModel.swift
│   │   └── LiveEventLog.swift
│   └── Views/
│       ├── AccentColorHelper.swift          # Resolves user accent colour with system fallback
│       ├── AlarmsView.swift
│       ├── ArtworkSearchView.swift          # Manual artwork search dialog (iTunes Search)
│       ├── BrowseView.swift                 # Hierarchical content browser; sidebar section cards
│       ├── BrowseChrome.swift / BrowseSortPicker.swift   # Back bar, bulk-action bar, sort row shared by every list
│       ├── CachedAsyncImage.swift           # Drop-in AsyncImage backed by ImageCache
│       ├── ChoragusQueueMenu.swift          # Folder-nested Choragus playlist submenus
│       ├── ClickOutside.swift               # Deselect-on-click-outside modifier
│       ├── ClubVisWindow.swift / ClubStageSets.swift   # Back of the Club visualisation
│       ├── ColorSwatchGrid.swift            # Grid picker for accent / zone colours
│       ├── ContentView.swift                # Main split layout
│       ├── DiagnosticsView.swift / DiagnosticsHealthTabs.swift / NetworkDiagnosticsTab.swift
│       ├── EQView.swift                     # Bass / treble / loudness popover
│       ├── FirstRunWelcomeView.swift        # First-launch language + Sonos-app hint
│       ├── GroupEditorView.swift            # Add/remove speakers from a group
│       ├── HelpView.swift                   # In-app Help (full body localised)
│       ├── HistoryPlayback.swift
│       ├── HomeTheaterEQView.swift          # Soundbar + Sub + Surrounds EQ window
│       ├── HomeTheaterQuickControls.swift
│       ├── HoverTooltip.swift               # Reliable replacement for SwiftUI .help()
│       ├── LibrarySharesSection.swift       # Music library shares, per-system tags
│       ├── LimitedTextField.swift           # Text field with a length cap and counter
│       ├── LineInBrowseView.swift           # Browse Line-In sources across speakers
│       ├── LiveEventsView.swift
│       ├── LyricsKaraokeWindow.swift / SlidingLyricsView.swift
│       ├── MarqueeText.swift                # Auto-scrolling marquee for long names
│       ├── MenuBarController.swift          # Menu-bar mini player
│       ├── MusicServicesView.swift          # SMAPI setup, Connect / Disconnect, status dots
│       ├── NowPlayingContextPanel.swift     # Bottom tabbed panel — Lyrics / About / History
│       ├── NowPlayingView.swift             # Album art, transport, volume, star, action buttons
│       ├── PlayHistoryDashboard.swift       # Stats hero cards, charts, quick pills
│       ├── PlayHistoryView.swift            # Listening Stats container (Dashboard + Timeline)
│       ├── PlayHistoryView2.swift           # Card-based timeline grouped by day
│       ├── PlaylistBuilderView.swift        # AI playlist builder (brief → songs → resolve → deliver)
│       ├── PlexDirectBrowseView.swift       # Plex – Local browse drill-down
│       ├── PresetManagerView.swift          # Group preset CRUD + EQ editor
│       ├── QueueLibraryWindow.swift         # Saved Choragus queues
│       ├── QueueView.swift                  # Live queue; multi-select, health badges
│       ├── RecentlyPlayedView.swift
│       ├── RoomListView.swift               # Sidebar; drag-to-group via GroupDropDecision
│       ├── ScrollWheelCapture.swift         # NSEvent monitor for scroll-wheel volume
│       ├── SettingsScrobblingTab.swift      # Last.fm scrobbling tab content
│       ├── SettingsView.swift               # Settings sheet (see below)
│       ├── SleepTimerView.swift
│       ├── SliderPopup.swift                # Reusable slider popover
│       ├── SonosRadioSearchView.swift       # Anonymous Sonos Radio search drill-down
│       ├── SunoExploreWindow.swift / SunoWebView.swift
│       ├── SupportSheet.swift               # Bug-bundle export
│       ├── UpdateChecker.swift              # GitHub /releases/latest poller
│       ├── VolumeControlView.swift          # Per-speaker volume sliders
│       └── WindowManager.swift              # Auxiliary-window factory
│
└── Packages/SonosKit/               # Local Swift Package
    ├── Package.swift
    ├── Sources/SonosKit/
    │   ├── SonosManager.swift            # @MainActor @Observable façade / composition root
    │   ├── SonosConstants.swift          # URIPrefix, ServiceID (incl. pandora=3), colours, timing, paths
    │   ├── AppError.swift / ErrorHandler.swift
    │   ├── Protocols.swift               # ISP service protocols (Playback, Volume, EQ, LiveQueueOperating, ...)
    │   ├── PresetManager.swift / PlayHistoryManager.swift / PlayHistoryRepository.swift
    │   ├── QueueHistory.swift / SavedQueueRepository.swift   # Saved Choragus queues (SQLite)
    │   ├── Discovery/
    │   │   ├── SpeakerDiscovery.swift    # Protocol abstraction over discovery transports
    │   │   ├── SSDPDiscovery.swift       # UDP multicast (239.255.255.250:1900)
    │   │   ├── MDNSDiscovery.swift       # NWBrowser-backed _sonos._tcp Bonjour transport
    │   │   ├── SeedAddressDiscovery.swift # Unicast probe of user-supplied speaker addresses
    │   │   └── MediaServerDiscovery.swift # SSDP search for UPnP/DLNA ContentDirectory servers
    │   ├── Events/
    │   │   ├── EventListener.swift       # NOTIFY callback socket, peer allow-list
    │   │   ├── EventSubscriptionManager.swift / LastChangeParser.swift
    │   │   └── TransportStrategy.swift   # Event-first vs polling strategy
    │   ├── Localization/
    │   │   ├── L10n.swift                # accessors + catalog lookup under the app language
    │   │   └── AppLanguage.swift         # the 13 locales, display names, system-default resolution
    │   ├── Resources/
    │   │   └── Localizable.xcstrings     # String Catalog: 1529 keys × 13 locales
    │   ├── Managers/
    │   │   └── ScrobbleManager.swift / ScrobbleService.swift / Scrobblers/
    │   ├── Models/
    │   │   ├── SonosDevice.swift / SonosGroup.swift
    │   │   ├── SonosSystemVersion.swift  # S1 vs S2 classifier
    │   │   ├── HomeTheaterZone.swift / HomeTheaterChannelMap.swift
    │   │   ├── TopologyCoordinatorResolver.swift
    │   │   ├── GroupPreset.swift / GroupDropDecision.swift / GroupVolumeDistribution.swift
    │   │   ├── PlayHistoryEntry.swift / SmartQueueRules.swift
    │   │   ├── TransportState.swift / TrackMetadata.swift / PlayMode.swift
    │   │   ├── BrowseItem.swift / BrowseExpansionOrder.swift / BrowseSortOption.swift
    │   │   ├── PhysicalInput.swift       # Line-in / TV inputs (Browse + Select Input intent)
    │   │   ├── SavedQueueTree.swift      # Folders + queues nested for menus
    │   │   ├── QueuePositionResolver.swift / QueueScrollAnchor.swift / QueuePlaytime.swift
    │   │   ├── StaleTrackURL.swift       # Expiry read out of signed CDN play URLs
    │   │   ├── PlaybackTimeFormat.swift  # Single duration formatter
    │   │   ├── LockedPlayOverride.swift  # Locked-screen media-key rule
    │   │   ├── AsyncResultGuard.swift    # GenerationGuard / IdentityGuard
    │   │   ├── ArtDisplayDecision.swift / LyricScrollPosition.swift / ScrollVolumeAccumulator.swift
    │   │   └── IPAddress.swift           # Private-range classifier
    │   ├── UPnP/
    │   │   ├── SOAPClient.swift / XMLResponseParser.swift
    │   │   ├── BrowseXMLParser.swift / DeviceDescriptionParser.swift
    │   ├── Services/
    │   │   ├── TopologyStore.swift                 # Collaborator: groups, devices, channel maps
    │   │   ├── VolumeController.swift              # Collaborator: per-device volume / mute
    │   │   ├── LibraryStore.swift                  # Collaborator: shares, S1/S2 rules, browse sections
    │   │   ├── TrackMetadataEnricher.swift         # Collaborator: metadata + local-art caches
    │   │   ├── QueueController.swift               # Collaborator: live queue read / mutate / fill
    │   │   ├── AVTransportService.swift / RenderingControlService.swift
    │   │   ├── ZoneGroupTopologyService.swift / ContentDirectoryService.swift
    │   │   ├── AlarmClockService.swift / MusicServicesService.swift
    │   │   ├── MusicServiceCatalog.swift           # Canonical service identity
    │   │   ├── SMAPIClient.swift / SMAPIAuthManager.swift / SMAPITokenStore.swift
    │   │   ├── PlexDirectClient.swift / PlexPlaybackReporter.swift
    │   │   ├── MediaServerService.swift / MediaServerReachability.swift   # UPnP/DLNA servers
    │   │   ├── QueueHealthScanner.swift / QueueHealthMonitor.swift
    │   │   ├── ResolvedPlaybackRegistry.swift      # Play URL → service item, for re-resolution
    │   │   ├── PlaylistResolver.swift / SongListAIService.swift / AIServiceProfile.swift / AIModelCatalog.swift
    │   │   ├── LyricsService.swift / LyricsCoordinator.swift   # LRCLIB synced + plain lyrics
    │   │   ├── MusicMetadataService.swift          # Wikipedia + MusicBrainz + Last.fm bios
    │   │   ├── MetadataCacheRepository.swift       # SQLite cache w/ language-prefixed keys
    │   │   ├── LastFMClient.swift / LastFMTokenStore.swift
    │   │   ├── AlbumArtSearchService.swift         # iTunes Search fallback
    │   │   ├── ArtCacheService.swift               # Persistent art-URL cache
    │   │   ├── ITunesRateLimiter.swift
    │   │   ├── ServiceSearchProvider.swift         # Apple Music / Sonos Radio / Calm Radio
    │   │   ├── SunoResolver.swift / TidalCatalog.swift
    │   │   ├── DiagnosticsService.swift / DiagnosticsRepository.swift
    │   │   ├── BugReportBundle.swift / BugReportEncryptor.swift
    │   │   ├── SpeakerNetworkDiagnosticsService.swift
    │   │   ├── MediaKeyHandler.swift
    │   │   ├── LocalNetworkPermissionMonitor.swift # Local Network entitlement watch
    │   │   └── SecretsStore.swift                  # Unified Keychain item, Choragus service
    │   ├── MCP/                                    # Agent access: local Model Context Protocol server
    │   │   ├── ChoragusMCPServer.swift             # HTTP handling, auth, JSON-RPC dispatch, prompts, dedupe cache
    │   │   ├── ChoragusMCPServer+Helpers.swift     # Room/device/item/playlist lookups, match-service resolution, grouping snapshots, build undo
    │   │   ├── LocalHTTPServer.swift               # Network.framework listener: 127.0.0.1 or all interfaces; Bonjour via NetService
    │   │   ├── MCPAccessGuard.swift                # Origin/Host validation, auth-failure lockout, per-token rate limit
    │   │   ├── MCPTokenStore.swift / MCPScope.swift # Named keychain tokens with access level and skip-confirmations flag
    │   │   ├── MCPActivityLog.swift / MCPDiagnostics.swift # Request log ring + payload for Diagnostics and the bug bundle
    │   │   ├── MCPTools.swift                      # Tool/resource types, argument helpers, encoders, output schemas, `all`
    │   │   ├── MCPTools+Playback/+Library/+Queue/+Playlists/+History/+Alarms/+Builder.swift   # 116 tools, one file per area
    │   │   ├── MCPBuildJobs.swift                  # Background playlist builds: passes, input-order merge, streaming hits, cap, undo data
    │   │   ├── MCPGroupingSnapshot.swift / MCPPrompts.swift   # Party-mode undo state; playbook prompts
    │   │   └── SleepInhibitor.swift                # IOKit power assertion
    │   └── Cache/
    │       ├── SonosCache.swift                    # Topology + browse-section JSON
    │       ├── ImageCache.swift                    # Two-tier NSCache + JPEG disk
    │       └── StaleDataError.swift
    └── Tests/SonosKitTests/                        # ~840 tests across 59 files
```

The Views layer is intentionally flat (no per-feature subfolders) because most views are top-level scenes; deeper folders haven't paid off yet.

## App Target: Choragus

The SwiftUI app layer. Contains views and the app entry point. All business logic lives in SonosKit.

### ChoragusApp.swift

Entry point. Creates the `SonosManager` as `@State` (it is `@Observable`) and injects it with the `.choragusServices(manager)` view modifier, which is the single injection point for the manager and its collaborators: `.environment(manager)`, `.environment(manager.topology)`, `.environment(manager.volume)`, `.environment(manager.library)`, `.environment(manager.queue)`, plus `EQServiceProtocol` through an `EnvironmentKey` (`\.eqService`), since `RenderingControlService` is not `@Observable`. Every Scene, `NSHostingController` root, sheet and popover goes through this one modifier. A missing `@Environment(T.self)` for an `@Observable` type traps at runtime with no compile-time signal, so injection is not repeated per call site. Views read `@Environment(SonosManager.self)` or, where they only need one collaborator, `@Environment(TopologyStore.self)` etc. `@Bindable` restores `$`-bindings where needed.

Starts speaker discovery on appear. Initializes `MenuBarController` and `WindowManager` for menu bar mode and AppKit-based window management. The app delegate holds an explicit weak reference to the manager for shutdown; `SonosManager.current` remains only for AppIntents (`PlaybackIntents.swift`), which run outside the SwiftUI environment. Window title is "Choragus".

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

The tab `Picker` is decorated with `.languageReactive()` (which applies `.id(appLanguage)`) so segmented label rendering rebuilds on language flip; without it the cached labels stay in their pre-flip language.

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
Sheet with tabs: Display, Music, Scrobbling, AI, Visualisations, System, Software Updates (official builds). Each is broken into `SettingsSectionCard` sub-sections (v4.0 promoted these from inline toggles to grouped sections so they're easier to scan). The AI tab holds the named `AIServiceProfile` list (provider, model, endpoint, per-profile keychain key, connection test) that the Playlist Builder generates with; the Music tab adds a Media Servers section (enable, discovered-vs-manual, add/remove by address, per-speaker reachability); the System tab adds an "Advanced network settings" disclosure (event listener port, discovery hop limit, seed addresses). The four original tabs:

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

The top-level façade and composition root. `@MainActor`, `@Observable` (migrated from `ObservableObject` in v5.0). Owns the services, the discovery instances, the transport strategy, and the state that has not yet moved to a collaborator. Views re-render only for the properties their body reads, rather than every observer invalidating on any published write.

**Observation mechanics:**
- No `@Published`. Lazily constructed services are `@ObservationIgnored`, as are per-tick bookkeeping fields no view reads.
- `groupTrackMetadata` additionally feeds `groupTrackMetadataPublisher` (a Combine `CurrentValueSubject`) because its consumers (art coordinator, metadata prewarm, `MediaKeyHandler`, `PlexPlaybackReporter`) are pipelines, not render dependencies.
- The art-cache `objectWillChange` forward became a tracked version counter.
- Every high-frequency write site is equality-gated and calls `tagPublish(_:)`; the per-second `[MGR-PUB]` diagnostic prints the tagged-write breakdown by bucket. Dropping a gate re-renders every observing view ~20 times a second (measured as 100–670 ms main-thread stalls), so the gates are load-bearing.
- `groupTransportStates`, `groupPlayModes` and `awaitingPlayback` are `private(set)` with exactly one gated writer each (`updateTransportState`, `updatePlayMode`, `confirmPlaying` / `beginAwaitingPlayback` / `clearAwaitingPlayback`).

**Collaborators** (each `@MainActor @Observable`, injected with `TopologyStore` rather than a back-reference to the façade; none names `SonosManager` outside doc comments):
- `TopologyStore` — `groups`, `devices`, `htSatChannelMaps`, `stereoChannelMaps`, `homeTheaterZones`, the topology merge with its per-household serialization, ten-second throttle, self-view rejection and coordinator repair. `refresh` returns a `RefreshResult`; deciding what to do about a change (save cache, restart transport strategy, rescan) stays in the manager. Depends on `ZoneGroupStateFetching`.
- `VolumeController` — `deviceVolumes`, `deviceMutes`, `fixedOutputDeviceIDs`, expected-echo queues, debounced verifiers (`[RC-VERIFY]`), optimistic group-mute propagation, UPnP 501 handling for Connect/Port/Amp. Depends on `RenderingControlling`; reads what a group is playing through `NowPlayingContextProviding`.
- `LibraryStore` — household capabilities, share matching, the S1/S2 availability tags (a share is per-system, not per-path), and `browseSections`. Depends on `ContentDirectoryBrowsing`; media-server sections arrive through `BrowseSectionContributing` so the store has no dependency on them.
- `TrackMetadataEnricher` — play-time metadata cache, local-album-art store and persistence, Apple Music and Suno self-heals, `lastQueueItems` / `cachedTrackByPosition` (one writer: `recordQueuePage` enriches on the way in). Depends on `AlbumArtSearchProtocol`; patches a now-playing row through `NowPlayingTitlePatching`. Conforms to `LocalAlbumArtResolving` for the app target.
- `QueueController` — reading, mutating and paging the live queue, background fill and repair bookkeeping (`isAdding` derived from a depth counter). Depends on `QueueDirectoryOperating` (the five queue verbs, kept separate from `ContentDirectoryBrowsing`), `QueueSnapshotting` (undo snapshot) and `QueueRowRepairing` (Apple Music naming pass). Conforms to `LiveQueueOperating`, which `QueueViewModel` depends on instead of the concrete class.
- EQ has no controller: `RenderingControlService` implements `EQServiceProtocol` and the manager exposes it as `eq`.

The façade forwards `groups`, `devices`, `browseSections`, `deviceVolumes`, `isAddingToQueue` etc. to the collaborators so existing call sites keep working; reading through the façade still registers observation on the property actually read. `clearQueue`, `playItemsReplacingQueue` and `playTrackFromQueue` deliberately stay on the façade: they write transport state and are transport orchestration that happens to involve a queue.

**Manager-owned state (selected):**
- `isDiscovering`, `isUsingCachedData`, `cacheAge`, `isRefreshing`, `staleMessage`, `networkAdvisory`
- `groupTransportStates`, `groupTrackMetadata`, `groupPlayModes`, `awaitingPlayback`, position anchors
- `mediaServers`, `isDiscoveringMediaServers`, `mediaServerReachability`, `mediaServerCheckProgress`
- `musicServicesList`, `plexPlaybackReporter`, `playHistoryManager`
- `startupMode: StartupMode` — Quick Start or Classic, persisted to UserDefaults

**Queue exclusivity:** one batch add (or play-now background fill) per coordinator at a time; an overlapping add throws `QueueBusyError` and logs `[QUEUE] Batch add refused`.

**Startup flow:**
1. If Quick Start mode and cache exists: restore cached devices, groups, and browse sections immediately. Set `isUsingCachedData = true`.
2. Start speaker discovery regardless of cache.
3. When first device responds: fetch zone topology through `TopologyStore`, which updates `groups` and `devices` with live data. Set `isUsingCachedData = false`. Save new cache only when the store reports it applied a change.

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
- `discoverMediaServers/addMediaServer(address:)/removeMediaServer(id:)/verifyMediaServerReachability(id:)` — UPnP/DLNA servers as a browse source
- `saveChoragusPlaylist/appendToChoragusPlaylist/liveQueueTracks` — saved queues (`QueueServiceProtocol`)

### Discovery/

The discovery layer is a protocol-abstraction (`SpeakerDiscovery`) over three transport implementations. All feed the same `handleDiscoveredDevice(location:)` pipeline in `SonosManager`, deduped by location URL. See `docs/DISCOVERY.md` for end-to-end design notes and the discovery-mode setting.

Discovery inputs are unauthenticated, so each transport bounds what it trusts: an SSDP `LOCATION` must be `http` and its host must equal the datagram's sender (mismatches are dropped and logged under `[DISCOVERY]`); mDNS learns the host from the resolved connection endpoint rather than the TXT record; device descriptions are capped at 256 KB (`DeviceDescriptionParser.maxDescriptionBytes`).

#### SpeakerDiscovery.swift
Protocol the rest of the app talks to. Hides the choice of SSDP vs Bonjour vs both behind a single interface. Backed by either a single transport (Bonjour-only, Legacy-Multicast/SSDP-only) or a parallel-merge wrapper (Auto = SSDP + Bonjour with location-URL dedup).

#### SSDPDiscovery.swift
UDP multicast speaker discovery using BSD sockets (Darwin). Sends M-SEARCH to `239.255.255.250:1900` for `urn:schemas-upnp-org:device:ZonePlayer:1`. Parses HTTP-like responses to extract `LOCATION` header (device description URL). Runs a receive loop on a background `DispatchQueue`. Filters responses for "ZonePlayer" or "Sonos" to ignore non-Sonos UPnP devices. `rescan()` re-sends the M-SEARCH without recreating the socket. Called every 30 seconds by a timer in SonosManager.

Use case: works on flat networks where all devices are in one broadcast domain. Often blocked by VLAN segmentation common with UniFi, OPNsense, and similar router setups.

#### MDNSDiscovery.swift
`NWBrowser`-backed mDNS discovery for `_sonos._tcp`. The Bonjour TXT record carries the same `location` URL that SSDP would surface in its M-SEARCH response, so the entire post-discovery pipeline is unchanged. The TXT record also surfaces the household ID, which lets the app skip one `GetHouseholdID` SOAP round-trip per speaker, measurable on S1 hardware.

Use case: works on segmented networks where mDNS is reflected (most modern routers, including UniFi with mDNS reflector enabled).

#### SeedAddressDiscovery.swift
Third `SpeakerDiscovery` transport, active in every discovery mode. Probes user-supplied addresses (Settings → System → Advanced network settings) with a unicast GET of `/xml/device_description.xml`, which crosses boundaries that block multicast outright (IGMP snooping without a querier, access points dropping multicast, firewall rules). One seed is normally enough: `GetZoneGroupState` on the seeded speaker returns every other member. Accepts a bare address, `host:port`, a hostname or a full description URL; refuses what it cannot probe rather than dropping it silently. Probes time out after three seconds.

#### MediaServerDiscovery.swift
SSDP search for UPnP/DLNA media servers, kept separate from `SSDPDiscovery` because servers are optional and looked for occasionally. A responder is accepted only once its description proves it offers `ContentDirectory:1` (Hue bridges and TV tuners answer the search too). Description URLs must be web-scheme and on a private address; the description fetch is capped at 256 KB.

All transports fan out to `handleDiscoveredDevice(location:)`, which dedupes by location URL so seeing the same speaker on more than one transport is harmless. `Info.plist` declares `NSBonjourServices` for `_sonos._tcp`; `NSLocalNetworkUsageDescription` covers the Local Network permission for all transports.

### Events/

`TransportStrategy` chooses event-first (GENA `SUBSCRIBE` with polling fallback) or legacy polling. `EventListener` binds the NOTIFY callback socket (default port 3401, user-configurable; ephemeral fallback with a logged `[EVENTS]` warning) and accepts connections only from discovered speakers: `TransportStrategy` calls `setAllowedPeers` before the socket binds and on every topology change; an IPv4-mapped IPv6 peer is unwrapped before comparison; refused peers are dropped without a response and counted with one sampled address (`refusedPeerStats`) rather than logged per event. An empty allow-list accepts any peer, which is only the window before the first device list. `stopAndWait()` resumes on the listener's `.cancelled` state with a bounded deadline so a network-change rebuild does not race its own dying socket onto an ephemeral port. `LastChangeParser` reads `TransportState`, `CurrentTrackMetaData`, `CurrentTrackURI`, `CurrentTrackDuration` and `CurrentTrack` (the speaker's 1-based queue position; zero means "not reported").

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

#### HomeTheaterChannelMap.swift
Merges each bonded member's partial `HTSatChanMapSet` view into one device-id → channel map, ordered by channel then id so the result does not depend on enumeration order. Reading a single member's value loses the channels that member cannot see, which hid the Surrounds tab on systems that had surrounds (#78).

#### TopologyCoordinatorResolver.swift
Decides which speaker a group is controlled through when the topology names a coordinator that is not one of the group's visible members. Such a group otherwise resolves to no coordinator: it accepts no transport command and reports no state while its speakers keep emitting events (#83). Prefers the coordinator the group was last controlled through, then the lowest visible id; substitutions are logged, never silent.

#### HomeTheaterZone.swift
Represents a home theater configuration parsed from `HTSatChanMapSet` in the zone topology XML. Every bonded member advertises that attribute, but a satellite advertises only the soundbar and itself, so the zone layout is the union across members (see `HomeTheaterChannelMap`). Fields: `soundbarID`, `subID`, `surroundIDs`, `channelMap`. Used to detect 5.1/sub setups and enable the home theater EQ window. Computed `hasSubwoofer` and `hasSurrounds`.

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

#### Tested value types
Decisions that used to live inline in views and view models are stated as pure functions in SonosKit so they can be tested without a speaker:

- `QueuePositionResolver` — which queue row is playing: the speaker's `Track` field wins when it names a row; a confirmed URI is never re-litigated by a title match; ambiguous title matches are refused.
- `QueueScrollAnchor`, `QueuePlaytime` (sums parseable durations, reports how many did not parse so the label can read `~`), `BrowseExpansionOrder`, `SmartQueueRules`, `GroupDropDecision`, `GroupVolumeDistribution`, `ArtDisplayDecision`, `LyricScrollPosition`, `ScrollVolumeAccumulator`.
- `PlaybackTimeFormat` — the single duration formatter (`h:mm:ss` / `m:ss`, truncating, clamps negative and non-finite input; `seconds(from:)` parses the speaker's strings).
- `StaleTrackURL` — reads the expiry out of a signed play URL (`Expires` / `exp` / `oauth2_expiry`, `X-Amz-Expires` + `X-Amz-Date`, Akamai-style `token=<epoch>~…` and `hdnts`); an opaque token with no readable expiry is "perishable, unknown", not "valid". Query parsing is hand-rolled because `URLComponents` returns nil on some real CDN URLs.
- `LockedPlayOverride` — N media-key play presses inside a rolling window grant one play while the screen is locked; presses closer than the minimum gap fold into the previous press so a device burst never accumulates.
- `AsyncResultGuard` — `GenerationGuard` (only the newest request may publish; token 0 is never current) and `IdentityGuard` (keyed on what the result is for). `BrowseViewModel` and `NowPlayingContextPanelViewModel` delegate to them.
- `IPAddress` — private-range classifier used by the HTTPS art upgrade, media-server description validation and the AI bearer-token rule.

### Managers

#### PresetManager.swift
Manages saved group presets. Persists presets to `~/Library/Application Support/Choragus/group_presets.json`. Methods: `save(preset:)`, `load()`, `delete(id:)`, `apply(preset:manager:)`. Applying a preset ungroups all speakers, forms the saved group, and sets per-speaker volumes.

#### PlayHistoryManager.swift
Tracks play history with automatic deduplication (same track within a duration-based time window is not re-recorded). Persists to SQLite database. Provides stats (top artists, top tracks, top sources, total play count), star/favorite tracks (toggleStar, starCurrentTrack, starredEntries), and CSV export. SQL-based filtering by date range, room, source, and search text handles 50,000+ entries. Filterable by room, service, and starred status. Toggle on/off via Settings. Supports right-click copy of track details.

#### PlaylistServiceScanner.swift
Background scanner that determines which streaming service each track in a Sonos playlist belongs to. Browses playlist tracks via ContentDirectory, extracts service from URI pattern and SID metadata. Results cached to `~/Library/Application Support/Choragus/playlist_services_cache.json`. Scans one playlist at a time to limit network load. Results populate service badges in the browse list. Lives under `Services/`.

#### ScrobbleManager.swift / ScrobbleService.swift / Scrobblers/
Scrobble dispatch (Last.fm) with room and service filters; the only contents of `Managers/`.

### UPnP

#### SOAPClient.swift
Builds SOAP envelopes and sends HTTP POST requests to Sonos speakers. Takes `baseURL`, `path`, `service`, `action`, and `arguments`. Returns parsed response as `[String: String]`.

Handles HTTP 500 as SOAP fault — extracts `errorCode` and `faultstring`. Defines `SOAPError` enum with cases for invalid URL, HTTP errors, network errors, parse errors, and SOAP faults. Responses over 2 MB are rejected (`parseError("response exceeded size cap")`); HTTP errors keep a 300-character excerpt of the body.

XML-escapes argument values (`&`, `<`, `>`, `"`, `'`).

#### XMLResponseParser.swift
Central XML parsing utilities. All use Foundation's `XMLParser` (SAX-based).

- `parseActionResponse()` — extracts leaf element text values from SOAP responses
- `parseFault()` — extracts `errorCode` and `faultstring` from SOAP faults
- `parseDeviceDescription()` — extracts UDN, roomName, modelName from device XML
- `parseZoneGroupState()` — parses the zone group topology XML, handling the double-encoded XML-in-XML structure. Extracts `ZoneGroup` and `ZoneGroupMember` attributes including `Invisible` flag for bonded speakers.
- `parseDIDLMetadata()` — parses DIDL-Lite XML for track metadata (title, creator, album, albumArtURI)

The SOAP SAX parser unescapes XML entities in element text. DIDL-Lite content within `Result` elements arrives already unescaped by the SAX parser. The DIDL parsers do not call `xmlUnescape()` again; doing so would corrupt `&amp;` in URLs and break XML parsing.

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

Exposes two narrow protocols: `ContentDirectoryBrowsing` (what `LibraryStore` needs to probe capabilities and build sections) and `QueueDirectoryOperating` (the five queue verbs `QueueController` needs). They are separate so a collaborator that only reads containers is not handed the ability to mutate a queue.

#### MediaServerService.swift / MediaServerReachability.swift
Browse third-party UPnP/DLNA media servers (Synology Media Server, MinimServer, Asset, Plex, Jellyfin). Sonos cannot browse such servers, but a speaker plays an ordinary HTTP URL, so the server supplies both the browse tree and the audio. `MediaServerService` builds a `MediaServer` from its description (locating the `controlURL` inside the `ContentDirectory:1` service block rather than taking the document's first `controlURL`, which usually belongs to `ConnectionManager`), browses containers into `BrowseItem`s marked for the direct-HTTP queue strategy, and runs the `Search` action with an escaped `SearchCriteria`, failing open to an empty result on servers without search support. The base URL is built from the address that answered; a different advertised host is recorded as `advertisedHostMismatch` because speakers are handed URLs on the advertised host. Roots are pruned by a first-page class verdict; video and image classes are filtered.

`MediaServerReachability` answers whether each visible group member can fetch from a server, since a VLAN the speaker cannot route to, a server bound to the wrong interface and a one-speaker firewall hole all present as STOPPED / OK with no fault. The probe makes the speaker fetch a reference track through its own `/getaa?u=` proxy — 200 proves reach, a 404 after ~5 s is the proxy's connect timeout, a fast 404 stays unknown. No transport command is sent. A speaker that never answers is reported as offline rather than blamed on the server. See `docs/PROTOCOLS.md`.

#### QueueHealthScanner.swift / QueueHealthMonitor.swift
`QueueHealthScanner` judges which queue rows will not play without playing them: expiry from the URL alone (`StaleTrackURL`; a CDN can answer 200 for a grace period after expiry, so no probe overrides a stated expiry), liveness with one HEAD (ranged-GET fallback for CDNs that reject HEAD), and filename-titled rows flagged as enqueued without metadata. Speaker-resolved URIs (`x-sonos-http:`, `x-file-cifs:`) are reported healthy on purpose. `QueueHealthMonitor` runs it automatically after track changes with a budget: offline checks cover the whole queue on every pass; one TCP touch per distinct NAS / media-server host verdicts every row that host serves; HEAD probes only for the ten rows after the playhead that nothing cheaper can answer. Verdicts cache on a signature-stripped key (ok six hours, dead thirty minutes), one pass per group per ten minutes, five-second debounce, and results land as one batched dictionary write. `QueueViewModel` greys expired / dead rows, shows a badge with an explanation on hover, offers one-click removal, and triggers one re-resolve repair pass per ten-minute window for rows whose origin `ResolvedPlaybackRegistry` recorded.

#### ResolvedPlaybackRegistry.swift
Records, at resolution time, which service item a controller-resolved play URL came from (TIDAL, Qobuz, Suno enqueue the pre-signed CDN URL from `getMediaURI` with empty DIDL, which discards the only thing that could produce a fresh URL). Keyed on the URL with rotating credentials stripped, persisted and bounded. `saved_queue_tracks` also carries `origin_sid` / `origin_item_id` so saved queues survive independently of the registry. Used on restore (expired URLs re-resolved before enqueue, capped at 200 round-trips), on playback failure (the early-advance detector repairs before reporting) and by the health monitor.

#### PlaylistResolver.swift / SongListAIService.swift / AIServiceProfile.swift
The AI Playlist Builder. `SongListAIService` turns a natural-language brief into an ordered `[SongSpec]` via the Claude Messages API or any OpenAI-compatible chat-completions endpoint (OpenAI, DeepSeek, Ollama, LM Studio); a bare custom host gains `/v1` (`chatCompletionsURL`). The reply is untrusted input end to end: typed decode, control-character stripping, field and list caps, stream size caps, byte-wise SSE parsing with mid-stream error surfacing. API keys are keychain-stored per profile (`aiProfile.<id>` in `SecretsStore`), sent only to that profile's host, and a bearer header is refused over cleartext unless the host is private (`IPAddress.isPrivate`). `AIServiceProfile` + `AIServiceProfileStore` hold the user-named profiles (provider, model, endpoint) in UserDefaults. `PlaylistResolver` matches each spec on a chosen service (Apple Music via the iTunes catalog path, an authenticated SMAPI service, the Sonos local library, or a DLNA server's `Search`), with artist match mandatory (a title-only fallback returned cover versions); hosted lookups pace at 2 s per song, LAN lookups at 150 ms.

#### PlexPlaybackReporter.swift
Reports direct ("Plex – Local") playback back to the Plex Media Server, which otherwise never sees a session. Opens a session per coordinator when a Plex track becomes current, sends `/:/timeline` heartbeats every 10 s (playing / paused / buffering / stopped), keeps the session across stop so Play resumes it, and calls `/:/scrobble` at track end when at least 90 % was played (`playedThreshold`). The play URL names a part, not the track, so the browse layer registers `partKey → ratingKey` (`register(partKey:ratingKey:durationMs:)`, persisted under `plex.direct.partRatingKeys`). Fed from the metadata store's `didSet` and from `updateTransportState`. See `docs/PROTOCOLS.md`.

#### MusicServiceCatalog.swift
Canonical service identity for the ~90 third-party descriptors a household advertises. When a descriptor's name matches nothing known, identity falls back to matching the host's first DNS label; both the scheme-token and name-word passes reject tokens that describe what a service serves rather than who it is (`genericHostTokens`: sonos, radio, music, player, stream, media, audio), so `sonos.<vendor>.com` no longer folds vendors into Sonos Radio. Descriptors folded by host match are logged under `CATALOG`.

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

**Disk tier:** JPEG files (80% compression) in `~/Library/Application Support/Choragus/ImageCache/`. 200 MB limit with LRU eviction (oldest-accessed files are removed first when the limit is exceeded). File modification date is updated on each read to track access recency.

Cache key: deterministic hash of the URL string.

Methods: `image(for:)`, `store(_:for:)`, `clearDisk()`, `clearMemory()`, `diskUsage`, `diskUsageString`, `evictIfNeeded()`.

#### StaleDataError.swift
Cache-staleness error types: `deviceUnreachable(roomName)`, `groupChanged(groupName)`, `topologyStale`. Each provides a user-facing `errorDescription` used in the warning banner.

### Tests

`Packages/SonosKit/Tests/SonosKitTests/` — around 840 tests in 59 files, run by `swift test --package-path Packages/SonosKit` and by the CI workflow on every push. No test makes a network call; live-hardware probes are excluded from the test target.

- **Collaborators** — `TopologyStoreTests` (merge invariants, self-view rejection, coordinator repair, duplicate group ids), `VolumeControllerTests` (echo absorption, fixed-output 501 handling, portable-speaker diagnostic), `LibraryStoreTests` / `LibraryAvailabilityTests` (S1/S2 rules), `TrackMetadataEnricherTests` (speaker wins unless it gave an empty or technical name), `QueueControllerTests` (enrichment on read, paging, nesting add counter). Each runs against a stub of the narrow protocol the collaborator depends on.
- **Value types** — `QueuePositionResolverTests`, `QueueScrollAnchorTests`, `QueuePlaytimeTests` (within `PlaybackTimeFormatTests`), `BrowseExpansionOrderTests`, `SmartQueueRulesTests`, `GroupDropDecisionTests`, `GroupVolumeDistributionTests`, `ArtDisplayDecisionTests`, `LyricScrollPositionTests`, `StaleTrackURLTests`, `LockedPlayOverrideTests`, `AsyncResultGuardTests`, `HomeTheaterChannelMapTests`, `HomeTheaterZoneTests`, `GroupPresetCodingTests`, `IPAddressTests`.
- **Media servers and queue health** — `MediaServerServiceTests` (fixtures trimmed from a real Synology description), `MediaServerRootPruneTests`, `MediaServerReachabilityTests`, `QueueHealthScannerTests`, `QueueHealthMonitorTests`, `ResolvedPlaybackRegistryTests`.
- **Discovery and events** — `SeedAddressDiscoveryTests`, `EventListenerTests`, `EventListenerPeerTests` (allow-list, IPv4-mapped IPv6, refused-peer count).
- **Services** — `CanonicalServiceFoldingTests` / `CanonicalServiceResolutionTests` (generic host tokens), `DirectStreamServiceNameTests`, `SongListAIEndpointTests` (`/v1` normalisation, error extraction), `MusicServiceCatalogTests`, `LastFMSigningTests`, `ScrobbleEligibilityTests`.
- **Diagnostics and export** — `DiagnosticsRedactorTests`, `BugReportBundleScrubTests`, `ExportTracksTests` (CSV / M3U).
- **Legacy suites** — `SonosKitTests`, `ComprehensiveTests`, `ExtendedTests`, `SessionTests`, `StaleHandlingTests`, `ServiceProtocolTests` (ISP conformance), with `MockSonosServices` for testable view models.
