# Changelog

## v3.5 — 2026-04-23

### New Features
- **Sonos S1 + S2 coexistence** — legacy S1 speakers are no longer wiped from the device list when a modern S2 system is on the same network. Rooms are grouped by household in the sidebar with S2 and S1 headers and a horizontal divider between systems. When only one system is present, the list renders flat with no header.
- **Household identification** — each device is identified by its Sonos household via `DeviceProperties/GetHouseholdID`. Topology refreshes are merged per-household instead of replacing the entire group list, so S1 and S2 refreshes no longer starve each other.
- **S1 / S2 classification** — speakers self-identify their platform via the UPnP `<swGen>` tag (`1`=S1, `2`=S2) in the device description. Firmware major-version (≥12 ⇒ S2) is used as fallback.
- **In-app Help** — new `Help → SonosController Help` (⌘?) opens a dedicated help window with eight topics: Getting Started, Playback, Grouping, Browsing Music, S1 and S2, Preferences, Keyboard Shortcuts, About & Support.
- **Check for Updates** — `SonosController → Check for Updates…` queries GitHub's `/releases/latest` and compares against the running version. Silent background check at most once per 24 h at launch; manual check always reports a result.
- **GitHub integration** — `Help → View Source on GitHub` and `Report an Issue` open the repository pages. About panel now includes a clickable repo link in its credits.
- **Browse panel resize** — user-adjustable width with a drag handle; local-library search field hides automatically when inside a music service view that has its own search.

### HIG Alignment
- **Controls menu** — new top-level menu: Play/Pause ⌘P, Next Track ⌘→, Previous Track ⌘←, Mute/Unmute ⌥⌘↓.
- **View menu** — `Toggle Browse Library` ⌘B, `Toggle Play Queue` ⌥⌘U, `Listening Stats` ⇧⌘S — injected into the system View menu via `CommandGroup(after: .sidebar)` to avoid a duplicate top-level menu.
- **Window menu** — default macOS items (Minimize, Zoom, Bring All to Front) are restored; previously stripped.
- **Help menu** — replaced with app-specific items. No more empty macOS default help menu.
- **About panel** — correctly populated with name, version (3.5), and copyright from Info.plist. Clickable GitHub link embedded in credits.
- **Bundle metadata** — `CFBundleShortVersionString = 3.5`, `CFBundleDisplayName = SonosController`, `NSHumanReadableCopyright` populated.

### Architecture
- **Per-household topology serialization** — `refreshingHouseholds: Set<String>` replaces single-flag `isRefreshingTopology`, so S1 and S2 refreshes don't block each other.
- **Cache backward-compat** — `CachedDevice` and `CachedGroup` carry new fields (`softwareVersion`, `swGen`, `householdID`) as optionals; one-shot backfill in `refreshTopology` adopts pre-upgrade nil-household cache entries into the first live household that claims them.
- **New model type** — `SonosSystemVersion` enum with pure classifier functions (`fromSwGen`, `fromSoftwareVersion`, `classify`). 17 dedicated unit tests.
- **New service** — `UpdateChecker` singleton (app-layer, under `Views/`) with `AppLinks` enum as single source of truth for repo/issues/releases URLs.
- **Topology merge logic** — new groups are appended to groups from other households instead of replacing `self.groups` wholesale.

### UI
- **Speaker sections** — `HouseholdSection` struct partitions the room list. Groups with no visible members are filtered out, and households with no groups are dropped entirely.
- **Menu item labels** — "Toggle Browse Library" / "Toggle Play Queue" accurately describe the action; "Settings…" uses the real ellipsis character per HIG.
- **Settings additions** — additional configuration options surfaced in Settings panel.
- **History / dashboard refinements** — play history view and dashboard tweaks carried over from post-v3.1 improvements.

### Code Quality
- **Force-unwrap elimination** — all new `URL(string:)!` call sites replaced with `guard let` pattern matching project convention.
- **Centralized URLs** — `AppLinks` enum replaces three duplicated hardcoded GitHub URL strings.
- **Observability** — new `[DISCOVERY]` and `[UPDATE]` debug-log entries for household resolution and update checks.
- **Dead code removal** — removed redundant `release.draft`/`prerelease` branch (endpoint already filters); removed unused `UDKey.selectedHouseholdID` after design iteration.
- **Idiomatic decoding** — `GitHubRelease` uses `CodingKeys` to map GitHub's `snake_case` to Swift `camelCase`.
- **Test coverage** — 284 unit tests passing (17 new, up from 267). All classifier paths and model integrations covered.

