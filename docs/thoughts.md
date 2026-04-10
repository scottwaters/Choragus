# SonosController — Ideas & Improvements

## High Priority — User-Facing Features

### Accessibility
- Zero VoiceOver labels exist in the entire app — every interactive element needs `.accessibilityLabel`
- Transport buttons, volume sliders, star toggle, room list, browse items all inaccessible to screen readers
- Status indicators (green/gray dots) need spoken descriptions
- Menu bar player completely inaccessible
- **Impact:** Blind/low-vision users cannot use the app at all

### Keyboard Shortcuts
- No global play/pause (space bar only works when Now Playing has focus)
- No arrow keys for volume or seeking
- No CMD+F for global search
- No CMD+1/2/3 for panel switching
- Need a keyboard shortcut reference (help menu or settings)

### Favorites Management
- Currently read-only — cannot create, edit, delete, or reorder favorites
- Cannot organize into folders or collections
- No bulk actions
- Sonos UPnP doesn't support CreateObject, so this may need workarounds (e.g. queue-based save)

### Party Mode / Play Everywhere
- No "group all speakers" one-click button
- GroupEditorView only supports manual group creation
- Quick preset for "play everywhere at volume X" would be useful

### Desktop Notifications
- No notification when queue ends
- No notification when speaker disconnects from group
- Could notify on track change (optional, for background monitoring)

### Now Playing Sharing
- Cannot share current track to social media, clipboard link, or other apps
- Could generate a formatted share card with artwork + metadata
- Integration with share sheet (macOS share extensions)

---

## Medium Priority — Feature Enhancements

### Listening History Insights
- **Recommendations** — "If you like Artist X, try Artist Y" from listening patterns
- **Time comparisons** — vs. last week / last month / last year
- **Mood playlists** — based on time-of-day listening patterns
- **"Rediscover" playlist** — auto-generate from tracks you used to play heavily but haven't recently
- **Artist timelines** — show when you first heard an artist, peak listening periods
- **Milestone celebrations** — "You've listened for 100 hours!" notifications
- **Weekly/monthly digest** — summary of listening stats

### Service Integrations
- **Last.fm scrobbling** — sync play history for recommendations and social features
- **Genius lyrics** — show lyrics for current track in Now Playing
- **MusicBrainz** — enriched artist/album metadata
- **HomeKit** — trigger Sonos via HomeKit scenes and automations
- **Calendar silence** — auto-pause during calendar meetings
- **MQTT/webhooks** — publish now-playing events to home automation systems (Home Assistant, Node-RED)
- **Slack/Discord** — post "now playing" status

### Sonos Radio
- Browse categories requires DeviceLink auth — investigate if this can be reverse-engineered from the official Sonos app's session
- The official app browses categories fine — it uses the Sonos account session, not standard SMAPI auth

### Advanced Search
- Fuzzy search across services
- Search filters by date range, service, album year
- Search history / recent searches
- Search suggestions / autocomplete

### Queue Improvements
- Undo for queue remove/clear operations
- Queue history (recently played queue configurations)
- "Up Next" mini-queue from selection
- Intelligent radio-to-queue transition (append vs. replace prompt)

---

## Low Priority — Polish & Technical

### Performance
- Metadata polling (5s) could be adaptive — faster during active playback, slower when idle
- Reconciliation polling (15s) across N groups × N speakers = N squared potential calls
- `discoveredArtURLs` cache grows unbounded with no eviction
- `updateArtwork()` iterates entire history backwards on every art search completion — O(n) per call
- Progress timer continues during window deactivation (should pause when app backgrounded)

### Architecture Improvements
- Grace period system has 6 separate dictionaries — consolidate to single map with action type enum
- Browse destination uses string pattern matching ("SMAPISEARCHPROMPT:") — should be an enum
- Transport strategy has 3 overlapping polling loops (strategy reconciliation + NowPlayingViewModel metadata poll + progress timer)
- Image cache lacks TTL semantics — no distinction between persistent (iTunes) vs. ephemeral (/getaa) entries
- SMAPI token storage assumes single user — doesn't support multi-account households

### Error Handling
- Many errors silently swallowed with `try?` or `catch {}` — should show user-facing feedback
- No exponential backoff on polling failures — could hammer speakers on repeated errors
- Network errors don't distinguish timeouts from refused connections
- Disk full not handled in image cache writes
- No cache corruption recovery

### Missing Platform Features
- **Trueplay / room correction** — not available via UPnP
- **Stereo pair creation** — requires Sonos cloud API
- **AirPlay 2** — no source/target support
- **Voice assistant settings** — Sonos Voice Control / Alexa configuration not exposed via UPnP
- **Gapless playback settings** — not found in UPnP service
- **Line-in / TV audio routing** — input selection not implemented
- **Music alarm sources** — UPnP AlarmClock returns 0 alarms on S2 (cloud API required)

### Testing
- No UI/integration tests — only unit tests (267)
- No XCTest UI test target configured in Xcode project
- Event subscription lifecycle (subscribe → event → renew → unsubscribe) untested
- Network failover (hybrid → polling degradation) untested
- Artwork search race conditions (rapid track changes) untested
- Drag-drop queue reordering interaction untested

### Localization
- Timestamp formatting not localized in CSV exports
- Language switching requires app restart
- Some strings still hardcoded in English (context menu items, error messages)

---

## Feature Comparison with Sonos S2

| Feature | SonosController | Sonos S2 | Notes |
|---------|:-:|:-:|-------|
| Playback controls | Yes | Yes | Full parity |
| Volume / mute | Yes | Yes | Proportional mode is unique to us |
| EQ (bass/treble/loudness) | Yes | Yes | |
| Home Theater EQ | Yes | Yes | Sub, surround, night mode, dialog |
| Sleep timer | Yes | Yes | |
| Crossfade | Yes | Yes | |
| Queue management | Yes | Yes | Save as playlist, shuffle, clear |
| Group management | Yes | Yes | Drag in S2, editor in ours |
| Group presets | Yes | No | Unique to us |
| Local library browse | Yes | Yes | |
| Favorites | Read-only | Full CRUD | Cannot create/edit/delete |
| Playlists | Partial | Full | Can browse/play/save queue, cannot create empty |
| Music services | 7+ services | 100+ | We support key services |
| Listening history | Yes | No | Unique to us |
| Star/favorite tracks | Yes | No | Unique to us |
| Artwork search | Yes | No | Manual search + auto iTunes unique to us |
| Menu bar controls | Yes | No | Unique to us |
| 13 languages | Yes | 20+ | |
| Alarms | Blocked | Yes | S2 uses cloud API |
| Trueplay | No | Yes | Requires cloud/hardware |
| AirPlay 2 | No | Yes | |
| Voice assistant | No | Yes | |
| Party mode | No | Yes | One-click group all |
| Share now playing | No | Yes | |

---

## Moonshot Ideas

- **Multi-household support** — manage speakers across different Sonos systems / locations
- **Sonos as speaker for Mac** — route macOS audio output to Sonos speakers (virtual audio device)
- **Visual equalizer** — real-time audio visualization in Now Playing
- **Smart home dashboard** — embed Sonos controls in a broader home automation panel
- **iOS companion app** — share listening history and presets between Mac and iPhone
- **Apple Watch complications** — now playing glance and volume control
- **Siri Shortcuts** — "Hey Siri, play my morning preset on Sonos"
- **Time Machine for music** — "What was I listening to this time last year?"
- **Collaborative queue** — multiple family members add to the queue from their devices
- **Room-aware auto-play** — use Mac's location/proximity to auto-select the nearest speaker group
