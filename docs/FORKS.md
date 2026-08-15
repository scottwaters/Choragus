# For Forks & Home Builds

Choragus is open source. You can clone it, build it, and run your own copy. A few features in the upstream binary depend on developer keys, signing identities, or hosted infrastructure that aren't (and can't be) included in the source. Those features stay inert in any self-built copy unless you supply your own substitutes — by design, so a fork can never be silently updated by upstream's binary or impersonate the upstream signing identity.

## What works identically in every self-built copy

All Sonos control: speaker discovery, transport, volume, queue, browse, presets, EQ. Lyrics (LRCLIB) and iTunes album art (public APIs, no key). Last.fm scrobbling, when you've configured your own Last.fm API key in Settings — already the design for everyone. SMAPI-backed music services (Spotify, etc.), which authenticate against your own speakers using the speakers' built-in flow. Local Plex direct browsing.

## What's gated on developer credentials you'd need to supply

### Auto-update

The upstream binary auto-updates via [Sparkle 2](https://sparkle-project.org), reading a signed appcast hosted under the upstream maintainer's GitHub Pages and verified against an EdDSA public key embedded in the bundle. A self-built copy does not auto-update — the **Check for Updates…** menu item drops back to opening the GitHub Releases page in your browser.

To run your own auto-update channel:

1. Generate your own EdDSA keypair with Sparkle's `generate_keys` tool. The private key auto-stashes in your macOS Keychain; the public key prints to stdout.
2. Host your own `appcast.xml` on a stable HTTPS URL (GitHub Pages on the `gh-pages` branch of your fork is the easy path).
3. At build time, populate `SUFeedURL` (your appcast URL) and `SUPublicEDKey` (your public key string) in `Choragus/Info.plist`. Empty / unset values keep Sparkle inert and the fallback notification path active.
4. After signing each release zip, run Sparkle's `sign_update` tool against the zip and append the resulting EdDSA signature + length to your appcast `<item>` enclosure. Push the appcast to `gh-pages` so future builds find the newer entry.

Sparkle's docs at <https://sparkle-project.org/documentation/> cover the signing-key workflow and appcast schema in detail.

### Code signing and notarization

The upstream binary is signed with the maintainer's Apple Developer ID and Apple-notarized, so Gatekeeper opens it cleanly on first launch on any Mac. A self-built copy is unsigned (or ad-hoc signed) by default — the first launch needs a right-click → **Open** to bypass the Gatekeeper warning, or you can sign and notarize with your own Apple Developer Program account.

A Developer Program membership is currently $99/year. For personal-use builds it's not required: macOS will let you run an unsigned binary after the first right-click → Open, and Keychain access works the same way once granted.

### Donation links

The upstream binary shows a heart button in the toolbar with ways to support the project. Both destinations are injected at package time from build configuration that is not in the repo, so a self-built copy has neither key and shows no button at all — not an empty one. Nothing else differs; no feature is gated behind it.

To point a fork at your own destinations, set `CHORAGUS_SUPPORT_URL` and/or `CHORAGUS_BITCOIN_ADDRESS` as build settings; they land in `Info.plist` as `ChoragusSupportURL` and `ChoragusBitcoinAddress`. Each row appears only if its key is non-empty.

### Maintainer-only tuning surfaces

The Back of the Club debug companion window is compiled only when `CHORAGUS_DEV` is defined, which the maintainer's local build sets and nothing else does. Release builds and fork builds omit it entirely. Nothing depends on it.

### Stable Keychain access across rebuilds

Choragus stores user-supplied secrets (Last.fm API key, SMAPI tokens, Plex tokens, etc.) in the macOS Keychain, ACL'd to the running binary's code identity. Ad-hoc-signed self-built copies get a different code identity on every rebuild, so macOS re-prompts for Keychain access on each launch. Signing with a stable Developer ID — your own — eliminates the re-prompt loop.

Not a feature gate, just a build-quality difference worth knowing about if you're iterating on the source.

## Future credential-gated features

If new functionality lands that requires its own developer credentials, hosted infrastructure, or signing material, it will be listed here. The pattern stays the same: empty Info.plist field → fallback or no-op; populated → full feature.

## End-to-end build pipeline

For prerequisites and the actual `xcodebuild` invocation, see [building from source](../technical_readme.md#building-from-source) in the technical README.
