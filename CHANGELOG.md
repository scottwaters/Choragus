
# Changelog

## v4.9 — 2026-05-15 — MusicKit Apple Music, karaoke stutter fix, queue self-resync

Native Apple Music replaces the SMAPI-routed browse path, the karaoke window stops stuttering during playback, and the queue indicator self-corrects after track changes when Sonos's UPnP event stream disagrees with the speaker's actual state.

### Apple Music — MusicKit-backed

A complete native Apple Music surface backed by Apple's `MusicKit` framework, replacing the legacy SMAPI search/browse for Apple Music in release builds. Auth is handled by macOS's TCC prompt (Privacy & Security → Media & Apple Music); no Sonos-side configuration. Playback still flows through Sonos via the speaker's Apple Music SMAPI service — MusicKit drives discovery, search, metadata, and library access only.

- **Browse landing**: Your Library (Songs / Albums / Artists / Playlists), Recently Played, Made for You, Charts (Top Songs / Top Albums / Top Playlists), Genres, Stations For You (sourced from `MusicRecentlyPlayedContainerRequest` + `MusicPersonalRecommendation.stations`), Radio Stations (Apple Music catalogue station search), Now in Spatial Audio (Dolby Atmos albums filtered from the chart feed).
- **Search**: Spotify-style `Browse | Search` tab toggle. Sub-tabs `All / Artists / Albums / Tracks / Playlists`. The "All" tab does the original prefix-5 + "See All" overview; per-category tabs hand off to the same list views used by drilldowns (sort pickers, right-click context menus, bulk action bars).
- **Prefix-matching search**: every search runs `MusicCatalogSearchRequest` and `MusicCatalogSearchSuggestionsRequest(includingTopResultsOfTypes:)` in parallel and merges results (top-results first, then broad search, de-duped by id). Apple Music's plain catalogue search misses prefix queries ("yankov" returns no Yankovic); the suggestions API with top-results does the prefix completion the same way the Apple Music app's type-ahead does.
- **Detail views**: Album / Artist / Playlist / Recommendation / Library / Genre drilldowns, all with right-click context menus (Play Now / Play Next / Add to Queue) on every row and bulk action bars (Play All / Add All Next / Add All Last) at the top. Sort pickers everywhere (Title / Artist / Album / Duration / Date Added / Release Date for tracks; Title / Artist / Newest / Oldest / Recently Added for albums; Name for artists / playlists / genres). Defaults: alpha for tracks/artists/playlists/genres, release-date-oldest for albums.
- **Artist drilldown** splits into two further drilldowns ("Top Songs" → track list, "Albums" → album list) instead of an inline scroll, matching the Apple Music app's structure.
- **Library artwork via Apple's `ArtworkImage` view**. Library item artwork URLs use a `musicKit://artwork/transient/...` scheme that `URLSession` cannot load. A new `MusicKitArtworkRegistry` stashes each `Artwork` value against the URL it would render to so `AppleMusicArtworkSquare` / `AppleMusicArtworkCircle` can render via Apple's native `ArtworkImage` — catalogue items still use the existing `CachedAsyncImage` path with the https URL.
- **Settings entry** (`AppleMusicKitConnectRow`) sits in Settings → Music Services with Connect / Re-check / Open System Settings actions. The Browse-pane sidebar entry auto-shows when MusicKit authorisation flips to `.authorised` and auto-hides if access is revoked, mirroring how the other services (TuneIn, Calm Radio, Sonos Radio) only surface their entry when enabled. Persisted via a new `appleMusicKitConnected` `@AppStorage` flag.
- **Legacy SMAPI Apple Music is removed from release builds**. Dev builds keep both visible for side-by-side comparison via the `SHOW_LEGACY_APPLE_MUSIC` compilation condition; the signed release omits it. The Settings → Music Services row for the legacy SMAPI Apple Music is also filtered out when `showLegacyAppleMusic` is false so there's no dead toggle.
- **Library item filtering**: `playParameters != nil && !title.isEmpty && !artistName.isEmpty && trackCount > 0` for albums; `playParameters != nil && !title.isEmpty && !artistName.isEmpty` for songs. Hash-style library ids (negative or 13+ digit positives) and letter-prefixed ids (`l.`/`p.`/`r.`/`i.`) route through a title+artist catalogue resolve at play time so Sonos receives a catalogue-shape song id; without the resolve `AddURIToQueue` faults with SOAP 800. The `idLane` heuristic was widened to accept legacy small artist ids (Beatles `136975`, etc.) — anything in `0 < id ≤ 1e12` counts as catalogue.

### Karaoke stutter — architectural fix

Resolved a ~70–85 ms main-thread stall that fired on every 1 Hz position update and dropped frames in `SlidingLyricsView`'s `TimelineView(.animation)`. Diagnosed via a new `MainThreadHeartbeat` probe (DEBUG-only; release builds drop the type and call site entirely).

- **Split high-churn playhead state out of `SonosManager`** into dedicated `PositionTracker` (`groupPositions`, `groupDurations`) and `AnchorTracker` (`groupPositionAnchors`) `ObservableObject`s. Internal writes route through the trackers; the original property names on `SonosManager` remain as computed forwarders so `TransportStateProviding` protocol consumers and `NowPlayingViewModel` keep compiling without changes. `SonosManager.objectWillChange` no longer fires for any position-related state.
- **Wired the trackers as separate `@EnvironmentObject`s** in `ChoragusApp` (WindowGroup + Settings) and explicitly on the karaoke / ClubVis windows in `WindowManager`. `LyricsKaraokeWindow` now observes `anchorTracker` for anchor reads instead of `sonosManager`; ClubVis and Now Playing got the same treatment so their re-renders only fire when the anchor actually changes.
- **Content-equality gate on `groupTrackMetadata` publishes**. `TrackMetadata` includes `position` and `duration` fields that get rewritten on every 1 Hz poll — full-struct equality tripped the publish gate every poll and re-evaluated every observing view. New `TrackMetadata.contentEquals(_:)` compares every field except `position` / `duration`; both publish gates now use it.

### Queue current-track self-correction

After a Prev/Next click, queue-row jump, or seek-then-auto-advance, Sonos's UPnP event stream has been observed to push wrong / stale track metadata for several seconds. Diagnosed against the Sonos iPhone app showing the correct state while our metadata insisted otherwise.

- `QueueView` tracks `lastObservedTrackURI` and schedules a 2 s-debounced `vm.refreshCurrentTrack()` on any `trackURI` change in `groupTrackMetadata`. The refresh calls `sonosManager.getPositionInfo(group:)` directly and updates `currentTrack` only — no queue browse, no loading spinner — same authoritative path the manual Refresh button uses. Whichever source (events or polls) happens to be racy in a given moment, the speaker's direct response wins.
- Removed an earlier stale-poll guard (`TrackMetadataSource.event` vs `.poll`) from `transportDidUpdateTrackMetadata`. Empirically Sonos's events also lie after a seek/auto-advance combo, so dropping disagreeing polls sometimes filtered the only correct source. The `TrackMetadataSource` enum stays on the protocol for future use.
- `addBrowseItemToQueue(playNext: true)` skips the optimistic-append payload and forces a full reload. Insert-at-N shifts every following row's id by one; the simple "append by id" path was dropping the new row as a duplicate of the track that just shifted down, leaving the queue stuck after a "Play Next".

### UX / Settings

- **Lyrics timing offset** moved from its own Lyrics tab to Settings → Visualisations → Karaoke alongside the karaoke style picker. The standalone Lyrics section is removed.
- **Manual album-art selection propagates to `ArtCacheService`** via `sonosManager.cacheArtURL(...)` so the karaoke window and play history reflect the user's choice immediately. Previously the Now Playing panel updated but `artCache.lookupCachedArt(uri:title:)` — which the karaoke window reads through — kept returning the auto-resolved URL.
- **Full-row back-button hit targets** across every drilldown header. `MusicKitAppleMusicView.detailBar`, `BrowseView` Plex / TuneIn / SMAPI drill headers, and `PlexDirectBrowseView` now wrap the entire `chevron + title + Spacer` HStack in a single Button with `.contentShape(Rectangle())`. A click anywhere across the bar pops the nav stack.

### Diagnostics

