/// Resizable popout for karaoke-style synced lyrics. Locked to the
/// group it was opened for; reopen to follow a different group.
///
/// Pure consumer of `LyricsCoordinator` — lyric content, parsed lines,
/// load status, and the user-tweaked timing offset all come from the
/// shared coordinator so the inline panel and this window stay in
/// lockstep on every dimension. No own fetch, no own offset save.
import SwiftUI
import SonosKit

struct LyricsKaraokeWindow: View {
    @EnvironmentObject var sonosManager: SonosManager
    @EnvironmentObject var lyricsCoordinator: LyricsCoordinator
    // Observed directly so user-driven art changes ("Search Artwork",
    // "Force Web Art", iTunes auto-resolve) republish through the
    // karaoke window's hero image and blurred backdrop without waiting
    // for a track-change reload. `SonosManager` exposes `artCache` as a
    // `let`, so observing it via `sonosManager` doesn't pick up the
    // inner `@Published discoveredArtURLs` change.
    @EnvironmentObject var artCache: ArtCacheService

    /// Global lyrics timing offset from Settings. Added on top of the
    /// per-track manual offset (the `±` toolbar) before being passed
    /// to `SlidingLyricsView`. Default `−2.0 s` empirically.
    @AppStorage(UDKey.lyricsGlobalOffset) private var lyricsGlobalOffset: Double = -2.0

    let groupID: String

    private var trackMetadata: TrackMetadata {
        sonosManager.groupTrackMetadata[groupID] ?? TrackMetadata()
    }

    private var anchor: PositionAnchor {
        sonosManager.groupPositionAnchors[groupID] ?? .zero
    }

    private var resolved: LyricsCoordinator.Resolved {
        lyricsCoordinator.resolved(for: trackMetadata)
    }

    private var lyricsOffset: Double {
        lyricsCoordinator.offset(for: trackMetadata)
    }

    private var albumArtURL: URL? {
        if let cached = artCache.lookupCachedArt(uri: trackMetadata.trackURI,
                                                 title: trackMetadata.title),
           !cached.isEmpty,
           let url = URL(string: cached) {
            return url
        }
        if let raw = trackMetadata.albumArtURI, !raw.isEmpty,
           let url = URL(string: raw) {
            return url
        }
        return nil
    }

    var body: some View {
        // Window-size floor enforced at the AppKit level via
        // NSWindow.contentMinSize — adding a SwiftUI `.frame(minHeight:)`
        // here would centre-clip top + bottom together during resize.
        VStack(spacing: 0) {
            header
            lyricsArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if hasSyncedLyrics {
                offsetToolbar
            }
        }
        .background(backgroundArt)
        // Dynamic light/dark mode: bind the override to the user's
        // current appearance preference so flipping the setting (or
        // toggling the system theme when on `.system`) updates the
        // karaoke window live. Without this, the AppKit-hosted window
        // stays frozen at whichever theme was active when it opened.
        .preferredColorScheme(currentColorScheme)
        .task(id: trackMetadata.stableKey) {
            // Idempotent — the panel may have already triggered the
            // fetch, in which case this is a no-op.
            lyricsCoordinator.loadIfNeeded(for: trackMetadata)
        }
    }

    private var hasSyncedLyrics: Bool {
        resolved.status == .loaded && resolved.lyrics?.synced != nil
    }

