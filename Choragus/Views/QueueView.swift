/// QueueView.swift — Queue panel displaying the current play queue.
///
/// Thin view layer — all business logic lives in QueueViewModel.
/// Supports drag-drop reordering and cross-view drag from browse panel.
import SwiftUI
import SonosKit
import UniformTypeIdentifiers

struct QueueView: View {
    /// External prop — the group currently selected in the sidebar. When the
    /// user switches speakers, SwiftUI passes a new value here and we need
    /// to push it into the view model (which otherwise holds onto the
    /// group captured at StateObject construction) and reload the queue.
    let group: SonosGroup

    @StateObject private var vm: QueueViewModel
    @State private var dropTargetIndex: Int?
    @State private var showFilterBar = false
    /// Single "Save to Playlist…" entry point. Opens a sheet that lets the
    /// user pick a destination system (Sonos always; Apple Music only when
    /// the whole queue is Apple Music catalog) and name the playlist.
    @State private var showSaveSheet = false
    @AppStorage(UDKey.appleMusicKitConnected) private var appleMusicKitConnected = false
    private let appleMusicProvider = AppleMusicProviderFactory.makeCurrent()
    /// Last `trackURI` we acted on. When the metadata stream pushes a
    /// new URI we schedule an authoritative `loadQueue()` so the
    /// current-track indicator re-syncs from `getPositionInfo` — same
    /// path the manual Refresh button uses. Sonos's UPnP events have
    /// been observed to push wrong / stale URIs in the seconds after
    /// a Prev/Next click, a queue-row jump, or a seek-then-auto-
    /// advance combo; the speaker's own polling response is the only
    /// source we've found that reliably agrees with the Sonos app.
    @State private var lastObservedTrackURI: String?
    @State private var trackURIRefreshTask: Task<Void, Never>?
    /// True once we've performed the one-shot initial scroll-to-current
    /// for the currently-selected `group`. Reset to `false` whenever the
    /// user switches speakers. Without this, the `.onChange(of: vm.current-
    /// Track)` handler can miss the launch case where `currentTrack` is
    /// set before `queueItems` are populated — `scrollTo(id:)` is a no-op
    /// against an id that hasn't materialised in the LazyVStack yet.
    @State private var didInitialScroll = false

    /// Debounce before the authoritative re-sync: long enough to collapse
    /// the STOPPED→PLAYING flap, short enough to keep up with the speaker.
    private static let trackURIResyncDebounce: Duration = .milliseconds(400)

    /// Single retry for when the speaker still answers with the outgoing
    /// track after the URI event.
    private static let trackURIResyncRetry: Duration = .milliseconds(1200)

    @EnvironmentObject private var sonosManager: SonosManager

    init(group: SonosGroup, sonosManager: SonosManager) {
        self.group = group
        _vm = StateObject(wrappedValue: QueueViewModel(sonosManager: sonosManager, group: group))
    }

    /// Apple Music catalog song IDs for the queue, in order — but only when
    /// EVERY item is an Apple Music catalog track (`sid=204`, `song%3a<id>`).
    /// `nil` if the queue is empty or mixes in any non-Apple-Music source,
    /// because a library playlist can only hold catalog songs. Each URI is
    /// `x-sonos-http:song%3a<id>.mp4?sid=204&…` (see AppleMusicPlaybackHelpers).
    private var appleMusicCatalogIDs: [String]? {
        guard !vm.queueItems.isEmpty else { return nil }
        var ids: [String] = []
        for item in vm.queueItems {
            guard let uri = item.uri, uri.contains("sid=204"),
                  let id = URIPrefix.appleMusicSongID(from: uri) else { return nil }
            ids.append(id)
        }
        return ids
    }

    /// Whether the queue can be saved as an Apple Music library playlist —
    /// MusicKit built in, Apple Music connected, and every item Apple Music
    /// catalog.
    private var canSaveToAppleMusic: Bool {
        AppleMusicProviderFactory.hasMusicKitSupport
            && appleMusicKitConnected
            && (appleMusicCatalogIDs?.isEmpty == false)
    }

