/// QueueView.swift — Queue panel displaying the current play queue.
///
/// Thin view layer — all business logic lives in QueueViewModel.
/// Supports drag-drop reordering and cross-view drag from browse panel.
import SwiftUI
import SonosKit
import UniformTypeIdentifiers

struct QueueView: View {
    /// External prop — the group currently selected in the sidebar. When the
    /// user switches speakers, SwiftUI passes a new value here; it must be
    /// pushed into the view model (which otherwise holds onto the group
    /// captured at StateObject construction) and the queue reloaded.
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
    /// Last `trackURI` acted on. A new URI from the metadata stream
    /// schedules an authoritative re-sync of the current-track indicator
    /// from `getPositionInfo` — same path the manual Refresh button uses.
    /// Sonos's UPnP events push wrong / stale URIs in the seconds after
    /// a Prev/Next click, a queue-row jump, or a seek-then-auto-advance
    /// combo; the speaker's own polling response is the only source
    /// that reliably agrees with the Sonos app.
    @State private var lastObservedTrackURI: String?
    @State private var trackURIRefreshTask: Task<Void, Never>?
    /// True once the one-shot initial scroll-to-current has run for the
    /// currently-selected `group`. Reset to `false` whenever the
    /// user switches speakers. Without this, the `.onChange(of: vm.current-
    /// Track)` handler can miss the launch case where `currentTrack` is
    /// set before `queueItems` are populated — `scrollTo(id:)` is a no-op
    /// against an id that hasn't materialised in the LazyVStack yet.
    @State private var didInitialScroll = false
    @State private var healthSummaryDismissed = false

    /// Debounce before the authoritative re-sync: long enough to collapse
    /// the STOPPED→PLAYING flap, short enough to keep up with the speaker.
    private static let trackURIResyncDebounce: Duration = .milliseconds(400)

    /// Single retry for when the speaker still answers with the outgoing
    /// track after the URI event.
    private static let trackURIResyncRetry: Duration = .milliseconds(1200)

    @Environment(SonosManager.self) private var sonosManager

