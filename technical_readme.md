# The SonosController — Technical README

Low-level reference for developers. For the end-user feature overview see [README.md](README.md).

---

## Project Shape

- **SonosController** — SwiftUI app target (views, ViewModels, app-level singletons).
- **SonosKit** — local Swift package (discovery, UPnP/SOAP services, models, caching, SMAPI, play history, transport strategies).
- **~24,000 lines of Swift** across 80+ source files.
- **292 unit tests** covering classifier logic, XML parsing, grace-period state machines, topology-merge invariants (value equality, stable member sort, household partitioning, grace window), protocol conformance, and model enrichment.
- **Zero external dependencies.** No CocoaPods, no Carthage, no remote SPM packages. The entire project builds against Apple's standard frameworks.
- Targets macOS 14+. Universal binary (arm64 + x86_64).

For deeper detail, see the documents under `docs/`:

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — module-by-module breakdown.
- [docs/PROTOCOLS.md](docs/PROTOCOLS.md) — UPnP/SOAP reference for every service action used.
- [docs/CACHING.md](docs/CACHING.md) — topology cache, image cache, art URL cache.

---

## Protocol Stack

| Protocol | Purpose |
|----------|---------|
| SSDP | UDP multicast discovery of speakers on 239.255.255.250:1900 |
| UPnP/SOAP | HTTP POST + XML commands to speakers on port 1400 |
| GENA | Real-time push notifications via HTTP SUBSCRIBE/NOTIFY |
| SMAPI | Music service browsing and authentication (AppLink / DeviceLink) |
| DIDL-Lite | XML metadata format for tracks, albums, playlists |
| iTunes Search API | Album art fallback for local library content |

All speaker communication is local — no cloud service is required beyond optional SMAPI authentication flows with individual music services.

---

## Architecture Highlights

### Service Layer (Interface Segregation)

11 focused service protocols instead of a single fat interface:

`PlaybackService`, `VolumeService`, `EQService`, `QueueService`, `BrowsingService`, `GroupingService`, `AlarmService`, `MusicServiceDetection`, `TransportStateProviding`, `ArtCache`.

ViewModels depend on protocol types, not `SonosManager` directly. `MockSonosServices` provides testable stand-ins for all protocols.

### Transport Strategies

Two implementations of `TransportStrategy` behind a single protocol:

- **`HybridEventFirstTransport`** (default) — subscribes to UPnP GENA events, falls back to targeted polling when subscriptions fail. Reconciliation poll every 30 s as a safety net. Position polled every 1 s for smooth seek-bar.
- **`LegacyPollingTransport`** — pure 5-second SOAP polling. Compatibility fallback for networks where multicast GENA is unreliable.

Switchable in Settings → System.

### Topology Management

`GetZoneGroupState` is called per-coordinator, and its response describes only that household's groups. Two households on the same LAN (S1 + S2) return disjoint topologies.

`SonosManager.refreshTopology` merges new groups into the existing list **per household** — never wholesale replacement. Pre-household-ID cache entries are backfilled on first live refresh when their coordinator's household becomes known. Each refresh is serialized per-household via `refreshingHouseholds: Set<String>` so S1 and S2 don't block each other.

**Defensive rules to avoid speaker flicker:**

1. `handleDiscoveredDevice` preserves any previously-resolved `householdID` across `GetHouseholdID` retries. A transient SOAP failure must not wipe a known household — seeding `device.householdID = existing?.householdID` before the fresh fetch makes the write idempotent when the retry fails.
2. `refreshTopology` aborts if the source device's household is still `nil`. Merging with a `nil` household would let the filter `groups.filter { $0.householdID != household }` retain every known-household group while appending new `nil`-tagged duplicates — producing visible duplicates and section reshuffles on subsequent rescans.
3. Members constructed in the topology loop inherit the source device's resolved `softwareVersion` / `swGen` only when the existing entry's corresponding field is empty, so a known fact is never downgraded to unknown.
4. **Members are stably sorted by `id` at construction.** `SonosGroup` conforms to `Equatable` by synthesis, and array equality is order-sensitive — a pure reorder in the next topology response would otherwise trip the change detector.
5. **Writes into `devices` are equality-guarded.** `@Published` on a dictionary fires on every assignment, regardless of whether the new value differs. Unconditional writes cascade re-renders through every `@EnvironmentObject` observer, which was triggering `onChange(of: groups)`-bound scroll animations even when `groups` itself was unchanged.
6. **Group-removal grace window (`groupRemovalGrace = 30 s`).** Different Sonos speakers in the same household occasionally return subtly different `GetZoneGroupState` views while state propagates. A single source's topology is no longer treated as authoritative for immediate removal — a group missing from the new response is retained if its id was present in *any* topology within the grace window. Only groups absent for longer than 30 s are actually dropped.