    /// Destinations valid for the current queue. Sonos is always valid (a
    /// saved Sonos queue accepts any mix of sources). Service-specific
    /// destinations appear only when every track belongs to that service.
    private var validDestinations: [SaveQueueDestination] {
        var out: [SaveQueueDestination] = [.sonos, .choragus]
        if canSaveToAppleMusic { out.append(.appleMusic) }
        return out
    }

    /// Distinct source systems present in the queue, ordered, for the
    /// save-sheet summary (explains why a service destination is or isn't
    /// offered).
    private var queueSources: [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for item in vm.queueItems {
            let name = ServiceName.resolve(uri: item.uri)
            if seen.insert(name).inserted { out.append(name) }
        }
        return out
    }

    /// Dispatches a save-queue request to the chosen destination. Both
    /// branches report through the same `saveMessage` capsule the queue
    /// already overlays.
    @MainActor
    private func performSave(destination: SaveQueueDestination, name: String) async {
        switch destination {
        case .sonos:
            await vm.saveAsPlaylist(name: name)   // manages its own saveMessage + auto-clear
        case .appleMusic:
            let ids = appleMusicCatalogIDs ?? []
            guard !ids.isEmpty else { return }
            let ok = await appleMusicProvider.createLibraryPlaylist(name: name, catalogSongIDs: ids)
            vm.showSaveMessage(ok ? L10n.savedToAppleMusic(ids.count) : L10n.appleMusicSaveFailed)
        case .choragus:
            await vm.saveToChoragus(name: name)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            if showFilterBar {
                filterBar
            }
            Divider()
            content
        }
        // Full-window overlay shown whenever the queue is mid-mutation
        // (a batch add-to-queue or a refresh fetch in flight). The
        // earlier inline header indicator was easy to miss for the
        // long Plex / local-library batch adds where the user is left
        // wondering "is anything happening?". Translucent so the
        // existing queue stays visible underneath as a reassurance
        // that the prior state is still there. Excluded when the
        // queue is empty — that state already has its own dedicated
        // full-screen progress block in `content`.
        .overlay {
            if (vm.isLoading || sonosManager.isAddingToQueue) && !vm.queueItems.isEmpty {
                queueBusyOverlay
            }
        }
        .onAppear {
            vm.refreshLocalSavedQueues()
            Task { await vm.loadQueue() }
        }
        .onChange(of: group.id) { _, newID in
            // Propagate the speaker-selection change into the view model,
            // then refresh the queue from the newly-selected coordinator.
            vm.group = group
            vm.queueItems = []
            vm.currentTrack = 0
            // New speaker → new initial-scroll window. The first time
            // `queueItems` populates for this group we want the one-shot
            // jump-to-current-track to fire again.
            didInitialScroll = false
            Task { await vm.loadQueue() }
            _ = newID
        }
        .onReceive(sonosManager.$groupTrackMetadata) { newMap in
            vm.updateCurrentTrack()
            // Auto-reconcile on any trackURI change. Events are racy
            // (sometimes stale, sometimes wrong, sometimes out-of-
            // order) so we use them only as a *signal* that something
            // changed and then ask the speaker authoritatively. The
            // short debounce collapses the transient burst (STOPPED →
            // PLAYING flap during Prev/Next, or the Sonos quirk where
            // it briefly emits the prior track again); the bounded
            // retry covers the case where the speaker answers with the
            // outgoing track instead of waiting out a longer sleep on
            // every single advance.
            let uri = newMap[group.coordinatorID]?.trackURI
            if uri != lastObservedTrackURI {
                lastObservedTrackURI = uri
                trackURIRefreshTask?.cancel()
                trackURIRefreshTask = Task {
                    try? await Task.sleep(for: Self.trackURIResyncDebounce)
                    if Task.isCancelled { return }
                    // Lightweight indicator-only sync — no spinner.
                    // Queue items don't change on track advance, so
                    // we skip the full `Browse(Q:0)` round-trip.
                    let before = vm.currentTrack
                    await vm.refreshCurrentTrack()
                    guard vm.currentTrack == before else { return }
                    try? await Task.sleep(for: Self.trackURIResyncRetry)
                    if Task.isCancelled { return }
                    await vm.refreshCurrentTrack()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .queueChanged)) { note in
            // Fast path — the sender told us exactly what was appended. Skips
            // the Browse(Q:0) round-trip, which is expensive on S1 coordinators.
            if let items = note.userInfo?[QueueChangeKey.optimisticItems] as? [QueueItem] {
                sonosDiagLog(.info, tag: "QUEUE",
                             "queueChanged: optimistic append \(items.count) items")
                vm.optimisticallyAppend(items)
            } else {
                sonosDiagLog(.info, tag: "QUEUE",
                             "queueChanged: triggering full reload")
                vm.pendingPostAddRetry = true
                Task { await vm.loadQueue() }
            }
        }
        .sheet(isPresented: $showSaveSheet) {
            SaveQueueSheet(
                destinations: validDestinations,
                sources: queueSources,
                trackCount: vm.queueItems.count,
                onSave: { destination, name in await performSave(destination: destination, name: name) }
            )
        }
        .overlay(alignment: .bottom) {
            if let msg = vm.saveMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.green.opacity(0.8), in: Capsule())
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: - Subviews

    private var headerBar: some View {
        HStack(spacing: 6) {
            // Title — lowest priority. Shrinks / truncates first
            // when the panel is narrow.
            Text(L10n.queue)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(0)
                .fixedSize(horizontal: false, vertical: false)
            // The mid-mutation indicator now lives as a full-window
            // overlay (see `queueBusyOverlay`) so it's hard to miss
            // during long Plex / local-library batch adds. The header
            // stays clean.
            Spacer(minLength: 0)
            // Track count is informational — drops out before any
            // button gets clipped.
            ViewThatFits(in: .horizontal) {
                Text("\(vm.totalTracks) \(L10n.tracks)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                EmptyView()
            }
            .layoutPriority(2)
            // Buttons get the HIGHEST layout priority and each is
            // .fixedSize so SwiftUI can't ever shrink them below
            // their natural icon width. Putting them as direct
            // children of the parent HStack (not nested in a Group)
            // ensures the priority is applied per-view.
            Button { Task { await vm.loadQueue() } } label: {
                Image(systemName: "arrow.clockwise").font(.caption)
            }
            .buttonStyle(.plain)
            .tooltip("Refresh queue")
            .fixedSize()
            .layoutPriority(3)

            Button {
                showFilterBar.toggle()
                if !showFilterBar { vm.filterText = "" }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle").font(.caption)
                    .foregroundStyle(showFilterBar ? Color.accentColor : Color.primary)
            }
            .buttonStyle(.plain)
            .tooltip(L10n.filterQueuePlaceholder)
            .disabled(vm.queueItems.isEmpty && !showFilterBar)
            .fixedSize()
            .layoutPriority(3)

            Button { Task { await vm.shuffleQueue() } } label: {
                Image(systemName: "shuffle").font(.caption)
            }
            .buttonStyle(.plain)
            .tooltip(L10n.shuffleQueueTooltip)
            .disabled(vm.queueItems.count < 2)
            .fixedSize()
            .layoutPriority(3)

            savedQueuesMenu

            Button { showSaveSheet = true } label: {
                Image(systemName: "text.badge.plus").font(.caption)
            }
            .buttonStyle(.plain)
            .tooltip(L10n.saveToPlaylist)
            .disabled(vm.queueItems.isEmpty)
            .fixedSize()
            .layoutPriority(3)

            queueHistoryMenu

            Button { Task { await vm.clearQueue() } } label: {
                if vm.isClearing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "trash").font(.caption)
                }
            }
            .buttonStyle(.plain)
            .tooltip(L10n.clearQueue)
            .disabled(vm.queueItems.isEmpty || vm.isClearing)
            .fixedSize()
            .layoutPriority(3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Display-only filter over the queue rows. Drag-reorder is disabled
    /// while active (filtered indices don't map to queue positions).
    private var filterBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(L10n.filterQueuePlaceholder, text: $vm.filterText)
                .textFieldStyle(.plain)
                .font(.callout)
            if !vm.filterText.isEmpty {
                Button {
                    vm.filterText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    /// Choragus-side saved queues — load (replace or append) and manage.
    /// Saving happens through the existing save sheet ("Choragus"
    /// destination); this menu is the read side.
    private var savedQueuesMenu: some View {
        Menu {
            if vm.localSavedQueues.isEmpty {
                Text(L10n.noSavedQueues)
            } else {
                ForEach(vm.localSavedQueues) { saved in
                    Menu("\(saved.name) (\(saved.trackCount))") {
                        Button(L10n.queueReplace) {
                            Task { await vm.loadLocalSavedQueue(saved, append: false) }
                        }
                        Button(L10n.queueAppend) {
                            Task { await vm.loadLocalSavedQueue(saved, append: true) }
                        }
                        Divider()
                        Button(L10n.delete, role: .destructive) {
                            vm.deleteLocalSavedQueue(saved)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "tray.full").font(.caption)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tooltip(L10n.savedQueues)
        .fixedSize()
        .layoutPriority(3)
    }

    /// Undo buffer for destructive queue changes. Each entry restores the
    /// queue to a state captured before a replace-all or clear. Restoring
    /// snapshots the current queue first, so a restore is itself undoable.
    private var queueHistoryMenu: some View {
        Menu {
            let snapshots = vm.queueSnapshots
            if snapshots.isEmpty {
                Text(L10n.noQueueHistory)
            } else {
                ForEach(snapshots) { snap in
                    Button {
                        Task { await vm.restoreSnapshot(snap) }
                    } label: {
                        Text("\(snap.savedAt, style: .time) · \(snap.summary)")
                    }
                }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath").font(.caption)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tooltip(L10n.queueHistory)
        .disabled(vm.queueSnapshots.isEmpty)
        .fixedSize()
        .layoutPriority(3)
    }

    /// Translucent full-window overlay shown while a batch add-to-queue
    /// or a queue refresh is in flight. Sits on top of the existing
    /// queue list so the user can still see what's there (reassurance
    /// the prior state is intact) but the spinner makes "work in
    /// progress" unmistakable. The `.allowsHitTesting(false)` means
    /// row interactions still pass through, so the user can scroll /
    /// reorder / delete unrelated rows while the batch lands.
    private var queueBusyOverlay: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor).opacity(0.55)
            VStack(spacing: 12) {
                ProgressView()
                    .scaleEffect(1.4)
                Text(addingStatusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    private var addingStatusText: String {
        if sonosManager.isAddingToQueue {
            let n = sonosManager.addingToQueueProgress
            if n > 0 {
                return "Adding \(n) tracks…"
            }
            return L10n.addingToQueueEllipsis
        }
        return L10n.loadingQueueEllipsis
    }

    @ViewBuilder
    private var content: some View {
        if vm.isShuffling {
            // Full-screen spinner during a shuffle (user-initiated, brief).
            VStack(spacing: 8) {
                ProgressView()
                Text(L10n.shufflingEllipsis)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxHeight: .infinity)
        } else if (vm.isLoading || sonosManager.isAddingToQueue) && vm.queueItems.isEmpty {
            // Full-screen spinner when we have nothing to show — first launch,
            // speaker switch, cleared queue, or an add-to-queue in flight on
            // a currently-empty queue. On a reload where items are already
            // present, the inline header spinner is used instead so the list
            // stays visible.
            VStack(spacing: 8) {
                ProgressView()
                Text(sonosManager.isAddingToQueue ? L10n.addingToQueueEllipsis : L10n.loadingQueueEllipsis)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxHeight: .infinity)
        } else if vm.queueItems.isEmpty {
            emptyState
        } else {
            queueList
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(L10n.queueIsEmpty)
                .foregroundStyle(.secondary)
            Text(L10n.dragTracksHere)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onDrop(of: [.text], isTargeted: nil) { _ in
            handleBrowseDrop(atPosition: 0)
        }
    }

    private var queueList: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(spacing: 0) {
                // While the filter is active, rows are a display-only subset:
                // enumerated indices no longer map to queue positions, so
                // drag-reorder is disabled (see `.onDrop` gating below).
                ForEach(Array(vm.displayedItems.enumerated()), id: \.element.id) { index, item in
                    VStack(spacing: 0) {
                        if dropTargetIndex == index {
                            Rectangle()
                                .fill(Color.accentColor)
                                .frame(height: 2)
                                .padding(.horizontal, 12)
                        }

                        QueueItemRow(item: item,
                                     isCurrentTrack: item.id == vm.currentTrack && vm.isPlayingFromQueue,
                                     isPlaying: item.id == vm.currentTrack && vm.isPlayingFromQueue && vm.sonosManager.groupTransportStates[vm.group.coordinatorID]?.isPlaying == true,
                                     isLoading: vm.playingTrack == item.id)
                            .id(item.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard vm.playingTrack == nil else { return } // Don't queue another play while one is pending
                                Task { await vm.playTrack(item.id) }
                            }
                            .contextMenu {
                                Button(L10n.play) { Task { await vm.playTrack(item.id) } }
                                Divider()
                                Button(L10n.removeFromQueue) { Task { await vm.removeTrack(item.id) } }
                            }
                            .onDrag { NSItemProvider(object: "\(item.id)" as NSString) }
                            .onDrop(of: [.text], delegate: QueueDropDelegate(
                                targetIndex: index, vm: vm,
                                dropTargetIndex: $dropTargetIndex
                            ))

                        Divider().padding(.leading, 60)
                    }
                }

                Rectangle()
                    .fill(dropTargetIndex == vm.queueItems.count ? Color.accentColor.opacity(0.3) : Color.clear)
                    .frame(height: 30)
                    .onDrop(of: [.text], delegate: QueueDropDelegate(
                        targetIndex: vm.queueItems.count, vm: vm,
                        dropTargetIndex: $dropTargetIndex
                    ))
            }
        }
        .onChange(of: vm.currentTrack) { _, newTrack in
            guard newTrack > 0, vm.isPlayingFromQueue else { return }
            performTrackChangeScroll(proxy: proxy, animated: didInitialScroll)
        }
        .onChange(of: vm.queueItems.count) { _, newCount in
            guard !didInitialScroll,
                  newCount > 0,
                  vm.currentTrack > 0,
                  vm.isPlayingFromQueue else { return }
            performTrackChangeScroll(proxy: proxy, animated: false)
        }
        .onChange(of: vm.isPlayingFromQueue) { _, newIsPlaying in
            // Metadata may flip `isQueueSource` to true *after* both
            // `currentTrack` and `queueItems` are already set by
            // `loadQueue`. Neither of the other watchers re-fires for
            // that flip, so this handler is the missing trigger for
            // the launch-from-mid-queue case.
            guard !didInitialScroll,
                  newIsPlaying,
                  vm.queueItems.count > 0,
                  vm.currentTrack > 0 else { return }
            performTrackChangeScroll(proxy: proxy, animated: false)
        }
        .onChange(of: vm.isShuffling) {
            if !vm.isShuffling, let firstID = vm.queueItems.first?.id {
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(firstID, anchor: .top)
                }
            }
        }
        }
    }

    private func handleBrowseDrop(atPosition: Int) -> Bool {
        guard let item = vm.sonosManager.draggedBrowseItem else { return false }
        vm.sonosManager.draggedBrowseItem = nil
        Task { await vm.addBrowseItem(item, atPosition: atPosition) }
        return true
    }

    /// Anchors the previous-track row to the top of the queue panel so
    /// the now-playing row sits as the second visible entry. Used by
    /// the three `.onChange` watchers (currentTrack, queueItems.count,
    /// isPlayingFromQueue). The scroll is dispatched on the next
    /// runloop turn so the `LazyVStack` has a chance to materialise
    /// the target row's identifier — `ScrollViewReader.scrollTo` is a
    /// silent no-op against ids that aren't yet in the visible /
    /// pre-materialised window, which produced the launch regression
    /// where the spinner cleared but the queue stayed at the top.
    private func performTrackChangeScroll(proxy: ScrollViewProxy, animated: Bool) {
        let current = vm.currentTrack
        guard current > 0 else { return }
        let anchorTrackID = current > 1 ? current - 1 : current
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeInOut(duration: 0.45)) {
                    proxy.scrollTo(anchorTrackID, anchor: .top)
                }
            } else {
                proxy.scrollTo(anchorTrackID, anchor: .top)
            }
            didInitialScroll = true
        }
    }
}

// MARK: - Drop Delegate

struct QueueDropDelegate: DropDelegate {
    let targetIndex: Int
    let vm: QueueViewModel
    @Binding var dropTargetIndex: Int?

    /// Drops are disabled while the display filter is active — the row
    /// indices the delegate receives are positions in the FILTERED list
    /// and would resolve to the wrong absolute queue position.
    private var filterActive: Bool { !vm.filterText.isEmpty }

    func dropEntered(info: DropInfo) {
        guard !filterActive else { return }
        dropTargetIndex = targetIndex
    }
    func dropExited(info: DropInfo) { if dropTargetIndex == targetIndex { dropTargetIndex = nil } }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: filterActive ? .forbidden : .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dropTargetIndex = nil
        guard !filterActive else { return false }

        // Browse item drag (cross-view)
        if let browseItem = vm.sonosManager.draggedBrowseItem {
            vm.sonosManager.draggedBrowseItem = nil
            let insertAt = targetIndex < vm.queueItems.count ? vm.queueItems[targetIndex].id : 0
            Task { @MainActor in await vm.addBrowseItem(browseItem, atPosition: insertAt) }
            return true
        }

        // Queue internal reorder
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let str = object as? String, let fromTrack = Int(str) else { return }
            let insertBefore: Int
            if targetIndex < vm.queueItems.count {
                insertBefore = vm.queueItems[targetIndex].id
            } else {
                insertBefore = (vm.queueItems.last?.id ?? 0) + 1
            }
            guard fromTrack != insertBefore else { return }
            Task { @MainActor in await vm.moveTrack(from: fromTrack, to: insertBefore) }
        }
        return true
    }
}

// MARK: - Queue Item Row

struct QueueItemRow: View {
    let item: QueueItem
    let isCurrentTrack: Bool
    var isPlaying: Bool = false
    var isLoading: Bool = false

    @State private var titleTruncated = false
    @State private var showTooltip = false
    @State private var hoverTask: Task<Void, Never>?

    /// Source system for this track, derived from its resource URI.
    private var source: String { ServiceName.resolve(uri: item.uri) }

    /// Measures whether the title is wider than the space it's given, so the
    /// hover tooltip only fires for names that actually truncate.
    private func checkTruncation(available: CGFloat) {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize,
                                     weight: isCurrentTrack ? .semibold : .regular)
        let intrinsic = (item.title as NSString).size(withAttributes: [.font: font]).width
        titleTruncated = intrinsic > available + 1
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                CachedAsyncImage(url: item.albumArtURI.flatMap { URL(string: $0) })
                    .frame(width: 36, height: 36)
                    .opacity(isLoading ? 0.4 : 1)
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else if isPlaying {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.black.opacity(0.4))
                        .frame(width: 36, height: 36)
                    NowPlayingBars()
                        .frame(width: 16, height: 14)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.body)
                    .fontWeight(isCurrentTrack ? .semibold : .regular)
                    .lineLimit(1)
                    .background(
                        GeometryReader { geo in
                            Color.clear
                                .onAppear { checkTruncation(available: geo.size.width) }
                                .onChange(of: geo.size.width) { _, w in checkTruncation(available: w) }
                                .onChange(of: item.title) { _, _ in checkTruncation(available: geo.size.width) }
                        }
                    )
                Text(item.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                // Third line — the source system this track plays from
                // (Apple Music, Spotify, TuneIn, Music Library, …). Same
                // classifier the save-queue destination gate and play
                // history use, so the row and the popup never disagree.
                HStack(spacing: 4) {
                    Image(systemName: ServiceName.icon(for: source))
                        .font(.system(size: 9))
                    Text(source)
                        .font(.caption2)
                }
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
            // Near-instant custom tooltip — only for titles that truncate when
            // the queue panel is narrow (the native .help() delay is ~1.5s).
            .onHover { inside in
                hoverTask?.cancel()
                guard inside, titleTruncated else { showTooltip = false; return }
                hoverTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    if !Task.isCancelled { showTooltip = true }
                }
            }
            .popover(isPresented: $showTooltip, arrowEdge: .top) {
                Text(item.artist.isEmpty ? item.title : "\(item.title) — \(item.artist)")
                    .font(.callout)
                    .lineLimit(nil)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(width: 320, alignment: .leading)
            }

            Spacer()

            Text(item.duration)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 12)
        .background(isCurrentTrack ? Color.accentColor.opacity(0.1) : Color.clear)
    }
}

// MARK: - Save Queue Sheet

/// A destination system the current queue can be saved to as a playlist.
enum SaveQueueDestination: String, Identifiable, CaseIterable {
    case sonos
    case appleMusic
    /// Local SQLite store — survives speaker resets, invisible to other
    /// controllers, no household saved-queue budget consumed.
    case choragus

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sonos:      return L10n.sonosDestination
        case .appleMusic: return ServiceName.appleMusic
        case .choragus:   return "Choragus"
        }
    }

