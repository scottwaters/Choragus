# Changelog

## v3.6 — 2026-04-24

Scrobbling, keychain consolidation, scroll-wheel volume, and a round of
correctness fixes around music-service filtering.

### Last.fm scrobbling
- **Settings → Scrobbling** — new tab. BYO Last.fm API app (register at
  last.fm/api/account/create, paste API key + shared secret). Test
  credentials, browser-based OAuth via `auth.getSession`, no bundled
  credentials, no shared-key exposure.
- **Generic `ScrobbleService` protocol** — Last.fm is the only
  implementation today but the manager, persistence, and UI all go through
  the protocol so additional services can be dropped in without touching
  the orchestration layer.
- **Batch submission, 50 tracks per call** (Last.fm's documented cap),
  with per-track acknowledgement parsing and retry-classified failures.
- **Filter by room** — substring match, case-insensitive, covers single
  playback, grouped playback (`"Office + Kitchen"`), and custom group
  names. Earlier split-equality match was replaced after it missed most
  real-world group names.
- **Filter by music service** — sid-mapped against the authoritative Sonos
  service IDs (Apple Music 204, Spotify 12, TuneIn 254, SoundCloud 160,
  YouTube Music 284, Sonos Radio 303, Calm Radio 144, Amazon Music 201,
  Local Library). Earlier keyword-only match silently dropped Apple Music
  and YouTube Music tracks — their URIs never contain the literal
  service name.
- **Permanent vs filter ineligibility** — structural rejections (< 30 s
  with known duration, > 14 days, missing artist/title) persist to
  `scrobble_log` so we stop re-considering them; filter-driven skips
  don't persist, so a filter change re-qualifies the row on the next run.
- **Reset ignored** button — clears prior ignore decisions when filters
  change.
- **Filter preview** diagnostic — shows, for the next N pending rows, how
  many would send, how many are blocked by room filter (with sample
  rows), how many by service filter (with sample URIs). Answers "why
  isn't this scrobbling?" without log-diving.
- **Recent non-scrobbled list** — shows Last.fm's per-track rejections
  (timestamp, artist/title, reason text straight from their response).
- **Radio streams now eligible** — duration=0 is treated as "unknown,
  assume OK" instead of "< 30 s, reject". Continuous streams submit
  without the duration parameter.

### Unified secrets store
- All credentials (Last.fm + SMAPI tokens for every service) now live in
  a single Keychain item. One authorization prompt per rebuild instead of
  one per stored item. Existing items under the old per-service
  namespaces migrate automatically on first launch.

### Scroll-wheel volume + middle-click mute
- Mouse scroll on the selected speaker adjusts volume with a 300 ms
  debounce on the SOAP commit so fast flicks don't stack calls.
- Middle-click toggles mute.
- Queue/stream next/prev button enablement corrected — previously
  group playback of a queue was treated as a radio stream when the
  track carried piggybacked station metadata.

### Localization
- Scrobbling UI strings added to every supported locale (13 languages).

### Fixes
- **Paste in Settings** — the Edit menu had been hidden globally, which
  unintentionally broke `⌘V` resolution in credential fields.
- **Last.fm error 13 on batches containing `+`** — form-encode now uses
  the RFC 3986 unreserved character set. `+` percent-encodes to `%2B`
  instead of round-tripping as a space. Tracks like "Mike + the
  Mechanics" were failing the whole batch they were in.

### Known not-viable
- Amazon Music, YouTube Music, SoundCloud, and Apple Music (as a
  Sonos SMAPI service) are gated on Sonos-identity authentication —
  confirmed by live probe of `getAppLink` against each. Third-party
  apps cannot drive these services. Scrobbling of listens via the
  official Sonos app still works. See `docs/TODO.md` for details.

## v3.51 — 2026-04-23

Performance-focused maintenance release targeting Sonos S1 hardware and other
request-sensitive coordinators, plus the queue-visibility polish that surfaced
while diagnosing it.

### S1 performance
- **`GetHouseholdID` cached per device** — speakers' household IDs never change
  at runtime. Previously we re-queried on every SSDP response (13+ extra SOAP
  calls per 30-second rescan cycle); now fetched exactly once per device for
  the app's lifetime.
- **Topology refresh throttling (10 s per household)** — SSDP response bursts
  (home-theater bundles advertising each sub-device separately) no longer
  trigger back-to-back `GetZoneGroupState` calls. User-initiated group changes
  (`joinGroup`, `ungroupDevice`, preset apply) pass `force: true` to bypass
  the throttle for immediate UI feedback.
- **Removed redundant queue pre-count** — `AddURIToQueue` used to do an extra
  `Browse(Q:0) count=1` just to compute the insertion position before the
  actual add. Sonos's `DesiredFirstTrackNumberEnqueued=0` natively means
  "append at end"; the pre-count is gone, cutting one round-trip per add.
- **Single-track optimistic queue append** — single-track `AddURIToQueue` now
  posts the new `QueueItem` via a userInfo payload on `.queueChanged` so the
  queue panel appends it locally without an extra `Browse(Q:0)` reload. Per
  single-track add: 3 SOAP calls → 1.
- **Batch track adds via `AddMultipleURIsToQueue`** — album adds and multi-
  select enqueues now go through a single SOAP call per 16-track chunk (Sonos
  firmware limit) instead of N sequential `AddURIToQueue` calls. On S2 a
  14-track album completes in ~1-2 s.
- **Auto-fallback to per-track on batch rejection** — if the firmware rejects
  the batch action (UPnPError 402 or similar), the code transparently falls
  back to sequential `AddURIToQueue` with the already-known URIs. Slower but
  always works on the S1 firmware versions that don't accept the batch form.
- **Corrected `AddMultipleURIsToQueue` wire format** — original implementation
  was double-escaping each DIDL (pre-escape + envelope escape) producing
  `&amp;lt;DIDL…` on the wire, which the speaker parsed as invalid args and
  rejected with 402. Now follows the SoCo / node-sonos-ts / jishi convention:
  raw DIDL joined with a single ASCII space, single XML-escape at envelope
  level only.
- **Per-track fallback breaks on first timeout** — avoids hammering an already-
  unresponsive S1 with a dozen more doomed SOAP calls after the first one
  times out. Whatever succeeded before the break is reported; the failure
  surfaces in the red error banner.

### Queue visibility
- **Clear Queue spinner** — the trash icon swaps to a spinner while the
  `RemoveAllTracksFromQueue` SOAP is in flight.
- **Queue loading spinner on every load** — `loadQueue` now always sets
  `isLoading = true` at the start. Full-screen "Loading queue…" spinner when
  the panel has no items to show (first launch, speaker switch, cleared
  queue). Inline header spinner when items are already present, so the
  existing list stays visible during a background reload.
- **"Adding to queue…" spinner during in-flight adds** — new `@Published
  isAddingToQueue` on `SonosManager` drives a spinner in the queue panel
  while a batch add is progressing, not only during the final reload. On
  S1 where the per-track fallback takes 30-40 s, the spinner covers the
  whole operation.
- **Green info banner on successful adds** — `ErrorHandler.info(_:)` shows a
  transient green banner at the top of the window ("Add to Queue: 14
  tracks"). An immediate "Adding N tracks…" banner appears the moment the
  action is invoked, so the user gets feedback before any SOAP round-trip
  completes. Red error banner surfaces SOAP faults that were previously
  being swallowed by `try?`.

### Queue synchronisation
- **Speaker-switch queue reload** — `QueueView` now reacts to the external
  `group` prop changing (previously the `@StateObject` held on to the
  originally-captured group). Switching speakers now clears the queue,
  updates `vm.group`, and triggers `loadQueue` against the new coordinator.

### Bug fixes
- **"+ Float Play 5 + Office" display glitch** — `SonosGroup.name` no longer
  emits a leading "+ " when the coordinator isn't present in the members
  list (transient topology inconsistency edge case).

### Removed
- **Topology grace windows** — the group-level and member-level grace timers
  introduced earlier in v3.5 turned out to create phantom groups under
  Sonos's topology eventual-consistency quirks, and to delay user-initiated
  grouping actions by up to 30 s. Replaced by a simple latest-response-wins
  merge that accurately reflects what the most recent speaker said.

### Known limitations
- Switching speakers while a multi-track batch add is in flight can leave
  the queue panel targeting the wrong coordinator for its post-add reload —
  tracked under the top High Priority item in `docs/TODO.md` for a proper
  fix. Workaround: wait for the green "Add to Queue: N tracks" banner before
  switching rooms.

---

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
