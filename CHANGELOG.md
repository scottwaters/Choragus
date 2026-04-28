
# Changelog

## v4.0 — 2026-04-27 — Choragus

The project has been renamed from **SonosController** to **Choragus** in respect of the Sonos trademark.

The bundle identifier moves to `com.choragus.app` to match the rename, and the Keychain service name now follows suit. Sandbox container, Keychain service, and the signed Developer ID identity all line up with the new bundle. **One-time cost**: Last.fm and SMAPI services need to be re-authenticated on first launch — those credentials lived in Keychain entries scoped to the old service name and aren't migrated forward. Reading them with the new signed binary would have prompted the user to "allow access to keychain item created by SonosController.app" on every launch until they clicked through; cleaner to wipe the bridge entirely and ask for one re-auth pass. Play history, art cache, and the SQLite metadata store live in the sandbox container, which already moved to `com.choragus.app` when the bundle ID flipped in the v4.0 work — they aren't touched by this change. Older entries in this changelog reference "SonosController" by name; that history is preserved as-is.

### Discovery — Bonjour added alongside SSDP

Discovery used to rely solely on SSDP M-SEARCH multicast to `239.255.255.250:1900`. On networks where Sonos speakers live in a separate VLAN — common with IoT segmentation on UniFi, OPNsense, and similar — SSDP multicast typically does not cross the VLAN boundary, so the controller could not see the speakers even though plain unicast to port 1400 worked.

Choragus now ships an `NWBrowser`-backed mDNS discovery transport (`_sonos._tcp`) that runs alongside SSDP. The Bonjour TXT record carries the same `location` URL that SSDP would surface in its M-SEARCH response, so the entire post-discovery pipeline (device-description → topology → browse) is unchanged.

- **Auto** (new default) runs SSDP and Bonjour in parallel and dedupes by location URL. Flat networks see no behavioural change; segmented networks where mDNS is reflected light up without configuration.
- **Bonjour** restricts discovery to mDNS only.
- **Legacy Multicast** restricts discovery to SSDP only — the original behaviour, kept as an escape hatch.

Speakers discovered via Bonjour also surface their household ID in the TXT record, which lets the app skip one `GetHouseholdID` SOAP round-trip per speaker. This is a measurable win on S1 hardware, which is sensitive to request pressure during topology discovery.

Setting lives in **Settings → System → Network → Discovery**. `NSBonjourServices` was already declared in `Info.plist` from prior work, and the existing `NSLocalNetworkUsageDescription` covers the Local Network permission for both transports.