    var icon: String {
        switch self {
        case .sonos:      return "hifispeaker.2.fill"
        case .appleMusic: return "music.note"
        case .choragus:   return "internaldrive.fill"
        }
    }
}

/// Sheet for "Save to Playlist…". The caller passes only the destinations
/// valid for the queue's contents (Sonos always; a service only when every
/// track belongs to it) plus the distinct source systems present. The sheet
/// owns name + selection state and reports the choice back through `onSave`,
/// then dismisses. Result feedback shows via the queue's own message capsule.
struct SaveQueueSheet: View {
    let destinations: [SaveQueueDestination]
    let sources: [String]
    let trackCount: Int
    let onSave: (SaveQueueDestination, String) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var destination: SaveQueueDestination
    @State private var name: String = ""
    @State private var working = false

    init(destinations: [SaveQueueDestination],
         sources: [String],
         trackCount: Int,
         onSave: @escaping (SaveQueueDestination, String) async -> Void) {
        self.destinations = destinations
        self.sources = sources
        self.trackCount = trackCount
        self.onSave = onSave
        _destination = State(initialValue: destinations.first ?? .sonos)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.saveQueueTitle)
                .font(.headline)

            // Source summary — what the queue contains, so an absent service
            // destination (e.g. Apple Music on a mixed queue) is explained.
            HStack(spacing: 6) {
                Image(systemName: "music.note.list")
                    .foregroundStyle(.secondary)
                Text(L10n.queueSource(sources.joined(separator: ", ")))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Picker(L10n.saveDestination, selection: $destination) {
                ForEach(destinations) { d in
                    Label(d.displayName, systemImage: d.icon).tag(d)
                }
            }
            .pickerStyle(.menu)

            TextField(L10n.playlistNamePlaceholder, text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)

            HStack {
                Spacer()
                Button(L10n.cancel, role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.save, action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty || working)
            }
        }
        .padding(20)
        .frame(width: 420)
        .disabled(working)
    }

    private func save() {
        let finalName = trimmedName
        guard !finalName.isEmpty, !working else { return }
        working = true
        Task {
            await onSave(destination, finalName)
            dismiss()
        }
    }
}