- **Diagnostics → Save Encrypted Log File…** Pick the destination via NSSavePanel instead of being routed to Downloads + GitHub. Same `BugReportBundle` envelope shape as the Report Bug (encrypted) path, minus the forced reveal and GitHub form open. Visible only when `BugReportEncryptor.isConfigured` (release builds). L10n keys `diagSaveEncryptedLog` / `diagSaveEncryptedLogHelp` added with translations for all 13 supported languages.
- **Portable-speaker diagnostic** for issue #37. New `SonosDevice.isPortable` flag (modelName contains "Move" or "Roam"). `setVolume(device:)` logs `[PORTABLE_VOL] setVolume on portable …` with model + group context when the target is a portable. `updateDeviceVolume(_:volume:)` logs `[PORTABLE_VOL] Portable … reports volume=0` with model + transport URI + transport state + group state when a portable reports zero — the signature for Sonos's Bluetooth-input quirk where the WiFi-side `RenderingControl` accepts SOAP but the audio pipeline ignores the value because it's reading from BT. Combined with the existing `[RC-VERIFY]` debug-log lines, the bug bundle from an affected user traces intent → SOAP send → verify read → next event without the maintainer needing a Move to reproduce.
- **`MainThreadHeartbeat` probe** (DEBUG-only). Background utility-queue `DispatchSourceTimer` pulses every 10 ms, dispatches a tiny block to `DispatchQueue.main`, measures the delivery delay. Delays > 50 ms log as `[MAIN-STALL] <N>ms` via `sonosDebugLog`. Coalesces back-to-back pulses behind one long stall to a single log line. Release builds drop the type and start call entirely via `#if DEBUG`.

### Internal

- New file `Choragus/AppleMusic/AppleMusicDetailViews.swift` — album / artist / playlist / library / recommendation / genre / station detail views.
- New file `Choragus/AppleMusic/AppleMusicKitConnectRow.swift` — Settings entry.
- New file `Choragus/AppleMusic/AppleMusicPlaybackHelpers.swift` — `AppleMusicPlayHelper`, sort enums, `AppleMusicBulkActionTracker`, context-menu builders, DIDL construction (`00032020song%3a<id>` + `parentID="0004206calbum%3a<albumID>"` + `cdudn=SA_RINCON<rinconServiceType>_X_#Svc<rinconServiceType>-0-Token`).
- New file `Choragus/AppleMusic/MusicKitAppleMusicView.swift` — root browse view with manual breadcrumb stack (`@State path: [AppleMusicDestination]`) replacing the SwiftUI `NavigationStack` which was hijacking the whole-app navigation context.
- New file `Packages/SonosKit/Sources/SonosKit/Services/PositionTrackers.swift` — `PositionTracker` + `AnchorTracker` observable objects.
- New file `Choragus/MainThreadHeartbeat.swift` — DEBUG-only main-thread responsiveness probe.

## v4.8 — 2026-05-10 — Back of the Club visualisation

A focused release for a new full-screen "club back wall" visualisation, the surrounding plumbing (Visualisation menu group, settings reorganisation, Up Next gating fix, bio render correctness) and the localisation refresh that goes with it.

**Back of the Club ships as beta.** Layout, lighting, tile-pool weighting, and the surrounding settings are subject to change in subsequent releases as the design lands.

### Back of the Club visualisation

- New full-screen popout (`⌘J` / Visualisation menu / toolbar). Renders to a fixed 1920×1080 logical canvas and fullscreens cleanly to native 4K. Layout is a tiled poster wall under a slow warm-bar lighting cue, with the now-playing card in the foreground and an Up Next + artist-info column on the right.
- **Tile pool tiers.** The wall sources artwork from: (1) queue items — always preferred; (2) tier-1 history rows whose genre matches any queue-item genre; (3) tier-2 history rows whose genre is adjacent to the queue's genre set; (4) random history sprinkle (configurable percentage of cells); (5) ambient wallpaper. Pool is deduplicated — never the same URL on two cells. Radio-stream URIs are excluded at every step so only real album art enters the wall.
- **Wall packing.** Greedy random placement of 3 large 4×4 super-cells, ≥28 medium 3×3 cells, and 1×1 fill across a 25×14 grid. A constraint-driven sweep breaks any 1×1 run of length ≥ 3 by force-placing extra 3×3s, keeping rows and columns visually varied.
- **Lighting cue.** Fixed warm bar palette (amber / magenta / indigo). The cue picker iterates with no sequential repeats so the vis never holds the same hue twice in a row.
- **Now-playing card.** Left-side card holds the album art, settled-key-gated so the card never flashes a station logo across an inter-track metadata gap. iTunes radio-track-art lookup gated to radio playback only — service streams (Spotify / Apple Music) keep their DIDL art instead of falling through to a popularity-ordered iTunes search that could resolve to the wrong cover (the Weird Al "Like a Surgeon" / *Dare to Be Stupid* case).
- **Artist info panel.** Right-column card sourced from `last.fm artist.getInfo` via `MusicMetadataService.artistInfo` (with Wikipedia + MusicBrainz fallbacks, cached per artist + language). Shows artist name, scrolling bio (rasterised once per track to a `CGImage` and drawn into a SwiftUI `Canvas` for sub-pixel scrolling), and genre tags pinned at the bottom.
- **Up Next list.** Right column above the artist panel. Gates on `queueItems` non-empty so Spotify Radio / Apple Music DJ tracks (where Sonos populates `stationName` despite a real queue) keep the list visible. True radio (empty queue) hides it automatically.
- **Hero / wall fade pipeline.** Wall cross-fades to a new shuffle on track change; per-slot fade-in / fade-out over 3.2–5 s. Queue mutations (add / re-order / remove) update Up Next and the tile pool in place — they no longer trigger a full wall rebuild, so adding a song mid-track doesn't flash the whole wall.

### Visualisation menu group

- New top-level **Visualisation** menu containing Karaoke (⌘K) and Back of the Club (⌘J). Both moved out of the View menu, where they previously shared space with the panel toggles.
- New toolbar `sparkles.tv` menu opens the same group from the main window.
- Menu labels simplified to **Karaoke** and **Back of the Club (beta)**. The longer descriptive strings (e.g. `popOutLyrics` / `Pop out for karaoke view`) survive as tooltips for context.

### Vis settings reorganised

- Vis tab in Settings now has a single **Back of the Club** section with one row per setting and a short caption underneath each control: genre matching mode, random sprinkle percent, About panel toggle, history source.
- New help-text strings (`visGenreMatchingHelp`, `visRandomArtMixHelp`, `visShowAboutPanelHelp`, `visHistorySourceHelp`) localised across all 13 languages.

### Bio Canvas rendering correctness

- Bio text rasterises once via `ImageRenderer` and draws into a SwiftUI `Canvas` for sub-pixel vertical scrolling. The previous `Image().offset(y:)` approach snapped to pixel boundaries and stepped visibly at the slow 5 pt/s cycle.
- Fixed a track-change regression where the Canvas kept drawing the previous artist's bitmap. Removed `Equatable` conformance from the bio sub-view — Equatable was letting SwiftUI skip propagating the new bitmap into the inner `TimelineView` content closure, leaving every track-change render one bitmap behind.
- Stale-fetch guard: artist-info fetches that arrive after a subsequent track change are discarded so the panel never flashes the previous artist's metadata.

### Karaoke window polish

- Wordmark resized to 64 pt height (matches the Back of the Club header). Width left unconstrained so `.scaledToFit()` picks the natural aspect-correct width — a fixed 320 pt frame had pulled the trailing edge inward from the album-art leading edge.
- App icon removed from the karaoke header; only the wordmark remains.

### Other

- **Window leak fix.** `NSWindow.contentViewController = nil` on `willClose` for both visualisation and karaoke popouts so the SwiftUI tree is released, not kept alive by the host controller across reopens.
- **Diagnostic-log async write.** `sonosDebugLog` writes via a serial utility-QoS dispatch queue, keeping file I/O off the main thread. Synchronous writes were causing visible stutter in the Vis fade pipeline at high log volume.
- **Translation refresh.** Visualisation menu names, toolbar tooltip, settings section + help captions, About panel header, and the new short `karaoke` menu label all localised to 13 languages.

---

## v4.7 — 2026-05-05 — TuneIn topic playback, bonded-set volume reconciliation, media keys, queue/UX robustness

A combined release covering the v4.7-wip work (media keys, diagnostics overhaul, Radio Paradise + SiriusXM service classification, queue-add fixes, hybrid volume throttle) and a focused round of speaker-state correctness work prompted by issues #28 and #34. The headline is two architectural shifts: per-item playback strategies in `BrowseItem` so service-specific quirks live in one place each, and per-device `GetMute`/`GetVolume` verifiers triggered by every outbound write so the speaker is the source of truth instead of optimistic dictionary writes.

### Per-item playback strategy — service isolation in playBrowseItem

