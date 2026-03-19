# Caching System

SonosController uses three caching layers to minimise latency and provide instant startup.

## 1. Topology Cache (Speaker Layout)

**Location:** `~/Library/Application Support/SonosController/topology_cache.json`
**Format:** JSON
**Contents:** Zone groups, devices (IP, UUID, room name, model), browse sections

### How it works

- **On successful discovery:** the current speaker topology and browse sections are serialized to JSON and written to disk.
- **On next launch (Quick Start mode):** the cached topology is loaded before SSDP discovery begins. The UI renders immediately with cached rooms and browse categories.
- **Background refresh:** SSDP discovery runs simultaneously. When the first live speaker responds, the topology is refreshed from the network and the cache is updated.
- **Transition:** `isUsingCachedData` flips to `false` and the blue cache banner disappears once live data replaces the cached data.

### Stale data handling

If a user taps a room whose speaker IP has changed since the cache was written:

1. The SOAP command fails with a network timeout
2. `withStaleHandling()` catches the error
3. `staleMessage` is set — an orange warning banner appears in the UI
4. `rescan()` is triggered — SSDP re-discovers all speakers
5. The topology updates with correct IPs
6. The banner auto-dismisses

The user sees a brief "not responding, refreshing..." message and the speaker list corrects itself within a few seconds.

### Settings

- **Quick Start mode (default):** loads from cache, refreshes in background
- **Classic mode:** ignores cache, waits for live discovery
- **Clear Speaker Cache:** removes the JSON file; next launch discovers fresh

## 2. Album Art Cache (Images)

**Location:** `~/Library/Application Support/SonosController/ImageCache/`
**Format:** JPEG files (80% quality compression)
**Key:** Deterministic hash of the image URL

### Memory tier

- `NSCache` with 200 image limit and 50 MB cost limit
- Checked first on every image request
- Evicted automatically by the system under memory pressure
- Populated from disk cache hits and network fetches

### Disk tier

- JPEG files stored in the ImageCache directory
- 200 MB maximum — LRU eviction removes oldest-accessed files when exceeded
- File modification date is updated on each read (touch) to track access recency
- Survives app restarts

### Flow

```
Image requested for URL
  → Check memory cache (NSCache)
    → HIT: return instantly
    → MISS: Check disk cache
      → HIT: load from disk, store in memory, return
      → MISS: Fetch from speaker over HTTP
        → Store in memory + disk, return
```

### Where it's used

- **Now Playing** album art (large, 180x180)
- **Queue** thumbnails (36x36)
- **Browse** list thumbnails (40x40)

All three views use `CachedAsyncImage`, a drop-in replacement for SwiftUI's `AsyncImage` that integrates with `ImageCache.shared`.

### Settings

- **Clear Artwork Cache:** removes all files from the ImageCache directory and clears the memory cache. Shows current disk usage in the button label.

## 3. Optimistic State Cache (In-Memory)

Not a traditional cache, but a grace period system that temporarily holds user-intended state to prevent polling from reverting it.

### Problem

When you press Play, the app sends a SOAP `Play` command to the speaker. The speaker takes 1-3 seconds to start playing (buffering audio). During this time, the 2-second polling cycle queries `GetTransportInfo`, which still returns `STOPPED` or `TRANSITIONING`. Without protection, the UI would flip the icon back to "play" even though your command is in flight.

### Solution

Each state category has a grace timestamp:
- `transportGraceUntil` — protects play/pause state
- `volumeGraceUntil` — protects volume slider
- `muteGraceUntil` — protects mute toggle
- `modeGraceUntil` — protects shuffle/repeat

When an action is taken:
1. The UI state is updated optimistically (immediately)
2. The grace timestamp is set to `now + 5 seconds`
3. The SOAP command is sent
4. During polling, if the grace period is active, the polled value is ignored for that category
5. Exception: if the polled value matches the intended state (speaker caught up), the grace ends early

This means:
- **Play:** icon flips to pause immediately, stays there for up to 5 seconds regardless of what the speaker reports
- **Volume:** slider holds your position for 5 seconds, won't snap back
- **Shuffle/Repeat:** toggle flips immediately, won't revert

### Duration

5 seconds was chosen because:
- Most Sonos commands are acknowledged within 1-2 seconds
- Buffering for streaming content can take up to 3-4 seconds
- 5 seconds provides margin without being noticeably stale