// MARK: - Now Playing Indicator
//
// Three vertical bars that breathe in and out on a sine-like curve next
// to the currently-playing queue row.
//
// Hosted as an `NSViewRepresentable` wrapping a plain `NSView` with
// three `CALayer` sublayers. Each sublayer carries an indefinitely-
// repeating `CABasicAnimation` on `transform.scale.y`. The animation
// runs entirely on the render server — the SwiftUI attribute graph is
// never touched after the layer is first created, so the bars do not
// drive `ViewGraph.updateOutputs` or `NSHostingView.layout` per frame.
//
// Earlier SwiftUI-native attempts (TimelineView + scaleEffect,
// TimelineView + Canvas, SF Symbol `.symbolEffect`) all reproduced a
// 50–60% main-thread CPU spike when the queue was visible because each
// frame's animation tick fed back through SwiftUI's graph and forced a
// layout pass on the surrounding LazyVStack of queue rows. Dropping out
// of SwiftUI for the animation alone removes the cascade.
private struct NowPlayingBars: NSViewRepresentable {
    func makeNSView(context: Context) -> NowPlayingBarsView {
        NowPlayingBarsView()
    }

    func updateNSView(_ nsView: NowPlayingBarsView, context: Context) {}
}

private final class NowPlayingBarsView: NSView {
    private static let barCount = 3
    private static let barWidth: CGFloat = 3
    private static let barSpacing: CGFloat = 2
    private static let minScale: CGFloat = 0.3
    private static let basePeriod: Double = 0.4
    private static let perBarPeriodIncrement: Double = 0.15
    private static let animationKey = "breathing"