**Defensive rules for artwork on radio streams:**

1. `ArtResolver.handleTrackURIChanged` does **not** clear `radioTrackArtURL` when a new radio track starts. The prior track's art stays visible until `searchRadioTrackArt` completes its iTunes lookup and sets the new URL (or clears it explicitly on no-match). This eliminates the `old-track-art → station-art → new-track-art` flicker sequence during radio advances.
2. `NowPlayingViewModel.searchRadioTrackArt` short-circuits when `transportState.isActive == false`. While paused, stream-content pings oscillate `title` between empty and populated; without the guard, each oscillation would clear radio art and then re-search, producing a visible flicker even though no real track change occurred.

### S1 / S2 Classification

Speakers self-identify via the UPnP device-description fields:

- `<swGen>` — canonical Sonos platform flag (`1` = S1, `2` = S2). Preferred when present.
- `<softwareVersion>` — firmware major version (≥ 12 ⇒ S2, < 12 ⇒ S1). Fallback.

Logic lives in `SonosSystemVersion.classify(swGen:softwareVersion:)` with 17 dedicated unit tests.

### Cache Layers

- **Topology cache** (`topology_cache.json`) — groups, devices, browse sections. Enables Quick Start mode. No TTL; staleness detected on SOAP failure (`withStaleHandling`).
- **Image cache** (`ImageCache/`) — two-tier (`NSCache` + disk). LRU eviction. Configurable size (100 MB – 5 GB) and age (7 d – ∞).
- **Art URL cache** (`art_url_cache.json`) — persisted URL lookups keyed by item ID, resource URI, title, normalized title. Debounced 2 s writes.
- **Play history** (`play_history.sqlite`) — SQLite database. SQL-based filtering for 50,000+ entries.

All cache files are created with `0o600` permissions.

### Security

- **Keychain** — all credentials (SMAPI tokens, Last.fm API app credentials, Last.fm session keys) live in a single unified `SecretsStore` Keychain item with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. One ACL means one authorization prompt per rebuild instead of one per credential. Legacy per-service Keychain items migrate automatically on first launch. Metadata (which services are connected) stored separately in Application Support JSON.
- **Scrobbling credentials** — BYO-only. The app ships no bundled Last.fm API key; users register their own at last.fm/api/account/create and paste it into Settings. Submissions are computed entirely from the local `play_history` table — no new network taps on the speakers.
- **App sandbox** — network client + server entitlements only. No filesystem, no contacts, no other apps.
- **ATS hardened** — specific domain exceptions for legacy HTTP radio services (TuneIn, 1.fm, radiotime.com), no blanket `NSAllowsArbitraryLoads`.
- **Error sanitization** — SOAP faults/HTTP errors surface user-friendly messages; raw details never exposed.
- **No telemetry** — no analytics, no crash reporting, no network calls outside Sonos LAN and explicitly-invoked music services / iTunes Search / GitHub releases (update check only).

### Localization (L10n)

Dictionary-based localization in `Packages/SonosKit/Sources/SonosKit/Localization/L10n.swift`. Keys are looked up against `UserDefaults[UDKey.appLanguage]` with English as the fallback. Supported languages: English, German, French, Dutch, Spanish, Italian, Swedish, Norwegian (nb), Danish, Japanese, Portuguese, Polish, Chinese Simplified.

**Invariant:** every new user-visible string surface must:

1. Add a `public static var` accessor (or `public static func` for format strings) to `L10n`.
2. Add the translation entry to the `translations` dictionary covering all 13 locales.
3. Reference via `L10n.keyName` (not hardcoded literals).

