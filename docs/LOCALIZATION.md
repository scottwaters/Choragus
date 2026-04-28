# Localization

Choragus ships fully translated user interface, in-app help, and metadata sources across 13 locales. This document explains how the system is structured, the gotchas that have bitten the project repeatedly, and the conventions for adding new strings without crashing the app.

## Supported locales

| Code | Language |
|------|----------|
| `en` | English |
| `de` | German |
| `fr` | French |
| `nl` | Dutch |
| `es` | Spanish |
| `it` | Italian |
| `sv` | Swedish |
| `nb` | Norwegian (Bokmål) |
| `da` | Danish |
| `ja` | Japanese |
| `pt` | Portuguese |
| `pl` | Polish |
| `zh-Hans` | Chinese (Simplified) |

Norwegian Nynorsk (`nn`) and Traditional Chinese (`zh-Hant`) are not currently shipped; `AppLanguage.systemDefault` maps both to their closest sibling (`nb` and `zh-Hans` respectively) on first launch.

## Where translations live

`Packages/SonosKit/Sources/SonosKit/Localization/L10n.swift` is the only translation file. It's a single Swift dictionary keyed by string-id, with each value being a sub-dictionary keyed by locale code:

```swift
"playPause": [
    "en": "Play / Pause",
    "de": "Wiedergabe / Pause",
    // … all 13 locales
],
```

A matching `public static var` accessor on the `L10n` struct provides a callsite-friendly shorthand:

```swift
public static var playPause: String { tr("playPause") }
```

`tr(_:)` reads the active locale from `UserDefaults[UDKey.appLanguage]` and falls back to English on miss.

## Invariants

Every new user-visible string must:

1. Add a `public static var` accessor (or `public static func` for format strings) to `L10n`.
2. Add a translation entry to the `translations` dictionary covering **all 13 locales**.
3. Reference via `L10n.keyName` from view code, never a hardcoded literal.

### No duplicate keys

Swift 6 asserts on duplicate dictionary-literal keys at first dictionary access — `EXC_BREAKPOINT` before the app ever draws a window. v3.6 shipped with two `"never"` entries that crashed every install on Swift 6 toolchains.

The recommended pre-commit gate:

```bash
grep -nE '^[[:space:]]+"[a-zA-Z][a-zA-Z0-9_]*":[[:space:]]*\[' \
  Packages/SonosKit/Sources/SonosKit/Localization/L10n.swift \
  | awk -F'"' '{print $2}' | sort | uniq -c | awk '$1 > 1 {print}'
```

Any output is a duplicate. Fix before committing. A second sweep should also check for duplicate `public static var` accessors:

```bash
grep -nE '^\s+public static var [a-zA-Z][a-zA-Z0-9_]*' L10n.swift \
  | awk '{print $4}' | sort | uniq -d
```

### No malformed unicode escapes

L10n entries use `\u{XXXX}` escapes for non-ASCII characters so the file stays diff-friendly and never depends on the editor's encoding. A truncated escape like `\u{00DFen` (missing the closing `}` before the next character) is a compile error, not a runtime error — the build will fail loudly. If a build error mentions `Expected '}' in \u{...}`, the offending line is in the new strings you just added.

### Format strings

Use `%1$@`, `%2$@`, … positional placeholders so translations can reorder the arguments. For example:

```swift
public static func updateAvailableBody(current: String, latest: String) -> String {
    String(format: tr("updateAvailableBody"), current, latest)
}
```

```
"updateAvailableBody": [
    "en": "You're on %1$@. The latest is %2$@.",
    "ja": "現在 %1$@ をお使いです。最新は %2$@ です。",
    // …
],
```

Some locales naturally place the version *before* "latest" — positional placeholders let the translator do this without code changes.

## Reactivity to language changes

### Vanilla SwiftUI views

Most views read locale via the `L10n` accessors during `body`. They re-render automatically when `@AppStorage(UDKey.appLanguage)` is updated — provided they observe it directly or are inside a parent that does.

### Segmented `Picker` controls

SwiftUI segmented `Picker` caches its rendered labels at first render. Flipping the language doesn't invalidate the cache, so the segment labels stay in their pre-flip language indefinitely. The fix is the `.languageReactive()` view modifier:

```swift
Picker("", selection: $mode) {
    ForEach(CommunicationMode.allCases) { mode in
        Text(mode.displayName).tag(mode)
    }
}
.pickerStyle(.segmented)
.languageReactive()  // ← required
```

`.languageReactive()` reads `@AppStorage(UDKey.appLanguage)` and applies `.id(appLanguage)` so the entire view rebuilds on flip, discarding the cached labels.

For this to work the enum must expose a localised `displayName`:

```swift
enum CommunicationMode: String, CaseIterable {
    case eventDriven, legacyPolling
    var displayName: String {
        switch self {
        case .eventDriven: L10n.communicationEventDriven
        case .legacyPolling: L10n.communicationLegacyPolling
        }
    }
}
```

`AppearanceMode`, `StartupMode`, `CommunicationMode`, and `DiscoveryMode` all follow this pattern.