    init(group: SonosGroup, sonosManager: SonosManager) {
        self.group = group
        _vm = StateObject(wrappedValue: QueueViewModel(sonosManager: sonosManager, queue: sonosManager.queue, group: group))
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
            if !vm.healthVerdicts.isEmpty, !healthSummaryDismissed {
                let dead = vm.healthVerdicts.values.filter { $0 == .dead }.count
                let expired = vm.healthVerdicts.values.filter { $0 == .expired }.count
                let noInfo = vm.healthVerdicts.values.filter { $0 == .missingMetadata }.count
                HStack(spacing: 8) {
                    Text(String(format: L10n.queueHealthSummary, dead, expired, noInfo))
                        .font(.caption)
                    Spacer()
                    if dead + expired > 0 {
                        Button(L10n.queueHealthRemoveBad) {
                            Task { await removeUnplayable() }
                        }
                        .controlSize(.small)
                    }
                    Button { healthSummaryDismissed = true } label: {
                        Image(systemName: "xmark.circle.fill").font(.caption)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 5)
                .background(.quaternary.opacity(0.4))
            }
            if showFilterBar {
                filterBar
            }
            Divider()
            content
            if !vm.queueItems.isEmpty {
                Divider()
                QueueFooterView(vm: vm)
            }
        }
        // Full-window overlay shown whenever the queue is mid-mutation
        // (a batch add-to-queue or a refresh fetch in flight). Translucent
        // so the existing queue stays visible underneath. Excluded when
        // the queue is empty — that state has its own full-screen
        // progress block in `content`.
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
            // New speaker → new initial-scroll window: the one-shot
            // jump-to-current-track fires again the first time
            // `queueItems` populates for this group.
            didInitialScroll = false
            Task { await vm.loadQueue() }
            _ = newID
        }
        .onReceive(sonosManager.groupTrackMetadataPublisher) { newMap in
            vm.updateCurrentTrack()
            // Auto-reconcile on any trackURI change. Events are racy
            // (sometimes stale, sometimes wrong, sometimes out-of-
            // order) so they serve only as a *signal* that something
            // changed; the speaker is then asked authoritatively. The
            // short debounce collapses the transient burst (STOPPED →
            // PLAYING flap during Prev/Next, or the Sonos quirk where
            // it briefly emits the prior track again); the bounded
            // retry covers the case where the speaker answers with the
            // outgoing track instead of waiting out a longer sleep on
            // every single advance.
            let uri = newMap[group.coordinatorID]?.trackURI
            if uri != lastObservedTrackURI {
                lastObservedTrackURI = uri
                healthSummaryDismissed = false
                vm.noteTrackChangedForHealth()
                trackURIRefreshTask?.cancel()
                trackURIRefreshTask = Task {
                    try? await Task.sleep(for: Self.trackURIResyncDebounce)
                    if Task.isCancelled { return }
                    // Lightweight indicator-only sync — no spinner.
                    // Queue items don't change on track advance, so
                    // the full `Browse(Q:0)` round-trip is skipped.
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
            // Fast path — the sender supplied exactly what was appended. Skips
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

    /// "12 tracks · 47:12" — the playtime is a lower bound (marked `~`)
    /// while queue pages are still loading or rows carry no duration.
    private var trackCountLabel: String {
        let count = "\(vm.totalTracks) \(L10n.tracks)"
        let loaded = vm.loadedPlaytime
        let playtime = QueuePlaytime(knownSeconds: loaded.knownSeconds,
                                     unknownCount: loaded.unknownCount,
                                     unloadedCount: max(0, vm.totalTracks - vm.queueItems.count))
        return playtime.isEmpty ? count : "\(count) · \(playtime.label)"
    }

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
            // The mid-mutation indicator is a full-window overlay
            // (see `queueBusyOverlay`), not a header spinner.
            Spacer(minLength: 0)
            // Track count is informational — drops out before any
            // button gets clipped.
            ViewThatFits(in: .horizontal) {
                Text(trackCountLabel)
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
            .tooltip(L10n.refreshQueue)
            .fixedSize()
            .layoutPriority(3)

            Button {
                showFilterBar.toggle()
                if !showFilterBar { vm.filterText = "" }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle").font(.caption)
                    .foregroundStyle(showFilterBar ? sonosManager.themeAccent : Color.primary)
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
            let tree = vm.savedQueueTree
            if tree.queues.isEmpty && tree.folders.isEmpty {
                Text(L10n.noSavedQueues)
            } else {
                ChoragusQueueTreeMenu(tree: tree) { saved in
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
            // Automatic history snapshots, one submenu per room, kept
            // apart from the playlists the user named.
            let history = vm.sonosManager.allQueueSnapshots()
            if !history.isEmpty {
                Divider()
                Menu {
                    ForEach(history, id: \.coordinatorID) { entry in
                        Menu(entry.room) {
                            ForEach(entry.snapshots) { snap in
                                Menu("\(snap.savedAt.formatted(date: .abbreviated, time: .shortened)) · \(snap.summary)") {
                                    Button(L10n.queueReplace) {
                                        Task { await vm.loadSnapshot(snap, append: false) }
                                    }
                                    Button(L10n.queueAppend) {
                                        Task { await vm.loadSnapshot(snap, append: true) }
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    Label(L10n.queueHistory, systemImage: "clock.arrow.circlepath")
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
            let n = sonosManager.queue.addingToQueueProgress
            if n > 0 {
                return L10n.addingTracksFormat(n)
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
            // Full-screen spinner when there is nothing to show — first launch,
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
                                .fill(sonosManager.themeAccent)
                                .frame(height: 2)
                                .padding(.horizontal, 12)
                        }

                        QueueItemRow(item: item,
                                     isCurrentTrack: item.id == vm.currentTrack && vm.isPlayingFromQueue,
                                     isSelected: vm.selection.contains(item.id),
                                     isPlaying: item.id == vm.currentTrack && vm.isPlayingFromQueue && vm.sonosManager.groupTransportStates[vm.group.coordinatorID]?.isPlaying == true,
                                     isLoading: vm.playingTrack == item.id,
                                     healthVerdict: vm.healthVerdicts[item.id])
                            .id(item.id)
                            .contentShape(Rectangle())
                            // Double-click plays; a single click selects
                            // (⌘ toggles, ⇧ extends) so a batch can be
                            // moved, copied, or removed in one go. One
                            // handler reads the AppKit event — competing
                            // SwiftUI tap gestures dropped modifier clicks.
                            .onTapGesture { handleClick(item.id) }
                            .contextMenu { rowMenu(for: item) }
                            .onDrag { NSItemProvider(object: "\(item.id)" as NSString) }
                            .onDrop(of: [.text], delegate: QueueDropDelegate(
                                targetIndex: index, vm: vm,
                                dropTargetIndex: $dropTargetIndex
                            ))

                        Divider().padding(.leading, 60)
                    }
                }

                Rectangle()
                    .fill(dropTargetIndex == vm.queueItems.count ? sonosManager.themeAccent.opacity(0.3) : Color.clear)
                    .frame(height: 30)
                    .onDrop(of: [.text], delegate: QueueDropDelegate(
                        targetIndex: vm.queueItems.count, vm: vm,
                        dropTargetIndex: $dropTargetIndex
                    ))
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onDeleteCommand { Task { await vm.removeTracks(vm.selection) } }
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
            guard QueueScrollAnchor.shouldPerformInitialScroll(
                hasScrolledAlready: didInitialScroll,
                isPlayingFromQueue: newIsPlaying,
                currentTrack: vm.currentTrack,
                queueCount: vm.queueItems.count) else { return }
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
        // Clicking anywhere else in the window, or pressing Escape, drops
        // the selection — the same rule AppKit tables follow.
        .onClickOutside { if !vm.selection.isEmpty { vm.selection = [] } }
        .onKeyPress(.escape) {
            guard !vm.selection.isEmpty else { return .ignored }
            vm.selection = []
            return .handled
        }
    }

    private func play(_ id: Int) {
        guard vm.playingTrack == nil else { return } // Don't queue another play while one is pending
        Task { await vm.playTrack(id) }
    }

    private func handleClick(_ id: Int) {
        let event = NSApp.currentEvent
        if event?.clickCount == 2 {
            play(id)
            return
        }
        let flags = event?.modifierFlags ?? NSEvent.modifierFlags
        let gesture: QueueViewModel.SelectionGesture =
            flags.contains(.command) ? .toggle : flags.contains(.shift) ? .extend : .replace
        vm.select(id, gesture: gesture)
    }

    /// Row context menu. Acts on the selection when the row is part of
    /// it, otherwise on the row alone.
    @ViewBuilder
    private func rowMenu(for item: QueueItem) -> some View {
        let targets = vm.actionTargets(for: item.id)
        let countSuffix = targets.count > 1 ? " (\(targets.count))" : ""
        let endPosition = (vm.queueItems.last?.id ?? 0) + 1
        let newName = targets.count == 1 ? item.title : vm.group.name
        Button(L10n.play) { play(item.id) }
        Divider()
        Button(L10n.moveToTop + countSuffix) { Task { await vm.moveTracks(targets, insertBefore: 1) } }
        Button(L10n.moveToBottom + countSuffix) { Task { await vm.moveTracks(targets, insertBefore: endPosition) } }
        Menu(L10n.addToChoragusQueue + countSuffix) {
            Button(L10n.newQueueEllipsis) {
                Task { await vm.copyTracksToChoragus(targets, queueID: nil, name: newName) }
            }
            let tree = vm.sonosManager.savedQueueTree()
            if !tree.queues.isEmpty || !tree.folders.isEmpty {
                Divider()
                ChoragusQueueTreeMenu(tree: tree) { q in
                    Button(q.name) { Task { await vm.copyTracksToChoragus(targets, queueID: q.id, name: q.name) } }
                }
            }
        }
        Divider()
        Button(L10n.removeFromQueue + countSuffix) { Task { await vm.removeTracks(targets) } }
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
    /// pre-materialised window.
    private func performTrackChangeScroll(proxy: ScrollViewProxy, animated: Bool) {
        guard let anchorTrackID = QueueScrollAnchor.target(
            currentTrack: vm.currentTrack, queueCount: vm.queueItems.count) else { return }
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
            Task { @MainActor in
                // Dragging a selected row carries the whole selection.
                let moving = vm.actionTargets(for: fromTrack)
                await vm.moveTracks(moving, insertBefore: insertBefore)
            }
        }
        return true
    }
}

// MARK: - Queue Item Row

extension QueueView {
    fileprivate func removeUnplayable() async {
        let positions = vm.healthVerdicts
            .filter { $0.value == .expired || $0.value == .dead }
            .keys
        await vm.removeTracks(Set(positions))
        vm.healthVerdicts = [:]
    }
}

struct QueueItemRow: View {
    @Environment(SonosManager.self) private var sonosManager
    let item: QueueItem
    let isCurrentTrack: Bool
    var isSelected: Bool = false
    var isPlaying: Bool = false
    var isLoading: Bool = false
    var healthVerdict: QueueHealthScanner.Verdict?

    @State private var showHealthTooltip = false

    /// Source system for this track, derived from its resource URI.
    private var source: String { ServiceName.resolve(uri: item.uri) }

    private var isUnplayable: Bool {
        healthVerdict == .expired || healthVerdict == .dead
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
                HStack(spacing: 5) {
                    if let verdict = healthVerdict {
                        // Same onHover+popover pattern as the truncated-title
                        // tooltip in this row. The NSView-backed .tooltip()
                        // never fires here: the row's tap gesture owns hit
                        // testing, so the AppKit toolTip rect under a
                        // 12-point glyph is unreachable.
                        Image(systemName: verdict == .missingMetadata
                              ? "questionmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(verdict == .missingMetadata ? Color.secondary : Color.orange)
                            .onHover { showHealthTooltip = $0 }
                            .popover(isPresented: $showHealthTooltip, arrowEdge: .top) {
                                Text(verdict == .expired ? L10n.queueHealthBadgeExpired
                                     : verdict == .dead ? L10n.queueHealthBadgeDead
                                     : L10n.queueHealthBadgeNoInfo)
                                    .font(.callout)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                            }
                    }
                    // Long titles slide once to reveal themselves on
                    // hover; static when they fit.
                    MarqueeText(text: item.title,
                                font: .body,
                                fontWeight: isCurrentTrack ? .semibold : .regular,
                                scrollOnHover: true)
                }
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

            Spacer()

            Text(item.duration)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 12)
        // A row that will not play reads as inert; the badge says why.
        .opacity(isUnplayable ? 0.45 : 1)
        .background(isSelected ? sonosManager.themeAccent.opacity(0.22)
                    : isCurrentTrack ? sonosManager.themeAccent.opacity(0.1) : Color.clear)
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
// Not SwiftUI-native (TimelineView + scaleEffect / Canvas, SF Symbol
// `.symbolEffect`): each frame's animation tick feeds back through
// SwiftUI's graph and forces a layout pass on the surrounding LazyVStack
// of queue rows — a 50–60% main-thread CPU spike while the queue is
// visible. Dropping out of SwiftUI for the animation alone removes the
// cascade.
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
        // discard the assigned one, silently dropping every added animation.
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

// MARK: - Footer

/// Bottom status line: "Track 12 of 34" on the left, "~1:23:45 remaining
/// of 2:10:00" on the right. Remaining counts what is left of the current
/// track plus every row after it. Its own view so the once-a-second
/// position tick re-renders this line alone, not the queue panel.
struct QueueFooterView: View {
    @ObservedObject var vm: QueueViewModel
    @EnvironmentObject private var positionTracker: PositionTracker

    private var fromQueue: Bool { vm.isPlayingFromQueue && vm.currentTrack > 0 }

    private var total: QueuePlaytime {
        QueuePlaytime(knownSeconds: vm.loadedPlaytime.knownSeconds,
                      unknownCount: vm.loadedPlaytime.unknownCount,
                      unloadedCount: max(0, vm.totalTracks - vm.queueItems.count))
    }

    private var positionLabel: String {
        fromQueue ? L10n.queueFooterTrackOfFormat(vm.currentTrack, vm.totalTracks)
                  : "\(vm.totalTracks) \(L10n.tracks)"
    }

    private var timeLabel: String {
        let total = total
        guard !total.isEmpty else { return "" }
        guard fromQueue else { return total.label }
        let elapsed = positionTracker.groupPositions[vm.group.coordinatorID] ?? 0
        let remaining = QueuePlaytime.remaining(items: vm.queueItems, currentTrack: vm.currentTrack,
                                                elapsed: elapsed, totalCount: vm.totalTracks)
        return L10n.queueFooterRemainingFormat(remaining.label, total.label)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(positionLabel)
            Spacer(minLength: 8)
            Text(timeLabel)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.25))
    }
}