Format-string helpers use `String(format:)` with `%1$@` / `%2$@` positional placeholders so translations can reorder arguments — see `L10n.updateAvailableBody(current:latest:)` for the canonical example.

**Scope note for v3.5:** the `HelpView` body prose is intentionally English-only. Topic titles (`L10n.helpGettingStarted`, etc.) and the navigation chrome are localized. Translating the detailed help paragraphs would triple the L10n dictionary size and is deferred to a future release.

### First-Run Welcome

`FirstRunWelcomeView` is shown once after the main window first appears. Dismissal is persisted via `UserDefaults[firstRunWelcome.shown]`. The dialog's *Open Settings* button directly opens the Settings sheet (via the existing `.openSettings` notification) so users can jump to Settings → Music without navigating the toolbar.

### Update Checker

Queries `https://api.github.com/repos/scottwaters/SonosController/releases/latest`, compares `tag_name` (normalized — strips leading "v", extracts numeric run) against the running `CFBundleShortVersionString` using a pure numeric semver comparator.

Silent background check at most once per 24 h at launch (`UserDefaults[updateChecker.lastCheck]`). Manual check from the app menu always reports a result. All outcomes (`available`, `current`, `error`) are logged via `sonosDebugLog`.

---

## Building From Source

**Prerequisites:** Xcode 15 or later. macOS 14+ SDK.

```bash
git clone https://github.com/scottwaters/SonosController.git
cd SonosController

xcodebuild -scheme SonosController \
  -configuration Release \
  -destination 'platform=macOS' \
  CONFIGURATION_BUILD_DIR="$(pwd)/build" \
  ONLY_ACTIVE_ARCH=NO \
  ARCHS="arm64 x86_64" \
  build
```

The resulting app is at `build/SonosController.app`. Use `-configuration Debug` for a debug build with symbols and `DEBUG` defined.

### Running Tests

```bash
cd Packages/SonosKit
swift test
```

The Swift Package Manager target for `SonosKit` is self-contained and runs independently of the app target. Tests are organized into five files covering XML parsing, service protocols, model enrichment, session state, and the `SonosSystemVersion` classifier.

### Project Conventions

- **Build output** — always to `build/SonosController.app` at the project root. Avoid DerivedData for command-line builds.
- **Universal binary** — CI should always pass `ONLY_ACTIVE_ARCH=NO ARCHS="arm64 x86_64"`.
- **Kill before rebuild** — `pkill -x SonosController` (or `killall SonosController`) before a rebuild to avoid stale state.
- **No force-unwraps** — use `guard let` with a safe fallback (see `SonosDevice.fallbackURL` pattern).
- **Debug logging** — `sonosDebugLog(_:)` writes to `~/Library/Containers/com.sonoscontroller.app/Data/Library/Application Support/SonosController/sonos_debug.log` in DEBUG builds. Look for `[DISCOVERY]`, `[UPDATE]`, and similar prefixes.

---

## File System Paths (Runtime)

Under `~/Library/Containers/com.sonoscontroller.app/Data/Library/Application Support/SonosController/`:

| File | Purpose |
|------|---------|
| `topology_cache.json` | Quick Start speaker cache |
| `art_url_cache.json` | Persisted art URL lookups |
| `group_presets.json` | Saved group presets with volumes/EQ |
| `playlist_services_cache.json` | Background playlist service-badge scan results |
| `play_history.sqlite` | Play history + starred tracks |
| `ImageCache/` | On-disk album-art JPEG cache (LRU evicted) |
| `sonos_debug.log` | Debug output (DEBUG builds only) |

---

## Contributing

Issues and PRs welcome at [github.com/scottwaters/SonosController](https://github.com/scottwaters/SonosController).

Before opening a PR:

1. `swift test` must pass in `Packages/SonosKit`.
2. New public API in `SonosKit` should include a doc comment.
3. Add or update unit tests when changing model logic, XML parsers, or classifiers.
4. Respect the engineering principles in [docs/Core software engineering principles:.md](../docs/Core%20software%20engineering%20principles%3A.md) (if present in the repo root).

## License

MIT. See [LICENSE](LICENSE).