Issue and approach reported by [@mbieh](https://github.com/mbieh) ([#11](https://github.com/scottwaters/SonosController/issues/11)) including the verification dump and the parallel-merge design recommendation. Initial implementation contributed by [@steventamm](https://github.com/steventamm) in [#12](https://github.com/scottwaters/SonosController/pull/12) — the `NWBrowser` transport, the `SpeakerDiscovery` protocol abstraction, and the 13-locale translation work all started from that PR.

### Now Playing — tabbed details panel

The Now Playing screen's bottom area is now a three-tab `TabView` instead of a single scrolling block:

- **Lyrics** — synced word-by-word lyrics from LRCLIB when available (auto-scroll, centre-focused gradient, font-weight ramp toward the active line). Plain lyrics fall back to centre-justified text in a normal scroll view with increased line spacing matched to the synced layout. Manual offset slider compensates for stream/lyric clock drift in 250 ms steps.
- **About** — artist bio, photo, tags, and related artists pulled from Wikipedia and Last.fm; album release date and tracklist from MusicBrainz when available. Right-click → Refresh metadata; click the photo to open a larger view; click the Wikipedia link to open the article.
- **History** — recent plays of the current track, scoped to whichever room is active.

The whole panel is collapsible via a chevron in the section header. Collapse state persists across launches in `UserDefaults[nowPlayingDetails.collapsed]` so it's out of the way for users who don't want it.

Tab labels honour the app language — the SwiftUI segmented `Picker` caches its rendered labels, so a `.languageReactive()` modifier (`.id(appLanguage)`) is applied to force a rebuild when the language flips.

### Localised metadata sources

Wikipedia, MusicBrainz, and Last.fm queries now follow the user's app language rather than the system locale.

- **Wikipedia** — `MusicMetadataService.fetchLocalisedWikipediaSummary` queries the per-language subdomain (e.g. `de.wikipedia.org`, `ja.wikipedia.org`) with `Accept-Language` set; falls back to `en.wikipedia.org` if the article isn't available in the user's language.
- **Last.fm** — `artist.getInfo` and `album.getInfo` carry a `lang=` parameter mapped from the app-language code.
- **Cache keys** — language code is now part of the SQLite cache key prefix, so e.g. an English bio and a German bio for the same artist coexist instead of overwriting each other. A one-shot UserDefault flag (`metadataCache.langPrefixMigrated.v1`) drives a SQLite UPDATE on first launch under v4.0 that renames any unprefixed legacy `artist:<x>` row to `artist:en|<x>`.
- **Reduced load on third-party APIs** — bios, tags, release dates, and similar-artist lookups are cached permanently in the SQLite metadata store. Wikipedia, MusicBrainz, and Last.fm are operated by small teams or community projects that explicitly ask third-party clients to cache aggressively; v4.0 honours that. A track skip never re-fetches data we already have, and a language flip only re-fetches the rows we don't have in the new language. Manual refresh (right-click → Refresh metadata) and the **Settings → Image Cache → Clear** action remain available for users who want to force a re-pull.

Helpers: `MusicMetadataService.wikipediaLanguageCode()` for Wikipedia subdomain selection (with `zh-Hans → zh.wikipedia.org` plus an `Accept-Language: zh-Hans` header), and `MusicMetadataService.lastFMLanguageCode()` for the Last.fm `lang=` value.

### Apple Music drill-down sort controls

`AppleMusicArtistView` and `AppleMusicAlbumView` now expose a sort menu with **Relevance**, **Newest**, **Oldest**, **Title**, and **Artist**. Sorting is purely client-side over the iTunes Search response — no extra request — so flipping between sort options is instant. Sort selection persists per drill-down level.

### Pandora identification

Pandora was missing from the Music Services list because the app's RINCON-based service ID lookup didn't recognise its SMAPI sid. Pandora uses **SMAPI sid 3** (the public sid documented in SoCo and other open-source Sonos libraries) which is distinct from its RINCON service descriptor (519). `SonosConstants.ServiceID.pandora = 3` is now defined, the service surfaces in `Settings → Music` with the standard service-row UI, and is shown as **untested** with a note that Pandora is US-only as of 2026. Connecting it goes through the standard SMAPI AppLink flow; please open an issue with the result if you try it.

### Audible promoted to working

Audible is now in the tested-blue services list. AppLink auth completes cleanly and audiobook playback works through the standard SMAPI URI patterns; chapter navigation surfaces as a Sonos queue.

### Home Theater EQ — full controls always visible

When editing a preset for a Home Theater zone, the Sub level/polarity, Surround level/balance, Night Mode, and Dialog Enhancement controls now show as soon as the EQ tab is selected. Previously the section guard was tied to whether the topology had finished classifying the zone as HT (`isHTZone`), so cold-launch races would render only Night Mode + Dialog Enhancement until the user toggled the include-EQ switch off and back on. The outer guard now keys off whether `preset.homeTheaterEQ` has been hydrated rather than the live topology state, and `ensureHomeTheaterEQInitialised()` is called on `.onAppear`, on `.onChange(of: preset.coordinatorDeviceID)`, and on `.onChange(of: isHTZone)` so any path into the editor — first open, coordinator change, late topology classification — populates the EQ struct and reveals the full controls.

### Settings — section labels within each tab

Settings keeps its four tabs (Display, Music, Scrobbling, System) but each tab now has explicit labelled sub-sections rather than a flat list of toggles. Display gets `Language`, `Appearance`, `Mouse Controls`. System gets `Network` (with its own Updates / Startup / Discovery rows) and `Cache`. Communication-mode, Startup-mode, and Discovery-mode picker labels are localised via new `displayName` computed properties on `CommunicationMode` / `StartupMode` / `AppearanceMode` / `DiscoveryMode`, and the segmented pickers are decorated with `.languageReactive()` so SwiftUI's cached label rendering rebuilds on language flip.

### Signed Debug builds

`dev-build.sh` (lives in the parent `SonosApp/scripts/` directory, deliberately outside the repo so signing details never touch GitHub) now signs Debug builds with the same Developer ID Application identity that `release.sh` uses for distribution. Stable code signature across rebuilds means macOS Keychain ACL prompts (Last.fm, SMAPI tokens) appear once on first install instead of on every rebuild. Bare `xcodebuild` invocations still work for syntax-only checks but produce ad-hoc signatures that re-prompt the keychain.

### Project rename — file system

- Bundle identifier: `com.sonoscontroller.app` → `com.choragus.app`. Sandbox container moves accordingly.
- Executable: `SonosController` → `Choragus`. Output path: `Choragus/build/Choragus.app`.
- Keychain service: renamed in line with the bundle. One-time re-authentication of Last.fm and SMAPI services on first launch under v4.0 (the cleanest way to avoid per-launch "allow keychain item created by SonosController.app" prompts).
- App Support directory: `~/Library/Containers/com.choragus.app/Data/Library/Application Support/Choragus/`. Play history, art cache, art URL cache, presets, and metadata cache all moved with the container — no migration step needed.
- Xcode project, scheme, package, and target names all updated; signing config in `project.pbxproj` is signing-neutral so forks build cleanly with their own Developer ID identity.

### Localisation

- v4.0 adds ~120 new L10n keys across the Help rewrite, Now Playing tab labels, sectional Settings labels, and the Pandora/Audible service rows. All 13 locales (en, de, fr, nl, es, it, sv, nb, da, ja, pt, pl, zh-Hans) ship complete translations.
- `AppLanguage` flips re-render the AppKit-hosted About box and Help windows via a `LanguageReactiveContainer` wrapper that observes `@AppStorage(UDKey.appLanguage)`. Without it, SwiftUI views inside `NSHostingController` ignore the change.
- Segmented `Picker` controls (Communication mode, Startup mode, Discovery mode, Now Playing tabs) get `.languageReactive()` applied so their cached label rendering is invalidated on language flip.

### Notes / housekeeping

- "For Fun" visualisations are paused in v4.0. The view file remains in the tree but `WindowManager.openForFun()` is a no-op stub, and the Window-menu entry is hidden. Will return when the visualisation work has a clearer data-meaning story.
- Older entries in this changelog reference "SonosController" by name; that history is preserved as-is.

## v3.71 — 2026-04-25

- **SoundCloud moved to blocked list.** `getAppLink` returns
  `Client.NOT_AUTHORIZED` (403) to non-Sonos clients, so SoundCloud
  can't be driven by a third-party controller. It was incorrectly shown
  in the "Connect" section in v3.7. Now correctly grouped with Amazon
  Music and YouTube Music as Sonos-identity-gated. Service-status matrix
  updated; Plex now listed as a working AppLink service.

## v3.7 — 2026-04-25

Signed + notarized distribution, Plex promoted to a tested service,
Spotify Keychain recovery, album-art single-source-of-truth, a first-run
language picker with system-locale detection, and a localization sweep
over every remaining English-only surface.

### Distribution
- **Developer ID + Notarization** — release `.zip` is signed with an Apple
  Developer ID and notarized by Apple. First launch is clean on any Mac.
- **Installing on macOS** — README section simplified from a multi-step
  Gatekeeper workaround to 3 lines: download, drag, launch.

### Plex integration
- **Promoted to tested SMAPI service** — `MusicServicesView` now lists
  Plex in `testedAppLinkServices`. `getAppLink` returns HTTP 200 with a
  usable `regUrl` at `app.plex.tv/auth`, and playback DIDL built from the
  `SA_RINCON<sid>_X_#Svc<sid>-0-Token` pattern is accepted.
- **Session-minted `linkDeviceId`** — Plex's AppLink flow returns a
  per-install device ID that must be echoed back in
  `getDeviceAuthToken`; `AppLinkResult` now carries it and SOAP faults
  from the poll endpoint are treated as "not linked yet" so polling
  continues rather than aborting.
- **Plex-specific URI overrides** — `serviceURIExtensions` adds `.mp3`
  for Plex and `serviceFlagsOverrides` adds flags `8232`
  (SMAPI-resolution) so `AddURIToQueue` / `SetAVTransportURI` don't hit
  UPnP 714.
- **Streams are direct from user's own Plex server** — no third-party
  CDN, no short-lived signatures.
- **Active/Needs Favorite** — `servicesNotNeedingSN` includes Plex
  (self-hosted, no `sn=` required).

### Spotify / Keychain
- **Zombie token cleanup** — `SMAPITokenStore.load()` drops entries whose
  Keychain data is missing (a side-effect of the v3.6 up-front migration
  that promoted keys but dropped values on some setups). Token JSON is
  rewritten so Spotify re-appears after one re-authorize.
- **Lazy legacy fallback** — `SecretsStore` no longer runs an up-front
  migration (which was `SecItemCopyMatching` with `kSecReturnData` on
  every launch, triggering a prompt per credential). Instead on cache
  miss it reads the legacy location and promotes the value to the
  unified store. Prompt cascade per rebuild dropped from ~5 to 1.

### Art resolver
- **Single source of truth** — `ArtResolver.pinnedArtByTrackURI` is the
  canonical pin map; `artURLForDisplay` checks the pin first.
  `SonosManager` no longer substitutes cached art and
  `PlayHistoryManager` no longer runs iTunes searches — both were
  competing with the resolver and causing flicker between e.g. Redux vs
  original album covers on the same track.
- **User-action invalidation** via `invalidateArtResolution(for:)` so
  manual overrides (Search Artwork dialog, Ignore Art) take immediate
  effect.

### Localization
- **First-run language picker** — `FirstRunWelcomeView` now includes a
  `Picker` bound to `sonosManager.appLanguage`. `AppLanguage.systemDefault`
  walks `Locale.preferredLanguages` with per-variant handling for
  Simplified Chinese (`zh-Hans` / `zh-CN` / `zh-SG`) and Norwegian (`nb`
  / `nn` / `no`); falls back to English. `SonosManager.init` snapshots
  the detected value to UserDefaults on first launch so subsequent macOS
  locale changes don't silently override the user's choice.
- **UI localization sweep** — ~165 new L10n keys covering every
  right-click context menu, the Home Theater EQ tab, the alarm editor,
  the preset editor, browse context menus + search placeholders, the
  artwork search dialog, queue tooltips, the play-history row context
  menu, the full Listening Stats dashboard (hero cards, quick-stat
  pills, filter dropdowns, tabs, date ranges, search placeholder), the
  menu-bar mini-player, and About / License / Source Code sections.
- **Help body fully localized** — every heading / paragraph / bullet
  across 8 topics × 13 languages. Independent audit pass applied
  Apple-macOS-standard terminology:
  - Preferences vs Settings title/body consistency for da, ja, zh-Hans.
  - Sonos product conventions: French keeps "Home Theater" untranslated
    (matches sonos.com/fr-fr); zh-Hans uses 音箱 (Sonos PRC) rather than
    扬声器 (generic PA/loudspeaker); Swedish uses `sidofältet`
    (sidebar) rather than `sidofliken` (side tab).
  - Polish `Preset` for the Sonos preset concept, replacing the literal
    `Ustawienie` (setting).
  - Italian spelling (`proprietari` not `propietari`) and subject-verb
    agreement (`apparirà` not `appariranno`).
  - Dutch product-view name kept English (`Now Playing`) rather than
    capitalized `Nu Speelt`.
- **Date grouping respects app language** — new `L10n.currentLocale`
  returns a `Locale` matching the app-language preference. Use this on
  any `DateFormatter` / `NumberFormatter` instead of relying on the
  system locale. `PlayHistoryView2` switched; the rest of the app
  should migrate on next touch.
- **Swift 6 dict-literal dup-key crash fix** — v3.6 shipped with two
  `"never"` entries in the L10n translation dictionary; Swift 6 asserts
  on dict-literal duplicates at first access, producing an EXC_BREAKPOINT
  before the app draws a window. All latent duplicates removed:
  `"never"`, `bass`, `treble`, `loudness`, `hour1`, `hours2`,
  `ungroupAll`. The grep-based check
  `grep -nE '^[[:space:]]+"[a-zA-Z][a-zA-Z0-9_]*":[[:space:]]*\[' L10n.swift | awk -F'"' '{print $2}' | sort | uniq -c | awk '$1 > 1 {print}'`
  is now the recommended pre-commit gate.

### Minor
- **Plex browse timeout fix** — reverted an experimental
  `BrowseListView(.id(...))` change that was forcing full re-fetch on
  every back/forward navigation in the Plex drill-down. Drill-downs now
  use the existing `navStack` + `itemsCache` path.
- **SMAPI string constants** — new `SMAPIPrefix` enum + `strip(_:serviceID:)`
  helper replaces scattered magic-string handling for the
  `x-rincon-cpcontainer:` / `x-sonos-http:` / etc. URI prefixes.
- **Spotify playlist play fix** — `playContainer` / `enqueueContainer`
  now route through `playBrowseItem` / `addBrowseItemToQueue` for
  `x-rincon-cpcontainer:` URIs, preferring the container resourceURI
  instead of rebuilding DIDL from individual tracks (which was failing
  on some Spotify playlists with speaker error).

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
  official Sonos app still works.

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
  the queue panel targeting the wrong coordinator for its post-add reload.
  Workaround: wait for the green "Add to Queue: N tracks" banner before
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