- New `BrowsePlaybackStrategy` enum on `BrowseItem` declared at construction time by the originating service path. Three closed cases: `.directURIWithDIDL` (default — TuneIn music stations, Sonos favorites, raw streams, line-in); `.smapiResolveThenEmpty` (SMAPI search items resolved via `getMediaURI`); `.tuneInResolveViaRadioTime` (TuneIn topics / programs / podcast episodes resolved via RadioTime's Tune.ashx).
- `SonosManager.playBrowseItem`'s direct-play branch is now a `switch` on `item.playbackStrategy`. Each case handles its own URI shape and metadata policy in a single place — adding or modifying one strategy can no longer regress another. Resolves a class of bugs where a SMAPI optimisation silently dropped TuneIn DIDL.

### TuneIn topic playback — Tune.ashx + queue-based

- Topics, programs, and podcast episodes (t/p/g-prefix guide IDs) returned UPnP fault 800 from `SetAVTransportURI` because the legacy `x-sonosapi-stream:` scheme rejects on-demand content. RadioTime's public `https://opml.radiotime.com/Tune.ashx?id=<guideId>&render=json&formats=mp3,aac,ogg,hls` is now consulted at play time; the resolved direct URL plays via the queue (`AddURIToQueue` with a track-class DIDL declaring `protocolInfo` `http-get:*:audio/mpeg:*` etc., then `SetAVTransportURI` to the queue, then play). The `x-rincon-mp3radio://` scheme was attempted first but rejected on HSTS-protected CDNs and on `:https://` form (UPnP 714 Illegal MIME). Queue-based play with a typed track DIDL is the only form Sonos accepts for HTTPS one-shot files.
- New `ServiceSearchProvider.resolveTuneIn(guideId:)` and `buildResolvedTuneInTrackDIDL(...)` helpers. `parseTuneInItem` and `searchTuneIn` tag t/p/g-prefix items with `.tuneInResolveViaRadioTime` at construction.
- TuneIn ad-pre-roll loop detection: `transportDidUpdateTrackMetadata` now logs a `[TUNEIN-AD]` warning on entry into Sonos's ad station (`tunein%3a31971` / `tunein-ondemand.cdnstream1.com`) and `INFO` on exit. The ad loop itself is a Sonos-side issue; the diagnostic surfaces it explicitly so users (and bug reports) don't mistake it for a Choragus bug.

### Pandora reclassified — blocked, favorites-only

- Pandora moved to `MusicServicesView.blockedServices` alongside Amazon Music, YouTube Music, SoundCloud, and SiriusXM. Renders red Unavailable, no Connect button. Rationale: post-SiriusXM acquisition, Pandora's Sonos integration moved behind the same identity gate as the rest — the legacy `-0-Token` placeholder Choragus was using stopped working around mid-2018, and modern Sonos auth requires per-household credentials only the official Sonos app can provision.
- Setup-guide copy in the help sheet (`L10n.blockedServicesBody`) updated to enumerate Amazon / YouTube Music / SoundCloud / SiriusXM / Pandora, note Pandora's SiriusXM ownership, and call out S1 unavailability. Per-row `.blocked` hint added (`L10n.blockedFavoritesPlayableHint`) so the row tells the user existing favorites still play through the Favorites view. Closes [#34](https://github.com/scottwaters/Choragus/issues/34).

### Bonded-set mute / volume reconciliation — issue #28

- Stereo pairs, surround sets, and sub-paired zones don't follow the coordinator's group-mute round-trip the way conventional members do — their hardware mute state stays independent. The previous optimistic propagation in `propagateMuteOptimistically` blindly wrote the coordinator's mute state to all members in the dict, leaving the dict desynced from speaker reality whenever a bonded set was in the group. The user-visible symptom was a slider stuck at 0, a mute button that couldn't unmute, and "every tap mutes more" — confirmed locally on a Sonos Five stereo pair.
- Architectural fix: every outbound `setMute` / `setVolume` SOAP now schedules a per-device `GetMute` / `GetVolume` verifier 500 ms later (`scheduleDeviceMuteVerify` / `scheduleDeviceVolumeVerify`). Cancel-and-reschedule semantics, so a drag or rapid-toggle coalesces to one verify per quiet window. Verifier consumes any pending expected-echo entry (so the next NOTIFY can't double-apply) and writes the speaker's authoritative state back to `deviceMutes` / `deviceVolumes`. The optimistic propagation is preserved for the instant-UI-flip path, but the verifier ensures bonded-set members are reconciled within 500 ms.
- `scheduleGroupMuteVerifier` mirrors the existing `scheduleGroupVolumeVerifier` for external coord mute changes. New diagnostic tags `[RC-VERIFY] mute|vol APPLY|NO-OP|FAIL` make the reconciliation visible in bug bundles. Closes [#28](https://github.com/scottwaters/Choragus/issues/28).

### Master volume — drag-snapshot offsets, no drift at extremes

- Replaced `lastAppliedMaster: Double` running-reference with `dragSnapshot: (master: Double, volumes: [String: Double])?` captured lazily on the first `applyMasterVolume` call after a commit. The snapshot is the immutable reference for the entire drag — every mid-drag tick computes targets against the snapshot, never the running per-member values. Without this, members that hit 0 or 100 had their offset to master permanently lost (the running clamped value was treated as the "real" value), and dragging back compressed the spread forever.
- Extreme-as-absolute special case: master at 0 silences all members, master at 100 drives all to max. The snapshot stays intact, so as soon as master leaves the extreme the original spread recovers via the linear/proportional distribution math.
- Snapshot cleared on `commitVolume`, `resetForGroupChange`, and at the end of `fetchCurrentState`.

### Type-in volume popover

- Double-click any volume number (master or per-speaker) to open a popover with a TextField pre-populated and pre-selected to the current value. Input filtered to digits only; values clamped to 0–100; Set/Cancel buttons with Return/Escape shortcuts. Implementation lives in `SliderPopup.swift` alongside the existing slider drag-popup.
- Master `applyMasterVolume(Double(newVal))` + `commitVolume()` for instant apply; per-speaker routes through the existing `setSpeakerVolume` callback.

### Browse cache — depth-keyed collisions fixed

- `itemsCache` was keyed by navigation depth (Int), so drilling into folder A → back → folder B (both at the same depth) returned A's cached items. SMAPI Browse on the resulting stale objectIDs returned UPnP fault 701 No Such Object — the symptom in TuneIn sub-folder navigation. Fix: every push site now invalidates `itemsCache` entries for depths > current depth before appending, so sibling paths start with a clean cache below the divergence point. Applied at all four push sites (TuneIn handleTap, Apple Music artist drill, Apple Music album drill, SMAPI search drill).

### Local Library — top-row buttons match right-click behaviour

- Top-row Play All / Add All / Play Next on local-library browse views previously skipped the client-side container expansion that right-click → Play Now / Add to Queue / Play Next does, and submitted album rows directly to `addBrowseItemsToQueue`. Result: queue panel showed the bare container row instead of leaf tracks. New `BrowseViewModel.bulkPlayAll` / `bulkAddToQueue` methods route the visible items through the same expansion path, then submit the flattened leaf set.
- Bulk queue cap at Sonos's 40 000 hard limit (`BrowseViewModel.sonosQueueLimit`). Per-container slicing fits remaining headroom; once capped, no further containers walk. User sees a clear "Stopped at Sonos's 40,000 track queue limit" message via `playbackError`.
- Large-add prompt sheet (right-click on a 1 000+ track container) now fully localised to all 13 languages (`largeAddBuildingTitle/Body`, `largeAddReadyTitle/Body`).

### Localisation sweep

- 11 new translatable keys with full 13-language coverage (3-source verified per language: Apple's localization glossary, Microsoft Language Portal, plus an authoritative dictionary or native primary source). Apple-correct quotes per locale: German „…", French «\u{00A0}…\u{00A0}» with NBSP, Spanish/Italian/Portuguese guillemets, Swedish/Danish "…", Japanese 「…」, Polish „…", Simplified Chinese "…".
- Backfilled translations for 8 previously English-only keys (`skipBack15` / `skipForward15` / `skipBack30` / `skipForward30`, `currentVersionLabel`, `openAboutWindowTooltip`, `versionBuildFormat`, `blockedFavoritesPlayableHint`).
- Hardcoded literals replaced in `BrowseView` (Cancel / Add All in the large-add sheet), `SliderPopup` (Cancel / Set), `NowPlayingView` + `VolumeControlView` (double-click tooltip), `PlayHistoryView` (alert titles), `PresetManagerView` (alert title + status toast), and `BrowseViewModel` (queue-limit messages).

### Media keys (carryover from v4.7-wip)

- `MPRemoteCommandCenter` for transport (play/pause/next/previous), `⌃⌥↑/↓/M` chord for group volume + mute, `MPNowPlayingInfoCenter` mirror with proper `playbackState` for OS routing. Works system-wide regardless of focus.

### Diagnostics overhaul (carryover from v4.7-wip)

- All diagnostic event routing now flows through `ErrorHandler.handle` → `sonosDiagLog`. SMAPI auth, repository SQLite, Last.fm, Plex Direct, and SOAPClient errors all surface through the unified path. URL scrubbing applied at bundle export. Encrypted bug-report form no longer pre-fills an empty title.

### Radio Paradise + SiriusXM (carryover from v4.7-wip)

- Radio Paradise (sid=633): per-service catalog overrides — `x-sonosapi-radio:` scheme, flags=8232, DIDL prefixes `100c2028` / `10fe2064`, auth-token-aware cdudn. Two-stage `resolveMediaURI`. Closes [#20](https://github.com/scottwaters/Choragus/issues/20).
- SiriusXM (sid=37): added to `unsupportedAppLink` + `blockedServices` (red Unavailable). Closes [#21](https://github.com/scottwaters/Choragus/issues/21), [#22](https://github.com/scottwaters/Choragus/issues/22), [#23](https://github.com/scottwaters/Choragus/issues/23), [#27](https://github.com/scottwaters/Choragus/issues/27).

### Queue and right-click flow (carryover from v4.7-wip)

- Right-click queue add: client-side container expansion (depth-first, alpha sort, 6-level cap, 40 000 leaf cap). `pagedBrowse` ignores speaker-reported `total` (composite containers under-report). M3U/PLS/CUE skipped. Mid-expansion sheet at 1 000 leaves with live count, Cancel always live, Add All disabled until walk completes. Speaker-cap detection (5 consecutive 402s → log once, stop). Bulk-add tolerates failures.
- Queue panel: `loadQueue` pages full queue (500/page, 40 k cap), one-shot 600 ms post-add retry, live-count status text. Closes [#8](https://github.com/scottwaters/Choragus/issues/8).
- Hybrid volume throttle: master + per-speaker run optimistic + 250 ms throttled mid-drag SOAP + authoritative drag-end commit.

### Tests + cleanup

- Code-quality pass before commit replaced hardcoded `"x-rincon-cpcontainer:"` with `URIPrefix.rinconContainer`, replaced duplicate `40_000` magic-number with `BrowseViewModel.sonosQueueLimit`, extracted duplicated token-snapshot block in `SMAPIAuthManager.init` to private `pushAuthTokenSnapshot()`.

## v4.6 — 2026-05-03 — SMAPI catalog + sandboxed auto-update + DMG distribution

Streaming-service URI routing is now per-household instead of compile-time, the in-app auto-update path actually works on the sandboxed build (entitlements gap closed end-to-end), Settings is a real macOS Preferences window, and distribution moves from a bare ZIP to a signed/notarized DMG with a drag-to-Applications layout.

### MusicServiceCatalog — runtime per-household URI routing

- New `MusicServiceCatalog` actor (in `SonosKit/Services/`) splits SMAPI service knowledge into two layers: a static rules table (Spotify wants `x-sonos-spotify:`, Apple Music wants `.mp4` + flags 8232, etc.) keyed by canonical name, and a per-household `sid → name` table populated from the speaker's `ListAvailableServices` response. Lookup at URI-build time goes `sid → name → rules`, so households whose Spotify is sid 9 (or anything other than the historically-hardcoded 12) now route to the correct URI scheme. Closes [#19](https://github.com/scottwaters/Choragus/issues/19) — single-track Spotify clicks were faulting with SOAP 714 because the prefix lookup missed by sid.
- Catalog driven refreshes on speaker bind, periodic 6-hour TTL, and miss-triggered (when `buildPlayURI` is called for a sid the catalog hasn't seen yet). Drift detection logs a CATALOG warning when the same service name reports a different sid between refreshes — rare but real on accounts where a service was removed and re-added in the Sonos app.
- `SMAPIAuthManager.loadServices` now delegates the descriptor fetch to the catalog and reads back through it, instead of owning a separate parser. `ServiceSearchProvider.buildPlayURI` and the iTunes-search Apple Music URIs both consult the catalog. TuneIn / Calm Radio search URIs do too.
- Tests: 17 new `MusicServiceCatalogTests` covering static rules, sid-resolution, refresh coalescing, drift detection, ensure-fresh TTL, and miss-triggered refresh.

### Add All on artist-album lists actually enqueues every album

- `addBrowseItemsToQueue` and `fillQueueInBackground` previously had a `!item.isContainer` guard that silently dropped every container — so on a Spotify artist's album list, "Add All" appeared to do nothing while "Play Next" on a single album worked fine. The single-track path used `addBrowseItemToQueue` (no filter), the bulk path filtered. Same shape for Plex playlists and any service that returns `x-rincon-cpcontainer:` URIs in browse results.
- Removed the filter; both paths now pass containers through to `AddURIToQueue` / `AddMultipleURIsToQueue`. Sonos expands them server-side. The existing per-item fallback covers the case where a batch faults on a mixed payload (no-op on local-library tracks; on cpcontainer mixes the per-item path takes over).
- Extracted a static `SonosManager.isQueueable(_:)` helper so the contract is regression-testable. New `BatchQueueFilterTests` (7 tests) cover Spotify/Apple Music/Plex containers, UPnP-only album items (no URI), empty URIs, and mixed lists.

### Plex direct: track duration in DIDL

- `PlexDirectBrowseView.buildDIDL` now emits `duration="H:MM:SS.fff"` on the `<res>` element using the Plex API's `durationMs`. Without it, Sonos's GetPositionInfo returned `0:00:00` for `TrackDuration` and the Now Playing UI showed "Live" instead of a seek bar — same UX as a radio stream. Track length now resolves correctly on freshly-added Plex direct tracks.
- `formatDIDLDuration(milliseconds:)` helper added alongside.

### Now Playing transport — semantically-correct icons + seek

- Previous/next buttons now use `backward.end.fill` / `forward.end.fill` (skip-to-track glyphs) instead of `backward.fill` / `forward.fill` (rewind/scrub glyphs). The actions were always next/previous track on Sonos; the icons just disagreed with the metaphor. Same swap in the menu-bar transport.
- New `±15 s` and `±30 s` seek buttons in their own row beneath the play/prev/next group. `gobackward.15` / `gobackward.30` / `goforward.15` / `goforward.30` SF Symbols, `.footnote` size so the main row stays visually dominant. Layout: pairs flank the centre, with the gap on each side aligned roughly under the prev / next icons. Wired to a new `NowPlayingViewModel.seekRelative(by:)` that clamps to `duration - 1` so a hold near the track end doesn't accidentally trigger queue advance. Disabled with the same gate as next/prev (radio streams that aren't queue-sourced).
- 4 new L10n keys (`skipBack15`, `skipForward15`, `skipBack30`, `skipForward30`).

### Encrypted bug bundle — `.log` extension + wider scrub before encryption

- Filename is now `Choragus-Bug-Bundle-<stamp>.choragus-bundle.log` (was `.choragus-bundle`). GitHub's attachment uploader rejects unknown extensions; users like the issue #19 reporter were renaming the file by hand to add `.log` before drag-drop. The trailing `.log` makes drag-drop work directly. The decrypter (`scripts/decrypt-bug-bundle.swift` and the `ChoragusBugBundleReader` helper app) doesn't care about the filename. Reader's open-panel allowlist updated to accept `.log`, `.choragus-bundle` (legacy), and `.json`.
- Encryption pipeline now runs the wider `scrubForPublicOutput` pass (account `sn=` bindings, LAN IPs, home paths, OAuth tokens, RINCON device-ID tail-mask) over each entry's `message` and `context` before assembly — defence in depth. Even though the body is encrypted to the maintainer's pubkey, minimisation principle: the maintainer doesn't need any of those values to diagnose, so don't ship them. Pre-fix bundles were leaking `sn=274` from the URI in context JSON.
- `BugReportBundle.scrubForPublicOutput(_:)` exposed as the single composable scrub helper. `DiagnosticsView.submitEncryptedReport` calls it; preview UI also routes through `bundleText` so what the user sees in the consent sheet matches what's actually shipped.
- Tests: 13 `DiagnosticsRedactorTests` (every redactor pattern: sn, home path, LAN IP across all RFC1918 ranges, link-local, RINCON device ID, Bearer token, query-string token), plus 6 `BugReportBundleScrubTests` including a full encrypted-bundle round-trip that asserts the decrypted body contains no leaked secrets.

### Sandboxed Sparkle auto-update — complete entitlements set

- v4.5 had only the static `org.sparkle-project.InstallerLauncher` and `DownloaderService` mach-lookup entitlements. Sparkle 2's installer flow on a sandboxed app ALSO needs the dynamic per-app status / connection / progress services it registers with launchd (`<bundle-id>-spki`, `<bundle-id>-spks`, `<bundle-id>-spkp`). Without those, the launcher would start, the Autoupdate helper would spawn, then the parent's "probe status service" would fail and the install would error out with a generic "An error occurred while launching the installer." dialog.
- `Choragus.entitlements` now grants both the static and dynamic mach-lookup names. Sparkle's full install + relaunch flow works end-to-end on the sandboxed build for the first time.
- `release.sh` now per-component-signs each Sparkle nested binary (Installer.xpc, Downloader.xpc, Updater.app, Autoupdate, then the framework, then the app shell) with our Developer ID + timestamp + hardened runtime, but without `--entitlements` on the inner components — `--deep` would clobber Sparkle's own entitlements posture and break the installer XPC. Single targeted re-sign of `Choragus.debug.dylib` and `__preview.dylib` adds the secure timestamp Apple's notary requires.

### Settings as a real Preferences window

- `SettingsView` is now wired through SwiftUI's `Settings { }` scene at the App level, presented as a separate non-modal window. Replaces the previous `.sheet(isPresented:)` presentation that was modal over the main window — that was blocking interaction with every other Choragus window AND preventing Sparkle's "Install and Relaunch" alert from surfacing because it tried to attach to the same already-modal window. The same complaint was filed in issue #23 ("The Settings popup is locally modal").
- ⌘, opens it (system-wired). `@Environment(\.openSettings)` in `ContentView` for the toolbar gear and the first-run welcome's "Open Settings" button.
- Settings → Software Updates surfaces the current version (clickable to open the About window) for quick reference.

### DMG distribution

- `release.sh` (production path) now produces a signed/notarized `Choragus.dmg` with the standard drag-to-Applications layout via `create-dmg`. Background art generated by `scripts/dmg/build-background.py` from the existing icon and wordmark assets — 640×480 canvas with the wordmark at the bottom and the app icon / Applications shortcut centred at the icon row. Falls back to ZIP if `create-dmg` isn't installed (with a warning).
- `release.sh --beta` continues to produce a ZIP — beta channel is arm64-only now (smaller, faster pre-release iteration; production stays universal).
- Beta releases get a build-suffixed git tag (`vX.Y.Z-betaN`) so they're separate GitHub release objects from any future stable `vX.Y.Z`. Beta release notes and stable release notes never overlap on the same release page.

### Queue UX

- Full-window busy overlay during long add-to-queue operations replaces the easy-to-miss inline header spinner. Shows on top of the existing queue list (translucent backdrop + centred ProgressView + label) so the user can still see what's there but the in-progress signal is unmistakable. Allows hit-testing of unrelated rows so reorder / delete on already-queued items still works while a batch lands.

### Build / signing pipeline

- Per-component Sparkle re-signing (see entitlements section above).
- `release.sh` channel-aware artifact + tag + appcast enclosure type.
- `MARKETING_VERSION` 4.5 → 4.6, `CURRENT_PROJECT_VERSION` 13 → 23 across iterations.

## v4.5 — 2026-05-02 — Karaoke + auto-update + encrypted bug reports + perf

A substantial release: the karaoke window now has its own resizable popout with smooth art crossfades and radio-art grace handling, Choragus now self-updates via Sparkle 2 with EdDSA-signed releases and an opt-in beta channel, the diagnostics surface gains an encrypted bug-report path that ships an opaque-to-GitHub bundle to the maintainer plus a live UPnP event monitor in a tabbed shell, and there's a substantial under-the-hood pass to drive idle CPU churn and SwiftUI invalidation rate down.

### Sparkle 2 auto-update integration

`SPUStandardUpdaterController` wired in `ChoragusApp.swift` via the new `SparkleUpdaterObserver`. Construction is gated on a non-empty `SUFeedURL` Info.plist value (placeholder-substituted at release time from `scripts/.release.env`); dev builds and forks leave the placeholder unsubstituted and Sparkle stays inert, with the existing GitHub-API `UpdateChecker` running as the fallback notification path.

`startUpdater()` is deferred to 0.5 s after the main `WindowGroup` mounts so Sparkle's first-run permission prompt opens against an already-rendered app window instead of holding initial rendering hostage. KVO observers for `automaticallyChecksForUpdates` and `automaticallyDownloadsUpdates` propagate Sparkle-side state changes (first-run prompt, sparkle CLI tooling, manual `defaults write`) back into the `@Published` mirror so the Settings UI reflects reality.

A new `SparkleUpdaterDelegate` implements `allowedChannels(for:)` reading `UDKey.sparkleBetaChannelEnabled` from UserDefaults — empty set for production-only (default), `["beta"]` when the user has opted in. The hook is read per-update-check, so flipping the toggle takes effect on the next "Check for Updates" without an app relaunch.

`scripts/release.sh` extended: signs each notarised zip with `sign_update`, prepends the new `<item>` entry to `appcast.xml` in a `gh-pages` worktree (with optional `--beta` flag injecting `<sparkle:channel>beta</sparkle:channel>` for staged releases), and pushes. First-run setup landed in the parent-dir `docs/auto-update-setup.md`. Existing v3.x / v4.0 users need one manual update to v4.5; from then on auto.

### Settings — dedicated Software Updates tab

Software Updates moved out of the System tab into its own top-level Settings tab (5th slot, "arrow.down.circle" icon) — only appears when Sparkle is active in the build. Three controls in the main section: auto-check toggle, auto-download toggle (disabled until auto-check is on), manual Check Now with last-checked timestamp.

Below that, a new Beta Channel section with an opt-in toggle and an orange-warning-triangle helper paragraph spelling out that beta builds may be unstable, may lose data, and may break features that work in stable; not recommended for the user's only Mac. Toggle binding writes the `sparkle.betaChannelEnabled` UserDefaults key; the SparkleUpdaterDelegate reads it on each update check.

### Encrypted bug-report bundles

Diagnostics window restructured as a tabbed shell (Log + Live Events). The Log tab's footer gains a "Report Bug (encrypted)" button (visible only when `BugReportEncryptor.isConfigured` — i.e. release builds with `BUG_REPORT_PUBLIC_KEY` substituted into Info.plist).

Click the button → a modal preview sheet opens showing the formatted bundle text exactly as it will be encrypted, with a redaction-counter summary at the bottom (`Substituted: N tokens, M LAN IPs, K paths`). Confirm → Choragus assembles the bundle, encrypts the body, writes a `Choragus-Bug-Bundle-<timestamp>.choragus-bundle` file to the user's Downloads folder, reveals it in Finder, and opens GitHub Issues with the title and body pre-filled (body names the exact filename + tells the user to drag the Finder reveal into the comment).

Two-tier redactor split: `DiagnosticsRedactor.scrubForPersistence` runs at the SQLite write boundary and strips only auth tokens — LAN IPs, file paths, RINCON IDs, and SMAPI account bindings stay so the user's local diagnostic store remains useful for self-debugging. `DiagnosticsRedactor.scrubForPublicOutput` runs at the export boundary (Copy All / Save Bundle / the legacy plaintext "Report on GitHub" / "Report Privately" buttons in dev/fork builds) and runs every redactor.

`BugReportEncryptor` (new in SonosKit) wraps the diagnostic body via X25519 key agreement + HKDF-SHA256 + ChaChaPoly AEAD (standard ECIES envelope: ephemeral X25519 keypair → shared secret → derived symmetric key → AEAD encrypt → concat ephemeral_pubkey ‖ nonce ‖ ciphertext ‖ tag). `BugReportBundle` (also new) wraps the ciphertext in a JSON envelope with a plaintext header (Choragus version, macOS, build tag, locale, event count, generation timestamp) so the maintainer can sort received bundles without decrypting first.

The bundle is opaque to GitHub itself, to any caching proxy, and to anyone who downloads the attached file from GitHub's CDN — only the maintainer's matching private key can unwrap it. Auth tokens are stripped at the source so the maintainer never holds working credentials even after decryption.

A maintainer-side decrypt CLI lives at `scripts/decrypt-bug-bundle.swift` (parent dir, outside the Choragus repo): pure CryptoKit + Foundation, prompts for the private key on stdin if not provided as argv, prints the decrypted entry list. A standalone `ChoragusBugBundleReader.app` (separate package, parent dir, drag-and-drop UI) provides a friendlier path.

A new context-menu item `Copy Row (with payload)` next to the existing scrubbed `Copy Row` exposes the on-disk-tier representation directly to clipboard for local debugging — auth tokens still stripped (those were never on disk), but LAN IPs / paths / device IDs preserved.

The required `com.apple.security.files.downloads.read-write` entitlement was added so the encrypted-bundle write to `~/Downloads` succeeds in the sandboxed app.

### Live Events tab — real-time UPnP event monitor

`HybridEventFirstTransport.handleEvent` now broadcasts every parsed UPnP event via `NotificationCenter` (`SonosUPnPEventNotification`) before dispatching to the existing per-kind handlers. The broadcast carries `serviceType` ("avTransport" / "renderingControl" / "topology"), `deviceID` (RINCON UUID), and the raw NOTIFY body. Single line of new work in the hot path; no measurable cost when nothing's subscribed.

A new app-side `LiveEventLog` (`@MainActor ObservableObject`, owned by `WindowManager.openDiagnostics` so it lives for the whole window's lifetime regardless of which tab is active) subscribes to that notification, resolves `deviceID` → room/group via the live `SonosManager`, parses the body via the existing `LastChangeParser` for one-line summaries, and stores newest-first in a 5,000-event ring buffer with pause-with-buffering semantics.

`LiveEventsView` renders the stream: per-kind toggle filters (RC / AVT / TOPO), per-speaker dropdown filter, expandable rows that reveal the raw NOTIFY XML inline, pause / resume / clear controls. Useful when investigating why a control feels unresponsive — if the event arrives at the speaker but Choragus reacts late, the Live Events tab will show that.

### Karaoke window — crossfade transitions, wordmark/icon resize, radio art grace

Album art crossfade: header `CachedAsyncImage` and the blurred backdrop both wrapped with `.id(url) + .transition(.opacity)` and a parent `.animation(.easeInOut(duration: 0.4), value: resolvedURL)`. Track changes now fade between covers instead of snapping. Same treatment applied to `NowPlayingView.albumArtView` for consistency.

Header wordmark and icon resized: wordmark dropped from `headerArtSize * 0.75` to `headerArtSize * 0.5625` (108pt → 81pt); icon dropped from full `headerArtSize` to `headerArtSize * 0.75` (144pt → 108pt). Both restore the album art's visual prominence after earlier work had over-scaled the brand block.

Radio-track-art grace window: `ArtResolver` now holds the previous song's art for up to 8 s on a radio track changeover so the karaoke display doesn't snap to the station logo during the iTunes-search-in-flight gap. `handleTrackURIChanged` entry gate extended to also accept "title changed on stable radio URI" — radio HLS streams keep the same trackURI for the entire session, so the previous URI-only gate missed every intra-stream song change. Released early on actual track-art resolution; immediate fallback for station-ID titles (empty, or title equals stationName).

Cross-source title-key cache contamination guard: `ArtCacheService.lookupCachedArt` now rejects a title-keyed cache hit when the cached `/getaa?u=<src>` proxy URL embeds a source URI from a different family (local-file vs Apple Music vs Spotify vs radio) than the requesting track's URI. Title is too coarse a key to share across sources — a previous local-library play of "Bohemian Rhapsody" was poisoning the karaoke window for the same nominal title played via Apple Music. URI-key hits are unaffected (URI is unique-per-source already). Defensive design: never breaks a lookup it can't verify.

### Help system — Live Events, encrypted reporting, Software Updates, Beta Channel

Diagnostics topic in the Help window gains two new sections: Live Events tab (what it shows, when to use it) and encrypted bug reports (the preview-sheet flow, how the bundle is opaque to GitHub, EdDSA + ChaChaPoly framing). Preferences topic gains Software Updates Heading and Beta Channel Heading covering the new Settings tab. Help banner inside the Diagnostics window itself rewritten to describe the encrypted-bundle flow, the Live Events tab, and the Copy Row variants.

Eight new help string keys + one bullet under Preferences, all translated to the project's 13 languages.

### Code and functional optimisation

Substantial under-the-hood work to reduce idle CPU churn, eliminate background log floods that were both slowing things down and saturating the diagnostic store, and tighten the SwiftUI invalidation surface so playback and lyric scrolling feel noticeably smoother across the board.

- Several high-frequency debug-log emitters removed (per-frame `[UI-RENDER]` traces, unconditional `[QUEUE] updateCurrentTrack` per metadata refresh, three verbose `[POSITION]` logs, two per-keepalive `[MDNS]` logs); `[DISCOVERY]` log gated inside the device-change-detection guard.
- Equality gates added on `@Published` writes across `SonosManager` and `ArtCacheService` so identical-value writes don't fire the publisher chain during steady-state playback or topology refresh storms. Sites covered: `groupTrackMetadata` (both same-track-poll write paths in `transportDidUpdateTrackMetadata`), `groupTransportStates` / `groupPlayModes` (in both event handlers and `scanGroup`), `groupPositions` / `groupDurations`, `groupPositionAnchors` (already drift-thresholded; tagged), `deviceVolumes` / `deviceMutes` (in both event handlers and the `updateDeviceVolume` / `updateDeviceMute` public setters that `scanGroup` calls per-member), `awaitingPlayback`, the three topology-refresh flags (`isUsingCachedData` / `isRefreshing` / `staleMessage`), `htSatChannelMaps` (string-serialised tuple comparison since the dict's tuple values aren't Equatable), and the `cacheArtURL` four-key write paths.
- Source-tagged publisher counters in SonosManager: per-second `[MGR-PUB]` reporter now logs `total=N tag1=A tag2=B untagged=C` so future optimisation work can attribute publish bursts to specific subsystems instead of generic guess-work. Production builds emit at most `total=1-2 untagged=0` per active second in steady-state karaoke playback, down from 14-16/sec pre-optimisation.
- `BrowseItemArtLoader` process-lifetime negative-art `Set<String>` short-circuits the SOAP cascade on items that have already failed every resolution strategy; per-error `[BROWSE]` log lines removed (the negative cache supersedes them).
- `NowPlayingContextPanel` history-tab filter cached via `.task(id: HistoryCacheKey(trackKey:entriesCount:))` so the playHistoryManager.entries scan no longer reruns on every parent invalidation.
- `dev-build.sh` switched to `ONLY_ACTIVE_ARCH=YES` for daily iteration (~halves build time on Apple Silicon); `release.sh` stays universal.

### Karaoke popout window

The Lyrics tab now has a popout button (top-right). Clicking it opens a separate, resizable `LyricsKaraokeWindow` with much larger karaoke-style text — 5 visible rows × 120pt rows, 72pt active / 44pt edge font, readable from across a room. The window is locked to the group it was opened for at open time and won't follow the main UI's selected-group changes (so a karaoke session doesn't get yanked away when the user clicks into a different room). Long lyric lines shrink-to-fit via `.minimumScaleFactor(0.3)` instead of truncating with an ellipsis.

The window header carries a 96pt album-art thumbnail plus the track title, artist, and album. A heavily-blurred full-bleed copy of the album art sits as an atmospheric backdrop at 30% opacity (no `.ignoresSafeArea()` — the backdrop stays bounded to the host contentView so it can't bleed into the macOS title-bar translucency layer).

Window-size floor is enforced at the AppKit level via `NSWindow.contentMinSize`, not via SwiftUI `.frame(minHeight:)`. The latter centres any overflow during resize and was clipping both the header *and* the footer at the same time on shrink. Lifecycle is hardened: every karaoke window carries a stable `NSUserInterfaceItemIdentifier`, an orphan sweep across `NSApp.windows` runs on every open (closes leaked windows from a previous bad state), and a `willCloseNotification` observer keeps the manager's ivar in sync with reality so the next reopen doesn't try to revive a half-torn-down host.

### Shared playhead anchor (refactor)

Underlying the karaoke window's lockstep with the inline panel: `PositionAnchor` was promoted from `Choragus/ViewModels/NowPlayingViewModel.swift` to `SonosKit/Models/PositionAnchor.swift`, and `SonosManager` gained a new `@Published public var groupPositionAnchors: [String: PositionAnchor]` plus the drift-tolerant rebase logic (forward 2 s, backward 30 s asymmetric thresholds) that previously lived in the view model. New public methods: `setPositionAnchor`, `setPositionDragInProgress`, `transportDidUpdatePosition`.

Both the inline panel and the karaoke window are now pure consumers of the shared anchor — neither maintains its own. Drift between the two views is eliminated structurally rather than by per-view re-syncing. The previous bug where the karaoke window's lyrics drifted hundreds of milliseconds out of sync with the panel was caused by each view independently rebuilding anchors with their own `wallClock` stamps; with one shared anchor that class of bug can't recur.

### Background metadata prewarmer

New `MetadataPrewarmService` in SonosKit. Subscribes to `SonosManager.$groupTrackMetadata` once at app start. For every track that begins playing in any group it fires fire-and-forget Tasks against `LyricsService` + `MusicMetadataService` to hydrate caches, regardless of UI state — context panel collapsed, panel open with a different tab, group not currently selected. Cross-group dedup uses the new shared `TrackMetadata.stableKey` (URI for streaming/library tracks, URI+title+artist for radio).

End-result: opening the Lyrics or About tab is now an instant cache hit unless the network was down at the moment of the track change.

### Diagnostics window

A new bug icon in the toolbar (top-right of the main window) opens the new Diagnostics window. Behind the icon is a SQLite-backed ring buffer at `~/Library/Application Support/Choragus/diagnostics.sqlite` — schema is `(id, ts, level, tag, message, context_json)`, with a 30-day TTL and a 5,000-entry hard cap so a runaway error storm can't fill disk.

Capture happens automatically through hooks in two layers:
- **`SOAPClient.send`** — every SOAP fault (HTTP 500) and every non-2xx response is logged with action, service, URL, fault code, fault string. Catches every UPnP error from any path.
- **`SonosManager.playBrowseItem` direct-play branch** — captures URI + DIDL metadata + service name when single-track plays fail. Specifically targets the diagnostic surface for issue #19's "SOAP fault when clicking single Spotify track" — the next reproducer will have the exact URI Sonos rejected.

PII redaction is applied at log time before persistence by a new `DiagnosticsRedactor`:
- Home directory paths → `~`
- LAN IPv4 (10/8, 172.16/12, 192.168/16, 169.254/16) → `<lan-ip>`
- Sonos device IDs (`RINCON_<hex>`) → keep last 4 chars, mask the rest
- SMAPI sub-account binding `sn=<digits>` → `sn=*`
- OAuth tokens / API keys / `Bearer <hex>` → `<redacted>`

Track titles, artist names, and album names are kept — this is a music app and they're useful for reproducing playback issues.

The Diagnostics window has filter pills (All / Errors only / Warnings + errors), a sortable table, per-row right-click `Copy Row`, and footer actions for `Copy All`, `Save Bundle…`, and `Report on GitHub`. The Report button URL-encodes the bundle into a GitHub `?body=` deep-link; if the bundle exceeds GitHub's URL ceiling (~7 KB) it falls back to clipboard + plain new-issue page so the user pastes manually. Help text in the window banner spells out the two paths (GitHub submission vs manual paste) and notes that GitHub doesn't accept anonymous issues. All three copy paths produce the same self-contained bundle (Choragus version, macOS version, bundle ID, then events) so the maintainer always has version context regardless of which path the reporter used.

A new `Settings → Display → Hide diagnostics icon in toolbar` toggle lets users hide the icon. Diagnostics still capture in the background; only the toolbar entry point is removed.

### Window state remembered across launches

The main window's panel toggles (`showBrowse` / `showQueue`) and the user-set Browse panel width all migrated from `@State` to `@AppStorage` so they persist across launches. A new `WindowFrameAutosaver` `NSViewRepresentable` sets `NSWindow.setFrameAutosaveName("ChoragusMainWindow")` on the main window so AppKit auto-persists the window's frame (position + width + height) to UserDefaults. Subsequent launches restore the previous frame; first launch falls back to `.defaultSize(width: 900, height: 550)` as before.

### Settings checkboxes — instant response

All `Toggle` bindings that previously used the manual `Binding(get: { UserDefaults.standard.bool(...) }, set: { UserDefaults.standard.set(...) })` pattern have been migrated to `@AppStorage`. SwiftUI doesn't observe UserDefaults via the manual pattern — the binding's `get` only re-runs when the parent view re-renders for some other reason, so clicking the toggle wrote the value but the UI didn't re-render to reflect it for half a second or longer. Affected toggles: scroll-volume, middle-click-mute, classic-shuffle, proportional-group-volume, ignore-TV/HDMI Line-In, realtime-stats. The realtime-stats interval `Picker` got the same treatment.

The Music tab section order now reads Play History → Music Services → Playback (was Playback → Play History → Music Services).

### Music Services — duplicate-row fix + per-household sid promotion

`MusicServicesView.buildServiceList` now dedupes by both `coveredIDs` *and* `coveredNames` (lowercased), tracked across all four build stages (pinned → Plex Cloud → authenticated → serial-discovered → catalog). Pinned services with hardcoded SoCo-wiki sids no longer produce duplicate rows when the household catalog lists the same service under a different sid (the Pandora-as-two-rows bug).

But dedup alone wasn't enough — keeping the pinned sid would mean SMAPI calls fail because Sonos doesn't recognise that sid for the household. So pinned-sid promotion was added: when a pinned service's name matches a household-catalog entry, the pinned entry's `serviceID` is replaced with the catalog's sid (the one Sonos understands for that household). The original sid is appended to `alternativeIDs` so dedup still catches any other path that might still reference the SoCo-wiki sid. Promotion is logged via `sonosDiagLog` so per-household sid mappings become observable in the diagnostics bundle — useful data if patterns emerge across reports.

### Last.fm bio depth + iTunes artist-image fallback

`parseLastFMArtist` and `parseLastFMAlbum` now read `bio.content` / `wiki.content` (full text) instead of `bio.summary` / `wiki.summary` (Last.fm-truncated 1–2 paragraph snippet). Both fields end with the same "Read more on Last.fm" trailer that `stripLastFMTrailer` cleans. For artists with rich Last.fm coverage (Weird Al, Eminem, etc.) the about card now shows the full biography instead of an obviously-cut-off summary.

Artist images: when neither Last.fm (placeholder-filtered post-2019) nor Wikipedia provides one, fall back to iTunes Search via the new public `AlbumArtSearchService.searchArtistArt(artist:)` method (uses `entity=musicArtist`). Returns ~100×100 typical, small but better than blank. The `MetadataCacheRepository` artist + album cache keys gain a `v2` schema-version suffix so existing v4.0 cached entries from before these fixes silently miss and re-fetch with the improved logic.

### Lyrics performance — virtualisation + cleaner overflow

`SlidingLyricsView` was extracted from `NowPlayingContextPanel.swift` into its own file and parameterised on `visibleRows` / `rowHeight` / `peakSize` / `baseSize` so the inline panel and karaoke window can size it without forking the implementation.

The renderer slices `lines` to a fixed window of `visibleRows + 2 × bufferRows` instead of iterating the full LRC. Per-frame cost drops from O(N) to O(constant). Long, repeat-dense LRCs — Eminem's *Not Afraid* fans out into ~200 entries via multi-tag chorus repeats — used to push N into the hundreds and the main thread couldn't keep up; the karaoke effect would judder. The slice keeps per-frame work bounded regardless of track length.

The frame uses `maxHeight` only (no `minHeight`) so the view shrinks below `windowHeight` when the parent is smaller, instead of overflowing into adjacent VStack siblings. Long lyric lines shrink-to-fit at `.minimumScaleFactor(0.3)`.

### Settings → System → Network — about copy rewritten

Replaced the four-line "Event-Driven / Legacy Polling / Quick Start / Classic" stub with comprehensive coverage of all current options: Updates (Event-Driven vs Legacy Polling), Startup (Quick Start vs Classic), Discovery (Auto / Bonjour Only / Legacy Multicast — previously undocumented), and the iTunes Throttle status row. Markdown rendering enabled via `LocalizedStringKey(text)` so `**bold**` actually formats and a clickable `github.com/scottwaters/Choragus` link appears at the bottom for users who want deeper troubleshooting detail. Translated to all 13 locales.

### Translations

Substantial translation pass:
- 24 new diagnostic / karaoke / window-state UI keys translated into all 13 supported locales (`en`, `de`, `fr`, `nl`, `es`, `it`, `sv`, `nb`, `da`, `ja`, `pt`, `pl`, `zh-Hans`).
- `aboutNetworkBody` updated for all 13 locales with the new comprehensive content.
- New help-section copy (Karaoke popout + Diagnostics topic) translated to all 13 locales.
- Settings → Language gains a new `translationHelpNote` underneath the language picker — also translated to all 13 — inviting users to file GitHub issues for incorrect or unnatural translations.

Multi-source verification: terminology was cross-referenced against Apple Console.app column names, Apple System Settings → Toolbar / Symbolleiste, Apple Save dialog convention (Sichern / Enregistrer / 保存), and Apple Finder Tags (kept "Tag" untranslated where Apple does). Confidence high on European locales; medium on `ja` and `zh-Hans` — native review still recommended for those before shipping non-English-default builds.

### Removed

- Five `ErrorHandler.shared.info(...)` queue-add toast call sites in `SonosManager.swift` ("Adding 0 / N tracks…", "Adding X / N tracks…", "Add to Queue: N tracks", "Add to Queue: <title>"). The QueueView's existing inline spinner was always the appropriate in-progress signal; the green banner was redundant noise that interfered with the surrounding UI.

### Browse pagination — SMAPI services + dedup guard

`BrowseViewModel.loadMore` now correctly paginates SMAPI-backed services (Spotify, Plex Cloud, Audible, etc.). The previous implementation routed *every* "Load More" request through the speaker's UPnP `browse(...)` SOAP, which has no understanding of SMAPI item IDs and silently returned empty results — meaning the user could only ever see the first ~100 items in any streaming service browse, with "Load More" doing nothing.

The new dispatch:

- **SMAPI sources** (Spotify, Plex Cloud, Audible, …) → `SMAPIClient.getMetadata` (or `getMetadataAnonymous`) with `index = loadedCount`. Result items go through `ServiceSearchProvider.smapiItemToBrowseItem` to land as normal `BrowseItem` rows.
- **Local-library / radio search** (`isSearch`, `isServiceSearch`) → bails early; the initial load returns the full result set, no pagination concept.
- **Default UPnP browse** → speaker `browse(start: loadedCount)` as before.

Plus a new `isLoadingMore` guard prevents the infinite-scroll bottom-sentinel from firing multiple concurrent `loadMore` calls when the user flicks past the threshold quickly. Without it, N concurrent requests produced duplicate rows when they all returned. `defer { isLoadingMore = false }` ensures the guard releases on every code path.

`totalItems` is also now updated from each page's reported total (it can grow during browse — e.g. a service that initially reported 100 items finds 200 in deeper pagination), so the bottom-sentinel keeps firing until the actual end.

### iTunes Search — UI/backfill priority split

`AlbumArtSearchService` now splits its public API by intent:

- **`searchArtwork(artist:album:)`** (no `maxWait`) is the **UI path** — runs `unthrottled: true`, bypassing the local 12 req/min self-throttle. Used by Now Playing art lookup, browse-row art rendering, manual refresh, and the new artist-image fallback.
- **`searchArtwork(artist:album:maxWait:)`** is the **backfill path** — stays throttled. Used by `playHistoryManager.backfillMissingArtwork()` with `maxWait: 120`, so it patiently waits for slots and yields to UI.

`searchArtistArt` and `searchRadioTrackArt` are also unthrottled. Apple-side 403/429 cooldown still applies to all paths.

Without this split, the post-launch backfill pass (which fires ~60 iTunes calls in the first few seconds) saturated the local 12/min cap and starved any user-initiated lookup happening in the same window — opening an album in Browse, refreshing an artist photo, etc. would silently get throttle-denied. After the split, UI lookups complete regardless of background backfill load.

The `searchArtistArt` cascade (musicArtist → album → song) accounts for an iTunes Search API quirk: `musicArtist` entity records often lack an `artworkUrl100` field, so a representative album cover is used as the artist's About-card photo when no real artist portrait is available.

### Diagnostic logging in iTunes paths

Every `iTunesSearchFull` call now logs to the diagnostics window when it returns nil, distinguishing four failure modes:

- Rate limiter denied or HTTP failure (`WARN ART`, includes the entity)
- JSON parse failure (`WARN ART`)
- Zero results from Apple (`INFO ART`, includes the query)
- Result has no `artworkUrl` field (`INFO ART`, includes the matched `artistName` and result count)

Plus the `ART/ARTIST` summary line includes a snapshot of the rate limiter state (`available`, `cooldownUntil`, `cooldownStatus`, `requestsInWindow`) when all three cascade entities fail. Together these make diagnosis of "why is artwork missing for X?" a single bundle paste rather than a back-and-forth.

`country=US` is now passed explicitly on every iTunes Search URL so the US storefront is queried regardless of caller IP geolocation. Removes one layer of ambiguity for non-US users hitting US-only artists.

### Radio-track-art dedup at two layers

Two separate sources of "previous song's art shows up after a radio station rolls to the next track" got fixes:

- **Menubar art** (`ArtCacheService`) — refuses to use radio URIs as cache keys. A station URI identifies the *station*, not the song; reusing it across the dozens of different tracks the station plays cross-contaminated every lookup. Title-based keys are now the only path for radio.
- **Now Playing art** (`ArtResolver`) — added `radioTrackArtKey` field tracking the title|artist key the current `radioTrackArtURL` was resolved for. `artURLForDisplay` now compares the stored key against the current track via `radioTrackArtKeyMatches` (title-only comparison; radio metadata arrives in stages so artist drift inside the same title is treated as the same song). Stale URLs from a previous song no longer display after a transition until the next iTunes lookup completes.

`ArtResolver` itself is now `@Observable` so SwiftUI re-renders when async art-search results land in `radioTrackArtURL` / `webArtURL` / `displayedArtURL`. The previous indirection through `NowPlayingViewModel` alone meant SwiftUI never got notified when ArtResolver state mutated after a metadata-driven search finished — visible as art correct on first launch but stuck across subsequent in-session track changes.

### Bug fixes

- Local library files with spaces in their path (e.g. `x-file-cifs://server/Pink Floyd/Wish You Were Here.mp3`) now reliably add to the queue. The `EnqueuedURIs` argument of `AddMultipleURIsToQueue` is a *space-separated* list of URIs — without URL-encoding, the speaker split at the wrong places and silently rejected every URI past the first one. The single-URI `AddURIToQueue` path didn't see this because there's no separator there. Idempotent: existing `%20` sequences are untouched.
- Synced lyrics no longer re-parse the LRC string on every position-projection tick. `NowPlayingContextPanelViewModel` now memoises one parsed result per source string. Under `@Observable`, the previous design ran the regex + split + sort + allocate cycle 60+ times per second whenever the position projection ticked.
- `MetadataCacheRepository` artist + album cache keys gain a `v2` schema-version suffix, so existing v4.0 cached `ArtistInfo` / `AlbumInfo` entries from before the bio + image fixes silently miss and re-fetch with the improved logic instead of stranding users on stale "no image" cached results for famous artists.

### Internal cleanup

- Multi-paragraph file docstrings and past-fix narrations trimmed across the lyrics-related files (per the project's "no comment unless WHY is non-obvious" convention). Net reduction across `SlidingLyricsView`, `LyricsKaraokeWindow`, `MetadataPrewarmService`, `NowPlayingContextPanel`: ~120 lines of comments.
- `trackKey` logic deduplicated into a single `TrackMetadata.stableKey` extension. Was previously hand-rolled in three places (panel, karaoke window, prewarmer).
- `NowPlayingViewModel` no longer maintains `forwardRebaseThreshold` / `backwardRebaseThreshold` constants or the `updateAnchorFromAuthoritative` / `updateAnchorPlayingState` methods — those are gone with the `PositionAnchor` move to SonosManager.
- `Info.plist` adds a `ChoragusBuildTag` custom key (populated via Xcode's `$(CHORAGUS_BUILD_TAG)` substitution from `dev-build.sh`). Surfaces as the Debug-only window-title suffix so accumulated dev builds in macOS's Local Network permissions list are individually identifiable. Custom key chosen specifically so it does *not* change `CFBundleVersion` — TCC treats `CFBundleVersion` changes as a new app version and re-prompts for Local Network access on every dev rebuild.

## v4.0 — 2026-04-27 — Choragus

> **Heads-up — major rework, breaking for existing installs.** v4.0 renames the project from SonosController to Choragus. The bundle ID changes (`com.sonoscontroller.app` → `com.choragus.app`), the executable name changes, and the Keychain service name changes with them. **Existing SonosController installs do not auto-upgrade** — Choragus arrives as a fresh app. **Re-authenticate Spotify, Plex, Audible, Last.fm, and any other connected services on first launch** (one-time). Play history, presets, accent colours, listening-stats data, and other preferences carry forward automatically. The old SonosController build keeps working alongside Choragus until you're ready to switch — they use different sandbox containers.

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

Issue and approach reported by [@mbieh](https://github.com/mbieh) ([#11](https://github.com/scottwaters/SonosController/issues/11)) including the verification dump and the parallel-merge design recommendation. Initial implementation contributed by [@steventamm](https://github.com/steventamm) in [#12](https://github.com/scottwaters/SonosController/issues/12) — the `NWBrowser` transport, the `SpeakerDiscovery` protocol abstraction, and the 13-locale translation work all started from that contribution.

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
- **Leading "+ " display glitch in group names** — `SonosGroup.name` no longer
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