### Bug Fixes
- **Topology wipe** — adding an S1 speaker to a network with S2 speakers no longer causes the device list to flash between the two systems. Root cause was `self.groups = sortedGroups` replacing all groups on every refresh; fixed with household-partitioned merge.
- **Duplicate View menu** — switched from `CommandMenu("View")` (which created a second top-level menu) to `CommandGroup(after: .sidebar)` (which extends the system-provided View menu).
- **Empty household sections** — households whose only groups have zero visible members no longer render an orphan header with no rooms.
- **Unknown tab label** — cache-hydrated groups without a `softwareVersion` now inherit the source device's version on first refresh instead of classifying as "Unknown".
- **Whitespace in swGen** — `SonosSystemVersion.fromSwGen` now trims `.whitespacesAndNewlines` instead of just `.whitespaces`, so tab/newline-wrapped XML values classify correctly.
- **S2 speakers disappearing on rescan** — individual speakers no longer drop out of their section every ~10 s when `GetHouseholdID` transiently fails. `handleDiscoveredDevice` now preserves any previously-resolved household across retries and only overwrites on a successful fetch; `refreshTopology` skips the household merge entirely when the source device's household is still unknown, rather than producing a nil-household duplicate set.
- **S2 speakers flickering across rescans (Sonos topology inconsistency)** — different speakers in the same household can return slightly different `GetZoneGroupState` responses while state propagates. A single refresh no longer forces group removal; a 30-second grace window retains groups that were seen recently by any other speaker in the same household. Observed rate of spurious "changed=true" merges drops from many-per-minute to effectively zero.
- **Member-order instability** — member lists inside a group are now stably sorted by device id when a `SonosGroup` is constructed, so a pure reorder in a topology response no longer trips the equality check and causes a UI refresh.
- **Spurious `@Published` fires on `devices`** — every topology refresh was rewriting each member into the `devices` dictionary even when the value was unchanged, cascading re-renders through every `@EnvironmentObject` observer of `SonosManager`. Writes now go through an equality guard.
- **Radio artwork flicker on track change** — previously clearing `radioTrackArtURL` immediately on a new radio track caused a brief revert to station art during the iTunes search window. The old art now stays visible until the new one is ready or the search fails.
- **Radio artwork flicker while paused** — stream-content pings make `title` oscillate between empty and populated while paused, which was forcing repeated clear/search/set cycles. `searchRadioTrackArt` now short-circuits when `transportState.isActive == false`; existing art remains stable while paused.
- **Station-art mini badge** — disabled on the bottom-right corner of the album art. The resolution heuristic was flaky and caused visual noise; the `ArtResolver` API is preserved so it can be re-enabled with one line.
- **Main volume slider color** — the master volume slider now explicitly picks up the user's custom accent color. Previously the outer container's `.tint(resolvedAccentColor)` passed `nil` when the system accent was selected, letting the slider fall back inconsistently compared to the per-speaker sliders.

### Test Coverage
- **+25 tests** covering the new v3.5 invariants: 17 for `SonosSystemVersion` classification, 8 for topology-merge invariants (`SonosDevice`/`SonosGroup` value equality, stable member sort, household partitioning, grace-window semantics). **292 tests total**, all passing.

### Documentation
- **README split** — `README.md` is now end-user focused (features, screenshots, installation, privacy). Architecture, protocol reference, build-from-source instructions, and contributor notes moved to the new `technical_readme.md`. A pointer at the top of the README directs developers to the technical file.
- **v3.1 entry** — the previously-missing 3.1 release is now documented (Stream/Queue, Artwork, Search, History).

### Localization
- **First-run welcome popup** — a one-time dialog on first launch explains that speakers and music services must be set up in the official Sonos app first, and points to Settings → Music to enable services in-app. Dismissal is persisted; *Open Settings* jumps directly to the Music tab.
- **All new v3.5 menus, alerts, and dialogs localized** across the 13 existing languages (English, German, French, Dutch, Spanish, Italian, Swedish, Norwegian, Danish, Japanese, Portuguese, Polish, Chinese Simplified). New strings cover: About / Check for Updates / Help menu items; View and Controls menu items with their shortcuts; update-available / up-to-date / update-failed alert dialogs; Help window topic titles; About panel tagline; first-run welcome dialog.
- **Help body prose remains English** — topic titles and navigation are localized; detailed paragraph text is English-only in this release, consistent with many macOS applications.

---

## v3.1 — 2026-04-11