    /// Maps the user's *karaoke-specific* appearance preference to a
    /// SwiftUI override. Independent of the main app theme so the
    /// karaoke window can stay dark (the default) even when the rest
    /// of Choragus is in light mode. `.system` → `nil` lets the OS
    /// theme drive the window.
    private var currentColorScheme: ColorScheme? {
        switch sonosManager.karaokeAppearanceMode {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }


    // MARK: - Sections

    /// Header sizing — bumped ~50 % above the original 96 pt baseline
    /// so the album art and track details have presence in the karaoke
    /// window's wide aspect ratio without crowding the lyrics. The
    /// constant flows through to album art, brand icon, wordmark
    /// height (75 % of art), and the text scale.
    private static let headerArtSize: CGFloat = 144

    private var header: some View {
        HStack(spacing: 24) {
            CachedAsyncImage(url: albumArtURL, cornerRadius: 10, priority: .interactive)
                .frame(width: Self.headerArtSize, height: Self.headerArtSize)
                .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
                // Same crossfade treatment as the main Now Playing
                // album art — `.id(url)` makes SwiftUI treat each new
                // URL as a view replacement so `.transition(.opacity)`
                // can fade the swap. `.animation` value-scoped to the
                // URL so unrelated header changes don't animate.
                .id(albumArtURL)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.4), value: albumArtURL)

            VStack(alignment: .leading, spacing: 6) {
                if !trackMetadata.title.isEmpty {
                    Text(trackMetadata.title)
                        .font(.system(size: 30, weight: .semibold))
                        .lineLimit(1)
                }
                if !trackMetadata.artist.isEmpty {
                    Text(trackMetadata.artist)
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !trackMetadata.album.isEmpty {
                    Text(trackMetadata.album)
                        .font(.system(size: 17))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Brand block on the right edge of the header. Wordmark
            // sits to the left of the icon (reads naturally LTR);
            // icon matches the album-art square on the opposite side
            // for visual symmetry. Wordmark is rendered at 75 % of
            // the album-art height so it has presence without
            // dominating. Both assets carry a `luminosity dark`
            // appearance variant and auto-swap with the active
            // colour scheme.
            Image("ChoragusTextLogo")
                .resizable()
                .scaledToFit()
                // Match Club Vis wordmark height (64 pt). Width is
                // intentionally unconstrained so `.scaledToFit()`
                // picks the asset's natural aspect width instead of
                // a fixed 320 pt frame — a fixed frame leaves
                // whitespace on either side of the asset and visually
                // pulls the trailing edge in from the 28 pt
                // horizontal padding the album art sits at.
                .frame(height: 64)
                .opacity(0.55)
                .accessibilityLabel("Choragus")
                .allowsHitTesting(false)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
    }

    /// Atmospheric backdrop. `scaleEffect(1.1)` hides the soft halo
    /// `.blur` creates at the bounds. `.drawingGroup()` flattens the
    /// 60pt gaussian blur to a Metal texture once instead of letting
    /// SwiftUI re-rasterise on every parent invalidation.
    @ViewBuilder
    private var backgroundArt: some View {
        // Wrap the conditional in a ZStack with value-scoped animation
        // so the backdrop blur crossfades when albumArtURL changes
        // (same shape as the header art transition). The
        // .drawingGroup keeps the gaussian blur cheap per-frame; the
        // crossfade runs at the layer level.
        ZStack {
            if let url = albumArtURL {
                CachedAsyncImage(url: url, cornerRadius: 0, priority: .background)
                    .blur(radius: 60)
                    .opacity(0.30)
                    .scaleEffect(1.1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .drawingGroup(opaque: false)
                    .allowsHitTesting(false)
                    .id(url)
                    .transition(.opacity)
            } else {
                Color.clear
            }
        }
        .animation(.easeInOut(duration: 0.4), value: albumArtURL)
    }

    @ViewBuilder
    private var lyricsArea: some View {
        switch resolved.status {
        case .idle, .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text(L10n.lookingUpLyrics)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            loadedContent
        case .missing:
            emptyMessage(icon: "text.alignleft", text: L10n.noLyricsFound)
        }
    }

    @ViewBuilder
    private var loadedContent: some View {
        let parsedLines = lyricsCoordinator.parsedLines(for: trackMetadata)
        if let lyrics = resolved.lyrics, lyrics.isInstrumental {
            VStack(spacing: 16) {
                Image(systemName: "music.note")
                    .font(.system(size: 64))
                    .foregroundStyle(.secondary)
                Text(L10n.instrumental)
                    .font(.title)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let lyrics = resolved.lyrics, lyrics.synced != nil, !parsedLines.isEmpty {
            SlidingLyricsView(
                lines: parsedLines,
                anchor: anchor,
                offset: lyricsOffset + lyricsGlobalOffset,
                visibleRows: 5,
                rowHeight: 120,
                peakSize: 72,
                baseSize: 44
            )
            .equatable()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let lyrics = resolved.lyrics, let plain = lyrics.plainText {
            ScrollView {
                VStack(spacing: 18) {
                    ForEach(plain
                        .split(separator: "\n", omittingEmptySubsequences: true)
                        .map(String.init), id: \.self) { line in
                        Text(line)
                            .font(.title2)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 36)
                .padding(.vertical, 28)
            }
            .textSelection(.enabled)
        } else {
            emptyMessage(icon: "text.alignleft", text: L10n.noLyricsFound)
        }
    }

    private func emptyMessage(icon: String, text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.title2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var offsetToolbar: some View {
        HStack(spacing: 6) {
            offsetButton(label: "−10", delta: -10)
            offsetButton(label: "−5", delta: -5)
            offsetButton(label: "−1", delta: -1)
            Text(offsetDisplayString)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 70)
                .contentShape(Rectangle())
                .onTapGesture {
                    lyricsCoordinator.setOffset(0, for: trackMetadata)
                }
                .help(L10n.tapToResetOffset)
            offsetButton(label: "+1", delta: 1)
            offsetButton(label: "+5", delta: 5)
            offsetButton(label: "+10", delta: 10)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
    }

    private func offsetButton(label: String, delta: Double) -> some View {
        Button(label) {
            lyricsCoordinator.setOffset(lyricsOffset + delta, for: trackMetadata)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .font(.callout.monospacedDigit())
    }

    private var offsetDisplayString: String {
        if lyricsOffset == 0 { return "0.0s" }
        let sign = lyricsOffset > 0 ? "+" : ""
        return String(format: "%@%.1fs", sign, lyricsOffset)
    }
}
