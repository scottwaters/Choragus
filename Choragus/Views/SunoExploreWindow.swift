/// SunoExploreWindow.swift — Popup browser for suno.com with Sonos playback.
///
/// Hosts `SunoWebView` (suno.com/explore by default) so the user browses and
/// searches Suno's catalog using Suno's own site. When the current page is a
/// public song, the toolbar lights up Play / Add to Queue, which resolve the
/// page URL to its CDN MP3 (`SunoResolver`) and play it on the main window's
/// currently-selected group via the queue-based HTTP-get path
/// (`BrowsePlaybackStrategy.directHTTPSQueue`). Public songs only; no sign-in.
import SwiftUI
import SonosKit

struct SunoExploreWindow: View {
    @EnvironmentObject var sonosManager: SonosManager
    @StateObject private var web = SunoWebController()
    @State private var status: String?
    @State private var isWorking = false
    // Dedupe: the click path and the audio-layer hook can both fire for the
    // same track within a moment — ignore a repeat of the same song URL.
    @State private var lastPlayURL = ""
    @State private var lastPlayAt = Date.distantPast

    private static let exploreURL = URL(string: "https://suno.com/explore")!

    /// Tracks the main window's live selection so playback targets whatever
    /// group the user currently has selected, even after the popup is open.
    private var selectedGroup: SonosGroup? {
        let id = UserDefaults.standard.string(forKey: UDKey.lastSelectedGroupID)
        return sonosManager.groups.first(where: { $0.id == id }) ?? sonosManager.groups.first
    }

    /// The current page URL when it points at a playable public Suno song.
    private var playableURL: URL? {
        guard let s = web.currentURL?.absoluteString else { return nil }
        let isSong = s.range(of: "suno\\.com/song/[0-9a-fA-F-]{36}", options: .regularExpression) != nil
        let isShare = s.range(of: "suno\\.com/s/", options: .regularExpression) != nil
        return (isSong || isShare) ? web.currentURL : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            SunoWebView(initialURL: Self.exploreURL, controller: web)
        }
        .frame(minWidth: 480, minHeight: 360)
        .onAppear {
            // Route the page's in-page play button + right-click menu to Sonos.
            web.onPlay = { url in act(url) { try await sonosManager.playBrowseItem($0, in: $1) } }
            web.onQueue = { url in act(url) { _ = try await sonosManager.addBrowseItemToQueue($0, in: $1) } }
            web.onPlayAll = { urls in actAll(urls) }
            web.onPlaylist = { url in playPlaylist(url) }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { web.goBack() } label: { Image(systemName: "chevron.backward") }
                .disabled(!web.canGoBack)
            Button { web.goForward() } label: { Image(systemName: "chevron.forward") }
                .disabled(!web.canGoForward)
            Button { web.reload() } label: { Image(systemName: "arrow.clockwise") }
            Button { web.load(Self.exploreURL) } label: { Image(systemName: "house") }
                .help(L10n.backToExplore)

            Divider().frame(height: 16)

            if let url = playableURL, let group = selectedGroup {
                Text("→ \(group.name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button {
                    act(url) { try await sonosManager.playBrowseItem($0, in: $1) }
                } label: { Label(L10n.play, systemImage: "play.fill") }
                    .disabled(isWorking)
                Button {
                    act(url) { _ = try await sonosManager.addBrowseItemToQueue($0, in: $1) }
                } label: { Label(L10n.addToQueue, systemImage: "plus") }
                    .disabled(isWorking)
            } else {
                Text(selectedGroup == nil ? L10n.noSpeakerSelected : L10n.openASongToPlay)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
            if isWorking { ProgressView().controlSize(.small) }
            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// Resolve the current Suno page to a track and run a playback action on
    /// the live-selected group. Used by the toolbar buttons and by the
    /// overridden in-page play button / right-click menu.
    private func act(_ url: URL, _ run: @escaping (BrowseItem, SonosGroup) async throws -> Void) {
        // Drop a duplicate play of the same song within a few seconds (click +
        // audio-hook firing for one tap).
        if url.absoluteString == lastPlayURL, Date().timeIntervalSince(lastPlayAt) < 3 { return }
        lastPlayURL = url.absoluteString
        lastPlayAt = Date()
        guard !isWorking else { return }
        guard let group = selectedGroup else {
            status = L10n.noSpeakerSelected
            return
        }
        isWorking = true
        status = nil
        sonosDebugLog("[SUNO] action tapped for \(url.absoluteString) group=\(group.name)")
        Task {
            do {
                let item = try await SunoResolver.resolve(url.absoluteString)
                sonosDebugLog("[SUNO] resolved → title=\(item.title) uri=\(item.resourceURI ?? "nil")")
                try await run(item, group)
                sonosDebugLog("[SUNO] playback action completed")
                await MainActor.run {
                    status = item.title
                    isWorking = false
                }
            } catch {
                sonosDebugLog("[SUNO] action FAILED: \(error)")
                await MainActor.run {
                    status = L10n.couldNotPlaySong
                    isWorking = false
                }
            }
        }
    }

    /// Fetch a playlist / album page's song list, then replace the queue.
    private func playPlaylist(_ url: URL) {
        guard !isWorking else { return }
        isWorking = true
        status = L10n.loadingPlaylistEllipsis
        Task {
            let urls = await SunoResolver.playlistSongURLs(url.absoluteString).compactMap { URL(string: $0) }
            await MainActor.run {
                isWorking = false
                if urls.isEmpty {
                    status = L10n.couldNotReadPlaylist
                } else {
                    actAll(urls)
                }
            }
        }
    }

    /// Resolve a whole playlist / genre page's songs and replace the queue.
    private func actAll(_ urls: [URL]) {
        guard !isWorking, !urls.isEmpty else { return }
        guard let group = selectedGroup else {
            status = L10n.noSpeakerSelected
            return
        }
        isWorking = true
        status = L10n.loadingSongsFormat(urls.count)
        sonosDebugLog("[SUNO] play all \(urls.count) songs group=\(group.name)")
        Task {
            // Resolve concurrently but preserve the page's list order.
            let items: [BrowseItem] = await withTaskGroup(of: (Int, BrowseItem?).self) { tg in
                for (i, url) in urls.enumerated() {
                    tg.addTask { (i, try? await SunoResolver.resolve(url.absoluteString)) }
                }
                var buf = [BrowseItem?](repeating: nil, count: urls.count)
                for await (i, item) in tg { buf[i] = item }
                // De-dup by resolved track URI as a safety net against any
                // duplicate links that slipped through the page-side de-dup.
                var seen = Set<String>()
                return buf.compactMap { $0 }.filter { item in
                    guard let u = item.resourceURI else { return true }
                    return seen.insert(u).inserted
                }
            }
            sonosDebugLog("[SUNO] play all resolved \(items.count)/\(urls.count)")
            do {
                try await sonosManager.playItemsReplacingQueue(items, in: group)
                await MainActor.run {
                    status = L10n.playingSongsFormat(items.count)
                    isWorking = false
                }
            } catch {
                sonosDebugLog("[SUNO] play all FAILED: \(error)")
                await MainActor.run {
                    status = L10n.couldNotPlayList
                    isWorking = false
                }
            }
        }
    }
}