### AppKit-hosted SwiftUI windows

The About box, Help window, and Listening Stats window are SwiftUI views inside `NSHostingController`. AppKit-hosted SwiftUI doesn't observe `UserDefaults` automatically, so a language flip is invisible to those windows — they render in whatever language was active when the window opened.

`LanguageReactiveContainer` (in `WindowManager.swift`) is the wrapper:

```swift
struct LanguageReactiveContainer<Content: View>: View {
    @AppStorage(UDKey.appLanguage) private var lang: String = "en"
    let content: () -> Content
    var body: some View {
        content().id(lang)
    }
}
```

Wrap any SwiftUI view that's about to be hosted in `NSHostingController`:

```swift
let host = NSHostingController(
    rootView: LanguageReactiveContainer { ChoragusAboutView() }
)
```

## Language-aware metadata

Wikipedia, MusicBrainz, and Last.fm queries follow the user's app language — not the system locale.

### Wikipedia

`MusicMetadataService.fetchLocalisedWikipediaSummary` queries `{lang}.wikipedia.org` (e.g. `de.wikipedia.org`, `ja.wikipedia.org`) using the helper:

```swift
static func wikipediaLanguageCode() -> String { ... }
```

Falls back to `en.wikipedia.org` when the article isn't available in the target language. The English fallback is cached under the original language key so a missing article doesn't re-fetch every play.

For Simplified Chinese the subdomain is `zh.wikipedia.org` plus an `Accept-Language: zh-Hans` header so Wikipedia returns Simplified script rather than Traditional.

### Last.fm

`artist.getInfo` and `album.getInfo` carry a `lang=` parameter mapped from the app language via `lastFMLanguageCode()`. Last.fm falls back internally if the language isn't supported.

### Cache keys

`MetadataCacheRepository` keys carry a language prefix so e.g. an English bio (`en|artist:radiohead`) and a German bio (`de|artist:radiohead`) coexist instead of overwriting. See [docs/CACHING.md](CACHING.md) §6 for the full scheme.

### One-shot v4.0 migration

A one-shot UserDefault flag (`metadataCache.langPrefixMigrated.v1`) drives a SQLite UPDATE on first launch under v4.0 that renames any unprefixed legacy `artist:<x>` rows to `en|artist:<x>`. After the migration completes the flag is set, and subsequent launches skip the UPDATE. New installs never run the migration.

## First-run language detection

`AppLanguage.systemDefault` walks `Locale.preferredLanguages` and matches against the supported list with these special cases:

- Any `zh-CN` / `zh-SG` / `zh-Hans-*` → `zh-Hans`
- Any `nn-*` / `no-*` / `nb-*` → `nb`
- Otherwise the first `<two-letter>` prefix that matches a supported locale wins
- Falls back to `en`

`SonosManager.init` snapshots the detected value to `UserDefaults[UDKey.appLanguage]` on first launch, so subsequent macOS locale changes don't silently override the user's choice.

`FirstRunWelcomeView` includes a language `Picker` so the user can override the detected default before doing anything else.

## Date and number formatting

`L10n.currentLocale` returns a `Locale` matching the app-language preference. Use this on any `DateFormatter` / `NumberFormatter` instead of relying on `Locale.current`:

```swift
let formatter = DateFormatter()
formatter.locale = L10n.currentLocale
formatter.dateStyle = .medium
```

Mixing `Locale.current` (system) and `L10n.currentLocale` (app) leaks the system locale into otherwise-localised UI — e.g. the listening-history grouping headers used to show in the system locale even when the app was set to French. `PlayHistoryView2` migrated to `L10n.currentLocale`; the rest of the app should adopt it on next touch.

## Help body

As of v3.7 every paragraph in the in-app Help window is localised across all 13 languages. v4.0 expanded the topic count from 8 to 10 (added Now Playing details, Music Services) and grew the Preferences bullet list from 5 to 11. Translation conventions:

- Apple-macOS style guide is followed where it differs from generic translation (e.g. Norwegian "Innstillinger" rather than "Preferanser").
- Sonos product conventions: "Home Theater" stays English in French (matches sonos.com/fr-fr); zh-Hans uses 音箱 (Sonos PRC convention) rather than 扬声器 (generic).
- "Preset" stays as a borrowed term in Polish (`Preset`) for the Sonos preset concept rather than the literal `Ustawienie` (setting).

## Translator workflow

There's no external translation file (no `.xcloc`, no `.po`). All translations live in `L10n.swift`. The dictionary literal is the source of truth.

When adding a single new key, the easiest path is:

1. Add the `public static var` accessor.
2. Add the dict entry with placeholder values for the 12 non-English locales:
   ```swift
   "newKey": [
       "en": "The English copy.",
       "de": "<placeholder>", "fr": "<placeholder>", // …
   ],
   ```
3. Run the dup-key gate.
4. Build — it should succeed.
5. Replace the placeholders with translations. Re-running the dup-key gate after each batch.

Bulk additions (Help rewrite, Settings reorganisation) typically batch keys in groups of ~10 per dict-edit so the diff stays reviewable.
