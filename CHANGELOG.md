# Changelog

## v3.0 — 2026-03-28

### New Features
- SMAPI music service browsing — connect TuneIn, Spotify, Deezer, TIDAL, and 40+ services
- Music Services setup guide with status indicators (Active / Needs Favorite / Connect)
- Dashboard: top tracks, top stations, top albums, day-of-week, room usage, listening streaks
- Quick stats pills (streak, avg/day, albums, stations)
- Card-based history timeline grouped by day
- Custom date range filter with From/To date pickers
- Menu bar redesign: hero art, room status dots, mute button, volume readout
- Proportional group volume scaling (optional, toggle in Settings)
- FlowLayout wrapping filter tags
- Shuffle disabled popover explanation

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