    private let barLayers: [CALayer] = (0..<NowPlayingBarsView.barCount).map { _ in CALayer() }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Layer-hosting pattern: assign the layer first, then opt in
        // to `wantsLayer`. Reverse order (`wantsLayer = true` then
        // `layer = …`) makes AppKit create its own backing layer and
        // discard ours, which silently drops every animation we add.
        let host = CALayer()
        self.layer = host
        self.wantsLayer = true
        for barLayer in barLayers {
            barLayer.backgroundColor = NSColor.white.cgColor
            barLayer.cornerRadius = 1
            barLayer.anchorPoint = CGPoint(x: 0.5, y: 0)
            host.addSublayer(barLayer)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // `CAAnimation` instances added before the layer joins a window
        // are dropped silently — they require a live render-server
        // backing to register. Attaching here guarantees the layer is
        // mounted, and re-attaching covers the queue-row recycling case
        // where the same view is removed and re-added on track change.
        guard window != nil else { return }
        for (index, barLayer) in barLayers.enumerated() {
            if barLayer.animation(forKey: Self.animationKey) == nil {
                attachBreathingAnimation(to: barLayer, index: index)
            }
        }
    }

    override func layout() {
        super.layout()
        let count = CGFloat(barLayers.count)
        let totalWidth = count * Self.barWidth + (count - 1) * Self.barSpacing
        let originX = (bounds.width - totalWidth) / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, barLayer) in barLayers.enumerated() {
            let centreX = originX + CGFloat(index) * (Self.barWidth + Self.barSpacing) + Self.barWidth / 2
            barLayer.bounds = CGRect(x: 0, y: 0, width: Self.barWidth, height: bounds.height)
            barLayer.position = CGPoint(x: centreX, y: 0)
        }
        CATransaction.commit()
    }

    private func attachBreathingAnimation(to barLayer: CALayer, index: Int) {
        let period = Self.basePeriod + Self.perBarPeriodIncrement * Double(index)
        let animation = CABasicAnimation(keyPath: "transform.scale.y")
        animation.fromValue = Self.minScale
        animation.toValue = 1.0
        animation.duration = period / 2.0
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        // Stagger the per-bar phase deterministically so the three bars
        // don't pulse in unison — each shifts by a quarter-cycle.
        animation.timeOffset = period * 0.25 * Double(index)
        barLayer.add(animation, forKey: Self.animationKey)
    }
}
