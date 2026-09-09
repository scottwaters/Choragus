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

`Packages/SonosKit/Sources/SonosKit/Resources/Localizable.xcstrings` is the only translation file: an Apple String Catalog, JSON, one entry per key with a `stringUnit` per locale. Xcode's catalog editor opens it directly and shows any locale that is missing a value.

```json
"playPause" : {
  "extractionState" : "manual",
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "Play / Pause" } },
    "de" : { "stringUnit" : { "state" : "translated", "value" : "Wiedergabe / Pause" } }
  }
}
```

A matching `public static var` accessor on `L10n` (`Packages/SonosKit/Sources/SonosKit/Localization/L10n.swift`) gives call sites a shorthand:

```swift
public static var playPause: String { tr("playPause") }
```

`tr(_:)` reads the active locale from `UserDefaults[UDKey.appLanguage]` and falls back to English, then to the key. The catalog is a package resource (`resources: [.process("Resources")]`, `defaultLocalization: "en"`), reached through `Bundle.module`:

- **Xcode builds** (the app, `xcodebuild`) compile the catalog into one `Localizable.strings` table per `<locale>.lproj` in `SonosKit_SonosKit.bundle`; `tr` resolves the locale's bundle and calls `localizedString(forKey:value:table:)`.
- **SwiftPM command-line builds** (`swift build`, `swift test`, CI) copy the catalog as is; `tr` decodes the catalog JSON once on first use instead. Same data, same lookup rules.

Keys stay in the catalog and lookup stays under the app's own language setting, so a user can run Choragus in Japanese on an English Mac.

## Invariants

Every new user-visible string must:

1. Add a `public static var` accessor (or `public static func` for format strings) to `L10n`.
2. Add the key to `Localizable.xcstrings` with a value for **all 13 locales** (Xcode's catalog editor, or edit the JSON).
3. Reference via `L10n.keyName` from view code, never a hardcoded literal.

`L10nCatalogTests` pins all of it on every `swift test`: every key carries every locale, no key is duplicated, every accessor resolves to a catalog key and every catalog key has an accessor, and every locale consumes the same format placeholders as English. The CI workflow (`.github/workflows/ci.yml`, hygiene job) runs the same checks without a Swift toolchain.

### No duplicate keys

A duplicate key in the catalog JSON is silently collapsed to the last value by any JSON parser, so the test and the CI gate both count raw key lines against parsed keys. Before the catalog (v3.6 to v5.0) the translations were Swift dictionary literals, where a duplicate key trapped at first access; that failure mode is gone.

### No malformed unicode escapes

The catalog stores characters as UTF-8, not escapes. `AppLanguage.displayName` and the few strings that remain in Swift use `\u{XXXX}` escapes; a truncated escape there is a compile error, not a runtime one.

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

## Shortcuts and Siri (App Intents)

App Intents metadata is the one place `L10n` cannot reach: intent titles, descriptions, parameter names, parameter summaries, entity type names and Siri phrases must be string literals so the `appintentsmetadataprocessor` can extract them at build time, and the system resolves them against the app bundle's string catalogs in the **system** locale, not the in-app language.

- `Choragus/Localizable.xcstrings` — intent titles, descriptions, parameter titles and descriptions, `ParameterSummary` strings (`"Play on ${room}"`), `TypeDisplayRepresentation` names and `shortTitle`s. Keys are the English literals as written in `PlaybackIntents.swift`.
- `Choragus/AppShortcuts.xcstrings` — the spoken phrases (`"Play ${applicationName} in ${room}"`).
- `knownRegions` in the project lists all 13 languages so the catalogs compile to per-language `.lproj` folders.

Two consequences:

- Dynamic text inside an intent (entity display names, thrown error messages) still goes through `L10n` and follows the in-app language. A user whose Mac runs German but who set Choragus to English sees German action titles around English room labels. Accepted: the picker labels match what the app's sidebar shows.
- Declaring the regions also lets AppKit-provided strings (standard menu items, open/save panels, alert buttons) follow the system language instead of staying English. Before v5.0 the bundle declared only `en`.

Adding an intent string: write the literal in Swift, add the same literal as a key in the matching catalog with all 12 translations. A key missing from the catalog falls back to the literal; a key that drifts from the literal silently falls back too, so keep them byte-identical.

## Translator workflow

The catalog is the source of truth and is what Apple's tooling expects:

- **Xcode**: open `Localizable.xcstrings`; the editor lists every key with a column per locale and flags the ones without a value.
- **XLIFF round-trip**: `xcodebuild -exportLocalizations -localizationPath <dir> -exportLanguage de` on the package produces an `.xcloc` for a translator; `-importLocalizations` merges it back.
- **By hand**: the JSON is stable and sorted, so a small change is a small diff.

When adding a single new key:

1. Add the `public static var` accessor.
2. Add the key to the catalog with a value for every locale (`"state": "translated"`).
3. `swift test --filter L10nCatalogTests` — it names any locale, accessor or placeholder that does not line up.

Bulk additions (Help rewrite, Settings reorganisation) typically batch keys in groups of ~10 per dict-edit so the diff stays reviewable.