### Stream / Queue
- **Direct streams no longer pick up stale queue metadata** — radio and stream playback wasn't correctly isolated from the previous queue state.
- **Queue track indicator works immediately on tap** — optimistic flag set on tap so the playing-track highlight moves right away instead of waiting for the speaker to confirm.
- **`isQueueSource` set before DIDL guard** — fixes Apple Music queue detection; the guard was running too early and rejecting valid queue contexts.
- **Art no longer flips between images during same-track playback** — stable art URL selection per track.

### Artwork
- **Service-provided art preserved** — Apple Music / Spotify / SMAPI art is never overridden by cache or heuristic replacements.
- **Improved iTunes art scoring** — common words filtered from query terms; a 30% similarity threshold prevents low-quality matches from winning.
- **Station art override** — no longer blocks track-specific art search when a station track has its own artwork.

### Search
- **Release date from iTunes API** — shown in Apple Music search results for context.
- **Sort options** — relevance, newest, oldest, title, or artist.
- **Release-date enrichment for SMAPI services** — prepared but not yet active.

### History
- **Ignore TV / HDMI / Line-In toggle** — Settings option to exclude TV and line-in input from logged history.

---

## v3.0 — 2026-03-28

### New Features
- SMAPI music service browsing — connect TuneIn, Spotify, Deezer, TIDAL, and 40+ services
- Music Services setup guide with status indicators (Active / Needs Favorite / Connect)
- Dashboard: top tracks, top stations, top albums, day-of-week, room usage, listening streaks
- Quick stats pills (streak, avg/day, albums, stations, starred count)
- Card-based history timeline grouped by day
- Star/favorite tracks — star button in Now Playing and menu bar, toggle on/off, starred filter in history
- Custom date range filter with From/To date pickers
- Menu bar redesign: hero art, room status dots, star button, mute button, volume readout
- Proportional group volume scaling (optional, toggle in Settings)
- FlowLayout wrapping filter tags
- Shuffle disabled popover explanation
- App title changed to "The SonosController" (build number removed from title bar)

### Architecture
- 11 ISP service protocols (Playback, Volume, EQ, Queue, Browsing, Grouping, Alarm, MusicServiceDetection, TransportStateProviding, ArtCache)
- ViewModels depend on protocol types (NowPlayingServices, BrowsingServices, QueueServices)
- TrackMetadata.enrichFromDIDL — single DIDL parsing method (was 4 copies)
- TrackMetadata.isAdBreak / isRadioStream computed properties
- Art orchestration moved from View to NowPlayingViewModel.handleMetadataChanged
- ArtResolver slimmed to display-only with encapsulated state methods
- State mutations wrapped in service methods (updateTransportState, etc.)
- App sandbox enabled
- Universal binary (arm64 + x86_64)
- Keychain security: kSecAttrAccessibleWhenUnlockedThisDeviceOnly + error checking
- 100 unit tests

### Performance
- Removed NowPlayingViewModel duplicate SOAP polling
- @Published change guards on all TransportStrategy delegate methods
- Dashboard stats cached in @State
- Position timer 1s with 0.5s change threshold
- SQL-based history filtering for 50,000+ entries
- SSDP receive timeout 5s (was 1s)
- scanAllGroups runs in background (non-blocking)

### Bug Fixes
- Radio station name preserved on pause
- Ad break artwork: station art shown, not stale track art
- Station change clears all radio art state
- Local file art not overridden by iTunes search
- Time bar resets on source change
- Spinner only during initial connection, not during ads
- Queue artwork for local library tracks
- History dedup uses track duration for window
- RINCON device IDs filtered from metadata and history
- Volume/mute correctly syncs on zone switch
- Service tag shows service name not station name
- Metadata polling CPU spin guard (continue → return)
- Silent catch blocks replaced with logging throughout

### Removed
- Alarm UI (Sonos S2 uses cloud API, UPnP returns empty)
- Old table-style history list (replaced by card timeline)
- Timeline spine from history cards

---

## v2.1

- Group presets with per-speaker volumes and EQ
- Play history with stats window and CSV export
- Home theater EQ (soundbar, sub, surrounds)
- Menu bar mode with quick controls
- Playlist service tags
- Recently played quick-access
- Queue shuffle, drag-drop reorder
- Crossfade toggle, pause all / resume all
- SMAPI browsing (beta)
- Many UI improvements

## v2.0

- 13 languages
- Dark mode and appearance customization
- UPnP event subscriptions (GENA)
- Persistent art URL caching
- Service identification and filtering
- Album art search (iTunes API)
- Browse search and navigation

## v1.0

- Initial release: native macOS Sonos controller for Apple Silicon
